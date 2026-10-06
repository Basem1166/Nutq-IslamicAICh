"""
test_search.py
==============
Runs a batch of test queries against the running search server and prints
a clean, readable report for each one.

Usage:
    python test_search.py [--verbose] [--query INDEX]

    --verbose    Show BM25 token expansions, pre-rerank candidates, and
                 all debug fields from query_meta. Useful for diagnosing
                 ranking issues.
    --query N    Run only query number N (1-based). Useful for quick iteration
                 on a single failing query.

Expects the server to be running at http://localhost:8000

New in this version
-------------------
- Stage timing breakdown: shows classify / retrieve / fuse / rerank latency
  for every query so you can immediately see which stage is slow.
- BM25 debug: prints the exact query string sent to BM25 and the token list
  BM25 actually matched against (including Arabic expansions).
- Arabic supplement: shows the Arabic emotional/semantic keywords appended to
  the dense query vector.
- Reranker query: shows what string was sent to the cross-encoder (may differ
  from normalized_query when an Arabic supplement is appended).
- Pre-rerank top-5: shows the fusion candidates BEFORE reranking so you can
  see whether the right chunks were retrieved but got pushed down, vs never
  retrieved at all.
- Latency coloring: green <1s, yellow 1-3s, red >3s per query.
"""

import json
import time
import sys
import re
import argparse
import requests
from typing import Optional

BASE_URL = "https://rectangle-freeness-essence.ngrok-free.dev/v1"
#BASE_URL = "https://voyage-unneeded-stoppable.ngrok-free.dev/v1"


