/// Decision logic for what the user just recited.
///
/// At each phrase boundary, [classifyPhrase] scores the new phrase
/// against three reference positions:
///
///   - **H1 — continuation:** the phrase continues forward from
///     `currentWordIdx`. Default expectation.
///   - **H2 — repetition:** the phrase re-recites earlier word(s) in
///     the same ayah (user noticed a mistake and is correcting). The
///     best starting position in `[0, currentWordIdx)` is found by
///     trying each.
///   - **H3 — next ayah:** the phrase is the start of the next ayah.
///     Only allowed when the current ayah's last word has been visited
///     AND H3 scores meaningfully better than H1.
///
/// If none score well enough, the result is `noise` and the caller
/// should hold state.
library;

import 'package:meta/meta.dart';

import 'phrase_alignment.dart';
import 'word_aligner.dart';

/// Tunable thresholds controlling the 3-hypothesis decision.
@immutable
class PhraseClassifierConfig {
  /// Builds a config. All fields have sensible defaults.
  const PhraseClassifierConfig({
    this.goodPerThreshold = 0.30,
    this.noisePerThreshold = 0.75,
    this.nextAyahMargin = 0.20,
    this.repetitionMargin = 0.15,
    this.continuationWindow = 0,
    this.repetitionWindow = 0,
    this.wordZeroLockPer = 0.75,
  });

  /// A match is "good" if PER is at or below this.
  final double goodPerThreshold;

  /// If all hypotheses have PER worse than this, the phrase is `noise`.
  final double noisePerThreshold;

  /// H3 (next-ayah) must beat H1 (continuation) by at least this margin
  /// in PER. Without this, normal recitation noise would frequently
  /// trigger a false advance.
  final double nextAyahMargin;

  /// H2 (repetition) must beat H1 (continuation) by at least this margin.
  final double repetitionMargin;

  /// When evaluating continuation, look ahead at most this many words.
  /// `0` means "evaluate to end of ayah" — recommended for long phrases.
  final int continuationWindow;

  /// When evaluating repetition, look back at most this many words from
  /// `currentWordIdx`. `0` means "search from start of ayah" —
  /// recommended for Quran where users commonly go back many words
  /// after a breath.
  final int repetitionWindow;

  /// Severe-error threshold: a word whose PER is at or above this is
  /// marked as a severe error (red in the UI). No longer blocks — the
  /// session always advances. Used by the session, not by [classifyPhrase].
  final double wordZeroLockPer;
}

