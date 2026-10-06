"""
Query classifier for the search engine.

Takes a raw user query and returns a ClassifierResult that goes down into every
downstream stage: retrieval weights, BM25 query, reranker window size, etc.

Classification order (first match wins):
  1. Language detection
  2. Transliteration expansion (like "sabr" -> "صبر")
  3. English connector stripping for Arabic-dominant mixed queries
  4. Scope detection (quran / hadith / all)
  5. Direct reference check -> early exit
  6. Alias map (named concepts) -> early exit
  7. Query type classification -> one of 8 types
  8. Type-specific enrichment (definitional expansion, comparative support, etc.)
"""
import json
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from pyarabic.araby import strip_tashkeel
from .translit_variants import latin_variants, ARTICLES as TRANSLIT_ARTICLES
from config import ( TOPIC_GLOSSES_ENABLED, STRIP_RERANK_FRAMING, ALIAS_MAP_FILE, TRANSLITERATION_FILE, TRANSLITERATION_VARIANTS_FILE, ARABIC_CHAR_THRESHOLD, ARABIC_THRESHOLD,
                    SCOPE_QURAN, SCOPE_HADITH, SCOPE_ALL, QTYPE_DIRECT_REF, QTYPE_NAMED, QTYPE_FIQH, QTYPE_THEMATIC,
                    QTYPE_NARRATIVE, QTYPE_AR_KEYWORD, QTYPE_DEFINITIONAL,SURAH_ONLY_WINDOW_SIZE, QURAN_SOURCE_TYPES, HADITH_SOURCE_TYPES, )
from .constants import ( TOPIC_GLOSSES, PERSON_GLOSSES, PERSON_FILLER_WORDS, SURAHS_NEEDING_SURAH_WORD, TRANSLIT_KEEP_ENGLISH, RERANK_FRAME_PREFIXES_AR, RERANK_FRAME_PREFIXES_EN, RERANK_SOURCE_PHRASES_AR, RERANK_SOURCE_PHRASES_EN,
                        ENGLISH_CONECTORS, QURAN_KEYWORDS, QURAN_EMOTIONAL_KEYWORDS,
                        HADITH_KEYWORDS, PRAYER_TIME_SIGNALS,
                        SURAH_AYAHH_PATTERN, THEMATIC_SURAH_NAME_GUARDS, STORY_INTENT_SIGNALS,
                        STORY_SURAH_NAMES, HADITH_PATTERN, BOOK_TO_EDITION,
                        FIQH_SIGNALS, DEFINITIONAL_ARABIC_SIGNALS, DEFINITIONAL_ENGLISH_SIGNALS,
                        NARATIVE_SIGNALS, COMPARATIVE_STRONG_SIGNALS, COMPARATIVE_WEAK_SIGNALS,
                        QUESTION_WORDS, THEMATIC_NOUNS, DUAL_SOURCE_SIGNALS, CONNECTORS,
                        DEF_META_TOKENS, DEF_SCOPE_PHRASES, DEFINITIONAL_EXPANSION_MAP,
                        COMPARATIVE_SUPPORT, COMPARATIVE_CANONICAL_HINTS,
                        ENGLISH_EMOTIONAL_SUPPLEMENTS, ENGLISH_PRESCRIPTIVE_SUPPLEMENTS,
                        ARABIC_AMBIGOUS_EXPANSIONS, QURAN_FRGMENT_PHRASES,FIQH_SCOPE_SIGNALS, QURAN_SCOPE_SIGNALS, 
                        HADITH_SCOPE_SIGNALS, surah_data, STORY_FRAME_TOKENS, STRONG_DEF_KEYWORDS, HISTORICAL_EVENT_TOKENS)

logger= logging.getLogger(__name__)

@dataclass
class ClassifierResult:
    query_type: str
    scope: str
    language: str
    early_exit: bool= False
    direct_result: dict | None= None
    # query after translitration expansion and enrichmnt
    normalized_query: str= ""
    # arabic-enriched query for BM25
    lexical_query: str= ""
    # arabic supplement for dense vector averaging (english queries only)
    arabic_supplement: str= ""
    # user query after transliteration + connector strip, before any enrichment -> used by the reranker
    rerank_query: str= ""
    # when set, fusion post-filters to these source_types only
    strict_scope_types: frozenset | None= None
    # true when early exit was suppressed due to scope mismatch
    scope_mismatch_fallthrough: bool= False
    # true when the caller explicitly passed a scope_override (even "all")
    user_scope_override: bool= False
    # pre-seeded chunk IDs for comparative queries (like Hadith Jibril)
    canonical_hints: list= field(default_factory=list)
    # per-arm instruction override for comparative sub-retrievals
    instruction_override: str= ""
    # full decision trail for debugging
    debug: dict= field(default_factory=dict)


#state loaded from disk at startup
state: dict= {
    "alias_map":{},
    "transliteration":[],
    "surah_name_to_id": {},
    "loaded":False,}


def load_classifier_data(corpus_map: dict) -> None:
    """Load alias map, transliteration table, and surah name map. Call once at startup."""
    if state["loaded"]:
        logger.warning("Classifier data already loaded -> skipping.")
        return

    if Path(ALIAS_MAP_FILE).exists():
        with open(ALIAS_MAP_FILE, "r", encoding="utf-8") as f:
            raw_alias= json.load(f)
        state["alias_map"]= {k.lower().strip(): v for k, v in raw_alias.items()}
        logger.info(f"Alias map: {len(state['alias_map'])} entries.")
    else:
        logger.warning("Alias map not found.")

    if Path(TRANSLITERATION_FILE).exists():
        with open(TRANSLITERATION_FILE, "r", encoding="utf-8") as f:
            raw_translit= json.load(f)
        state["transliteration"]= [(k.lower().strip(), v) for k, v in raw_translit.items()]
        # key (words joined by single spaces) -> text that replaces it in the query
        lookup= {}
        keep_english= set(TRANSLIT_KEEP_ENGLISH)
        if Path(TRANSLITERATION_VARIANTS_FILE).exists():
            # generated spellings ("zakaat", "al-bakara", "ebrahim") -> build_transliteration_variants.py
            with open(TRANSLITERATION_VARIANTS_FILE, "r", encoding="utf-8") as f:
                generated= json.load(f)
            keep_english |= set(generated.get("keep_english", []))
            for key, replacement in generated.get("variants", {}).items():
                lookup[_translit_key(key)]= replacement
        else:
            logger.warning("Transliteration variants file not found - run build_transliteration_variants.py.")
        for key, arabic in state["transliteration"]:
            if not arabic:
                continue
            # an English word the translations use is kept and gets the Arabic added ("patience (الصبر)")
            has_arabic= bool(re.search(r"[؀-ۿ]", arabic))
            lookup[_translit_key(key)]= f"{{match}} ({arabic})" if (key in keep_english and has_arabic) else arabic
        state["translit_lookup"]= lookup
        state["translit_max_words"]= max((k.count(" ") + 1 for k in lookup), default=1)
        logger.info(f"Transliteration table: {len(state['transliteration'])} entries, {len(lookup)} spellings.")
    else:
        logger.warning("Translitration file not found.")

    state["surah_name_to_id"]= get_surah_map()
    # surahs whose name alone means a person / topic ("يوسف", "الحج"): every alias needs an explicit surah word
    state["surah_ids_needing_word"]= {surah_id for surah_id, aliases in surah_data
                                      if any(normalize_arabic(a.lower()) in SURAHS_NEEDING_SURAH_WORD for a in aliases)}
    state["loaded"]= True
    logger.info("Classifier data ready.")