# ─── Test queries ─────────────────────────────────────────────────────────────
test_queries = [
    # ── named_concept (dense 0.5 · sparse 0.5) ─────────────────────────────
    
    {"q": "الصلاه",                                      "scope": "quran"},
    {"q": "ما هي أركان الإسلام الخمسة؟",                                      "scope": None},
    {"q": "تعريف الزكاة وشروطها",                                              "scope": None},
    {"q": "معنى التوحيد في القرآن",                                            "scope": "quran"},
    {"q": "أحكام الحج والعمرة",                                                "scope": None},
    {"q": "تعريف الإيمان في السنة النبوية",                                    "scope": "hadith"},
    {"q": "ما هو الشرك بالله؟",                                               "scope": None},
    {"q": "تعريف الصيام وأركانه",                                              "scope": None},
    {"q": "معنى الصلاة في الإسلام",                                            "scope": None},

    # ── fiqh (dense 0.6 · sparse 0.4) ──────────────────────────────────────
    {"q": "هل يجوز أكل لحم الخنزير في حالة الاضطرار؟",                        "scope": None},
    {"q": "أحكام الطهارة قبل الصلاة",                                          "scope": None},
    {"q": "شروط صحة الزواج في الإسلام",                                        "scope": None},
    {"q": "ما حكم الربا في القرآن والسنة؟",                                    "scope": None},
    {"q": "أحكام الطلاق والخلع",                                               "scope": None},
    {"q": "هل تجب الزكاة على الذهب والفضة؟",                                  "scope": None},
    {"q": "حكم الصلاة في وقت النهي",                                           "scope": None},
    {"q": "شروط وجوب صيام رمضان",                                              "scope": None},
    {"q": "أحكام الميراث للمرأة",                                              "scope": None},
    {"q": "هل يجوز التيمم عند عدم الماء؟",                                    "scope": None},

    # ── thematic (dense 0.7 · sparse 0.3) ──────────────────────────────────
    {"q": "آيات وأحاديث عن الصبر والشكر",                                     "scope": None},
    {"q": "ما يقوله القرآن عن يوم القيامة",                                    "scope": "quran"},
    {"q": "الأحاديث المتعلقة بحسن الخلق",                                     "scope": "hadith"},
    {"q": "موضوع العدل والمساواة في الإسلام",                                  "scope": None},
    {"q": "كيف تتحدث السنة عن حقوق الجار؟",                                   "scope": "hadith"},
    {"q": "آيات تتعلق بالرحمة والمغفرة",                                       "scope": "quran"},
    {"q": "موضوع التوبة والاستغفار في القرآن",                                 "scope": "quran"},
    {"q": "ما ورد عن الأمانة والصدق في الحديث",                                "scope": "hadith"},
    {"q": "آيات الرزق والتوكل على الله",                                       "scope": "quran"},
    {"q": "الأحاديث الواردة في فضل العلم",                                     "scope": "hadith"},

    # ── narrative (dense 0.75 · sparse 0.25) ────────────────────────────────
    {"q": "قصة سيدنا يوسف عليه السلام",                                        "scope": "quran"},
    {"q": "ما الذي حدث في غزوة بدر؟",                                          "scope": None},
    {"q": "قصة أصحاب الكهف",                                                   "scope": "quran"},
    {"q": "حادثة الإسراء والمعراج",                                             "scope": None},
    {"q": "قصة سيدنا موسى مع فرعون",                                           "scope": "quran"},
    {"q": "أحداث هجرة النبي إلى المدينة",                                      "scope": None},
    {"q": "قصة أيوب عليه السلام والصبر",                                        "scope": None},
    {"q": "ما حدث في فتح مكة؟",                                                "scope": None},
    # ── comparative (dense 0.7 · sparse 0.3) ────────────────────────────────
    {"q": "الفرق بين الزكاة والصدقة في القرآن والسنة",                         "scope": None},
    {"q": "ما الفرق بين الصلاة الفريضة والنافلة؟",                             "scope": None},
    {"q": "كيف يختلف الإيمان عن الإسلام في الأحاديث؟",                         "scope": "hadith"},
    {"q": "الفرق بين الحلال والحرام في الطعام",                                 "scope": None},
    {"q": "مقارنة بين التوبة والاستغفار",                                       "scope": None},
    {"q": "ما الفرق بين الخشوع والخضوع في العبادة؟",                           "scope": None},
    {"q": "الفرق بين النبي والرسول في القرآن",                                  "scope": "quran"},
    {"q": "كيف يتناول القرآن والحديث موضوع الصبر؟",                             "scope": None},
    # ── direct_reference (dense 0.5 · sparse 0.5) ──────────────────────────
    {"q": "سورة الفاتحة ",                                              "scope": None},
    {"q": "حديث إنما الأعمال بالنيات",                                        "scope": None},
    {"q": "آية الكرسي",                                                       "scope": "quran"},
    {"q": "حديث من كان يؤمن بالله واليوم الآخر",                              "scope": None},
    {"q": "سورة الإخلاص",                                                     "scope": "quran"},
    {"q": "حديث لا يؤمن أحدكم حتى يحب لأخيه ما يحب لنفسه",                  "scope": None},
    {"q": "آية لا إكراه في الدين",                                             "scope": "quran"},
    {"q": "حديث الصدق يهدي إلى البر",                                         "scope": None},
    # ── arabic_keyword (dense 0.1 · sparse 0.9) ─────────────────────────────
    {"q": "جهاد",                                                               "scope": None},
    {"q": "توبة استغفار",                                                       "scope": None},
    {"q": "صلاة الفجر",                                                         "scope": None},
    {"q": "زكاة الفطر",                                                         "scope": None},
    {"q": "نكاح مهر",                                                           "scope": None},
    {"q": "جنة نار",                                                            "scope": None},
    {"q": "دعاء كرب",                                                           "scope": None},
    {"q": "حجاب عفة",                                                           "scope": None},
    {"q": "فرائض سنة",                                                          "scope": None},

    # ── exact_arabic (dense 1.0 · sparse 0.0) ───────────────────────────────
    {"q": "إِنَّا أَعْطَيْنَاكَ الْكَوْثَرَ",                                 "scope": "quran"},
    {"q": "قُلْ هُوَ اللَّهُ أَحَدٌ",                                          "scope": "quran"},
    {"q": "وَمَا خَلَقْتُ الْجِنَّ وَالْإِنسَ إِلَّا لِيَعْبُدُونِ",         "scope": "quran"},
    {"q": "إِنَّمَا الْأَعْمَالُ بِالنِّيَّاتِ",                              "scope": "hadith"},
    {"q": "الدِّينُ النَّصِيحَةُ",                                             "scope": "hadith"},
    {"q": "كُلُّ نَفْسٍ ذَائِقَةُ الْمَوْتِ",                                 "scope": "quran"},
    {"q": "لَا إِكْرَاهَ فِي الدِّينِ",                                        "scope": "quran"},
    {"q": "إِنَّ اللَّهَ مَعَ الصَّابِرِينَ",                                 "scope": "quran"},

]

