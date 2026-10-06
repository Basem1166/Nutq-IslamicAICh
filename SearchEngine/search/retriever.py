"""
Retriever -> runs dense (FAISS) and BM25 searches and returns both result sets.

The query is encoded with a task-specific instruction prefix before embedding.
BM25 query is expanded with event/narrative vocabulary when relevant.
Both retrievers always run (unless dense_weight=1.0)
"""

import logging
import re
import numpy as np
import torch

from config import (QUERY_INSTRUCTION, DENSE_TOP_K, BM25_TOP_K, RETRIEVAL_WEIGHTS,
                    QTYPE_NARRATIVE, QTYPE_AR_KEYWORD, QTYPE_FIQH, QTYPE_THEMATIC,
                    QTYPE_NAMED, QTYPE_DIRECT_REF, QTYPE_DEFINITIONAL, QTYPE_COMPARATIVE,
                    SCOPE_QURAN, SCOPE_HADITH, SCOPE_ALL,
                    ARABIC_KEYWORD_DENSE_TOP_K, ARABIC_KEYWORD_BM25_TOP_K,)
from indexes import faiss_index, bm25_index
from models.loader import get_embedding_model
from .classifier import ClassifierResult, get_arabic_keyword_expansion, normalize_arabic, topic_gloss
from .constants import NARRATIVE_QURAN_BM25_EXPANSIONS, EVENT_BM25_EXPANSIONS, FRAME_WORDS, EVENT_INTENT_TOKENS

logger= logging.getLogger(__name__)

INSTRUCTION_GENERAL= (
    "Instruct: Given an Islamic search query, retrieve the most relevant "
    "Quran ayahs or Hadith\nQuery: "
)
INSTRUCTION_QURAN= (
    "Instruct: Given a query about the Quran, retrieve the most relevant "
    "Quran ayahs or passages\nQuery: "
)
INSTRUCTION_HADITH= (
    "Instruct: Given a query about Islamic rulings or Hadith, retrieve the "
    "most relevant Hadith\nQuery: "
)
INSTRUCTION_FIQH= (
    "Instruct: Given a question about Islamic jurisprudence (fiqh), retrieve "
    "the most relevant Quran ayahs and Hadith that establish rulings, "
    "prohibitions, obligations, or permissions on this topic\nQuery: "
)
INSTRUCTION_NARRATIVE= (
    "Instruct: Given a query about a specific Islamic historical event or "
    "story, retrieve the most relevant Quran passage about that exact event. "
    "Do not retrieve passages about different events.\nQuery: "
)
INSTRUCTION_MIXED= (
    "Instruct: Given a mixed Arabic-English Islamic search query, retrieve "
    "the most relevant Quran ayahs or Hadith\nQuery: "
)
INSTRUCTION_COMPARATIVE= (
    "Instruct: Given a comparative Islamic query asking about the difference "
    "between two concepts, retrieve passages that discuss both concepts or "
    "explicitly contrast them\nQuery: "
)
INSTRUCTION_DEFINITIONAL= (
    "Instruct: Given a query asking for the definition, meaning, or components "
    "of an Islamic concept, retrieve the most relevant Quran ayahs or Hadith "
    "that define, explain, or enumerate that concept\nQuery: "
)


class RetrieverOutput:
    """Raw results from both retrievers before fusion."""

    def __init__(self, dense_results: list[dict], bm25_results: list[dict], query_vector: np.ndarray,
                 dense_weight: float,bm25_weight: float, bm25_query_sent: str= "", bm25_tokens_used: list[str] | None= None,):
        self.dense_results= dense_results
        self.bm25_results = bm25_results
        self.query_vector = query_vector
        self.dense_weight = dense_weight
        self.bm25_weight  = bm25_weight
        self.bm25_query_sent= bm25_query_sent
        self.bm25_tokens_used= bm25_tokens_used or []


