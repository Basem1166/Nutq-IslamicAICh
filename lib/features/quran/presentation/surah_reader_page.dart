import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quran/quran.dart' as quran;

import '../../../core/quran/surah_names.dart';
import '../../../core/recitation/recitation_progress_store.dart';
import '../../../theme/app_theme.dart';
import '../../activity/data/activity_store.dart';
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

class _SurahReaderPageState extends State<SurahReaderPage>
    with WidgetsBindingObserver {
  /// Shared with the text-size sheet, which lives in its own route and so
  /// can't be rebuilt by this State's setState.
  final ValueNotifier<double> _fontSize = ValueNotifier<double>(24);
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  late final List<GlobalKey> _ayahKeys = List<GlobalKey>.generate(
    quran.getVerseCount(widget.surahNumber),
    (_) => GlobalKey(),
  );
  final ActivitySessionTimer _activityTimer = ActivitySessionTimer();
  bool _initialScrollScheduled = false;

  /// The ayah currently at the top of the viewport, saved as the resume point.
  late int _visibleAyah;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SavedBookmarksStore.instance.ensureLoaded();
    _activityTimer.start();
    // Opening a surah becomes the new "Continue Reading" point. Without an
    // explicit ayah, resume where this surah was last read.
    final progress = RecitationProgressStore.instance;
    _visibleAyah =
        widget.initialAyahNumber ??
        progress.lastAyahOf(widget.surahNumber) ??
        1;
    progress.save(widget.surahNumber, _visibleAyah);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _activityTimer.start();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _activityTimer.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activityTimer.stop();
    _scrollController.dispose();
    _fontSize.dispose();
    super.dispose();
  }

  /// Fraction of the viewport height used as the "currently reading" line, and
  /// as the alignment when jumping to an ayah, so the two agree.
  static const double _readingLine = 0.15;

  /// Finds the first ayah whose bottom edge is below the reading line and
  /// saves it as the reading position.
  bool _onScrollEnd(ScrollEndNotification notification) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox) return false;
    final line =
        viewport.localToGlobal(Offset.zero).dy +
        viewport.size.height * _readingLine;
    for (var i = 0; i < _ayahKeys.length; i++) {
      final box = _ayahKeys[i].currentContext?.findRenderObject();
      if (box is! RenderBox) continue;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      if (bottom > line) {
        final ayah = i + 1;
        if (ayah != _visibleAyah) {
          _visibleAyah = ayah;
          RecitationProgressStore.instance.save(widget.surahNumber, ayah);
        }
        break;
      }
    }
    return false;
  }

  Future<void> _toggleBookmark(int ayahNumber) async {
    HapticFeedback.selectionClick();
    final saved = await SavedBookmarksStore.instance.toggleAyahBookmark(
      surahNumber: widget.surahNumber,
      ayahNumber: ayahNumber,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            saved ? 'Ayah $ayahNumber added to Saved' : 'Removed from Saved',
          ),
        ),
      );
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

  void _scheduleInitialScroll(int ayahNumber) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = _ayahKeys[ayahNumber - 1].currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 250),
          alignment: _readingLine,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final surahNumber = widget.surahNumber;
    final surahTitle = surahName(surahNumber);
    final surahNameArabic = quran.getSurahNameArabic(surahNumber);
    final verseCount = quran.getVerseCount(surahNumber);
    // Resume point: the requested ayah, or where this surah was last read.
    final initialAyahNumber = _visibleAyah;

    if (!_initialScrollScheduled) {
      _initialScrollScheduled = true;
      if (initialAyahNumber > 1 && initialAyahNumber <= verseCount) {
        _scheduleInitialScroll(initialAyahNumber);
      }
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
                                surahTitle,
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
                        // Balances the back button so the title stays centered.
                        const SizedBox(width: 48),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    child: Row(
                      children: [
                        // Mirrors the text-size button so the mic is centered.
                        const SizedBox(width: 48),
                        Expanded(
                          child: Center(
                            child: _RoundActionButton(
                              icon: Icons.mic_rounded,
                              onTap: () => _openRecitation(_visibleAyah),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Text size',
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
              key: _viewportKey,
              child: NotificationListener<ScrollEndNotification>(
                onNotification: _onScrollEnd,
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
                          key: _ayahKeys[verseNumber - 1],
                          surahNumber: surahNumber,
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
                          onToggleBookmark: () => _toggleBookmark(verseNumber),
                        ),
                      ],
                    ],
                  ),
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
              ValueListenableBuilder<double>(
                valueListenable: _fontSize,
                builder: (context, fontSize, _) {
                  return Slider(
                    min: 20,
                    max: 32,
                    divisions: 6,
                    value: fontSize,
                    label: fontSize.round().toString(),
                    activeColor: AppTheme.primary,
                    onChanged: (value) => _fontSize.value = value,
                  );
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
    required this.surahNumber,
    required this.verseNumber,
    required this.arabic,
    required this.translation,
    required this.fontSize,
    this.onRecite,
    this.onToggleBookmark,
  });

  final int surahNumber;
  final int verseNumber;
  final String arabic;
  final String translation;
  final ValueListenable<double> fontSize;
  final VoidCallback? onRecite;
  final VoidCallback? onToggleBookmark;

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
            if (onToggleBookmark != null)
              ValueListenableBuilder<List<SavedBookmark>>(
                valueListenable: SavedBookmarksStore.instance.bookmarks,
                builder: (context, _, _) {
                  final saved = SavedBookmarksStore.instance.isAyahSaved(
                    surahNumber,
                    verseNumber,
                  );
                  return IconButton(
                    onPressed: onToggleBookmark,
                    icon: Icon(
                      saved
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded,
                    ),
                    color: AppTheme.primary,
                    visualDensity: VisualDensity.compact,
                    tooltip: saved ? 'Remove bookmark' : 'Bookmark this ayah',
                  );
                },
              ),
            const SizedBox(width: 12),
            Expanded(
              child: ValueListenableBuilder<double>(
                valueListenable: fontSize,
                builder: (context, size, _) {
                  return Text(
                    arabic,
                    textAlign: TextAlign.right,
                    style: GoogleFonts.amiriQuran(
                      fontSize: size,
                      height: 1.9,
                      color: AppTheme.textPrimary,
                    ),
                  );
                },
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