def classify(query: str, scope_override: str | None= None) -> ClassifierResult:
    """Classify a raw query and return a ClassifierResult with all routing info."""
    if not query or not query.strip():
        return ClassifierResult(query_type=QTYPE_THEMATIC,
                                scope=scope_override or SCOPE_ALL,
                                language="english",
                                normalized_query="",
                                lexical_query="",
                                user_scope_override=bool(scope_override),
                                debug={"reason": "empty query"},)

    debug= {}

    language= detect_language(query)
    debug["language"]= language
    logger.debug(f"[CLASSIFY] query='{query[:80]}' | language={language}")

    normalized_query= expand_translitration(query)
    debug["after_translitration"]= normalized_query

    normalized_query, _= strip_english_connectors(normalized_query)
    debug["after_connector_strip"]= normalized_query
    rerank_query= strip_source_framing(normalized_query) if STRIP_RERANK_FRAMING else normalized_query

    # re-detect in case transliteration changed the script balance
    lang_after= detect_language(normalized_query)
    if lang_after != language:
        debug["language_post_translit"]= lang_after
        language= lang_after
        logger.debug(f"[CLASSIFY] language changed after transliteration: {language}")

    lexical_query= normalized_query
    arabic_supplement= ""
    if language in ("english", "mixed"):
        enriched= enrich_english_query(query, normalized_query)
        if enriched != normalized_query:
            lexical_query= enriched
            arabic_supplement= enriched[len(normalized_query):].strip()
            debug["english_enriched"]= lexical_query
            debug["arabic_supplement"]= arabic_supplement
            logger.debug(f"[CLASSIFY] English query enriched: '{arabic_supplement}'")

    # scope detection
    dual_source= has_dual_source_signal(normalized_query)

    if scope_override:
        scope= scope_override
        debug["scope_source"]= "user_override"
    elif dual_source:
        scope= SCOPE_ALL
        debug["scope_source"]= "dual_source_signal"
        debug["dual_source_forced_scope_all"]= True
        logger.debug("[CLASSIFY] Dual-source signal - forcing scope ALL")
    else:
        scope= detect_search_scope(normalized_query, language)
        debug["scope_source"]= "auto"

    debug["scope"]= scope

    strict_scope_types= None
    if scope_override:
        if scope_override== SCOPE_QURAN:
            strict_scope_types= frozenset(QURAN_SOURCE_TYPES)
        elif scope_override== SCOPE_HADITH:
            strict_scope_types= frozenset(HADITH_SOURCE_TYPES)

    # direct reference early exit (numeric surah:ayah, hadith book+number, surah name)
    ref_result= match_direct_reference(query) or match_direct_reference(normalized_query)
    if ref_result:
        if scope_allows_early_exit(ref_result, scope):
            debug["early_exit_reason"]= "direct_reference"
            logger.debug(f"[CLASSIFY] Early exit: direct_reference -> {ref_result.get('chunk_id')}")
            return ClassifierResult(query_type=QTYPE_DIRECT_REF, scope=scope, language=language,
                                    early_exit=True, direct_result=ref_result, normalized_query=query,
                                    lexical_query=lexical_query, strict_scope_types=strict_scope_types,
                                    user_scope_override=bool(scope_override), debug=debug,)
        else:
            msg= (f"direct_reference matched '{ref_result.get('chunk_id')}' "
                  f"but scope='{scope}' - falling through to full pipeline")
            debug["early_exit_suppressed"]= msg
            logger.debug(f"[CLASSIFY] {msg}")

    # named concept early exit (alias map match)
    alias_result= match_alias(query) or match_alias(normalized_query)
    if alias_result:
        if scope_allows_early_exit(alias_result, scope):
            debug["early_exit_reason"]= "named_concept"
            logger.debug(f"[CLASSIFY] Early exit: named_concept -> {alias_result.get('chunk_id')}")
            return ClassifierResult(query_type=QTYPE_NAMED, scope=scope, language=language,
                                    early_exit=True, direct_result=alias_result, normalized_query=query,
                                    lexical_query=lexical_query, strict_scope_types=strict_scope_types,
                                    user_scope_override=bool(scope_override), debug=debug,)
        else:
            msg= (f"named_concept matched '{alias_result.get('chunk_id')}' "
                  f"but scope='{scope}' - falling through")
            debug["early_exit_suppressed"]= msg
            logger.debug(f"[CLASSIFY] {msg}")

    query_type, type_reason= classify_query_type(normalized_query, language, scope_override=scope_override)
    debug["query_type_reason"]= type_reason
    logger.debug(f"[CLASSIFY] query_type={query_type} | {type_reason}")

    # fiqh queries should include both Quran and Hadith
    if query_type== QTYPE_FIQH and scope== SCOPE_HADITH and not scope_override:
        scope= SCOPE_ALL
        debug["fiqh_scope_override"]= "auto-detected hadith scope widened to ALL"
        logger.debug("[CLASSIFY] Fiqh query - widened hadith scope to ALL")

    # lock scope back to user's override
    if scope_override and scope != scope_override:
        scope= scope_override
        debug["scope_locked_to_user_override"]= f"query_type={query_type} scope forced to {scope_override}"

    # arabic_keyword sub-classification and scope inference
    if query_type== QTYPE_AR_KEYWORD:
        ar_subtype, ar_reason= subclassify_arabic_keyword(normalized_query)
        debug["arabic_keyword_subtype"]= ar_subtype
        debug["arabic_keyword_reason"]= ar_reason

        if ar_subtype== "quran_fragment":
            query_type= QTYPE_THEMATIC
            type_reason= f"arabic_keyword -> quran_fragment: {ar_reason}"
            debug["query_type_reason"]= type_reason
            logger.debug("[CLASSIFY] arabic_keyword -> promoted to thematic (quran_fragment)")

        if not scope_override and scope== SCOPE_ALL and query_type== QTYPE_AR_KEYWORD:
            inferred= infer_scope_for_arabic_keyword(normalized_query)
            if inferred != SCOPE_ALL:
                scope= inferred
                debug["arabic_keyword_scope_inferred"]= inferred
                logger.debug(f"[CLASSIFY] arabic_keyword auto-scope -> {inferred}")

    if query_type== QTYPE_NAMED and alias_result is None and not scope_override and scope== SCOPE_ALL:
        scope= SCOPE_QURAN
        debug["quran_fragment_scope_inferred"]= True

    # comparative: append framing context and find canonical hints
    if query_type== "comparative":
        support= apply_comparative_support(normalized_query, language)
        if support != normalized_query:
            debug["comparative_framing"]= support
            normalized_query= support

    canonical_hints: list= []
    if query_type== "comparative":
        canonical_hints= get_comparative_canonical_hints(normalized_query)
        if canonical_hints:
            debug["comparative_canonical_hints"]= canonical_hints

    # definitional enrichment
    if query_type== QTYPE_DEFINITIONAL:
        enriched_def= enrich_definitional_query(normalized_query, language, scope=scope)
        if enriched_def != normalized_query:
            debug["definitional_enrichment"]= enriched_def
            supplement_only= enriched_def[len(normalized_query):].strip()
            concept_term= strip_definitional_meta(normalized_query)
            if concept_term and supplement_only:
                lexical_query= (concept_term + " " + supplement_only).strip()
            elif supplement_only:
                lexical_query= supplement_only
            else:
                lexical_query= concept_term or normalized_query
            debug["definitional_bm25_query"]= lexical_query
            normalized_query= enriched_def
        else:
            # No match in DEFINITIONAL_EXPANSION_MAP - try ARABIC_AMBIGOUS_EXPANSIONS
            norm_full_q= normalize_arabic(normalized_query.strip().lower())
            if language== "arabic" and any(normalize_arabic(k)== norm_full_q for k in ARABIC_AMBIGOUS_EXPANSIONS):
                enriched_lexical= get_arabic_keyword_expansion(normalized_query)
                if enriched_lexical != normalized_query:
                    lexical_query= enriched_lexical
                    debug["definitional_ambiguous_expansion"]= enriched_lexical

    # thematic Arabic ambiguous-term expansion
    if query_type== QTYPE_THEMATIC and language== "arabic":
        norm_full_q= normalize_arabic(normalized_query.strip().lower())
        exact_match= any(normalize_arabic(k)== norm_full_q for k in ARABIC_AMBIGOUS_EXPANSIONS)
        if exact_match:
            enriched_lexical= get_arabic_keyword_expansion(normalized_query)
            if enriched_lexical != normalized_query:
                lexical_query= enriched_lexical
                debug["thematic_arabic_expansion"]= enriched_lexical

    # re-lock scope
    if scope_override and scope != scope_override:
        logger.warning(f"[CLASSIFY] Late scope drift: user gave '{scope_override}' but ended up '{scope}'. "
                       f"Forcing. query_type={query_type}")
        scope= scope_override
        if scope_override== SCOPE_QURAN:
            strict_scope_types= frozenset(QURAN_SOURCE_TYPES)
        elif scope_override== SCOPE_HADITH:
            strict_scope_types= frozenset(HADITH_SOURCE_TYPES)

    logger.info(f"[CLASSIFY] DONE | type={query_type} | scope={scope} | "
                f"lang={language} | early_exit=False")

    return ClassifierResult(query_type=query_type,
                            scope=scope,
                            language=language,
                            early_exit=False,
                            direct_result=None,
                            normalized_query=normalized_query,
                            lexical_query=lexical_query,
                            arabic_supplement=arabic_supplement,
                            rerank_query=rerank_query,
                            strict_scope_types=strict_scope_types,
                            canonical_hints=canonical_hints,
                            user_scope_override=bool(scope_override),
                            debug=debug,)

