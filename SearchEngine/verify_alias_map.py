"""
verify_alias_map.py
===================
Run this once after building your corpus to find any alias_map.json entries
whose chunk_id doesn't exist in your actual corpus_map.json.

Usage:
    python verify_alias_map.py

Expects:
    assets/corpus_map.json
    data/alias_map.json

Output:
    Prints missing chunk IDs grouped by type (Quran / Hadith) so you can
    correct either the alias map or look up the right hadith number.
"""

import json
from pathlib import Path
from collections import defaultdict

CORPUS_MAP_FILE = Path("assets/corpus_map.json")
ALIAS_MAP_FILE  = Path("data/alias_map.json")


def main():
    print("Loading corpus map ...")
    with open(CORPUS_MAP_FILE, "r", encoding="utf-8") as f:
        corpus_map = json.load(f)

    # corpus_map.json is a list from vectorization output
    # convert to set of chunk_ids for O(1) lookup
    if isinstance(corpus_map, list):
        known_ids = {c["chunk_id"] for c in corpus_map}
    else:
        known_ids = set(corpus_map.keys())

    print(f"  {len(known_ids):,} chunk IDs loaded.\n")

    print("Loading alias map ...")
    with open(ALIAS_MAP_FILE, "r", encoding="utf-8") as f:
        alias_map = json.load(f)

    # Skip comment/section keys
    entries = {
        k: v for k, v in alias_map.items()
        if not k.startswith("_") and isinstance(v, str) and not v.startswith("---")
    }
    print(f"  {len(entries)} alias entries to verify.\n")

    # ── Check each entry ──────────────────────────────────────────────────────
    missing   = defaultdict(list)   # chunk_id -> [aliases that point to it]
    ok_count  = 0

    for alias, chunk_id in entries.items():
        if chunk_id in known_ids:
            ok_count += 1
        else:
            ctype = "Quran" if chunk_id.startswith("Q_") else "Hadith"
            missing[ctype].append((alias, chunk_id))

    # ── Report ────────────────────────────────────────────────────────────────
    total   = len(entries)
    n_miss  = sum(len(v) for v in missing.values())

    print(f"Results: {ok_count}/{total} OK  |  {n_miss} missing\n")

    if not missing:
        print("All alias chunk IDs found in corpus. You are good to go.")
        return

    for ctype, items in missing.items():
        print(f"{'─'*60}")
        print(f"MISSING {ctype} chunks ({len(items)}):")
        for alias, chunk_id in sorted(items, key=lambda x: x[1]):
            print(f"  alias : \"{alias}\"")
            print(f"  target: {chunk_id}  ← NOT IN CORPUS")
            print()



if __name__ == "__main__":
    main()