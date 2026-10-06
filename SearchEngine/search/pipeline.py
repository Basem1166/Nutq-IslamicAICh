"""
Main search pipeline.

Stages:
  1. Classify -> query_type, scope, language, early_exit?
  2. Early exit -> return the exact matched chunk (named concept / direct reference).
                   Only early-exit results are allowed to have fewer than top_k items.
                   If the chunk is not found in the corpus, falls through to stage 3.
  3. Retrieve -> dense (FAISS) + BM25 candidates
  4. Fuse -> weighted RRF + passage dedup -> top-N
  5. Rerank -> cross-encoder -> top-K
  6. Filter -> scope, topic-misclassification, narrative mismatch, backfill
  7. Assemble -> attach metadata, build response

All non-early-exit queries are guaranteed to return top_k results.
The pipeline uses backfill, top-up, and a final emergency BM25 fill
in that order until top_k is reached.
"""
import logging
import time
from dataclasses import dataclass, field
import re
import copy
from itertools import zip_longest
from config import (COMPARATIVE_RERANK_QUERY, COMPARATIVE_BALANCE_MIN_EACH, COMPARATIVE_BALANCE_MIN_RATIO, COMPARATIVE_TAG_POOL, COMPARATIVE_TAG_MIN, COMPARATIVE_TAG_MARGIN, API_DEFAULT_TOP_K, API_MAX_TOP_K, SCOPE_ALL, SCOPE_QURAN, SCOPE_HADITH,
                    QTYPE_DIRECT_REF, QTYPE_NAMED, QTYPE_FIQH, QTYPE_THEMATIC, QTYPE_COMPARATIVE_CONCEPT,
                    QTYPE_DEFINITIONAL, QTYPE_NARRATIVE, QURAN_SOURCE_TYPES, HADITH_SOURCE_TYPES,
                    FUSION_TOP_K, FUSION_TOP_K_BY_TYPE, RERANKER_BM25_ONLY_THRESHOLD, RERANKER_FLOOR_SCORE,
                    RERANK_CANDIDATE_CAP, FIQH_MIN_RERANKER_SCORE, DEFINITIONAL_MIN_RERANKER_SCORE, QTYPE_AR_KEYWORD,
                    COMPARATIVE_COOCCURRENCE_BOOST, FUSION_TOP_K_BY_TYPE,
                    PAD_RESULTS_TO_TOP_K, MIN_RESULT_ABS_SCORE, MIN_RESULT_REL_SCORE, MIN_RESULTS_KEPT,
                    POST_RERANK_MAX_PER_SURAH, COMPARATIVE_MIN_SIDE_SCORE, RERANK_FUSION_BLEND,
                    SOURCE_BALANCE_MIN_EACH, SOURCE_BALANCE_MIN_RATIO, COMPARATIVE_CONCEPT_RESCORE)
from indexes.faiss_index import get_chunk
from search import classifier, retriever, fusion, reranker
from .reranker import format_chunk
from .helpers import dedup_quran_passage_overlap, deduplicate_hadiths, dedup_identical_quran_ayahs, cap_same_surah_results
from indexes import bm25_index
from .classifier import normalize_arabic, apply_comparative_support
from .constants import COMPARATIVE_STRONG_SIGNALS, COMPARATIVE_WEAK_SIGNALS, CONCEPT_SPLIT_PATTERN, COMPARATIVE_GLUE_WORDS


logger= logging.getLogger(__name__)


@dataclass
class SearchRequest:
    query: str
    top_k: int= API_DEFAULT_TOP_K
    scope: str | None= None


@dataclass
class SearchResponse:
    query_meta: dict
    results: list[dict]
    latency_ms: float
    error: str | None= None