def _tolerant_arabic(phrase: str) -> str:
    """Regex for an Arabic phrase that ignores hamza / taa-marbuta / alif-maqsura spelling variants."""
    out= []
    for ch in phrase:
        if ch in "اأإآ":
            out.append("[اأإآ]")
        elif ch in "ةه":
            out.append("[ةه]")
        elif ch in "يى":
            out.append("[يى]")
        elif ch == " ":
            out.append(r"\s+")
        else:
            out.append(re.escape(ch))
    return "".join(out)


_FRAME_PREFIX_RE= re.compile(r"^\s*(?:" + "|".join(
    [_tolerant_arabic(p) for p in sorted(RERANK_FRAME_PREFIXES_AR, key=len, reverse=True)]
    + [re.escape(p).replace(" ", r"\s+") for p in sorted(RERANK_FRAME_PREFIXES_EN, key=len, reverse=True)]) + r")\s*", re.IGNORECASE)
_SOURCE_PHRASE_RE= re.compile(r"\s*(?:" + "|".join(
    [_tolerant_arabic(p) for p in sorted(RERANK_SOURCE_PHRASES_AR, key=len, reverse=True)]
    + [re.escape(p).replace(" ", r"\s+") for p in sorted(RERANK_SOURCE_PHRASES_EN, key=len, reverse=True)]) + r")(?=\s|[?؟.!]|$)", re.IGNORECASE)


_GLOSS_PREFIXES= ("وال", "بال", "فال", "لل", "ال", "و", "ب", "ف", "ل")


def _query_words(query: str) -> set[str]:
    """Normalized query words, each also without its leading article / proclitic."""
    words= set()
    for word in re.findall(r"\w+", normalize_arabic(query).lower()):
        words.add(word)
        for prefix in _GLOSS_PREFIXES:
            if word.startswith(prefix) and len(word) - len(prefix) >= 2:
                words.add(word[len(prefix):])
    return words


def topic_gloss(query: str) -> str:
    """The TOPIC_GLOSSES description for the first topic whose words all appear in the query, else ""."""
    if not TOPIC_GLOSSES_ENABLED:
        return ""
    words= _query_words(query)
    for needles, gloss in TOPIC_GLOSSES:
        if all(needle in words for needle in needles):
            return gloss
    return person_gloss(query)


