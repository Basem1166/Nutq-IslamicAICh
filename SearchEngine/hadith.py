"""
hadith.py  —  v4  (Raw GitHub only + proper 403 handling)
=========================================================
"""

import json
import requests
import os
import time

# ─── Configuration ────────────────────────────────────────────────────────────

# Raw GitHub — stable, no CDN rate-limiting
BASE_URL = "https://raw.githubusercontent.com/fawazahmed0/hadith-api/1"

BOOK_IDS = [
    # (eng_edition,   ara_edition,    display_name,        sections)
    ("eng-bukhari",  "ara-bukhari1",  "Sahih al-Bukhari",  97),
    ("eng-muslim",   "ara-muslim",    "Sahih Muslim",       56),
    ("eng-tirmidhi", "ara-tirmidhi",  "Jami` at-Tirmidhi", 49),
    ("eng-abudawud", "ara-abudawud",  "Sunan Abu Dawood",  43),
]

OUTPUT_FILE   = "hadith_semantic_chunks.json"
REQUEST_DELAY = 0.3   # seconds between requests
MAX_RETRIES   = 3
TIMEOUT       = 30


# ─── Fetch helper ─────────────────────────────────────────────────────────────

def fetch_json(path: str) -> dict | None:
    """Fetch a JSON file from the raw GitHub repo."""
    url = f"{BASE_URL}/{path}"
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            r = requests.get(url, timeout=TIMEOUT)
            # 404 or 403 on raw GitHub = file doesn't exist -> clean skip
            if r.status_code in (404, 403):
                return None
            r.raise_for_status()
            return r.json()
        except requests.exceptions.RequestException as e:
            print(f"    [ERROR attempt {attempt}/{MAX_RETRIES}] {url}: {e}")
            if attempt < MAX_RETRIES:
                time.sleep(1.5 * attempt)
    return None


# ─── Main ─────────────────────────────────────────────────────────────────────

hadith_chunks: list[dict] = []

print("Starting hadith retrieval (raw GitHub, sections-based)...")
print(f"Source: {BASE_URL}\n")

for eng_edition, ara_edition, book_name, num_sections in BOOK_IDS:
    print(f"{'─'*60}")
    print(f"Processing: {book_name}  ({eng_edition})")
    print(f"  Sections to fetch: 1-{num_sections}")

    book_chunks: list[dict] = []
    skipped = 0

    for sec_num in range(1, num_sections + 1):

        # English section
        eng_sec = fetch_json(f"editions/{eng_edition}/sections/{sec_num}.json")
        time.sleep(REQUEST_DELAY)
        if not eng_sec:
            skipped += 1
            continue

        # Arabic section
        ara_sec = fetch_json(f"editions/{ara_edition}/sections/{sec_num}.json")
        time.sleep(REQUEST_DELAY)
        if not ara_sec:
            skipped += 1
            continue

        # Arabic lookup: hadithnumber -> text
        arabic_lookup: dict[str, str] = {
            str(h["hadithnumber"]): h["text"]
            for h in ara_sec.get("hadiths", [])
            if "hadithnumber" in h and "text" in h
        }

        for eng_h in eng_sec.get("hadiths", []):
            try:
                h_id = str(eng_h["hadithnumber"])
                if h_id not in arabic_lookup:
                    continue
                book_chunks.append({
                    "chunk_id":     f"H_{eng_edition}_{h_id}",
                    "source_type":  "Hadith",
                    "book_name":    book_name,
                    "chapter_id":   str(sec_num),
                    "hadith_id":    h_id,
                    "arabic_text":  arabic_lookup[h_id],
                    "english_text": eng_h["text"],
                    # [{"name": grader, "grade": "Sahih" | "Hasan" | "Da'if" ...}] (empty for Bukhari/Muslim)
                    "grades":       eng_h.get("grades", []),
                })
            except KeyError as e:
                print(f"    [WARNING] Missing key {e} in section {sec_num}")
                continue

        # Progress every 10 sections
        if sec_num % 10 == 0:
            print(f"    ... section {sec_num}/{num_sections}  "
                  f"({len(book_chunks)} hadiths so far)")

    # Deduplicate
    seen: set[str] = set()
    deduped: list[dict] = []
    for chunk in book_chunks:
        if chunk["chunk_id"] not in seen:
            seen.add(chunk["chunk_id"])
            deduped.append(chunk)

    dups = len(book_chunks) - len(deduped)
    print(f"  OK  {len(deduped):,} unique hadiths  "
          f"({dups} duplicates removed, {skipped} sections skipped)\n")
    hadith_chunks.extend(deduped)


# ─── Summary ──────────────────────────────────────────────────────────────────

print(f"{'─'*60}")
print(f"Total hadith chunks : {len(hadith_chunks):,}")

n_real = sum(1 for c in hadith_chunks if c.get("chapter_id") not in ("N/A", "", None))
pct    = 100 * n_real / len(hadith_chunks) if hadith_chunks else 0
print(f"With real chapter_id: {n_real:,}  ({pct:.1f}%)")

for _, _, book_name, _ in BOOK_IDS:
    chapters = {c["chapter_id"] for c in hadith_chunks if c["book_name"] == book_name}
    count    = sum(1 for c in hadith_chunks if c["book_name"] == book_name)
    print(f"  {book_name}: {count:,} hadiths, {len(chapters)} chapters")


# ─── Save ─────────────────────────────────────────────────────────────────────

try:
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(hadith_chunks, f, ensure_ascii=False, indent=2)
    print(f"\nSaved -> '{OUTPUT_FILE}'")
    print(f"   Path: {os.path.join(os.getcwd(), OUTPUT_FILE)}")
except Exception as e:
    print(f"\n[ERROR] Could not save: {e}")