def search(request: SearchRequest) -> SearchResponse:
    """Run the full search pipeline and return ranked results.

    query_meta includes the full decision trail so every routing decision
    can be inspected without touching the logs.
    """
    t_start= time.perf_counter()
    timings= {}

    top_k= max(1, min(request.top_k, API_MAX_TOP_K))

    try:
        # Stage 1: Classify
        t0= time.perf_counter()
        classification= classifier.classify(query=request.query, scope_override=request.scope)
        timings["classify_ms"]= round((time.perf_counter() - t0) * 1000, 1)

        query_meta= {"original_query": request.query,
                     "normalized_query": classification.normalized_query,
                     "detected_language": classification.language,
                     "query_type":classification.query_type,
                     "scope": classification.scope,
                     "early_exit": classification.early_exit,
                     "lexical_query": classification.lexical_query,
                     "arabic_supplement": getattr(classification, "arabic_supplement", ""),
                     "classifier_debug":  classification.debug,}

        logger.info(
            f"[PIPELINE] query='{request.query[:80]}' | "
            f"type={classification.query_type} | scope={classification.scope} | "
            f"lang={classification.language} | early_exit={classification.early_exit}"
        )

        # Stage 2: Early exit
        if classification.early_exit and classification.direct_result:
            results= handle_early_exit(classification.direct_result, top_k, classification.scope, classification.normalized_query)
            if results:
                latency= (time.perf_counter() - t_start) * 1000
                timings["total_ms"]= round(latency, 1)
                query_meta["stage_timings_ms"]= timings
                return SearchResponse(query_meta=query_meta, results=results, latency_ms=round(latency, 2))
            else:
                # chunk not in FAISS -> fall through to full pipeline
                query_meta["early_exit_fallback"]= True
                classification.early_exit= False
                if classification.query_type in (QTYPE_DIRECT_REF, QTYPE_NAMED):
                    classification.query_type= QTYPE_AR_KEYWORD
                    logger.warning(
                        f"[PIPELINE] Early exit chunk not found for "
                        f"'{classification.direct_result}' -> continuing as arabic_keyword"
                    )

        # Stage 3: Comparative branch (separate pipeline)
        if classification.query_type == "comparative":
            logger.debug("[PIPELINE] Routing to comparative pipeline")
            classification.request_scope= request.scope
            if request.scope:
                classification.user_scope_override= True
            results= run_comparative_pipeline(classification, top_k, t_start, query_meta, timings)
            latency= (time.perf_counter() - t_start) * 1000
            timings["total_ms"]= round(latency, 1)
            query_meta["stage_timings_ms"]= timings
            logger.info(
                f"[PIPELINE] DONE | type={classification.query_type} | scope={classification.scope} | "
                f"results={len(results)} | latency={latency:.0f}ms | "
                f"[classify={timings.get('classify_ms')}ms "
                f"retrieve={timings.get('retrieve_ms')}ms "
                f"rerank={timings.get('rerank_ms')}ms]"
            )
            return SearchResponse(query_meta=query_meta, results=results, latency_ms=round(latency, 2))

        # Stage 3: Retrieve
        t0= time.perf_counter()
        ret_output= retriever.retrieve(classification)
        timings["retrieve_ms"]= round((time.perf_counter() - t0) * 1000, 1)
        timings["dense_hits"]= len(ret_output.dense_results)
        timings["bm25_hits"]= len(ret_output.bm25_results)

        query_meta["bm25_tokens"]= getattr(ret_output, "bm25_tokens_used", [])
        query_meta["bm25_query_sent"]= getattr(ret_output, "bm25_query_sent", classification.lexical_query)

        logger.debug(
            f"[PIPELINE] Retrieved | dense={timings['dense_hits']} | "
            f"bm25={timings['bm25_hits']} | bm25_q='{query_meta['bm25_query_sent'][:60]}'"
        )

        # sparse BM25 fallback for arabic_keyword with very few hits
        if classification.query_type == QTYPE_AR_KEYWORD and len(ret_output.bm25_results) < 5:
            ret_output= run_arabic_keyword_bm25_fallback(classification, ret_output)

        # Stage 4: Fuse
        t0= time.perf_counter()
        query_tokens= classification.normalized_query.split()
        fusion_top_k= FUSION_TOP_K_BY_TYPE.get(classification.query_type, FUSION_TOP_K)

        candidates= fusion.fuse(ret_output, query_type=classification.query_type,
                                query_lang=classification.language, query_tokens=query_tokens,
                                strict_scope_types=getattr(classification, "strict_scope_types", None),
                                top_k_override=fusion_top_k,)

        timings["fuse_ms"]= round((time.perf_counter() - t0) * 1000, 1)
        timings["fusion_candidates"]= len(candidates)

        top5_records = []
        top5_candidates = candidates[:5]
        for candidate in top5_candidates:
            raw_rrf = candidate.get("rrf_score", 0)
            rounded_rrf = round(raw_rrf, 5)
            candidate_record = {"chunk_id": candidate["chunk_id"],
                                "source_type": candidate["source_type"],
                                "rrf_score": rounded_rrf,
                                "dense_rank": candidate.get("dense_rank"),
                                "bm25_rank": candidate.get("bm25_rank")}
            top5_records.append(candidate_record)
        query_meta["pre_rerank_top5"] = top5_records
        
        query_meta["fusion_candidate_count"]= len(candidates)

        if candidates:
            logger.debug(f"[PIPELINE] Fusion done | candidates={len(candidates)} | top_rrf={candidates[0].get('rrf_score', 0):.5f}")
        else:
            logger.debug("[PIPELINE] Fusion done | candidates=0")

        if not candidates:
            latency= (time.perf_counter() - t_start) * 1000
            timings["total_ms"]= round(latency, 1)
            query_meta["stage_timings_ms"]= timings
            return SearchResponse(query_meta=query_meta, results=[], latency_ms=round(latency, 2))

        # score-collapse fallback for arabic_keyword: re-run with balanced weights
        if classification.query_type == QTYPE_AR_KEYWORD and candidates[0].get("rrf_score", 0) < 0.003:
            logger.info(
                f"[PIPELINE] arabic_keyword score collapse (top_rrf={candidates[0].get('rrf_score', 0):.5f}) "
                "-> re-retrieving with balanced weights"
            )
            fallback_cls= copy.copy(classification)
            fallback_cls.query_type= QTYPE_THEMATIC

            t0= time.perf_counter()
            fb_ret= retriever.retrieve(fallback_cls)
            timings["retrieve_fallback_ms"]= round((time.perf_counter() - t0) * 1000, 1)

            fb_candidates= fusion.fuse(fb_ret, query_type=QTYPE_AR_KEYWORD, query_lang=classification.language,
                                       query_tokens=query_tokens, strict_scope_types=getattr(classification, "strict_scope_types", None),
                                       top_k_override=fusion_top_k,)
            if fb_candidates and fb_candidates[0].get("rrf_score", 0) > candidates[0].get("rrf_score", 0):
                candidates= fb_candidates
                query_meta["arabic_keyword_fallback"]= "balanced_weights"
                timings["fusion_candidates"]= len(candidates)
                logger.info("[PIPELINE] Fallback candidates accepted (better score)")

        # Stage 5: Rerank
        rerank_cap= pick_rerank_cap(classification, fusion_top_k)
        rerank_cands= candidates[:rerank_cap]
        reranker_query= pick_reranker_query(classification)

        timings["rerank_input_count"]= len(rerank_cands)
        query_meta["reranker_query"]= reranker_query

        logger.debug(f"[PIPELINE] Reranking {len(rerank_cands)} candidates | q='{reranker_query[:60]}'")

        t0= time.perf_counter()
        reranked= reranker.rerank(query=reranker_query, candidates=rerank_cands, top_k=len(rerank_cands))
        reranked= blend_with_fusion(reranked)
        timings["rerank_ms"]= round((time.perf_counter() - t0) * 1000, 1)

        if reranked:
            logger.debug(f"[PIPELINE] Reranker done | results={len(reranked)} | top={reranked[0]['reranker_score']:.4f}")
        else:
            logger.debug("[PIPELINE] Reranker returned 0 results")

        # reranker returned nothing -> fall back to fusion scores
        if not reranked and candidates:
            logger.warning(
                f"[PIPELINE] Reranker returned 0 results for '{request.query[:60]}' "
                f"({len(rerank_cands)} candidates entered). Falling back to fusion scores."
            )
            fallback= sorted(candidates, key=lambda c: c.get("rrf_score", 0), reverse=True)
            for rank_i, cand in enumerate(fallback[:top_k], start=1):
                cand["reranker_score"]= RERANKER_FLOOR_SCORE
                cand["final_rank"]= rank_i
                chunk_data= cand.get("data") or {}
                cand["chunk"]= format_chunk(chunk_data) if chunk_data else {}
            reranked= fallback[:top_k]
            query_meta["reranker_fallback"]= True

        # Stage 6: Post-rerank filters
        #
        # Order matters:
        #   1. Quality filters (bm25-artifact, narrative-mismatch, topic-misclassification)
        #   2. Scope enforcement  <- before backfill so the backfill pool is clean
        #   3. Dedup
        #   4. Backfill
        #   5. Second dedup pass

        # track BM25-artifact IDs before filter so they can be excluded from backfill later
        pre_bm25_ids = set()
        for r in reranked:
            pre_bm25_ids.add(r["chunk_id"])
        reranked = filter_bm25_only_artifacts(reranked)
        post_filter_ids = set()
        for r in reranked:
            post_filter_ids.add(r["chunk_id"])

        bm25_artifact_ids = pre_bm25_ids - post_filter_ids

        if classification.query_type == QTYPE_NARRATIVE:
            clean = []
            for r in reranked:
                if not r.get("narrative_mismatch"):
                    clean.append(r)
            dropped = len(reranked) - len(clean)
            if dropped > 0 and len(clean) >= 2:
                logger.debug(f"[PIPELINE] Narrative mismatch filter: removed {dropped}")
                reranked = clean
        misclassification_filtered_ids = set()
        requires_misclassification_filter = False
        active_min_score = 0.0
        if classification.query_type == QTYPE_FIQH:
            requires_misclassification_filter = True
            active_min_score = FIQH_MIN_RERANKER_SCORE
        elif classification.query_type == QTYPE_DEFINITIONAL:
            requires_misclassification_filter = True
            active_min_score = DEFINITIONAL_MIN_RERANKER_SCORE

        if requires_misclassification_filter:
            pre_misclassification_ids = set()
            for r in reranked:
                pre_misclassification_ids.add(r["chunk_id"])
            reranked = filter_topic_misclassification(reranked, min_score=active_min_score, relative_drop_ratio=0.08)
            post_misclassification_ids = set()
            for r in reranked:
                post_misclassification_ids.add(r["chunk_id"])
            misclassification_filtered_ids = pre_misclassification_ids - post_misclassification_ids

        # scope enforcement before backfill
        if request.scope:
            reranked= hard_scope_filter(reranked, request.scope)
        elif classification.scope != SCOPE_ALL:
            reranked= soft_scope_filter(reranked, classification.scope, min_score_to_keep_out_of_scope=0.35)

        # ayah-vs-passage decisions use reranker scores (fusion no longer dedups Quran units)
        is_narrative= classification.query_type == QTYPE_NARRATIVE
        reranked= dedup_identical_quran_ayahs(reranked, is_narrative=is_narrative, by_reranker_score=True)
        reranked= dedup_quran_passage_overlap(reranked, query_type=classification.query_type, by_reranker_score=True)
        if not is_narrative:
            reranked= cap_same_surah_results(reranked, max_per_surah=POST_RERANK_MAX_PER_SURAH)
        if classification.scope == SCOPE_ALL and not request.scope:
            reranked= balance_sources(reranked, top_k)
        reranked= reranked[:top_k]

        # backfill -> exclude misclassification-filtered and BM25-artifact candidates to break the filter->backfill cycle
        if len(reranked) < top_k:
            excluded= misclassification_filtered_ids | bm25_artifact_ids
            reranked= run_backfill(reranked, candidates, rerank_cap, top_k, reranker_query, classification, request, excluded_ids=excluded)

        # second dedup pass -> backfill can re-introduce items removed earlier
        if any(r.get("source_type") == "Quran_Passage" for r in reranked):
            reranked= dedup_quran_passage_overlap(reranked, query_type=classification.query_type, by_reranker_score=True)
        if any(r.get("source_type") in ("Hadith", "Hadith_Cluster") for r in reranked):
            is_english= getattr(classification, "language", "arabic") == "english"
            reranked= deduplicate_hadiths(reranked, is_english=is_english)

        # final top-up if second dedup pushed count below top_k (unscored filler -> off by default)
        if PAD_RESULTS_TO_TOP_K and len(reranked) < top_k:
            seen_ids= {r["chunk_id"] for r in reranked}

            # respect both explicit user scope and auto-detected scope
            effective_scope_for_topup= request.scope or classification.scope
            if effective_scope_for_topup and effective_scope_for_topup != SCOPE_ALL:
                allowed_for_topup= QURAN_SOURCE_TYPES if effective_scope_for_topup == SCOPE_QURAN else HADITH_SOURCE_TYPES
            else:
                allowed_for_topup= None

            for cand in candidates:
                if len(reranked) >= top_k:
                    break
                if cand["chunk_id"] in seen_ids:
                    continue
                if allowed_for_topup is not None:
                    if cand.get("source_type") not in allowed_for_topup:
                        continue
                item= cand.copy()
                if "chunk" not in item or not item["chunk"]:
                    item["chunk"]= format_chunk(cand.get("data") or {})
                if "reranker_score" not in item:
                    item["reranker_score"]= cand.get("rrf_score", RERANKER_FLOOR_SCORE)
                item["final_rank"]= len(reranked) + 1
                reranked.append(item)
                seen_ids.add(item["chunk_id"])

            if len(reranked) < top_k:
                effective_scope= request.scope or classification.scope
                reranked= emergency_bm25_fill(reranked, classification.normalized_query, effective_scope, top_k)

        # backfilled items are appended after the main list -> restore score order
        if not PAD_RESULTS_TO_TOP_K:
            reranked.sort(key=lambda r: r.get("reranker_score") or 0.0, reverse=True)
        reranked= apply_result_score_floor(reranked)
        for rank, item in enumerate(reranked, start=1):
            item["final_rank"]= rank

        # Stage 7: Assemble
        results= assemble_results(reranked)

        latency= (time.perf_counter() - t_start) * 1000
        timings["total_ms"]= round(latency, 1)
        query_meta["stage_timings_ms"]= timings

        logger.info(
            f"[PIPELINE] DONE | type={classification.query_type} | scope={classification.scope} | "
            f"results={len(results)} | latency={latency:.0f}ms | "
            f"[classify={timings.get('classify_ms')}ms "
            f"retrieve={timings.get('retrieve_ms')}ms "
            f"fuse={timings.get('fuse_ms')}ms "
            f"rerank={timings.get('rerank_ms')}ms]"
        )

        return SearchResponse(query_meta=query_meta, results=results, latency_ms=round(latency, 2))

    except Exception as e:
        latency= (time.perf_counter() - t_start) * 1000
        logger.exception(f"[PIPELINE] Error for query '{request.query}': {e}")
        return SearchResponse(query_meta={"original_query": request.query}, results=[], latency_ms=round(latency, 2), error=str(e),)


