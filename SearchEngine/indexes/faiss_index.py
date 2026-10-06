import logging
import numpy as np
import faiss

from config import (VECTOR_FILE, CORPUS_MAP_FILE, EMBEDDING_DIMENSION, DENSE_TOP_K,
                    QURAN_SOURCE_TYPES, HADITH_SOURCE_TYPES, SCOPE_QURAN, SCOPE_HADITH, SCOPE_ALL,)

logger= logging.getLogger(__name__)

# holds everything after load_faiss_index() runs
index_state: dict= {"index": None,   # faiss.Index
                    "scoped": {},   # scope -> (faiss.Index over that scope's rows only, row -> global row)
                    "id_to_idx": None,   # chunk_id -> row index in the matrix
                    "idx_to_id": None,   # row index -> chunk_id
                    "corpus_map": None,   # chunk_id -> full chunk dict
                    "loaded": False,}


def load_faiss_index(corpus_map: dict) -> None:
    """Load semantic_vectors.npy into a FAISS flat inner-product index. """
    if index_state["loaded"]:
        logger.warning("FAISS index already loaded -> skipping.")
        return

    logger.info(f"Loading vectors from '{VECTOR_FILE}' ...")
    vectors= np.load(str(VECTOR_FILE)).astype("float32")
    n_vectors, dimension= vectors.shape
    logger.info(f"  {n_vectors:,} vectors, dimension={dimension}")

    if dimension != EMBEDDING_DIMENSION:
        raise RuntimeError(f"Vector dimension mismatch: file has {dimension}, config expects {EMBEDDING_DIMENSION}. "
            "Re-run vectorisation or fix config.py.")

    if n_vectors != len(corpus_map):
        raise RuntimeError(f"Vector count ({n_vectors:,}) != corpus_map size ({len(corpus_map):,}). "
            "Re-run vectorisation to regenerate both files together.")

    logger.info("Building FAISS IndexFlatIP ...")
    index= faiss.IndexFlatIP(dimension)
    index.add(vectors)
    logger.info(f"  {index.ntotal:,} vectors indexed.")

    chunk_ids= list(corpus_map.keys())

    # one exact sub-index per scope. Filtering a global top-k afterwards loses most of the
    # in-scope hits whenever the other corpus dominates the neighbourhood (e.g. "الصلاه" with
    # scope=quran kept 45 of 100 requested ayahs because prayer hadiths filled the top 400).
    for scope_name in (SCOPE_QURAN, SCOPE_HADITH):
        allowed= scope_to_types(scope_name)
        rows= np.array([i for i, cid in enumerate(chunk_ids) if corpus_map[cid].get("source_type") in allowed], dtype="int64")
        sub= faiss.IndexFlatIP(dimension)
        if len(rows):
            sub.add(vectors[rows])
        index_state["scoped"][scope_name]= (sub, rows)
        logger.info(f"  scope '{scope_name}': {sub.ntotal:,} vectors")

    index_state["index"]= index
    index_state["idx_to_id"]= chunk_ids
    index_state["id_to_idx"]= {cid: i for i, cid in enumerate(chunk_ids)}
    index_state["corpus_map"]= corpus_map
    index_state["loaded"]= True

    logger.info("FAISS index ready.")


def search(query_vector: np.ndarray, scope: str= SCOPE_ALL, top_k: int= DENSE_TOP_K,) -> list[dict]:
    """Dense nearest-neighbour search.

    query_vector should be L2-normalised float32 of shape (EMBEDDING_DIMENSION,).
    A narrow scope searches that scope's own sub-index, so top_k in-scope hits are always returned.
    Returns list of {chunk_id, source_type, score, rank} sorted by score desc.
    """
    check_loaded()
    query= query_vector.reshape(1, -1).astype("float32")

    scoped= index_state["scoped"].get(scope)
    if scoped is not None:
        sub_index, row_map= scoped
        scores, indices= sub_index.search(query, min(top_k, sub_index.ntotal))
        indices= np.where(indices[0] >= 0, row_map[np.maximum(indices[0], 0)], -1)
    else:
        scores, indices= index_state["index"].search(query, top_k)
        indices= indices[0]
    scores= scores[0]

    results= []

    for score, idx in zip(scores, indices):
        if idx == -1:
            continue
        chunk_id= index_state["idx_to_id"][idx]
        chunk= index_state["corpus_map"][chunk_id]

        results.append({"chunk_id": chunk_id,
                        "source_type": chunk.get("source_type"),
                        "score": float(score),})

        if len(results) >= top_k:
            break

    for rank, r in enumerate(results, start=1):
        r["rank"]= rank

    logger.debug(f"FAISS | scope={scope} top_k={top_k} hits={len(results)}")
    return results


def get_chunk(chunk_id: str) -> dict | None:
    """Fetch a single chunk by ID. Returns None if not found."""
    check_loaded()
    return index_state["corpus_map"].get(chunk_id)


def get_chunks_by_ids(chunk_ids: list[str]) -> list[dict]:
    """Bulk fetch chunks. Missing IDs are silently skipped, order preserved."""
    check_loaded()
    return [index_state["corpus_map"][cid] for cid in chunk_ids if cid in index_state["corpus_map"]]


def scope_to_types(scope: str) -> set[str] | None:
    if scope == SCOPE_QURAN:
        return QURAN_SOURCE_TYPES
    if scope == SCOPE_HADITH:
        return HADITH_SOURCE_TYPES
    return None


def check_loaded() -> None:
    if not index_state["loaded"]:
        raise RuntimeError("FAISS index not loaded. Call load_faiss_index() at startup.")


def is_loaded() -> bool:
    return index_state["loaded"]


def index_stats() -> dict:
    if not index_state["loaded"]:
        return {"loaded": False}
    return {"loaded": True,
            "total_vectors": index_state["index"].ntotal,
            "dimension": EMBEDDING_DIMENSION,}
