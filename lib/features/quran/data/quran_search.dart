import 'dart:math' as math;

import 'package:quran/quran.dart' as quran;

import '../../../core/quran/surah_names.dart';

/// Which list a query explicitly targets, e.g. "page 12" or "juz 30".
enum QuranSearchScope { surah, page, juz }

class QuranSearchResult {
  const QuranSearchResult({
    required this.surahs,
    required this.pages,
    required this.juz,
    this.explicitScope,
  });

  /// Matching surah numbers, best match first.
  final List<int> surahs;

  /// Matching mushaf page numbers, ascending.
  final List<int> pages;

  /// Matching juz numbers, ascending.
  final List<int> juz;

  /// Set when the query named a scope ("page 50", "جزء 3").
  final QuranSearchScope? explicitScope;
}

/// Fuzzy search over surahs, pages and juz for the Quran tab.
///
/// Surahs match by number or (fuzzily) by transliterated, English or Arabic
/// name. Pages and juz match by number, or by containing a matched surah.
class QuranSearch {
  QuranSearch._();

  /// Minimum similarity (0..1) for a fuzzy, non-substring surah match.
  static const double threshold = 0.7;

  static final RegExp _pageQuery = RegExp(r'^(?:page|pg|p|صفحه|ص)\s*(\d+)$');
  static final RegExp _juzQuery = RegExp(
    r'^(?:juz|juzz|jus|para|parah|الجزء|جزء|ج)\s*(\d+)$',
  );
  static final RegExp _surahQuery = RegExp(
    r'^(?:surah|surat|sura|سوره)\s*(\d+)$',
  );

  static QuranSearchResult search(String rawQuery) {
    final query = _basicNormalize(rawQuery);
    final allSurahs = List<int>.generate(quran.totalSurahCount, (i) => i + 1);
    final allPages = List<int>.generate(quran.totalPagesCount, (i) => i + 1);
    final allJuz = List<int>.generate(quran.totalJuzCount, (i) => i + 1);

    if (query.isEmpty) {
      return QuranSearchResult(surahs: allSurahs, pages: allPages, juz: allJuz);
    }

    final pageMatch = _pageQuery.firstMatch(query);
    if (pageMatch != null) {
      final n = int.parse(pageMatch.group(1)!);
      return QuranSearchResult(
        surahs: const [],
        pages: _inRange(n, quran.totalPagesCount),
        juz: const [],
        explicitScope: QuranSearchScope.page,
      );
    }
    final juzMatch = _juzQuery.firstMatch(query);
    if (juzMatch != null) {
      final n = int.parse(juzMatch.group(1)!);
      return QuranSearchResult(
        surahs: const [],
        pages: const [],
        juz: _inRange(n, quran.totalJuzCount),
        explicitScope: QuranSearchScope.juz,
      );
    }
    final surahMatch = _surahQuery.firstMatch(query);
    if (surahMatch != null) {
      final n = int.parse(surahMatch.group(1)!);
      return QuranSearchResult(
        surahs: _inRange(n, quran.totalSurahCount),
        pages: const [],
        juz: const [],
        explicitScope: QuranSearchScope.surah,
      );
    }

    final number = int.tryParse(query);
    if (number != null) {
      return QuranSearchResult(
        surahs: _inRange(number, quran.totalSurahCount),
        pages: _inRange(number, quran.totalPagesCount),
        juz: _inRange(number, quran.totalJuzCount),
      );
    }

    final scored = _scoreSurahs(query);
    final surahs = scored.map((e) => e.key).toList();
    // Pages/juz follow only the strongest surah matches, so a loose fuzzy hit
    // (e.g. "kahf" ~ "Kafirun") doesn't pull in unrelated pages.
    final cutoff = (scored.isNotEmpty && scored.first.value >= 0.95)
        ? 0.95
        : threshold;
    final surahSet = scored
        .where((e) => e.value >= cutoff)
        .map((e) => e.key)
        .toSet();
    final pages = surahSet.isEmpty
        ? const <int>[]
        : allPages.where((page) {
            return quran
                .getPageData(page)
                .any((section) => surahSet.contains((section as Map)['surah']));
          }).toList();
    final juz = surahSet.isEmpty
        ? const <int>[]
        : allJuz.where((n) {
            return quran
                .getSurahAndVersesFromJuz(n)
                .keys
                .any(surahSet.contains);
          }).toList();
    return QuranSearchResult(surahs: surahs, pages: pages, juz: juz);
  }