def person_gloss(query: str) -> str:
    """PERSON_GLOSSES description when the query is essentially just a person's name, else ""."""
    tokens= re.findall(r"\w+", normalize_arabic(query).lower())
    if not tokens or len(tokens) > 6:
        return ""
    for required, allowed, gloss in PERSON_GLOSSES:
        known= set(required) | set(allowed) | PERSON_FILLER_WORDS
        found= set()
        for token in tokens:
            forms= [token] + [token[len(p):] for p in _GLOSS_PREFIXES
                              if token.startswith(p) and len(token) - len(p) >= 2]
            match= next((f for f in forms if f in known), None)
            if match is None:
                break
            found.add(match)
        else:
            if all(word in found for word in required):
                return gloss
    return ""


def strip_source_framing(query: str) -> str:
    """Drop "what does the Quran say about" / "في القرآن والسنة" style framing for the cross-encoder.

    Scope is handled by retrieval; left in the query, these words make the cross-encoder favour any
    passage that merely mentions the Quran or the Sunnah (Q 17:46 "وإذا ذكرت ربك في القرآن وحده" for
    "معنى التوحيد في القرآن"), and the framing pulls the score of the real answers down
    ("كيف تتحدث السنة عن حقوق الجار" 0.003 vs "فضل العلم" 0.97 for Tirmidhi 2646).
    """
    stripped= _FRAME_PREFIX_RE.sub("", query, count=1)
    stripped= _SOURCE_PHRASE_RE.sub("", stripped)
    stripped= re.sub(r"\s+([?؟.!])", r"\1", stripped)
    stripped= re.sub(r"\s+", " ", stripped).strip()
    return stripped if len(re.sub(r"[?؟.!\s]", "", stripped)) >= 2 else query


def detect_language(query: str) -> str:
    """Detect query language by Arabic character ratio.
    Returns 'arabic' (>=60%), 'mixed' (30-60%), or 'english' (<30%).
    """
    if not query:
        return "english"

    arabic_count= sum(1 for char in query if '\u0600' <= char <= '\u06FF')
    ratio= arabic_count / len(query)
    
    if ratio >= ARABIC_THRESHOLD:
        return "arabic"
    elif ratio >= ARABIC_CHAR_THRESHOLD:
        return "mixed"
    else:
        return "english"


_TRANSLIT_WORD_RE= re.compile(r"[A-Za-z][A-Za-z'’`ʿʾ]*")


def _translit_key(text: str) -> str:
    """Lookup form of a transliteration: lowercase, one apostrophe style, words split on spaces/hyphens."""
    text= re.sub(r"['’`ʿʾ]", "'", text.lower())
    return " ".join(w for w in re.split(r"[\s\-]+", text) if w)


def expand_translitration(query: str) -> str:
    """Replace transliterated Islamic terms and names with Arabic ("sabr" -> "الصبر", "al-bakara" -> "البقرة").
    The longest phrase starting at each word wins, so "battle of badr" is replaced as a whole.
    English words the translations use are kept, with the Arabic added: "patience" -> "patience (الصبر)".
    """
    lookup= state.get("translit_lookup")
    if not lookup:
        return query

    words= list(_TRANSLIT_WORD_RE.finditer(query))
    max_words= state.get("translit_max_words", 1)
    pieces, cursor, i= [], 0, 0
    while i < len(words):
        replaced= False
        for n in range(min(max_words, len(words) - i), 0, -1):
            span= words[i:i + n]
            # the words of a phrase may only be separated by spaces or hyphens
            if any(re.fullmatch(r"[\s\-]+", query[a.end():b.start()]) is None for a, b in zip(span, span[1:])):
                continue
            key= _translit_key(" ".join(w.group(0) for w in span))
            replacement= lookup.get(key)
            if replacement is None and key.endswith("s") and len(key) > 4:
                replacement= lookup.get(key[:-1])    # simple plural: "prophets", "angels"
            if replacement is None:
                continue
            start, end= span[0].start(), span[-1].end()
            pieces.append(query[cursor:start])
            pieces.append(replacement.replace("{match}", query[start:end]))
            cursor, i, replaced= end, i + n, True
            break
        if not replaced:
            i += 1
    pieces.append(query[cursor:])
    return "".join(pieces)


def strip_english_connectors(query: str) -> tuple[str, bool]:
    """Remove English connectors (and/or/of/in) from Arabic-dominant mixed queries.
    Only fires when >=50% of words are Arabic.
    """
    words= query.split()
    if not words:
        return query, False

    # We consider a word "Arabic" if >40% of its characters are in the Arabic unicode block.
    arabic_word_count= sum(1 for word in words 
        if (sum(1 for char in word if '\u0600' <= char <= '\u06FF') / max(len(word), 1)) > 0.4)
    
    if arabic_word_count / len(words) < 0.5:
        return query, False

    kept_words= [word for word in words if word.lower() not in ENGLISH_CONECTORS]
    cleaned_query= " ".join(kept_words).strip()

    if not cleaned_query or cleaned_query== query:
        return query, False

    return cleaned_query, True


def has_dual_source_signal(query: str) -> bool:
    """Return True if query explicitly references both Quran and Hadith/Sunnah."""
    lowercase_query= query.lower()
    normalized_query= normalize_arabic(lowercase_query)

    for signal in DUAL_SOURCE_SIGNALS:
        lowercase_signal= signal.lower()
        normalized_signal= normalize_arabic(lowercase_signal)
        if normalized_signal in normalized_query or lowercase_signal in lowercase_query:
            return True
    return False


def query_is_about_prayer_time(query: str) -> bool:
    """Return True if the query is about prayer times (Fajr/Dhuhr etc.)."""
    lowercase_query= query.lower()
    normalized_query= normalize_arabic(lowercase_query)
    for prayer_keyword in PRAYER_TIME_SIGNALS:
        if prayer_keyword in lowercase_query or prayer_keyword in normalized_query:
            return True
    return False


