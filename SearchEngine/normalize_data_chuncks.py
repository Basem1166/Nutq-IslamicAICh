import json
import os
import re
from pyarabic.araby import strip_tashkeel, normalize_ligature, normalize_hamza


# superscript alif, small high/low Quranic annotation marks (U+06D6-06ED), tatweel, BOM
QURANIC_MARKS_RE = re.compile(r'[\u0670\u06D6-\u06ED\u0640\uFEFF]')


def normalize_arabic_text(text: str) -> str:
    # strips harakat, normalizes alif variants, converts ta-marbuta and alef maqsura
    # to their base forms so indexing is consistent across different writing styles.
    # Must stay identical to search.classifier.normalize_arabic (used at query time).
    if not isinstance(text, str):
        return ""

    text = strip_tashkeel(text)
    text = QURANIC_MARKS_RE.sub('', text)

    # flatten the alif variants (incl. alif wasla) into bare alif
    text = re.sub(r'[أإآٱ]', 'ا', text)

    # ta-marbuta -> haa, alef maqsura -> yaa
    text = text.replace('ة', 'ه')
    text = text.replace('ى', 'ي')

    # hamza on waw/yaa -> standalone hamza
    text = text.replace('ؤ', 'ء').replace('ئ', 'ء')

    return text.strip()


# English text of entries that only repeat a previous hadith through another isnad
# ("This hadith has been narrated ... with the same chain of transmitters", "As above").
# They have no matn of their own, so they only add noise to retrieval and results.
CHAIN_ONLY_EN_RE = re.compile(
    r"(hadith|tradition)s? (like (this|it|that)|has been (narrated|reported|transmitted)|"
    r"(is|was|had been) (narrated|reported|transmitted)|similar to|to the same effect)|"
    r"same chain|with the same (wording|meaning|chain)|through (a|another) (different )?chain",
    re.IGNORECASE,
)
SEE_ABOVE_EN_RE = re.compile(
    r"\b(as above|see (the )?previous hadith|same as (the )?(above|previous)|see (translation|hadith)\b|"
    r"same as no\.?|as (hadith )?no\.? ?\d+|similarly-*\s*as no|narration about the chain)",
    re.IGNORECASE,
)


def is_chain_only_hadith(chunk: dict) -> bool:
    english = (chunk.get('english_text') or '').strip()
    if len(english) < 80 and SEE_ABOVE_EN_RE.search(english):
        return True
    return len(english) < 300 and bool(CHAIN_ONLY_EN_RE.search(english))


def load_and_normalize_data():
    HADITH_FILE = "hadith_semantic_chunks.json"
    QURAN_FILE  = "quran_and_tafsir_data.json"
    OUTPUT_FILE = "master_semantic_corpus_normalized.json"

    all_chunks = []

    # --- Hadith ---
    print(f"Loading and normalizing Hadith data from {HADITH_FILE}...")
    try:
        with open(HADITH_FILE, 'r', encoding='utf-8') as f:
            hadith_data = json.load(f)

        dropped = 0
        for chunk in hadith_data:
            if is_chain_only_hadith(chunk):
                dropped += 1
                continue
            ar_norm = normalize_arabic_text(chunk.get('arabic_text', ''))
            chunk['arabic_text_normalized'] = ar_norm
            # combined field used by BM25 at index time
            chunk['combined_arabic_text_normalized'] = (
                ar_norm + " " + chunk.get('english_text', '')
            ).strip()
            all_chunks.append(chunk)

        print(f"  ok: {len(hadith_data) - dropped:,} Hadith chunks normalized "
              f"({dropped:,} chain-only repeats dropped).")

    except FileNotFoundError:
        print(f"  [ERROR] Hadith file not found: {HADITH_FILE}")
    except json.JSONDecodeError:
        print(f"  [ERROR] Could not parse JSON from {HADITH_FILE}")

    # --- Quran / Tafsir ---
    print(f"\nLoading and normalizing Quran/Tafsir data from {QURAN_FILE}...")
    try:
        with open(QURAN_FILE, 'r', encoding='utf-8') as f:
            quran_data = json.load(f)

        for chunk in quran_data:
            # search uses the simple (imla'i) text; arabic_text stays Uthmani for display
            ar_norm     = normalize_arabic_text(chunk.get('arabic_text_simple') or chunk.get('arabic_text', ''))
            tafsir_norm = normalize_arabic_text(chunk.get('arabic_tafsir', ''))

            chunk['arabic_text_normalized']   = ar_norm
            chunk['arabic_tafsir_normalized'] = tafsir_norm

            chunk['combined_arabic_text_normalized'] = (
                ar_norm + " " + tafsir_norm + " " + chunk.get('english_translation', '')
            ).strip()

        all_chunks.extend(quran_data)
        print(f"  ok: {len(quran_data):,} Quran/Tafsir chunks normalized.")

    except FileNotFoundError:
        print(f"  [ERROR] Quran/Tafsir file not found: {QURAN_FILE}")
    except json.JSONDecodeError:
        print(f"  [ERROR] Could not parse JSON from {QURAN_FILE}")

    print(f"\nTotal chunks ready for vectorization: {len(all_chunks):,}")

    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        json.dump(all_chunks, f, ensure_ascii=False, indent=2)

    print(f"Saved to '{OUTPUT_FILE}'")
    print(f"   Path: {os.path.join(os.getcwd(), OUTPUT_FILE)}")


if __name__ == "__main__":
    load_and_normalize_data()
