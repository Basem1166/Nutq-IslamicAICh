import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:quran/quran.dart' as quran;

import '../../../core/phonetizer_service.dart';
import '../../../core/phonetizer_settings_store.dart';
import '../../../core/quran/surah_names.dart';
import '../../activity/data/activity_store.dart';
import '../../../core/recitation/audio_recorder.dart';
import '../../../core/recitation/ctc_decoder.dart';
import '../../../core/recitation/recitation_engine.dart';
import '../../../core/recitation/recitation_progress_store.dart';
import '../../../core/recitation/recitation_scorer.dart';
import '../../../core/recitation/sifat_labels.dart';
import '../../../theme/app_theme.dart';

/// Records the user reciting [surahNumber]:[ayahNumber], runs the on-device
/// model, and shows the real accuracy + per-word tajweed highlighting (demo UI
/// design, driven by live model output).
class ErrorAnalysisPage extends StatefulWidget {
  const ErrorAnalysisPage({
    super.key,
    this.initialSurahNumber,
    this.initialAyahNumber,
    this.onSearchMeaning,
  });

  /// When both are null the screen resumes the last practiced ayah (or a
  /// default); pass them to start on a specific ayah (e.g. from the Quran tab).
  final int? initialSurahNumber;
  final int? initialAyahNumber;
  final ValueChanged<String>? onSearchMeaning;

  @override
  State<ErrorAnalysisPage> createState() => _ErrorAnalysisPageState();
}

enum _Stage { preparing, idle, recording, analyzing, done, error }

/// A/B scorer choice: the original two-alignment scorer, the same scorer with
/// the chunk-based sifat word-attribution fix, or the group-based scorer.
enum _ScorerKind { legacy, legacyFixed, grouped }

class _ErrorAnalysisPageState extends State<ErrorAnalysisPage> {
  final AudioRecorderService _recorder = AudioRecorderService();

  /// When the current recording started, used to log practice time on success.
  DateTime? _recordStart;

  int _surah = 1;
  int _ayah = 1;
  bool _positionReady = false;

  _Stage _stage = _Stage.preparing;
  String _statusMessage = 'Preparing model…';
  PhonetizerResult? _expected;

  double _accuracy = 0.0;
  Set<int> _wrongWordIndices = <int>{};
  Map<int, Set<int>> _wrongCharIndicesByWord = <int, Set<int>>{};
  Map<int, Set<int>> _sifatCharIndicesByWord = <int, Set<int>>{};
  SifatComparison? _sifat;

  /// Both scorings from the last analysis; null until a clip is analyzed.
  RecitationAnalysis? _analysis;

  /// A/B toggle across the three scorers. Flipping it re-renders from
  /// [_analysis] instantly — all three are precomputed per analysis.
  _ScorerKind _scorerKind = _ScorerKind.legacy;

  /// Which CTC decode feeds the scorer (default greedy). Flipping it re-renders
  /// from [_analysis] instantly — both flavors are precomputed per analysis.
  DecodeMode _decodeMode = DecodeMode.greedy;

  bool get _hasResult => _stage == _Stage.done;
  bool get _busy => _stage == _Stage.preparing || _stage == _Stage.analyzing;

  String _verseText = '';

  @override
  void initState() {
    super.initState();
    _initPosition();
  }