def retrieve(classification: ClassifierResult) -> RetrieverOutput:
    """Run dense (FAISS) + BM25 retrieval for the given classification.
    Returns a RetrieverOutput with both result sets and their fusion weights.
    """
    query= classification.normalized_query
    query_type= classification.query_type
    scope= classification.scope
    language= classification.language

    user_gave_scope= bool(getattr(classification, "user_scope_override", False))

    if user_gave_scope:
        effective_scope= scope
        logger.debug(f"[RETRIEVER] User provided scope '{scope}' -> no auto-override")
    elif query_type == QTYPE_NARRATIVE and scope == SCOPE_ALL:
        # keep ALL for narrative -> the narrative mismatch filter in fusion handles quality.
        # forcing QURAN would lose relevant hadith (like patience hadiths for قصة أيوب)
        effective_scope= SCOPE_ALL
        logger.debug("[RETRIEVER] Narrative query -> keeping scope ALL")
    else:
        effective_scope= scope

    dense_weight, bm25_weight= RETRIEVAL_WEIGHTS.get(query_type, RETRIEVAL_WEIGHTS[QTYPE_THEMATIC])

    if query_type == QTYPE_AR_KEYWORD:
        dense_k= ARABIC_KEYWORD_DENSE_TOP_K
        bm25_k= ARABIC_KEYWORD_BM25_TOP_K
    else:
        dense_k= DENSE_TOP_K
        bm25_k= BM25_TOP_K

    instruction= pick_instruction(query_type, effective_scope, language)
    instruction_override= getattr(classification, "instruction_override", "")
    if instruction_override:
        instruction= instruction_override

    encoded_query= instruction + classification.normalized_query
    query_vector= encode_query(encoded_query)
    logger.debug(f"[RETRIEVER] Encoded query with instruction for type={query_type}")

    # for English/mixed queries with an Arabic emotional supplement, average the
    # supplement vector in at 30% weight -> improves cross-lingual recall
    arabic_supplement= getattr(classification, "arabic_supplement", "")
    if arabic_supplement and language in ("english", "mixed"):
        supp_instruction= (
            "Instruct: Given an Islamic concept or theme, retrieve the most "
            "relevant Quran ayahs or Hadith\nQuery: "
        )
        supp_vector = encode_query(supp_instruction + arabic_supplement)
        query_vector= 0.70 * query_vector + 0.30 * supp_vector
        normalization= np.linalg.norm(query_vector)
        if normalization > 0:
            query_vector= query_vector / normalization
        logger.debug(f"[RETRIEVER] Arabic supplement averaged in: '{arabic_supplement[:60]}'")

    # for long Arabic thematic queries, also encode each concept separately and merge keeping the best score per chunk.
    norm_q_tokens= frozenset(normalize_arabic(t) for t in classification.normalized_query.split())
    is_event_query= bool(norm_q_tokens & EVENT_INTENT_TOKENS)

    should_stratify= (effective_scope == SCOPE_ALL) and (not user_gave_scope)
    stratify_types= {QTYPE_THEMATIC, QTYPE_AR_KEYWORD, QTYPE_COMPARATIVE , QTYPE_DEFINITIONAL, QTYPE_FIQH}
    run_stratified= should_stratify and (query_type in stratify_types or (query_type == QTYPE_NARRATIVE and is_event_query))

    concept_extras: list[list[dict]]= []
    if language == "arabic" and query_type == QTYPE_THEMATIC and not run_stratified and len(classification.normalized_query.split()) >= 3:
        concept_parts= split_concepts(classification.normalized_query)
        if concept_parts:
            concept_instruction= (
                "Instruct: Given an Islamic concept or theme, retrieve the most "
                "relevant Quran ayahs or Hadith\nQuery: "
            )
            per_concept_k= max(dense_k // len(concept_parts), 30)
            for concept in concept_parts:
                cvec = encode_query(concept_instruction + concept)
                cresults= faiss_index.search(query_vector=cvec, scope=effective_scope, top_k=per_concept_k)
                concept_extras.append(cresults)
            logger.debug(f"[RETRIEVER] Split-concept dense retrieval: {len(concept_parts)} concepts")

    # a named event/concept: also search with its description (TOPIC_GLOSSES), which uses the
    # vocabulary of the verses and hadiths themselves
    gloss= topic_gloss(classification.normalized_query)
    if gloss:
        gloss_vector= encode_query(instruction + f"{classification.normalized_query}: {gloss}")
        if run_stratified:
            concept_extras.append(faiss_index.search(query_vector=gloss_vector, scope=SCOPE_QURAN, top_k=dense_k // 2))
            concept_extras.append(faiss_index.search(query_vector=gloss_vector, scope=SCOPE_HADITH, top_k=dense_k // 2))
        else:
            concept_extras.append(faiss_index.search(query_vector=gloss_vector, scope=effective_scope, top_k=dense_k))
        logger.debug(f"[RETRIEVER] Topic gloss added: '{gloss[:60]}'")

    if run_stratified:
        if is_event_query:
            quran_k= dense_k // 3
            hadith_k= dense_k - quran_k
            logger.debug(f"[RETRIEVER] Event stratified: quran_k={quran_k} hadith_k={hadith_k}")
        elif query_type == QTYPE_FIQH:
            quran_k= max(dense_k * 3 // 10, 1)
            hadith_k= dense_k - quran_k
            logger.debug(f"[RETRIEVER] Fiqh stratified: quran_k={quran_k} hadith_k={hadith_k}")
        else:
            quran_k= dense_k // 2
            hadith_k= dense_k // 2

        quran_results= faiss_index.search(query_vector=query_vector, scope=SCOPE_QURAN,  top_k=quran_k)
        hadith_results= faiss_index.search(query_vector=query_vector, scope=SCOPE_HADITH, top_k=hadith_k)
        dense_results= merge_dense_results(quran_results, [hadith_results] + concept_extras, dense_k)
        logger.debug(f"[RETRIEVER] Stratified: quran={len(quran_results)} hadith={len(hadith_results)} -> merged={len(dense_results)}")

    else:
        dense_results= faiss_index.search(query_vector=query_vector, scope=effective_scope, top_k=dense_k)
        if concept_extras:
            dense_results= merge_dense_results(dense_results, concept_extras, dense_k)

    logger.debug(f"[RETRIEVER] Dense: {len(dense_results)} hits | scope={effective_scope}")

    # BM25 retrieval
    bm25_query= classification.lexical_query or classification.normalized_query

    if query_type == QTYPE_AR_KEYWORD:
        bm25_query= get_arabic_keyword_expansion(bm25_query)

    if is_event_query and effective_scope in (SCOPE_ALL, SCOPE_HADITH):
        bm25_query= expand_event_bm25_query(bm25_query, classification.normalized_query)
        logger.debug(f"[RETRIEVER] Event BM25 expansion -> '{bm25_query[:120]}'")

    if query_type == QTYPE_NARRATIVE:
        bm25_query= expand_narrative_quran_bm25_query(bm25_query, classification.normalized_query)
        logger.debug(f"[RETRIEVER] Narrative BM25 expansion -> '{bm25_query[:120]}'")

    if gloss:
        bm25_query= f"{bm25_query} {re.sub(r'\(.*?\)', ' ', gloss)}"

    logger.debug(f"[RETRIEVER] BM25 q='{bm25_query[:80]}' | scope={effective_scope} | top_k={bm25_k}")

    bm25_tokens_used= bm25_index.tokenize_query(bm25_query)
    logger.debug(f"[RETRIEVER] BM25 tokens ({len(bm25_tokens_used)}): {bm25_tokens_used[:20]}")

    if dense_weight >= 1.0:
        bm25_results= []
    else:
        bm25_results= bm25_index.search(query=bm25_query, scope=effective_scope, top_k=bm25_k)

    logger.info(
        f"[RETRIEVER] Done | dense={len(dense_results)} | bm25={len(bm25_results)} | "
        f"weights=({dense_weight:.2f}, {bm25_weight:.2f}) | tokens={bm25_tokens_used[:10]}"
    )

    return RetrieverOutput(dense_results=dense_results, bm25_results=bm25_results,
                           query_vector=query_vector, dense_weight=dense_weight,
                           bm25_weight=bm25_weight, bm25_query_sent=bm25_query, bm25_tokens_used=bm25_tokens_used,)


_VECTOR_CACHE: dict[str, np.ndarray]= {}
_VECTOR_CACHE_MAX= 256

def encode_query(text: str) -> np.ndarray:
    """Encode a single query string into a normalised float32 vector.
    Results are cached -> max 256 entries with oldest-first eviction.
    """
    if text in _VECTOR_CACHE:
        return _VECTOR_CACHE[text]

    model= get_embedding_model()
    with torch.no_grad():
        raw_embedding= model.encode(text, normalize_embeddings=True,
                                    convert_to_tensor=False,show_progress_bar=False,)

    result= np.array(raw_embedding, dtype="float32")

    if len(_VECTOR_CACHE) >= _VECTOR_CACHE_MAX:
        oldest_cached_query = next(iter(_VECTOR_CACHE))
        del _VECTOR_CACHE[oldest_cached_query]
    _VECTOR_CACHE[text]= result

    return result


def pick_instruction(query_type: str, scope: str, language: str= "english") -> str:
    """Return the most appropriate embedding instruction for this query type and scope."""
    if query_type == QTYPE_DEFINITIONAL:
        if scope == SCOPE_HADITH:
            return INSTRUCTION_HADITH
        if scope == SCOPE_QURAN:
            return INSTRUCTION_QURAN
        return INSTRUCTION_DEFINITIONAL

    if query_type == QTYPE_FIQH:
        if scope == SCOPE_HADITH:
            return INSTRUCTION_HADITH
        if scope == SCOPE_QURAN:
            return INSTRUCTION_QURAN
        return INSTRUCTION_FIQH

    if query_type == QTYPE_NARRATIVE:
        return INSTRUCTION_NARRATIVE

    if query_type == QTYPE_COMPARATIVE:
        if scope == SCOPE_QURAN:
            return INSTRUCTION_QURAN
        if scope == SCOPE_HADITH:
            return INSTRUCTION_HADITH
        return INSTRUCTION_COMPARATIVE

    if language == "mixed":
        return INSTRUCTION_MIXED
    if scope == SCOPE_QURAN:
        return INSTRUCTION_QURAN
    if scope == SCOPE_HADITH:
        return INSTRUCTION_HADITH
    return INSTRUCTION_GENERAL


def split_concepts(query: str) -> list[str]:
    """Split an Arabic query like 'الصبر والشكر' into ['الصبر', 'الشكر'].
    Only fires for Arabic queries with 2+ content tokens.
    Returns empty list if no valid split found.
    """
    normalized_query= normalize_arabic(query)
    split_segments= re.split(r'\s+و(?:ال)?\s*', normalized_query)
    if len(split_segments) < 2:
        return []

    extracted_concepts= []
    for part in split_segments:
        tokens= [t for t in part.split() if len(t) >= 2 and normalize_arabic(t) not in FRAME_WORDS]
        if tokens:
            extracted_concepts.append(" ".join(tokens))

    return extracted_concepts if len(extracted_concepts) >= 2 else []


def merge_dense_results(base: list[dict], extras: list[list[dict]], top_k: int) -> list[dict]:
    """Merge multiple dense result lists into one ranked list of length top_k.
    Keeps the best score for each chunk_id across all lists.
    """
    best: dict[str, dict]= {result["chunk_id"]: result for result in base}
    for result_list in extras:
        for result in result_list:
            chunk_id= result["chunk_id"]
            if chunk_id not in best or result["score"] > best[chunk_id]["score"]:
                best[chunk_id]= result

    merged= sorted(best.values(), key=lambda x: x["score"], reverse=True)[:top_k]
    for rank, result in enumerate(merged, start=1):
        result["rank"]= rank
    return merged


def expand_event_bm25_query(bm25_query: str, normalized_query: str) -> str:
    """Append canonical hadith surface forms for known historical events.
    Helps BM25 match hadiths using classical vocabulary the user didn't type.
    """
    normalized_text = normalize_arabic(normalized_query.lower())
    expansion_terms_to_add = []

    for trigger_signal, classical_expansion in EVENT_BM25_EXPANSIONS.items():
        
        # Edge Case 1: "Conquest" (Fath) must co-occur with "Mecca" 
        # to avoid false positives on other queries like "Conquest of Jerusalem"
        if trigger_signal  == "فتح":
            if "مكه" in normalized_text:
                expansion_terms_to_add.append(classical_expansion)
            continue

        # Edge Case 2: The Battle of Uhud (Compound Key)
        # Checking for any battle synonym PLUS the word "Uhud"
        if trigger_signal  == "غزوهاحد":
            battle_keywords = ("غزوه", "معركه", "غزوة", "معركة")
            
            has_battle_word = any(keyword in normalized_text for keyword in battle_keywords)
            if has_battle_word and "احد" in normalized_text:
                expansion_terms_to_add.append(classical_expansion)
            continue

        # Standard Case: Direct substring match for all other events
        if trigger_signal in normalized_text:
            expansion_terms_to_add.append(classical_expansion)
    if not expansion_terms_to_add:
        return bm25_query
    all_expansions_combined = " ".join(expansion_terms_to_add)
    return f"{bm25_query} {all_expansions_combined}"

def expand_narrative_quran_bm25_query(bm25_query: str, normalized_query: str) -> str:
    """Append distinctive Quran vocabulary for narrative story queries.
    Fires for both scope=QURAN and scope=ALL.
    """
    normalized_text = normalize_arabic(normalized_query.lower())
    expansion_terms_to_add = []

    for trigger_signal, quranic_expansion in NARRATIVE_QURAN_BM25_EXPANSIONS.items():
        if trigger_signal in normalized_text:
            expansion_terms_to_add.append(quranic_expansion)
    if not expansion_terms_to_add:
        return bm25_query

    all_expansions_combined = " ".join(expansion_terms_to_add)
    return f"{bm25_query} {all_expansions_combined}"