test_queries_1 = [

    # ── direct_reference (dense 0.5 · sparse 0.5) ──────────────────────────
    {"q": "سورة الفاتحة ",                                              "scope": None},
    {"q": "حديث إنما الأعمال بالنيات",                                        "scope": None},
    {"q": "آية الكرسي",                                                       "scope": "quran"},
    {"q": "حديث من كان يؤمن بالله واليوم الآخر",                              "scope": None},
    {"q": "سورة الإخلاص",                                                     "scope": "quran"},
    {"q": "حديث لا يؤمن أحدكم حتى يحب لأخيه ما يحب لنفسه",                  "scope": None},
    {"q": "آية لا إكراه في الدين",                                             "scope": "quran"},
    {"q": "حديث الصدق يهدي إلى البر",                                         "scope": None},

    # ── named_concept (dense 0.5 · sparse 0.5) ─────────────────────────────
    {"q": "ما هي أركان الإسلام الخمسة؟",                                      "scope": None},
    {"q": "تعريف الزكاة وشروطها",                                              "scope": None},
    {"q": "معنى التوحيد في القرآن",                                            "scope": "quran"},
    {"q": "أحكام الحج والعمرة",                                                "scope": None},
    {"q": "تعريف الإيمان في السنة النبوية",                                    "scope": "hadith"},
    {"q": "ما هو الشرك بالله؟",                                               "scope": None},
    {"q": "تعريف الصيام وأركانه",                                              "scope": None},
    {"q": "معنى الصلاة في الإسلام",                                            "scope": None},

    # ── fiqh (dense 0.6 · sparse 0.4) ──────────────────────────────────────
    {"q": "هل يجوز أكل لحم الخنزير في حالة الاضطرار؟",                        "scope": None},
    {"q": "أحكام الطهارة قبل الصلاة",                                          "scope": None},
    {"q": "شروط صحة الزواج في الإسلام",                                        "scope": None},
    {"q": "ما حكم الربا في القرآن والسنة؟",                                    "scope": None},
    {"q": "أحكام الطلاق والخلع",                                               "scope": None},
    {"q": "هل تجب الزكاة على الذهب والفضة؟",                                  "scope": None},
    {"q": "حكم الصلاة في وقت النهي",                                           "scope": None},
    {"q": "شروط وجوب صيام رمضان",                                              "scope": None},
    {"q": "أحكام الميراث للمرأة",                                              "scope": None},
    {"q": "هل يجوز التيمم عند عدم الماء؟",                                    "scope": None},

    # ── thematic (dense 0.7 · sparse 0.3) ──────────────────────────────────
    {"q": "آيات وأحاديث عن الصبر والشكر",                                     "scope": None},
    {"q": "ما يقوله القرآن عن يوم القيامة",                                    "scope": "quran"},
    {"q": "الأحاديث المتعلقة بحسن الخلق",                                     "scope": "hadith"},
    {"q": "موضوع العدل والمساواة في الإسلام",                                  "scope": None},
    {"q": "كيف تتحدث السنة عن حقوق الجار؟",                                   "scope": "hadith"},
    {"q": "آيات تتعلق بالرحمة والمغفرة",                                       "scope": "quran"},
    {"q": "موضوع التوبة والاستغفار في القرآن",                                 "scope": "quran"},
    {"q": "ما ورد عن الأمانة والصدق في الحديث",                                "scope": "hadith"},
    {"q": "آيات الرزق والتوكل على الله",                                       "scope": "quran"},
    {"q": "الأحاديث الواردة في فضل العلم",                                     "scope": "hadith"},

    # ── narrative (dense 0.75 · sparse 0.25) ────────────────────────────────
    {"q": "قصة سيدنا يوسف عليه السلام",                                        "scope": "quran"},
    {"q": "ما الذي حدث في غزوة بدر؟",                                          "scope": None},
    {"q": "قصة أصحاب الكهف",                                                   "scope": "quran"},
    {"q": "حادثة الإسراء والمعراج",                                             "scope": None},
    {"q": "قصة سيدنا موسى مع فرعون",                                           "scope": "quran"},
    {"q": "أحداث هجرة النبي إلى المدينة",                                      "scope": None},
    {"q": "قصة أيوب عليه السلام والصبر",                                        "scope": None},
    {"q": "ما حدث في فتح مكة؟",                                                "scope": None},

    # ── arabic_keyword (dense 0.1 · sparse 0.9) ─────────────────────────────
    {"q": "جهاد",                                                               "scope": None},
    {"q": "توبة استغفار",                                                       "scope": None},
    {"q": "صلاة الفجر",                                                         "scope": None},
    {"q": "زكاة الفطر",                                                         "scope": None},
    {"q": "نكاح مهر",                                                           "scope": None},
    {"q": "جنة نار",                                                            "scope": None},
    {"q": "دعاء كرب",                                                           "scope": None},
    {"q": "حجاب عفة",                                                           "scope": None},
    {"q": "فرائض سنة",                                                          "scope": None},

    # ── exact_arabic (dense 1.0 · sparse 0.0) ───────────────────────────────
    {"q": "إِنَّا أَعْطَيْنَاكَ الْكَوْثَرَ",                                 "scope": "quran"},
    {"q": "قُلْ هُوَ اللَّهُ أَحَدٌ",                                          "scope": "quran"},
    {"q": "وَمَا خَلَقْتُ الْجِنَّ وَالْإِنسَ إِلَّا لِيَعْبُدُونِ",         "scope": "quran"},
    {"q": "إِنَّمَا الْأَعْمَالُ بِالنِّيَّاتِ",                              "scope": "hadith"},
    {"q": "الدِّينُ النَّصِيحَةُ",                                             "scope": "hadith"},
    {"q": "كُلُّ نَفْسٍ ذَائِقَةُ الْمَوْتِ",                                 "scope": "quran"},
    {"q": "لَا إِكْرَاهَ فِي الدِّينِ",                                        "scope": "quran"},
    {"q": "إِنَّ اللَّهَ مَعَ الصَّابِرِينَ",                                 "scope": "quran"},

    # ── comparative (dense 0.7 · sparse 0.3) ────────────────────────────────
    {"q": "الفرق بين الزكاة والصدقة في القرآن والسنة",                         "scope": None},
    {"q": "ما الفرق بين الصلاة الفريضة والنافلة؟",                             "scope": None},
    {"q": "كيف يختلف الإيمان عن الإسلام في الأحاديث؟",                         "scope": "hadith"},
    {"q": "الفرق بين الحلال والحرام في الطعام",                                 "scope": None},
    {"q": "مقارنة بين التوبة والاستغفار",                                       "scope": None},
    {"q": "ما الفرق بين الخشوع والخضوع في العبادة؟",                           "scope": None},
    {"q": "الفرق بين النبي والرسول في القرآن",                                  "scope": "quran"},
    {"q": "كيف يتناول القرآن والحديث موضوع الصبر؟",                             "scope": None},
]

