"""
BM25 index over the Islamic corpus.

Design notes:
- BM25Okapi with k1=1.5, b=0.65.
  b is below the 0.75 default because Arabic root-based morphology produces
  longer average document lengths -> lower b reduces the length penalty so
  shorter hadith snippets aren't unfairly penalised.

- Indexed field: combined arabic + tafsir + English translation.

- Tokenisation uses arabic_tokenize_passage() / arabic_tokenize_query()
  from tokenizer.py -> consistent tashkeel/hamza normalisation, light stemming,
  and stopword removal across index time and query time.

- Synonym expansion at query time: if synonym_index.json exists it's loaded
  once and each query stem is expanded with its top-N synonyms.

- Bigram injection for Arabic multi-word queries so "حسن الخلق" also emits
  "حسن_الخلق" to reward co-occurrence.

- Index is pickled to disk; subsequent restarts load in ~2s vs ~60s rebuild.

- Scope filtering is post-search (same pattern as the FAISS index).
"""

from __future__ import annotations

import json
import logging
import pickle
import re
from pathlib import Path
from typing import Any
import numpy as np
from rank_bm25 import BM25Okapi
from config import (BM25_INDEX_FILE, SYNONYM_INDEX_PATH, BM25_TOP_K, HADITH_SOURCE_TYPES, QURAN_SOURCE_TYPES, SCOPE_ALL, SCOPE_HADITH, SCOPE_QURAN,
                    MAX_SYNONYMS_PER_TOKEN, BM25_SYNONYM_WEIGHT, BM25_B, BM25_K1, HADITH, HADITH_CLUSTER)
from search.classifier import normalize_arabic
from search.constants import PUNCT_PATTERN
from search.tokenizer import arabic_tokenize_passage, english_tokenize, light_stem
from search.helpers import extract_matn, strip_english_isnad


logger= logging.getLogger(__name__)

# module-level state -> populated by load_bm25_index()
index_state: dict[str, Any]= {
    "bm25":          None,
    "chunk_ids":     None,
    "source_types":  None,
    "doc_tokens":    None,
    "synonym_index": {},
    "quran_mask":    None,   # pre-computed boolean mask for Quran documents
    "hadith_mask":   None,   # pre-computed boolean mask for Hadith documents
    "loaded":        False,
}


def normalize_text(text: str) -> str:
    if not isinstance(text, str):
        return ""
    return normalize_arabic(text).lower()


def tokenize_document(text: str) -> list[str]:
    """Tokenise a corpus document at index-build time.
    Applies normalisation, punctuation stripping, light stemming,
    and the extended PASSAGE_EXTRA_STOPWORDS set.
    Also appends bigrams for adjacent Arabic tokens.
    """
    text= normalize_text(text)

    arabic_part= re.sub(r'[^\u0600-\u06FF\s]', ' ', text)
    english_part= re.sub(r'[\u0600-\u06FF]', ' ', text)

    arabic_tokens= arabic_tokenize_passage(arabic_part)
    english_tokens= english_tokenize(english_part)
    tokens= arabic_tokens + english_tokens

    if len(arabic_tokens) >= 2:
        bigrams = []
        for i in range(len(arabic_tokens) - 1):
            word_1 = arabic_tokens[i]
            word_2 = arabic_tokens[i + 1]
            paired_token = f"{word_1}_{word_2}"
            bigrams.append(paired_token)
        tokens = tokens + bigrams

    return tokens


_SHORT_PROCLITICS= ("ب", "ل", "ك")
_CONJUNCTIONS= ("و", "ف")
PROCLITIC_MIN_DF= 20      # the bare word must be a common token in the corpus ...
PROCLITIC_DF_RATIO= 3     # ... and far more common than the prefixed form


