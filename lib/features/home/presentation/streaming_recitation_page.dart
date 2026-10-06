import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quran/quran.dart' as quran;
import 'package:quran_recitation_core/quran_recitation_core.dart';

import '../../../core/audio/reference_audio_player.dart';
import '../../../core/audio/reference_audio_service.dart';
import '../../../core/phonetizer_service.dart';
import '../../../core/quran/surah_names.dart';
import '../../../core/recitation/recitation_progress_store.dart';
import '../../../core/recitation/sifat_labels.dart';
import '../../../core/recitation/streaming_recitation_controller.dart';
import '../../../theme/app_theme.dart';
import '../../activity/data/activity_store.dart';
import '../../saved/data/saved_bookmarks_store.dart';

/// How the page lays out ayahs: the physical mushaf page that contains the
/// entry ayah, or the whole surah scrolling.
enum MushafViewMode { page, surah }

/// Full-page, mushaf-style live recitation. Renders every ayah of the current
/// page (or surah) at once, flowing right-to-left with the existing per-word
/// colouring. The reciter marks an ayah and presses Start; recitation matches
/// that ayah alone, then auto-advances down the page, persisting each finished
/// ayah's colours, and stops at the page's last ayah. Long-pressing an ayah
/// opens a menu (start here, hear reference, meaning, copy).
class StreamingRecitationPage extends StatefulWidget {
  const StreamingRecitationPage({
    super.key,
    required this.surahNumber,
    required this.ayahNumber,
    this.viewMode = MushafViewMode.page,
  });

  final int surahNumber;
  final int ayahNumber;
  final MushafViewMode viewMode;

  @override
  State<StreamingRecitationPage> createState() =>
      _StreamingRecitationPageState();
}

class _StreamingRecitationPageState extends State<StreamingRecitationPage> {
  final StreamingRecitationController _controller =
      StreamingRecitationController();
  final _audioService = ReferenceAudioService.instance;
  final ScrollController _scroll = ScrollController();

  MushafViewMode _viewMode = MushafViewMode.page;

  /// The mushaf page currently shown in [MushafViewMode.page]. Seeded from the
  /// entry ayah, then advanced/rewound by the page-flip controls. The total
  /// mushaf is 604 pages.
  int _pageNumber = 1;
  static const int _lastMushafPage = 604;

  /// The surah currently shown in [MushafViewMode.surah]. Seeded from the entry
  /// surah, then advanced/rewound by surah-flip. The Quran has 114 surahs. Kept
  /// in sync with [_pageNumber] when flipping, so toggling view mode is
  /// coherent.
  int _surahNumber = 1;
  static const int _lastSurah = 114;

  /// Ordered ayahs displayed on the page.
  List<AyahRef> _pageAyahs = const <AyahRef>[];

  /// Uthmani text per ayah, keyed `"sura:ayah"`.
  final Map<String, String> _textByKey = <String, String>{};

  /// Per-ayah scroll anchors for auto-follow.
  final Map<String, GlobalKey> _ayahKeys = <String, GlobalKey>{};

  /// The marked (selected) ayah — start point for recitation.
  int? _markedSura;
  int? _markedAyah;

  /// The ayah currently loaded in the reference-audio player, highlighted on
  /// the page while it plays.
  int? _playingSura;
  int? _playingAyah;

  String? _lastActiveKey;

  /// Credits time spent actively reciting to the daily stats/streak.
  final ActivitySessionTimer _activityTimer = ActivitySessionTimer();

  static String _k(int sura, int ayah) => '$sura:$ayah';

  @override
  void initState() {
    super.initState();
    _viewMode = widget.viewMode;
    _surahNumber = widget.surahNumber;
    _pageNumber = quran.getPageNumber(widget.surahNumber, widget.ayahNumber);
    _controller.onAyahFinished = _autoPressStop;
    _markedSura = widget.surahNumber;
    _markedAyah = widget.ayahNumber;
    _controller.addListener(_followActiveAyah);
    _controller.addListener(_trackActivity);
    SavedBookmarksStore.instance.ensureLoaded();
    _rebuildPage();
  }