  /// Surah numbers whose names fuzzily match [rawQuery], best first.
  static List<int> searchSurahs(String rawQuery) =>
      _scoreSurahs(rawQuery).map((e) => e.key).toList();

  /// (surah, score) pairs at or above [threshold], best first.
  static List<MapEntry<int, double>> _scoreSurahs(String rawQuery) {
    final query = normalize(rawQuery);
    final queryWithArticle = normalize(rawQuery, stripArticle: false);
    if (query.isEmpty) return const [];

    final scored = <MapEntry<int, double>>[];
    for (var n = 1; n <= quran.totalSurahCount; n++) {
      var best = 0.0;
      for (final name in _surahCandidates(n)) {
        best = math.max(best, fuzzyScore(query, normalize(name)));
        best = math.max(
          best,
          fuzzyScore(queryWithArticle, normalize(name, stripArticle: false)),
        );
        if (best >= 1.0) break;
      }
      if (best >= threshold) scored.add(MapEntry(n, best));
    }
    scored.sort((a, b) {
      final byScore = b.value.compareTo(a.value);
      return byScore != 0 ? byScore : a.key.compareTo(b.key);
    });
    return scored;
  }

  static List<String> _surahCandidates(int n) => [
    surahName(n),
    quran.getSurahName(n),
    surahMeaning(n),
    quran.getSurahNameArabic(n),
  ];

  /// Similarity of [query] to [candidate] in 0..1, both already normalized.
  /// A prefix scores 1.0 and a substring 0.95. Otherwise the best edit-distance
  /// similarity against same-length windows of the candidate or the whole
  /// candidate. Queries shorter than 3 characters only match as substrings.
  static double fuzzyScore(String query, String candidate) {
    if (query.isEmpty || candidate.isEmpty) return 0;
    if (candidate.startsWith(query)) return 1.0;
    if (candidate.contains(query)) return 0.95;
    if (query.length < 3) return 0;

    var best =
        1 -
        _levenshtein(query, candidate) /
            math.max(query.length, candidate.length);
    for (final len in {query.length - 1, query.length, query.length + 1}) {
      if (len <= 0 || len > candidate.length) continue;
      for (var i = 0; i + len <= candidate.length; i++) {
        final window = candidate.substring(i, i + len);
        final score =
            1 - _levenshtein(query, window) / math.max(query.length, len);
        if (score > best) best = score;
      }
    }
    // Slightly prefer whole-name matches over partial-window ones.
    return best * 0.95;
  }

  /// Lowercases, folds Arabic letter variants, drops diacritics/punctuation and
  /// spaces, and (optionally) the leading definite article.
  static String normalize(String input, {bool stripArticle = true}) {
    var s = _basicNormalize(input);
    s = s.replaceFirst(RegExp(r'^(?:surah|surat|sura|سوره)\s*'), '');
    if (stripArticle) {
      s = s.replaceFirst(
        RegExp(r"^(?:aal|al|an|ar|as|ash|at|ad|adh|az)[\s\-']+"),
        '',
      );
      s = s.replaceFirst(RegExp(r'^ال'), '');
    }
    return s.replaceAll(RegExp(r'[^a-z0-9ء-ي]'), '');
  }

  /// Lowercase + Arabic folding + digit conversion, keeping spaces.
  static String _basicNormalize(String input) {
    var s = input.trim().toLowerCase();
    // Arabic-Indic digits -> ASCII.
    s = s.replaceAllMapped(
      RegExp('[٠-٩]'),
      (m) => '${m[0]!.codeUnitAt(0) - 0x0660}',
    );
    // Diacritics, Quranic marks, tatweel.
    s = s.replaceAll(RegExp('[ً-ٰٟۖ-ۭـ]'), '');
    s = s
        .replaceAll(RegExp('[آأإٱ]'), 'ا')
        .replaceAll('ة', 'ه')
        .replaceAll('ى', 'ي');
    return s.replaceAll(RegExp(r'\s+'), ' ');
  }

  static List<int> _inRange(int n, int max) =>
      (n >= 1 && n <= max) ? [n] : const [];

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = math.min(
          math.min(curr[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[b.length];
  }
}
