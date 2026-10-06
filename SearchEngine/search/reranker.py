"""
Cross-encoder reranker using BAAI/bge-reranker-v2-m3.

Sends every (query, passage) pair to the model jointly

Results are cached in-memory by a hash of (query, candidate_ids) so repeated
backfill calls with the same inputs don't hit the GPU twice.
"""

import logging
import hashlib
import numpy as np
from pyarabic.araby import strip_tashkeel
from config import RERANKER_ENSEMBLE_WEIGHT, RERANKER_ENSEMBLE_WEIGHT_QURAN, RERANK_TOP_K, RERANKER_BATCH_SIZE, MAX_ARABIC_CHARS, MAX_ENGLISH_CHARS, MAX_TAFSIR_CHARS, MAX_HADITH_ARABIC_CHARS, MAX_HADITH_ENGLISH_CHARS, QURAN_SOURCE_TYPES, HADITH_SOURCE_TYPES
from indexes.faiss_index import get_chunks_by_ids
from models.loader import get_reranker
from .helpers import extract_matn, strip_english_isnad, strip_grading_tail

logger= logging.getLogger(__name__)

# simple md5-keyed cache; oldest entry evicted when full
rerank_cache: dict[str, list[dict]]= {}
CACHE_MAX= 128
cache_hits= 0
cache_miss= 0


# weight of the second ensemble reranker per source (mutable so the eval can sweep it)
ENSEMBLE_WEIGHTS= {"quran": RERANKER_ENSEMBLE_WEIGHT_QURAN, "other": RERANKER_ENSEMBLE_WEIGHT}


def cache_key(query: str, chunk_ids: list[str]) -> str:
    raw= query.strip().lower() + "|" + ",".join(chunk_ids)
    return hashlib.md5(raw.encode("utf-8")).hexdigest()

def rerank(query: str, candidates: list[dict], top_k: int= RERANK_TOP_K,) -> list[dict]:
    """Score every (query, passage) pair with the cross-encoder, return top_k.

    Candidates must have chunk_id. Data field is fetched from FAISS if missing.
    Results sorted by reranker_score descending.
    """
    global cache_hits, cache_miss
    if not candidates:
        return []

    chunk_ids= [candidate["chunk_id"] for candidate in candidates]
    key= cache_key(query, chunk_ids)

    if key in rerank_cache:
        cache_hits += 1
        logger.debug(f"[RERANK] cache hit (hits={cache_hits}, miss={cache_miss})")
        return rerank_cache[key][:top_k]

    cache_miss += 1
    logger.debug(f"[RERANK] scoring {len(candidates)} candidates for '{query[:60]}'")

    chunks= get_chunks_by_ids(chunk_ids)
    chunk_map= {chunk["chunk_id"]: chunk for chunk in chunks}

    pairs= []
    valid_candidates= []

    for candidate in candidates:
        chunk= chunk_map.get(candidate["chunk_id"])
        if chunk is None:
            logger.warning(f"[RERANK] chunk {candidate['chunk_id']} not in corpus -> skipping")
            continue
        pairs.append([query, build_passage_text(chunk)])
        valid_candidates.append(candidate)

    if not pairs:
        return []

    model= get_reranker()
    batch_size= min(RERANKER_BATCH_SIZE, len(pairs))

    if hasattr(model, "members") and len(model.members) == 2:
        # bge under-rates ayahs (Q 3:123 "ولقد نصركم الله ببدر" scored 0.04 for "غزوة بدر", Qwen 0.96),
        # so the second reranker gets a larger say on Quran candidates
        second_weights= [ENSEMBLE_WEIGHTS["quran"] if chunk_map[c["chunk_id"]].get("source_type") in QURAN_SOURCE_TYPES
                         else ENSEMBLE_WEIGHTS["other"] for c in valid_candidates]
        scores= model.predict(pairs, second_weights=second_weights, batch_size=batch_size, show_progress_bar=False,
                              convert_to_numpy=True,)
    else:
        scores: np.ndarray= model.predict(pairs, batch_size=batch_size, show_progress_bar=False, convert_to_numpy=True,)

    ranked_indices= np.argsort(scores)[::-1]

    all_results= []
    for final_rank, idx in enumerate(ranked_indices, start=1):
        candidate= valid_candidates[idx].copy()
        chunk= chunk_map[candidate["chunk_id"]]

        candidate["reranker_score"]= float(scores[idx])
        candidate["final_rank"]= final_rank
        candidate["chunk"]= format_chunk(chunk)

        all_results.append(candidate)

    logger.debug(f"[RERANK] done | scored={len(all_results)} | "
                 f"top={all_results[0]['reranker_score']:.4f} | "
                 f"bottom={all_results[-1]['reranker_score']:.4f}")

    if len(rerank_cache) >= CACHE_MAX:
        del rerank_cache[next(iter(rerank_cache))]
    rerank_cache[key]= all_results

    return all_results[:top_k]