def pick_rerank_cap(classification, fusion_top_k: int) -> int:
    """Choose how many candidates go to the reranker.

    All query types use the same unified cap now that the reranker runs on a
    server. The cap is always kept below fusion_top_k so that candidates
    beyond the cap remain available as an unscored backfill pool.
    """
    return min(fusion_top_k, RERANK_CANDIDATE_CAP)


def pick_reranker_query(classification) -> str:
    """Build the query string for the cross-encoder.

    The cross-encoder gets the user's own query (after transliteration), not the
    enriched one: appended expansion terms dilute the question and measurably
    lower the score of the right passage (e.g. Q 2:183 for "تعريف الصيام وأركانه":
    0.049 -> 0.007). Enrichment stays in the retrieval stage only.
    Hard cap at 300 chars.
    """
    query= (getattr(classification, "rerank_query", "") or classification.normalized_query).strip()
    if len(query) > 300:
        query= query[:300].rsplit(" ", 1)[0]
    gloss= classifier.topic_gloss(query)
    if gloss:
        query= f"{query}: {gloss}"
    return query


def blend_with_fusion(reranked: list) -> list:
    """final = (1 - w) * cross-encoder score + w * fusion score scaled to [0, 1].

    The cross-encoder alone over-rates passages that share words with the query (Q 6:96 "and has made
    the night for rest" scored above Q 2:183 for "تعريف الصيام"); agreement of dense + BM25 retrieval is
    an independent signal. The raw cross-encoder score is kept in "cross_encoder_score".
    """
    if RERANK_FUSION_BLEND <= 0 or not reranked:
        return reranked
    # real RRF scores are < 1; injected canonical hints carry a 9999 placeholder -> count as the best
    real= [r.get("rrf_score") or 0.0 for r in reranked if (r.get("rrf_score") or 0.0) < 1.0]
    best_fusion= max(real) if real and max(real) > 0 else 1.0
    for r in reranked:
        ce= r.get("reranker_score") or 0.0
        fusion_norm= min(1.0, (r.get("rrf_score") or 0.0) / best_fusion)
        r["cross_encoder_score"]= ce
        r["reranker_score"]= (1 - RERANK_FUSION_BLEND) * ce + RERANK_FUSION_BLEND * fusion_norm
    reranked.sort(key=lambda r: r["reranker_score"], reverse=True)
    return reranked


def balance_sources(reranked: list, top_k: int) -> list:
    """For scope=all, keep at least SOURCE_BALANCE_MIN_EACH Quran and Hadith results in the top_k.

    A relevance judge saturates on topical text (ten purification hadiths at 0.97-0.99 pushed
    Q 5:6 and 4:43 out of "أحكام الطهارة قبل الصلاة"), but an answer that cites no ayah when strong
    Quran evidence exists - or no hadith when the Sunnah speaks to it - is incomplete. Only items
    scoring >= SOURCE_BALANCE_MIN_RATIO x the best score are promoted.
    """
    if SOURCE_BALANCE_MIN_EACH <= 0 or len(reranked) <= top_k:
        return reranked
    best= reranked[0].get("reranker_score") or 0.0
    floor= best * SOURCE_BALANCE_MIN_RATIO
    head, tail= list(reranked[:top_k]), list(reranked[top_k:])
    for group in (QURAN_SOURCE_TYPES, HADITH_SOURCE_TYPES):
        have= sum(1 for r in head if r.get("source_type") in group)
        promotable= [r for r in tail if r.get("source_type") in group and (r.get("reranker_score") or 0.0) >= floor]
        while have < SOURCE_BALANCE_MIN_EACH and promotable:
            # drop the weakest item of the over-represented source from the head
            victims= [i for i, r in enumerate(head) if r.get("source_type") not in group]
            other_count= len(victims)
            if not victims or other_count <= SOURCE_BALANCE_MIN_EACH:
                break
            victim_idx= victims[-1]
            tail.insert(0, head.pop(victim_idx))
            incoming= promotable.pop(0)
            tail.remove(incoming)
            head.append(incoming)
            have += 1
    head.sort(key=lambda r: r.get("reranker_score") or 0.0, reverse=True)
    return head + tail


