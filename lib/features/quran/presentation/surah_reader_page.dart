import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quran/quran.dart' as quran;

import '../../../core/recitation/recitation_progress_store.dart';
import '../../../theme/app_theme.dart';
import '../../home/presentation/streaming_recitation_page.dart';
import '../../saved/data/saved_bookmarks_store.dart';

class SurahReaderPage extends StatefulWidget {
  const SurahReaderPage({
    super.key,
    required this.surahNumber,
    this.initialAyahNumber,
  });

  final int surahNumber;
  final int? initialAyahNumber;

  @override
  State<SurahReaderPage> createState() => _SurahReaderPageState();
}

class _SurahReaderPageState extends State<SurahReaderPage> {
  double _fontSize = 24;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _targetAyahKey = GlobalKey();
  bool _initialScrollScheduled = false;

  @override
  void initState() {
    super.initState();
    SavedBookmarksStore.instance.ensureLoaded();
    // Opening a surah (from Quran, favorites, or saved) becomes the new
    // "Continue Reading" / resume point reflected on the home page.
    RecitationProgressStore.instance.save(
      widget.surahNumber,
      widget.initialAyahNumber ?? 1,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _openRecitation(int ayahNumber) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StreamingRecitationPage(
          surahNumber: widget.surahNumber,
          ayahNumber: ayahNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final surahNumber = widget.surahNumber;
    final surahNameEnglish = quran.getSurahNameEnglish(surahNumber);
    final surahNameArabic = quran.getSurahNameArabic(surahNumber);
    final verseCount = quran.getVerseCount(surahNumber);
    final initialAyahNumber = widget.initialAyahNumber;

    if (!_initialScrollScheduled &&
        initialAyahNumber != null &&
        initialAyahNumber >= 1 &&
        initialAyahNumber <= verseCount) {
      _initialScrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final targetContext = _targetAyahKey.currentContext;
        if (targetContext != null) {
          Scrollable.ensureVisible(
            targetContext,
            duration: const Duration(milliseconds: 250),
            alignment: 0.15,
          );
        }
      });
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: AppTheme.primary,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Back',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Column(
                            children: [
                              const SizedBox(height: 8),
                              Text(
                                surahNameEnglish,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                surahNameArabic,
                                style: GoogleFonts.amiriQuran(
                                  fontSize: 18,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Reading settings',
                          onPressed: _showFontSizeSheet,
                          icon: const Icon(
                            Icons.settings,
                            color: AppTheme.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    child: Row(
                      children: [
                        ValueListenableBuilder<List<SavedBookmark>>(
                          valueListenable:
                              SavedBookmarksStore.instance.bookmarks,
                          builder: (context, bookmarks, _) {
                            final isSaved = bookmarks.any(
                              (bookmark) =>
                                  bookmark.surahNumber == widget.surahNumber,
                            );
                            return IconButton(
                              tooltip: isSaved
                                  ? 'Remove from Saved'
                                  : 'Add to Saved',
                              onPressed: () async {
                                HapticFeedback.selectionClick();
                                await SavedBookmarksStore.instance
                                    .toggleSurahBookmark(
                                      surahNumber: widget.surahNumber,
                                      ayahNumber: widget.initialAyahNumber ?? 1,
                                    );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        isSaved
                                            ? 'Removed from Saved'
                                            : 'Added to Saved',
                                      ),
                                    ),
                                  );
                              },
                              icon: Icon(
                                isSaved
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                color: Colors.white,
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Center(
                            child: _RoundActionButton(
                              icon: Icons.mic_rounded,
                              onTap: () =>
                                  _openRecitation(widget.initialAyahNumber ?? 1),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: _showFontSizeSheet,
                          icon: const Icon(
                            Icons.text_fields,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      quran.basmala,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.amiriQuran(
                        fontSize: 24,
                        color: AppTheme.textPrimary,
                        height: 1.8,
                      ),
                    ),
                    Text(
                      '$verseCount verses • ${quran.getPlaceOfRevelation(surahNumber)}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.black.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 20),
                    for (
                      var verseNumber = 1;
                      verseNumber <= verseCount;
                      verseNumber++
                    ) ...[
                      if (verseNumber > 1)
                        ShaderMask(
                          shaderCallback: (bounds) => LinearGradient(
                            colors: [
                              AppTheme.primary.withValues(alpha: 0),
                              AppTheme.primary,
                              AppTheme.primary,
                              AppTheme.primary.withValues(alpha: 0),
                            ],
                            stops: const [0, 0.2, 0.8, 1],
                          ).createShader(bounds),
                          blendMode: BlendMode.srcIn,
                          child: Container(
                            height: 1,
                            color: AppTheme.primary,
                            margin: const EdgeInsets.symmetric(vertical: 20),
                          ),
                        ),
                      _VerseTile(
                        key: verseNumber == initialAyahNumber
                            ? _targetAyahKey
                            : null,
                        verseNumber: verseNumber,
                        arabic: quran.getVerse(
                          surahNumber,
                          verseNumber,
                          verseEndSymbol: true,
                        ),
                        translation: quran.getVerseTranslation(
                          surahNumber,
                          verseNumber,
                          translation: quran.Translation.enSaheeh,
                        ),
                        fontSize: _fontSize,
                        onRecite: () => _openRecitation(verseNumber),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFontSizeSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          decoration: const BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: AppTheme.outline,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Text size',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Slider(
                min: 20,
                max: 32,
                divisions: 6,
                value: _fontSize,
                activeColor: AppTheme.primary,
                onChanged: (value) {
                  setState(() => _fontSize = value);
                },
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Start recitation practice',
      child: Material(
        color: AppTheme.secondary,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
      ),
    );
  }
}

class _VerseTile extends StatelessWidget {
  const _VerseTile({
    super.key,
    required this.verseNumber,
    required this.arabic,
    required this.translation,
    required this.fontSize,
    this.onRecite,
  });

  final int verseNumber;
  final String arabic;
  final String translation;
  final double fontSize;
  final VoidCallback? onRecite;

  @override
  Widget build(BuildContext context) {
    return Column(
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
            if (onRecite != null)
              IconButton(
                onPressed: onRecite,
                icon: const Icon(Icons.mic_none_rounded),
                color: AppTheme.primary,
                visualDensity: VisualDensity.compact,
                tooltip: 'Recite this ayah',
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                arabic,
                textAlign: TextAlign.right,
                style: GoogleFonts.amiriQuran(
                  fontSize: fontSize,
                  height: 1.9,
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
    );
  }
}
