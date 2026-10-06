import re
from functools import lru_cache
from .classifier import normalize_arabic
from .constants import (PASSAGE_EXTRA_STOPWORDS, QUERY_STOPWORDS, ARABIC_STOPWORDS, PUNCT_PATTERN, ARABIC_SUFFIXES,
                        ARABIC_CONJUNCTIONS, ARABIC_ARTICLES, ARABIC_PREPOSITIONS, ARABIC_LONG_REMAINDER_SUFFIXES,
                        ENGLISH_STOPWORDS)

@lru_cache(maxsize=32768)
def light_stem(word: str) -> str:
    """Light stemmer: strip proclitics in their grammatical order, then one suffix.

    Order is conjunction (و/ف) -> article (وال/بال/.../ال) or preposition (ب/ل/ك),
    at most one of each, so root letters are not stripped as stacked prefixes
    (الكتاب -> كتاب, not تاب). Length guards keep at least 3 letters, 4 for
    single-letter proclitics and plural/dual endings (فرضه, رمضان stay whole).
    """
    article_stripped= False
    for article in ARABIC_ARTICLES:
        if word.startswith(article) and len(word) - len(article) >= 3:
            word= word[len(article):]
            article_stripped= True
            break

    if not article_stripped:
        if word[:1] in ARABIC_CONJUNCTIONS and len(word) - 1 >= 4:
            word= word[1:]
            # conjunction + preposition + article (وبالوالدين) -> the article forms are covered here
            for article in ARABIC_ARTICLES:
                if word.startswith(article) and len(word) - len(article) >= 3:
                    word= word[len(article):]
                    article_stripped= True
                    break
        if not article_stripped and word[:1] in ARABIC_PREPOSITIONS and len(word) - 1 >= 4:
            word= word[1:]

    for suffix in ARABIC_SUFFIXES:
        if not word.endswith(suffix):
            continue
        min_remainder= 4 if suffix in ARABIC_LONG_REMAINDER_SUFFIXES else 3
        if len(word) - len(suffix) >= min_remainder:
            word= word[:-len(suffix)]
        # the longest matching suffix decides: a blocked "ات" must not fall through to "ت"
        break

    return word


def arabic_tokenize(text: str, remove_stopwords: bool= True, stopword_set: frozenset | None= None, stem: bool= True,) -> list[str]:
    """General Arabic tokeniser for corpus indexing and dedup.
    Applies: normalize_arabic -> strip punct -> drop short tokens -> stem -> stopword removal.
    Returns stemmed token list.
    """
    if not isinstance(text, str) or not text.strip():
        return []

    stopword= stopword_set if stopword_set is not None else ARABIC_STOPWORDS
    text= normalize_arabic(text)
    text= PUNCT_PATTERN.sub(' ', text)

    result= []
    for raw in text.split():
        if len(raw) < 3:
            continue

        if stem:
            stemmed= light_stem(raw)
        else:
            stemmed= raw
        # also check the word without a leading و/ف: والله, وفي, فقال are stopwords too
        without_conjunction= raw[1:] if raw[:1] in ARABIC_CONJUNCTIONS else raw
        if remove_stopwords and (stemmed in stopword or raw in stopword or without_conjunction in stopword):
            continue
        result.append(stemmed)

    return result

def arabic_tokenize_query(text: str) -> list[str]:
    """Tokeniser for user queries -> uses lighter QUERY_STOPWORDS.
    Emits both stemmed and raw forms so BM25 can match on the exact surface form.
    """
    if not isinstance(text, str) or not text.strip():
        return []

    normalized= normalize_arabic(text)
    cleaned= PUNCT_PATTERN.sub(' ', normalized)

    result= []
    seen: set[str]= set()

    for raw in cleaned.split():
        if len(raw) < 3 or raw in QUERY_STOPWORDS:
            continue
        stemmed= light_stem(raw)

        if stemmed not in seen and stemmed not in QUERY_STOPWORDS:
            result.append(stemmed)
            seen.add(stemmed)

        # emit raw form when it differs -> exact-form queries can still match
        if raw != stemmed and raw not in seen:
            result.append(raw)
            seen.add(raw)

    return result

def arabic_tokenize_passage(text: str) -> list[str]:
    """Tokeniser for passage chunks at index time.
    Uses PASSAGE_EXTRA_STOPWORDS to strip more noise words.
    """
    return arabic_tokenize(text, remove_stopwords=True, stopword_set=PASSAGE_EXTRA_STOPWORDS)

def english_tokenize(text: str) -> list[str]:
    """Lowercase, strip punctuation, remove stopwords."""
    if not isinstance(text, str):
        return []
    clean_text= PUNCT_PATTERN.sub(' ', text.lower())
    final_tokens = [word for word in clean_text.split() if len(word) >= 3 and word not in ENGLISH_STOPWORDS]
    return final_tokens