def apply_result_score_floor(results: list) -> list:
    """Drop low-confidence tail results instead of padding to top_k.

    A result is kept when its reranker score is >= MIN_RESULT_ABS_SCORE and
    >= MIN_RESULT_REL_SCORE * best score. The first MIN_RESULTS_KEPT results are
    always kept so a weak-but-valid query never comes back empty.
    """
    if PAD_RESULTS_TO_TOP_K or not results:
        return results
    best= max(r.get("reranker_score") or 0.0 for r in results)
    threshold= max(MIN_RESULT_ABS_SCORE, MIN_RESULT_REL_SCORE * best)
    kept= [r for i, r in enumerate(results) if i < MIN_RESULTS_KEPT or (r.get("reranker_score") or 0.0) >= threshold]
    if len(kept) < len(results):
        logger.debug(f"[PIPELINE] Score floor {threshold:.4f}: dropped {len(results) - len(kept)} tail results")
    return kept

def run_arabic_keyword_bm25_fallback(classification, ret_output) -> object:
    """BM25 sparse fallback for arabic_keyword queries with very few hits.
    Tries progressively shorter prefix stems until we get at least 5 hits.
    """
    clean_query = normalize_arabic(classification.normalized_query.strip())
    q_words = clean_query.split()

    existing_ids = set()
    for r in ret_output.bm25_results:
        chunk_id = r.get("chunk_id")
        if chunk_id is not None:
            existing_ids.add(chunk_id)        
    augmented = False

    top_words = q_words[:4]

    for word in top_words:
        stems_to_try = []
        stems_to_try.append(word)
        if len(word) > 3:
            stems_to_try.append(word[1:])
        if len(word) > 4:
            stems_to_try.append(word[2:])
        for stem in stems_to_try:
            if len(stem) < 3:
                continue

            fallback_results = bm25_index.search(query=stem, scope=classification.scope, top_k=30)
            
            if fallback_results:
                for fb in fallback_results:
                    fb_id = fb.get("chunk_id")

                    if fb_id is not None and fb_id not in existing_ids:
                        ret_output.bm25_results.append(fb)
                        existing_ids.add(fb_id)
                    augmented = True
                
                break 
        if augmented:
            break
    
    if augmented:
        ret_output.bm25_results.sort(key=lambda x: x.get("score", 0), reverse=True)
        for rank, r in enumerate(ret_output.bm25_results, start=1):
            r["rank"] = rank
            
        logger.debug(f"[PIPELINE] arabic_keyword BM25 fallback: {len(ret_output.bm25_results)} results")
        
    return ret_output

def run_backfill(reranked: list, candidates: list, rerank_cap: int, top_k: int, reranker_query: str, classification,
                 request: SearchRequest, excluded_ids: set | None= None,) -> list:
    """Fill remaining result slots from the fusion pool when reranked < top_k.

    Pool 1: candidates beyond the rerank cap (never cross-encoder scored).
            These get a mini-batch rerank.
    Pool 2: candidates in the rerank window but removed by filters.
            These already have reranker_score from the cross-encoder.

    Scope is enforced here using the same rules as the main pipeline.
    excluded_ids: chunk_ids removed by topic-misclassification filter -> kept out of the backfill pool
                  so the filter -> backfill cycle is broken.
    """
    seen_ids= {r["chunk_id"] for r in reranked}
    if excluded_ids:
        seen_ids |= excluded_ids

    # build backfill pool from both unscored and already-scored candidates
    backfill_pool= [c for c in candidates[rerank_cap:] if c["chunk_id"] not in seen_ids]
    for c in candidates[:rerank_cap]:
        if c["chunk_id"] not in seen_ids:
            backfill_pool.append(c)

    # scope enforcement on the backfill pool
    if request.scope and request.scope != SCOPE_ALL:
        allowed= QURAN_SOURCE_TYPES if request.scope == SCOPE_QURAN else HADITH_SOURCE_TYPES
        before= len(backfill_pool)
        backfill_pool= [chunk for chunk in backfill_pool if chunk.get("source_type") in allowed]
        if before - len(backfill_pool):
            logger.debug(f"[PIPELINE] Backfill hard scope ({request.scope}): removed {before - len(backfill_pool)}")
    elif classification.scope != SCOPE_ALL:
        allowed= QURAN_SOURCE_TYPES if classification.scope == SCOPE_QURAN else HADITH_SOURCE_TYPES
        before= len(backfill_pool)
        backfill_pool= [chunk for chunk in backfill_pool if chunk.get("source_type") in allowed or chunk.get("rrf_score", 0) >= 0.35]
        if before - len(backfill_pool):
            logger.debug(f"[PIPELINE] Backfill soft scope ({classification.scope}): removed {before - len(backfill_pool)}")

    if classification.query_type == QTYPE_NARRATIVE:
        backfill_pool= [c for c in backfill_pool if not c.get("narrative_mismatch")]

    # mini-batch rerank for candidates we haven't scored yet
    backfill_unscored= [chunk for chunk in backfill_pool if chunk.get("reranker_score") is None]
    backfill_prescored= [chunk for chunk in backfill_pool if chunk.get("reranker_score") is not None]

    needed= top_k - len(reranked)
    if backfill_unscored and needed > 0:
        backfill_unscored.sort(key=lambda c: c.get("rrf_score", 0), reverse=True)
        batch_cap= min(len(backfill_unscored), max(needed * 2, 6))
        to_score= backfill_unscored[:batch_cap]
        remainder= backfill_unscored[batch_cap:]
        try:
            rescored= reranker.rerank(query=reranker_query, candidates=to_score, top_k=len(to_score))
            backfill_unscored= rescored + remainder
        except Exception as err:
            logger.warning(f"[PIPELINE] Backfill rerank failed: {err} -> using rrf_score")

    def sort_key(c: dict) -> float:
        rs= c.get("reranker_score")
        if rs is not None and rs > RERANKER_FLOOR_SCORE:
            return rs
        return c.get("rrf_score", 0.0)

    backfill_pool= sorted(backfill_prescored + backfill_unscored, key=sort_key, reverse=True)

    filled= 0
    for bf in backfill_pool:
        if len(reranked) >= top_k:
            break
        if bf["chunk_id"] in seen_ids:
            continue
        item= bf.copy()
        if "chunk" not in item or not item["chunk"]:
            item["chunk"]= format_chunk(bf.get("data") or {})
        if "reranker_score" not in item:
            item["reranker_score"]= bf.get("rrf_score", RERANKER_FLOOR_SCORE)
        item["final_rank"]= len(reranked) + 1
        reranked.append(item)
        seen_ids.add(bf["chunk_id"])
        filled += 1

    if filled:
        logger.info(f"[PIPELINE] Backfilled {filled} results (top_k={top_k})")
    elif needed > 0:
        logger.warning(
            f"[PIPELINE] Backfill pool empty after filters -> "
            f"{len(reranked)}/{top_k} from clean pool; top-up fallback will fill the rest"
        )

    return reranked


