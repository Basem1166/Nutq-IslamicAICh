"""
Shared helper functions for deduplication and text cleaning.
Used by both fusion.py (pre-rerank) and pipeline.py (post-rerank).
"""

import re
from .tokenizer import arabic_tokenize
from collections import Counter

from config import (PASSAGE_OVERLAP_THRESHOLD, MAX_TOTAL_QURAN_AYAHS_NARRATIVE, MAX_AYAHS_PER_STEM, MAX_TOTAL_QURAN_AYAHS, 
                    PASSAGE_LARGE_THRESHOLD_NORMAL, PASSAGE_LARGE_THRESHOLD_NARRATIVE, QTYPE_NARRATIVE, HADITH_JACCARD_THRESHOLD, 
                    HADITH_JACCARD_THRESHOLD_ENGLISH, QURAN_SOURCE_TYPES, QURAN_TAFSIR, QURAN_PASSAGE, HADITH_SOURCE_TYPES)
from .constants import QURAN_CITATION_RE, ENGLISH_ISNAD_RE, MATN_MARKERS, CHAIN_WORDS, GRADING_TAIL_RE


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


def extract_matn(arabic_text: str) -> tuple[str, bool]:
    """Find where the hadith matn starts by skipping the isnad narrator chain.
    Returns (matn_text, found_explicit_marker).
    """
    if not arabic_text:
        return arabic_text, False

    words= arabic_text.split()
    start= find_matn_start(words)
    if start is not None and start < len(words):
        matn= ' '.join(words[start:])
        if len(matn) >= 30:
            return matn, True

    total_len= len(arabic_text)
    min_cut_pos= int(total_len * 0.10)

    # pass 1: look for explicit speech markers
    best_marker_pos= -1
    for marker in MATN_MARKERS:
        search_from= 0
        while True:
            pos= arabic_text.find(marker, search_from)
            if pos == -1:
                break
            chars_after= total_len - pos - len(marker)
            if pos >= min_cut_pos and pos > best_marker_pos and chars_after >= 30:
                best_marker_pos= pos
            search_from= pos + 1

    if best_marker_pos != -1:
        return arabic_text[best_marker_pos:], True

    # pass 2: last "قال" that introduces direct speech
    best_qal_pos= -1
    search_from= min_cut_pos

    while True:
        pos= arabic_text.find('قال', search_from)
        if pos == -1:
            break

        text_after= arabic_text[pos + 3: pos + 60].strip()
        next_word= text_after.split()[0] if text_after.split() else ''

        is_direct_speech= (
            text_after.startswith('‏"‏') or text_after.startswith('"') or
            text_after.startswith(' "') or text_after.startswith(' ‏"') or
            text_after.startswith('رسول') or text_after.startswith('النبي') or
            text_after.startswith('صلى') or text_after.startswith('أن ') or
            text_after.startswith('ان ') or text_after.startswith('بينما')
        )
        still_in_chain= next_word in CHAIN_WORDS

        if is_direct_speech and not still_in_chain and pos > best_qal_pos:
            best_qal_pos= pos

        search_from= pos + 1

    if best_qal_pos != -1 and (total_len - best_qal_pos) >= 30:
        return arabic_text[best_qal_pos:], False

    # pass 3: last "قال" after the 10% mark
    pos= arabic_text.rfind('قال', min_cut_pos)
    if pos != -1 and (total_len - pos) >= 30:
        return arabic_text[pos:], False

    # pass 4: hard cut at 35%
    return arabic_text[int(total_len * 0.35):], False


def strip_quran_citations(text: str) -> str:
    """Remove inline Quran citation patterns from hadith text."""
    return QURAN_CITATION_RE.sub(' ', text)


def strip_english_isnad(english_text: str) -> str:
    """Strip the narrator-chain prefix from an English hadith translation.
    Returns original text if the cleaned result is too short (regex over-matched).
    """
    if not english_text:
        return english_text
    cleaned= ENGLISH_ISNAD_RE.sub('', english_text.strip())
    return cleaned if len(cleaned) > 20 else english_text


