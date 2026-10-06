import json
import numpy as np
import os
import re
import torch
from sentence_transformers import SentenceTransformer
from tqdm import tqdm

os.environ["PYTORCH_CUDA_ALLOC_CONF"]= "expandable_segments:True"

NORMALIZED_CORPUS_FILE= "master_semantic_corpus_normalized.json"
EMBEDDING_MODEL_NAME= "intfloat/multilingual-e5-large-instruct"
VECTOR_FILE= "semantic_vectors.npy"
CORPUS_MAP_FILE= "corpus_map.json"
CHECKPOINT_FILE= "semantic_vectors_checkpoint.npy"

BATCH_SIZE= 32
CHECKPOINT_EVERY= 500  # save a checkpoint after this many batches

# (window, stride). Windows of 20/40 ayahs were dropped: the embedding model reads
# 512 tokens, so ~98% of them were embedded from their first few ayahs only.
PASSAGE_SCALES = [
    (3, 1),
    (6, 3),
    (12, 6),
]

# Hadith_Cluster chunks covered whole book sections (hundreds of hadiths) and were
# embedded from a truncated prefix -> they matched queries by accident. Off by default.
BUILD_HADITH_CLUSTERS = False

MIN_HADITHS_FOR_CLUSTER = 3
MAX_HADITHS_IN_CLUSTER_TEXT = 12
HADITH_BAND_SIZE = 50
TAFSIR_CHARS_PER_AYAH = 300

MATN_MARKERS = [
    "قال رسول الله",
    "قال النبي",
    "قال صلى الله عليه وسلم",
    "قال صلي الله عليه وسلم",
    "يقول رسول الله",
    "يقول النبي صلى",
    # corpus text is normalized (ى -> ي)
    "يقول النبي صلي",
]
CHAIN_WORDS = frozenset({"عن", "بن", "ابن", "ابو", "عبد", "انه", "قال", "عنه", "انها"})
ENGLISH_ISNAD_PATTERN = re.compile(
    r"^(Narrated\s+[\w\s'`\.]+?:|[\w\s'`\.]+?\s+reported\s*:|[\w\s'`\.]+?\s+said\s*:)\s*",
    re.IGNORECASE,
)
MIN_MATN_LENGTH = 30
MIN_MARKER_RATIO = 0.10
FALLBACK_CUT_RATIO = 0.35
MAX_PASSAGE_MEMBERS_FOR_EMBEDDING = 8
# ~250 tokens each (XLM-R tokenizer) -> both languages fit in the 512-token window
HADITH_ARABIC_EMBED_CHARS = 900
HADITH_ENGLISH_EMBED_CHARS = 1100


# isnad -> matn boundary. The chain opens with transmission verbs (حدثنا / أخبرنا / عن ...) a few
# words apart; it ends at the Prophet's name or at the first speech verb that is not followed by
# another transmission verb. The old "last speech marker wins" rule cut multi-turn hadiths down to
# their final sentence (Bukhari 50 kept only "هذا جبريل جاء يعلم الناس دينهم").
_ISNAD_TASHKEEL_RE= re.compile(r'[ؐ-ًؚ-ٰٟۖ-ۭـ‏‎]')
_ISNAD_TRANSMISSION= frozenset({'حدثنا', 'حدثني', 'اخبرنا', 'اخبرني', 'انبانا', 'انباني', 'سمعت', 'سمعنا', 'سمع',
                                'عن', 'حدثه', 'حدثهم', 'اخبره', 'اخبرهم', 'يحدث', 'حدثناه', 'اخبرناه', 'ح', 'ثنا', 'نا'})
_ISNAD_PROPHET= frozenset({'رسول', 'النبي', 'نبي'})
_ISNAD_SPEECH= frozenset({'قال', 'قالت', 'قالا', 'يقول', 'تقول', 'قالوا', 'ان', 'انه', 'انها', 'انهم', 'انهما'})
_ISNAD_MAX_GAP= 12


def _isnad_norm(word: str) -> str:
    w= _ISNAD_TASHKEEL_RE.sub('', word).strip("،,.:;\"'()[]-–‏ ")
    w= re.sub('[أإآٱ]', 'ا', w)
    if len(w) > 2 and w[0] in 'وف' and (w[1:] in _ISNAD_TRANSMISSION or w[1:] in _ISNAD_SPEECH):
        w= w[1:]
    return w