def emergency_bm25_fill(reranked: list, query: str, scope: str, top_k: int) -> list:
    """Last-resort BM25 fill when the fusion pool is exhausted and results < top_k.

    Runs a direct BM25 search on the normalized query and appends any unseen,
    in-scope results at RERANKER_FLOOR_SCORE. This is the final guarantee that
    all non-early-exit queries reach top_k results even if filtering was aggressive
    and the fusion pool did not have enough candidates.
    """
    needed= top_k - len(reranked)
    if needed <= 0 or not query or not query.strip():
        return reranked

    seen_ids= {r["chunk_id"] for r in reranked}

    # fetch extra to account for exclusions
    fetch_k= needed + len(seen_ids) + 20
    hits= bm25_index.search(query=query.strip(), scope=scope, top_k=fetch_k)

    filled= 0
    for hit in hits:
        if len(reranked) >= top_k:
            break
        chunk_id= hit.get("chunk_id", "")
        if chunk_id in seen_ids:
            continue
        chunk= get_chunk(chunk_id)
        if not chunk:
            continue
        item= {"chunk_id": chunk_id,
               "source_type": chunk.get("source_type"),
               "reranker_score": RERANKER_FLOOR_SCORE,
               "final_rank": len(reranked) + 1,
               "rrf_score": hit.get("score", 0.0),
               "dense_rank": None,
               "bm25_rank": hit.get("rank"),
               "chunk": format_chunk(chunk),}
        reranked.append(item)
        seen_ids.add(chunk_id)
        filled += 1

    if filled:
        logger.info(f"[PIPELINE] Emergency BM25 fill added {filled} results to reach top_k={top_k}")
    elif needed > 0:
        logger.warning(f"[PIPELINE] Emergency BM25 fill exhausted -> returning {len(reranked)}/{top_k}")

    return reranked


def handle_early_exit(direct_result: dict, top_k: int, scope: str= SCOPE_ALL, normalized_query: str= "") -> list[dict]:
    """Return the primary matched chunk for a named concept or alias hit.

    Only the exact chunk that was found in the alias map is returned.
    No BM25 fill and no sibling fill are added. Early exit results are
    intentionally allowed to have fewer than top_k items — the caller
    treats them as complete and exact answers that do not need padding.

    Returns [] if the chunk is not found in the corpus so the caller
    can fall through to the normal retrieval pipeline.
    """
    chunk_id= direct_result.get("chunk_id")
    if not chunk_id:
        return []

    if direct_result.get("surah_only"):
        return handle_surah_window_exit(direct_result, top_k, normalized_query)

    chunk= get_chunk(chunk_id)
    if not chunk:
        return []

    primary= {"chunk_id": chunk_id,
              "source_type": chunk.get("source_type"),
              "reranker_score": 1.0,
              "final_rank": 1,
              "rrf_score": 1.0,
              "dense_rank": None,
              "bm25_rank": None,
              "chunk": format_chunk(chunk),}

    return [primary]


def handle_surah_window_exit(direct_result: dict, top_k: int, normalized_query: str= "") -> list[dict]:
    """Return ayahs of a surah when only the surah name was given.

    Iterates all ayahs in the surah up to top_k. If the surah is shorter than
    top_k, only the available ayahs are returned. Early exit results are
    intentionally allowed to have fewer than top_k items.
    """
    surah_id= direct_result.get("surah_id", 1)
    results= []

    for ayah_num in range(1, top_k + 1):
        chunk_id= f"Q_{surah_id}:{ayah_num}"
        chunk= get_chunk(chunk_id)
        if chunk is None:
            break  # reached end of surah

        entry= {"chunk_id": chunk_id,
                "source_type": chunk.get("source_type"),
                "reranker_score": 1.0,
                "final_rank": ayah_num,
                "rrf_score": 1.0,
                "dense_rank": None,
                "bm25_rank": None,
                "chunk": format_chunk(chunk),}
        if ayah_num == 1:
            entry["note"]= (
                "Surah name matched without an ayah number -> "
                "showing ayahs from this surah. "
                "Add an ayah number (like 'Surah Al-Fatiha 3') to fetch a specific verse."
            )
        results.append(entry)

    for rank, item in enumerate(results, start=1):
        item["final_rank"]= rank

    return results


def assemble_results(reranked: list[dict]) -> list[dict]:
    """Convert the internal reranked list into the public API response shape."""
    results= []
    for item in reranked:
        assembled= {"chunk_id":item["chunk_id"],
                    "source_type": item["source_type"],
                    "final_rank": item["final_rank"],
                    "reranker_score": round(item.get("reranker_score", 0.0), 6),
                    "cross_encoder_score": round(item.get("cross_encoder_score", item.get("reranker_score", 0.0)) or 0.0, 6),
                    "rrf_score": round(item.get("rrf_score", 0.0), 6),
                    "dense_rank": item.get("dense_rank"),
                    "bm25_rank": item.get("bm25_rank"),
                    "chunk": item.get("chunk", {}),}
        if "note" in item:
            assembled["note"]= item["note"]
        if QTYPE_COMPARATIVE_CONCEPT in item:
            assembled[QTYPE_COMPARATIVE_CONCEPT]= item[QTYPE_COMPARATIVE_CONCEPT]
        results.append(assembled)
    return results


def filter_bm25_only_artifacts(reranked: list[dict]) -> list[dict]:
    """Remove low-score BM25-only results that the reranker also rated poorly.
    These snuck in on a keyword match but the cross-encoder confirmed they're irrelevant.
    """
    filtered= []
    removed= 0
    for item in reranked:
        is_bm25_only= item.get("dense_rank") is None and item.get("bm25_rank") is not None
        score= item.get("reranker_score", 0.0)
        if is_bm25_only and score < RERANKER_BM25_ONLY_THRESHOLD:
            removed += 1
        else:
            filtered.append(item)
    if removed:
        logger.info(f"[PIPELINE] BM25 artifact filter removed {removed} results")
    return filtered


def filter_topic_misclassification(reranked: list[dict],min_score: float,relative_drop_ratio: float | None= None, min_results: int= 3,) -> list[dict]:
    """Two-stage topic-misclassification filter for fiqh and definitional queries.

    Stage 1 -> absolute floor: drop results with score < min_score.
    Stage 2 -> relative drop: when top result >= 0.10, also drop results
               below top_score * relative_drop_ratio.

    Both stages respect min_results (never drop below that count).
    """
    if not reranked:
        return reranked

    filtered= [item for item in reranked if item.get("reranker_score", 0.0) >= min_score]
    if not filtered:
        logger.warning(f"[PIPELINE] Topic-misclassification filter removed all {len(reranked)} results -> keeping top-1.")
        return reranked[:1]

    removed_abs= len(reranked) - len(filtered)

    removed_rel= 0
    if relative_drop_ratio is not None and len(filtered) > min_results:
        top_score= max(item.get("reranker_score", 0.0) for item in filtered)
        if top_score >= 0.10:
            rel_floor= top_score * relative_drop_ratio
            after_rel= [item for item in filtered if item.get("reranker_score", 0.0) >= rel_floor]
            if len(after_rel) >= min_results:
                removed_rel= len(filtered) - len(after_rel)
                filtered= after_rel

    if removed_abs + removed_rel:
        logger.info(
            f"[PIPELINE] Topic-misclassification removed {removed_abs + removed_rel} "
            f"(abs<{min_score}: {removed_abs}, rel: {removed_rel})"
        )
    return filtered


def hard_scope_filter(reranked: list[dict], scope: str) -> list[dict]:
    """Remove all results not in the user-requested scope. No exceptions."""
    if scope == SCOPE_ALL:
        return reranked

    if scope == SCOPE_QURAN:
        in_scope= QURAN_SOURCE_TYPES
    elif scope == SCOPE_HADITH:
        in_scope= HADITH_SOURCE_TYPES
    else:
        return reranked

    filtered= [item for item in reranked if item.get("source_type", "") in in_scope]
    removed= len(reranked) - len(filtered)
    if removed:
        logger.info(f"[PIPELINE] Hard scope filter ({scope}): removed {removed}")
    return filtered