def get_result_score(item: dict) -> float:
    """Return the best available score for a result dict.
    Prefers reranker_score (post-rerank) over rrf_score (pre-rerank).
    """
    rs= item.get("reranker_score")
    if rs is not None:
        return rs
    return item.get("rrf_score", 0.0)

def strip_grading_tail(arabic_text: str) -> str:
    """Cut the compiler's grading note (Tirmidhi: "قال ابو عيسي هذا حديث حسن صحيح ...").

    The note is shared by thousands of unrelated hadiths, so leaving it in makes
    extract_matn anchor on it and the dedup treat unrelated hadiths as duplicates.
    """
    cut= len(arabic_text)
    for match in GRADING_TAIL_RE.finditer(arabic_text):
        if match.start() >= len(arabic_text) * 0.3:
            cut= match.start()
            break
    return arabic_text[:cut]


def get_hadith_tokens(chunk: dict) -> frozenset:
    arabic_text= chunk.get("arabic_text_normalized") or chunk.get("arabic_text", "")
    matn, _= extract_matn(strip_grading_tail(arabic_text))
    return frozenset(arabic_tokenize(matn, remove_stopwords=True))


def jaccard(set_a: frozenset, set_b: frozenset) -> float:
    if not set_a and not set_b:
        return 1.0
    shared= len(set_a & set_b)
    total= len(set_a | set_b)
    return shared / total if total > 0 else 0.0


def is_duplicate_matn(tokens_a: frozenset, tokens_b: frozenset, threshold: float= HADITH_JACCARD_THRESHOLD) -> bool:
    """Same hadith? Jaccard on matn tokens, or one matn (largely) contained in the other
    (abridged / extended narrations of the same report)."""
    if jaccard(tokens_a, tokens_b) >= threshold:
        return True
    shorter, longer= (tokens_a, tokens_b) if len(tokens_a) <= len(tokens_b) else (tokens_b, tokens_a)
    if len(shorter) >= 4 and shorter.issubset(longer):
        return True
    # high containment ratio -> extended versions
    if len(shorter) >= 4 and len(shorter & longer) / len(shorter) >= 0.75:
        return True
    # moderate overlap
    return len(shorter) >= 5 and len(shorter & longer) / len(shorter) >= 0.60


def deduplicate_hadiths(scored_results: list, threshold: float= HADITH_JACCARD_THRESHOLD, is_english: bool= False,) -> list:
    """Remove near-duplicate hadiths using Jaccard similarity on matn tokens.

    Non-hadith results pass through unchanged.
    Catches same-matn hadiths across different books (Bukhari + Muslim narrating
    the same hadith with slightly different isnads but identical matn).
    Also catches abridged cross-book narrations via subset containment.
    """
    if is_english:
        active_threshold = HADITH_JACCARD_THRESHOLD_ENGLISH
    else:
        active_threshold = threshold
    kept= []
    kept_token_sets= []
    kept_hadith_pos= []   # index in `kept` of each entry of kept_token_sets

    for item in scored_results:
        if item["source_type"] not in HADITH_SOURCE_TYPES:
            kept.append(item)
            continue

        candidate_tokens= get_hadith_tokens(item["data"])
        is_dupe= False
        dupe_of= -1

        for seen_idx, seen in enumerate(kept_token_sets):
            dupe_of= kept_hadith_pos[seen_idx]
            if is_duplicate_matn(candidate_tokens, seen, active_threshold):
                is_dupe= True
                break

        if not is_dupe:
            kept_hadith_pos.append(len(kept))
            kept.append(item)
            kept_token_sets.append(candidate_tokens)
        elif book_priority(item["chunk_id"]) < book_priority(kept[dupe_of]["chunk_id"]):
            # same hadith in a more authoritative collection -> show that one, at the better slot/score
            replaced= kept[dupe_of]
            promoted= dict(item)
            for score_key in ("rrf_score", "reranker_score", "fusion_score"):
                scores= [x[score_key] for x in (item, replaced) if isinstance(x.get(score_key), (int, float))]
                if scores:
                    promoted[score_key]= max(scores)
            kept[dupe_of]= promoted

    return kept