def detect_search_scope(query: str, language: str) -> str:
    """Auto-detect whether query is about Quran, Hadith, or both.
    English emotional keywords weakly favour Quran when no explicit Quran signal matched.
    """
    lowercase_query= query.lower()
    normalized_query= normalize_arabic(lowercase_query)

    quran_score= sum(1 for keyword in QURAN_KEYWORDS
                     if keyword in lowercase_query or keyword in normalized_query)

    hadith_score= sum(1 for keyword in HADITH_KEYWORDS
                      if keyword in lowercase_query or keyword in normalized_query)
    #emotional expressions mostly lean towards the quran
    if language in ("english", "mixed") and quran_score==0:
        query_words= set(re.findall(r'\b\w+\b', lowercase_query))
        if query_words & QURAN_EMOTIONAL_KEYWORDS:
            quran_score+= 1

    if quran_score>hadith_score:
        return SCOPE_QURAN
    elif hadith_score > quran_score:
        return SCOPE_HADITH
    else:
        return SCOPE_ALL


def match_direct_reference(query: str) -> dict | None:
    """Try to match the query as a direct Quran or hadith reference.

    Tries in order:
      1. Numeric surah:ayah patterns (2:255, Q2:255, etc.)
      2. Hadith book + number (Bukhari 1, Sahih Muslim 123)
      3. Surah name + optional ayah number
      4. Surah name alone -> returns window flag for first N ayahs
    """
    clean_query= query.strip().lower()
    skip_surah_matching= query_is_about_prayer_time(query)

    # pattern 1 Numeric Quran Patterns (like "2:255" or "Q2:255")
    for pattern in SURAH_AYAHH_PATTERN:
        match= pattern.search(clean_query)
        if match:
            surah_id= int(match.group(1))
            ayah_id= int(match.group(2))

            return{"type": "quran_ref", 
                   "chunk_id":f"Q_{surah_id}:{ayah_id}",
                    "surah_id": surah_id,
                    "ayah_id": ayah_id }

    #pattern 2: Hadith References (like "Bukhari 1")
    hadith_match= HADITH_PATTERN.search(clean_query)
    if hadith_match:
        book= (hadith_match.group("book") or hadith_match.group("book2") or "").lower().strip()
        number= hadith_match.group("number") or hadith_match.group("number2")
        edition= BOOK_TO_EDITION.get(book)
        if edition and number:
            return{"type":"hadith_ref",
                   "chunk_id": f"H_{edition}_{number}",
                   "edition":edition,
                   "hadith_number":number}

    # If it's a prayer time query, return before the Surah name searches as sometimes they match
    if skip_surah_matching:
        return None

    # pattern 3: Surah Name Matching (on the normalized query: "سوره البقره", "سورة الانعام" match too)
    clean_query= normalize_arabic(clean_query)

    # surah word + number only: "surah 18", "chapter 18", "سورة 18"
    number_only= re.fullmatch(_SURAH_WORD + r"\s*(\d{1,3})", clean_query, flags=re.IGNORECASE)
    if number_only and 1 <= int(number_only.group(1)) <= 114:
        surah_id= int(number_only.group(1))
        return {"type": "quran_ref", "chunk_id": f"Q_{surah_id}:1", "surah_id": surah_id, "ayah_id": 1,
                "surah_only": True, "window_size": SURAH_ONLY_WINDOW_SIZE}

    for surah_name, surah_id in state["surah_name_to_id"].items():
        if surah_name not in clean_query:
            continue

        #standalone not a substring from a larger word 
        if not re.search(r'\b'+re.escape(surah_name)+ r'\b', clean_query, flags=re.IGNORECASE):
            continue

        #case 1: surah name followed by a number 
        number_match= re.compile(re.escape(surah_name)+ r"\s+(\d{1,3})", re.IGNORECASE).search(clean_query)
        if number_match:
            ayah_number= int(number_match.group(1))
            return{"type": "quran_ref", 
                   "chunk_id":f"Q_{surah_id}:{ayah_number}",
                   "surah_id": surah_id,
                   "ayah_id": ayah_number }
        #case 2: surah name + verse/ayah+ number
        expression= re.escape(surah_name) + r"(?:\s+\w+){0,3}?\s+(?:verse|ayah|ayat|aya)\s+(\d{1,3})"
        keyword_match= re.compile(expression, re.IGNORECASE).search(clean_query)
        if keyword_match:
            ayah_number= int(keyword_match.group(1))
            return{"type": "quran_ref",
                   "chunk_id":f"Q_{surah_id}:{ayah_number}",
                   "surah_id": surah_id,
                   "ayah_id": ayah_number }
        #case 3: verse/ayah + number + of + surah name ("ayah 255 of baqarah", "الآية 255 من سورة البقرة")
        expression= (r"(?:verse|ayah|ayat|aya|ايه|الايه|ايات)\s+(\d{1,3})\s+(?:(?:of|from|in|من|في)\s+)?"
                     r"(?:(?:the\s+)?" + _SURAH_WORD + r"\s+)?" + re.escape(surah_name) + r"(?!\w)")
        reverse_match= re.compile(expression, re.IGNORECASE).search(clean_query)
        if reverse_match:
            ayah_number= int(reverse_match.group(1))
            return {"type": "quran_ref", "chunk_id": f"Q_{surah_id}:{ayah_number}",
                    "surah_id": surah_id, "ayah_id": ayah_number}

        #contextual search protection 
        normalized_query= normalize_arabic(clean_query)
        if any(normalize_arabic(guard_word) in normalized_query for guard_word in THEMATIC_SURAH_NAME_GUARDS):
            continue

        normalized_surah_name= normalize_arabic(surah_name)
        is_story_surah= (normalized_surah_name in STORY_SURAH_NAMES) or (surah_name in STORY_SURAH_NAMES)
        if is_story_surah:
            if any(normalize_arabic(signal_word) in normalized_query for signal_word in STORY_INTENT_SIGNALS):
                continue

        #pattern 4: standalone surah name return the first N ayah
        # a bare person/topic name ("يوسف", "Mary", "الحج") asks about it, not for the surah -> needs a surah word
        has_surah_word= _SURAH_WORD_RE.search(clean_query)
        if surah_id in state["surah_ids_needing_word"] and not has_surah_word:
            continue
        query_without_prefix= re.sub(r"^" + _SURAH_WORD + r"\s+", "", clean_query, flags=re.IGNORECASE).strip()
        expression= r"(?:" + _SURAH_WORD + r"\s+)?" + re.escape(surah_name) + r"(?:\s+" + _SURAH_WORD + r")?\s*"
        standalone_pattern= re.compile(expression, re.IGNORECASE)

        # the whole query must be the surah name: "عيسى ابن مريم" is not a request for surah Maryam
        is_exact_match= standalone_pattern.fullmatch(clean_query) or (query_without_prefix.lower()==surah_name.lower())
        has_no_numbers= not re.search(r"\d", clean_query)

        if is_exact_match and has_no_numbers:
            return{"type": "quran_ref",
                   "chunk_id": f"Q_{surah_id}:1",
                   "surah_id":surah_id,
                   "ayah_id":1,
                   "surah_only": True,
                   "window_size": SURAH_ONLY_WINDOW_SIZE}

    return None


