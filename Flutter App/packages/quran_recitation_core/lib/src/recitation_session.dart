/// Stateful orchestrator that drives a live recitation session.
///
/// Responsibilities
/// ────────────────
///   1. **Reference preparation.** Calls the phonetizer for the active
///      ayah (and pre-loads the next ayah for H3 / auto-advance).
///   2. **Audio routing.** Incoming audio is gated by the VAD before
///      reaching the streamer. Speech goes through; silence is dropped.
///      On `speechStart` the streamer is pre-padded so we don't clip
///      the first phoneme.
///   3. **Two emission paths:**
///      - [_checkTentativeEmission] / [_checkEagerEmission] after every
///        streamer commit. If the accumulated phrase clearly contains a
///        full word's worth of correctly aligned phonemes AND has run
///        past it, we emit a [WordResult] immediately. Snappy feedback.
///      - [_classifyPhraseBoundary] on VAD `phraseBoundary`. The
///        three-hypothesis classifier picks among
///        continuation / repetition / nextAyah / noise and updates
///        state. More deliberate decision point.
///   4. **Always advance.** Each word is scored on its first pass and
///      committed with a pure PER-based status; the session never blocks
///      on a mis-recited word. A later re-recitation can still replace a
///      word's result in place (repetition), improving its score.
///   5. **Auto-advance.** When the classifier returns `nextAyah`, the
///      session finalizes the current ayah and re-seeds state with the
///      next ayah's pre-loaded reference.
///
/// What's NOT in here
/// ──────────────────
///   - Microphone capture. `feedAudio` takes a `Float32List`; the
///     caller manages mic capture.
///   - Model loading. The caller passes in an already-constructed
///     [AdaptiveStreamingMuaalem].
///   - Phonetizer implementation. The caller passes in an abstract
///     [AyahReferenceLoader] (a Flutter adapter wraps the real
///     `PhonetizerService`).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'ayah_result.dart';
import 'phoneme_chunking.dart';
import 'phrase_alignment.dart';
import 'phrase_classifier.dart';
import 'sifat.dart';
import 'streaming_inference.dart';
import 'vad_gate.dart';
import 'word_aligner.dart';
import 'word_result.dart';

// ─────────────────────────────────────────────────────────────────────────
//  AyahReference + loader interface
// ─────────────────────────────────────────────────────────────────────────

/// Per-ayah reference produced by [AyahReferenceLoader] and consumed by
/// [RecitationSession].
@immutable
class AyahReference {
  /// Builds an ayah reference.
  const AyahReference({
    required this.sura,
    required this.ayah,
    required this.uthmaniText,
    required this.refPhonemes,
    required this.spans,
  });

  /// Sura number (1–114).
  final int sura;

  /// Ayah number within the sura (1-based).
  final int ayah;

  /// Full Uthmani text of the ayah.
  final String uthmaniText;

  /// Full reference phoneme string.
  final String refPhonemes;

  /// Per-word reference spans (output of `buildWordSpans`).
  final List<WordSpan> spans;
}

/// Loads phonetizer-derived references for ayat. The Flutter app's
/// adapter wraps the real `PhonetizerService` here.
abstract class AyahReferenceLoader {
  /// Returns the reference for `(sura, ayah)`. Throws if the ayah
  /// doesn't exist or the phonetizer fails — the session catches and
  /// treats the failure as "no next ayah" for pre-load purposes.
  Future<AyahReference> load({required int sura, required int ayah});
}

// ─────────────────────────────────────────────────────────────────────────
//  Session configuration
// ─────────────────────────────────────────────────────────────────────────

/// Knobs for the orchestrator (separate from the streamer's
/// [AdaptiveConfig] and the classifier's [PhraseClassifierConfig], both
/// injected).
@immutable
class SessionConfig {
  /// Builds a session config.
  const SessionConfig({
    this.eagerEmissionPer = 0.20,
    this.eagerEmissionLookaheadChunks = 1,
    this.speechStartPrepadMs = 300,
    this.sampleRate = 16000,
    this.vadEnabled = true,
    this.eagerEmissionPerTolerant = 0.60,
    this.silenceEmitTimeoutS = 1.0,
    this.ayahEndSilenceMs = 700,
  });

  /// First-word PER must be below this for eager emission. More
  /// conservative than the classifier's `goodPerThreshold` because
  /// mid-phrase decisions are riskier (we don't have the next word
  /// yet).
  final double eagerEmissionPer;

  /// Minimum extra chunks past the expected word's chunk count before
  /// we consider emitting eagerly. 1 chunk of lookahead is enough
  /// evidence the streamer has moved past the word.
  final int eagerEmissionLookaheadChunks;

  /// Pre-pad the streamer with this much recent audio on `speechStart`
  /// to capture the leading edge of the first phoneme.
  final int speechStartPrepadMs;

  /// Sample rate (must match streamer and VAD).
  final int sampleRate;

  /// When `false`, bypass VAD entirely — all audio goes to the streamer
  /// with relaxed emission thresholds.
  final bool vadEnabled;

  /// Tolerant PER for eager emission when VAD is disabled.
  final double eagerEmissionPerTolerant;

  /// When VAD is disabled, if no new tokens for this many seconds,
  /// auto-flush and classify. Replaces VAD's silence-detection role.
  final double silenceEmitTimeoutS;

  /// Silence window (ms) used once the reciter has fully said the ayah's
  /// *last* word (its alignment PER ≤ [eagerEmissionPer]). Caps the Madd
  /// anticipation stretch (2.0–2.5 s), which otherwise delays "ayah complete"
  /// at every waqf because ayah endings almost always carry a madd. Never
  /// raises the window above the current one. Mid-ayah words are unaffected.
  final int ayahEndSilenceMs;
}

// ─────────────────────────────────────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────────────────────────────────────

/// Maps a PER value to a coarse status label for the UI.
///
/// [severeThreshold] only affects coloring: at or above it a word renders red
/// ([WordStatus.locked]) instead of amber ([WordStatus.errors]). It no longer
/// blocks progress — the session always advances regardless of PER.
WordStatus _perToStatus(double per, double severeThreshold, int nChunks) {
  if (nChunks == 0) return WordStatus.skipped;
  if (per <= 0.05) return WordStatus.correct;
  if (per >= severeThreshold) return WordStatus.locked;
  return WordStatus.errors;
}

/// Run-length pattern used by the Madd-anticipation heuristic. Matches a
/// character repeated 4+ times in a row — corresponds to a long Madd
/// (Munfasil 4 harakat, Lazim 6 harakat, etc.).
final RegExp _maddRepeat = RegExp(r'(.)\1{3,}');

/// Minimum chunk count an eager phrase must reach before a clean backward match
/// is allowed to trigger an early go-back classification (see
/// `_maybeClassifyGoBack`). Keeps a transient partial-word prefix from firing a
/// spurious repetition before the reciter has clearly gone back.
const int _goBackMinPhraseChunks = 3;

/// Live incremental re-match window (see `_rematchActiveWindow`). Re-aligns the
/// last [_rematchWindowWords] words against the recent stream tail on each
/// commit to fix words a premature boundary split (e.g. أُنزِلَ's dropped hamza)
/// *during* recitation rather than only at finalize. Bounding the word window
/// keeps cost O(1) per commit regardless of ayah length.
const int _rematchWindowWords = 4;

/// A word is only corrected once the cursor is at least this many words past it
/// — its audio is then settled, so re-matching won't flicker a still-in-progress
/// word.
const int _rematchSettleMargin = 1;

/// Hard cap on the stream-tail length fed to the window re-align, so a drifting
/// offset estimate (repetition-inflated stream) can't make the tail — and thus
/// the cost — unbounded. ~ (window + margin) words of phonemes.
const int _rematchMaxTailChars = 160;

// ─────────────────────────────────────────────────────────────────────────
//  The orchestrator
// ─────────────────────────────────────────────────────────────────────────

/// Drives a live recitation session for one ayah at a time, with
/// auto-advance support.
///
/// Lifecycle
/// ─────────
/// ```dart
/// final session = RecitationSession(
///   streamer: streamer,
///   referenceLoader: loader,
///   vadGate: vadGate,
/// );
/// await session.startAyah(sura: 1, ayah: 1);
/// for (final chunk in micStream) {
///   final words = session.feedAudio(chunk);
///   for (final w in words) print(w.uthmaniWord);
///   // If feedAudio returned a `null`, the session is about to switch
///   // ayahs and needs an awaited preparation step — see autoAdvance.
/// }
/// final result = session.finalizeAyah();
/// ```
class RecitationSession {
  /// Builds the session. The streamer must already be reset before the
  /// first [startAyah] (the session calls reset for you).
  RecitationSession({
    required this.streamer,
    required this.referenceLoader,
    required VadGate? vadGate,
    PhraseClassifierConfig? classifierConfig,
    SessionConfig? sessionConfig,
    this.onWordComplete,
    this.onAyahComplete,
    this.onStreamUpdate,
    this.onPhraseClassified,
    this.onLiveWordFeedback,
  })  : _vad = (sessionConfig?.vadEnabled ?? true) ? vadGate : null,
        classifierConfig = classifierConfig ?? const PhraseClassifierConfig(),
        cfg = sessionConfig ?? const SessionConfig() {
    if (cfg.vadEnabled && _vad == null) {
      throw ArgumentError(
        'sessionConfig.vadEnabled = true but vadGate is null',
      );
    }
  }