# when the same hadith is in several books, the result shows the most authoritative one
HADITH_BOOK_PRIORITY= {"bukhari": 0, "muslim": 1, "abudawud": 2, "tirmidhi": 3}


def book_priority(chunk_id: str) -> int:
    match= re.match(r"H_eng-([a-z]+)_", chunk_id or "")
    return HADITH_BOOK_PRIORITY.get(match.group(1), 9) if match else 9


def dedup_identical_quran_ayahs(results: list, is_narrative: bool= False, by_reranker_score: bool= False) -> list:
    """Remove redundant Quran results when both a standalone ayah and a passage
    covering that same ayah are present. Keeps whichever scored better.

    For non-narrative: large passages always lose to the focused standalone ayah.
    For narrative: large passages only lose when the standalone ayah is 2x better.
    by_reranker_score: scores are cross-encoder scores (post-rerank) -> for normal-size
    windows the higher score simply wins, without the RRF-era bias towards passages.
    """
    if is_narrative:
        large_threshold = PASSAGE_LARGE_THRESHOLD_NARRATIVE
    else:
        large_threshold = PASSAGE_LARGE_THRESHOLD_NORMAL

    # build passage -> member ayah set map
    passage_to_members: dict[str, set]= {}
    for result in results:
        if result["source_type"] != QURAN_PASSAGE:
            continue
        pid= result["data"].get("chunk_id", "")
        member_ids = set()
        members_list = result["data"].get("members", [])
        for member in members_list:
            member_id = member.get("chunk_id", "")
            if member_id != "":
                member_ids.add(member_id)
        if pid and member_ids:
            passage_to_members[pid]= member_ids

    # build ayah -> best-scoring passage that covers it
    ayah_to_best_passage: dict[str, str]= {}
    for result in results:
        if result["source_type"] != QURAN_PASSAGE:
            continue
        pid= result["data"].get("chunk_id", "")
        current_passage_score = get_result_score(result)
        for ayah_id in passage_to_members.get(pid, set()):
            if ayah_id not in ayah_to_best_passage:
                ayah_to_best_passage[ayah_id]= pid
            else:
                existing_pid= ayah_to_best_passage[ayah_id]
                existing_score = 0
                for x in results:
                    if x["data"].get("chunk_id") == existing_pid:
                        existing_score = get_result_score(x)
                        break
                if current_passage_score > existing_score:
                    ayah_to_best_passage[ayah_id] = pid

    ids_to_drop: set[str]= set()

    for result in results:
        if result["source_type"] != QURAN_TAFSIR:
            continue

        ayah_id= result["data"].get("chunk_id", "")
        covering_pid= ayah_to_best_passage.get(ayah_id)
        if not covering_pid:
            continue

        passage_item = None
        for x in results:
            if x["data"].get("chunk_id") == covering_pid:
                passage_item = x
                break
        if passage_item is None:
            continue

        ayah_score= get_result_score(result)
        passage_score= get_result_score(passage_item)
        window= passage_item["data"].get("window_size", len(passage_item["data"].get("members", [])))

        if window >= large_threshold:
            if is_narrative:
                if ayah_score > passage_score * 2.0:
                    ids_to_drop.add(covering_pid)
            else:
                ids_to_drop.add(covering_pid)
        elif by_reranker_score:
            ids_to_drop.add(covering_pid if ayah_score >= passage_score else ayah_id)
        elif window >= 5:
            if ayah_score > passage_score * 1.20:
                ids_to_drop.add(covering_pid)
            else:
                ids_to_drop.add(ayah_id)
        else:
            if ayah_score > passage_score * 1.50:
                ids_to_drop.add(covering_pid)
            else:
                ids_to_drop.add(ayah_id)

    surviving_results = []
    for r in results:
        chunk_id = r["data"].get("chunk_id")
        if chunk_id not in ids_to_drop:
            surviving_results.append(r)

    # text-level dedup: drop standalone ayahs whose text is already in a surviving passage
    seen_texts: set= set()
    for result in surviving_results:
        if result["source_type"] != QURAN_PASSAGE:
            continue
        members = result.get("data", {}).get("members", [])
        for member in members:
            text = member.get("arabic_text_normalized", "")
            if text == "":
                text = member.get("arabic_text", "")
            text = text.strip()
            if text != "":
                seen_texts.add(text)

    deduped= []
    for result in results:
        if result["source_type"] != QURAN_TAFSIR:
            deduped.append(result)
            continue
        data = result.get("data", {})
        norm_text = data.get("arabic_text_normalized", "")
        if norm_text == "":
            norm_text = data.get("arabic_text", "")
        norm_text = norm_text.strip()
        if not norm_text or norm_text not in seen_texts:
            deduped.append(result)
            seen_texts.add(norm_text)

    return deduped


