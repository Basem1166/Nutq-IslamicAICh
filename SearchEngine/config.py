import os
from pathlib import Path

BASE_DIR= Path(__file__).parent
DATA_DIR= BASE_DIR / "data"
ASSETS_DIR= BASE_DIR / "assets"

VECTOR_FILE= ASSETS_DIR / "semantic_vectors.npy"
CORPUS_MAP_FILE= ASSETS_DIR / "corpus_map.json"
BM25_INDEX_FILE= ASSETS_DIR / "bm25_index.pkl"

ALIAS_MAP_FILE= DATA_DIR / "alias_map.json"
TRANSLITERATION_FILE= DATA_DIR / "transliteration.json"
TRANSLITERATION_VARIANTS_FILE= DATA_DIR / "transliteration_variants.json"
SYNONYM_INDEX_PATH=  DATA_DIR / "synonym_index.json"


EMBEDDING_MODEL_NAME= "intfloat/multilingual-e5-large-instruct"

QUERY_INSTRUCTION= (
    "Instruct: Given an Islamic search query, retrieve the most relevant "
    "Quran ayahs or Hadith\nQuery: "
)

EMBEDDING_DIMENSION= 1024
EMBEDDING_BATCH_SIZE= 32
# cross-encoder. Qwen3-Reranker (LLM yes/no relevance judge) separated the right ayah/hadith from
# look-alikes far better than bge-reranker-v2-m3 on the gold set (eval/gold_queries.json):
# 68% vs 46% gold-over-distractor pairs. Larger variants (Qwen/Qwen3-Reranker-4B) are a drop-in
# upgrade on a big GPU. "BAAI/bge-reranker-v2-m3" still works here (scores are on a different scale ->
# see RERANKER_SCORE_PROFILE below).
RERANKER_MODEL_NAME= os.environ.get("NUTQ_RERANKER_MODEL", "BAAI/bge-reranker-v2-m3")
RERANKER_INSTRUCTION= ("Given an Islamic search query (Arabic or English), judge whether this Quran verse or "
                       "Hadith is relevant evidence that directly addresses the query")
# local OpenVINO only: int8 weights (3x faster on an Intel iGPU, scores within ~0.02). CUDA always uses fp16.
RERANKER_OPENVINO_INT8= True
# second reranker; cross-encoder score = (1 - w) * primary + w * this model ("" / NUTQ_RERANKER_ENSEMBLE= disables).
# Gold eval (55 q): bge alone 0.829 P@10 / 0.532 core recall; + Qwen3-0.6B at w=0.15 (with the 0.3 floor below)
# 0.828 / 0.546 - Qwen vetoes off-topic items bge over-rates; larger w raises recall but blurs the ordering (MRR drops).
RERANKER_ENSEMBLE_MODEL= os.environ.get("NUTQ_RERANKER_ENSEMBLE", "Qwen/Qwen3-Reranker-0.6B")
RERANKER_ENSEMBLE_WEIGHT= float(os.environ.get("NUTQ_RERANKER_ENSEMBLE_WEIGHT", "0.15"))
# bge scores clearly relevant ayahs near 0 (Q 3:123 for "غزوة بدر" 0.04, Q 23:2 for khushu' 0.005; Qwen 0.96 / 0.86),
# so Qwen gets half the say on Quran candidates. Gold eval: core recall 0.542 -> 0.561, MRR 0.735 -> 0.730 (alone);
# with TOPIC_GLOSSES and FUSION_GUARANTEE_TOP_EACH 0.820 P@10 / 0.577 core / 0.784 MRR.
RERANKER_ENSEMBLE_WEIGHT_QURAN= float(os.environ.get("NUTQ_RERANKER_ENSEMBLE_WEIGHT_QURAN", "0.5"))

# retrieval budgets
DENSE_TOP_K= 200
BM25_TOP_K= 200

# Arabic keyword queries depend more heavily on lexical matching.
ARABIC_KEYWORD_DENSE_TOP_K= 100
ARABIC_KEYWORD_BM25_TOP_K= 200

# how many fused candidates the cross-encoder scores. The reranker is accurate when
# the right passage reaches it; most misses were candidates ranked 30-150 in fusion.
RERANK_CANDIDATE_CAP= 120

# batch size for BGE reranker
RERANKER_BATCH_SIZE= 16

# max tokens per (query, passage) pair; model default is 8192, which is very slow on CPU
RERANKER_MAX_LENGTH= 1024

# inference backend: "openvino" (Intel CPU/iGPU) or "torch". Falls back to torch
# if OpenVINO isn't installed or fails to load.
INFERENCE_BACKEND= "openvino"
OPENVINO_DEVICE= "GPU"   # "GPU" (Intel iGPU) | "CPU" | "AUTO"
# models are converted to OpenVINO once and cached here
OPENVINO_MODEL_DIR= ASSETS_DIR / "openvino"