def soft_scope_filter(reranked: list[dict], scope: str, min_score_to_keep_out_of_scope: float= 0.35,) -> list[dict]:
    """Remove out-of-scope results, but keep high-confidence cross-scope hits.
    Used for auto-detected scope (not explicit user override).
    """
    if scope == SCOPE_ALL:
        return reranked

    if scope == SCOPE_QURAN:
        in_scope= QURAN_SOURCE_TYPES
    elif scope == SCOPE_HADITH:
        in_scope= HADITH_SOURCE_TYPES
    else:
        return reranked

    filtered= []
    removed= 0
    for item in reranked:
        if item.get("source_type", "") not in in_scope:
            score= item.get("reranker_score", 0.0)
            if score >= min_score_to_keep_out_of_scope:
                filtered.append(item)
            else:
                removed += 1
                logger.debug(
                    f"[PIPELINE] Soft scope removed {item['chunk_id']} "
                    f"(type={item.get('source_type')}, score={score:.4f})"
                )
        else:
            filtered.append(item)

    if removed:
        logger.info(f"[PIPELINE] Soft scope filter ({scope}): removed {removed}")
    return filtered

def extract_comparative_concepts(base_for_split: str, sorted_phrases_to_strip, normalized_framing_words) -> list[str]:
    for phrase in sorted_phrases_to_strip:
        base_for_split = base_for_split.replace(normalize_arabic(phrase), ' ')

    punctuation_ready_text = ' '.join(
        word for word in base_for_split.split() 
        if word not in normalized_framing_words
    )

    split_ready_text = re.sub(r'[؟?،!.:;]+', ' ', punctuation_ready_text).strip()


    raw_split_segments = CONCEPT_SPLIT_PATTERN.split(split_ready_text)

    # Fast list comprehension to clean whitespace and drop stray/short characters
    extracted_concepts = [concept.strip() for concept in raw_split_segments if concept.strip() and len(concept.strip()) >= 2]
    
    return extracted_concepts

# a trailing "في X" / "in X" on the last concept is context shared by both sides
_SHARED_CONTEXT_RE= re.compile(r"^(.*\S)\s+(في|in|during)\s+(\S.*)$", re.IGNORECASE)
# words a split concept may still carry from the question frame ("what الزكاه" from "What is the difference ...")
_CONCEPT_FRAME_WORDS= frozenset(normalize_arabic(w) for w in COMPARATIVE_GLUE_WORDS - {"and", "و"}) | {
    "what", "is", "the", "between", "how", "does", "do", "differ", "from", "are", "of", "a", "an"}


_SOURCE_CONTEXT_WORDS= frozenset({"القران", "والقران", "السنه", "والسنه", "الحديث", "والحديث", "الاحاديث", "الاسلام", "الكتاب",
                                  "quran", "qur'an", "sunnah", "sunna", "hadith", "hadiths", "islam"})


def comparative_concepts(classification) -> list[str]:
    """The concepts a comparative question contrasts ('الصلاه الفريضه', 'النافله').

    Source framing ("في القرآن والسنة") is dropped first - left in, "والسنة" split off as a third
    concept and "في القرآن" stuck to the second one. A trailing context ("الحلال والحرام في الطعام")
    belongs to every concept. The and / و separators are kept until the split (removing them as
    glue words first left English questions unsplittable).
    """
    text= classification.lexical_query or classification.normalized_query
    text= classifier.strip_source_framing(text)
    text= normalize_arabic(text).lower()
    text= re.sub(r"[؟?،,!.:;]+", " ", text)
    for phrase in sorted(COMPARATIVE_STRONG_SIGNALS | COMPARATIVE_WEAK_SIGNALS, key=len, reverse=True):
        text= re.sub(rf"(?<!\w){re.escape(normalize_arabic(phrase).lower())}(?!\w)", " ", text)

    concepts= []
    for segment in CONCEPT_SPLIT_PATTERN.split(text):
        words= [w for w in segment.split() if w not in _CONCEPT_FRAME_WORDS]
        if words and len(" ".join(words)) >= 2:
            concepts.append(" ".join(words))

    if len(concepts) >= 2:
        match= _SHARED_CONTEXT_RE.match(concepts[-1])
        if match:
            concepts[-1]= match.group(1)
            context_words= set(re.split(r"\s+|(?<=\s)و", match.group(3))) - {""}
            if not context_words <= _SOURCE_CONTEXT_WORDS:   # "in the Quran" is framing, not context
                context= f"{match.group(2)} {match.group(3)}"
                concepts= [f"{c} {context}" for c in concepts]
    return concepts


def comparative_rerank_query(concepts: list[str], language: str) -> str:
    """The contrasted concepts without the question frame: "الصلاه الفريضه والنافله".

    The cross-encoders score evidence against "what is the difference between X and Y" far lower than
    against "X and Y" (Bukhari 6502 for the fard/nafl question: Qwen 0.46 vs 0.95, bge 0.001 vs 0.015) -
    no ayah or hadith states a difference verbatim.
    """
    joiner= " and " if language == "english" else " و"
    context= ""
    match= _SHARED_CONTEXT_RE.match(concepts[0])
    if match and all(c.endswith(f"{match.group(2)} {match.group(3)}") for c in concepts):
        context= f" {match.group(2)} {match.group(3)}"
        concepts= [c[: len(c) - len(context)] for c in concepts]
    return joiner.join(concepts) + context