def dedup_quran_passage_overlap(results: list, query_type: str= "", by_reranker_score: bool= False) -> list:
    """Remove overlapping Quran passages post-reranking.
    When two passages cover the same ayahs, the lower-scoring one is dropped.

    Non-narrative: large passages are always dropped when they overlap with a shorter one.
    Narrative: thresholds are permissive (0.60 ratio) so consecutive story windows coexist.
    """
    is_narrative= (query_type == QTYPE_NARRATIVE)
    if is_narrative:
        large_threshold = PASSAGE_LARGE_THRESHOLD_NARRATIVE
    else:
        large_threshold = PASSAGE_LARGE_THRESHOLD_NORMAL

    score_by_id: dict[str, float]= {}
    for result in results:
        chunk_id= (result.get("data") or {}).get("chunk_id") or (result.get("chunk") or {}).get("chunk_id")
        if chunk_id:
            score_by_id[chunk_id]= get_result_score(result)

    def get_chunk_id(result: dict) -> str | None:
        return ((result.get("data") or {}).get("chunk_id")
                 or (result.get("chunk") or {}).get("chunk_id")
                 or result.get("chunk_id"))

    def get_passage_coords(result: dict) -> tuple:
        for src in (result.get("data") or {}, result.get("chunk") or {}):
            surah_id= src.get("surah_id")
            start_ayah= src.get("start_ayah")
            end_ayah= src.get("end_ayah")
            window_size= src.get("window_size")
            if surah_id is not None and start_ayah is not None and end_ayah is not None:
                if window_size is not None:
                    final_window = window_size
                else:
                    final_window = end_ayah - start_ayah + 1
                return surah_id, start_ayah, end_ayah, final_window
        return None, None, None, None

    passage_to_ayah_ids: dict[str, set]= {}
    standalone_ayah_ids: set= set()
    anchor_ayah_ids: set= set()
    anchor_by_id: dict= {}

    for result in results:
        chunk_id= get_chunk_id(result)
        if result["source_type"] == QURAN_PASSAGE:
            data= result.get("data") or {}
            ayah_ids= set(data.get("member_ids", []))
            if not ayah_ids:
                members_src= data.get("members") or (result.get("chunk") or {}).get("members") or []
                ayah_ids = set()
                for member in members_src:
                    current_chunk_id = member.get("chunk_id", "")
                    ayah_ids.add(current_chunk_id)
                ayah_ids.discard("")
            passage_to_ayah_ids[chunk_id]= ayah_ids
        elif result["source_type"] == QURAN_TAFSIR:
            standalone_ayah_ids.add(chunk_id)
            if result.get("anchor_injected", False):
                anchor_ayah_ids.add(chunk_id)
                anchor_by_id[chunk_id]= result

    ids_to_drop: set= set()

    for result in results:
        if result["source_type"] != QURAN_PASSAGE:
            continue

        pid= get_chunk_id(result)
        passage_score= score_by_id.get(pid, get_result_score(result))
        data= result.get("data") or {}
        window_size= (data.get("window_size")
                      or len(data.get("members") or [])
                      or (result.get("chunk") or {}).get("window_size")
                      or 1)
        passage_ayahs= passage_to_ayah_ids.get(pid, set())
        overlapping= passage_ayahs & standalone_ayah_ids

        if not overlapping:
            if not is_narrative:
                noise_threshold= large_threshold + 5
                if window_size >= noise_threshold and passage_score < 0.15:
                    ids_to_drop.add(pid)
            continue

        for ayah_id in overlapping:
            if ayah_id in anchor_ayah_ids:
                continue

            ayah_score= score_by_id.get(ayah_id, 0)

            if window_size >= large_threshold:
                if is_narrative:
                    if ayah_score > passage_score * 2.0:
                        ids_to_drop.add(pid)
                        break
                else:
                    ids_to_drop.add(pid)
                    break
            elif by_reranker_score:
                # cross-encoder scores are comparable across units -> the better-scored one stays
                if ayah_score >= passage_score:
                    ids_to_drop.add(pid)
                    break
                ids_to_drop.add(ayah_id)
            elif window_size >= 5:
                if passage_score >= ayah_score + 0.25:
                    ids_to_drop.add(ayah_id)
                else:
                    ids_to_drop.add(pid)
                    break
            else:
                if ayah_score > passage_score + 0.3:
                    ids_to_drop.add(pid)
                    break
                else:
                    ids_to_drop.add(ayah_id)

        # extra check: large non-narrative passages near anchor ayahs
        if not is_narrative and window_size >= large_threshold and pid not in ids_to_drop:
            p_surah, p_start, _, _= get_passage_coords(result)
            for anchor_id, anchor_result in anchor_by_id.items():
                a_data= anchor_result.get("data") or {}
                if a_data.get("surah_id") != p_surah:
                    continue
                anchor_ayah_num= a_data.get("ayah_id", 0)
                if p_start is not None and abs(p_start - anchor_ayah_num) <= 30:
                    if score_by_id.get(anchor_id, 0) >= passage_score - 0.5:
                        ids_to_drop.add(pid)
                        break

    surviving = []
    for result in results:
        current_chunk_id = get_chunk_id(result)
        if current_chunk_id not in ids_to_drop:
            surviving.append(result)

    # among surviving passages, remove those that fully contain or heavily overlap with a higher-scoring sibling
    quran_passages_only = []
    for result in surviving:
        if result["source_type"] == QURAN_PASSAGE:
            quran_passages_only.append(result)

    surviving_passages = sorted(quran_passages_only, key=get_result_score, reverse=True)
    non_passages = []
    for result in surviving:
        if result["source_type"] != QURAN_PASSAGE:
            non_passages.append(result)

    accepted_passages= []
    for candidate in surviving_passages:
        candidate_surah, candidate_start, candidate_end, _= get_passage_coords(candidate)
        is_redundant= False

        for accepted in accepted_passages:
            accepted_surah, accepted_start, accepted_end, _= get_passage_coords(accepted)

            if candidate_surah is None or accepted_surah is None or candidate_surah != accepted_surah:
                continue

            overlap_count= max(0, min(candidate_end, accepted_end) - max(candidate_start, accepted_start) + 1)
            shorter_span= min(candidate_end - candidate_start + 1, accepted_end - accepted_start + 1)

            fully_inside= ((candidate_start >= accepted_start and candidate_end <= accepted_end) or (accepted_start >= candidate_start and accepted_end <= candidate_end))
            if fully_inside:
                is_redundant= True
                break

            candidate_span= candidate_end - candidate_start + 1
            accepted_span= accepted_end - accepted_start + 1
            both_short= (candidate_span <= 5 and accepted_span <= 5)
            one_short= (candidate_span <= 5 or accepted_span <= 5)
            short_span= min(candidate_span, accepted_span)
            one_short_redundant= (one_short and overlap_count >= 1
                                  and (short_span <= 0 or overlap_count / short_span >= 0.33))
            if not is_narrative and overlap_count >= 1 and (both_short or one_short_redundant):
                is_redundant= True
                break

            max_ratio= 0.60 if is_narrative else PASSAGE_OVERLAP_THRESHOLD
            if shorter_span > 0 and (overlap_count / shorter_span) > max_ratio:
                is_redundant= True
                break

        if not is_redundant:
            accepted_passages.append(candidate)

    final= non_passages + accepted_passages
    final.sort(key=get_result_score, reverse=True)
    return final