def source_type_for_direct_result(direct_result: dict) -> str:
    reference_type= direct_result.get("type", "")
    if reference_type== "quran_ref":
        return "quran"
    if reference_type== "hadith_ref":
        return "hadith"
    if reference_type== "named_concept":
        chunk_id= direct_result.get("chunk_id", "")
        if chunk_id.startswith("Q_"):
            return "quran"
        if chunk_id.startswith("H_"):
            return "hadith"
    return "unknown"


def scope_allows_early_exit(direct_result: dict, scope: str) -> bool:
    if scope== SCOPE_ALL:
        return True
    result_source= source_type_for_direct_result(direct_result)
    is_quran_match= (scope== SCOPE_QURAN and result_source== "quran")
    is_hadith_match= (scope== SCOPE_HADITH and result_source== "hadith")
    return is_quran_match or is_hadith_match

def clean_for_alias(text: str) -> str:
    """Normalise text for alias map lookup."""
    base_text= text.lower().strip()
    spaced_text= re.sub(r"[-_]+", " ", base_text)
    normalized_text= normalize_arabic(spaced_text)
    final_text= " ".join(normalized_text.split())

    return final_text


def match_alias(query: str) -> dict | None:
    """Try to match query against the named-concept alias map.
    Tries exact match, normalised match, then substring/word-set matching.
    """
    alias_map= state.get("alias_map")
    if not alias_map:
        return None

    clean_query= re.sub(r'[\"«»\']', '', query.lower().strip())
    arabic_norm_query= normalize_arabic(clean_query)
    fully_normalized= clean_for_alias(clean_query)

    query_words= {word for word in fully_normalized.split() if len(word) > 1}

    for search_key in (clean_query, arabic_norm_query, fully_normalized):
        if search_key in alias_map:
            return {"type": "named_concept", 
                    "chunk_id": alias_map[search_key], 
                    "matched_alias": search_key}

    wants_story= any(keyword in clean_query for keyword in ["story", "قصة", "قصص"])

    if not wants_story:
        sorted_aliases= sorted(alias_map.items(), key=lambda kv: (len(kv[0].split()), len(kv[0])), reverse=True)
        for alias, chunk_id in sorted_aliases:
            alias_norm= clean_for_alias(alias)
            alias_words= {word for word in alias_norm.split() if len(word) > 1}

            is_substring= (alias in clean_query or alias in arabic_norm_query or alias_norm in fully_normalized)
            
            is_word_match= len(alias_words) >= 2 and alias_words.issubset(query_words)

            if is_substring or is_word_match:
                return {"type": "named_concept", 
                        "chunk_id": chunk_id, 
                        "matched_alias": alias}

    # common misspellings of prophet names
    fuzzy_names= {
        "muhamad": "prophet muhammad", "muhamed": "prophet muhammad",
        "mohamad": "prophet muhammad", "mohammad": "prophet muhammad",
        "muhammed": "prophet muhammad", 
        "ibrahim": "prophet ibrahim", "ibraheem": "prophet ibrahim", 
        "musa": "prophet musa", "mousa": "prophet musa", 
        "isa": "prophet isa", "eesa": "prophet isa", 
        "yusuf": "prophet yusuf", "yousef": "prophet yusuf", 
        "maryam": "story of maryam", "mariam": "story of maryam", 
        "forgivness": "forgiveness", "forgivenes": "forgiveness", 
        "patince": "patience", "patiens": "patience",
    }

    if len(clean_query.split()) <= 2:
        for typo, correct_spelling in fuzzy_names.items():
            if clean_query== typo or arabic_norm_query== typo:
                if correct_spelling in alias_map:
                    return {"type": "named_concept", 
                            "chunk_id": alias_map[correct_spelling], 
                            "matched_alias": correct_spelling}

    return None

def classify_query_type(query: str, language: str, scope_override: str | None= None) -> tuple[str, str]:
    """Classify the query into one of the 8 search types.
    Returns (query_type, reason_string).
    """
    clean_query= query.lower()
    normalized_query= normalize_arabic(clean_query)
    query_words= clean_query.split()

    # Quran fragment match
    for fragment in QURAN_FRGMENT_PHRASES:
        if normalize_arabic(fragment) in normalized_query:
            return QTYPE_NAMED, f"quran_fragment match: '{fragment}'"

    # Comparative Matching
    # Checked before dual-source so queries like "الفرق بين X في القرآن والسنة" 
    # route as comparative rather than thematic.
    strong_comparative_hits= sum(1 for signal in COMPARATIVE_STRONG_SIGNALS if signal in clean_query or signal in normalized_query)
    weak_comparative_hits= sum(1 for signal in COMPARATIVE_WEAK_SIGNALS   if signal in clean_query or signal in normalized_query)    
    if strong_comparative_hits >= 1 or weak_comparative_hits >= 2:
        return "comparative", f"comparative signals: strong={strong_comparative_hits} weak={weak_comparative_hits}"

    # Thematic
    if(has_dual_source_signal(clean_query) or has_dual_source_signal(normalized_query)):
        return QTYPE_THEMATIC, f"dual-source:"

    # Definitional / Fiqh Overlap
    def_arabic_hits= sum(1 for signal in DEFINITIONAL_ARABIC_SIGNALS  if signal in clean_query or signal in normalized_query)
    def_english_hits= 0
    if language in ("english", "mixed"):
        def_english_hits= sum(1 for signal in DEFINITIONAL_ENGLISH_SIGNALS if signal in clean_query)

    if def_arabic_hits >= 1 or def_english_hits >= 1:
        has_strong_def= any(keyword in clean_query or keyword in normalized_query for keyword in STRONG_DEF_KEYWORDS)

        if has_strong_def:
            # Fiqh takes priority when there is overlap (example "شروط صحة الزواج")
            fiqh_hits_in_def= sum(1 for signal in FIQH_SIGNALS if signal in clean_query or signal in normalized_query)

            if fiqh_hits_in_def >= 1:
                return QTYPE_FIQH, "definitional+fiqh overlap -> fiqh"

            return QTYPE_DEFINITIONAL, f"definitional ar={def_arabic_hits} en={def_english_hits}"

    # Fiqh (Standalone)
    fiqh_standalone_hits= sum(1 for signal in FIQH_SIGNALS if signal in clean_query or signal in normalized_query)
    if fiqh_standalone_hits >= 1:
        return QTYPE_FIQH, f"fiqh signals: {fiqh_standalone_hits}"

    # Narrative
    story_normalized= normalized_query.replace("قصه", "قصة").replace("قصص", "قصة")
    narrative_hits= sum(1 for signal in NARATIVE_SIGNALS if signal in clean_query or signal in normalized_query or signal in story_normalized)

    if narrative_hits >= 1:
        is_historical_event= any(token in normalized_query for token in HISTORICAL_EVENT_TOKENS)
        has_explicit_story_framing= any(token in normalized_query for token in STORY_FRAME_TOKENS)
        
        if is_historical_event and not has_explicit_story_framing and not scope_override:
            return QTYPE_THEMATIC, "narrative+event override -> thematic"

        return QTYPE_NARRATIVE, f"narrative signals: {narrative_hits}"

    # Prayer Times
    if query_is_about_prayer_time(query):
        # Routed to thematic so it can include Hadiths about prayer schedules
        return QTYPE_THEMATIC, "prayer-time query -> thematic to include hadith"

    # Short Arabic Keywords
    if language== "arabic" and len(query_words) <= 3:
        normalized_words= normalized_query.split()
        is_question= any(word in QUESTION_WORDS for word in normalized_words)
        has_theme_word= any(word in THEMATIC_NOUNS for word in normalized_words)
        has_connector= any(word in CONNECTORS or (word.startswith("و") and len(word) > 1) for word in normalized_words)

        fully_normalized_query= normalize_arabic(query.strip().lower())
        is_known_compound_pair= any(normalize_arabic(key)== fully_normalized_query for key in ARABIC_AMBIGOUS_EXPANSIONS)
        
        if is_known_compound_pair:
            return QTYPE_AR_KEYWORD, "known compound Islamic keyword pair"

        if not is_question and not has_connector and not has_theme_word:
            return QTYPE_AR_KEYWORD, "arabic + very short + no question/connector/theme word"

    return QTYPE_THEMATIC, "no strong signals -> default thematic"