# test_queries = [
#     # [1]  Arabic fiqh question
#     {"q": "ما هي أركان الإسلام الخمسة؟", "scope": None},
#     # [2]  English thematic
#     {"q": "What is the reward for patience in hardship?", "scope": None},
#     # [3]  Arabic thematic
#     {"q": "الصلاة والزكاة", "scope": None},
#     # [4]  Arabic thematic — virtue of Quran recitation
#     {"q": "فضل قراءة القرآن", "scope": None},
#     # [5]  Arabic fiqh — hadith scope override -> should NOT leak Quran results
#     {"q": "حكم الصيام في رمضان", "scope": "hadith"},
#     # [6]  Arabic fiqh
#     {"q": "الحج وشروطه", "scope": None},
#     # [7]  Arabic thematic — good character
#     {"q": "حسن الخلق والرحمة بالناس", "scope": None},
#     # [8]  Arabic narrative
#     {"q": "قصه موسى و فرعون", "scope": None},
#     # [9]  Arabic fiqh
#     {"q": "أحكام الطلاق", "scope": None},
#     # [10] Named concept (transliterated)
#     {"q": "Ayat al Kursi", "scope": None},
#     # [11] Named concept (Arabic)
#     {"q": "آية الكرسي", "scope": None},
#     # [12] English thematic — niyyah / intentions
#     {"q": "People are rewarded based on what is inside their hearts", "scope": None},
#     # [13] Arabic thematic — creation from one soul
#     {"q": "خلق الرجال والنساء من نفس واحدة", "scope": None},
#     # [14] Arabic keyword — anger
#     {"q": "غضب", "scope": None},
#     # [15] English thematic — tawakkul
#     {"q": "ayah about tawakkul", "scope": None},
#     # [16] Mixed — hadiths about parents
#     {"q": "hadith about بر الوالدين", "scope": None},
#     # [17] Transliteration — Prophet (should match alias)
#     {"q": "muhamad", "scope": None},
#     # [18] Arabic keyword — paradise
#     {"q": "الجنة", "scope": None},
#     # [19] English thematic — forgiveness (misspelled intentionally)
#     {"q": "forgivness", "scope": None},
#     # [20] Exact Quranic fragment — Q 2:152
#     {"q": "اذكروني أذكركم", "scope": None},
#     # [21] English thematic — sabr
#     {"q": "Allah is with the patient", "scope": None},
#     # [22] English fiqh
#     {"q": "marriage", "scope": None},
#     # [23] English fiqh
#     {"q": "inheritance", "scope": None},
#     # [24] Arabic keyword — trade (BM25 injection issue)
#     {"q": "التجارة", "scope": None},
#     # [25] English narrative — Ibrahim
#     {"q": "Ibrahim", "scope": None},
#     # [26] Arabic keyword — Pharaoh (RRF anomaly)
#     {"q": "فرعون", "scope": None},
#     # [27] Named concept (Arabic) — Maryam
#     {"q": "مريم", "scope": None},
#     # [28] English comparative — zakat vs sadaqah
#     {"q": "What is the difference between zakat and sadaqah?", "scope": None},
#     # [29] Arabic comparative — fear vs hope
#     {"q": "ما الفرق بين الخوف والرجاء؟", "scope": None},
#     # [30] English thematic — honesty (high latency)
#     {"q": "hadiths about honesty and trust", "scope": None},
#     # [31] Arabic thematic — patience and prayer (high latency)
#     {"q": "آيات عن الصبر والصلاة", "scope": None},
#     # [32] English emotional — hopeless (zero-precision, high latency)
#     {"q": "verses for someone feeling hopeless", "scope": None},
#     # [33] English emotional/prescriptive — scared (zero-precision, high latency)
#     {"q": "what should I read when I am scared", "scope": None},
#     # [34] Arabic thematic — overthinking (high latency)
#     {"q": "آيات عن كثرة التفكير", "scope": None},
#     # [35] Exact Quranic fragment — Q 94:6
#     {"q": "بعد العسر يسرا", "scope": None},
#     # [36] Quoted hadith phrase — Bukhari #1
#     {"q": '"إنما الأعمال بالنيات"', "scope": None},
# ]