def proclitic_candidates(text: str) -> list[tuple[str, str]]:
    """(stem of the word, stem without its proclitic) for short prefixed words.

    light_stem keeps 4+ letters after a single-letter proclitic so roots are not cut
    (بلد, كتب stay whole) -> ببدر, بمكة, لمكة were indexed as ببدر / بمك and never matched
    a query for بدر / مكة. Whether the bare form is the real word is decided from corpus
    frequencies in add_proclitic_variants().
    """
    text= PUNCT_PATTERN.sub(" ", normalize_text(re.sub(r"[^؀-ۿ\s]", " ", text)))
    out= []
    for word in text.split():
        bare= word
        if bare[:1] in _CONJUNCTIONS and len(bare) >= 4:
            bare= bare[1:]
        if bare[:1] in _SHORT_PROCLITICS and len(bare) - 1 == 3:
            out.append((light_stem(word), light_stem(bare[1:])))
    return out


def add_proclitic_variants(texts: list[str], tokenized: list[list[str]]) -> int:
    """Append the bare-word token to documents whose prefixed short word is a known word
    with a proclitic (ببدر -> بدر), using document frequencies over the whole corpus."""
    from collections import Counter
    df= Counter()
    for tokens in tokenized:
        df.update(set(tokens))
    added= 0
    for text, tokens in zip(texts, tokenized):
        have= set(tokens)
        for full, bare in proclitic_candidates(text):
            if bare in have or len(bare) < 3:
                continue
            if df[bare] >= PROCLITIC_MIN_DF and df[bare] >= PROCLITIC_DF_RATIO * max(1, df[full]):
                tokens.append(bare)
                have.add(bare)
                added += 1
    return added


def strip_query_frame(text: str) -> str:
    """Remove meta-language framing from a query before BM25 tokenisation.

    Phrases like "ما ورد عن الأمانة في الحديث" are framed -> "ما ورد عن ... في الحديث"
    is boilerplate and "الأمانة" is the real search term.
    Only applied to Arabic queries.
    """
    FRAME_PHRASES= [
        'ما يقوله القران عن', 'ما يقوله القرآن عن',
        'ما ورد عن', 'ما ورد في', 'ما جاء عن', 'ما جاء في',
        'ما ذكر عن', 'ما ذكر في',
        'كيف تتحدث السنة عن', 'كيف تتحدث عن',
        'في القران', 'في القرآن',
        'في الحديث', 'في السنة', 'في الاسلام', 'في الإسلام',
        'آيات عن', 'آيات تتعلق بـ', 'آيات تتعلق',
        'أحاديث عن', 'احاديث عن',
        'حديث عن',
        'موضوع',
        'الواردة في', 'الواردة',
        'الوارد في', 'الوارد',
        'المتعلقة بـ', 'المتعلقة',
        'المتعلق بـ', 'المتعلق',
        'يتعلق بـ', 'يتعلق',
        'تتعلق بـ', 'تتعلق',
        'مسألة',
    ]
    result= text
    for phrase in FRAME_PHRASES:
        result= result.replace(phrase, ' ')
    return ' '.join(result.split())


def tokenize_query(text: str) -> list[str]:
    """Tokenise a query string at search time.

    Uses arabic_tokenize_query() which emits both stemmed and raw normalised forms.
    Also appends bigrams and synonym expansions.
    This function is public so retriever.py can call it for debug logging.
    """
    base_tokens, expansions= tokenize_query_parts(text)
    return base_tokens + expansions