  @override
  void dispose() {
    _controller.removeListener(_followActiveAyah);
    _controller.removeListener(_trackActivity);
    _activityTimer.stop();
    _audioService.stop();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- Page data -----------------------------------------------------------

  List<AyahRef> _buildPageAyahs() {
    if (_viewMode == MushafViewMode.surah) {
      final count = quran.getVerseCount(_surahNumber);
      return [
        for (var a = 1; a <= count; a++) (sura: _surahNumber, ayah: a),
      ];
    }
    final data = quran.getPageData(_pageNumber);
    final list = <AyahRef>[];
    for (final section in data) {
      final map = section as Map;
      final s = map['surah'] as int;
      final start = map['start'] as int;
      final end = map['end'] as int;
      for (var a = start; a <= end; a++) {
        list.add((sura: s, ayah: a));
      }
    }
    return list;
  }

  Future<void> _rebuildPage() async {
    final ayahs = _buildPageAyahs();
    _pageAyahs = ayahs;
    _ayahKeys
      ..clear()
      ..addEntries(ayahs.map((r) => MapEntry(_k(r.sura, r.ayah), GlobalKey())));
    // Keep the marked ayah only if still on the page.
    if (!ayahs.any((r) => r.sura == _markedSura && r.ayah == _markedAyah)) {
      _markedSura = ayahs.isNotEmpty ? ayahs.first.sura : null;
      _markedAyah = ayahs.isNotEmpty ? ayahs.first.ayah : null;
    }
    if (mounted) setState(() {});
    await _loadTexts(ayahs);
  }

  Future<void> _loadTexts(List<AyahRef> ayahs) async {
    await Future.wait(
      ayahs.map((r) async {
        final key = _k(r.sura, r.ayah);
        if (_textByKey.containsKey(key)) return;
        try {
          final t = await PhonetizerService.uthmaniTextAt(
            surah: r.sura,
            ayah: r.ayah,
          );
          _textByKey[key] = t;
        } catch (_) {
          _textByKey[key] = quran.getVerse(r.sura, r.ayah);
        }
      }),
    );
    if (mounted) setState(() {});
  }

  // ---- Recitation control --------------------------------------------------

  void _autoPressStop() {
    if (_controller.isListening) _controller.stop();
  }

  Future<void> _start(int sura, int ayah) async {
    await _audioService.stop();
    setState(() {
      _markedSura = sura;
      _markedAyah = ayah;
      _playingSura = null;
      _playingAyah = null;
    });
    RecitationProgressStore.instance.save(sura, ayah);
    await _controller.start(
      startSura: sura,
      startAyah: ayah,
      pageAyahs: _pageAyahs,
    );
  }

  void _followActiveAyah() {
    final active = _controller.activeAyah;
    if (active == null) return;
    final key = _k(active.sura, active.ayah);
    if (key == _lastActiveKey) return;
    _lastActiveKey = key;
    // Persist the auto-advanced ayah so Home resumes where recitation stopped.
    RecitationProgressStore.instance.save(active.sura, active.ayah);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToAyah(key));
  }

  void _trackActivity() {
    if (_controller.isListening) {
      _activityTimer.start();
    } else {
      _activityTimer.pause();
    }
  }

