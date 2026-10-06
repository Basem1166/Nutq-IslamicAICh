"""
FastAPI entry point.

sequence (lifespan):
  1. Load corpus_map.json -> shared dict used by all modules
  2. Load FAISS index     -> dense retrieval
  3. Load BM25 index      -> sparse retrieval (builds pickle on first run)
  4. Load classifier data -> alias map, transliteration table, surah index
  5. Load ML models       -> embedding model + reranker onto GPU/CPU

Endpoints:
  POST /v1/search              -> main search
  GET  /v1/chunk/{chunk_id}    -> fetch single chunk by ID
  GET  /v1/health              -> server + model status
"""
import os
# Force Hugging Face to avoid saving heavy local cache copies
os.environ["HF_DATASETS_CACHE"] = "RAM"
os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"

# Prevent PyArrow from using heavy multi-threaded allocations
os.environ["ARROW_DEFAULT_MEMORY_POOL"] = "system"

import json
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, field_validator

from config import (
    CORPUS_MAP_FILE, API_DEFAULT_TOP_K, API_MAX_TOP_K, API_VERSION,
    SCOPE_ALL, SCOPE_QURAN, SCOPE_HADITH,
)
from indexes import faiss_index, bm25_index
from models.loader import load_models, unload_models, is_loaded
from search import classifier
from search.pipeline import SearchRequest, search as run_search

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
)
logger = logging.getLogger(__name__)
class ListHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records: list[str] = []

    def emit(self, record):
        self.records.append(self.format(record))
        
@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Startup: load everything into memory in the right order.
    Shutdown: release GPU memory cleanly.
    """
    logger.info("=" * 60)
    logger.info("Islamic Search Engine starting up ...")
    logger.info("=" * 60)

    t0 = time.perf_counter()

    # ── 1. Load corpus map ────────────────────────────────────────────────────
    # corpus_map.json is a list from vectorization; convert to ordered dict
    # keyed by chunk_id so all modules can do O(1) lookup by ID.
    logger.info(f"Loading corpus map from '{CORPUS_MAP_FILE}' ...")
    with open(CORPUS_MAP_FILE, "r", encoding="utf-8") as f:
        raw = json.load(f)

    if isinstance(raw, list):
        corpus_map = {chunk["chunk_id"]: chunk for chunk in raw}
    else:
        corpus_map = raw   # already a dict

    logger.info(f"  Corpus map loaded — {len(corpus_map):,} chunks.")

    # 2. FAISS index
    faiss_index.load_faiss_index(corpus_map)

    # 3. BM25 index
    bm25_index.load_bm25_index(corpus_map)

    # 4. Classifier data
    classifier.load_classifier_data(corpus_map)

    # 5. ML models
    load_models()

    elapsed = time.perf_counter() - t0
    logger.info("=" * 60)
    logger.info(f"Startup complete in {elapsed:.1f}s — ready to serve requests.")
    logger.info("=" * 60)

    # server runs here
    yield

    # Shutdown
    logger.info("Shutting down ...")
    unload_models()
    logger.info("Shutdown complete.")


# App
app = FastAPI(
    title="Nutq Semantic Search",
    description="Semantic search over Quran and Hadith —> dense + BM25 + reranker.",
    version=API_VERSION,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# Request / Response schemas

class SearchFilters(BaseModel):
    scope: str | None = Field(
        default=None,
        description="Restrict corpus: 'quran' | 'hadith' | null (auto-detect)",
    )

    @field_validator("scope")
    @classmethod
    def validate_scope(cls, v):
        if v is not None and v not in (SCOPE_QURAN, SCOPE_HADITH, SCOPE_ALL):
            raise ValueError(f"scope must be 'quran', 'hadith', 'all', or null")
        return v


class SearchRequestSchema(BaseModel):
    query: str = Field(
        ...,
        min_length=1,
        max_length=500,
        description="Search query in Arabic, English, or transliteration",
        examples=["hadith about treating parents well", "آية الكرسي", "2:255"],
    )
    top_k: int = Field(
        default=API_DEFAULT_TOP_K,
        ge=1,
        le=API_MAX_TOP_K,
        description=f"Number of results to return (1-{API_MAX_TOP_K})",
    )
    filters: SearchFilters = Field(default_factory=SearchFilters)


class SearchResponseSchema(BaseModel):
    query_meta: dict
    results:    list[dict]
    latency_ms: float
    error:      str | None = None
    debug_log:  list[str] = Field(default_factory=list)

# Routes

@app.post(f"/{API_VERSION}/search", response_model=SearchResponseSchema)
def search_endpoint(body: SearchRequestSchema):
    request = SearchRequest(
        query=body.query.strip(),
        top_k=body.top_k,
        scope=body.filters.scope,
    )

    # Capture all debug logs for this request
    handler = ListHandler()
    handler.setLevel(logging.DEBUG)
    handler.setFormatter(logging.Formatter("%(name)s | %(levelname)s | %(message)s"))
    root_logger = logging.getLogger()
    root_logger.addHandler(handler)
    root_logger.setLevel(logging.DEBUG)

    try:
        response = run_search(request)
    finally:
        root_logger.removeHandler(handler)  # always clean up

    if response.error:
        raise HTTPException(status_code=500, detail=f"Search pipeline error: {response.error}")

    return SearchResponseSchema(
        query_meta=response.query_meta,
        results=response.results,
        latency_ms=response.latency_ms,
        debug_log=handler.records,
    )

@app.get(
    f"/{API_VERSION}/chunk/{{chunk_id}}",
    summary="Fetch a single chunk by ID",
)
async def get_chunk_endpoint(chunk_id: str):
    """
    Retrieve a single chunk's full metadata by chunk_id.

    chunk_id formats:
      Q_{surah}:{ayah}             individual ayah
      QP_{surah}:{start}-{end}_w{n} passage chunk
      H_{edition}_{number}         individual hadith
      HC_{book}_ch{chapter}        hadith cluster
    """
    chunk = faiss_index.get_chunk(chunk_id)
    if chunk is None:
        raise HTTPException(
            status_code=404,
            detail=f"Chunk '{chunk_id}' not found in corpus.",
        )

    from search.reranker import format_chunk
    return format_chunk(chunk)


@app.get(
    f"/{API_VERSION}/health",
    summary="Server and model health check",
)
async def health_endpoint():
    """
    Returns model load status and index stats.
    """
    from search.reranker import cache_stats
    return {
        "status":   "ok" if is_loaded() else "loading",
        "models": {
            "embedding_model": is_loaded(),
            "reranker":        is_loaded(),
        },
        "indexes": {
            "faiss": faiss_index.index_stats(),
            "bm25":  bm25_index.index_stats(),
        },
        "cache": cache_stats(),
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
        workers=1,
        log_level="info",
    )