def tokenize_query_parts(text: str) -> tuple[list[str], list[str]]:
    """Return (query tokens + bigrams, synonym expansions) separately so search()
    can weight the synonyms below the user's own words."""
    from search.tokenizer import arabic_tokenize_query, english_tokenize

    text= strip_query_frame(text)
    text= normalize_text(text)

    arabic_part= re.sub(r'[^\u0600-\u06FF\s]', ' ', text)
    english_part= re.sub(r'[\u0600-\u06FF]', ' ', text)

    arabic_tokens= arabic_tokenize_query(arabic_part)
    english_tokens= english_tokenize(english_part)
    base_tokens= arabic_tokens + english_tokens

    if len(arabic_tokens) >= 2:
        bigrams = []
        for i in range(len(arabic_tokens) - 1):
            word_1 = arabic_tokens[i]
            word_2 = arabic_tokens[i + 1]
            paired_token = f"{word_1}_{word_2}"
            bigrams.append(paired_token)
        base_tokens = base_tokens + bigrams

    # synonym expansion
    synonym_index= index_state["synonym_index"]
    expansions: list[str]= []
    if synonym_index and MAX_SYNONYMS_PER_TOKEN > 0 and BM25_SYNONYM_WEIGHT > 0:
        seen= set(base_tokens)
        for token in base_tokens:
            for syn in synonym_index.get(token, [])[:MAX_SYNONYMS_PER_TOKEN]:
                if syn not in seen:
                    expansions.append(syn)
                    seen.add(syn)

    return base_tokens, expansions


def load_synonym_index() -> dict[str, list[str]]:
    """Load synonym_index.json if it exists."""
    if not SYNONYM_INDEX_PATH.exists():
        logger.info(f"No synonym index at '{SYNONYM_INDEX_PATH}' -> running without synonym expansion.")
        return {}
    try:
        with open(SYNONYM_INDEX_PATH, "r", encoding="utf-8") as f:
            data= json.load(f)

        def canonical(token: str) -> str:
            """Normalize -> strip punctuation -> stem -> return canonical BM25 token form.
            Returns '' for tokens that would be dropped by the BM25 tokenizer
            """
            token= PUNCT_PATTERN.sub(' ', normalize_arabic(token)).strip()
            if not token or ' ' in token or len(token) < 3:
                return ''
            stemmed= light_stem(token)
            return stemmed if len(stemmed) >= 3 else ''

        cleaned: dict[str, list[str]]= {}
        for key, syns in data.items():
            ck= canonical(key)
            if not ck:
                continue
            seen = set()
            clean_syns = []
            for syn in syns:
                s = canonical(syn)
                if s != "" and s != ck:
                    if s not in seen:
                        seen.add(s)
                        clean_syns.append(s)
            if ck in cleaned:
                existing_set= set(cleaned[ck])
                cleaned[ck].extend(s for s in clean_syns if s not in existing_set)
                existing_set.update(clean_syns)
            elif clean_syns:
                cleaned[ck]= clean_syns

        logger.info(f"Synonym index: {len(cleaned):,} entries from '{SYNONYM_INDEX_PATH}'.")
        return cleaned
    except Exception as exc:
        logger.warning(f"Failed to load synonym index: {exc}")
        return {}