# ─── Color helpers ────────────────────────────────────────────────────────────

COLORS = {
    "reset":   "\033[0m",
    "bold":    "\033[1m",
    "cyan":    "\033[96m",
    "green":   "\033[92m",
    "yellow":  "\033[93m",
    "red":     "\033[91m",
    "magenta": "\033[95m",
    "gray":    "\033[90m",
    "blue":    "\033[94m",
    "white":   "\033[97m",
}


def c(text: str, color: str) -> str:
    return f"{COLORS.get(color, '')}{text}{COLORS['reset']}"


def latency_color(ms: float) -> str:
    """Color a latency value: green <1s, yellow 1-3s, red >3s."""
    if ms < 1000:
        return c(f"{ms:.0f}ms", "green")
    if ms < 3000:
        return c(f"{ms:.0f}ms", "yellow")
    return c(f"{ms:.0f}ms", "red")


def score_color(score: float) -> str:
    """Color a reranker score: green >0.4, yellow 0.15-0.4, red <0.15."""
    if score >= 0.4:
        return c(f"{score:.4f}", "green")
    if score >= 0.15:
        return c(f"{score:.4f}", "yellow")
    return c(f"{score:.4f}", "red")


def source_color(source_type: str) -> str:
    mapping = {
        "Quran_Tafsir":   "green",
        "Quran_Passage":  "blue",
        "Hadith":         "yellow",
        "Hadith_Cluster": "magenta",
    }
    return mapping.get(source_type, "gray")


# ─── Logger (tee to file) ─────────────────────────────────────────────────────

class Logger:
    def __init__(self, filename):
        self.terminal = sys.stdout
        self.log = open(filename, "w", encoding="utf-8")
        self._ansi_re = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

    def write(self, message):
        self.terminal.write(message)
        self.log.write(self._ansi_re.sub('', message))

    def flush(self):
        self.terminal.flush()
        self.log.flush()


# ─── Search function ──────────────────────────────────────────────────────────

def search(query: str, top_k: int = 10, scope: Optional[str] = None) -> dict:
    payload = {
        "query":   query,
        "top_k":   top_k,
        "filters": {"scope": scope},
    }
    response = requests.post(f"{BASE_URL}/search", json=payload, headers={"ngrok-skip-browser-warning": "true"}, timeout=120)
    response.raise_for_status()
    return response.json()


# ─── Display helpers ──────────────────────────────────────────────────────────