def find_matn_start(words: list[str]) -> int | None:
    """Index of the first matn word, or None when the text does not open with an isnad."""
    norm= [_isnad_norm(w) for w in words]
    if not any(n in _ISNAD_TRANSMISSION for n in norm[:3]):
        return None
    last_t= -1
    for i, n in enumerate(norm):
        if n in _ISNAD_PROPHET:
            # the Prophet closes the chain: keep "عن/سمعت/أن رسول الله ..." with the matn
            prev= norm[i - 1] if i else ''
            if prev in _ISNAD_TRANSMISSION or prev in _ISNAD_SPEECH:
                return i - 1
            return last_t + 1 if 0 <= last_t + 1 < i else i
        if n in _ISNAD_TRANSMISSION:
            if last_t != -1 and i - last_t > _ISNAD_MAX_GAP:
                return last_t + 1
            last_t= i
            continue
        if n in _ISNAD_SPEECH and last_t != -1:
            nxt= norm[i + 1] if i + 1 < len(norm) else ''
            if nxt not in _ISNAD_TRANSMISSION:
                return i
        if last_t != -1 and i - last_t > _ISNAD_MAX_GAP:
            return last_t + 1
    return last_t + 1 if last_t != -1 else None


def extract_matn_arabic(text: str) -> str:
    """
    Return only the Arabic hadith matn while trimming the isnad when possible.

    Parameters:
        text (str): Full Arabic hadith text.

    Returns:
        str: Matn-focused Arabic text.

    Notes:
        The function first looks for explicit prophetic speech markers, then falls
        back to progressively weaker heuristics so standalone indexing still works.
    """
    if not text:
        return text

    words = text.split()
    start = find_matn_start(words)
    if start is not None and start < len(words):
        matn = " ".join(words[start:])
        if len(matn) >= MIN_MATN_LENGTH:
            return matn

    total_length = len(text)
    minimum_cut_position = int(total_length * MIN_MARKER_RATIO)
    best_marker_position = -1

    for marker in MATN_MARKERS:
        marker_position = text.find(marker)
        while marker_position != -1:
            chars_after_marker = total_length - marker_position - len(marker)
            if (
                marker_position >= minimum_cut_position
                and marker_position > best_marker_position
                and chars_after_marker >= MIN_MATN_LENGTH
            ):
                best_marker_position = marker_position
            marker_position = text.find(marker, marker_position + 1)

    if best_marker_position != -1:
        return text[best_marker_position:]

    best_qal_position = -1
    search_start = minimum_cut_position
    while True:
        marker_position = text.find("قال", search_start)
        if marker_position == -1:
            break

        trailing_text = text[marker_position + 3 : marker_position + 60].strip()
        trailing_words = trailing_text.split()
        next_word = ""
        if trailing_words:
            next_word = trailing_words[0]

        is_direct_speech = (
            trailing_text.startswith("‏\"‏")
            or trailing_text.startswith('"')
            or trailing_text.startswith("رسول")
            or trailing_text.startswith("النبي")
            or trailing_text.startswith("صلى")
            or trailing_text.startswith("صلي")
        )
        if is_direct_speech and next_word not in CHAIN_WORDS and marker_position > best_qal_position:
            best_qal_position = marker_position

        search_start = marker_position + 1

    if best_qal_position != -1 and (total_length - best_qal_position) >= MIN_MATN_LENGTH:
        return text[best_qal_position:]

    fallback_qal_position = text.rfind("قال", minimum_cut_position)
    if fallback_qal_position != -1 and (total_length - fallback_qal_position) >= MIN_MATN_LENGTH:
        return text[fallback_qal_position:]

    fallback_start = int(total_length * FALLBACK_CUT_RATIO)
    return text[fallback_start:]


def extract_matn_english(text: str) -> str:
    if not text:
        return text

    cleaned_text = ENGLISH_ISNAD_PATTERN.sub("", text.strip())
    if len(cleaned_text) > 20:
        return cleaned_text
    return text