def build_bm25_index(corpus_map: dict) -> None:
    """Build a BM25 index from corpus_map and write it to BM25_INDEX_FILE.

    For hadiths, only the matn (actual hadith text) is indexed -> the isnad
    narrator chain is stripped so narrator names don't pollute thematic queries.
    """
    logger.info(f"Building BM25 index over {len(corpus_map):,} chunks ...")

    chunk_ids: list[str]= []
    source_types: list[str]= []
    tokenized: list[list[str]]= []
    texts: list[str]= []

    for chunk_id, chunk in corpus_map.items():
        source_type= chunk.get("source_type", "")

        if source_type == HADITH:
            # index matn only -> isnad tokens pollute BM25 with narrator names
            ar_full= chunk.get("arabic_text_normalized", "") or chunk.get("arabic_text", "")
            en_full= chunk.get("english_text", "")
            from search.helpers import extract_matn, strip_english_isnad
            ar_matn, _= extract_matn(ar_full)
            en_matn= strip_english_isnad(en_full)
            text= f"{ar_matn} {en_matn}"

        elif source_type == HADITH_CLUSTER:
            parts= []
            for m in chunk.get("members", []):
                arabic_full= m.get("arabic_text_normalized", "") or m.get("arabic_text", "")
                english_full= m.get("english_text", "")
                arabic_matn, _= extract_matn(arabic_full)
                english_matn= strip_english_isnad(english_full)
                parts.extend([arabic_matn, english_matn])
            valid_parts = []
            for part in parts:
                if part is not None and part != "":
                    valid_parts.append(part)
            text = " ".join(valid_parts)

        else:
            text= chunk.get("combined_arabic_text_normalized", "")
            if not text:
                parts= [chunk.get("arabic_text_normalized", ""),
                        chunk.get("arabic_text", ""),
                        chunk.get("english_text", ""),
                        chunk.get("english_translation", ""),]
                valid_parts = []
                for part in parts:
                    if part is not None and part != "":
                        valid_parts.append(part)
                text = " ".join(valid_parts)

        tokens= tokenize_document(text)
        texts.append(text)

        # BM25 breaks on empty doc lists -> use chunk_id as sentinel
        if not tokens:
            tokens= [chunk_id]

        chunk_ids.append(chunk_id)
        source_types.append(source_type)
        tokenized.append(tokens)

    added= add_proclitic_variants(texts, tokenized)
    logger.info(f"  added {added:,} proclitic-stripped tokens (e.g. ببدر -> بدر)")

    bm25= BM25Okapi(tokenized, k1=BM25_K1, b=BM25_B)

    BM25_INDEX_FILE.parent.mkdir(parents=True, exist_ok=True)
    payload= {"bm25": bm25,
              "chunk_ids": chunk_ids,
              "source_types": source_types,
              "doc_tokens": tokenized,}
    with open(BM25_INDEX_FILE, "wb") as f:
        pickle.dump(payload, f, protocol=pickle.HIGHEST_PROTOCOL)

    logger.info(f"BM25 index saved to '{BM25_INDEX_FILE}'.")

    index_state["bm25"]= bm25
    index_state["chunk_ids"]= chunk_ids
    index_state["source_types"]= source_types
    index_state["doc_tokens"]= tokenized
    index_state["loaded"]= True
    build_scope_masks()
    logger.info("BM25 index ready.")


def load_bm25_index(corpus_map: dict | None= None) -> None:
    """Load the BM25 index from disk.
    If the pickle doesn't exist, builds it from corpus_map (must be provided).
    The synonym index is always reloaded from disk so updates are picked up.
    """
    if index_state["loaded"]:
        logger.warning("BM25 index already loaded -> skipping.")
        return

    if Path(BM25_INDEX_FILE).exists():
        logger.info(f"Loading BM25 index from '{BM25_INDEX_FILE}' ...")
        with open(BM25_INDEX_FILE, "rb") as f:
            payload= pickle.load(f)

        index_state["bm25"]= payload["bm25"]
        index_state["chunk_ids"]= payload["chunk_ids"]
        index_state["source_types"]= payload["source_types"]
        index_state["doc_tokens"]= payload.get("doc_tokens")
        index_state["loaded"]= True
        build_scope_masks()
        logger.info(f"BM25 index loaded -> {len(index_state['chunk_ids']):,} documents.")
    else:
        if corpus_map is None:
            raise RuntimeError(
                f"BM25 index not found at '{BM25_INDEX_FILE}' and no corpus_map provided. "
                "Pass corpus_map to load_bm25_index() on first startup."
            )
        logger.info("BM25 pickle not found -> building from corpus_map ...")
        build_bm25_index(corpus_map)

    index_state["synonym_index"]= load_synonym_index()