def format_chunk_preview(chunk: dict, source_type: str) -> list[str]:
    """Return display lines for one result chunk."""
    lines = []
    indent = "      "

    if source_type == "Quran_Tafsir":
        ref = f"Q {chunk.get('surah_id')}:{chunk.get('ayah_id')}"
        lines.append(f"{indent}{c('Ref:', 'gray')} {ref}")
        lines.append(f"{indent}{c('AR:', 'gray')}  {chunk.get('arabic_text', '')}")
        lines.append(f"{indent}{c('EN:', 'gray')}  {chunk.get('english_translation', '')}")

    elif source_type == "Quran_Passage":
        ref = (
            f"Q {chunk.get('surah_id')}:{chunk.get('start_ayah')}-{chunk.get('end_ayah')}"
            f"  (window={chunk.get('window_size')}, {chunk.get('ayah_count')} ayahs)"
        )
        lines.append(f"{indent}{c('Ref:', 'gray')} {ref}")
        for i, member in enumerate(chunk.get("members", [])):
            ayah_num = member.get('ayah_id', i + 1)
            lines.append(f"{indent}{c(f'— Ayah {ayah_num}:', 'blue')}")
            lines.append(f"{indent}{c('AR:', 'gray')}  {member.get('arabic_text', '')}")
            lines.append(f"{indent}{c('EN:', 'gray')}  {member.get('english_translation', '')}")
            if i < len(chunk.get("members", [])) - 1:
                lines.append("")

    elif source_type == "Hadith":
        ref = f"{chunk.get('book_name', '')}  #{chunk.get('hadith_id', '')}"
        lines.append(f"{indent}{c('Ref:', 'gray')} {ref}")
        lines.append(f"{indent}{c('AR:', 'gray')}  {chunk.get('arabic_text', '')}")
        lines.append(f"{indent}{c('EN:', 'gray')}  {chunk.get('english_text', '')}")

    elif source_type == "Hadith_Cluster":
        ref = (
            f"{chunk.get('book_name', '')}  ch.{chunk.get('chapter_id', '')}"
            f"  ({chunk.get('hadith_count', 0)} hadiths)"
        )
        lines.append(f"{indent}{c('Ref:', 'gray')} {ref}")
        members = chunk.get("members", [])
        if members:
            lines.append(f"{indent}{c('EN:', 'gray')}  {members[0].get('english_text', '')}")
    else:
        lines.append(f"{indent}{c('chunk_id:', 'gray')} {chunk.get('chunk_id', '')}")

    return lines


def print_debug_meta(meta: dict, verbose: bool, debug_log: list = []):
    """Print all debug fields from query_meta."""
    indent = "  "

    # ── Stage timings ─────────────────────────────────────────────────────────
    timings = meta.get("stage_timings_ms", {})
    if timings:
        parts = []
        for stage in ["classify_ms", "retrieve_ms", "fuse_ms", "rerank_ms"]:
            if stage in timings:
                label = stage.replace("_ms", "")
                parts.append(f"{c(label, 'gray')}={latency_color(timings[stage])}")
        if "dense_hits" in timings:
            parts.append(c(f"dense_hits={timings['dense_hits']}", "gray"))
        if "bm25_hits" in timings:
            parts.append(c(f"bm25_hits={timings['bm25_hits']}", "gray"))
        print(f"{indent}{c('⏱ stages:', 'cyan')}  " + "  ".join(parts))

        if debug_log:
            print(f"  {c('🪵 debug log:', 'cyan')}")
            for line in debug_log:
                # Color by level for easy scanning
                if "ERROR" in line:
                    print(f"    {c(line, 'red')}")
                elif "WARNING" in line:
                    print(f"    {c(line, 'yellow')}")
                elif "DEBUG" in line:
                    print(f"    {c(line, 'gray')}")
                else:
                    print(f"    {line}")

    if not verbose:
        return

    # ── BM25 debug ────────────────────────────────────────────────────────────
    bm25_query = meta.get("bm25_query_sent", "")
    bm25_tokens = meta.get("bm25_tokens", [])
    if bm25_query or bm25_tokens:
        print(f"{indent}{c('BM25 query:', 'cyan')}  {bm25_query}")
        token_display = ", ".join(f'"{t}"' for t in bm25_tokens[:20])
        if len(bm25_tokens) > 20:
            token_display += f" … (+{len(bm25_tokens)-20} more)"
        print(f"{indent}{c('BM25 tokens:', 'cyan')} [{token_display}]  "
              f"{c(f'({len(bm25_tokens)} total)', 'gray')}")

    # ── Arabic supplement ─────────────────────────────────────────────────────
    arabic_supp = meta.get("arabic_supplement", "")
    if arabic_supp:
        print(f"{indent}{c('Arabic supp:', 'cyan')} {arabic_supp}")

    # ── Reranker query ────────────────────────────────────────────────────────
    reranker_q = meta.get("reranker_query", "")
    norm_q     = meta.get("normalized_query", "")
    if reranker_q and reranker_q != norm_q:
        print(f"{indent}{c('Reranker Q:', 'cyan')}  {reranker_q}")

    # ── Comparative concepts ──────────────────────────────────────────────────
    concepts = meta.get("comparative_concepts", [])
    if concepts:
        print(f"{indent}{c('Concepts:', 'cyan')}   {concepts[0]}  ↔  {concepts[1]}")

    # ── Pre-rerank top-5 ─────────────────────────────────────────────────────
    pre_rerank = meta.get("pre_rerank_top5", [])
    if pre_rerank:
        print(f"{indent}{c('Pre-rerank:', 'cyan')}")
        for i, cand in enumerate(pre_rerank, start=1):
            dr = cand.get("dense_rank")
            br = cand.get("bm25_rank")
            rrf = cand.get("rrf_score", 0)
            print(
                f"{indent}  {c(f'#{i}', 'bold')}  "
                f"{c(cand['chunk_id'], 'white')}  "
                f"{c(f'rrf={rrf:.5f}', 'gray')}  "
                f"{c(f'dense={dr}', 'blue')}  "
                f"{c(f'bm25={br}', 'yellow')}"
            )

    # ── Classifier debug trace ────────────────────────────────────────────────
    cls_debug = meta.get("classifier_debug", {})
    if cls_debug:
        for key, val in cls_debug.items():
            if val:
                print(f"{indent}{c(f'cls.{key}:', 'gray')} {val}")

    # ── Fusion stats ─────────────────────────────────────────────────────────
    fusion_count = meta.get("fusion_candidate_count")
    if fusion_count is not None:
        print(f"{indent}{c('Fusion candidates:', 'gray')} {fusion_count}")




