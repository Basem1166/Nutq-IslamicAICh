import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import torch
from sentence_transformers import SentenceTransformer
from sklearn.metrics.pairwise import cosine_similarity

# ── Resolve project root so we can import from the main codebase ──────────────
# Adjust if your directory layout differs.
PROJECT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_ROOT))

from search.tokenizer import arabic_tokenize_passage, english_tokenize


# ─── Config ───────────────────────────────────────────────────────────────────

CORPUS_FILE = "master_semantic_corpus_normalized.json"
OUTPUT_FILE = "data/synonym_index.json"
MODEL_NAME  = "intfloat/multilingual-e5-large-instruct"

# Only build synonyms for tokens that appear at least this many times.
MIN_TOKEN_FREQ = 5

# Cap on unique tokens to embed — keeps memory/time reasonable.
MAX_VOCAB_SIZE = 8_000

# Cosine similarity threshold for two tokens to be considered synonyms.
# 0.82 is tight enough to avoid false positives but still catches morphological
# variants and close semantic relatives well.
SIMILARITY_THRESHOLD = 0.75

# Max synonyms per token — BM25 expansion with 10+ tokens per query term
# gets noisy fast; keep it small.
MAX_SYNONYMS_PER_TOKEN = 6


# ─── Tokenization ─────────────────────────────────────────────────────────────

def tokenize_for_vocab(text: str) -> list[str]:
    """
    Tokenize a corpus document for vocabulary building.

    Mirrors tokenize_document() in indexes/bm25_index.py exactly so that synonym
    index keys and BM25 document index tokens are produced by the same pipeline:
      normalize_text  →  split Arabic/English  →  arabic_tokenize_passage / english_tokenize
    """
    import re
    from indexes.bm25_index import normalize_text

    text = normalize_text(text)   # normalize_arabic + .lower() — must come first

    arabic_part  = re.sub(r'[^\u0600-\u06FF\s]', ' ', text)
    english_part = re.sub(r'[\u0600-\u06FF]', ' ', text)

    return arabic_tokenize_passage(arabic_part) + english_tokenize(english_part)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    print("Loading corpus …")
    with open(CORPUS_FILE, encoding="utf-8") as f:
        chunks = json.load(f)

    # ── Collect all text ───────────────────────────────────────────────────
    all_texts: list[str] = []
    for c in chunks:
        st = c.get("source_type", "")
        if st == "Quran_Tafsir":
            all_texts.append(c.get("arabic_text_normalized", ""))
            all_texts.append(c.get("arabic_tafsir_normalized", ""))
            all_texts.append(c.get("english_translation", ""))
        else:
            all_texts.append(c.get("arabic_text_normalized", ""))
            all_texts.append(c.get("english_text", ""))

    # ── Build vocabulary ───────────────────────────────────────────────────
    print("Building vocabulary …")
    counter: Counter = Counter()
    for text in all_texts:
        if text:
            counter.update(tokenize_for_vocab(text))

    vocab = [
        tok for tok, freq in counter.most_common(MAX_VOCAB_SIZE)
        if freq >= MIN_TOKEN_FREQ
    ]
    print(f"  Vocabulary size: {len(vocab):,} tokens")

    # ── Embed all vocab tokens ─────────────────────────────────────────────
    print(f"Loading model {MODEL_NAME} …")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model  = SentenceTransformer(MODEL_NAME, device=device)

    print(f"Embedding {len(vocab):,} tokens …")
    # Prefix matches the query embedding space used by the retriever
    prefixed   = [f"query: {tok}" for tok in vocab]
    embeddings = model.encode(
        prefixed,
        batch_size=256,
        normalize_embeddings=True,
        show_progress_bar=True,
        convert_to_numpy=True,
    ).astype("float32")

    # ── Pairwise cosine similarity in blocks to avoid OOM ─────────────────
    print("Computing pairwise similarities …")
    n            = len(vocab)
    synonym_index: dict[str, list[str]] = {}
    block_size   = 500

    for i in range(0, n, block_size):
        block_embs = embeddings[i : i + block_size]
        sims       = cosine_similarity(block_embs, embeddings)

        for j, sim_row in enumerate(sims):
            token     = vocab[i + j]
            neighbors = np.where(sim_row >= SIMILARITY_THRESHOLD)[0]
            synonyms: list[tuple[str, float]] = []
            for nidx in neighbors:
                if nidx == (i + j):
                    continue
                synonyms.append((vocab[nidx], float(sim_row[nidx])))

            synonyms.sort(key=lambda x: x[1], reverse=True)
            synonym_index[token] = [s for s, _ in synonyms[:MAX_SYNONYMS_PER_TOKEN]]

        if (i // block_size) % 5 == 0:
            print(f"  {i:,}/{n:,} done …")

    # Filter tokens with no synonyms to save space
    synonym_index = {k: v for k, v in synonym_index.items() if v}

    print(f"\nSynonym index built: {len(synonym_index):,} tokens with synonyms")
    # Spot-check a few key Islamic terms
    for sample in ["صيام", "صبر", "patience", "prayer", "زكاة"]:
        print(f"  {sample} -> {synonym_index.get(sample, 'not found')}")

    output_path = Path(OUTPUT_FILE)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(synonym_index, f, ensure_ascii=False, indent=2)
    print(f"\nSaved -> '{output_path}'")


if __name__ == "__main__":
    main()