# Nutq Search Engine

Bilingual (Arabic / English) semantic search over the Quran and Hadith, served as a FastAPI service.

- **Corpus:** 6,236 ayahs + 9,129 Quran passage windows (3 / 6 / 12 ayahs) with tafsir al-Muyassar and the
  Saheeh International translation; 22,117 hadiths from Sahih al-Bukhari, Sahih Muslim, Sunan Abu Dawood and
  Jami' at-Tirmidhi (Arabic matn + English, with gradings).
- **Pipeline:** classify the query (language, type, scope, direct references such as `2:255` or
  `Bukhari 1`) → dense retrieval (`intfloat/multilingual-e5-large-instruct` + FAISS) and BM25 →
  weighted RRF fusion → cross-encoder rerank (`BAAI/bge-reranker-v2-m3` + `Qwen/Qwen3-Reranker-0.6B`)
  → score floor, de-duplication, source balance.
- **Query understanding:** transliterations and spelling variants (`sabr`, `zakaat`, `Ebrahim`,
  `namaz`, `al-bakara` → Arabic), person and topic glosses (`أحمد`, `غزوة بدر`, `الحجاب`).

---

## 1. Requirements

| | Minimum | Recommended |
|---|---|---|
| Python | 3.11 | 3.11 – 3.14 |
| RAM | 16 GB | 32 GB (the server holds three models + the indexes, ~10 GB) |
| Disk | ~15 GB | models (~4.5 GB in the Hugging Face cache) + `assets/` (~0.5 GB) + OpenVINO exports (~9 GB, only with OpenVINO) |
| Accelerator | none (CPU works, slowly) | NVIDIA GPU (CUDA) **or** an Intel CPU / iGPU with OpenVINO |

Internet access is needed on the first start (model downloads from Hugging Face) and for the data
download scripts.

---

## 2. Install

```bash
cd SearchEngine
python -m venv .venv-ov

# Windows (PowerShell):  .venv-ov\Scripts\Activate.ps1
# Windows (Git Bash):    source .venv-ov/Scripts/activate
# Linux / macOS:         source .venv-ov/bin/activate

python -m pip install --upgrade pip
pip install -r requirements.txt
```

Then pick **one** of the accelerators:

- **NVIDIA GPU (CUDA):** install the CUDA build of PyTorch, e.g.
  `pip install torch --index-url https://download.pytorch.org/whl/cu124`
  (match the CUDA version of your driver). The engine detects CUDA automatically and runs in fp16.
- **Intel CPU / iGPU (OpenVINO):** `pip install -r requirements-openvino.txt`.
  `config.py` → `OPENVINO_DEVICE` selects `"GPU"` (Intel iGPU, default), `"CPU"` or `"AUTO"`.
  Without these packages the engine logs a warning and falls back to plain PyTorch.

Optional: `huggingface-cli login` (or set `HF_TOKEN`) avoids Hugging Face rate limits on the first download.

---

## 3. Data

The server needs these files in `SearchEngine/assets/` (not in git - see `.gitignore`):

| File | What it is |
|---|---|
| `assets/corpus_map.json` | every searchable chunk (ayahs, passages, hadiths) with its texts and metadata |
| `assets/semantic_vectors.npy` | e5 embedding of each chunk, same order as `corpus_map.json` |
| `assets/bm25_index.pkl` | BM25 index - **built automatically** on the first start if missing |

and these in `SearchEngine/data/` (in git): `alias_map.json`, `transliteration.json`,
`transliteration_variants.json`, `synonym_index.json`.

### Option A - copy the prebuilt assets (fastest)

Get `corpus_map.json` and `semantic_vectors.npy` from a teammate / the shared drive / the Kaggle run
output, put them in `assets/`, and delete any old `assets/bm25_index.pkl`. Go to step 4.

### Option B - build everything from the sources

Run from the `SearchEngine/` folder, in this order:

```bash
# 1. Hadith: downloads Bukhari, Muslim, Abu Dawood, Tirmidhi (Arabic + English) from the
#    fawazahmed0/hadith-api GitHub mirror          -> hadith_semantic_chunks.json
python hadith.py

# 2. Quran: Uthmani + simple (imla'i) text, Saheeh International, tafsir al-Muyassar
#    from api.alquran.cloud                        -> quran_and_tafsir_data.json
python quran-with-tafser.py

# 3. Merge + Arabic normalisation                 -> master_semantic_corpus_normalized.json
python normalize_data_chuncks.py

# 4. Chunking (passage windows, hadith matn extraction) + e5 embeddings
#                                                  -> semantic_vectors.npy, corpus_map.json
python vectorize_and_index.py
```

Step 4 embeds ~37k chunks with a 560M-parameter model: **use a GPU** (a free Kaggle / Colab GPU is
enough; a laptop CPU took ~77 min per 6k chunks, i.e. many hours). It saves a checkpoint
every 500 batches (`semantic_vectors_checkpoint.npy`) and resumes from it if interrupted. On Kaggle,
upload `master_semantic_corpus_normalized.json` + `vectorize_and_index.py`, run it, and download the two
outputs.

Then move the outputs into place and drop the stale BM25 index:

```bash
mkdir -p assets
mv semantic_vectors.npy corpus_map.json assets/
rm -f assets/bm25_index.pkl        # rebuilt automatically on the next start
```

> **Whenever `corpus_map.json` changes, re-embed (`semantic_vectors.npy` must match it row for row)
> and delete `assets/bm25_index.pkl`.**

### Optional data tools

```bash
# after editing data/transliteration.json: regenerate the spelling variants (needs assets/corpus_map.json)
python build_transliteration_variants.py

# rebuild data/synonym_index.json (embedding-based Arabic synonyms for BM25 expansion)
python build_synonym_index_file.py

# check that every alias in data/alias_map.json points at an existing chunk
python verify_alias_map.py
```

---

## 4. Run the server

```bash
python main.py
# or, equivalently:
uvicorn main:app --host 0.0.0.0 --port 8000
```

The first start downloads the three models from Hugging Face and, with OpenVINO, exports them once to
`assets/openvino/` (a one-time step of several minutes; the Qwen3 reranker is exported with int8 weights).
Later starts load the exported copies. Wait for `Startup complete ... ready to serve requests.`

Interactive API docs: <http://localhost:8000/docs>

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/search` | search |
| `GET` | `/v1/chunk/{chunk_id}` | one chunk by id (e.g. `Q_2:255`, `H_eng-bukhari_1`) |
| `GET` | `/v1/health` | models / index status |

```bash
curl -X POST http://localhost:8000/v1/search \
     -H "Content-Type: application/json" \
     -d '{"query": "ما هو جزاء الصبر", "top_k": 5, "filters": {"scope": null}}'
```

PowerShell:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8000/v1/search -ContentType "application/json" `
  -Body '{"query": "patience during hardship", "top_k": 5}'