  /// Resolves the starting ayah: an explicit one if provided, else the saved
  /// last position (default 18:25 on first run).
  Future<void> _initPosition() async {
    int surah;
    int ayah;
    if (widget.initialSurahNumber != null && widget.initialAyahNumber != null) {
      surah = widget.initialSurahNumber!;
      ayah = widget.initialAyahNumber!;
    } else {
      final last = await RecitationProgressStore.instance.loadLast(
        defaultSurah: 18,
        defaultAyah: 25,
      );
      surah = last.surah;
      ayah = last.ayah;
    }
    if (!mounted) return;
    setState(() {
      _surah = surah;
      _ayah = ayah;
      _positionReady = true;
    });
    await RecitationProgressStore.instance.save(surah, ayah);
    await _prepare();
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() {
      _stage = _Stage.preparing;
      _statusMessage = 'Preparing model…';
      _accuracy = 0.0;
      _wrongWordIndices = <int>{};
      _wrongCharIndicesByWord = <int, Set<int>>{};
      _sifatCharIndicesByWord = <int, Set<int>>{};
      _sifat = null;
      _analysis = null;
    });
    try {
      // Warm the 35 MB model and phonetize the target verse in parallel.
      final results = await Future.wait<dynamic>([
        RecitationEngine.instance.ensureLoaded(),
        PhonetizerService.phonetizeByLocation(
          surah: _surah,
          ayah: _ayah,
          removeSpaces: false,
          moshafAttr: PhonetizerSettingsStore.instance.toMoshafAttr(),
        ),
        PhonetizerService.uthmaniTextAt(surah: _surah, ayah: _ayah),
      ]);
      _expected = results[1] as PhonetizerResult;
      _verseText = results[2] as String;
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _statusMessage = 'Ready to analyze';
      });
    } catch (e) {
      _fail('Could not prepare analysis: $e');
    }
  }

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        _fail('Microphone permission is required to analyze your recitation.');
        return;
      }
      await _recorder.start();
      _recordStart = DateTime.now();
      if (!mounted) return;
      setState(() {
        _stage = _Stage.recording;
        _statusMessage = 'Recording… recite, then tap stop';
      });
    } catch (e) {
      _fail('Could not start recording: $e');
    }
  }

  Future<void> _stopAndAnalyze() async {
    final expected = _expected;
    if (expected == null) {
      _fail('Expected recitation not ready.');
      return;
    }
    setState(() {
      _stage = _Stage.analyzing;
      _statusMessage = 'Analyzing your recitation…';
    });
    try {
      final path = await _recorder.stop();
      if (path == null) {
        _fail('No audio was captured. Please try again.');
        return;
      }
      final verseWords = _verseText.trim().split(RegExp(r'\s+'));
      final analysis = await RecitationEngine.instance.analyze(
        wavPath: path,
        expected: expected,
        verseWords: verseWords,
      );
      final start = _recordStart;
      if (start != null) {
        ActivityStore.instance.recordSession(DateTime.now().difference(start));
        _recordStart = null;
      }
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _stage = _Stage.done;
        _applyScore();
      });
    } catch (e) {
      _fail(e is RecitationException ? e.message : 'Analysis failed: $e');
    }
  }

  void _reset() {
    setState(() {
      _stage = _Stage.idle;
      _statusMessage = 'Ready to analyze';
      _accuracy = 0.0;
      _wrongWordIndices = <int>{};
      _wrongCharIndicesByWord = <int, Set<int>>{};
      _sifatCharIndicesByWord = <int, Set<int>>{};
      _sifat = null;
      _analysis = null;
    });
  }

  /// Copies the currently-selected scoring (legacy vs grouped) from [_analysis]
  /// into the display fields. Must be called inside a [setState].
  void _applyScore() {
    final analysis = _analysis;
    if (analysis == null) return;
    final pair = analysis.forMode(_decodeMode);
    final score = switch (_scorerKind) {
      _ScorerKind.legacy => pair.legacy,
      _ScorerKind.legacyFixed => pair.legacyFixed,
      _ScorerKind.grouped => pair.grouped,
    };
    _accuracy = score.accuracy;
    _wrongWordIndices = score.wrongWordIndices;
    _wrongCharIndicesByWord = score.wrongCharIndicesByWord;
    _sifatCharIndicesByWord = score.sifatCharIndicesByWord;
    _sifat = score.sifat;
  }

  // --- Per-character color coding --------------------------------------------
  //
  // Accuracy is measured on phonemes only, so a high score can still carry many
  // noisy sifat mismatches. To keep the two readable apart, a letter is colored
  // by the WORST issue it has: a pronunciation (phoneme) error is red, a
  // tajweed-only (sifat) attribute mismatch on a correctly-said letter is amber,
  // and a clean letter is green.

  /// Correctly recited letter.
  static const Color _kRight = Color(0xFF1A9A63); // green
  /// Letter said correctly but with a tajweed (sifat) attribute off.
  static const Color _kSifat = Color(0xFFE0A100); // amber
  Color get _kWrong => Colors.red.shade700; // mispronounced letter

  // --- Ayah navigation -------------------------------------------------------

  bool get _canGoPrev => _surah > 1 || _ayah > 1;
  bool get _canGoNext =>
      _surah < quran.totalSurahCount || _ayah < quran.getVerseCount(_surah);

  Future<void> _goPrev() async {
    if (_ayah > 1) {
      await _goToAyah(_surah, _ayah - 1);
    } else if (_surah > 1) {
      final prevSurah = _surah - 1;
      await _goToAyah(prevSurah, quran.getVerseCount(prevSurah));
    }
  }

  Future<void> _goNext() async {
    if (_ayah < quran.getVerseCount(_surah)) {
      await _goToAyah(_surah, _ayah + 1);
    } else if (_surah < quran.totalSurahCount) {
      await _goToAyah(_surah + 1, 1);
    }
  }

  Future<void> _goToAyah(int surah, int ayah) async {
    // Drop any in-progress recording before switching verses.
    if (_stage == _Stage.recording) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    setState(() {
      _surah = surah;
      _ayah = ayah;
    });
    await RecitationProgressStore.instance.save(surah, ayah);
    await _prepare();
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.error;
      _statusMessage = message;
    });
  }

  void _openMeaningSearch() {
    final verse = _verseText;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    widget.onSearchMeaning?.call(verse);
  }

  /// Structured sifat diffs for a tapped word.
  List<SifatDiff> _sifatDiffsForWord(int wordIndex) {
    final s = _sifat;
    if (s == null) return const <SifatDiff>[];
    return s.diffs.where((d) => d.word == wordIndex).toList();
  }

  void _openCorrectionDrawer(BuildContext context, int wordIndex) {
    final verseWords = _verseText.trim().split(RegExp(r'\s+'));
    final word = wordIndex < verseWords.length ? verseWords[wordIndex] : '';
    final wrongChars = _wrongCharIndicesByWord[wordIndex] ?? <int>{};
    final sifatChars = _sifatCharIndicesByWord[wordIndex] ?? <int>{};
    final diffs = _sifatDiffsForWord(wordIndex);
    final hasPhonemeError = wrongChars.isNotEmpty;
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
              wrongCharIndices: wrongChars,
              sifatCharIndices: sifatChars,
              sifatDiffs: diffs,
              hasPhonemeError: hasPhonemeError,
            );
          },
        );
      },
    );
  }

  String get _headline {
    switch (_stage) {
      case _Stage.preparing:
        return 'Preparing…';
      case _Stage.idle:
        return 'Ready to analyze';
      case _Stage.recording:
        return 'Listening…';
      case _Stage.analyzing:
        return 'Analyzing…';
      case _Stage.error:
        return 'Something went wrong';
      case _Stage.done:
        if (_accuracy >= 0.85) return 'Excellent recitation';
        if (_accuracy >= 0.6) return 'Good — keep practicing';
        return 'Needs more practice';
    }
  }

  String get _subtitle {
    if (_stage == _Stage.done) {
      return _wrongWordIndices.isEmpty
          ? 'No tajweed issues detected — well done.'
          : 'Tap a highlighted word to hear the correction.';
    }
    return _statusMessage;
  }

  @override
  Widget build(BuildContext context) {
    if (!_positionReady) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final verse = _verseText;
    final verseWords = verse.trim().split(RegExp(r'\s+'));

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                ),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text(
                    'Analysis Results',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Live',
                    style: TextStyle(
                      color: AppTheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Center(child: _AccuracyMeter(accuracy: _accuracy)),
            if (_hasResult) ...[
              const SizedBox(height: 16),
              Center(
                child: SegmentedButton<_ScorerKind>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment<_ScorerKind>(
                        value: _ScorerKind.legacy, label: Text('Legacy')),
                    ButtonSegment<_ScorerKind>(
                        value: _ScorerKind.legacyFixed, label: Text('Legacy+')),
                    ButtonSegment<_ScorerKind>(
                        value: _ScorerKind.grouped, label: Text('Grouped')),
                  ],
                  selected: {_scorerKind},
                  onSelectionChanged: (sel) {
                    setState(() {
                      _scorerKind = sel.first;
                      _applyScore();
                    });
                  },
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: SegmentedButton<DecodeMode>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment<DecodeMode>(
                        value: DecodeMode.greedy, label: Text('Greedy')),
                    ButtonSegment<DecodeMode>(
                        value: DecodeMode.beam, label: Text('Beam')),
                    ButtonSegment<DecodeMode>(
                        value: DecodeMode.beamRescored, label: Text('Beam+Ref')),
                  ],
                  selected: {_decodeMode},
                  onSelectionChanged: (sel) {
                    setState(() {
                      _decodeMode = sel.first;
                      _applyScore();
                    });
                  },
                ),
              ),
            ],
            const SizedBox(height: 18),
            Text(
              _headline,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _stage == _Stage.error
                    ? Colors.red.shade700
                    : Colors.black.withValues(alpha: 0.68),
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            Builder(
              builder: (ctx) {
                final surahNameEn = surahName(_surah);
                final surahNameAr = quran.getSurahNameArabic(_surah);

                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  surahNameEn,
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  surahNameAr,
                                  style: TextStyle(
                                    color: AppTheme.textPrimary.withValues(
                                      alpha: 0.72,
                                    ),
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'Ayah $_ayah',
                              style: const TextStyle(
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Directionality(
                        textDirection: TextDirection.rtl,
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          alignment: WrapAlignment.end,
                          children: verseWords.asMap().entries.map((e) {
                            final idx = e.key;
                            final word = e.value;
                            final isWrong = _wrongWordIndices.contains(idx);
                            final phonemeChars = _wrongCharIndicesByWord[idx];
                            final sifatChars = _sifatCharIndicesByWord[idx];
                            final clusters = graphemeClusters(word);

                            // Per-letter color: red if mispronounced, else amber
                            // if a tajweed attribute is off, else green.
                            Color charColor(int c) {
                              if (phonemeChars?.contains(c) ?? false) {
                                return _kWrong;
                              }
                              if (sifatChars?.contains(c) ?? false) {
                                return _kSifat;
                              }
                              return _kRight;
                            }

                            final hasCharDetail = _hasResult &&
                                isWrong &&
                                ((phonemeChars?.isNotEmpty ?? false) ||
                                    (sifatChars?.isNotEmpty ?? false));

                            // Word-level color = worst issue present, used for
                            // the whole-word fallback and the border tint.
                            final Color severity;
                            if (!_hasResult) {
                              severity = Colors.grey.shade400;
                            } else if (phonemeChars?.isNotEmpty ?? false) {
                              severity = _kWrong;
                            } else if (isWrong &&
                                (phonemeChars == null || phonemeChars.isEmpty) &&
                                (sifatChars == null || sifatChars.isEmpty)) {
                              // Flagged with no per-char detail (rare fallback).
                              severity = _kWrong;
                            } else if (sifatChars?.isNotEmpty ?? false) {
                              severity = _kSifat;
                            } else {
                              severity = _kRight;
                            }

                            Widget wordWidget;
                            if (hasCharDetail) {
                              final spans = <TextSpan>[];
                              for (var c = 0; c < clusters.length; c++) {
                                spans.add(
                                  TextSpan(
                                    text: clusters[c],
                                    style: GoogleFonts.amiriQuran(
                                      fontSize: 28,
                                      color: charColor(c),
                                      fontWeight: FontWeight.w700,
                                      height: 1.4,
                                    ),
                                  ),
                                );
                              }
                              wordWidget = RichText(
                                text: TextSpan(children: spans),
                              );
                            } else {
                              // Grey until we have a result, then the word's
                              // worst-issue color for the whole word.
                              wordWidget = Text(
                                word,
                                style: GoogleFonts.amiriQuran(
                                  fontSize: 28,
                                  color: severity,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                ),
                              );
                            }

                            // Border/background tint follows the word's worst
                            // issue (red > amber > green).
                            final bgTint = severity;

                            return Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _hasResult && isWrong
                                    ? () => _openCorrectionDrawer(ctx, idx)
                                    : null,
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: bgTint.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: wordWidget,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
            _buildAyahNav(),
            const SizedBox(height: 14),
            _buildControls(),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildAyahNav() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TextButton.icon(
          onPressed: (_canGoPrev && !_busy) ? _goPrev : null,
          icon: const Icon(Icons.chevron_left_rounded),
          label: const Text('Previous'),
          style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
        ),
        TextButton(
          onPressed: (_canGoNext && !_busy) ? _goNext : null,
          style: TextButton.styleFrom(foregroundColor: AppTheme.primary),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [Text('Next'), Icon(Icons.chevron_right_rounded)],
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    switch (_stage) {
      case _Stage.preparing:
      case _Stage.analyzing:
        return const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: CircularProgressIndicator(),
          ),
        );
      case _Stage.error:
        return Center(
          child: ElevatedButton.icon(
            onPressed: _prepare,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              minimumSize: const Size(200, 52),
            ),
          ),
        );
      case _Stage.idle:
        return Center(
          child: ElevatedButton.icon(
            onPressed: _startRecording,
            icon: const Icon(Icons.mic_rounded),
            label: const Text('Record & Analyze'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.secondary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              minimumSize: const Size(200, 52),
            ),
          ),
        );
      case _Stage.recording:
        return Center(
          child: ElevatedButton.icon(
            onPressed: _stopAndAnalyze,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('Stop & Analyze'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              minimumSize: const Size(200, 52),
            ),
          ),
        );
      case _Stage.done:
        return Column(
          children: [
            if (widget.onSearchMeaning != null)
              ElevatedButton.icon(
                onPressed: _openMeaningSearch,
                icon: const Icon(Icons.search_rounded),
                label: const Text('Search Meaning'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _reset,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: const BorderSide(color: AppTheme.primary),
                minimumSize: const Size.fromHeight(50),
              ),
              child: const Text('Try Again'),
            ),
          ],
        );
    }
  }
}

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

class _CorrectionDrawer extends StatelessWidget {
  const _CorrectionDrawer({
    required this.scrollController,
    required this.word,
    required this.wrongCharIndices,
    required this.sifatCharIndices,
    required this.sifatDiffs,
    required this.hasPhonemeError,
  });

  final ScrollController scrollController;
  final String word;
  final Set<int> wrongCharIndices;
  final Set<int> sifatCharIndices;
  final List<SifatDiff> sifatDiffs;
  final bool hasPhonemeError;

  @override
  Widget build(BuildContext context) {
    final clusters = graphemeClusters(word);

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
                      child: const Icon(
                        Icons.spellcheck_rounded,
                        color: AppTheme.secondary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Error Details',
                            style: TextStyle(
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

                // ---- Word with per-character highlighting
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
                      child: RichText(
                        textDirection: TextDirection.rtl,
                        text: TextSpan(
                          children: clusters.asMap().entries.map((e) {
                            final Color color;
                            if (wrongCharIndices.contains(e.key)) {
                              color = const Color(0xFFFF6B6B); // red: phoneme
                            } else if (sifatCharIndices.contains(e.key)) {
                              color = const Color(0xFFFFD24D); // amber: tajweed
                            } else {
                              color = const Color(0xFF7DFFCC); // green: correct
                            }
                            return TextSpan(
                              text: e.value,
                              style: GoogleFonts.amiriQuran(
                                fontSize: 38,
                                color: color,
                                fontWeight: FontWeight.w700,
                                height: 1.5,
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                ),

                // ---- Phoneme mismatch indicator
                if (hasPhonemeError) ...[
                  const SizedBox(height: 14),
                  _ErrorCard(
                    icon: Icons.mic_off_rounded,
                    iconColor: const Color(0xFFFF6B6B),
                    title: 'Pronunciation Mismatch',
                    subtitle:
                        'The highlighted characters differ from the expected pronunciation.',
                  ),
                ],

                // ---- Sifat error cards
                if (sifatDiffs.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  ...sifatDiffs.map((diff) => _SifatDiffCard(diff: diff)),
                ],

                // ---- No details fallback
                if (!hasPhonemeError && sifatDiffs.isEmpty) ...[
                  const SizedBox(height: 14),
                  _ErrorCard(
                    icon: Icons.info_outline_rounded,
                    iconColor: AppTheme.secondary,
                    title: 'Word Flagged',
                    subtitle:
                        'This word was detected as incorrect but specific error details are unavailable.',
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
    if (hasPhonemeError) parts.add('pronunciation');
    if (sifatDiffs.isNotEmpty) {
      final n = sifatDiffs.fold<int>(
        0,
        (sum, d) => sum + d.mismatchedHeads.length,
      );
      parts.add('$n tajweed attribute${n == 1 ? '' : 's'}');
    }
    if (parts.isEmpty) return 'Error detected';
    return '${parts.join(' & ')} ${parts.length == 1 && !hasPhonemeError ? 'error' : 'errors'} found';
  }
}

/// A generic error information card used inside the correction drawer.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;

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
      child: Row(
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
    );
  }
}

/// A card that displays one sifat diff for a specific phoneme, showing
/// each mismatched tajweed attribute with expected vs predicted values.
class _SifatDiffCard extends StatelessWidget {
  const _SifatDiffCard({required this.diff});

  final SifatDiff diff;

  @override
  Widget build(BuildContext context) {
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
                    diff.phoneme,
                    style: GoogleFonts.amiriQuran(
                      fontSize: 18,
                      color: AppTheme.secondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Tajweed Attribute${diff.mismatchedHeads.length > 1 ? 's' : ''}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Per-head expected vs predicted rows
            ...diff.mismatchedHeads.map((head) {
              final expectedLabel = sifatClassLabel(diff.expected[head] ?? '');
              final predictedLabel = sifatClassLabel(
                diff.predicted[head] ?? '',
              );
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sifatHeadLabel(head),
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