  /// The streamer this session drives.
  final AdaptiveStreamingMuaalem streamer;

  /// Loads ayah references on demand.
  final AyahReferenceLoader referenceLoader;

  /// Tunables.
  final SessionConfig cfg;

  /// Phrase-classifier tunables.
  final PhraseClassifierConfig classifierConfig;

  /// Fired for each [WordResult] emitted (both eagerly and at phrase
  /// boundaries).
  void Function(WordResult)? onWordComplete;

  /// Fired when the active ayah transitions to a terminal status.
  void Function(AyahResult)? onAyahComplete;

  /// Fired whenever the streamer's `fullText` grows. The argument is
  /// the new full text.
  void Function(String)? onStreamUpdate;

  /// Fired after every phrase-boundary classification.
  void Function(PhraseAlignment, String phraseHyp)? onPhraseClassified;

  /// Fired with a *provisional* (non-committed) [WordResult] for the word the
  /// reciter is currently on, the moment there's enough evidence the word is
  /// being mis-recited but the eager path is still holding off on committing
  /// it (PER too high to accept, or the reciter has moved to a later word that
  /// can't yet be accepted). Lets the UI tint the in-progress word amber/red in
  /// real time instead of only at the next VAD phrase boundary — without which
  /// a wrong word stays grey for as long as the (Madd-stretched, up to ~2.5 s)
  /// silence window takes to fire.
  ///
  /// This NEVER advances [AyahResult.currentWordIdx], adds to the emitted set,
  /// or mutates any session state — it is a pure UI hint. The authoritative
  /// result for the word still arrives later via [onWordComplete]; consumers
  /// must treat the provisional result as superseded once that lands.
  void Function(WordResult provisional)? onLiveWordFeedback;

  final VadGate? _vad;

  /// Whether VAD is currently engaged. `false` when [SessionConfig.vadEnabled]
  /// is `false`.
  bool get vadEnabled => _vad != null;

  // Per-ayah state — populated by startAyah.
  AyahResult? _ayah;
  List<WordSpan> _wordSpans = const <WordSpan>[];
  WordSpan? _nextAyahFirstWord;
  AyahReference? _nextAyahPreloaded;
  int _phraseAnchorHypLen = 0;
  // Set by a mid-stream classify when it declines to commit a trailing partial
  // word: how many trailing phrase chars to PRESERVE (re-process next phrase)
  // instead of consuming, so the held word's full body lands on it — not the
  // next word. Read once by [_classifyPhraseBoundary] when resetting the anchor.
  int _heldTrailingHypLen = 0;
  final List<SifaSnapshot> _predictedSifaChunks = <SifaSnapshot>[];
  int _wordsAtPhraseStart = 0;
  final Set<int> _emittedWordIdxs = <int>{};
  int _curSura = 0;
  int _curAyah = 0;
  int _lastTokenCount = 0;
  DateTime _lastTokenTime = DateTime.now();
  double _refundedExpansions = 0.0;
  int _lastCommittedTextLen = 0;
  // Stream length at the last incremental window re-match, so the live re-match
  // runs at most once per stream growth (≈ per commit), not per audio feed.
  int _lastRematchStreamLen = 0;
  int _lastMaddAnchorIdx = -1;

  /// Whether [onAyahComplete] has already fired mid-stream for the active
  /// ayah. Guards against re-firing on every subsequent feed once the ayah is
  /// `complete`, while still letting *any* emission path (eager OR
  /// phrase-boundary) trigger the one mid-stream completion signal that the
  /// integrator uses to auto-stop. Reset per ayah in [_applyAyahReference].
  bool _ayahCompleteFired = false;

  /// Whether the VAD window is currently capped by [SessionConfig.ayahEndSilenceMs].
  bool _ayahEndCapped = false;

  // Stash of original streamer config values for Madd stretch restore.
  double? _origBaseChunkS;
  double? _origExpansionS;
  int? _origMaxExpansions;
  double? _origRightLookaheadS;
  int? _origEdgeFrames;
  int _origVadMinSilenceSamples = 0;

  /// Active ayah result. `null` before [startAyah] or after
  /// [finalizeAyah].
  AyahResult? get currentAyah => _ayah;

  /// Number of reference word-spans for the active ayah (diagnostic).
  int get wordSpanCount => _wordSpans.length;

  // ─── Reference setup ─────────────────────────────────────────────────

  /// Loads the reference for `(sura, ayah)`, resets all session state,
  /// and pre-loads the next ayah for H3 / auto-advance.
  Future<AyahResult> startAyah({required int sura, required int ayah}) async {
    final ref = await referenceLoader.load(sura: sura, ayah: ayah);

    AyahReference? nextRef;
    try {
      nextRef = await referenceLoader.load(sura: sura, ayah: ayah + 1);
    } catch (_) {
      // Last ayah of a sura, or no next ayah available — H3 will simply
      // be inactive. Auto-advance becomes a no-op.
      nextRef = null;
    }

    _applyAyahReference(ref, nextRef);
    return _ayah!;
  }

  /// Internal: swap in a freshly-loaded reference, resetting state.
  ///
  /// Used by both [startAyah] (loads the next ayah) and the auto-advance
  /// path (uses the pre-loaded next ayah, then triggers loading of the
  /// new "next next" ayah in the background).
  void _applyAyahReference(
    AyahReference ref,
    AyahReference? nextRef,
  ) {
    streamer.reset();
    _refundedExpansions = 0.0;
    _lastCommittedTextLen = 0;
    _vad?.reset();
    _wordSpans = ref.spans;
    _nextAyahFirstWord = nextRef?.spans.isNotEmpty ?? false
        ? nextRef!.spans.first
        : null;
    _nextAyahPreloaded = nextRef;
    _phraseAnchorHypLen = 0;
    _lastRematchStreamLen = 0;
    _predictedSifaChunks.clear();
    _wordsAtPhraseStart = 0;
    _emittedWordIdxs.clear();
    _curSura = ref.sura;
    _curAyah = ref.ayah;
    _lastTokenCount = 0;
    _lastTokenTime = DateTime.now();
    _lastMaddAnchorIdx = -1;
    _ayahCompleteFired = false;
    _ayahEndCapped = false;

    // Cache originals once for Madd stretch restore.
    _origBaseChunkS ??= streamer.cfg.baseChunkS;
    _origExpansionS ??= streamer.cfg.expansionS;
    _origMaxExpansions ??= streamer.cfg.maxExpansions;
    _origRightLookaheadS ??= streamer.cfg.rightLookaheadS;
    _origEdgeFrames ??= streamer.cfg.edgeFrames;
    if (_vad != null) {
      _origVadMinSilenceSamples = _vad.minSilenceSamples;
    }

    _ayah = AyahResult(
      sura: ref.sura,
      ayah: ref.ayah,
      uthmaniText: ref.uthmaniText,
      refPhonemes: ref.refPhonemes,
    );
  }

  // ─── Audio in, word events out ───────────────────────────────────────

  /// Pushes a chunk of float32 mono audio. Returns any [WordResult]
  /// events emitted during this call.
  ///
  /// If a `nextAyah` decision fires and the next ayah's reference
  /// hasn't pre-loaded yet, the session falls through to `noise`/hold
  /// for this phrase — the user's audio is still on the streamer's
  /// buffer for the next attempt.
  ///
  /// Synchronous: calls the model and classifier on the current thread.
  List<WordResult> feedAudio(Float32List audioChunk) {
    final ayah = _ayah;
    if (ayah == null) {
      throw StateError('Call startAyah() before feedAudio()');
    }
    if (ayah.status == AyahStatus.complete ||
        ayah.status == AyahStatus.abandoned) {
      return const <WordResult>[];
    }

    _updateVadThreshold();

    final emitted = _vad != null
        ? _feedAudioWithVad(audioChunk)
        : _feedAudioNoVad(audioChunk);

    _postFeedBookkeeping(emitted);
    return emitted;
  }

