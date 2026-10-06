"""
RRF (Reciprocal Rank Fusion) + score adjustments + deduplication.

Takes dense and BM25 results, merges them using weighted RRF, applies
source-type penalties and boosts, runs deduplication, then returns top-N
candidates for the reranker.

RRF formula:  score(d) = sum_i [ weight_i / (k + rank_i(d)) ]
"""

import re
import logging
from collections import defaultdict

from config import (FUSION_GUARANTEE_TOP_EACH, RERANK_CANDIDATE_CAP, RRF_K, FUSION_TOP_K, PASSAGE_OVERLAP_THRESHOLD, HADITH_CLUSTER_RRF_PENALTY, BM25_RANK1_BOOST_MULTIPLIER,
                    QTYPE_DEFINITIONAL, QURAN_TAFSIR_SECONDARY_PENALTY, HADITH_CLUSTER_FIQH_PENALTY, PASSAGE_LARGE_THRESHOLD_DEFINITIONAL,
                    BM25_ONLY_FIQH_SCORE_CAP, TAIL_DROP_RATIO, TAIL_ABS_FLOOR, MIN_TAIL_POOL_SIZE, PRE_RERANK_QURAN_DEDUP, QTYPE_FIQH, QTYPE_NARRATIVE,
                    PASSAGE_LARGE_THRESHOLD_NORMAL, PASSAGE_LARGE_THRESHOLD_NARRATIVE, QURAN_SOURCE_TYPES, QTYPE_THEMATIC,
                    QTYPE_AR_KEYWORD, QTYPE_EXACT_AR, HADITH_SOURCE_TYPES, QURAN_TAFSIR, QURAN_PASSAGE, HADITH, HADITH_CLUSTER, )
from .helpers import (deduplicate_hadiths, dedup_identical_quran_ayahs, dedup_quran_passage_overlap, cap_same_stem_ayahs,cap_same_surah_results)
from .retriever import RetrieverOutput
from .constants import EVENT_INTENT_TOKENS, ECLIPSE_TOKENS, MILITARY_TOKENS, PROPHET_NAMES, REFERENCE_ONLY_EN_RE
from .classifier import normalize_arabic
from indexes.faiss_index import get_chunk



logger= logging.getLogger(__name__)