def cap_same_stem_ayahs(results: list, query_tokens: list, query_type: str= "") -> list:
    """Prevent one query stem from flooding results with near-identical ayahs.
    Anchor results (anchor_injected=True) always bypass this cap.
    """
    if not query_tokens:
        return results

    is_narrative= (query_type == QTYPE_NARRATIVE)
    if is_narrative:
        total_ayah_cap = MAX_TOTAL_QURAN_AYAHS_NARRATIVE
        per_stem_cap = MAX_AYAHS_PER_STEM + 2
    else:
        total_ayah_cap = MAX_TOTAL_QURAN_AYAHS
        per_stem_cap = MAX_AYAHS_PER_STEM

    kept= []
    stem_counts= {}
    total_ayahs= 0

    for item in results:
        if item["source_type"] != QURAN_TAFSIR:
            kept.append(item)
            continue

        if item.get("anchor_injected", False):
            kept.append(item)
            total_ayahs += 1
            continue

        if total_ayahs >= total_ayah_cap:
            continue

        ayah_tokens= set(arabic_tokenize(item["data"].get("arabic_text_normalized", ""), remove_stopwords=True))
        matched_stems = []
        for token in query_tokens:
            if token in ayah_tokens:
                matched_stems.append(token)

        if not matched_stems:
            kept.append(item)
            total_ayahs += 1
            continue

        top_stem= matched_stems[0]
        times_seen= stem_counts.get(top_stem, 0)

        if times_seen < per_stem_cap:
            kept.append(item)
            stem_counts[top_stem]= times_seen + 1
            total_ayahs += 1

    return kept


def cap_same_surah_results(candidates: list[dict], max_per_surah: int= 4) -> list[dict]:
    """Limit results from any single surah.
    Excess results are deferred to the end (not dropped) for potential backfill.
    """
    surah_counts: Counter= Counter()
    for candidate in candidates:
        data= candidate.get("data", {})
        if candidate.get("source_type") in QURAN_SOURCE_TYPES:
            sid= data.get("surah_id")
            if sid is not None:
                surah_counts[sid] += 1

    exceeds_limit = False
    for count in surah_counts.values():
        if count > max_per_surah:
            exceeds_limit = True
            break

    if exceeds_limit == False:
        return candidates

    kept: list[dict]= []
    deferred:list[dict]= []
    per_surah: dict[int, int]= {}

    for candidate in candidates:
        data= candidate.get("data", {})
        if candidate.get("source_type") in QURAN_SOURCE_TYPES:
            surah_id= data.get("surah_id")
            if surah_id is not None:
                count= per_surah.get(surah_id, 0)
                if count >= max_per_surah:
                    deferred.append(candidate)
                    continue
                per_surah[surah_id]= count + 1
        kept.append(candidate)

    return kept + deferred