def build_passage_text(chunk: dict) -> str:
    """Assemble the passage string sent to the cross-encoder for a given chunk."""
    source_type= chunk.get("source_type", "")

    if source_type in QURAN_SOURCE_TYPES:
        # imla'i (simple) script: the cross-encoder reads Uthmani spelling poorly
        # (Q 5:6 for "أحكام الطهارة قبل الصلاة": Uthmani 0.009 vs simple 0.91)
        arabic= quran_simple_text(chunk)[:MAX_ARABIC_CHARS]
        english= chunk.get("english_translation", "")[:MAX_ENGLISH_CHARS]
        tafsir= chunk.get("arabic_tafsir", "")[:MAX_TAFSIR_CHARS] if MAX_TAFSIR_CHARS > 0 else ""
        return f"{arabic} {english} {tafsir}".strip()

    if source_type == "Hadith":
        # diacritics hide the matn markers (قَالَ رَسُولُ) and the grading note is not content
        matn, _= extract_matn(strip_grading_tail(strip_tashkeel(chunk.get("arabic_text", ""))))
        arabic= matn[:MAX_HADITH_ARABIC_CHARS]
        english= strip_english_isnad(chunk.get("english_text", ""))[:MAX_HADITH_ENGLISH_CHARS]
        return f"{arabic} {english}".strip()

    if source_type == "Hadith_Cluster":
        arabic= chunk.get("arabic_text_normalized", "")[:MAX_ARABIC_CHARS]
        english= chunk.get("english_text", "")[:MAX_ENGLISH_CHARS]
        return f"{arabic} {english}".strip()

    # fallback
    arabic= chunk.get("arabic_text", "")[:MAX_ARABIC_CHARS]
    english= chunk.get("english_text", chunk.get("english_translation", ""))[:MAX_ENGLISH_CHARS]
    return f"{arabic} {english}".strip()


def quran_simple_text(chunk: dict) -> str:
    """Imla'i text of an ayah or of all ayahs of a passage window (Uthmani as a last resort)."""
    if chunk.get("source_type") == "Quran_Passage":
        members= chunk.get("members", [])
        text= " ".join(m.get("arabic_text_simple", "") for m in members).strip()
        if text:
            return text
        return chunk.get("combined_arabic_text_normalized") or chunk.get("arabic_text", "")
    return chunk.get("arabic_text_simple") or chunk.get("arabic_text", "")


def format_chunk(chunk: dict) -> dict:
    """Format a raw corpus chunk into the API response shape."""
    source_type= chunk.get("source_type", "")
    base= {"chunk_id": chunk.get("chunk_id"),
            "source_type": source_type,}

    if source_type == "Quran_Tafsir":
        base.update({"surah_id": chunk.get("surah_id"),
                     "ayah_id": chunk.get("ayah_id"),
                     "arabic_text": chunk.get("arabic_text", ""),
                     "english_translation": chunk.get("english_translation", ""),
                     "arabic_tafsir": chunk.get("arabic_tafsir", ""),})

    elif source_type == "Quran_Passage":
        base.update({"surah_id": chunk.get("surah_id"),
                     "start_ayah": chunk.get("start_ayah"),
                     "end_ayah": chunk.get("end_ayah"),
                     "ayah_count": chunk.get("ayah_count"),
                     "window_size": chunk.get("window_size"),
                     "arabic_text": chunk.get("arabic_text", ""),
                     "english_translation": chunk.get("english_translation", ""),
                     "arabic_tafsir": chunk.get("arabic_tafsir", ""),
                     "members": [
                        {"chunk_id": member.get("chunk_id"),
                         "ayah_id":member.get("ayah_id"),
                         "arabic_text": member.get("arabic_text", ""),
                         "english_translation": member.get("english_translation", ""),}
                         for member in chunk.get("members", [])],
                    })

    elif source_type == "Hadith":
        base.update({"book_name": chunk.get("book_name", ""),
                     "chapter_id": chunk.get("chapter_id", ""),
                     "hadith_id": chunk.get("hadith_id", ""),
                     "arabic_text": chunk.get("arabic_text", ""),
                     "english_text": chunk.get("english_text", ""),
                     "grades": chunk.get("grades", []),})

    elif source_type == "Hadith_Cluster":
        base.update({"book_name":chunk.get("book_name", ""),
                     "chapter_id": chunk.get("chapter_id", ""),
                     "hadith_count": chunk.get("hadith_count", 0),
                     "members": [{"chunk_id":member.get("chunk_id"),
                         "hadith_id": member.get("hadith_id", ""),
                         "arabic_text": member.get("arabic_text", ""),
                         "english_text": member.get("english_text", ""),}
                         for member in chunk.get("members", [])],})
    return base

def cache_stats() -> dict:
    """Reranker cache stats for the /health endpoint."""
    total= cache_hits + cache_miss
    return {"size": len(rerank_cache), "max": CACHE_MAX,
            "hits": cache_hits,
            "misses": cache_miss,
            "hit_rate": round(cache_hits / max(1, total), 3),}