def run_comparative_pipeline(classification, top_k: int, t_start: float, query_meta: dict, timings: dict,) -> list[dict]:
    """Run the comparative pipeline: split into two concept arms, retrieve per-arm,
    apply co-occurrence boost, then rerank jointly.
    Falls back to single thematic search when the query can't be split.
    """
    concepts= comparative_concepts(classification)

    if len(concepts) < 2:
        logger.debug("[PIPELINE] Comparative split failed -> falling back to thematic")
        cls_single= copy.copy(classification)
        cls_single.query_type= QTYPE_THEMATIC
        ret_out= retriever.retrieve(cls_single)
        q_tokens= classification.normalized_query.split()
        cands= fusion.fuse(
            ret_out, query_type=QTYPE_THEMATIC, query_lang=classification.language,
            query_tokens=q_tokens, strict_scope_types=getattr(classification, "strict_scope_types", None),
        )
        if not cands:
            return []
        rq= pick_reranker_query(classification)
        ranked= reranker.rerank(query=rq, candidates=cands[:RERANK_CANDIDATE_CAP], top_k=len(cands))
        ranked= filter_bm25_only_artifacts(ranked)
        ranked= dedup_quran_passage_overlap(ranked, query_type=QTYPE_THEMATIC, by_reranker_score=True)

        # backfill from unscored candidates beyond the rerank cap if needed
        if PAD_RESULTS_TO_TOP_K and len(ranked) < top_k:
            seen_fallback= {r["chunk_id"] for r in ranked}
            for cand in cands[RERANK_CANDIDATE_CAP:]:
                if len(ranked) >= top_k:
                    break
                if cand["chunk_id"] in seen_fallback:
                    continue
                item= cand.copy()
                if "reranker_score" not in item:
                    item["reranker_score"]= RERANKER_FLOOR_SCORE
                item["final_rank"]= len(ranked) + 1
                ranked.append(item)
                seen_fallback.add(cand["chunk_id"])

        # emergency BM25 fill as absolute last resort
        if PAD_RESULTS_TO_TOP_K and len(ranked) < top_k:
            effective_scope= getattr(classification, "request_scope", None) or classification.scope
            ranked= emergency_bm25_fill(ranked, classification.normalized_query, effective_scope, top_k)

        return assemble_results(apply_result_score_floor(ranked[:top_k]))

    logger.debug(f"[PIPELINE] Comparative: '{concepts[0]}' vs '{concepts[1]}'")
    if COMPARATIVE_RERANK_QUERY == "concepts":
        full_query= comparative_rerank_query(concepts, classification.language)
    else:
        full_query= pick_reranker_query(classification)
    query_meta["comparative_reranker_query"]= full_query
    query_meta["comparative_concepts"]= [concepts[0], concepts[1]]

    t0= time.perf_counter()
    cands_a= retrieve_concept_candidates(concepts[0], classification)
    cands_b= retrieve_concept_candidates(concepts[1], classification)
    timings["retrieve_ms"]= round((time.perf_counter() - t0) * 1000, 1)

    tokens_a= set(normalize_arabic(concepts[0].lower()).split())
    tokens_b= set(normalize_arabic(concepts[1].lower()).split())

    seen_ids: set[str]= set()
    all_cands: list[dict]= []
    for c in cands_a + cands_b:
        if c["chunk_id"] not in seen_ids:
            seen_ids.add(c["chunk_id"])
            all_cands.append(c)

    boosted= apply_cooccurrence_boost(all_cands, tokens_a, tokens_b)
    boosted.sort(key=lambda c: c.get("rrf_score", 0), reverse=True)

    # inject canonical hints for well-known comparative pairs
    canonical_hints= getattr(classification, "canonical_hints", [])
    if canonical_hints:
        existing_ids= {c["chunk_id"] for c in boosted}
        hint_cands= []
        for chunk_id in canonical_hints:
            if chunk_id in existing_ids:
                continue
            chunk= get_chunk(chunk_id)
            if chunk is None:
                logger.warning(f"[PIPELINE] Comparative canonical hint {chunk_id} not found")
                continue
            hint_cands.append({"chunk_id": chunk_id,
                               "source_type": chunk.get("source_type"),
                               "rrf_score": 9999.0,  # always within rerank window
                               "dense_rank": None,
                               "bm25_rank": None,
                               "data": chunk,})
        boosted= hint_cands + boosted
        query_meta["canonical_hints_injected"]= [c["chunk_id"] for c in hint_cands]

    t0= time.perf_counter()
    rerank_pool= boosted[:RERANK_CANDIDATE_CAP]
    reranked= reranker.rerank(query=full_query, candidates=rerank_pool, top_k=len(rerank_pool),)
    if COMPARATIVE_CONCEPT_RESCORE:
        reranked= rescore_comparative_by_concept(reranked, rerank_pool, concepts[:2])
    reranked= blend_with_fusion(reranked)
    if classification.scope == SCOPE_ALL and not getattr(classification, "request_scope", None):
        reranked= balance_sources(reranked, top_k)
    if COMPARATIVE_CONCEPT_RESCORE:
        reranked= promote_each_concept(reranked, concepts[:2])
    elif COMPARATIVE_BALANCE_MIN_EACH > 0:
        reranked= balance_concepts(reranked, concepts[:2], top_k)
    timings["rerank_ms"]= round((time.perf_counter() - t0) * 1000, 1)

    reranked= filter_bm25_only_artifacts(reranked)
    reranked= dedup_quran_passage_overlap(reranked, query_type=QTYPE_THEMATIC, by_reranker_score=True)

    # backfill from per-arm results if needed
    if len(reranked) < top_k:
        res_a= run_single_concept(concepts[0], classification, top_k, full_query, concepts[0])
        res_b= run_single_concept(concepts[1], classification, top_k, full_query, concepts[1])
        existing= {r["chunk_id"] for r in reranked}
        for pair in zip_longest(res_a, res_b):
            for item in pair:
                if item and item["chunk_id"] not in existing:
                    existing.add(item["chunk_id"])
                    reranked.append(item)
            if len(reranked) >= top_k:
                break

    # final top-up from the joint candidate pool beyond the rerank cap ->
    # these were never scored but are still in-scope and relevant enough
    # to have made the fusion pool; used when per-arm backfill is exhausted
    if PAD_RESULTS_TO_TOP_K and len(reranked) < top_k:
        existing= {r["chunk_id"] for r in reranked}
        request_scope_for_topup= getattr(classification, "request_scope", None)
        topup_allowed= None
        if request_scope_for_topup and request_scope_for_topup != SCOPE_ALL:
            topup_allowed= QURAN_SOURCE_TYPES if request_scope_for_topup == SCOPE_QURAN else HADITH_SOURCE_TYPES
        for cand in boosted[RERANK_CANDIDATE_CAP:]:
            if len(reranked) >= top_k:
                break
            if cand["chunk_id"] in existing:
                continue
            if topup_allowed and cand.get("source_type") not in topup_allowed:
                continue
            item= cand.copy()
            if "chunk" not in item or not item["chunk"]:
                item["chunk"]= format_chunk(cand.get("data") or {})
            if "reranker_score" not in item:
                item["reranker_score"]= RERANKER_FLOOR_SCORE
            item["final_rank"]= len(reranked) + 1
            reranked.append(item)
            existing.add(item["chunk_id"])
        if len(reranked) < top_k:
            logger.debug(
                f"[PIPELINE] Comparative top-up exhausted -> running emergency BM25 fill"
            )

    # emergency BM25 fill as absolute last resort for the comparative pipeline
    if PAD_RESULTS_TO_TOP_K and len(reranked) < top_k:
        effective_scope= getattr(classification, "request_scope", None) or classification.scope
        reranked= emergency_bm25_fill(reranked, classification.normalized_query, effective_scope, top_k)

    reranked= apply_result_score_floor(reranked[:top_k])
    for rank, item in enumerate(reranked, start=1):
        item["final_rank"]= rank

    assembled= assemble_results(reranked)

    # hard scope filter for explicit user scope
    request_scope= getattr(classification, "request_scope", None)
    if request_scope:
        assembled= hard_scope_filter(assembled, request_scope)
        for rank, item in enumerate(assembled, start=1):
            item["final_rank"]= rank

    return assembled


def tag_concepts(reranked: list[dict], concepts: list[str]) -> None:
    """Mark which contrasted concept each of the top COMPARATIVE_TAG_POOL results is evidence for.

    Each result is scored against each concept alone; it belongs to a concept when that score is
    >= COMPARATIVE_TAG_MIN and clearly above the other concept's (repentance verses score high for
    both "التوبة" and "الاستغفار" and stay untagged). Which arm retrieved an item was not reliable:
    both arms return the same repentance verses.
    """
    pool= reranked[:COMPARATIVE_TAG_POOL]
    per_concept= [{r["chunk_id"]: r["reranker_score"] for r in reranker.rerank(query=c, candidates=pool, top_k=len(pool))}
                  for c in concepts]
    for item in pool:
        scores= [scores_of.get(item["chunk_id"], 0.0) for scores_of in per_concept]
        best= max(range(len(concepts)), key=lambda i: scores[i])
        others= [scores[i] for i in range(len(concepts)) if i != best]
        if scores[best] >= COMPARATIVE_TAG_MIN and scores[best] >= COMPARATIVE_TAG_MARGIN * max(others, default=0.0):
            item[QTYPE_COMPARATIVE_CONCEPT]= concepts[best]


