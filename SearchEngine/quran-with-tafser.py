import requests
import json
import re

# --- API Endpoints ---
# Uthmani script is kept for display only. Its spelling (ٱلصَّلَوٰةَ, ٱلْكِتَـٰبُ) never matches
# modern Arabic queries, so search uses the simple (imla'i) edition below.
ARABIC_QURAN_URL = "https://api.alquran.cloud/v1/quran/quran-uthmani"
ARABIC_SIMPLE_URL = "https://api.alquran.cloud/v1/quran/quran-simple-clean"
ENGLISH_TRANSLATION_URL = "https://api.alquran.cloud/v1/quran/en.sahih"
ARABIC_TAFSIR_URL = "https://api.alquran.cloud/v1/quran/ar.muyassar"

# --- 1. Fetch Data ---
print("Fetching Arabic Quran (Uthmani)...")
arabic_quran_data = requests.get(ARABIC_QURAN_URL).json()
print("Fetching Arabic Quran (simple)...")
arabic_simple_data = requests.get(ARABIC_SIMPLE_URL).json()
print("Fetching English Translation...")
english_translation_data = requests.get(ENGLISH_TRANSLATION_URL).json()
print("Fetching Arabic Tafsir...")
arabic_tafsir_data = requests.get(ARABIC_TAFSIR_URL).json()


# --- 2. Build maps keyed by (surah_number, POSITION_in_surah) ---
def _build_position_map(data: dict, text_key: str) -> dict:
    """
    Returns {(surah_number, position_in_surah): text}
    where position_in_surah is 0-based index into the surah's ayahs list.
    """
    pos_map = {}
    if 'data' not in data: return pos_map
    for surah in data['data']['surahs']:
        snum = surah['number']
        # Use index 'i' to ensure we match the N-th ayah of Surah X in every edition
        for i, ayah in enumerate(surah['ayahs']):
            pos_map[(snum, i)] = ayah[text_key]
    return pos_map

arabic_text_map   = _build_position_map(arabic_quran_data, 'text')
arabic_simple_map = _build_position_map(arabic_simple_data, 'text')
arabic_tafsir_map = _build_position_map(arabic_tafsir_data, 'text')

BASMALA_WORDS = ["بسم", "الله", "الرحمن", "الرحيم"]


def _bare(word: str) -> str:
    # letters only, alif variants flattened -> enough to recognise the basmala in either script
    word = re.sub(r'[\u064B-\u065F\u0670\u06D6-\u06ED\u0640\uFEFF]', '', word)
    return re.sub(r'[أإآٱ]', 'ا', word)


def strip_basmala(text: str, surah_number: int) -> str:
    """alquran.cloud prepends the basmala to ayah 1 of every surah. It is only an
    ayah of Al-Fatiha (and surah 9 has none), so drop it everywhere else."""
    text = text.replace('\ufeff', '').strip()
    if surah_number == 1:
        return text
    words = text.split()
    if [_bare(w) for w in words[:4]] == BASMALA_WORDS:
        return " ".join(words[4:])
    return text

# --- Updated 3. Combine using English as the ID reference ---
quran_chunks = []
for surah in english_translation_data['data']['surahs']:
    snum = surah['number']
    for i, ayah in enumerate(surah['ayahs']):
        # Reference the positional key (snum, i)
        key = (snum, i)
        
        # English ayah['numberInSurah'] is usually the most stable canonical ID
        # because Sahih International follows the standard Egyptian/Tanzil numbering.
        canonical_id = ayah['numberInSurah'] 
        
        arabic_text = arabic_text_map.get(key, "")
        # drop the small Quranic pause marks (ۛ ۖ ...) the simple edition still carries
        arabic_simple = " ".join(re.sub(r'[ۖ-ۭ]', '', arabic_simple_map.get(key, "")).split())
        if canonical_id == 1:
            arabic_text = strip_basmala(arabic_text, snum)
            arabic_simple = strip_basmala(arabic_simple, snum)

        chunk = {
            "chunk_id": f"Q_{snum}:{canonical_id}",
            "source_type": "Quran_Tafsir",
            "surah_id": snum,
            "ayah_id": canonical_id,
            "arabic_text": arabic_text,
            "arabic_text_simple": arabic_simple,
            "english_translation": ayah['text'],
            "arabic_tafsir": arabic_tafsir_map.get(key, "")
        }
        quran_chunks.append(chunk)

# --- 4. Verify alignment with spot-checks ---
# These are well-known verses. If their Arabic text does not match, the
# positional alignment is broken and needs investigation.
SPOT_CHECKS = {
    "Q_2:43":  ["اقيموا", "الصلاة", "الزكاة"],    # Establish prayer and give zakah
    "Q_2:183": ["امنوا", "كتب", "الصيام"],          # Fasting is prescribed for you
    "Q_2:185": ["رمضان", "انزل", "القران"],          # Month of Ramadan
    "Q_3:97":  ["حج", "البيت", "استطاع"],            # Pilgrimage obligation
    "Q_65:1":  ["طلقتم", "النساء", "عدتهن"],         # Divorce procedure
}

chunk_by_id = {c["chunk_id"]: c for c in quran_chunks}
print("\n--- Spot-check alignment ---")
all_ok = True
for chunk_id, required_words in SPOT_CHECKS.items():
    chunk = chunk_by_id.get(chunk_id)
    if not chunk:
        print(f"  ✗ {chunk_id} NOT FOUND in output")
        all_ok = False
        continue
    # compare against the simple text: the Uthmani spelling (ٱلصَّلَوٰةَ) never contains "الصلاة"
    ar = _bare(chunk["arabic_text_simple"])
    missing = [w for w in required_words if _bare(w) not in ar]
    if missing:
        print(f"  ✗ {chunk_id}: missing {missing}")
        print(f"       Arabic preview: {ar[:80]}...")
        all_ok = False
    else:
        print(f"  ✓ {chunk_id}")

if all_ok:
    print("  All spot-checks passed — alignment is correct.")
else:
    print("  ⚠  Some spot-checks FAILED. Investigate the API edition numbering.")

# --- 5. Save Data ---
output_filename = "quran_and_tafsir_data.json"
with open(output_filename, "w", encoding="utf-8") as f:
    json.dump(quran_chunks, f, ensure_ascii=False, indent=2)

print(f"\n✅ Successfully saved {len(quran_chunks):,} ayahs to **{output_filename}**")
print("--- Sample Ayahs ---")
for chunk in quran_chunks[3:5]:
    print(f"ID: {chunk['chunk_id']}")
    print(f"Arabic Text: {chunk['arabic_text'][:50]}...")
    print(f"English Trans: {chunk['english_translation'][:50]}...")
    print(f"Arabic Tafsir: {chunk['arabic_tafsir'][:50]}...")
    print("-" * 20)