FUSION_TOP_K= 120
FUSION_TOP_K_BY_TYPE= {
    "thematic": 150,
    "definitional": 150,
    "fiqh": 150,
    "narrative": 150,
    "arabic_keyword": 120,
    "comparative": 60,
    "comparative_concept": 60,
    "direct_reference": 5,
    "named_concept": 5,}

COMPARATIVE_COOCCURRENCE_BOOST= 1.5
RRF_K= 60
BM25_RANK1_BOOST_MULTIPLIER= 3.0
HADITH_CLUSTER_RRF_PENALTY= 0.3
RETRIEVAL_WEIGHTS= {
    "direct_reference": (0.5,  0.5),
    "named_concept":    (0.5,  0.5),
    "fiqh":             (0.65, 0.35),
    "thematic":         (0.7,  0.3),
    "definitional":     (0.65, 0.35),
    "narrative":        (0.75, 0.25),
    "arabic_keyword":   (0.1,  0.9),
    "exact_arabic":     (1.0,  0.0),
    "comparative":      (0.55, 0.45),
}

# Reranking Settings
RERANK_TOP_K= 5
RERANKER_BM25_ONLY_THRESHOLD= 0.02
RERANKER_FLOOR_SCORE= 0.01

# result tail: instead of always padding to top_k with unscored filler, drop results whose
# reranker score is < max(MIN_RESULT_ABS_SCORE, MIN_RESULT_REL_SCORE * best score).
# The first MIN_RESULTS_KEPT results are always returned.
# Gold eval: below 20% of the top score ~2/3 of results were off-topic (P@10 0.80 -> 0.83, core recall -0.005);
# an absolute floor cost recall because weak-but-valid queries (comparatives) score ~0.1 throughout.
PAD_RESULTS_TO_TOP_K= False
MIN_RESULT_ABS_SCORE= 0.01
# Qwen in the ensemble lifts tail scores, so the cutoff is higher with it (0.3) than for bge alone (0.2)
MIN_RESULT_REL_SCORE= 0.3 if (RERANKER_ENSEMBLE_MODEL and RERANKER_ENSEMBLE_WEIGHT > 0) else 0.2
MIN_RESULTS_KEPT= 3


# stem-cap dedup in fusion
FUSE_STEM_CAP_SIZE= 60

# quran passage window sizes
PASSAGE_WINDOW_NORMAL_MAX= 12
PASSAGE_WINDOW_NARRATIVE_MAX= 40
PASSAGE_LARGE_THRESHOLD_NORMAL= PASSAGE_WINDOW_NORMAL_MAX + 1
PASSAGE_LARGE_THRESHOLD_NARRATIVE= PASSAGE_WINDOW_NARRATIVE_MAX + 1

# definitional queries need 3-5 ayah windows (fasting, zakat etc.) only penalise windows wider than 6 ayahs
PASSAGE_LARGE_THRESHOLD_DEFINITIONAL= 6
PASSAGE_OVERLAP_THRESHOLD= 0.4

# language detection
ARABIC_CHAR_THRESHOLD= 0.3
ARABIC_THRESHOLD= 0.6

# corpus scope
SCOPE_QURAN= "quran"
SCOPE_HADITH= "hadith"
SCOPE_ALL= "all"

QURAN_SOURCE_TYPES= {"Quran_Tafsir", "Quran_Passage"}
HADITH_SOURCE_TYPES= {"Hadith", "Hadith_Cluster"}
QURAN_TAFSIR= "Quran_Tafsir"
QURAN_PASSAGE= "Quran_Passage"
HADITH= "Hadith"
HADITH_CLUSTER= "Hadith_Cluster"

# query type labels
QTYPE_DIRECT_REF= "direct_reference"
QTYPE_NAMED= "named_concept"
QTYPE_FIQH= "fiqh"
QTYPE_THEMATIC= "thematic"
QTYPE_NARRATIVE= "narrative"
QTYPE_AR_KEYWORD= "arabic_keyword"
QTYPE_DEFINITIONAL= "definitional"
QTYPE_COMPARATIVE= "comparative"
QTYPE_COMPARATIVE_CONCEPT= "comparative_concept"
QTYPE_EXACT_AR= "exact_arabic"


SURAH_ONLY_WINDOW_SIZE= 4

FIQH_MIN_RERANKER_SCORE= 0.01
DEFINITIONAL_MIN_RERANKER_SCORE= 0.005
QURAN_TAFSIR_SECONDARY_PENALTY= 0.85
HADITH_CLUSTER_FIQH_PENALTY= 0.2

BM25_ONLY_FIQH_SCORE_CAP= 0.008

# fusion tail cutoff -> kept loose: the reranker scores up to RERANK_CANDIDATE_CAP candidates,
# so trimming on RRF score only removes things the reranker would have ranked
TAIL_DROP_RATIO= 0.01
TAIL_ABS_FLOOR= 0.001