def get_text_for_embedding(chunk: dict) -> str:
    """Build the text string that gets embedded for a given chunk.

    multilingual-e5-*instruct* embeds documents with no prefix (the instruction
    goes on the query side only), so no "passage: " prefix is added.
    Quran text uses the simple (imla'i) script: Uthmani spelling is far from how
    queries are written.
    """
    source_type = chunk.get("source_type", "")

    if source_type == "Quran_Tafsir":
        arabic_text = chunk.get("arabic_text_simple") or chunk.get("arabic_text_normalized", "")
        tafsir_text = chunk.get("arabic_tafsir", "") or chunk.get("arabic_tafsir_normalized", "")
        english_text = chunk.get("english_translation", "")
        raw_text = f"{arabic_text}\n{english_text}\n{tafsir_text}".strip()
    elif source_type == "Quran_Passage":
        # ayah text + translation only: the per-ayah tafsir is in the Quran_Tafsir chunks,
        # and leaving it out keeps 3/6-ayah windows inside the 512-token limit
        text_parts = []
        for member in chunk.get("members", []):
            text_parts.append(member.get("arabic_text_simple") or member.get("arabic_text_normalized", ""))
        for member in chunk.get("members", []):
            text_parts.append(member.get("english_translation", ""))
        raw_text = " ".join(part for part in text_parts if part).strip()
    elif source_type == "Hadith_Cluster":
        text_parts = []
        for member in chunk.get("members", [])[:MAX_HADITHS_IN_CLUSTER_TEXT]:
            arabic_text = member.get("arabic_text_normalized", "") or member.get("arabic_text", "")
            english_text = member.get("english_text", "")
            text_parts.append(extract_matn_arabic(arabic_text))
            text_parts.append(extract_matn_english(english_text))
        raw_text = " ".join(part for part in text_parts if part).strip()
    else:
        # Arabic matn first and both sides capped: with English first, long translations pushed the
        # Arabic past the 512-token limit, so Arabic queries matched long hadiths on English only
        arabic_text = chunk.get("arabic_text_normalized", "") or chunk.get("arabic_text", "")
        english_text = chunk.get("english_text", "")
        arabic_matn = extract_matn_arabic(arabic_text)[:HADITH_ARABIC_EMBED_CHARS]
        english_matn = extract_matn_english(english_text)[:HADITH_ENGLISH_EMBED_CHARS]
        raw_text = f"{arabic_matn}\n{english_matn}".strip()

    return raw_text.strip()