  /// Finalizes the active ayah. Flushes the streamer, classifies any
  /// residue, fills in missing-word entries, and returns the final
  /// [AyahResult].
  AyahResult finalizeAyah() {
    final ayah = _ayah;
    if (ayah == null) {
      throw StateError('No active ayah');
    }
    _absorbStreamerOutput(streamer.flush());
    // Surface the final flushed chunk: finalize bypasses the normal per-feed
    // bookkeeping, so without this the last committed phonemes never reach the
    // live "Heard" display nor the ayah's persisted hypothesis.
    _fireStreamUpdateIfGrown();
    ayah.hypPhonemes = streamer.fullText;
    final residue = _classifyPhraseBoundary();
    final cb = onWordComplete;
    if (cb != null) {
      for (final w in residue) {
        try {
          cb(w);
        } catch (_) {
          // swallow; matches Python's behaviour
        }
      }
    }

    // End-of-recitation correction pass: re-align the WHOLE heard stream
    // against the WHOLE ayah and adopt any strictly-better per-word match.
    _rematchFullStream();

    // Fill missing word entries
    for (final ws in _wordSpans) {
      if (_emittedWordIdxs.contains(ws.wordIdx)) continue;
      ayah.wordResults.add(_buildMissingWordResult(ws));
    }
    ayah.wordResults.sort((a, b) => a.wordIdx - b.wordIdx);
    _recomputeOverallPer();

    if (_emittedWordIdxs.isNotEmpty &&
        _emittedWordIdxs.length == _wordSpans.length) {
      ayah.status = AyahStatus.complete;
    } else {
      ayah.status = AyahStatus.abandoned;
    }

    final cb2 = onAyahComplete;
    if (cb2 != null) {
      try {
        cb2(ayah);
      } catch (_) {
        // swallow
      }
    }
    return ayah;
  }

  /// End-of-recitation correction pass.
  ///
  /// The streaming pipeline commits words against LOCAL, greedy boundaries, so
  /// a premature VAD cut or a long elongation can split a word mid-way — e.g.
  /// أُنزِلَ (`ءُںںںزِلَ`) committed as just its first phoneme "ءُ" at a false 500 ms
  /// silence, its body then orphaned onto the next phrase so the word's leading
  /// hamza is dropped from the match. Once the whole recitation is in hand,
  /// re-align it against the whole ayah in ONE pass — global context recovers
  /// the correct per-word boundaries — and adopt any per-word match that scores
  /// STRICTLY BETTER than the committed result.
  ///
  /// Strict improvement is the safety guarantee: PER is edit distance to the
  /// reference, so a lower PER is by definition closer to correct. A word can
  /// only improve or stay — never regress. A repetition/go-back inflates the
  /// stream with duplicated content that scores WORSE under a single global
  /// alignment, so those words are left to their (already best-per) streaming
  /// results. Only words that were actually committed are touched — re-match
  /// corrects mis-attribution, it does not invent results for un-recited words.
  void _rematchFullStream() {
    final ayah = _ayah;
    if (ayah == null) return;
    final whole = streamer.fullText;
    if (whole.trim().isEmpty) return;
    final global = alignPhraseToWords(
      phraseHyp: whole,
      wordSpans: _wordSpans,
      startIdx: 0,
    );
    for (final wm in global.wordMatches) {
      if (wm.hypPhonemes.trim().isEmpty) continue;
      if (!_emittedWordIdxs.contains(wm.wordIdx)) continue;
      final idx = ayah.wordResults.indexWhere((w) => w.wordIdx == wm.wordIdx);
      if (idx < 0) continue;
      final old = ayah.wordResults[idx];
      if (wm.per < old.per - 1e-9) {
        ayah.wordResults[idx] = _buildWordResult(
          _wordSpans[wm.wordIdx],
          wm.hypPhonemes,
          wm.per,
          nRepetitions: old.nRepetitions,
        );
      }
    }
  }

  /// Live (per-commit) version of [_rematchFullStream], bounded to a small
  /// window so the same boundary-split corrections (e.g. أُنزِلَ's orphaned
  /// hamza) surface DURING recitation instead of only at finalize — without the
  /// full-ayah re-align's quadratic cost.
  ///
  /// Runs at most once per stream growth. Re-aligns the last
  /// [_rematchWindowWords] words (plus a one-word context margin) against the
  /// recent stream tail, and adopts a strictly-better match only for words that
  /// have SETTLED — the cursor is ≥ [_rematchSettleMargin] words past them, so
  /// their audio is complete and the correction won't flicker. Bounding both the
  /// word window and the tail keeps this O(1) in time and memory per commit,
  /// independent of ayah length. Returns adopted corrections so the feed surfaces
  /// them to the UI like any other word result.
  List<WordResult> _maybeRematchActiveWindow() {
    final whole = streamer.fullText;
    if (whole.length <= _lastRematchStreamLen) return const <WordResult>[];
    _lastRematchStreamLen = whole.length;

    final ayah = _ayah;
    if (ayah == null) return const <WordResult>[];
    final cur = ayah.currentWordIdx;
    // Need at least one settled word behind the cursor to correct.
    if (cur - _rematchSettleMargin < 1) return const <WordResult>[];

    final lo = _maxInt(0, cur - _rematchWindowWords);
    // One-word context margin: start the alignment a word earlier so word `lo`
    // doesn't absorb leading offset drift. The margin word is not adopted.
    final loCtx = _maxInt(0, lo - 1);

    // Estimate the stream offset where loCtx begins (committed hyps are slices
    // of the stream), then hard-cap how far back the tail may start so a
    // drifting estimate can't unbound the cost.
    var est = 0;
    for (final w in ayah.wordResults) {
      if (w.wordIdx < loCtx) est += w.hypPhonemes.length;
    }
    final tailStart =
        _maxInt(est, whole.length - _rematchMaxTailChars).clamp(0, whole.length);
    if (tailStart >= whole.length) return const <WordResult>[];

    final win = alignPhraseToWords(
      phraseHyp: whole.substring(tailStart),
      wordSpans: _wordSpans,
      startIdx: loCtx,
      maxWords: cur - loCtx,
    );

    final corrections = <WordResult>[];
    for (final wm in win.wordMatches) {
      // Adopt only SETTLED words strictly inside the window — never the context
      // margin (< lo) and never the still-in-flux latest word (≥ cur - settle).
      if (wm.wordIdx < lo || wm.wordIdx >= cur - _rematchSettleMargin) continue;
      if (wm.hypPhonemes.trim().isEmpty) continue;
      if (!_emittedWordIdxs.contains(wm.wordIdx)) continue;
      final idx = ayah.wordResults.indexWhere((w) => w.wordIdx == wm.wordIdx);
      if (idx < 0) continue;
      final old = ayah.wordResults[idx];
      if (wm.per < old.per - 1e-9) {
        final wr = _buildWordResult(
          _wordSpans[wm.wordIdx],
          wm.hypPhonemes,
          wm.per,
          nRepetitions: old.nRepetitions,
        );
        ayah.wordResults[idx] = wr;
        corrections.add(wr);
      }
    }
    return corrections;
  }

  /// Words emitted during the in-progress phrase (since the last phrase
  /// boundary or `startAyah`).
  List<WordResult> wordsInCurrentPhrase() {
    final ayah = _ayah;
    if (ayah == null) return const <WordResult>[];
    return ayah.wordResults.sublist(_wordsAtPhraseStart);
  }

  // ─── Audio paths ─────────────────────────────────────────────────────

