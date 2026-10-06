import 'package:flutter_test/flutter_test.dart';
import 'package:nutq/core/quran/surah_names.dart';
import 'package:nutq/features/quran/data/quran_search.dart';

void main() {
  group('QuranSearch.searchSurahs', () {
    void expectTop(String query, int surah) {
      final results = QuranSearch.searchSurahs(query);
      expect(results, isNotEmpty, reason: 'no match for "$query"');
      expect(results.first, surah, reason: 'top match for "$query"');
    }

    test('exact and partial transliterations', () {
      expectTop('baqara', 2);
      expectTop('Al-Baqarah', 2);
      expectTop('al kahf', 18);
      expectTop('alkahf', 18);
      expectTop('fatiha', 1);
    });

    test('misspellings', () {
      expectTop('bakarah', 2);
      expectTop('yasin', 36);
      expectTop('rahmaan', 55);
      expectTop('ikhlass', 112);
    });

    test('Arabic names with or without article and diacritics', () {
      expectTop('الكهف', 18);
      expectTop('كهف', 18);
      expectTop('سورة البقرة', 2);
    });

    test('English meaning', () {
      expectTop('the cow', 2);
    });

    test('garbage returns nothing', () {
      expect(QuranSearch.searchSurahs('zzzzzz'), isEmpty);
    });
  });

  group('QuranSearch.search', () {
    test('empty query returns everything', () {
      final r = QuranSearch.search('');
      expect(r.surahs.length, 114);
      expect(r.pages.length, 604);
      expect(r.juz.length, 30);
    });

    test('plain number matches surah, page and juz', () {
      final r = QuranSearch.search('2');
      expect(r.surahs, [2]);
      expect(r.pages, [2]);
      expect(r.juz, [2]);
      expect(r.explicitScope, isNull);
    });

    test('number beyond juz range only matches pages/surahs', () {
      final r = QuranSearch.search('300');
      expect(r.surahs, isEmpty);
      expect(r.pages, [300]);
      expect(r.juz, isEmpty);
    });

    test('explicit page and juz queries', () {
      final page = QuranSearch.search('page 50');
      expect(page.pages, [50]);
      expect(page.explicitScope, QuranSearchScope.page);

      final juz = QuranSearch.search('juz 30');
      expect(juz.juz, [30]);
      expect(juz.explicitScope, QuranSearchScope.juz);

      expect(QuranSearch.search('صفحة ٣').pages, [3]);
      expect(QuranSearch.search('جزء 5').juz, [5]);
    });

    test('surah name also finds its pages and juz', () {
      final r = QuranSearch.search('kahf');
      expect(r.surahs.first, 18);
      expect(r.pages, containsAll([293, 304]));
      expect(r.juz, [15, 16]);
    });
  });

  test('surahName is transliterated', () {
    expect(surahName(2), 'Al-Baqarah');
    expect(surahMeaning(2), 'The Cow');
  });
}