def subclassify_arabic_keyword(query: str) -> tuple[str, str]:
    """Sub-classify arabic_keyword into: quran_fragment, ambiguous_term, or normal."""
    normalized_query= normalize_arabic(query.strip().lower())

    for fragment in QURAN_FRGMENT_PHRASES:
        if fragment in normalized_query:
            return "quran_fragment", f"matched fragment: '{fragment}'"
    for ambiguous_term in ARABIC_AMBIGOUS_EXPANSIONS:
        normalized_term= normalize_arabic(ambiguous_term)
        is_overlapping_match= (normalized_term in normalized_query) or (normalized_query in normalized_term)

        if is_overlapping_match:
            return "ambiguous_term", f"ambiguous term: '{ambiguous_term}'"
    return "normal", "standard arabic keyword"

def infer_scope_for_arabic_keyword(query: str) -> str:
    """Infer corpus scope from a short Arabic keyword query by counting vocabulary signals."""
    normalized_query= normalize_arabic(query.strip().lower())
    query_words_set= set(normalized_query.split())

    def signal_matches(signal_text: str) -> bool:
        normalized_signal= normalize_arabic(signal_text)
        # Multi-word signals: check if the exact phrase exists anywhere in the text
        if " " in normalized_signal:
            return normalized_signal in normalized_query

        # Single-word signals: require exact whole-word match in our set to avoid 
        # false substring hits (like, "حج" falsely matching inside "حجاب").
        return normalized_signal in query_words_set

    
    quran_score= sum(1 for s in QURAN_SCOPE_SIGNALS  if signal_matches(s))
    hadith_score= sum(1 for s in HADITH_SCOPE_SIGNALS if signal_matches(s))
    fiqh_score= sum(1 for s in FIQH_SCOPE_SIGNALS   if signal_matches(s))
    # fiqh terms live mostly in Hadith
    hadith_score += fiqh_score

    if quran_score > hadith_score:
        return SCOPE_QURAN
    elif hadith_score > quran_score:
        return SCOPE_HADITH
    else:
        return SCOPE_ALL

def strip_definitional_meta(query: str) -> str:
    """Strip definitional meta-words leaving only the concept name.
    example 'تعريف الزكاة وشروطها' -> 'الزكاة'
    """
    normalized_query= normalize_arabic(query.lower())
    # strip punctuation before splitting so "الاسلام؟" matches "الاسلام" in meta set
    punctuation_pattern= r'[?؟!،,.:;\u060c-\u060f\u061b\u061e\u061f]+'
    punctuation_free_text= re.sub(punctuation_pattern, ' ', normalized_query)

    phrase_stripped_text= punctuation_free_text
    for meta_phrase in DEF_SCOPE_PHRASES:
        normalized_phrase= normalize_arabic(meta_phrase)
        phrase_stripped_text= phrase_stripped_text.replace(normalized_phrase, " ")

    normalized_meta_tokens= frozenset(normalize_arabic(token) for token in DEF_META_TOKENS)
    concept_words= [word for word in phrase_stripped_text.split() if word not in normalized_meta_tokens and len(word) >= 3]
    return " ".join(concept_words).strip()

def enrich_definitional_query(query: str, language: str, scope: str | None= None) -> str:
    """Append related terms so dense retrieval surfaces definitional passages.
    Hard cap at 400 chars.
    """
    normalized_query_text= normalize_arabic(query.lower())
    normalized_query_words= normalized_query_text.split()
    normalized_query_word_set= frozenset(normalized_query_words)

    raw_query_text= query.lower()
    raw_query_words= raw_query_text.split()

    supplements_to_add= []
    seen_words= set(normalized_query_words)

    for trigger_group, supplement_text in DEFINITIONAL_EXPANSION_MAP:
        for trigger in trigger_group:
            normalized_trigger= normalize_arabic(trigger.lower())
            normalized_trigger_words= normalized_trigger.split()
            raw_trigger_words= trigger.lower().split()

            is_matched= False

            if len(normalized_trigger_words)== 1:
                is_matched= (normalized_trigger in normalized_query_word_set or trigger.lower() in raw_query_words)
            else:
                trigger_len= len(normalized_trigger_words)

                for i in range(len(normalized_query_words) - trigger_len + 1):
                    if normalized_query_words[i : i + trigger_len]== normalized_trigger_words:
                        is_matched= True
                        break

                if not is_matched:
                    raw_trigger_len= len(raw_trigger_words)
                    for i in range(len(raw_query_words) - raw_trigger_len + 1):
                        if raw_query_words[i : i + raw_trigger_len]== raw_trigger_words:
                            is_matched= True
                            break

            if is_matched:
                new_tokens= [word for word in supplement_text.split() if normalize_arabic(word) not in seen_words]
                if new_tokens:
                    supplements_to_add.append(" ".join(new_tokens))
                    seen_words.update(normalize_arabic(word) for word in new_tokens)
                break

    if not supplements_to_add:
        return query

    final_query= f"{query} {' '.join(supplements_to_add)}"
    return final_query[:400]