  List<WordResult> _feedAudioWithVad(Float32List audioChunk) {
    final emitted = <WordResult>[];
    final vad = _vad!;

    // 1) Gate by VAD
    final vadEvents = vad.process(audioChunk);

    // 2) Speech-start prepad
    final speechStarted =
        vadEvents.any((e) => e.type == VadEventType.speechStart);
    if (speechStarted && cfg.speechStartPrepadMs > 0) {
      final prepad = vad.recentAudio(cfg.speechStartPrepadMs);
      if (prepad.isNotEmpty) {
        _absorbStreamerOutput(streamer.process(prepad));
      }
    }

    // 3) Forward audio to streamer only when speech is active (or just
    // ended) — saves compute on long silences.
    final hasPhraseBoundary =
        vadEvents.any((e) => e.type == VadEventType.phraseBoundary);
    if (vad.isSpeech || hasPhraseBoundary) {
      final wasElongating = streamer.isElongating;
      _absorbStreamerOutput(streamer.process(audioChunk));
      final nowElongating = streamer.isElongating;

      // Falling edge: the streamer just committed an elongation chunk.
      // Do NOT hard-reset the VAD window to baseline here. Muqatta'at and
      // multi-madd words (e.g. ٱلٓمٓ = "alif-laaam-miiim", which has two
      // long madds back to back) commit several elongations within a single
      // word; snapping straight to the ~500ms baseline after the first one
      // lets VAD fire a phrase boundary mid-word and cut the reciter off
      // (the "2:1 gets cut" report). Instead recompute the stretch from the
      // current reference context: it stays stretched while we're still
      // anchored on a madd word and only relaxes once recitation has moved
      // on to non-madd words.
      if (wasElongating && !nowElongating) {
        _lastMaddAnchorIdx = -1;
        _updateVadThreshold();
      }

      _fireStreamUpdateIfGrown();
      emitted.addAll(_checkTentativeEmission());
      emitted.addAll(_checkEagerEmission());
      emitted.addAll(_maybeRematchActiveWindow());

      // Breath-then-go-back during CONTINUOUS recitation: if the forward-only
      // eager path made no progress because the reciter resumed a few words
      // earlier (re-reciting with no pause), there is no VAD silence to trigger
      // the repetition classifier — so the pointer would freeze on the expected
      // word until the reciter finally stops. Detect the clean backward match
      // and run the classifier NOW so the pointer follows the reciter.
      if (emitted.isEmpty) {
        emitted.addAll(_maybeClassifyGoBack());
      }
    }

    // 4) Phrase-boundary classification
    for (final e in vadEvents) {
      if (e.type == VadEventType.phraseBoundary) {
        // DIAGNOSTIC (Bug B): reveal whether the boundary fired at the
        // baseline silence window or a Madd-stretched one, and what hypothesis
        // the streamer had committed when it fired. A boundary at ~500 ms with
        // a still-growing hyp means the Madd stretch never engaged for this
        // (muqatta'at) word; a boundary at 2000–2500 ms means the reciter
        // genuinely paused past the stretched window. Remove once Bug B is
        // understood.
        final windowMs = vad.minSilenceSamples * 1000 ~/ vad.sampleRate;
        // ignore: avoid_print
        print('[session-vad] phraseBoundary window=${windowMs}ms '
            'lastProb=${vad.lastProb.toStringAsFixed(3)} '
            'hyp="${streamer.fullText}"');
        _absorbStreamerOutput(streamer.flush());
        emitted.addAll(_classifyPhraseBoundary());
      }
    }

    return emitted;
  }

  List<WordResult> _feedAudioNoVad(Float32List audioChunk) {
    final emitted = <WordResult>[];

    // 1) Always forward audio to streamer.
    _absorbStreamerOutput(streamer.process(audioChunk));
    final grew = _fireStreamUpdateIfGrown();

    // 2) Eager emission with tolerant PER.
    emitted.addAll(_checkTentativeEmission());
    emitted.addAll(_checkEagerEmission());
    emitted.addAll(_maybeRematchActiveWindow());

    // 3) Time-based fallback: if no new tokens for silenceEmitTimeoutS, flush
    //    the streamer and classify whatever phrase we have. This replaces VAD's
    //    silence-detection role.
    final staleMs =
        DateTime.now().difference(_lastTokenTime).inMilliseconds;
    final phraseHyp = _getSafePhraseHyp(streamer.fullText);
    if (!grew &&
        staleMs >= cfg.silenceEmitTimeoutS * 1000 &&
        phraseHyp.trim().isNotEmpty) {
      _absorbStreamerOutput(streamer.flush());
      emitted.addAll(_classifyPhraseBoundary());
      _lastTokenCount = streamer.fullText.length;
      _lastTokenTime = DateTime.now();
    }

    return emitted;
  }

  // ─── Madd anticipation ───────────────────────────────────────────────

  void _updateVadThreshold() {
    if (_vad == null || !cfg.vadEnabled || _ayah == null) return;

    var anchoredIdx = _ayah!.currentWordIdx;
    final phraseHyp = _getSafePhraseHyp(streamer.fullText);
    if (phraseHyp.isNotEmpty) {
      final alignment = alignPhraseToWords(
        phraseHyp: phraseHyp,
        wordSpans: _wordSpans,
        startIdx: anchoredIdx,
      );
      if (alignment.wordMatches.isNotEmpty) {
        anchoredIdx = alignment.wordMatches.last.wordIdx;
      }
    }

    // Ayah end: once the final word (madd included) has been fully said, the
    // stretched window only delays "ayah complete" — while a madd is still
    // being voiced VAD reports speech, so the silence timer isn't running
    // anyway. Re-checked every chunk because the anchor doesn't change while
    // the reciter holds the last word.
    if (_saidLastWord()) {
      final cap = cfg.ayahEndSilenceMs * cfg.sampleRate ~/ 1000;
      if (_vad.minSilenceSamples > cap) {
        _vad.minSilenceSamples = cap;
        // ignore: avoid_print
        print(
          '[session-madd] ayah-end cap silenceWindow=${cfg.ayahEndSilenceMs}ms',
        );
      }
      _ayahEndCapped = true;
      return;
    }
    if (_ayahEndCapped) {
      // The match regressed (e.g. still elongating) — restore the stretch.
      _ayahEndCapped = false;
      _lastMaddAnchorIdx = -1;
    }

    if (_lastMaddAnchorIdx == anchoredIdx) return;
    _lastMaddAnchorIdx = anchoredIdx;

    var maxRun = 0;
    final endIdx = anchoredIdx + 2 > _wordSpans.length
        ? _wordSpans.length
        : anchoredIdx + 2;
    for (var i = anchoredIdx; i < endIdx; i++) {
      final ws = _wordSpans[i];
      for (final m in _maddRepeat.allMatches(ws.phonemeText)) {
        final runLen = m.group(0)!.length;
        if (runLen > maxRun) maxRun = runLen;
      }
    }
    _applyMaddStretch(maxRun);
  }

  /// Whether the final word of the ayah has been fully recited (PER ≤
  /// [SessionConfig.eagerEmissionPer]). Uses [AdaptiveStreamingMuaalem.tentativeText]
  /// so a final word still in the streamer's uncommitted tail counts — during
  /// silence the streamer receives no audio, so committed text alone could
  /// lag behind forever. Only evaluated near the end of the ayah.
  bool _saidLastWord() {
    final lastIdx = _wordSpans.length - 1;
    final curIdx = _ayah!.currentWordIdx;
    if (lastIdx < 0 || curIdx < lastIdx - 1 || curIdx > lastIdx) return false;
    final hyp = _getSafePhraseHyp(streamer.tentativeText);
    if (hyp.trim().isEmpty) return false;
    final matches = alignPhraseToWords(
      phraseHyp: hyp,
      wordSpans: _wordSpans,
      startIdx: curIdx,
    ).wordMatches;
    if (matches.isEmpty) return false;
    final m = matches.last;
    return m.wordIdx == lastIdx &&
        m.hypPhonemes.trim().isNotEmpty &&
        m.per <= cfg.eagerEmissionPer;
  }

  void _applyMaddStretch(int maxRun) {
    final vad = _vad;
    if (vad == null) return;

    // Madd anticipation keeps the mic open longer (a stretched VAD silence
    // window) AND lets the streamer expand its decode window to capture an
    // ongoing elongation. The expansion is now hard-bounded by
    // [_boundedExpansions]: previously it pushed expansionS to 1.0–1.5 and
    // maxExpansions to 8–9, ballooning the decode window to ~9 s, which both
    // exploded inference (10–21× realtime) and corrupted the decode via
    // overlap-duplication. Keeping the window ≤ _maddMaxDecodeWindowS still
    // captures a 6-harakat Madd within a single window.
    if (maxRun >= 5) {
      // Madd Lazim (~6 harakat) — keep the mic open to 2.5s.
      vad.minSilenceSamples = (2.5 * cfg.sampleRate).toInt();
      final baseChunkS = _max(_origBaseChunkS!, 1.5);
      final expansionS = _max(_origExpansionS!, 0.5);
      streamer.cfg
        ..baseChunkS = baseChunkS
        ..expansionS = expansionS
        ..maxExpansions = _boundedExpansions(
          baseChunkS,
          expansionS,
          _maxInt(_origMaxExpansions!, 4),
        )
        ..rightLookaheadS = _max(_origRightLookaheadS!, 0.5)
        ..edgeFrames = _maxInt(_origEdgeFrames!, 20);
    } else if (maxRun == 4) {
      // Madd Arid / Muttasil (~4–5 harakat) — keep the mic open to 2.0s.
      vad.minSilenceSamples = (2.0 * cfg.sampleRate).toInt();
      final baseChunkS = _max(_origBaseChunkS!, 1.5);
      final expansionS = _max(_origExpansionS!, 0.5);
      streamer.cfg
        ..baseChunkS = baseChunkS
        ..expansionS = expansionS
        ..maxExpansions = _boundedExpansions(
          baseChunkS,
          expansionS,
          _maxInt(_origMaxExpansions!, 4) + _refundedExpansions.toInt(),
        )
        ..rightLookaheadS = _max(_origRightLookaheadS!, 0.5)
        ..edgeFrames = _maxInt(_origEdgeFrames!, 12);
    } else {
      // Restore baseline — still window-bounded so a large refund can't balloon
      // the decode window outside Madd anticipation either.
      vad.minSilenceSamples = _origVadMinSilenceSamples;
      streamer.cfg
        ..baseChunkS = _origBaseChunkS!
        ..expansionS = _origExpansionS!
        ..maxExpansions = _boundedExpansions(
          _origBaseChunkS!,
          _origExpansionS!,
          _origMaxExpansions! + _refundedExpansions.toInt(),
        )
        ..rightLookaheadS = _origRightLookaheadS!
        ..edgeFrames = _origEdgeFrames!;
    }

    // DIAGNOSTIC: when/how long the Madd anticipation holds the mic open. A
    // stretched window (2000–2500ms) is what makes the app feel "blocked" after
    // a phrase — the boundary can't fire until this much silence elapses.
    // ignore: avoid_print
    print('[session-madd] stretch maxRun=$maxRun '
        'silenceWindow=${vad.minSilenceSamples * 1000 ~/ cfg.sampleRate}ms '
        'baseChunkS=${streamer.cfg.baseChunkS} '
        'maxExpansions=${streamer.cfg.maxExpansions}');
  }