def search(query: str,scope: str= SCOPE_ALL, top_k: int= BM25_TOP_K,) -> list[dict]:
    """BM25 keyword search with stemmed tokenisation and synonym expansion.

    query: raw query string 
    scope: SCOPE_ALL | SCOPE_QURAN | SCOPE_HADITH.
    Returns list of {chunk_id, source_type, score, rank} sorted by score desc.
    """
    check_loaded()

    tokens, synonym_tokens= tokenize_query_parts(query)
    if not tokens:
        logger.debug("BM25: query tokenised to empty -> returning []")
        return []

    logger.debug(
        f"BM25 tokens ({len(tokens)}): {tokens[:20]}"
        + (" ..." if len(tokens) > 20 else "")
        + (f" | synonyms x{BM25_SYNONYM_WEIGHT}: {synonym_tokens[:20]}" if synonym_tokens else "")
    )

    # the synonym index is automatically built and noisy (ربا -> رباح/رهب, صيام -> رجيم),
    # so expansions only add a down-weighted score on top of the user's own terms
    raw_scores: np.ndarray= index_state["bm25"].get_scores(tokens)
    if synonym_tokens:
        raw_scores= raw_scores + BM25_SYNONYM_WEIGHT * index_state["bm25"].get_scores(synonym_tokens)
    allowed_types= scope_to_types(scope)

    if allowed_types is None:
        # global top-k, no scope filter
        fetch_k= min(top_k, len(raw_scores))
        top_indices= np.argpartition(raw_scores, -fetch_k)[-fetch_k:]
        top_indices= top_indices[np.argsort(raw_scores[top_indices])[::-1]]
    else:
        # scope-filtered: restrict to the allowed document subset before ranking
        # so the global top-K can't be monopolised by the other corpus type
        mask_key= "quran_mask" if scope == SCOPE_QURAN else "hadith_mask"
        scope_mask= index_state.get(mask_key)
        if scope_mask is None:
            scope_mask= np.array([st in allowed_types for st in index_state["source_types"]])
        scoped_indices= np.where(scope_mask)[0]
        if scoped_indices.size == 0:
            logger.debug(f"BM25 | scope={scope} top_k={top_k} hits=0 (no docs in scope)")
            return []
        scoped_scores= raw_scores[scoped_indices]
        fetch_k= min(top_k, scoped_indices.size)
        top_local= np.argpartition(scoped_scores, -fetch_k)[-fetch_k:]
        top_local= top_local[np.argsort(scoped_scores[top_local])[::-1]]
        top_indices= scoped_indices[top_local]

    results: list[dict]= []
    for idx in top_indices:
        score= float(raw_scores[idx])
        if score <= 0.0:
            break   # scores are non-negative; zero means no token overlap

        source_type= index_state["source_types"][idx]
        if allowed_types and source_type not in allowed_types:
            continue

        results.append({"chunk_id": index_state["chunk_ids"][idx],
                        "source_type": source_type,
                        "score": score,})

        if len(results) >= top_k:
            break

    for rank, result in enumerate(results, start=1):
        result["rank"]= rank

    logger.debug(f"BM25 | scope={scope} top_k={top_k} hits={len(results)}")
    return results


def scope_to_types(scope: str) -> set[str] | None:
    if scope == SCOPE_QURAN:
        return QURAN_SOURCE_TYPES
    if scope == SCOPE_HADITH:
        return HADITH_SOURCE_TYPES
    return None


def build_scope_masks() -> None:
    """Pre-compute boolean masks for scope filtering."""
    source_types= index_state["source_types"]
    arr= np.array(source_types)
    index_state["quran_mask"]= np.isin(arr, list(QURAN_SOURCE_TYPES))
    index_state["hadith_mask"]= np.isin(arr, list(HADITH_SOURCE_TYPES))


def check_loaded() -> None:
    if not index_state["loaded"]:
        raise RuntimeError(
            "BM25 index not loaded. Call load_bm25_index() at startup."
        )


def is_loaded() -> bool:
    return index_state["loaded"]


def index_stats() -> dict:
    if not index_state["loaded"]:
        return {"loaded": False}
    return {"loaded": True,
            "documents":len(index_state["chunk_ids"]),
            "k1":BM25_K1,
            "b": BM25_B,
            "synonyms_loaded": len(index_state["synonym_index"]) > 0,
            "synonym_entries": len(index_state["synonym_index"]),}