def fuse(retriever_output: RetrieverOutput, query_type: str= "", query_lang: str= "", query_tokens: list= None,
         strict_scope_types: frozenset | None= None, top_k_override: int | None= None,) -> list[dict]:
    """Merge dense + BM25 results using weighted RRF, apply score adjustments,
    run deduplication, and return the top-N candidates for the reranker.
    """
    dense_results= retriever_output.dense_results
    bm25_results= retriever_output.bm25_results
    dense_weight= retriever_output.dense_weight
    bm25_weight= retriever_output.bm25_weight

    is_fiqh= (query_type == QTYPE_FIQH)
    is_definitional= (query_type == QTYPE_DEFINITIONAL)
    is_narrative= (query_type == QTYPE_NARRATIVE)

    logger.debug(
        f"[FUSION] type={query_type} | dense={len(dense_results)} | "
        f"bm25={len(bm25_results)} | weights=({dense_weight:.2f}, {bm25_weight:.2f})"
    )

    # compute weighted RRF scores
    scores: dict[str, float]= defaultdict(float)
    meta: dict[str, dict]= {}

    for result in dense_results:
        chunk_id= result["chunk_id"]
        rank= result["rank"]
        scores[chunk_id] += dense_weight / (RRF_K + rank)
        if chunk_id not in meta:
            meta[chunk_id]= {"chunk_id": chunk_id,
                             "source_type": result["source_type"],
                             "dense_rank":  rank,
                             "bm25_rank":   None,}
        else:
            meta[chunk_id]["dense_rank"]= rank

    for result in bm25_results:
        chunk_id= result["chunk_id"]
        rank= result["rank"]
        scores[chunk_id] += bm25_weight / (RRF_K + rank)
        if chunk_id not in meta:
            meta[chunk_id]= {"chunk_id": chunk_id,
                             "source_type": result["source_type"],
                             "dense_rank":  None,
                             "bm25_rank":   rank,}
        else:
            meta[chunk_id]["bm25_rank"]= rank
        if result.get("anchor_injected"):
            meta[chunk_id]["anchor_injected"]= True

    # hadiths whose translation is only "See translation for hadith 484 above" have nothing to show
    for chunk_id in [cid for cid, m in meta.items() if m["source_type"] == HADITH]:
        chunk_data= get_chunk(chunk_id) or {}
        english= (chunk_data.get("english_text") or "").strip()
        if english and len(english) < 80 and REFERENCE_ONLY_EN_RE.search(english):
            del meta[chunk_id]
            scores.pop(chunk_id, None)

    # score adjustments
    if is_narrative:
        large_window_thresh= PASSAGE_LARGE_THRESHOLD_NARRATIVE
    else:
        large_window_thresh= PASSAGE_LARGE_THRESHOLD_NORMAL

    # detect event intent
    is_event_intent= False
    event_hits: frozenset= frozenset()
    quran_only_scope = False
    if strict_scope_types is not None:
        is_strictly_quran = strict_scope_types.issubset(QURAN_SOURCE_TYPES)
        if is_strictly_quran:
            quran_only_scope = True

    if query_tokens and query_type in (QTYPE_THEMATIC, QTYPE_NARRATIVE) and not quran_only_scope:
        norm_tokens= frozenset(normalize_arabic(token) for token in query_tokens)
        event_hits= norm_tokens & EVENT_INTENT_TOKENS
        if event_hits:
            if query_type == QTYPE_NARRATIVE:
                if event_hits & MILITARY_TOKENS:
                    is_event_intent= True
            else:
                is_event_intent= True
            if is_event_intent:
                logger.debug(f"[FUSION] Event intent detected: {event_hits}")

    # narrative entity tokens for mismatch penalties
    narrative_key_tokens: frozenset= frozenset()
    narrative_entity_tokens: frozenset= frozenset()
    if is_narrative and query_tokens:
        narrative_key_tokens= frozenset(normalize_arabic(token) for token in query_tokens if len(token) >= 2)
        narrative_entity_tokens= frozenset(token for token in narrative_key_tokens if token in PROPHET_NAMES)

    # find BM25 rank-1 chunk (for the rank-1 boost)
    bm25_top1_id= None
    if query_type in (QTYPE_AR_KEYWORD, QTYPE_EXACT_AR, QTYPE_DEFINITIONAL, QTYPE_FIQH):
        for chunk_id, m in meta.items():
            if m.get("bm25_rank") == 1:
                bm25_top1_id= chunk_id
                break

    # apply per-chunk score adjustments
    for chunk_id, m in meta.items():
        source_type= m["source_type"]

        if source_type == HADITH_CLUSTER:
            if is_fiqh:
                scores[chunk_id] *= HADITH_CLUSTER_FIQH_PENALTY
            else:
                scores[chunk_id] *= HADITH_CLUSTER_RRF_PENALTY

        # floating fragment penalty -> very short hadiths that reference something ("بمثله")
        # are essentially empty and should be ranked low
        if source_type in HADITH_SOURCE_TYPES:
            chunk_data= get_chunk(chunk_id)
            if chunk_data is not None:
                ar_text= chunk_data.get("arabic_text", "")
                from .helpers import extract_matn
                matn, _= extract_matn(ar_text)
                matn_words= matn.split()

                if len(matn_words) < 15:
                    is_fragment= any(w in matn for w in ["بمثله", "بنحوه", "نحوه", "بمثل"])
                    if is_fragment:
                        scores[chunk_id] *= 0.15
                        logger.debug(f"[FUSION] Floating reference hadith penalized: {chunk_id}")

        if is_event_intent:
            if source_type == HADITH:
                is_eclipse= False
                if "اسراء" in event_hits or "معراج" in event_hits:
                    chunk_data= get_chunk(chunk_id)
                    if chunk_data is not None:
                        hadith_text= normalize_arabic(chunk_data.get("arabic_text", "") + " " + chunk_data.get("english_text", "")).lower()
                        is_eclipse= any(token in hadith_text for token in ECLIPSE_TOKENS)

                if is_eclipse:
                    scores[chunk_id] *= 0.35
                    meta[chunk_id]["narrative_mismatch"]= True
                    logger.debug(f"[FUSION] Eclipse hadith penalised for Isra/Miraj query: {chunk_id}")
                else:
                    scores[chunk_id] *= 1.4

            elif source_type in QURAN_SOURCE_TYPES:
                chunk_data= get_chunk(chunk_id)
                window= 1
                if chunk_data is not None and source_type == QURAN_PASSAGE:
                    window= chunk_data.get("window_size", len(chunk_data.get("members", [])))
                if window >= PASSAGE_LARGE_THRESHOLD_NORMAL:
                    scores[chunk_id] *= 0.65
                    logger.debug(f"[FUSION] Event-intent large-quran-window penalty (w={window}): {chunk_id}")

        # tafsir ayahs are secondary for most query types
        if source_type == QURAN_TAFSIR:
            if query_type not in (QTYPE_AR_KEYWORD, QTYPE_EXACT_AR):
                scores[chunk_id] *= QURAN_TAFSIR_SECONDARY_PENALTY

        # passage window penalties (non-narrative only)
        if source_type == QURAN_PASSAGE and not is_narrative:
            chunk_data= get_chunk(chunk_id)
            if chunk_data:
                window= chunk_data.get("window_size", len(chunk_data.get("members", [])))

                if is_definitional:
                    # definitional queries legitimately need 3-5 ayah windows
                    if window > PASSAGE_LARGE_THRESHOLD_DEFINITIONAL:
                        excess= window - PASSAGE_LARGE_THRESHOLD_DEFINITIONAL
                        factor= max(0.5, 0.95 - excess * 0.05)
                        scores[chunk_id] *= factor
                        logger.debug(f"[FUSION] Definitional window penalty: {chunk_id} w={window} f={factor:.2f}")
                elif window >= large_window_thresh:
                    scores[chunk_id] *= 0.8

        # anchor-tail penalty: if the anchor ayah sits in the last third of the window,
        # the leading ayahs are off-topic padding
        if source_type == QURAN_PASSAGE and (is_definitional or is_fiqh):
            chunk_data= get_chunk(chunk_id)
            if chunk_data:
                members= chunk_data.get("members", [])
                window= chunk_data.get("window_size", len(members))
                if window >= 4 and members:
                    dense_ids= {r["chunk_id"] for r in dense_results}
                    anchor_pos = None
                    for pos, member in enumerate(members):
                        current_chunk_id = member.get("chunk_id")
                        if current_chunk_id in dense_ids:
                            anchor_pos = pos
                            break
                    if anchor_pos is not None and anchor_pos >= (window * 2 // 3):
                        factor= max(0.55, 0.85 - (anchor_pos / window) * 0.35)
                        scores[chunk_id] *= factor
                        logger.debug(f"[FUSION] Anchor-tail penalty: {chunk_id} pos={anchor_pos}/{window} f={factor:.2f}")

        # narrative entity mismatch penalties
        if is_narrative and narrative_key_tokens:
            if source_type in QURAN_SOURCE_TYPES:
                chunk_data= get_chunk(chunk_id)
                if chunk_data:
                    passage_text= normalize_arabic(chunk_data.get("arabic_text", "") + " " +
                                                   chunk_data.get("english_translation", "") + " " +
                                                   chunk_data.get("arabic_tafsir", "")).lower()
                    check_tokens= narrative_entity_tokens if narrative_entity_tokens else narrative_key_tokens
                    matching = 0
                    for token in check_tokens:
                        if token in passage_text:
                            matching += 1

                    if matching == 0 and len(check_tokens) >= 1:
                        scores[chunk_id] *= 0.3
                        meta[chunk_id]["narrative_mismatch"]= True
                        logger.debug(f"[FUSION] Narrative mismatch (0 matches): {chunk_id}")

            elif source_type == HADITH:
                chunk_data= get_chunk(chunk_id)
                if chunk_data and narrative_entity_tokens:
                    from .helpers import extract_matn, strip_english_isnad
                    matn, _= extract_matn(chunk_data.get("arabic_text", ""))
                    clean_en= strip_english_isnad(chunk_data.get("english_text", ""))
                    hadith_text= normalize_arabic(matn + " " + clean_en).lower()
                    if sum(1 for t in narrative_entity_tokens if t in hadith_text) == 0:
                        scores[chunk_id] *= 0.35
                        meta[chunk_id]["narrative_mismatch"]= True
                        logger.debug(f"[FUSION] Narrative entity-absent hadith penalty: {chunk_id}")

        # BM25 rank-1 boost for keyword/definitional/fiqh queries
        if chunk_id == bm25_top1_id:
            dense_r= m.get("dense_rank")
            if is_fiqh:
                if dense_r is not None and dense_r <= 30:
                    scores[chunk_id] *= BM25_RANK1_BOOST_MULTIPLIER
            elif is_definitional:
                scores[chunk_id] *= BM25_RANK1_BOOST_MULTIPLIER
            else:
                if dense_r is None or dense_r <= 30:
                    scores[chunk_id] *= BM25_RANK1_BOOST_MULTIPLIER

        # fiqh BM25-only cap: prevents keyword-match noise from polluting the reranker
        if is_fiqh and m.get("dense_rank") is None and m.get("bm25_rank") is not None:
            if scores[chunk_id] > BM25_ONLY_FIQH_SCORE_CAP:
                scores[chunk_id]= BM25_ONLY_FIQH_SCORE_CAP
                logger.debug(f"[FUSION] Fiqh BM25-only cap: {chunk_id}")

        # definitional BM25-only noise cap for lower-ranked hits
        if (is_definitional and m.get("dense_rank") is None and m.get("bm25_rank") is not None and m["bm25_rank"] > 5):
            if scores[chunk_id] > BM25_ONLY_FIQH_SCORE_CAP:
                scores[chunk_id]= BM25_ONLY_FIQH_SCORE_CAP
                logger.debug(f"[FUSION] Definitional BM25-only noise cap (rank={m['bm25_rank']}): {chunk_id}")

    # sort descending by RRF score
    ranked= sorted(scores.keys(), key=lambda chunk_id: scores[chunk_id], reverse=True)

    # hard scope filter before BM25 floor
    if strict_scope_types:
        before= len(ranked)
        ranked= [chunk_id for chunk_id in ranked if meta[chunk_id]["source_type"] in strict_scope_types]
        if before - len(ranked):
            logger.debug(f"[FUSION] Strict scope filter removed {before - len(ranked)} chunks")

    # BM25 floor -> ensure strong keyword hits aren't drowned by dense-only results
    # skip for fiqh so BM25-only capped results don't bypass the cap via the floor
    if not is_fiqh:
        dense_floor= dense_weight / (RRF_K + 30)
        bm25_floor_top= 20 if is_definitional else 10
        for chunk_id in ranked:
            m= meta[chunk_id]
            if m.get("dense_rank") is None and m.get("bm25_rank") is not None:
                bm25_r= m["bm25_rank"]
                if bm25_r <= bm25_floor_top:
                    mult= 0.8 if is_definitional else (0.6 - (bm25_r - 1) * 0.05)
                    floor= dense_floor * mult
                    if scores[chunk_id] < floor:
                        scores[chunk_id]= floor

        ranked= sorted(ranked, key=lambda chunk_id: scores[chunk_id], reverse=True)

    # tail cutoff -> trim very weak candidates
    # narrative-mismatched items below the cutoff go to tail_reserve (not dropped)
    # so the backfill pool is never empty for story queries where 100+ ayahs
    # don't mention the prophet by name and get x0.3 penalties
    tail_reserve: list[str]= []
    if len(ranked) >= MIN_TAIL_POOL_SIZE:
        top_score= scores[ranked[0]] if ranked else 0.0
        tail_ratio= TAIL_DROP_RATIO / 2 if is_definitional else TAIL_DROP_RATIO
        cutoff= max(top_score * tail_ratio, TAIL_ABS_FLOOR)
        before= len(ranked)
        kept= []
        for chunk_id in ranked:
            if scores[chunk_id] >= cutoff:
                kept.append(chunk_id)
            elif meta[chunk_id].get("narrative_mismatch"):
                tail_reserve.append(chunk_id)
        trimmed= before - len(kept) - len(tail_reserve)
        ranked= kept
        if trimmed or tail_reserve:
            logger.debug(
                f"[FUSION] Tail cutoff: dropped {trimmed}, reserved {len(tail_reserve)} mismatch (cutoff={cutoff:.5f})"
            )

    # build merged list
    merged= []
    for chunk_id in ranked:
        entry= meta[chunk_id].copy()
        entry["rrf_score"]= scores[chunk_id]
        if meta[chunk_id].get("narrative_mismatch"):
            entry["narrative_mismatch"]= True
        merged.append(entry)

    for canditade in merged:
        canditade["data"]= get_chunk(canditade["chunk_id"]) or {}
        canditade["reranker_score"]= canditade["rrf_score"]
        canditade["fusion_score"]= canditade["rrf_score"]

    # deduplication
    is_english= (query_lang == "english")
    merged= deduplicate_hadiths(merged, is_english=is_english)

    if PRE_RERANK_QURAN_DEDUP:
        merged= dedup_identical_quran_ayahs(merged, is_narrative=is_narrative)

        if is_definitional or is_fiqh:
            merged= dedup_quran_passage_overlap(merged, query_type=query_type)

        if query_tokens:
            merged= cap_same_stem_ayahs(merged, query_tokens, query_type=query_type)

    # surah cap defers excess items to the end of the list, which pushed e.g. Q 2:183 past the
    # fusion cut-off behind two surah-2 passages -> applied after reranking instead
    if PRE_RERANK_QURAN_DEDUP and query_type not in (QTYPE_NARRATIVE, QTYPE_AR_KEYWORD):
        surah_cap= 2 if (is_definitional or is_fiqh) else 4
        merged.sort(key=lambda x: x.get("rrf_score", 0.0), reverse=True)
        merged= cap_same_surah_results(merged, max_per_surah=surah_cap)

    for canditade in merged:
        canditade.pop("reranker_score", None)

    if tail_reserve:
        for chunk_id in tail_reserve:
            entry= meta[chunk_id].copy()
            entry["rrf_score"]= scores[chunk_id]
            entry["narrative_mismatch"]= True
            entry["data"]= get_chunk(chunk_id) or {}
            entry["reranker_score"]= entry["rrf_score"]
            entry["fusion_score"]= entry["rrf_score"]
            merged.append(entry)
        logger.debug(f"[FUSION] Appended {len(tail_reserve)} tail-reserve candidates")

    effective_top_k= top_k_override if top_k_override is not None else FUSION_TOP_K
    result= merged[:effective_top_k]

    # each retriever's own top hits always reach the reranker: with keyword weights (dense 0.1) the
    # dense #1 for "حجاب عفة" - Q 24:31, "وليضربن بخمرهن على جيوبهن" - sat at fusion rank 165
    if FUSION_GUARANTEE_TOP_EACH > 0 and len(merged) > effective_top_k:
        def is_top(entry: dict) -> bool:
            dense_r, bm25_r= entry.get("dense_rank"), entry.get("bm25_rank")
            return (dense_r is not None and dense_r <= FUSION_GUARANTEE_TOP_EACH) or (bm25_r is not None and bm25_r <= FUSION_GUARANTEE_TOP_EACH)
        missing= [entry for entry in merged[effective_top_k:] if is_top(entry) and not entry.get("narrative_mismatch")]
        if missing:
            base= result[:max(0, effective_top_k - len(missing))]
            # inside the reranker's window (the pipeline reranks the first RERANK_CANDIDATE_CAP)
            insert_at= max(0, min(len(base), RERANK_CANDIDATE_CAP - len(missing)))
            result= base[:insert_at] + missing + base[insert_at:]
            logger.debug(f"[FUSION] Guaranteed {len(missing)} top retriever hits a reranker slot")

    logger.debug(f"[FUSION] Done | merged={len(merged)} -> returning {len(result)} (top_k={effective_top_k})")
    return result