```

- `top_k`: 1-20 (default 5). Fewer results can come back: weak matches below the relevance floor are dropped.
- `filters.scope`: `"quran"`, `"hadith"` or `null` (auto-detect from the query).

---

## 5. Configuration

Everything is in `config.py`. The main switches can also be set as environment variables:

| Variable | Default | Effect |
|---|---|---|
| `NUTQ_RERANKER_MODEL` | `BAAI/bge-reranker-v2-m3` | primary cross-encoder |
| `NUTQ_RERANKER_ENSEMBLE` | `Qwen/Qwen3-Reranker-0.6B` | second reranker; set to an empty string to disable (faster, slightly less precise) |
| `NUTQ_RERANKER_ENSEMBLE_WEIGHT` | `0.15` | weight of the second reranker on hadith candidates |
| `NUTQ_RERANKER_ENSEMBLE_WEIGHT_QURAN` | `0.5` | weight of the second reranker on Quran candidates |
| `NUTQ_TOPIC_GLOSSES` | `1` | event / concept / person glosses (`0` disables) |
| `NUTQ_FUSION_GUARANTEE` | `10` | top-N of dense and of BM25 always reach the reranker |
| `NUTQ_TAFSIR_CHARS` | `200` | tafsir characters shown to the reranker per ayah |

In `config.py` only: `INFERENCE_BACKEND` (`"openvino"` / `"torch"`), `OPENVINO_DEVICE`,
`RERANKER_OPENVINO_INT8`, `RERANK_CANDIDATE_CAP`, `MIN_RESULT_REL_SCORE`.

On a strong GPU, `NUTQ_RERANKER_ENSEMBLE=Qwen/Qwen3-Reranker-4B` is a drop-in upgrade (re-check with the
evaluation below before switching).

Examples:

```bash
# bash
NUTQ_RERANKER_ENSEMBLE= python main.py
```
```powershell
# PowerShell
$env:NUTQ_RERANKER_ENSEMBLE = ""; python main.py
```

---

## 6. Test and evaluate

**Smoke test** (server must be running): sends a fixed set of queries and writes a readable report to
`search_test_results.txt`.

```bash
python test.py                 # all queries
python test.py --query 12      # one query
python test.py --verbose       # with BM25 / rerank debug fields
```

**Gold evaluation** (no server needed; loads the engine in-process): 55 Arabic queries with expected
evidence in `eval/gold_queries.json`, reports P@10, core recall@10 and MRR. Reranker scores are cached in
`eval/.rerank_cache.sqlite`, so re-runs after small changes are fast.

```bash
python eval/run_eval.py --out eval/runs/my_run.json
python eval/run_eval.py --out eval/runs/my_run.json --compare eval/runs/final3.json   # per-metric diff
python eval/run_eval.py --only 3,17 --trace       # selected queries, with fusion/rerank ranks of the gold ids
python eval/score_results_file.py search_test_results.txt                             # score test.py report(s)
```

Current reference (`eval/runs/final3.json`): **P@10 0.820, core recall@10 0.577, MRR 0.784**.

---

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| `FileNotFoundError: assets/corpus_map.json` | step 3 - copy or build the assets |
| `Vector count (...) != corpus_map size (...)`, or nonsense results | `semantic_vectors.npy` and `corpus_map.json` come from different runs - re-embed, delete `bm25_index.pkl` |
| `OpenVINO/optimum-intel isn't installed - using torch` | `pip install -r requirements-openvino.txt` (or ignore on CUDA machines) |
| `No GPU - using CPU` | expected without CUDA; with OpenVINO the iGPU is still used |
| process killed / out of memory | close other heavy apps; don't run the server and `eval/run_eval.py` at the same time (each loads all models) |
| first query is slow | normal - warm-up; later queries are faster |
| `pip install faiss-gpu` fails on Windows | use `faiss-cpu` (default in `requirements.txt`) |
| Hugging Face 429 / slow downloads | `huggingface-cli login` or set `HF_TOKEN` |

---

## Project layout

```
main.py                         FastAPI app (startup loads corpus, indexes, classifier data, models)
config.py                       all settings
search/
  classifier.py                 language / query type / scope, direct references, transliteration, glosses
  retriever.py, fusion.py       dense + BM25 retrieval and weighted RRF
  reranker.py, pipeline.py      reranking, filtering, comparative queries, response assembly
  constants.py                  signal word lists, surah names, topic / person glosses
  translit_variants.py          Latin spelling-variant generator
indexes/                        FAISS and BM25 index code
models/                         model loading (CUDA / OpenVINO / CPU), Qwen3 reranker, ensemble
data/                           alias map, transliteration table (+ generated variants), synonym index
eval/                           gold queries and evaluation scripts
hadith.py, quran-with-tafser.py, normalize_data_chuncks.py, vectorize_and_index.py    data pipeline
build_transliteration_variants.py, build_synonym_index_file.py, verify_alias_map.py   data tools
test.py                         smoke test against a running server
```
