"""Latin spelling variants of a transliterated Arabic word or phrase.

"surah al-baqarah" is also written "al baqara", "albaqarah", "el-bakara"; "ibrahim" is "ibraheem",
"ebrahim"; "zakat" is "zakaat". latin_variants() produces those forms so the transliteration table and the
surah-name lookup only need one canonical spelling per entry.

Edits on each content word (up to `depth` of them, combined):
  - long vowels written doubled or single: ee/i, oo/u, aa/a, ou/u
  - final taa marbuta: -ah / -a
  - doubled consonants collapsed: muhammad -> muhamad, hajj -> haj
  - apostrophes dropped: ka'bah -> kabah
  - q -> k, dh -> z (common in Urdu / Turkish / Malay spellings)
and on the whole phrase:
  - the article: al-/al /al/el-, and the assimilated an-/ar-/ash-/at-... before sun letters
  - word separators: space / hyphen (/ nothing after an article or particle like abu, ibn, umm)
"""
import itertools
import re

ARTICLES= frozenset({"al", "el", "ul", "an", "ar", "as", "at", "ash", "adh", "ad", "az", "ath", "aj"})
# words that are written joined to the next one as often as apart ("abubakr", "abdulrahman")
PARTICLES= frozenset({"abu", "ibn", "bin", "bint", "umm", "ahl", "dhul", "zul", "abd", "abdul", "bani", "dhu", "ya"})
SUN_PREFIXES= ("th", "sh", "dh", "t", "d", "r", "z", "s", "n", "l")
CONSONANTS= "bcdfghjklmnpqrstvwxyz"
APOSTROPHES= "'’`ʿʾ"
MAX_VARIANTS= 150


def _content_edits(word: str, lengthen: bool) -> set[str]:
    """Single spelling edits of one content word."""
    out= set()
    stripped= word
    for ch in APOSTROPHES:
        stripped= stripped.replace(ch, "")
    if stripped != word:
        out.add(stripped)
    for long, short in (("ee", "i"), ("oo", "u"), ("aa", "a"), ("ou", "u")):
        if long in word:
            out.add(word.replace(long, short))
    if lengthen and not re.search(r"ee|oo|ou", word):
        # one long vowel spelled doubled (yusuf -> yoosuf / yusoof, ibrahim -> ibraheem), never the first letter
        for short, long in (("i", "ee"), ("u", "oo"), ("u", "ou")):
            for m in re.finditer(short, word):
                k= m.start()
                if k > 0 and word[k - 1] not in "aeiou" and word[k + 1:k + 2] not in "aeiou":
                    out.add(word[:k] + long + word[k + 1:])
        # long final "a" doubled: zakat -> zakaat, iman -> imaan, salat -> salaat
        last_a= re.search(r"(?<=[^aeiou])a(?=[^aeiou]h?$)", word)
        if last_a:
            out.add(word[:last_a.start()] + "aa" + word[last_a.end():])
    # u written o: umar -> omar, uthman -> othman, yunus -> yonus
    for m in re.finditer("u", word):
        k= m.start()
        if word[k + 1:k + 2] != "u" and word[k - 1:k] != "o":
            out.add(word[:k] + "o" + word[k + 1:])
    # leading i written e: ibrahim -> ebrahim, iman -> eman
    if word.startswith("i") and len(word) > 3:
        out.add("e" + word[1:])
    # last vowel a / i written e: ahmad -> ahmed, muhammad -> muhammed, ibrahim -> ibrahem
    last_vowel= re.search(r"(?<=[^aeiou])[ai](?=[^aeiou]+$)", word)
    if last_vowel and last_vowel.start() > 0:
        out.add(word[:last_vowel.start()] + "e" + word[last_vowel.end():])
    # d written dh: ramadan -> ramadhan, wudu -> wudhu
    for m in re.finditer(r"d(?!h)", word):
        k= m.start()
        if k > 0:
            out.add(word[:k] + "dh" + word[k + 1:])
    if word.endswith("ah") and len(word) > 4:
        out.add(word[:-1])
    elif word.endswith("a") and len(word) > 3 and word[-2] in CONSONANTS:
        out.add(word + "h")
    collapsed= re.sub(rf"([{CONSONANTS}])\1", r"\1", word)
    if collapsed != word:
        out.add(collapsed)
    if "q" in word:
        out.add(word.replace("q", "k"))
    if "dh" in word:
        out.add(word.replace("dh", "z"))
    out.discard(word)
    return {w for w in out if len(w) >= 2 and not re.search(r"(.)\1\1", w)}


def _word_forms(word: str, depth: int, lengthen: bool) -> list[str]:
    forms= {word}
    frontier= {word}
    for step in range(depth):
        # lengthening only on the original spelling -> at most one doubled vowel is added
        frontier= {e for w in frontier for e in _content_edits(w, lengthen and step == 0)} - forms
        forms |= frontier
    # the original first, then shortest edits first -> stable, and the cap keeps the closest spellings
    return sorted(forms, key=lambda w: (w != word, abs(len(w) - len(word)), w))


def _article_forms(next_word: str) -> list[str]:
    forms= ["al", "el"]
    for sun in SUN_PREFIXES:
        if next_word.startswith(sun):
            forms.append("a" + sun)
            break
    return forms


def latin_variants(key: str, depth: int= 2, lengthen: bool= True, max_variants: int= MAX_VARIANTS,
                   fixed_words: frozenset= frozenset()) -> set[str]:
    """Spelling variants of `key` (lowercase), not including `key` itself.
    Words in `fixed_words` (ordinary English words like "day", "of") keep their spelling.
    """
    key= key.lower().strip()
    if not key or not re.fullmatch(rf"[a-z{APOSTROPHES}\- ]+", key):
        return set()
    words= [w for w in re.split(r"[\s\-]+", key) if w]
    if not words:
        return set()

    content_count= sum(1 for i, w in enumerate(words) if not ((w in ARTICLES or w in PARTICLES) and i + 1 < len(words)))
    per_word= max(3, 12 // max(content_count, 1))
    slots= []    # per word: spellings, closest first
    joins= []    # per gap between word i and i+1: separators, the original's first
    for i, word in enumerate(words):
        nxt= words[i + 1] if i + 1 < len(words) else ""
        if word in ARTICLES and nxt:
            slots.append(_article_forms(nxt))
            joins.append(["-", " ", ""])
        elif word in PARTICLES and nxt:
            slots.append([word])
            joins.append([" ", "", "-"])
        else:
            slots.append([word] if word in fixed_words else _word_forms(word, depth, lengthen)[:per_word])
            if nxt:
                joins.append([" ", "-"])
    original_seps= re.findall(r"[\s\-]+", key)

    scored= {}
    for spelled_idx in itertools.product(*[range(len(s)) for s in slots]):
        spelled= [slots[i][j] for i, j in enumerate(spelled_idx)]
        for seps in itertools.product(*joins):
            phrase= spelled[0] + "".join(sep + w for sep, w in zip(seps, spelled[1:]))
            if phrase == key:
                continue
            # distance from the original: spelling edits + separators that differ
            cost= sum(spelled_idx) + sum(1 for k, sep in enumerate(seps)
                                         if k >= len(original_seps) or sep != original_seps[k][:1])
            if phrase not in scored or cost < scored[phrase]:
                scored[phrase]= cost
    return set(sorted(scored, key=lambda ph: (scored[ph], ph))[:max_variants])