  void _scrollToAyah(String key) {
    final ctx = _ayahKeys[key]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
      alignment: 0.3,
    );
  }

  void _onViewModeChanged(MushafViewMode mode) {
    if (_controller.isListening || _controller.isBusy) return;
    if (mode == _viewMode) return;
    setState(() => _viewMode = mode);
    _rebuildPage();
  }

  /// Flips to an adjacent mushaf page (delta of -1 / +1) while idle, clamped to
  /// the mushaf bounds. The new page's first ayah becomes the marked start, and
  /// [_surahNumber] tracks the page's opening surah.
  Future<void> _goToPage(int delta) async {
    if (_controller.isListening || _controller.isBusy) return;
    final target = _pageNumber + delta;
    if (target < 1 || target > _lastMushafPage) return;
    await _audioService.stop();
    final firstSurah = (quran.getPageData(target).first as Map)['surah'] as int;
    setState(() {
      _pageNumber = target;
      _surahNumber = firstSurah;
      _playingSura = null;
      _playingAyah = null;
    });
    await _rebuildPage();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Flips to an adjacent surah (delta of -1 / +1) while idle, clamped to the
  /// 114-surah bounds. [_pageNumber] tracks the surah's opening page so the
  /// page view stays coherent after a toggle.
  Future<void> _goToSurah(int delta) async {
    if (_controller.isListening || _controller.isBusy) return;
    final target = _surahNumber + delta;
    if (target < 1 || target > _lastSurah) return;
    await _audioService.stop();
    setState(() {
      _surahNumber = target;
      _pageNumber = quran.getPageNumber(target, 1);
      _playingSura = null;
      _playingAyah = null;
    });
    await _rebuildPage();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Handles a horizontal fling over the page body: flips page or surah based
  /// on the active view mode. Right-to-left (negative velocity) advances and
  /// left-to-right rewinds, matching the mushaf's RTL reading direction. Small
  /// flings are ignored so vertical reading scrolls aren't hijacked.
  void _onHorizontalSwipe(double? velocity) {
    if (velocity == null || velocity.abs() < 250) return;
    final delta = velocity < 0 ? 1 : -1;
    if (_viewMode == MushafViewMode.page) {
      _goToPage(delta);
    } else {
      _goToSurah(delta);
    }
  }

  // ---- Word colouring (unchanged) -----------------------------------------

  Color _statusColor(WordStatus status) {
    switch (status) {
      case WordStatus.correct:
        return const Color(0xFF1A9A63);
      case WordStatus.errors:
        return const Color(0xFFE0A100);
      case WordStatus.locked:
        return Colors.red.shade700;
      case WordStatus.incomplete:
        return AppTheme.primary;
      case WordStatus.skipped:
        return Colors.grey.shade500;
    }
  }

  void _openWordDetails(WordResult word) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.18,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return _CorrectionDrawer(
              scrollController: scrollController,
              word: word,
            );
          },
        );
      },
    );
  }

  // ---- Long-press menu -----------------------------------------------------

  void _openAyahMenu(int sura, int ayah) {
    final canRecite = !_controller.isListening && !_controller.isBusy;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.secondaryBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: AppTheme.outline.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${surahName(sura)} • Ayah $ayah',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.mic_rounded,
                  color: AppTheme.secondary,
                ),
                title: const Text('Start reciting here'),
                enabled: canRecite,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _start(sura, ayah);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.volume_up_rounded,
                  color: AppTheme.primary,
                ),
                title: const Text('Hear this ayah'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openPlayer(sura, ayah);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.menu_book_rounded,
                  color: AppTheme.primary,
                ),
                title: const Text('Show meaning'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showMeaning(sura, ayah);
                },
              ),
              ListTile(
                leading: Icon(
                  SavedBookmarksStore.instance.isAyahSaved(sura, ayah)
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  color: AppTheme.primary,
                ),
                title: Text(
                  SavedBookmarksStore.instance.isAyahSaved(sura, ayah)
                      ? 'Remove bookmark'
                      : 'Bookmark ayah',
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final saved = await SavedBookmarksStore.instance
                      .toggleAyahBookmark(surahNumber: sura, ayahNumber: ayah);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(
                          saved ? 'Ayah $ayah bookmarked' : 'Bookmark removed',
                        ),
                      ),
                    );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.copy_rounded,
                  color: AppTheme.primary,
                ),
                title: const Text('Copy text'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _copyAyah(sura, ayah);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _openPlayer(int sura, int ayah) {
    final startIdx = _pageAyahs.indexWhere(
      (r) => r.sura == sura && r.ayah == ayah,
    );
    if (startIdx < 0) return;
    if (_controller.isListening) _controller.stop();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.secondaryBackground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return _AyahPlayerSheet(
          pageAyahs: _pageAyahs,
          initialIndex: startIdx,
          onAyahChanged: (ref) {
            setState(() {
              _playingSura = ref?.sura;
              _playingAyah = ref?.ayah;
            });
            if (ref != null) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _scrollToAyah(_k(ref.sura, ref.ayah)),
              );
            }
          },
        );
      },
    ).whenComplete(() {
      _audioService.stop();
      if (mounted) {
        setState(() {
          _playingSura = null;
          _playingAyah = null;
        });
      }
    });
  }

  void _showMeaning(int sura, int ayah) {
    final translation = quran.getVerseTranslation(
      sura,
      ayah,
      translation: quran.Translation.enSaheeh,
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.secondaryBackground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${surahName(sura)} • Ayah $ayah',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Meaning (Saheeh International)',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textPrimary.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  translation,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.6,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _copyAyah(int sura, int ayah) async {
    final text = quran.getVerse(sura, ayah, verseEndSymbol: true);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Ayah copied to clipboard')));
  }

  // ---- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final finished = _controller.phase == StreamingPhase.finished;
            return Column(
              children: [
                _header(),
                _viewToggle(),
                _navBar(),
                if (_controller.phase != StreamingPhase.idle &&
                    _controller.phase != StreamingPhase.finished)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: _statusBanner(),
                  ),
                Expanded(
                  child: GestureDetector(
                    // Horizontal flings flip page/surah; the ListView keeps
                    // vertical scrolling, so the two axes don't conflict.
                    onHorizontalDragEnd: (details) =>
                        _onHorizontalSwipe(details.primaryVelocity),
                    child: ListView(
                      controller: _scroll,
                      // Eager (non-recycling) so each per-ayah GlobalKey is
                      // attached exactly once — a recycling builder reuses rows
                      // and trips "Duplicate GlobalKey".
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                      children: [
                        if (finished) _resultsCard(),
                        for (final ref in _pageAyahs) _ayahBlock(ref),
                      ],
                    ),
                  ),
                ),
                _control(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    final surahNameEn = surahName(_surahNumber);
    final subtitle = _viewMode == MushafViewMode.page
        ? 'Page $_pageNumber'
        : surahNameEn;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Live Recitation',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: AppTheme.textPrimary.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          if (_controller.isListening)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.red.shade600,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Live',
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _viewToggle() {
    final locked = _controller.isListening || _controller.isBusy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: SegmentedButton<MushafViewMode>(
        segments: const [
          ButtonSegment(
            value: MushafViewMode.page,
            label: Text('Page'),
            icon: Icon(Icons.menu_book_rounded, size: 18),
          ),
          ButtonSegment(
            value: MushafViewMode.surah,
            label: Text('Surah'),
            icon: Icon(Icons.list_rounded, size: 18),
          ),
        ],
        selected: {_viewMode},
        onSelectionChanged: locked ? null : (s) => _onViewModeChanged(s.first),
      ),
    );
  }

  /// Prev/next flip bar. In page view it flips mushaf pages; in surah view it
  /// flips surahs. Disabled while a recitation is live/busy or at the first/last
  /// page or surah. Chevrons point inward to follow the mushaf's RTL direction
  /// (mirroring the swipe gestures).
  Widget _navBar() {
    final locked = _controller.isListening || _controller.isBusy;
    final isPage = _viewMode == MushafViewMode.page;
    final current = isPage ? _pageNumber : _surahNumber;
    final total = isPage ? _lastMushafPage : _lastSurah;
    final canPrev = !locked && current > 1;
    final canNext = !locked && current < total;
    final label = isPage
        ? 'Page $_pageNumber / $_lastMushafPage'
        : 'Surah $_surahNumber / $_lastSurah';
    void prev() => isPage ? _goToPage(-1) : _goToSurah(-1);
    void next() => isPage ? _goToPage(1) : _goToSurah(1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            onPressed: canPrev ? prev : null,
            icon: const Icon(Icons.chevron_left_rounded),
            label: const Text('Prev'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.primary,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textPrimary.withValues(alpha: 0.7),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          OutlinedButton.icon(
            onPressed: canNext ? next : null,
            icon: const Icon(Icons.chevron_right_rounded),
            label: const Text('Next'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBanner() {
    final phase = _controller.phase;
    String message;
    Color color = AppTheme.primary;
    switch (phase) {
      case StreamingPhase.idle:
      case StreamingPhase.finished:
        return const SizedBox.shrink();
      case StreamingPhase.loading:
        message = 'Preparing model…';
      case StreamingPhase.listening:
        message = _controller.isElongating
            ? 'Listening… (holding for madd)'
            : 'Listening… recite at your pace.';
        color = const Color(0xFF1A9A63);
      case StreamingPhase.finalizing:
        message = 'Finalizing…';
      case StreamingPhase.error:
        message = _controller.errorMessage ?? 'Something went wrong.';
        color = Colors.red.shade700;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          if (phase == StreamingPhase.loading ||
              phase == StreamingPhase.finalizing)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsCard() {
    final accuracy = _controller.pageAccuracy;
    final flagged = _controller.allWords.any(
      (w) => w.status == WordStatus.errors || w.status == WordStatus.locked,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          Center(child: _AccuracyMeter(accuracy: accuracy)),
          const SizedBox(height: 16),
          Text(
            _headline(accuracy),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            flagged
                ? 'Tap a highlighted word to see the correction.'
                : 'No tajweed issues detected — well done.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.68),
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 8),
          Divider(color: AppTheme.outline.withValues(alpha: 0.3)),
        ],
      ),
    );
  }

  String _headline(double accuracy) {
    if (accuracy >= 0.85) return 'Excellent recitation';
    if (accuracy >= 0.6) return 'Good — keep practicing';
    return 'Needs more practice';
  }

  Widget _ayahBlock(AyahRef ref) {
    final key = _k(ref.sura, ref.ayah);
    final text = _textByKey[key];
    final active = _controller.activeAyah;
    final isActive =
        active != null &&
        active.sura == ref.sura &&
        active.ayah == ref.ayah &&
        (_controller.isListening || _controller.isBusy);
    final isMarked = _markedSura == ref.sura && _markedAyah == ref.ayah;
    final isPlaying = _playingSura == ref.sura && _playingAyah == ref.ayah;

    Color bg = Colors.transparent;
    Border? border;
    if (isPlaying) {
      bg = AppTheme.primary.withValues(alpha: 0.10);
      border = Border.all(color: AppTheme.primary, width: 1.5);
    } else if (isActive) {
      bg = AppTheme.secondary.withValues(alpha: 0.08);
    } else if (isMarked) {
      bg = AppTheme.secondary.withValues(alpha: 0.06);
      border = Border.all(color: AppTheme.secondary.withValues(alpha: 0.6));
    }

    return Container(
      key: _ayahKeys[key],
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: (_controller.isListening || _controller.isBusy)
            ? null
            : () => setState(() {
                _markedSura = ref.sura;
                _markedAyah = ref.ayah;
              }),
        onLongPress: () => _openAyahMenu(ref.sura, ref.ayah),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            border: border,
          ),
          child: text == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : _ayahWords(ref, text),
        ),
      ),
    );
  }

  Widget _ayahWords(AyahRef ref, String text) {
    final verseWords = text.trim().split(RegExp(r'\s+'));
    final results = _controller.wordsForAyah(ref.sura, ref.ayah);
    final byIdx = {for (final w in results) w.wordIdx: w};
    final waitingIdx = _controller.waitingWordIdxFor(ref.sura, ref.ayah);

    return Stack(
      children: [
        Directionality(
          textDirection: TextDirection.rtl,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...verseWords.asMap().entries.map((e) {
                final idx = e.key;
                final word = e.value;
                final result = byIdx[idx];
                final color = result == null
                    ? Colors.grey.shade600
                    : _statusColor(result.status);
                final flagged =
                    result != null &&
                    (result.status == WordStatus.errors ||
                        result.status == WordStatus.locked);
                final isWaiting = waitingIdx >= 0 && idx == waitingIdx;

                final textWidget = Text(
                  word,
                  style: GoogleFonts.amiriQuran(
                    fontSize: 28,
                    color: color,
                    fontWeight: FontWeight.w700,
                    height: 1.5,
                  ),
                );

                // Cheap path: an un-scored, non-waiting word is just text — no
                // Material/InkWell/glow. Keeps large pages light to rebuild.
                if (result == null && !isWaiting) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: textWidget,
                  );
                }

                final chip = Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isWaiting
                        ? AppTheme.secondary.withValues(alpha: 0.14)
                        : color.withValues(alpha: flagged ? 0.16 : 0.0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: textWidget,
                );

                return _GlowingWord(
                  active: isWaiting,
                  color: AppTheme.secondary,
                  child: result != null
                      ? Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _openWordDetails(result),
                            borderRadius: BorderRadius.circular(12),
                            child: chip,
                          ),
                        )
                      : chip,
                );
              }),
              // Reserve space at the verse end so the corner medallion never
              // sits on top of the last word.
              const SizedBox(width: 42, height: 36),
            ],
          ),
        ),
        // Ornamental end-of-ayah medallion (Amiri Quran renders U+06DD as the
        // mushaf rosette enclosing the verse number), pinned to the block's
        // bottom-left corner.
        Positioned(left: 0, bottom: 0, child: _ayahMarker(ref.ayah)),
      ],
    );
  }

  Widget _ayahMarker(int ayah) {
    return Text(
      quran.getVerseEndSymbol(ayah),
      textAlign: TextAlign.center,
      style: GoogleFonts.amiriQuran(
        fontSize: 34,
        height: 1.0,
        color: AppTheme.primary,
      ),
    );
  }

  Widget _control() {
    final phase = _controller.phase;
    final listening = phase == StreamingPhase.listening;
    final busy =
        phase == StreamingPhase.loading || phase == StreamingPhase.finalizing;

    final Widget button;
    if (listening) {
      button = ElevatedButton.icon(
        onPressed: _controller.stop,
        icon: const Icon(Icons.stop_rounded),
        label: const Text('Stop'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red.shade600,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(54),
        ),
      );
    } else if (busy) {
      button = ElevatedButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text(
          phase == StreamingPhase.loading ? 'Preparing…' : 'Finishing…',
        ),
        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(54)),
      );
    } else {
      final canStart = _markedSura != null && _markedAyah != null;
      final label = canStart
          ? 'Start Reciting (Ayah $_markedAyah)'
          : 'Tap an ayah to start';
      button = ElevatedButton.icon(
        onPressed: canStart ? () => _start(_markedSura!, _markedAyah!) : null,
        icon: const Icon(Icons.mic_rounded),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.secondary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(54),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: button,
    );
  }
}

