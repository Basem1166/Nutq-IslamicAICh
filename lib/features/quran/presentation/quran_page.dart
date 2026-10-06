import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quran/quran.dart' as quran;

import '../../../core/quran/surah_names.dart';
import '../../../theme/app_theme.dart';
import '../data/quran_search.dart';
import 'surah_reader_page.dart';

class QuranPage extends StatefulWidget {
  const QuranPage({super.key});

  @override
  State<QuranPage> createState() => _QuranPageState();
}

class _QuranPageState extends State<QuranPage> {
  final TextEditingController _searchController = TextEditingController();
  final PageController _pageController = PageController();

  int _selectedTab = 0;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = QuranSearch.search(_query);
    final searching = _query.trim().isNotEmpty;
    String label(String name, int count) =>
        searching ? '$name ($count)' : name;

    return Column(
      children: [
        _buildHeader(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: TextField(
            controller: _searchController,
            onChanged: _onQueryChanged,
            decoration: InputDecoration(
              hintText: 'Search surah, page, or juz',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppTheme.outline),
            ),
            child: Row(
              children: [
                _TabButton(
                  label: label('Surahs', results.surahs.length),
                  selected: _selectedTab == 0,
                  onTap: () => _switchTab(0),
                ),
                _TabButton(
                  label: label('Pages', results.pages.length),
                  selected: _selectedTab == 1,
                  onTap: () => _switchTab(1),
                ),
                _TabButton(
                  label: label('Juz', results.juz.length),
                  selected: _selectedTab == 2,
                  onTap: () => _switchTab(2),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: PageView(
            controller: _pageController,
            onPageChanged: (index) => setState(() => _selectedTab = index),
            children: [
              _SurahListView(
                surahs: results.surahs,
                onTapSurah: (surahNumber) =>
                    _showSurahReader(context, surahNumber),
              ),
              _PageListView(
                pages: results.pages,
                onTapPage: (pageNumber) => _showPageReader(context, pageNumber),
              ),
              _JuzListView(
                juz: results.juz,
                onTapJuz: (juzNumber) => _showJuzReader(context, juzNumber),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
    // "page 12" / "juz 30" jump straight to the matching tab.
    final scope = QuranSearch.search(value).explicitScope;
    if (scope != null && scope.index != _selectedTab) {
      _switchTab(scope.index);
    }
  }

  void _switchTab(int index) {
    setState(() => _selectedTab = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: AppTheme.primary,
                child: Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white.withValues(alpha: 0.96),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Quran',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Browse surahs, pages, and juz from the package data',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.black.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showSurahReader(BuildContext context, int surahNumber) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SurahReaderPage(surahNumber: surahNumber),
      ),
    );
  }

  Future<void> _showPageReader(BuildContext context, int pageNumber) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final pageData = quran.getPageData(pageNumber);
        final verses = <_VerseReference>[];

        for (final section in pageData) {
          final map = section as Map;
          final surahNumber = map['surah'] as int;
          final start = map['start'] as int;
          final end = map['end'] as int;
          for (var verseNumber = start; verseNumber <= end; verseNumber++) {
            verses.add(_VerseReference(surahNumber, verseNumber));
          }
        }

        return _SheetScaffold(
          title: 'Page $pageNumber',
          subtitle:
              '${pageData.length} section${pageData.length == 1 ? '' : 's'} on this page',
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            itemCount: verses.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final verse = verses[index];
              return _VerseTile(
                verseNumber: verse.verseNumber,
                arabic: quran.getVerse(
                  verse.surahNumber,
                  verse.verseNumber,
                  verseEndSymbol: true,
                ),
                translation: quran.getVerseTranslation(
                  verse.surahNumber,
                  verse.verseNumber,
                  translation: quran.Translation.enSaheeh,
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showJuzReader(BuildContext context, int juzNumber) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final juzMap = quran.getSurahAndVersesFromJuz(juzNumber);

        return _SheetScaffold(
          title: 'Juz $juzNumber',
          subtitle:
              '${juzMap.length} surah${juzMap.length == 1 ? '' : 's'} in this juz',
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            itemCount: juzMap.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final entry = juzMap.entries.elementAt(index);
              final surahNumber = entry.key;
              final range = entry.value as List;
              final start = range.first as int;
              final end = range.last as int;

              return _InfoTile(
                title: surahName(surahNumber),
                subtitle:
                    '${quran.getSurahNameArabic(surahNumber)} • Verses $start-$end',
                trailing: '${end - start + 1} ayahs',
                onTap: () => _showSurahReader(context, surahNumber),
              );
            },
          ),
        );
      },
    );
  }
}

class _SurahListView extends StatelessWidget {
  const _SurahListView({required this.surahs, required this.onTapSurah});

  final List<int> surahs;
  final ValueChanged<int> onTapSurah;

  @override
  Widget build(BuildContext context) {
    if (surahs.isEmpty) {
      return const Center(child: Text('No surahs matched your search'));
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: surahs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final surahNumber = surahs[index];
        return _SurahTile(
          surahNumber: surahNumber,
          onTap: () => onTapSurah(surahNumber),
        );
      },
    );
  }
}

class _PageListView extends StatelessWidget {
  const _PageListView({required this.pages, required this.onTapPage});

  final List<int> pages;
  final ValueChanged<int> onTapPage;

  @override
  Widget build(BuildContext context) {
    if (pages.isEmpty) {
      return const Center(child: Text('No pages matched your search'));
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: pages.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final pageNumber = pages[index];
        final pageData = quran.getPageData(pageNumber);
        return _InfoTile(
          title: 'Page $pageNumber',
          subtitle: _pageSummary(pageData),
          trailing:
              '${pageData.length} section${pageData.length == 1 ? '' : 's'}',
          onTap: () => onTapPage(pageNumber),
        );
      },
    );
  }

  String _pageSummary(List<dynamic> pageData) {
    final parts = <String>[];
    for (final section in pageData.take(2)) {
      final map = section as Map;
      final surahNumber = map['surah'] as int;
      final start = map['start'] as int;
      final end = map['end'] as int;
      parts.add('${surahName(surahNumber)} $start-$end');
    }
    return parts.join(' • ');
  }
}

class _JuzListView extends StatelessWidget {
  const _JuzListView({required this.juz, required this.onTapJuz});

  final List<int> juz;
  final ValueChanged<int> onTapJuz;

  @override
  Widget build(BuildContext context) {
    if (juz.isEmpty) {
      return const Center(child: Text('No juz matched your search'));
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: juz.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final juzNumber = juz[index];
        final juzMap = quran.getSurahAndVersesFromJuz(juzNumber);
        return _InfoTile(
          title: 'Juz $juzNumber',
          subtitle: _juzSummary(juzMap),
          trailing: '${juzMap.length} surah${juzMap.length == 1 ? '' : 's'}',
          onTap: () => onTapJuz(juzNumber),
        );
      },
    );
  }

  String _juzSummary(Map<dynamic, dynamic> juzMap) {
    final parts = <String>[];
    for (final entry in juzMap.entries.take(3)) {
      final surahNumber = entry.key as int;
      final range = entry.value as List;
      final start = range.first as int;
      final end = range.last as int;
      parts.add('${surahName(surahNumber)} $start-$end');
    }
    return parts.join(' • ');
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : AppTheme.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SurahTile extends StatelessWidget {
  const _SurahTile({required this.surahNumber, required this.onTap});

  final int surahNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final verseCount = quran.getVerseCount(surahNumber);
    final pageNumber = quran.getPageNumber(surahNumber, 1);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.outline),
          ),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Text(
                    '$surahNumber',
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                surahName(surahNumber),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${surahMeaning(surahNumber)} • ${quran.getPlaceOfRevelation(surahNumber)} • Page $pageNumber',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.black.withValues(alpha: 0.58),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          quran.getSurahNameArabic(surahNumber),
                          style: GoogleFonts.amiriQuran(
                            fontSize: 20,
                            color: AppTheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _StatChip(label: '$verseCount ayahs'),
                        const SizedBox(width: 8),
                        _StatChip(
                          label: 'Juz ${quran.getJuzNumber(surahNumber, 1)}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.outline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.black.withValues(alpha: 0.58),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                trailing,
                textAlign: TextAlign.end,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.92,
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: AppTheme.outline,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Colors.black.withValues(alpha: 0.6),
                              ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _VerseTile extends StatelessWidget {
  const _VerseTile({
    required this.verseNumber,
    required this.arabic,
    required this.translation,
  });

  final int verseNumber;
  final String arabic;
  final String translation;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppTheme.secondary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    '$verseNumber',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  arabic,
                  textAlign: TextAlign.right,
                  style: GoogleFonts.amiriQuran(
                    fontSize: 24,
                    height: 1.8,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            translation,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              height: 1.5,
              color: Colors.black.withValues(alpha: 0.72),
            ),
          ),
        ],
      ),
    );
  }
}

class _VerseReference {
  const _VerseReference(this.surahNumber, this.verseNumber);

  final int surahNumber;
  final int verseNumber;
}