def get_comparative_canonical_hints(normalized_query: str) -> list[str]:
    """Return canonical chunk IDs for well-known comparative pairs found in query."""
    fully_normalized_query= normalize_arabic(normalized_query.lower())
    query_words= set(fully_normalized_query.split())

    for concept_set, target_hint_ids in COMPARATIVE_CANONICAL_HINTS:
        all_concepts_matched= True

        for concept in concept_set:
            concept_found= False
            for word in query_words:
                if concept in word or word in concept:
                    concept_found= True
                    break
            if not concept_found:
                all_concepts_matched= False
                break 

        if all_concepts_matched:
            return target_hint_ids

def apply_comparative_support(query: str, language: str) -> str:
    """Append framing context terms to a comparative query for dense retrieval."""
    lowercase_query= query.lower()
    normalized_query= normalize_arabic(lowercase_query)
    support_terms_to_add= []
    already_seen_words= set()

    for trigger_word, supplemental_context in COMPARATIVE_SUPPORT:
        lowercase_trigger= trigger_word.lower()
        normalized_trigger= normalize_arabic(lowercase_trigger)

        is_match= (normalized_trigger in normalized_query) or (lowercase_trigger in lowercase_query)

        if is_match:
            new_words= [word for word in supplemental_context.split() if word not in already_seen_words]

            if new_words:
                support_terms_to_add.append(" ".join(new_words))
                already_seen_words.update(new_words)

    if not support_terms_to_add:
        return query

    all_extra_terms= " ".join(support_terms_to_add)
    return f"{query} {all_extra_terms}"

def get_arabic_keyword_expansion(query: str) -> str:
    """Expand an ambiguous Arabic term with its disambiguation variants."""
    normalized_query= normalize_arabic(query.strip().lower())

    for ambiguous_term, clarifying_expansion in ARABIC_AMBIGOUS_EXPANSIONS.items():
        normalized_term= normalize_arabic(ambiguous_term)
        is_overlapping_match= (normalized_term in normalized_query) or (normalized_query in normalized_term)
        if is_overlapping_match:
            return f"{query} {clarifying_expansion}"
            
    return query

def enrich_english_query(original: str, after_transliteration: str) -> str:
    """Append Arabic supplement terms to an English query for cross-lingual retrieval.
    Skips enrichment if the query is already mostly Arabic after transliteration.
    """
    words_after_translit= after_transliteration.strip().split()

    arabic_word_count= sum(1 for w in words_after_translit
                           if (sum(1 for c in w if '\u0600' <= c <= '\u06FF') / max(len(w), 1)) > 0.5)

    total_words= max(len(words_after_translit), 1)
    if (arabic_word_count / total_words) >= 0.5:
        return after_transliteration

    clean_original= original.lower()
    arabic_supplements= []
    for english_keywords, arabic_translation in ENGLISH_PRESCRIPTIVE_SUPPLEMENTS:
        for keyword in english_keywords:
            if re.search(r'\b' + re.escape(keyword) + r'\b', clean_original):
                arabic_supplements.append(arabic_translation)
                break

    for english_keywords, arabic_translation in ENGLISH_EMOTIONAL_SUPPLEMENTS:
        for keyword in english_keywords:
            if re.search(r'\b' + re.escape(keyword) + r'\b', clean_original):
                arabic_supplements.append(arabic_translation)
                break

    if not arabic_supplements:
        return after_transliteration

    supplements_string= " ".join(arabic_supplements)
    return f"{after_transliteration} {supplements_string}"

def normalize_arabic(text: str) -> str:
    """Light Arabic normalisation for keyword matching.
    Strips tashkeel and Quranic annotation marks, normalises hamza/alif variants
    (incl. alif wasla ٱ), converts ة->ه, ى->ي, ؤ/ئ->ء.
    Must stay identical to normalize_arabic_text() in normalize_data_chuncks.py.
    """
    text= strip_tashkeel(text)
    text= QURANIC_MARKS_RE.sub('', text)
    text= re.sub(r'[أإآٱ]', 'ا', text)
    text= text.replace('ة', 'ه')
    text= text.replace('ى', 'ي')
    text= text.replace('ؤ', 'ء').replace('ئ', 'ء')
    return text.strip()

# superscript alif, small high/low Quranic annotation marks (U+06D6-06ED), tatweel, BOM
QURANIC_MARKS_RE= re.compile(r'[\u0670\u06D6-\u06ED\u0640\uFEFF]')


_SURAH_WORD= r"(?:surah?|surat|sourah?|soorah?|sorah?|chapter|سورة|سوره)"
_SURAH_WORD_RE= re.compile(r"(?<!\w)" + _SURAH_WORD + r"(?!\w)", re.IGNORECASE)


def get_surah_map() -> dict:
    """Build a lowercased name -> surah_id lookup from surah_data.
    Arabic names are stored normalized (matched against the normalized query); Latin names also get their
    spelling variants ("al-baqara", "albaqarah", "el bakara"). Variants are only generated for names with an
    article or of 5+ letters, without vowel lengthening, so short names don't turn into English words
    ("tin" -> "ten", "nur" -> "nor").
    """
    surah_lookup_map= {}
    for surah_id, aliases in surah_data:
        for name in aliases:
            name= name.lower().strip()
            if re.search(r"[؀-ۿ]", name):
                surah_lookup_map[normalize_arabic(name)]= surah_id
                continue
            surah_lookup_map[name]= surah_id
            words= re.split(r"[\s\-]+", name)
            has_article= words[0] in TRANSLIT_ARTICLES and len(words) > 1
            if has_article or len(name) >= 5:
                # vowel lengthening only behind an article ("al ikhlaas"); bare "rum" would become "room"
                for variant in latin_variants(name, lengthen=has_article, max_variants=60):
                    if len(re.sub(r"[\s\-']", "", variant)) >= 4:
                        surah_lookup_map.setdefault(variant, surah_id)
    return surah_lookup_map