  // ─── Shared helpers ──────────────────────────────────────────────────

  bool _fireStreamUpdateIfGrown() {
    final cur = streamer.fullText.length;
    if (cur <= _lastTokenCount) return false;
    final cb = onStreamUpdate;
    if (cb != null) {
      try {
        cb(streamer.fullText);
      } catch (_) {
        // swallow
      }
    }
    _lastTokenCount = cur;
    _lastTokenTime = DateTime.now();
    if (cur > _lastCommittedTextLen) {
      _refundedExpansions = 0.0;
      _lastCommittedTextLen = cur;
    }
    return true;
  }

  void _postFeedBookkeeping(List<WordResult> emitted) {
    final ayah = _ayah;
    if (ayah == null) return;
    ayah.hypPhonemes = streamer.fullText;
    _recomputeOverallPer();

    // Mark the ayah complete once every word has a committed result. Both
    // emission paths leave the ayah `inProgress` until then.
    if (ayah.status == AyahStatus.inProgress &&
        _emittedWordIdxs.length == _wordSpans.length) {
      ayah.status = AyahStatus.complete;
    }

    final cb = onWordComplete;
    if (cb != null) {
      for (final w in emitted) {
        try {
          cb(w);
        } catch (_) {
          // swallow
        }
      }
    }

    // Signal completion as soon as the last word lands mid-stream so the
    // integrator can auto-stop the mic. Fire once for the active ayah no
    // matter which path completed it: the eager path and the phrase-boundary
    // path both set `complete` here once every word has been emitted.
    // finalizeAyah() fires this again with the authoritative result;
    // downstream listeners must be idempotent.
    if (ayah.status == AyahStatus.complete && !_ayahCompleteFired) {
      _ayahCompleteFired = true;
      final cb2 = onAyahComplete;
      if (cb2 != null) {
        try {
          cb2(ayah);
        } catch (_) {
          // swallow
        }
      }
    }
  }

  // ─── Streamer output absorption ──────────────────────────────────────

  void _absorbStreamerOutput(StreamingResult? result) {
    if (result == null) return;
    for (final mout in result.muaalemOutputs) {
      // For each predicted phoneme chunk, build a SifaSnapshot using the
      // model's per-level sifat IDs at the same chunk index. The
      // streamer's sifat output is keyed by level name; each level's
      // ids[] is aligned 1:1 with phoneme chunks of that mout's
      // committed text.
      final phonemeText = mout.phonemes.text;
      final chunks = chunkPhonemes(phonemeText);
      for (var ci = 0; ci < chunks.length; ci++) {
        _predictedSifaChunks.add(_snapshotPredictedSifa(mout, ci, chunks[ci]));
      }
    }
  }

  /// Builds a [SifaSnapshot] for chunk index [ci] from a model output's
  /// per-level sifat IDs. The integrator's [RecitationModel] supplies a
  /// vocab table for each level; we use those to translate IDs → string
  /// labels.
  ///
  /// If a level isn't present in [mout.sifat] OR `ids[ci]` is out of
  /// range, the attribute is left `null`.
  SifaSnapshot _snapshotPredictedSifa(
    MuaalemOutput mout,
    int ci,
    String chunkText,
  ) {
    String? labelAt(String level) {
      final unit = mout.sifat[level];
      if (unit == null || ci >= unit.ids.length) return null;
      return streamer.model.vocabLookup(level, unit.ids[ci]);
    }

    final conf = <String, double>{};
    void addConfidence(String level) {
      final unit = mout.sifat[level];
      if (unit == null || ci >= unit.probabilities.length) return;
      conf[level] = unit.probabilities[ci];
    }

    for (final attr in sifatAttributes) {
      addConfidence(attr);
    }

    return SifaSnapshot(
      phonemeGroup: chunkText,
      hamsOrJahr: labelAt('hams_or_jahr'),
      shiddaOrRakhawa: labelAt('shidda_or_rakhawa'),
      tafkheemOrTaqeeq: labelAt('tafkheem_or_taqeeq'),
      itbaq: labelAt('itbaq'),
      safeer: labelAt('safeer'),
      qalqla: labelAt('qalqla'),
      tikraar: labelAt('tikraar'),
      tafashie: labelAt('tafashie'),
      istitala: labelAt('istitala'),
      ghonna: labelAt('ghonna'),
      confidence: conf,
    );
  }

  // ─── Eager emission ──────────────────────────────────────────────────

  List<WordResult> _checkTentativeEmission() => _checkEmissionInternal(
        useTentative: true,
        perThreshold: 0.05,
      );

  List<WordResult> _checkEagerEmission() => _checkEmissionInternal(
        useTentative: false,
        perThreshold: cfg.vadEnabled
            ? cfg.eagerEmissionPer
            : cfg.eagerEmissionPerTolerant,
      );