/// Bottom sheet that plays the reference recitation for an ayah with Prev/Next
/// constrained to the displayed page. Reports the playing ayah back to the page
/// via [onAyahChanged] so the page can highlight + scroll to it.
class _AyahPlayerSheet extends StatefulWidget {
  const _AyahPlayerSheet({
    required this.pageAyahs,
    required this.initialIndex,
    required this.onAyahChanged,
  });

  final List<AyahRef> pageAyahs;
  final int initialIndex;
  final void Function(AyahRef?) onAyahChanged;

  @override
  State<_AyahPlayerSheet> createState() => _AyahPlayerSheetState();
}

class _AyahPlayerSheetState extends State<_AyahPlayerSheet> {
  late int _index = widget.initialIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onAyahChanged(widget.pageAyahs[_index]),
    );
  }

  void _move(int delta) {
    setState(() => _index = _index + delta);
    widget.onAyahChanged(widget.pageAyahs[_index]);
  }

  @override
  Widget build(BuildContext context) {
    final ref = widget.pageAyahs[_index];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 5,
              decoration: BoxDecoration(
                color: AppTheme.outline.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${surahName(ref.sura)} • Ayah ${ref.ayah}',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            ReferenceAudioPlayer(
              key: ValueKey('${ref.sura}:${ref.ayah}'),
              surah: ref.sura,
              ayah: ref.ayah,
              onPrev: _index > 0 ? () => _move(-1) : null,
              onNext: _index < widget.pageAyahs.length - 1
                  ? () => _move(1)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Wraps a verse word with a soft, pulsing glow when it's the word the
/// session is currently waiting for. The pulse is a gentle breathing halo in
/// [color]; when [active] is false the child is returned untouched (no
/// animation ticker runs), so only the single current word ever animates.
class _GlowingWord extends StatefulWidget {
  const _GlowingWord({
    required this.active,
    required this.color,
    required this.child,
  });

  final bool active;
  final Color color;
  final Widget child;

  @override
  State<_GlowingWord> createState() => _GlowingWordState();
}

class _GlowingWordState extends State<_GlowingWord>
    with SingleTickerProviderStateMixin {
  // Created only when the word actually glows. Most words never do, so we avoid
  // a ticker per word. It MUST stay nullable: a `late final` initializer would
  // be lazily created if touched in dispose(), and creating an
  // AnimationController during unmount looks up TickerMode on a deactivated
  // element — crashing the whole subtree.
  AnimationController? _pulse;

  AnimationController _ensurePulse() => _pulse ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _ensurePulse().repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _GlowingWord oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      final pulse = _ensurePulse();
      if (!pulse.isAnimating) pulse.repeat(reverse: true);
    } else if (_pulse != null && _pulse!.isAnimating) {
      _pulse!
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pulse = _pulse;
    if (!widget.active || pulse == null) return widget.child;
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(pulse.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.25 + 0.35 * t),
                blurRadius: 10 + 14 * t,
                spreadRadius: 1 + 2 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Circular accuracy meter mirroring the analysis-results screen, fed the
/// live ayah's `1 - overallPer`.
class _AccuracyMeter extends StatelessWidget {
  const _AccuracyMeter({required this.accuracy});

  final double accuracy;

  @override
  Widget build(BuildContext context) {
    final percent = (accuracy * 100).round();

    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 190,
          height: 190,
          child: CircularProgressIndicator(
            value: accuracy,
            strokeWidth: 18,
            backgroundColor: AppTheme.outline.withValues(alpha: 0.28),
            valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.secondary),
          ),
        ),
        Container(
          width: 176,
          height: 176,
          decoration: const BoxDecoration(
            color: AppTheme.secondaryBackground,
            shape: BoxShape.circle,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$percent%',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Accuracy',
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.58),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Gradient bottom sheet that mirrors the analysis-results correction drawer,
/// adapted to a live [WordResult]: it shows the word, the expected-vs-heard
/// phonemes, and any per-attribute tajweed (sifat) mismatch — all from the
/// streaming data, with no per-character indices available, so the word is
/// tinted by its [WordStatus] rather than per letter.
class _CorrectionDrawer extends StatelessWidget {
  const _CorrectionDrawer({required this.scrollController, required this.word});

  final ScrollController scrollController;
  final WordResult word;

  bool get _flagged =>
      word.status == WordStatus.errors || word.status == WordStatus.locked;

  /// On-gradient color for the headline word, by status.
  Color get _wordColor {
    switch (word.status) {
      case WordStatus.correct:
        return const Color(0xFF7DFFCC);
      case WordStatus.errors:
        return const Color(0xFFFFD24D);
      case WordStatus.locked:
        return const Color(0xFFFF6B6B);
      case WordStatus.incomplete:
        return Colors.white;
      case WordStatus.skipped:
        return Colors.white70;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Group the attribute-level diffs by their phoneme chunk so each card
    // lists all mismatched attributes for one phoneme group, matching the
    // analysis-results layout.
    final byChunk = <int, List<SifaDiff>>{};
    for (final d in word.sifatDiffs) {
      byChunk.putIfAbsent(d.chunkIdx, () => <SifaDiff>[]).add(d);
    }
    final sifatGroups = byChunk.entries.toList()..sort((a, b) => a.key - b.key);
    final per = (word.per.clamp(0.0, 1.0) * 100).round();

    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF007A76), Color(0xFF005250)],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                // Drag handle
                Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 20),

                // ---- Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        _flagged
                            ? Icons.spellcheck_rounded
                            : Icons.check_circle_outline_rounded,
                        color: AppTheme.secondary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _flagged ? 'Error Details' : 'Word Details',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _summaryLine,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 22),

                // ---- Word (whole-word tint — streaming has no per-char index)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 20,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Directionality(
                    textDirection: TextDirection.rtl,
                    child: Center(
                      child: Text(
                        word.uthmaniWord,
                        style: GoogleFonts.amiriQuran(
                          fontSize: 38,
                          color: _wordColor,
                          fontWeight: FontWeight.w700,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),

                // ---- Expected vs heard phonemes
                const SizedBox(height: 14),
                _ErrorCard(
                  icon: _flagged
                      ? Icons.mic_off_rounded
                      : Icons.graphic_eq_rounded,
                  iconColor: _flagged
                      ? const Color(0xFFFF6B6B)
                      : const Color(0xFF7DFFCC),
                  title:
                      'Phoneme error: $per%'
                      '${word.nRepetitions > 1 ? ' • ${word.nRepetitions} attempts' : ''}',
                  subtitle: 'Expected vs heard phonemes for this word.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PhonemeLine(label: 'Expected', value: word.refPhonemes),
                      const SizedBox(height: 8),
                      _PhonemeLine(label: 'Heard', value: word.hypPhonemes),
                    ],
                  ),
                ),

                // ---- Sifat error cards
                if (sifatGroups.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  ...sifatGroups.map((e) => _SifatDiffCard(diffs: e.value)),
                ],

                // ---- Clean fallback
                if (!_flagged && sifatGroups.isEmpty) ...[
                  const SizedBox(height: 14),
                  _ErrorCard(
                    icon: Icons.verified_rounded,
                    iconColor: const Color(0xFF7DFFCC),
                    title: 'Well recited',
                    subtitle:
                        'No pronunciation or tajweed issues detected for this word.',
                  ),
                ],

                const SizedBox(height: 22),

                // ---- Close button
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                      minimumSize: const Size.fromHeight(54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Close',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _summaryLine {
    final parts = <String>[];
    if (_flagged) parts.add('pronunciation');
    final n = word.sifatDiffs.length;
    if (n > 0) parts.add('$n tajweed attribute${n == 1 ? '' : 's'}');
    if (parts.isEmpty) return 'No issues detected';
    return '${parts.join(' & ')} '
        '${parts.length == 1 && !_flagged ? 'error' : 'errors'} found';
  }
}

/// A single "Expected"/"Heard" phoneme row inside a drawer card (on-gradient).
class _PhonemeLine extends StatelessWidget {
  const _PhonemeLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// A generic info card used inside the correction drawer; an optional [child]
/// hangs below the title/subtitle row (used here for the phoneme lines).
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.child,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (child != null) ...[const SizedBox(height: 12), child!],
        ],
      ),
    );
  }
}