/// Decides what the just-spoken phrase represents.
///
/// Parameters
/// ──────────
///   - [phraseHyp]: phonemes the streamer has decoded since the last
///     phrase boundary.
///   - [wordSpans]: per-word reference spans for the current ayah.
///   - [currentWordIdx]: index of the next word we expect.
///   - [nextAyahFirstWord]: the [WordSpan] of the next ayah's first
///     word, if preloaded. `null` if at the end of the corpus or not
///     yet fetched.
///   - [config]: thresholds; defaults to `const PhraseClassifierConfig()`.
PhraseAlignment classifyPhrase({
  required String phraseHyp,
  required List<WordSpan> wordSpans,
  required int currentWordIdx,
  WordSpan? nextAyahFirstWord,
  PhraseClassifierConfig config = const PhraseClassifierConfig(),
}) {
  final nWords = wordSpans.length;

  // Degenerate input.
  if (phraseHyp.trim().isEmpty || nWords == 0) {
    return PhraseAlignment(
      decision: PhraseDecision.noise,
      startWordIdx: currentWordIdx,
      endWordIdx: currentWordIdx,
      perPerWord: const <double>[],
      overallPer: 1.0,
      confidence: 0.0,
    );
  }

  // ─── Score H1, H2, H3 ─────────────────────────────────────────────────
  final h1 = alignPhraseToWords(
    phraseHyp: phraseHyp,
    wordSpans: wordSpans,
    startIdx: currentWordIdx,
    maxWords: config.continuationWindow,
  );

  final (h2, h2Start) = _scoreRepetition(
    phraseHyp: phraseHyp,
    wordSpans: wordSpans,
    currentWordIdx: currentWordIdx,
    window: config.repetitionWindow,
  );

  final h3 = nextAyahFirstWord == null
      ? null
      : alignPhraseToWords(
          phraseHyp: phraseHyp,
          wordSpans: <WordSpan>[nextAyahFirstWord],
          startIdx: 0,
          maxWords: 1,
        );

  final h1Per = h1.overallPer;
  final h2Per = h2?.overallPer ?? double.infinity;
  final h3Per = h3?.overallPer ?? double.infinity;
  final minPer = <double>[h1Per, h2Per, h3Per].reduce((a, b) => a < b ? a : b);

  // Rule 1: noise.
  if (minPer > config.noisePerThreshold) {
    return PhraseAlignment(
      decision: PhraseDecision.noise,
      startWordIdx: currentWordIdx,
      endWordIdx: currentWordIdx,
      perPerWord: const <double>[],
      overallPer: h1Per,
      confidence: 1.0 - h1Per,
      nextAyahFirstWordPer: h3 == null ? null : h3Per,
    );
  }

  // Rule 2: next_ayah.
  final atOrPastEnd = currentWordIdx >= nWords - 1;
  if (h3 != null &&
      atOrPastEnd &&
      (h1Per - h3Per) >= config.nextAyahMargin &&
      h3Per <= config.goodPerThreshold) {
    return PhraseAlignment(
      decision: PhraseDecision.nextAyah,
      startWordIdx: 0,
      endWordIdx: h3.wordMatches.length,
      perPerWord: h3.wordMatches.map((m) => m.per).toList(growable: false),
      overallPer: h3Per,
      confidence: h3.confidence,
      nextAyahFirstWordPer: h3Per,
    );
  }

  // Rule 3: repetition. Two independent ways to qualify:
  //   (a) margin rule — H2 beats forward continuation by ≥ repetitionMargin.
  //   (b) clean-go-back rule — H2 is a *clean* match to an earlier word
  //       (PER ≤ goodPerThreshold) and is *strictly* better than H1. A clean
  //       alignment to a word the reciter already passed is strong evidence of
  //       a deliberate go-back (e.g. after a breath), even when an imperfect
  //       re-recitation doesn't clear the full margin and H1 also reads
  //       moderate. The strict `< h1Per` guard keeps a genuinely clean *forward*
  //       continuation (where H1 ≤ H2) from being mis-stolen as a repetition.
  final repByMargin = (h1Per - h2Per) >= config.repetitionMargin;
  final repByCleanGoBack =
      h2Per <= config.goodPerThreshold && h2Per < h1Per;
  if (h2 != null &&
      (repByMargin || repByCleanGoBack) &&
      h2Per <= config.noisePerThreshold) {
    return PhraseAlignment(
      decision: PhraseDecision.repetition,
      startWordIdx: h2Start,
      endWordIdx: h2Start + h2.wordMatches.length,
      perPerWord: h2.wordMatches.map((m) => m.per).toList(growable: false),
      overallPer: h2Per,
      confidence: h2.confidence,
      nextAyahFirstWordPer: h3 == null ? null : h3Per,
    );
  }

  // Rule 4: default → continuation.
  return PhraseAlignment(
    decision: PhraseDecision.continuation,
    startWordIdx: currentWordIdx,
    endWordIdx: currentWordIdx + h1.wordMatches.length,
    perPerWord: h1.wordMatches.map((m) => m.per).toList(growable: false),
    overallPer: h1Per,
    confidence: h1.confidence,
    nextAyahFirstWordPer: h3 == null ? null : h3Per,
  );
}

/// Public wrapper over the repetition (H2) back-scan that [classifyPhrase]
/// uses internally, exposed so other callers — notably the session's eager
/// (pre-boundary) path — can detect a repetition-in-progress with the *same*
/// scoring the boundary classifier uses.
///
/// Returns the best go-back alignment and the word index it starts at, or
/// `null` when there's no earlier word to return to (`currentWordIdx == 0`),
/// the phrase is empty, or no candidate aligned.
///
///   - [phraseHyp]: phonemes decoded since the last boundary.
///   - [wordSpans]: per-word reference spans for the current ayah.
///   - [currentWordIdx]: the word the session currently expects; the scan
///     searches strictly earlier positions `[lo, currentWordIdx)`.
///   - [window]: how many words to look back (`0` = to start of ayah), matching
///     [PhraseClassifierConfig.repetitionWindow].
({PhraseToWordsAlignment alignment, int startIdx})? scoreRepetition({
  required String phraseHyp,
  required List<WordSpan> wordSpans,
  required int currentWordIdx,
  int window = 0,
}) {
  if (phraseHyp.trim().isEmpty || wordSpans.isEmpty) return null;
  final (best, start) = _scoreRepetition(
    phraseHyp: phraseHyp,
    wordSpans: wordSpans,
    currentWordIdx: currentWordIdx,
    window: window,
  );
  if (best == null) return null;
  return (alignment: best, startIdx: start);
}

/// Tries each starting position in `[max(0, currentWordIdx - window),
/// currentWordIdx)`, returns the best alignment and its start.
(PhraseToWordsAlignment?, int) _scoreRepetition({
  required String phraseHyp,
  required List<WordSpan> wordSpans,
  required int currentWordIdx,
  required int window,
}) {
  if (currentWordIdx == 0) return (null, 0);
  PhraseToWordsAlignment? best;
  var bestStart = currentWordIdx;
  final lo = window > 0
      ? (currentWordIdx - window).clamp(0, currentWordIdx)
      : 0;
  for (var k = lo; k < currentWordIdx; k++) {
    final maxWords = currentWordIdx - k + 1;
    final align = alignPhraseToWords(
      phraseHyp: phraseHyp,
      wordSpans: wordSpans,
      startIdx: k,
      maxWords: maxWords,
    );
    if (best == null || align.overallPer < best.overallPer) {
      best = align;
      bestStart = k;
    }
  }
  return (best, bestStart);
}