# Quran ayah-vs-passage dedup and the per-stem ayah cap used to run before reranking, on RRF
# scores. That threw away the better unit (Q 9:60 lost to the weaker QP_9:60-62 window) before
# the cross-encoder could compare them. They now run after reranking only.
PRE_RERANK_QURAN_DEDUP= False
# after reranking: at most this many results from one surah in the final list (non-narrative)
POST_RERANK_MAX_PER_SURAH= 3
MIN_TAIL_POOL_SIZE= 8

# text truncation limits —> keeps reranker input under its token budget
# Quran (ayah / passage window): imla'i Arabic + English (+ optional tafsir)
MAX_ARABIC_CHARS= 600
MAX_ENGLISH_CHARS= 400
# tafsir lets the cross-encoder score an ayah by its commentary rather than by what it says
# (Q 11:115 "واصبر" ranked #1 for "الصلاه" because al-Muyassar mentions prayer). 0 = off
MAX_TAFSIR_CHARS= int(os.environ.get("NUTQ_TAFSIR_CHARS", "200"))
# hadith: matn + English without isnad. Long hadiths (Jibril, Isra) carry the answer past 600 chars
MAX_HADITH_ARABIC_CHARS= 900
MAX_HADITH_ENGLISH_CHARS= 900

########## helpers #########
MAX_AYAHS_PER_STEM= 3
MAX_TOTAL_QURAN_AYAHS= 7
MAX_TOTAL_QURAN_AYAHS_NARRATIVE= 15 
HADITH_JACCARD_THRESHOLD= 0.40
HADITH_JACCARD_THRESHOLD_ENGLISH= 0.55

################### bm25 index #######################3
BM25_K1= 1.5
BM25_B= 0.65

MAX_SYNONYMS_PER_TOKEN= 3
# synonym_index.json is auto-generated and noisy -> expansions score at this fraction of a real query term
BM25_SYNONYM_WEIGHT= 0.3

# API
API_DEFAULT_TOP_K= 5
API_MAX_TOP_K= 20
API_VERSION= "v1"

# comparative queries: a concept's best result is promoted into the top 3 only if it scores at least this
COMPARATIVE_MIN_SIDE_SCORE= 0.05

# weight of the (dense + BM25) fusion score in the final ranking score; 0 = cross-encoder only
RERANK_FUSION_BLEND= 0.1

# scope=all: at least this many Quran and this many Hadith results in the top_k, when such candidates
# score >= SOURCE_BALANCE_MIN_RATIO x the best result (0 disables)
SOURCE_BALANCE_MIN_EACH= 3
SOURCE_BALANCE_MIN_RATIO= 0.5

# reranker query: drop "في القرآن" / "كيف تتحدث السنة عن" style framing (see classifier.strip_source_framing)
STRIP_RERANK_FRAMING= os.environ.get("NUTQ_STRIP_FRAMING", "0") == "1"

# comparative queries: also score candidates against each concept alone (max/mean with the full question)
COMPARATIVE_CONCEPT_RESCORE= os.environ.get("NUTQ_COMPARATIVE_RESCORE", "0") == "1"

# reranker query for comparative questions: "full" = the user's question, "concepts" = the two concepts only
# ("ما الفرق بين الصلاة الفريضة والنافلة" scored Bukhari 6502 at 0.46 with Qwen, "الصلاة الفريضة والنافلة" at 0.95)
# gold eval: "concepts" helped 2 of 7 comparatives and hurt 4 -> off
COMPARATIVE_RERANK_QUERY= os.environ.get("NUTQ_COMPARATIVE_RERANK_QUERY", "full")

# search/constants.py TOPIC_GLOSSES: describe a named event/concept to retrieval and the rerankers
TOPIC_GLOSSES_ENABLED= os.environ.get("NUTQ_TOPIC_GLOSSES", "1") == "1"
# comparative answers keep >= N results per contrasted concept (0 = off: the gold comparatives were already
# balanced, and tagging costs 2 x COMPARATIVE_TAG_POOL extra reranker pairs per query) (only items >= ratio x best score are promoted)
COMPARATIVE_BALANCE_MIN_EACH= int(os.environ.get("NUTQ_COMPARATIVE_BALANCE", "0"))
COMPARATIVE_BALANCE_MIN_RATIO= 0.4
# the top N of dense and of BM25 always enter the reranker pool, whatever the fusion weights
FUSION_GUARANTEE_TOP_EACH= int(os.environ.get("NUTQ_FUSION_GUARANTEE", "10"))
COMPARATIVE_TAG_POOL= 30       # results scored against each concept alone to tag them
COMPARATIVE_TAG_MIN= 0.3        # ... a tag needs at least this concept-only score
COMPARATIVE_TAG_MARGIN= 1.3     # ... and this factor above the other concept's score