  List<WordResult> _checkEmissionInternal({
    required bool useTentative,
    required double perThreshold,
  }) {
    final ayah = _ayah;
    if (ayah == null ||
        ayah.status == AyahStatus.complete ||
        ayah.status == AyahStatus.abandoned) {
      return const <WordResult>[];
    }
    final emitted = <WordResult>[];

    while (true) {
      final curIdx = ayah.currentWordIdx;
      if (curIdx >= _wordSpans.length) break;

      final ws = _wordSpans[curIdx];
      final source =
          useTentative ? streamer.tentativeText : streamer.fullText;
      final phraseHyp = _getSafePhraseHyp(source);

      final alignment = alignPhraseToWords(
        phraseHyp: phraseHyp,
        wordSpans: _wordSpans,
        startIdx: curIdx,
      );
      if (alignment.wordMatches.isEmpty) break;
      final wm = alignment.wordMatches.first;
      if (wm.wordIdx != curIdx) break;
      // An empty hypothesis means the aligner found no phrase characters for
      // this word — the user hasn't reached it yet. Wait for more audio
      // instead of emitting a phantom (per=1.0, "locked") result and
      // advancing past a word that was never attempted.
      if (wm.hypPhonemes.trim().isEmpty) break;

      final isLastMatch = alignment.wordMatches.length == 1;
      if (!isLastMatch) {
        // Later words also matched, so the reciter has clearly moved past this
        // one — commit it on its pure PER. The one exception: a severe error
        // (PER ≥ the red threshold) on a non-last word almost always means the
        // aligner spread stray/noise phonemes across several words while the
        // reciter actually stopped here. Committing would fabricate a cascade
        // of red results for words that were never recited (the user's "pointer
        // marks all consecutive words as wrong"). Hold instead — surface a live
        // hint and wait. The phrase-boundary classifier still commits/advances
        // once the reciter genuinely pauses, and a later re-recitation can
        // replace the result via the repetition path.
        //
        // EXCEPT for head-of-line blocking: if a LATER word in this alignment is
        // *cleanly* recited, the reciter has genuinely moved on and the model
        // just garbled/dropped THIS word (e.g. a reduced connecting وَ the model
        // emitted no CTC peak for). Freezing on it until the next VAD boundary
        // is the multi-second "stuck/glowing on a word" stall. Instead, commit
        // this word red and advance — the reciter sees the error and the pointer
        // keeps moving; a later re-recitation can still correct it.
        final movedPast = alignment.wordMatches.skip(1).any(
              (m) =>
                  m.hypPhonemes.trim().isNotEmpty &&
                  m.per <= classifierConfig.goodPerThreshold,
            );
        if (wm.per >= classifierConfig.wordZeroLockPer) {
          // Skip-ahead (commit this word red and advance) is ONLY valid for a
          // forward model-miss: a cleanly-recited LATER word is proof the
          // reciter moved on past a word the model garbled/dropped. During a
          // GO-BACK the reciter re-recited earlier words with no pause, and the
          // forward-only aligner forces that re-recitation onto
          // [curWord, curWord+1, …] — so the "clean later word" is just the next
          // re-recited word, NOT forward progress. Skipping ahead here commits
          // the current word red by mistake (the إِنْ per=6.0 misfire). So skip
          // ahead only when this is NOT a go-back; otherwise hold and let
          // _maybeClassifyGoBack run the repetition path on the next feed.
          final isGoBack = _looksLikeRepetition(phraseHyp);
          if (!movedPast || isGoBack) {
            if (!useTentative && !isGoBack) {
              _fireLiveWordFeedback(ws, wm.hypPhonemes, wm.per);
            }
            break;
          }
        }
      } else if (wm.per > 0.05) {
        // Last (current) word, imperfect score. Wait until there's a chunk of
        // audio past the expected word length so we don't score a word that's
        // still being spoken.
        final phraseChunks = chunkPhonemes(phraseHyp);
        final minChunksNeeded =
            ws.chunks.length + cfg.eagerEmissionLookaheadChunks;
        if (phraseChunks.length < minChunksNeeded) break;
        // Lookahead satisfied but the score is still bad — the reciter is most
        // likely stuck on this word. Hold (surface a live hint) rather than
        // committing a red result and marching the pointer onto un-recited
        // words. The boundary classifier commits this word once they pause.
        if (wm.per > perThreshold) {
          if (!useTentative && !_looksLikeRepetition(phraseHyp)) {
            _fireLiveWordFeedback(ws, wm.hypPhonemes, wm.per);
          }
          break;
        }
      }

      var wr = _buildWordResult(ws, wm.hypPhonemes, wm.per);
      // Upsert: if a result for this word already exists (e.g. emitted
      // earlier and now being re-emitted by a corrected recitation),
      // replace it in place and inherit its repetition count.
      var replaced = false;
      for (var i = 0; i < ayah.wordResults.length; i++) {
        if (ayah.wordResults[i].wordIdx == curIdx) {
          wr = wr.copyWith(nRepetitions: ayah.wordResults[i].nRepetitions);
          ayah.wordResults[i] = wr;
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        ayah.wordResults.add(wr);
      }
      _emittedWordIdxs.add(curIdx);
      // Monotonic — never goes backward, even if the upsert was for
      // a word the user re-recited from a position behind currentWordIdx.
      ayah.currentWordIdx = _maxInt(ayah.currentWordIdx, curIdx + 1);
      emitted.add(wr);

      final consumed = wm.hypPhonemes.length;
      if (useTentative) {
        // Refund expansion budget based on actual audio time consumed.
        final tentativeChars = _maxInt(
            (_phraseAnchorHypLen + consumed) - streamer.fullText.length,
            0,
        );
        final consumedS =
            streamer.getTentativeTimeConsumed(tentativeChars);
        _refundedExpansions = consumedS / streamer.cfg.expansionS;
      }
      _phraseAnchorHypLen += consumed;
    }

    return emitted;
  }

  /// Surfaces a provisional hint for the word currently being held in the
  /// eager path, WITHOUT committing it. This is a pure read — it mutates no
  /// session state and never advances the pointer; it only lets the UI flash
  /// an amber/red cue on the word the reciter is stuck on. Only "needs work"
  /// statuses ([WordStatus.errors] / [WordStatus.locked]) are surfaced; a clean
  /// in-progress word produces no hint.
  void _fireLiveWordFeedback(WordSpan ws, String hypPhonemes, double per) {
    final cb = onLiveWordFeedback;
    if (cb == null) return;
    final wr = _buildWordResult(ws, hypPhonemes, per);
    if (wr.status != WordStatus.errors && wr.status != WordStatus.locked) {
      return;
    }
    try {
      cb(wr);
    } catch (_) {
      // swallow — matches the other callback sites
    }
  }

  /// True when the current eager phrase would be classified as a repetition of
  /// a word EARLIER than `currentWordIdx` — i.e. the reciter went back to
  /// re-recite (e.g. after a breath). The eager path can't commit a repetition
  /// (it only scans forward from the current word), but it uses this to avoid
  /// flashing a misleading error hint on the current word while a go-back is in
  /// progress, and [_maybeClassifyGoBack] uses it to run the phrase-boundary
  /// classifier immediately so the pointer follows the reciter without waiting
  /// for a pause. Predicts [classifyPhrase]'s Rule-3 repetition decision exactly
  /// (same back-scan, same clean-go-back / margin tests) so it neither steals a
  /// clean forward continuation nor misses an imperfect re-recitation.
  bool _looksLikeRepetition(String phraseHyp) {
    final ayah = _ayah;
    if (ayah == null || ayah.currentWordIdx == 0) return false;
    final rep = scoreRepetition(
      phraseHyp: phraseHyp,
      wordSpans: _wordSpans,
      currentWordIdx: ayah.currentWordIdx,
      window: classifierConfig.repetitionWindow,
    );
    if (rep == null) return false;
    final h2Per = rep.alignment.overallPer;
    // This mid-stream gate must fire in exactly the cases the boundary
    // classifier would actually COMMIT a repetition — no looser (which would
    // steal a clean forward continuation and stall the pointer) and no tighter.
    // The old gate only accepted an *absolutely* clean back-match
    // (`<= goodPerThreshold`), which is stricter than classifyPhrase's own Rule
    // 3: a slightly-imperfect re-recitation after a breath (e.g. PER ~0.35) that
    // still reads clearly better against the word the reciter went back to than
    // against the expected next word was recognised by classifyPhrase but never
    // got the chance to run, so the pointer didn't follow the go-back. Mirror
    // classifyPhrase's Rule 3 exactly: H2 below the noise floor AND either a
    // clean go-back (H2 ≤ good AND strictly better than H1) or H2 beats forward
    // continuation by the repetition margin.
    if (h2Per > classifierConfig.noisePerThreshold) return false;
    final h1Per = alignPhraseToWords(
      phraseHyp: phraseHyp,
      wordSpans: _wordSpans,
      startIdx: ayah.currentWordIdx,
      maxWords: classifierConfig.continuationWindow,
    ).overallPer;
    final repByCleanGoBack =
        h2Per <= classifierConfig.goodPerThreshold && h2Per < h1Per;
    final repByMargin =
        (h1Per - h2Per) >= classifierConfig.repetitionMargin;
    return repByCleanGoBack || repByMargin;
  }

  /// Resolves a breath-then-go-back that has no accompanying VAD silence.
  ///
  /// Called only when the eager (forward-only) path made no progress. If the
  /// reciter clearly went back to re-recite an earlier word — a non-trivial
  /// phrase that cleanly matches a word behind `currentWordIdx` — run the
  /// phrase-boundary classifier immediately. It already handles repetition
  /// correctly (commit/replace the re-recited words and advance the pointer),
  /// so the UI follows the reciter instead of freezing on the expected word
  /// until the next pause. Returns the committed results, or empty if this
  /// isn't a recognisable go-back.
  ///
  /// Self-limiting: [_classifyPhraseBoundary] resets the phrase anchor, so the
  /// next phrase is empty and this won't re-fire until a new go-back appears.
  List<WordResult> _maybeClassifyGoBack() {
    final ayah = _ayah;
    if (ayah == null || ayah.currentWordIdx == 0) return const <WordResult>[];
    final phraseHyp = _getSafePhraseHyp(streamer.fullText);
    // Require a substantial phrase so a transient partial-word prefix that
    // happens to match an earlier word can't trigger a spurious classify.
    if (chunkPhonemes(phraseHyp).length < _goBackMinPhraseChunks) {
      return const <WordResult>[];
    }
    if (!_looksLikeRepetition(phraseHyp)) return const <WordResult>[];
    // Mid-stream: the reciter has NOT paused, so a trailing word in this phrase
    // is very likely still being pronounced. Hold a trailing partial rather
    // than committing the fragment red and spilling its body onto the next word.
    return _classifyPhraseBoundary(holdTrailingPartial: true);
  }

  // ─── Phrase-boundary classification ──────────────────────────────────

  List<WordResult> _classifyPhraseBoundary({bool holdTrailingPartial = false}) {
    final ayah = _ayah;
    if (ayah == null) return const <WordResult>[];

    _heldTrailingHypLen = 0;
    final emitted = <WordResult>[];
    final phraseHyp = _getSafePhraseHyp(streamer.fullText);
    if (phraseHyp.trim().isEmpty) return emitted;

    final alignment = classifyPhrase(
      phraseHyp: phraseHyp,
      wordSpans: _wordSpans,
      currentWordIdx: ayah.currentWordIdx,
      nextAyahFirstWord: _nextAyahFirstWord,
      config: classifierConfig,
    );

    // DIAGNOSTIC: why a phrase advanced / repeated / was rejected. The
    // per-word PERs reveal whether a "correctly recited" word is being scored
    // high (alignment/segmentation problem) vs genuinely mis-recited.
    // ignore: avoid_print
    print('[session-classify] decision=${alignment.decision.name} '
        'overallPer=${alignment.overallPer.toStringAsFixed(2)} '
        'perWord=[${alignment.perPerWord.map((p) => p.toStringAsFixed(2)).join(',')}] '
        'curWord=${ayah.currentWordIdx} '
        'hyp="$phraseHyp"');

    switch (alignment.decision) {
      case PhraseDecision.continuation:
        emitted.addAll(
          _applyContinuation(alignment, phraseHyp, holdTrailingPartial),
        );
      case PhraseDecision.repetition:
        emitted.addAll(
          _applyRepetition(alignment, phraseHyp, holdTrailingPartial),
        );
      case PhraseDecision.nextAyah:
        emitted.addAll(_applyNextAyah(alignment, phraseHyp));
      case PhraseDecision.ambiguous:
      case PhraseDecision.noise:
        emitted.addAll(_applyNoiseForceAttempt(phraseHyp));
    }

    final cb = onPhraseClassified;
    if (cb != null) {
      try {
        cb(alignment, phraseHyp);
      } catch (_) {
        // swallow
      }
    }

    // Preserve a held trailing partial word (see _holdTrailingPartial) so the
    // next phrase re-attributes its full body instead of the anchor consuming
    // the fragment and spilling the rest onto the next word.
    _phraseAnchorHypLen =
        _maxInt(0, streamer.fullText.length - _heldTrailingHypLen);
    _wordsAtPhraseStart = ayah.wordResults.length;

    return emitted;
  }

  /// Phrase-boundary commits attribute the WHOLE phrase across the matched
  /// words — including a trailing word the reciter has only STARTED. When the
  /// boundary fired mid-word (a mid-stream go-back classify during an
  /// elongation/decode-backlog), committing that partial fragment (e.g. just
  /// "وَ" of وَمِمَّا) marks it red AND, once the anchor advances past it, spills
  /// the word's real body onto the NEXT word — both go red (the on-device 2:3
  /// وَمِمَّا/رَزَقْنَـٰهُمْ mixing). Detect that trailing partial — a not-yet-emitted
  /// LAST match whose hyp covers fewer chunks than its reference AND scores
  /// worse than a clean match — drop it from the commit set and record how many
  /// trailing phrase chars to preserve via [_heldTrailingHypLen]. Returns the
  /// matches to actually commit. Only used on the mid-stream path; at a true VAD
  /// boundary the reciter paused, so even a short word is a complete attempt and
  /// must commit (red) as before.
  List<WordMatch> _holdTrailingPartial(
    List<WordMatch> matches,
    String leftoverHyp,
  ) {
    if (matches.isEmpty) return matches;
    final last = matches.last;
    if (_emittedWordIdxs.contains(last.wordIdx)) return matches;
    final ws = _wordSpans[last.wordIdx];
    final isTrailingPartial = last.hypChunks.length < ws.chunks.length &&
        last.per > classifierConfig.goodPerThreshold;
    if (!isTrailingPartial) return matches;
    _heldTrailingHypLen = last.hypPhonemes.length + leftoverHyp.length;
    return matches.sublist(0, matches.length - 1);
  }

  List<WordResult> _applyContinuation(
    PhraseAlignment alignment,
    String phraseHyp,
    bool holdTrailingPartial,
  ) {
    final ayah = _ayah!;
    final emitted = <WordResult>[];
    final detail = alignPhraseToWords(
      phraseHyp: phraseHyp,
      wordSpans: _wordSpans,
      startIdx: alignment.startWordIdx,
      maxWords: alignment.endWordIdx - alignment.startWordIdx,
    );
    final commitMatches = holdTrailingPartial
        ? _holdTrailingPartial(detail.wordMatches, detail.leftoverHyp)
        : detail.wordMatches;
    for (final wm in commitMatches) {
      if (_emittedWordIdxs.contains(wm.wordIdx)) continue;
      // An empty hypothesis means the aligner padded this (and every later)
      // word with no recited content — the phrase ended before the reciter
      // reached it. Stop instead of force-committing the un-recited tail as red
      // phantoms (which also falsely completes the ayah). The reciter reaches
      // these words in a later phrase. The aligner trims *trailing* empty
      // matches, but a stray garbage match landing on a much later word (a
      // model mis-decode) leaves real empties in the middle — this guard stops
      // the red cascade there.
      if (wm.hypPhonemes.trim().isEmpty) break;
      final ws = _wordSpans[wm.wordIdx];
      final wr = _buildWordResult(ws, wm.hypPhonemes, wm.per);
      ayah.wordResults.add(wr);
      _emittedWordIdxs.add(wm.wordIdx);
      emitted.add(wr);
    }
    while (ayah.currentWordIdx < _wordSpans.length &&
        _emittedWordIdxs.contains(ayah.currentWordIdx)) {
      ayah.currentWordIdx += 1;
    }
    return emitted;
  }

  List<WordResult> _applyRepetition(
    PhraseAlignment alignment,
    String phraseHyp,
    bool holdTrailingPartial,
  ) {
    final ayah = _ayah!;
    final emitted = <WordResult>[];
    final detail = alignPhraseToWords(
      phraseHyp: phraseHyp,
      wordSpans: _wordSpans,
      startIdx: alignment.startWordIdx,
      maxWords: alignment.endWordIdx - alignment.startWordIdx,
    );
    final commitMatches = holdTrailingPartial
        ? _holdTrailingPartial(detail.wordMatches, detail.leftoverHyp)
        : detail.wordMatches;
    for (final wm in commitMatches) {
      final ws = _wordSpans[wm.wordIdx];
      int? oldIdx;
      for (var i = 0; i < ayah.wordResults.length; i++) {
        if (ayah.wordResults[i].wordIdx == wm.wordIdx) {
          oldIdx = i;
          break;
        }
      }
      final nRep = oldIdx != null
          ? ayah.wordResults[oldIdx].nRepetitions + 1
          : 2;
      var wr =
          _buildWordResult(ws, wm.hypPhonemes, wm.per, nRepetitions: nRep);
      if (oldIdx != null) {
        // A re-recitation only replaces the stored result when it scores at
        // least as well; otherwise keep the better earlier attempt and just
        // bump the repetition count.
        if (wr.per <= ayah.wordResults[oldIdx].per) {
          ayah.wordResults[oldIdx] = wr;
        } else {
          ayah.wordResults[oldIdx] = ayah.wordResults[oldIdx]
              .copyWith(nRepetitions: nRep);
          wr = ayah.wordResults[oldIdx];
        }
      } else {
        ayah.wordResults.add(wr);
        _emittedWordIdxs.add(wm.wordIdx);
      }
      emitted.add(wr);
    }
    // A repetition that re-recites the CURRENT word (e.g. the model duplicated
    // it and the classifier read the duplicate as a repetition spanning into
    // currentWordIdx) now has that word emitted — advance the monotonic pointer
    // past any contiguous emitted words so the eager path doesn't keep
    // re-evaluating an already-committed word and flooding live hints for it.
    while (ayah.currentWordIdx < _wordSpans.length &&
        _emittedWordIdxs.contains(ayah.currentWordIdx)) {
      ayah.currentWordIdx += 1;
    }
    return emitted;
  }

  List<WordResult> _applyNextAyah(
    PhraseAlignment alignment,
    String phraseHyp,
  ) {
    final ayah = _ayah!;
    // Finalize the current ayah implicitly.
    for (final ws in _wordSpans) {
      if (!_emittedWordIdxs.contains(ws.wordIdx)) {
        ayah.wordResults.add(_buildMissingWordResult(ws));
      }
    }
    ayah.wordResults.sort((a, b) => a.wordIdx - b.wordIdx);
    ayah.status = AyahStatus.complete;
    final cb = onAyahComplete;
    if (cb != null) {
      try {
        cb(ayah);
      } catch (_) {
        // swallow
      }
    }

    // Use the pre-loaded next ayah. If it isn't available, we can't
    // advance — fall back to clearing state and bailing out.
    final next = _nextAyahPreloaded;
    if (next == null) {
      // No pre-loaded ayah; we still close out the current one. The
      // user can call startAyah() manually for the next one.
      return const <WordResult>[];
    }
    _applyAyahReference(next, null);

    // Re-route the carried phrase through the new ayah's first word.
    final emitted = <WordResult>[];
    final newAyah = _ayah!;
    final reAlign = alignPhraseToWords(
      phraseHyp: phraseHyp,
      wordSpans: _wordSpans,
      startIdx: 0,
      maxWords: 1,
    );
    for (final wm in reAlign.wordMatches) {
      final ws = _wordSpans[wm.wordIdx];
      final wr = _buildWordResult(ws, wm.hypPhonemes, wm.per);
      newAyah.wordResults.add(wr);
      _emittedWordIdxs.add(wm.wordIdx);
      newAyah.currentWordIdx = _maxInt(
        newAyah.currentWordIdx,
        wm.wordIdx + 1,
      );
      emitted.add(wr);
    }

    // Kick off loading the new "next next" ayah in the background. We
    // fire-and-forget the future; if it completes before the user
    // finishes this ayah, _nextAyahPreloaded gets populated. Otherwise
    // H3 stays inactive for now.
    unawaited(_preloadNextAyahInBackground());

    return emitted;
  }

  Future<void> _preloadNextAyahInBackground() async {
    try {
      final ref = await referenceLoader.load(
        sura: _curSura,
        ayah: _curAyah + 1,
      );
      _nextAyahPreloaded = ref;
      _nextAyahFirstWord =
          ref.spans.isNotEmpty ? ref.spans.first : null;
    } catch (_) {
      _nextAyahPreloaded = null;
      _nextAyahFirstWord = null;
    }
  }

  /// Handles `noise`/`ambiguous` outcomes by force-attempting alignment at the
  /// current word index, so even an unclear phrase still yields a result for
  /// the word the reciter is on rather than stalling.
  List<WordResult> _applyNoiseForceAttempt(String phraseHyp) {
    final ayah = _ayah!;
    final emitted = <WordResult>[];
    final forceIdx = ayah.currentWordIdx;
    if (forceIdx >= _wordSpans.length) return emitted;
    if (_emittedWordIdxs.contains(forceIdx)) return emitted;

    final forced = alignPhraseToWords(
      phraseHyp: phraseHyp,
      wordSpans: _wordSpans,
      startIdx: forceIdx,
    );
    if (forced.wordMatches.isEmpty) return emitted;
    final wm = forced.wordMatches.first;
    final ws = _wordSpans[wm.wordIdx];
    final wr = _buildWordResult(ws, wm.hypPhonemes, wm.per);
    ayah.wordResults.add(wr);
    _emittedWordIdxs.add(wm.wordIdx);
    emitted.add(wr);
    return emitted;
  }

  // ─── WordResult construction ─────────────────────────────────────────

  WordResult _buildWordResult(
    WordSpan ws,
    String hypPhonemes,
    double per, {
    int nRepetitions = 1,
  }) {
    final predictedSifa = _slicePredictedSifaForWord(ws, hypPhonemes);
    final sifaDiffs = _computeSifaDiffs(ws.sifatRefs, predictedSifa);
    final status =
        _perToStatus(per, classifierConfig.wordZeroLockPer, ws.chunks.length);

    return WordResult(
      wordIdx: ws.wordIdx,
      uthmaniWord: ws.uthmaniText,
      uthmaniSpanInAyah: ws.uthmaniSpan,
      refPhonemes: ws.phonemeText,
      hypPhonemes: hypPhonemes,
      per: per,
      status: status,
      sifatReference: ws.sifatRefs,
      sifatPredicted: predictedSifa,
      sifatDiffs: sifaDiffs,
      confidence: per >= 1.0 ? 0.0 : (1.0 - per),
      nRepetitions: nRepetitions,
    );
  }

  WordResult _buildMissingWordResult(WordSpan ws) => WordResult(
        wordIdx: ws.wordIdx,
        uthmaniWord: ws.uthmaniText,
        uthmaniSpanInAyah: ws.uthmaniSpan,
        refPhonemes: ws.phonemeText,
        hypPhonemes: '',
        per: 1.0,
        status: WordStatus.skipped,
        sifatReference: ws.sifatRefs,
      );

  // ─── Predicted-sifa slicing ──────────────────────────────────────────

  /// Locates the slice of [_predictedSifaChunks] that corresponds to
  /// [hypPhonemes] for word [ws].
  ///
  /// Strategy: chunk both `streamer.fullText` and `hypPhonemes`; search
  /// the global chunks list from the end backward for the most recent
  /// contiguous match of the word's chunks. Falls back to "last N
  /// chunks" if no contiguous match found.
  List<SifaSnapshot> _slicePredictedSifaForWord(
    WordSpan ws,
    String hypPhonemes,
  ) {
    if (_predictedSifaChunks.isEmpty || hypPhonemes.isEmpty) {
      return const <SifaSnapshot>[];
    }
    final wordChunks = chunkPhonemes(hypPhonemes);
    if (wordChunks.isEmpty) return const <SifaSnapshot>[];

    final fullChunks = chunkPhonemes(streamer.fullText);
    final nFull = fullChunks.length;

    // Try ending positions from the end backward; most recent match wins.
    for (var end = nFull; end >= wordChunks.length; end--) {
      final start = end - wordChunks.length;
      var match = true;
      for (var k = 0; k < wordChunks.length; k++) {
        if (fullChunks[start + k] != wordChunks[k]) {
          match = false;
          break;
        }
      }
      if (match) {
        // Bounds-safe slice.
        final safeEnd =
            end <= _predictedSifaChunks.length ? end : _predictedSifaChunks.length;
        final safeStart = start <= safeEnd ? start : safeEnd;
        return _predictedSifaChunks.sublist(safeStart, safeEnd);
      }
    }

    // Fallback: last N predicted chunks.
    final n = wordChunks.length;
    if (n >= _predictedSifaChunks.length) {
      return List<SifaSnapshot>.from(_predictedSifaChunks);
    }
    return _predictedSifaChunks.sublist(_predictedSifaChunks.length - n);
  }

  // Aligns predicted ↔ reference sifat chunks by phoneme group (rather than
  // zipping by index) and labels each diff with the reference chunk, so a
  // streaming-seam spillover chunk can't surface another word's phonemes in
  // the correction drawer. See [computeSifaDiffs] in sifat.dart.
  List<SifaDiff> _computeSifaDiffs(
    List<SifaSnapshot> refSifa,
    List<SifaSnapshot> predictedSifa,
  ) =>
      computeSifaDiffs(ref: refSifa, predicted: predictedSifa);

  String _getSafePhraseHyp(String source) {
    if (_phraseAnchorHypLen >= source.length) return '';
    return source.substring(_phraseAnchorHypLen);
  }

  // ─── Overall PER ─────────────────────────────────────────────────────

  void _recomputeOverallPer() {
    final ayah = _ayah;
    if (ayah == null || ayah.wordResults.isEmpty) return;
    var totalChunks = 0;
    var weightedPer = 0.0;
    for (final w in ayah.wordResults) {
      final nc = chunkPhonemes(w.refPhonemes).length;
      final ncAtLeastOne = nc < 1 ? 1 : nc;
      totalChunks += ncAtLeastOne;
      weightedPer += w.per * ncAtLeastOne;
    }
    if (totalChunks <= 0) {
      ayah.overallPer = 0.0;
    } else {
      ayah.overallPer = weightedPer / totalChunks;
    }
  }

  static double _max(double a, double b) => a > b ? a : b;
  static int _maxInt(int a, int b) => a > b ? a : b;

  /// Hard ceiling (seconds) on the streamer's worst-case decode window during
  /// Madd anticipation: `baseChunkS + maxExpansions * expansionS` must stay at
  /// or below this. A larger window both explodes inference (each audio chunk
  /// re-decodes the entire window) and corrupts the decode through
  /// overlap-duplication — the failure that stalled the pipeline on Madd-heavy
  /// ayat. 3.5 s still captures a 6-harakat Madd (~3 s) inside one window.
  static const double _maddMaxDecodeWindowS = 3.5;

  /// Caps [desired] expansions so the worst-case decode window stays within
  /// [_maddMaxDecodeWindowS], however high Madd anticipation or refunded
  /// expansion budget would otherwise push it.
  static int _boundedExpansions(
    double baseChunkS,
    double expansionS,
    int desired,
  ) {
    final d = desired < 0 ? 0 : desired;
    if (expansionS <= 0) return d;
    final maxByWindow =
        ((_maddMaxDecodeWindowS - baseChunkS) / expansionS).floor();
    final cap = maxByWindow < 0 ? 0 : maxByWindow;
    return d < cap ? d : cap;
  }
}