/// A card listing every mismatched tajweed attribute for one phoneme chunk,
/// each as an expected-vs-said pair. Driven by the streaming [SifaDiff] shape.
class _SifatDiffCard extends StatelessWidget {
  const _SifatDiffCard({required this.diffs});

  final List<SifaDiff> diffs;

  @override
  Widget build(BuildContext context) {
    final phonemeGroup = diffs.isEmpty ? '' : diffs.first.phonemeGroup;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Phoneme badge row
            Row(
              children: [
                if (phonemeGroup.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.secondary.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      phonemeGroup,
                      style: GoogleFonts.amiriQuran(
                        fontSize: 18,
                        color: AppTheme.secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    'Tajweed Attribute${diffs.length > 1 ? 's' : ''}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Per-attribute said-vs-expected rows
            ...diffs.map((diff) {
              final expectedLabel = sifatClassLabel(diff.expected ?? '');
              final predictedLabel = sifatClassLabel(diff.predicted ?? '');
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sifatHeadLabel(diff.attribute),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: _ValueChip(
                            label: predictedLabel,
                            color: const Color(0xFFFF6B6B),
                            prefix: 'Said',
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                            color: Colors.white38,
                          ),
                        ),
                        Expanded(
                          child: _ValueChip(
                            label: expectedLabel,
                            color: const Color(0xFF7DFFCC),
                            prefix: 'Expected',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// A small chip showing "Said: X" or "Expected: Y" with a colored accent.
class _ValueChip extends StatelessWidget {
  const _ValueChip({
    required this.label,
    required this.color,
    required this.prefix,
  });

  final String label;
  final Color color;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$prefix: ',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          Flexible(
            child: Text(
              label,
              softWrap: true,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