def balance_concepts(reranked: list[dict], concepts: list[str], top_k: int) -> list[dict]:
    """Keep at least COMPARATIVE_BALANCE_MIN_EACH results per contrasted concept in the top_k.

    "مقارنة بين التوبة والاستغفار" returned eight repentance verses and two on seeking forgiveness: an
    answer to a comparison needs the evidence for both sides. Only items scoring
    >= COMPARATIVE_BALANCE_MIN_RATIO x the best are promoted; the weakest result of the
    over-represented side (or an untagged one) makes room.
    """
    if len(reranked) <= top_k:
        return reranked
    tag_concepts(reranked, concepts)
    floor= (reranked[0].get("reranker_score") or 0.0) * COMPARATIVE_BALANCE_MIN_RATIO
    head, tail= list(reranked[:top_k]), list(reranked[top_k:])
    for concept in concepts:
        have= sum(1 for r in head if r.get(QTYPE_COMPARATIVE_CONCEPT) == concept)
        promotable= [r for r in tail if r.get(QTYPE_COMPARATIVE_CONCEPT) == concept and (r.get("reranker_score") or 0.0) >= floor]
        while have < COMPARATIVE_BALANCE_MIN_EACH and promotable:
            counts= {c: sum(1 for r in head if r.get(QTYPE_COMPARATIVE_CONCEPT) == c) for c in concepts}
            victims= [i for i, r in enumerate(head) if r.get(QTYPE_COMPARATIVE_CONCEPT) != concept
                      and (r.get(QTYPE_COMPARATIVE_CONCEPT) is None
                           or counts.get(r.get(QTYPE_COMPARATIVE_CONCEPT), 0) > COMPARATIVE_BALANCE_MIN_EACH)]
            if not victims:
                break
            tail.insert(0, head.pop(victims[-1]))
            incoming= promotable.pop(0)
            tail.remove(incoming)
            head.append(incoming)
            have += 1
    head.sort(key=lambda r: r.get("reranker_score") or 0.0, reverse=True)
    return head + tail


def rescore_comparative_by_concept(reranked: list[dict], pool: list[dict], concepts: list[str]) -> list[dict]:
    """Score each candidate against each concept as well as the full question; keep the best.

    No passage answers "what is the difference between X and Y" verbatim, so the cross-encoder scores
    everything low against the full question (Q 23:2 for "الفرق بين الخشوع والخضوع": 0.045), while the
    evidence for each side scores well against that side alone. Results are then balanced so both
    concepts are represented near the top.
    """
    if not reranked or len(concepts) < 2:
        return reranked
    per_concept= []
    for concept in concepts:
        scored= reranker.rerank(query=concept, candidates=pool, top_k=len(pool))
        per_concept.append({r["chunk_id"]: r["reranker_score"] for r in scored})

    for item in reranked:
        concept_scores= [scores.get(item["chunk_id"], 0.0) for scores in per_concept]
        best_idx= max(range(len(concepts)), key=lambda i: concept_scores[i])
        # half max, half mean: evidence on one side still ranks, evidence covering both sides ranks higher
        # (Q 22:52 "من رسول ولا نبي" for "الفرق بين النبي والرسول")
        side_score= 0.5 * concept_scores[best_idx] + 0.5 * (sum(concept_scores) / len(concept_scores))
        item["reranker_score"]= max(item.get("reranker_score", 0.0), side_score)
        item[QTYPE_COMPARATIVE_CONCEPT]= concepts[best_idx]
    reranked.sort(key=lambda r: r.get("reranker_score", 0.0), reverse=True)
    return reranked


def promote_each_concept(reranked: list[dict], concepts: list[str]) -> list[dict]:
    """Each side's best evidence goes in the top 3, so one concept cannot fill the whole top of the list."""
    for concept in concepts:
        pos= next((i for i, r in enumerate(reranked) if r.get(QTYPE_COMPARATIVE_CONCEPT) == concept), None)
        if pos is not None and pos > 2 and reranked[pos].get("reranker_score", 0.0) >= COMPARATIVE_MIN_SIDE_SCORE:
            reranked.insert(2, reranked.pop(pos))
    return reranked


def retrieve_concept_candidates(concept: str, base_classification) -> list[dict]:
    """Retrieve and fuse candidates for a single comparative concept arm."""

    cls= copy.copy(base_classification)
    framed= apply_comparative_support(concept, base_classification.language)
    if len(framed) > 150:
        framed= framed[:150].rsplit(" ", 1)[0]

    cls.normalized_query= framed
    cls.lexical_query= concept
    cls.arabic_supplement= ""
    cls.query_type= QTYPE_THEMATIC
    cls.instruction_override= (
        "Instruct: Given a comparative Islamic query about one of two concepts "
        "being contrasted, retrieve the most relevant Quran ayahs or Hadith "
        "that define or discuss this concept\nQuery: "
    )

    ret_out= retriever.retrieve(cls)
    query_tokens= concept.split()
    fusion_top_k= FUSION_TOP_K_BY_TYPE.get(QTYPE_COMPARATIVE_CONCEPT, 15)

    return fusion.fuse(ret_out, query_type=QTYPE_THEMATIC, query_lang=cls.language, query_tokens=query_tokens, strict_scope_types=getattr(base_classification, "strict_scope_types", None), top_k_override=fusion_top_k,)


def apply_cooccurrence_boost(candidates: list[dict], concept_a_tokens: set[str], concept_b_tokens: set[str],) -> list[dict]:
    """Boost rrf_score of candidates whose text contains tokens from BOTH concepts."""
    meaningful_a= {token for token in concept_a_tokens if len(token) >= 3}
    meaningful_b= {token for token in concept_b_tokens if len(token) >= 3}

    if not meaningful_a or not meaningful_b:
        return candidates

    for candidate in candidates:
        data= candidate.get("data") or {}
        text= normalize_arabic(data.get("arabic_text", "") + " " + data.get("english_translation", data.get("english_text", "")) + " " +
                               data.get("arabic_tafsir", "")).lower()

        if any(token in text for token in meaningful_a) and any(token in text for token in meaningful_b):
            candidate["rrf_score"]= candidate.get("rrf_score", 0) * COMPARATIVE_COOCCURRENCE_BOOST
            candidate["cooccurrence_boosted"]= True

    return candidates


def run_single_concept(concept: str, base_classification, top_k: int, reranker_query: str | None= None, concept_label: str | None= None,) -> list[dict]:
    """Full retrieve->fuse->rerank for a single comparative concept arm.
    Used as backfill when the joint reranker pool is too sparse.
    """
    cls= copy.copy(base_classification)
    framed= apply_comparative_support(concept, base_classification.language)
    if len(framed) > 150:
        framed= framed[:150].rsplit(" ", 1)[0]

    cls.normalized_query= framed
    cls.lexical_query= concept
    cls.arabic_supplement= ""
    cls.query_type= QTYPE_THEMATIC

    ret_out= retriever.retrieve(cls)
    query_tokens= concept.split()
    comp_top_k= FUSION_TOP_K_BY_TYPE.get(QTYPE_COMPARATIVE_CONCEPT, 15)

    candidates= fusion.fuse(ret_out, query_type=QTYPE_THEMATIC, query_lang=cls.language, query_tokens=query_tokens,
                       strict_scope_types=getattr(base_classification, "strict_scope_types", None), top_k_override=comp_top_k,)
    if not candidates:
        return []

    eff_query= reranker_query if reranker_query else framed
    ranked= reranker.rerank(query=eff_query, candidates=candidates[:RERANK_CANDIDATE_CAP], top_k=len(candidates[:RERANK_CANDIDATE_CAP]),)
    ranked= filter_bm25_only_artifacts(ranked)
    ranked= dedup_quran_passage_overlap(ranked, query_type=QTYPE_THEMATIC, by_reranker_score=True)
    ranked= ranked[:top_k]

    for rank, item in enumerate(ranked, start=1):
        item["final_rank"]= rank

    assembled= assemble_results(ranked)
    if concept_label:
        for item in assembled:
            item[QTYPE_COMPARATIVE_CONCEPT]= concept_label

    return assembled