def print_result(i: int, result: dict):
    source_type = result.get("source_type", "unknown")
    chunk       = result.get("chunk", {})
    col         = source_color(source_type)

    chunk_id  = result.get("chunk_id", "")
    rel_marker = ""

    rank_str   = c(f"  #{i}", "bold")
    type_str   = c(f"[{source_type}]", col)
    score_str  = score_color(result.get("reranker_score", 0))
    rrf_str    = c(f"rrf={result.get('rrf_score', 0):.5f}", "gray")
    dense_str  = c(f"dense={result.get('dense_rank')}", "gray")
    bm25_str   = c(f"bm25={result.get('bm25_rank')}", "gray")
    comp_str   = ""
    if result.get("comparative_concept"):
        comp_str = c(f"  [{result['comparative_concept']}]", "magenta")

    print(
        f"{rank_str}{rel_marker}  {type_str}  {score_str}  {rrf_str}  "
        f"{dense_str}  {bm25_str}{comp_str}"
    )
    for line in format_chunk_preview(chunk, source_type):
        print(line)


def print_query_header(
    idx: int,
    query_item: dict,
    meta: dict,
    latency: float,
    total: int,
):
    query = query_item["q"]
    scope_override = query_item.get("scope")
    bar = "─" * 72

    print(f"\n{bar}")
    print(
        f"  {c(f'[{idx}/{total}]', 'cyan')}  {c(query, 'bold')}"
        + (f"  {c(f'(scope={scope_override})', 'magenta')}" if scope_override else "")
    )
    print(
        f"  {c('lang:', 'gray')} {meta.get('detected_language')}"
        f"  {c('type:', 'gray')} {c(meta.get('query_type','?'), 'yellow')}"
        f"  {c('scope:', 'gray')} {meta.get('scope')}"
        f"  {c('early_exit:', 'gray')} {meta.get('early_exit')}"
        f"  {c('latency:', 'gray')} {latency_color(latency)}"
    )
    norm = meta.get("normalized_query", "")
    orig = meta.get("original_query", "")
    if norm and norm != orig:
        print(f"  {c('normalized:', 'gray')} {norm}")
    lexical = meta.get("lexical_query", "")
    if lexical and lexical != norm and lexical != orig:
        print(f"  {c('lexical_q:', 'gray')}  {lexical[:120]}")
    print()

# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true",
                        help="Show BM25 tokens, pre-rerank candidates, and all debug fields")
    parser.add_argument("--query", type=int, default=None,
                        help="Run only this query number (1-based)")
    args = parser.parse_args()

    log_file = "search_test_results_kaggle.txt"
    sys.stdout = Logger(log_file)

    print(c(f"🚀 Starting Test. Results will be saved to: {log_file}", "magenta"))
    if args.verbose:
        print(c("   Verbose mode: ON — BM25 tokens, pre-rerank, and debug fields shown", "cyan"))

    # ── Health check ─────────────────────────────────────────────────────────
    print(c("\nChecking server health ...", "cyan"))
    try:
        health = requests.get(f"{BASE_URL}/health", headers={"ngrok-skip-browser-warning": "true"}, timeout=10).json()
        status = health.get("status", "unknown")
        color  = "green" if status == "ok" else "red"
        print(c(f"  Server status: {status}", color))
        faiss_stats = health.get("indexes", {}).get("faiss", {})
        bm25_stats  = health.get("indexes", {}).get("bm25", {})
        total_vecs = faiss_stats.get('total_vectors')
        print(f"  FAISS: {f'{total_vecs:,}' if isinstance(total_vecs, int) else '?'} vectors")

        total_docs = bm25_stats.get('documents')
        print(f"  BM25:  {f'{total_docs:,}' if isinstance(total_docs, int) else '?'} documents")
        cache = health.get("cache", {})
        if cache:
            print(
                f"  Cache: size={cache.get('size')}/{cache.get('max')}  "
                f"hit_rate={cache.get('hit_rate')}"
            )
    except Exception as e:
        print(c(f"  Health check failed: {e}", "red"))
        print(c("  Is the server running at http://localhost:8000?", "red"))
        return

    # ── Determine which queries to run ───────────────────────────────────────
    if args.query is not None:
        idx_range = [args.query]
        queries_to_run = [(args.query, test_queries[args.query - 1])]
    else:
        queries_to_run = list(enumerate(test_queries, start=1))

    total = len(test_queries)
    print(c(f"\nRunning {len(queries_to_run)} test quer{'y' if len(queries_to_run)==1 else 'ies'} ...", "cyan"))

    # ── Stats ─────────────────────────────────────────────────────────────────
    total_latency    = 0.0
    errors: list     = []
    type_counts:  dict = {}
    scope_counts: dict = {}
    early_exits      = 0
    latency_by_type: dict[str, list[float]] = {}
    slow_queries: list = []

    for idx, query_item in queries_to_run:
        query = query_item["q"]
        scope = query_item.get("scope")

        try:
            t0       = time.perf_counter()
            response = search(query, top_k=10, scope=scope)
            elapsed  = (time.perf_counter() - t0) * 1000

            meta    = response.get("query_meta", {})
            results = response.get("results", [])
            latency = response.get("latency_ms", elapsed)
            debug_log  = response.get("debug_log", [])
            total_latency += latency

            if latency > 3000:
                slow_queries.append((idx, query[:60], latency))

            qtype = meta.get("query_type", "unknown")
            scope_val = meta.get("scope", "unknown")
            type_counts[qtype]    = type_counts.get(qtype, 0) + 1
            scope_counts[scope_val] = scope_counts.get(scope_val, 0) + 1
            latency_by_type.setdefault(qtype, []).append(latency)
            if meta.get("early_exit"):
                early_exits += 1

            print_query_header(idx, query_item, meta, latency, total)
            print_debug_meta(meta, verbose=args.verbose, debug_log=debug_log)

            if not results:
                print(c("  ⚠  No results returned.", "red"))
            else:
                for result in results:
                    print_result(result["final_rank"], result)
                    print()

        except Exception as e:
            errors.append((idx, query, str(e)))
            print(c(f"\n  ✗ ERROR for query [{idx}] '{query}': {e}", "red"))

    # ── Summary ───────────────────────────────────────────────────────────────
    num_run = len(queries_to_run)
    print("\n" + "═" * 72)
    print(c("  SUMMARY", "bold"))
    print("═" * 72)
    print(f"  Queries run    : {num_run}")
    print(f"  Errors         : {c(str(len(errors)), 'red' if errors else 'green')}")
    print(f"  Early exits    : {early_exits}")
    avg_lat = total_latency / max(num_run, 1)
    print(f"  Avg latency    : {latency_color(avg_lat)}")

    # Slow queries
    if slow_queries:
        print()
        print(c("  ⚠ Slow queries (>3s):", "red"))
        for q_idx, q_text, q_lat in sorted(slow_queries, key=lambda x: -x[2]):
            print(f"    [{q_idx}] {latency_color(q_lat)}  {q_text}")

    # Latency by type
    print()
    print(f"  Avg latency by type:")
    for qtype, lats in sorted(latency_by_type.items()):
        avg = sum(lats) / len(lats)
        print(f"    {qtype:<22}  {latency_color(avg)}  (n={len(lats)})")

    # Query type distribution
    print()
    print(f"  Query types:")
    for qtype, count in sorted(type_counts.items(), key=lambda x: -x[1]):
        print(f"    {qtype:<22}  {count}")

    # Scope distribution
    print()
    print(f"  Corpus scope:")
    for scope, count in sorted(scope_counts.items(), key=lambda x: -x[1]):
        print(f"    {scope:<22}  {count}")

    # Errors
    if errors:
        print()
        print(c("  Failed queries:", "red"))
        for q_idx, q_text, err in errors:
            print(f"    [{q_idx}] {q_text[:60]} -> {err}")

    print("═" * 72)
    print(c(f"\n✅ Results saved to: {log_file}", "green"))


if __name__ == "__main__":
    main()