def build_quran_passages(quran_chunks: list) -> list:
    """Build overlapping passage chunks at multiple window sizes.

    Every scale runs over every surah independently.
    No query-type gating -> all scales are always built.
    The reranker picks the best window size at search time.
    """
    surah_groups: dict[int, list] = {}
    for chunk in quran_chunks:
        surah_id = int(chunk.get("surah_id", 0))
        surah_groups.setdefault(surah_id, []).append(chunk)

    passages = []
    for surah_id in sorted(surah_groups):
        ayahs = sorted(surah_groups[surah_id], key=lambda chunk: int(chunk.get("ayah_id", 0)))
        ayah_count = len(ayahs)

        for window_size, stride in PASSAGE_SCALES:
            if ayah_count < window_size:
                continue

            start_index = 0
            while start_index < ayah_count:
                end_index = min(start_index + window_size, ayah_count)
                window = ayahs[start_index:end_index]
                if len(window) < max(2, window_size // 2):
                    break

                first_ayah = int(window[0].get("ayah_id", 0))
                last_ayah = int(window[-1].get("ayah_id", 0))

                passage = {
                    "chunk_id": f"QP_{surah_id}:{first_ayah}-{last_ayah}_w{window_size}",
                    "source_type": "Quran_Passage",
                    "surah_id": surah_id,
                    "start_ayah": first_ayah,
                    "end_ayah": last_ayah,
                    "ayah_count": len(window),
                    "window_size": window_size,
                    "arabic_text": " ".join(member.get("arabic_text", "") for member in window),
                    "arabic_text_normalized": " ".join(
                        member.get("arabic_text_normalized", "") for member in window
                    ),
                    "english_translation": " ".join(
                        member.get("english_translation", "") for member in window
                    ),
                    # BM25 field: normalized simple text + translation (tafsir lives in the ayah chunks)
                    "combined_arabic_text_normalized": " ".join(
                        [member.get("arabic_text_normalized", "") for member in window]
                        + [member.get("english_translation", "") for member in window]
                    ),
                    "arabic_tafsir": " ".join(member.get("arabic_tafsir", "") for member in window),
                    "arabic_tafsir_normalized": " ".join(
                        member.get("arabic_tafsir_normalized", "") for member in window
                    ),
                    "member_ids": [member["chunk_id"] for member in window],
                    "members": [
                        {
                            "chunk_id": member["chunk_id"],
                            "ayah_id": member["ayah_id"],
                            "arabic_text": member.get("arabic_text", ""),
                            "arabic_text_simple": member.get("arabic_text_simple", ""),
                            "arabic_text_normalized": member.get("arabic_text_normalized", ""),
                            "english_translation": member.get("english_translation", ""),
                            "arabic_tafsir_normalized": member.get("arabic_tafsir_normalized", ""),
                        }
                        for member in window
                    ],
                }
                passages.append(passage)
                start_index += stride

    return passages


def get_chapter_id(chunk: dict) -> str:
    """Get chapter ID, falling back to a hadith-number band when unavailable."""
    raw_chapter_id = str(chunk.get("chapter_id", "unknown")).strip()
    if raw_chapter_id not in {"N/A", "unknown", "", "None"}:
        return raw_chapter_id

    chunk_id = chunk.get("chunk_id", "")
    chunk_id_parts = chunk_id.split("_")
    try:
        hadith_number = int(chunk_id_parts[-1])
        band_start = (hadith_number // HADITH_BAND_SIZE) * HADITH_BAND_SIZE
        return f"band{band_start}"
    except (ValueError, IndexError):
        return "band0"


def build_hadith_clusters(hadith_chunks: list) -> list:
    """Group Hadith chunks by (book_short_id, chapter_id) and build one
    Hadith_Cluster per group with >= MIN_HADITHS_FOR_CLUSTER members.
    """
    grouped_chunks: dict[tuple, list] = {}
    for chunk in hadith_chunks:
        chunk_id = chunk.get("chunk_id", "")
        chunk_id_parts = chunk_id.split("_", 2)
        book_short_id = chunk_id_parts[1] if len(chunk_id_parts) >= 2 else "unknown"
        chapter_id = get_chapter_id(chunk)
        grouped_chunks.setdefault((book_short_id, chapter_id), []).append(chunk)

    clusters = []
    for (book_short_id, chapter_id), members in grouped_chunks.items():
        if len(members) < MIN_HADITHS_FOR_CLUSTER:
            continue

        text_members = members[:MAX_HADITHS_IN_CLUSTER_TEXT]
        cluster = {
            "chunk_id": f"HC_{book_short_id}_ch{chapter_id}",
            "source_type": "Hadith_Cluster",
            "book_name": members[0].get("book_name", book_short_id),
            "book_short": book_short_id,
            "chapter_id": chapter_id,
            "hadith_count": len(members),
            "arabic_text_normalized": " ".join(
                member.get("arabic_text_normalized", "") for member in text_members
            ),
            "english_text": " ".join(member.get("english_text", "") for member in text_members),
            "member_ids": [member["chunk_id"] for member in members],
            "members": [
                {
                    "chunk_id": member["chunk_id"],
                    "hadith_id": member.get("hadith_id", ""),
                    "arabic_text": member.get("arabic_text", ""),
                    "arabic_text_normalized": member.get("arabic_text_normalized", ""),
                    "english_text": member.get("english_text", ""),
                }
                for member in members
            ],
        }
        clusters.append(cluster)

    return clusters


def encode_batch(model: SentenceTransformer, batch_texts: list) -> np.ndarray:
    with torch.no_grad():
        embeddings= model.encode(batch_texts, convert_to_tensor=False, normalize_embeddings=True, show_progress_bar=False,)
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return np.array(embeddings, dtype='float32')


def main():
    if torch.cuda.is_available():
        gpu_name= torch.cuda.get_device_name(0)
        total_mem= torch.cuda.get_device_properties(0).total_memory / 1024**3
        print(f"GPU: {gpu_name} ({total_mem:.1f} GB)")

    # 1. load normalized corpus
    print(f"\nLoading corpus from '{NORMALIZED_CORPUS_FILE}'...")
    if not os.path.exists(NORMALIZED_CORPUS_FILE):
        print("  file not found -> run normalize_data_chuncks.py first")
        return

    with open(NORMALIZED_CORPUS_FILE, 'r', encoding='utf-8') as f:
        base_chunks= json.load(f)

    quran_chunks = []
    hadith_chunks = []

    # Route all chunks to their respective lists in a single, fast O(N) pass
    for chunk in base_chunks:
        if chunk.get("source_type") == "Quran_Tafsir":
            quran_chunks.append(chunk)
        else:
            hadith_chunks.append(chunk)
    print(f"  {len(base_chunks):,} base chunks ({len(quran_chunks):,} Quran | {len(hadith_chunks):,} Hadith)")

    # 2. build passage + cluster chunks
    print("\nBuilding Quran passage chunks ...")
    passage_chunks= build_quran_passages(quran_chunks)
    print(f"  {len(passage_chunks):,} passage chunks")

    cluster_chunks= []
    if BUILD_HADITH_CLUSTERS:
        print(f"\nBuilding Hadith cluster chunks (min_members={MIN_HADITHS_FOR_CLUSTER}, band={HADITH_BAND_SIZE})...")
        cluster_chunks= build_hadith_clusters(hadith_chunks)
        print(f"  {len(cluster_chunks):,} cluster chunks")

    # 3. assemble full corpus
    all_chunks= base_chunks + passage_chunks + cluster_chunks
    total= len(all_chunks)
    print(f"\nTotal: {total:,} chunks ({len(base_chunks):,} base + {len(passage_chunks):,} passages + {len(cluster_chunks):,} clusters)")

    # 4. resume from checkpoint if shape is compatible
    start_index= 0
    all_embeddings: list= []

    if os.path.exists(CHECKPOINT_FILE):
        ckpt= np.load(CHECKPOINT_FILE)
        if ckpt.shape[0] < total:
            start_index= ckpt.shape[0]
            all_embeddings= [ckpt]
            print(f"\n  Resuming from checkpoint: {start_index:,} / {total:,} done.")
        else:
            os.remove(CHECKPOINT_FILE)
            print(f"\nStale checkpoint ({ckpt.shape[0]} rows) discarded -> starting fresh.")
    else:
        print(f"\nStarting from scratch: {total:,} chunks to encode.")

    # 5. prepare all texts
    print("\nPreparing embedding texts...")
    texts = [get_text_for_embedding(chunk) for chunk in all_chunks]
    print(f"  {len(texts):,} texts ready.")

    # 6. load model
    print(f"\nLoading model '{EMBEDDING_MODEL_NAME}'...")
    model= SentenceTransformer(EMBEDDING_MODEL_NAME,device='cuda' if torch.cuda.is_available() else 'cpu',)
    print("  Model loaded.")

    # 7. batch encoding loop
    remaining= texts[start_index:]
    n_rem= len(remaining)
    n_batches= (n_rem + BATCH_SIZE - 1) // BATCH_SIZE

    print(f"\nEncoding {n_rem:,} texts in {n_batches:,} batches (batch_size={BATCH_SIZE})...\n")

    batches_since_ckpt= 0
    with tqdm(total=n_batches, unit="batch") as pbar:
        for i in range(0, n_rem, BATCH_SIZE):
            batch= remaining[i: i + BATCH_SIZE]
            embeddings= encode_batch(model, batch)
            all_embeddings.append(embeddings)
            pbar.update(1)
            batches_since_ckpt += 1

            if batches_since_ckpt >= CHECKPOINT_EVERY:
                combined= np.vstack(all_embeddings).astype('float32')
                np.save(CHECKPOINT_FILE, combined)
                batches_since_ckpt= 0
                pbar.set_postfix({"checkpoint": f"{combined.shape[0]:,} saved"})

    # 8. save final vectors
    print("\nConcatenating all batches...")
    final= np.vstack(all_embeddings).astype('float32')
    print(f"  Final matrix shape: {final.shape}")

    np.save(VECTOR_FILE, final)
    print(f"  Vectors saved to '{VECTOR_FILE}'.")

    if os.path.exists(CHECKPOINT_FILE):
        os.remove(CHECKPOINT_FILE)

    with open(CORPUS_MAP_FILE, "w", encoding="utf-8") as file_handle:
        json.dump(all_chunks, file_handle, ensure_ascii=False, indent=2)

    print(f"  Corpus map saved to '{CORPUS_MAP_FILE}'.")

    print("\nDone.")

if __name__== "__main__":
    main()
