# Nutq Semantic Search — API Reference
> Base URL: `http://localhost:8000/v1`  
> All requests and responses are JSON. No authentication required.

---

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/search` | Run a semantic search query |
| `GET` | `/v1/chunk/{chunk_id}` | Fetch a single chunk by its ID |
| `GET` | `/v1/health` | Server and model status |

---

## POST `/v1/search`

The main search endpoint. Accepts a query string (Arabic, English, or transliterated Islamic terms), returns ranked results from the Quran and Hadith corpus.

### Request Body

```json
{
  "query":   "string",
  "top_k":   5,
  "filters": {
    "scope": null
  }
}
```

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `query` | `string` | ✅ Yes | — | The search query. 1–500 characters. Arabic, English, or transliteration (e.g. `"sabr"`, `"2:255"`, `"آية الكرسي"`). |
| `top_k` | `integer` | No | `5` | How many results to return. Min `1`, max `20`. |
| `filters.scope` | `string \| null` | No | `null` | Restrict the corpus. One of `"quran"`, `"hadith"`, or `null` (auto-detect). |

#### Request Examples

**Minimal request (auto-detect everything):**
```json
{
  "query": "patience in hardship"
}
```

**With scope and custom result count:**
```json
{
  "query":   "حكم الزكاة وشروطها",
  "top_k":   10,
  "filters": { "scope": "hadith" }
}
```

**Direct reference (returns the exact ayah):**
```json
{
  "query":   "2:255",
  "top_k":   1,
  "filters": { "scope": "quran" }
}
```

---

### Response Body

```json
{
  "query_meta": { ... },
  "results":    [ ... ],
  "latency_ms": 420.5,
  "error":      null,
  "debug_log":  [ ... ]
}
```

| Field | Type | Description |
|---|---|---|
| `query_meta` | `object` | Classification and pipeline metadata for this query. |
| `results` | `array` | Ranked list of matching chunks. |
| `latency_ms` | `float` | Total server-side latency in milliseconds. |
| `error` | `string \| null` | Non-null if the pipeline threw an exception. |
| `debug_log` | `array[string]` | Raw server log lines captured during this request. Useful for debugging; can be ignored in production UI. |

---

### `query_meta` Object

Contains everything the classifier and pipeline decided about the query.

```json
{
  "original_query":         "patience in hardship",
  "normalized_query":       "patience in hardship صبر",
  "detected_language":      "english",
  "query_type":             "thematic",
  "scope":                  "quran",
  "early_exit":             false,
  "lexical_query":          "patience in hardship صبر",
  "arabic_supplement":      "صبر",
  "reranker_query":         "patience in hardship صبر",
  "bm25_query_sent":        "patience in hardship صبر",
  "bm25_tokens":            ["patience", "hardship", "صبر"],
  "fusion_candidate_count": 28,
  "pre_rerank_top5":        [ ... ],
  "stage_timings_ms": {
    "classify_ms":  3.1,
    "retrieve_ms":  85.2,
    "fuse_ms":      12.0,
    "rerank_ms":    310.4,
    "total_ms":     420.5,
    "dense_hits":   100,
    "bm25_hits":    87
  },
  "comparative_concepts":   null,
  "classifier_debug":       { ... }
}
```

| Field | Type | Description |
|---|---|---|
| `original_query` | `string` | The query exactly as submitted. |
| `normalized_query` | `string` | Query after transliteration expansion and connector stripping. May differ from `original_query` (e.g. `"sabr"` → `"صبر"`). |
| `detected_language` | `string` | `"arabic"`, `"english"`, or `"mixed"`. |
| `query_type` | `string` | One of `"thematic"`, `"fiqh"`, `"narrative"`, `"definitional"`, `"arabic_keyword"`, `"comparative"`, `"direct_reference"`, `"named_concept"`. Drives which retrieval strategy was used. |
| `scope` | `string` | The effective corpus scope used: `"quran"`, `"hadith"`, or `"all"`. May differ from `filters.scope` when auto-detected. |
| `early_exit` | `boolean` | `true` if the result came from a direct chunk lookup (no retrieval pipeline ran). This happens for queries like `"2:255"` or `"Ayat al-Kursi"`. |
| `lexical_query` | `string` | The query string sent to BM25. |
| `arabic_supplement` | `string` | Arabic keywords appended to help cross-lingual dense retrieval (English queries only). Empty string if not applicable. |
| `reranker_query` | `string` | The exact string sent to the cross-encoder. Usually the same as `normalized_query`. |
| `bm25_query_sent` | `string` | The exact query string sent to the BM25 index. |
| `bm25_tokens` | `array[string]` | Tokenized + stemmed form of `bm25_query_sent`. What BM25 actually matched against. |
| `fusion_candidate_count` | `integer` | Number of candidates after fusion, before reranking. |
| `pre_rerank_top5` | `array[object]` | Top 5 fusion candidates before the reranker ran. Each has `chunk_id`, `source_type`, `rrf_score`, `dense_rank`, `bm25_rank`. Useful for debugging retrieval quality. |
| `stage_timings_ms` | `object` | Per-stage latency breakdown. See fields: `classify_ms`, `retrieve_ms`, `fuse_ms`, `rerank_ms`, `total_ms`, `dense_hits`, `bm25_hits`. |
| `comparative_concepts` | `array[string] \| null` | For `query_type = "comparative"` only: the two concept arms the query was split into, e.g. `["الزكاة", "الصدقة"]`. |
| `classifier_debug` | `object` | Step-by-step decision trail from the classifier. Useful for diagnosing unexpected `query_type` or `scope` values. |

---

### `results` Array

Each element is a ranked result chunk. The shape of the inner `chunk` object depends on `source_type`.

```json
[
  {
    "chunk_id":       "Q_2:255",
    "source_type":    "Quran_Tafsir",
    "final_rank":     1,
    "reranker_score": 0.9341,
    "rrf_score":      0.01234,
    "dense_rank":     3,
    "bm25_rank":      1,
    "chunk":          { ... },
    "note":           "(optional string)",
    "comparative_concept": "(optional string)"
  }
]
```

| Field | Type | Description |
|---|---|---|
| `chunk_id` | `string` | Unique identifier for this chunk. Format depends on `source_type` (see below). |
| `source_type` | `string` | One of `"Quran_Tafsir"`, `"Quran_Passage"`, `"Hadith"`, `"Hadith_Cluster"`. |
| `final_rank` | `integer` | 1-based rank in the result list. `1` is the best match. |
| `reranker_score` | `float` | Cross-encoder confidence score. Range roughly `0.0–1.0`. Higher is better. Scores above `0.4` are strong matches; below `0.15` are weak. |
| `rrf_score` | `float` | Reciprocal rank fusion score before reranking. Smaller numbers. Not directly interpretable by users — use `reranker_score` for display. |
| `dense_rank` | `integer \| null` | This chunk's rank in the dense (semantic) retrieval results. `null` if it came from BM25 only. |
| `bm25_rank` | `integer \| null` | This chunk's rank in the BM25 (keyword) retrieval results. `null` if it came from dense only. |
| `chunk` | `object` | The actual content. Shape varies by `source_type` — see below. |
| `note` | `string` | *(Optional)* Present when a surah-name-only query was given (e.g. `"Surah Al-Fatiha"`). Tells the user to add an ayah number for a specific verse. |
| `comparative_concept` | `string` | *(Optional)* For comparative queries only. Which concept arm this result belongs to (e.g. `"الزكاة"` or `"الصدقة"`). |

---

### `chunk` Object Shapes by `source_type`

#### `Quran_Tafsir` — a single ayah

```json
{
  "chunk_id":            "Q_2:255",
  "source_type":         "Quran_Tafsir",
  "surah_id":            2,
  "ayah_id":             255,
  "arabic_text":         "اللَّهُ لَا إِلَٰهَ إِلَّا هُوَ ...",
  "english_translation": "Allah — there is no deity except Him ...",
  "arabic_tafsir":       "قوله تعالى: الله لا إله إلا هو ..."
}
```

| Field | Type | Description |
|---|---|---|
| `chunk_id` | `string` | Format: `Q_{surah}:{ayah}` e.g. `"Q_2:255"` |
| `surah_id` | `integer` | Surah number (1–114). |
| `ayah_id` | `integer` | Ayah number within the surah. |
| `arabic_text` | `string` | The ayah text in Arabic. |
| `english_translation` | `string` | English translation of the ayah. |
| `arabic_tafsir` | `string` | Arabic commentary/explanation of the ayah. |

---

#### `Quran_Passage` — a multi-ayah window

Returned for thematic/narrative queries where a span of consecutive ayahs is more relevant than a single one.

```json
{
  "chunk_id":            "QP_2:183-187_w6",
  "source_type":         "Quran_Passage",
  "surah_id":            2,
  "start_ayah":          183,
  "end_ayah":            187,
  "ayah_count":          5,
  "window_size":         6,
  "arabic_text":         "يَا أَيُّهَا الَّذِينَ آمَنُوا ...",
  "english_translation": "O you who have believed ...",
  "arabic_tafsir":       "...",
  "members": [
    {
      "chunk_id":            "Q_2:183",
      "ayah_id":             183,
      "arabic_text":         "يَا أَيُّهَا الَّذِينَ آمَنُوا ...",
      "english_translation": "O you who have believed, decreed upon you is fasting ..."
    },
    ...
  ]
}
```

| Field | Type | Description |
|---|---|---|
| `chunk_id` | `string` | Format: `QP_{surah}:{start}-{end}_w{window}` e.g. `"QP_2:183-187_w6"` |
| `surah_id` | `integer` | Surah number. |
| `start_ayah` | `integer` | First ayah number in the window. |
| `end_ayah` | `integer` | Last ayah number in the window. |
| `ayah_count` | `integer` | Number of ayahs in this passage. |
| `window_size` | `integer` | The passage scale this was indexed at (3, 6, 12, 20, or 40). |
| `arabic_text` | `string` | All ayahs concatenated in Arabic. |
| `english_translation` | `string` | All ayahs concatenated in English. |
| `arabic_tafsir` | `string` | Combined tafsir for the window. |
| `members` | `array` | Individual ayahs in the window. Each member has `chunk_id`, `ayah_id`, `arabic_text`, `english_translation`. Use this array to render each ayah separately. |

---

#### `Hadith` — a single hadith

```json
{
  "chunk_id":     "H_bukhari_6982",
  "source_type":  "Hadith",
  "book_name":    "Sahih al-Bukhari",
  "chapter_id":   "73",
  "hadith_id":    "6982",
  "arabic_text":  "حَدَّثَنَا أَبُو الْيَمَانِ ...",
  "english_text": "Narrated Abu Huraira: The Prophet said ..."
}
```

| Field | Type | Description |
|---|---|---|
| `chunk_id` | `string` | Format: `H_{edition}_{number}` e.g. `"H_bukhari_6982"` |
| `book_name` | `string` | Full name of the hadith collection (e.g. `"Sahih al-Bukhari"`, `"Sahih Muslim"`). |
| `chapter_id` | `string` | Chapter identifier within the book. |
| `hadith_id` | `string` | The hadith number within the book. |
| `arabic_text` | `string` | Full Arabic text including isnad (narrator chain) and matn. |
| `english_text` | `string` | Full English translation including narrator attribution. |

---

#### `Hadith_Cluster` — a group of hadiths from the same chapter

Returned when several hadiths from the same chapter are collectively more relevant than any single one. Useful for thematic/definitional queries.

```json
{
  "chunk_id":     "HC_bukhari_ch73",
  "source_type":  "Hadith_Cluster",
  "book_name":    "Sahih al-Bukhari",
  "chapter_id":   "73",
  "hadith_count": 8,
  "members": [
    {
      "chunk_id":     "H_bukhari_6011",
      "hadith_id":    "6011",
      "arabic_text":  "...",
      "english_text": "Narrated Abu Huraira: ..."
    },
    ...
  ]
}
```

| Field | Type | Description |
|---|---|---|
| `chunk_id` | `string` | Format: `HC_{book}_ch{chapter}` e.g. `"HC_bukhari_ch73"` |
| `book_name` | `string` | Full name of the hadith collection. |
| `chapter_id` | `string` | Chapter identifier. |
| `hadith_count` | `integer` | Total hadiths in this chapter group. |
| `members` | `array` | Individual hadiths in the cluster. Each has `chunk_id`, `hadith_id`, `arabic_text`, `english_text`. Render the first few if you want a preview. |

---

### `chunk_id` Format Reference

| Format | Source Type | Example |
|---|---|---|
| `Q_{surah}:{ayah}` | `Quran_Tafsir` | `Q_2:255` |
| `QP_{surah}:{start}-{end}_w{n}` | `Quran_Passage` | `QP_2:183-187_w6` |
| `H_{edition}_{number}` | `Hadith` | `H_bukhari_6982` |
| `HC_{book}_ch{chapter}` | `Hadith_Cluster` | `HC_bukhari_ch73` |

---

### Full Response Example

```json
{
  "query_meta": {
    "original_query":         "2:255",
    "normalized_query":       "2:255",
    "detected_language":      "english",
    "query_type":             "direct_reference",
    "scope":                  "quran",
    "early_exit":             true,
    "lexical_query":          "2:255",
    "arabic_supplement":      "",
    "fusion_candidate_count": null,
    "stage_timings_ms":       {}
  },
  "results": [
    {
      "chunk_id":       "Q_2:255",
      "source_type":    "Quran_Tafsir",
      "final_rank":     1,
      "reranker_score": 1.0,
      "rrf_score":      1.0,
      "dense_rank":     null,
      "bm25_rank":      null,
      "chunk": {
        "chunk_id":            "Q_2:255",
        "source_type":         "Quran_Tafsir",
        "surah_id":            2,
        "ayah_id":             255,
        "arabic_text":         "اللَّهُ لَا إِلَٰهَ إِلَّا هُوَ الْحَيُّ الْقَيُّومُ ...",
        "english_translation": "Allah — there is no deity except Him, the Ever-Living ...",
        "arabic_tafsir":       "..."
      }
    }
  ],
  "latency_ms": 4.2,
  "error":      null,
  "debug_log":  []
}
```

---

## GET `/v1/chunk/{chunk_id}`

Fetch the full metadata for a single chunk by its ID. Use this to load a specific ayah or hadith directly without running a search query.

### Path Parameter

| Parameter | Type | Description |
|---|---|---|
| `chunk_id` | `string` | A valid chunk ID. See the format table above. |

### Request Example

```
GET /v1/chunk/Q_2:255
GET /v1/chunk/H_bukhari_6982
GET /v1/chunk/QP_2:183-187_w6
```

### Response

Returns a single `chunk` object in the same shape as described in the search results above. The outer result wrapper (`chunk_id`, `source_type`, `reranker_score`, etc.) is **not** included — only the chunk content itself is returned.

```json
{
  "chunk_id":            "Q_2:255",
  "source_type":         "Quran_Tafsir",
  "surah_id":            2,
  "ayah_id":             255,
  "arabic_text":         "اللَّهُ لَا إِلَٰهَ إِلَّا هُوَ ...",
  "english_translation": "Allah — there is no deity except Him ...",
  "arabic_tafsir":       "..."
}
```

### Error Response

If the `chunk_id` does not exist:

```json
{
  "detail": "Chunk 'Q_2:999' not found in corpus."
}
```

HTTP status: `404`

---

## GET `/v1/health`

Returns the server status and index statistics. Use this to confirm the server is fully loaded before sending search queries. Call it once on app startup.

### Response

```json
{
  "status": "ok",
  "models": {
    "embedding_model": true,
    "reranker":        true
  },
  "indexes": {
    "faiss": {
      "loaded":        true,
      "total_vectors": 284530,
      "dimension":     1024
    },
    "bm25": {
      "loaded":          true,
      "documents":       284530,
      "k1":              1.5,
      "b":               0.65,
      "synonyms_loaded": true,
      "synonym_entries": 1842
    }
  },
  "cache": {
    "size":     12,
    "max":      128,
    "hits":     47,
    "misses":   61,
    "hit_rate": 0.435
  }
}
```

| Field | Type | Description |
|---|---|---|
| `status` | `string` | `"ok"` when models and indexes are fully loaded. `"loading"` during startup. |
| `models.embedding_model` | `boolean` | Whether the sentence-embedding model is loaded. |
| `models.reranker` | `boolean` | Whether the cross-encoder reranker is loaded. |
| `indexes.faiss.loaded` | `boolean` | Whether the FAISS vector index is ready. |
| `indexes.faiss.total_vectors` | `integer` | Number of vectors in the index (= total chunks). |
| `indexes.faiss.dimension` | `integer` | Embedding dimension (always `1024`). |
| `indexes.bm25.loaded` | `boolean` | Whether the BM25 index is ready. |
| `indexes.bm25.documents` | `integer` | Number of indexed documents. |
| `indexes.bm25.synonyms_loaded` | `boolean` | Whether the optional synonym expansion index is loaded. |
| `cache.size` | `integer` | Number of cached reranker results. |
| `cache.max` | `integer` | Cache capacity (128 entries). |
| `cache.hit_rate` | `float` | Reranker cache hit rate since server start. |

---

## Error Handling

| HTTP Status | When it happens |
|---|---|
| `422 Unprocessable Entity` | Request body failed validation (e.g. `query` is empty, `top_k` out of range, invalid `scope` value). The response body will include a `detail` field describing which field failed and why. |
| `404 Not Found` | `chunk_id` passed to `/chunk/{chunk_id}` does not exist in the corpus. |
| `500 Internal Server Error` | The search pipeline threw an unexpected exception. The `error` field in the response body will contain the exception message. |

### Validation Error Example

```json
{
  "detail": [
    {
      "type":  "string_too_short",
      "loc":   ["body", "query"],
      "msg":   "String should have at least 1 character",
      "input": ""
    }
  ]
}
```

---

## Notes for Frontend Integration

**1. Server warmup.** The server takes ~30–60 seconds to start (loading models and indexes into GPU memory). Call `GET /v1/health` on app launch and wait for `status = "ok"` before enabling the search UI.

**2. `scope` defaults to null (auto-detect).** The server will figure out the right corpus automatically based on the query. Only set `scope` if the user explicitly wants to filter — e.g. if you have a "Quran only" toggle in your UI.

**3. `early_exit = true` means instant results.** Queries like `"2:255"` or `"Ayat al-Kursi"` resolve in under 5ms via direct lookup. When `early_exit` is `true`, `reranker_score` will always be `1.0` and `dense_rank` / `bm25_rank` will both be `null`.

**4. Rendering passages vs single ayahs.** When `source_type = "Quran_Passage"`, iterate over `chunk.members` to render each ayah individually with its number. The top-level `arabic_text` and `english_translation` fields are the concatenation of all members — useful for a collapsed preview.

**5. Rendering Hadith_Cluster.** Show the first 1–3 members as a preview. The `hadith_count` field tells the user how many hadiths are in the full group. Optionally add a "see all" link that calls `GET /v1/chunk/{chunk_id}` for the full cluster.

**6. `debug_log` is verbose.** It contains every server-side log line for the request. Strip it or collapse it in the UI — it's intended for developers, not end users.

**7. Latency expectations.**

| Query type | Typical latency |
|---|---|
| `direct_reference` / `named_concept` (early exit) | < 10ms |
| `arabic_keyword` | 200–500ms |
| `thematic` / `fiqh` / `definitional` | 400–900ms |
| `narrative` | 600–1200ms |
| `comparative` | 1000–2500ms |

Latencies above are on a machine with a GPU. On CPU they are 3–5× slower.
