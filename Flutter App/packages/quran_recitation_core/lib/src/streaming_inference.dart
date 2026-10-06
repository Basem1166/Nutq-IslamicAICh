/// Adaptive streaming inference for the recitation pipeline.
///
/// Why adaptive
/// ────────────
/// Fixed-chunk streaming fails when an elongated phoneme (Madd `اا`,
/// repeated diacritic `ييي`, etc.) crosses a chunk boundary. The model's
/// CTC emits one peak per "time unit" of the phoneme; cutting the audio
/// mid-elongation leaves the encoder with incomplete context on both
/// sides, producing phantom peaks (overcount), missed peaks
/// (undercount), or substitutions.
///
/// Idea
/// ────
/// Don't commit a window's tokens while the *last* decoded token's peak
/// frame sits in the boundary-risk zone at the right edge of the audio
/// — it may be the ongoing middle of an elongation. Instead, keep the
/// audio in the buffer, wait for the next `expansionS` worth of
/// samples, and re-run inference on the expanded window. Commit when
/// the last peak is comfortably inside the chunk (we've seen a phoneme
/// change after it), or when `maxExpansions` is reached (hard latency
/// cap).
///
/// Trade-offs vs. fixed-window:
///   - Higher accuracy on elongated phonemes (encoder sees the full
///     extent before committing).
///   - Higher worst-case latency: `baseChunkS + maxExpansions *
///     expansionS`.
///   - Higher compute: up to `maxExpansions + 1` inferences per commit.
///
/// Model abstraction
/// ─────────────────
/// The streamer doesn't depend on a specific ONNX runtime. It calls a
/// [RecitationModel] which must:
///   - Run inference on `(audio, frameStart, frameEnd)` and return a
///     [MuaalemOutput] with phoneme IDs, frame indices, and text.
///   - Re-decode a different `(frameStart, frameEnd)` range from the
///     logits cached during the most recent inference (for seam
///     recovery).
///   - Look up vocabulary by `(level, id)` for text construction.
///
/// The user's existing `mualem_model.dart` + `ctc_decoder.dart` +
/// `feature_extractor.dart` wrap this interface in a thin adapter
/// (see `integration_patches/recitation_model_adapter.dart`).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

// ─────────────────────────────────────────────────────────────────────────
//  Wav2Vec2-BERT timing constants
// ─────────────────────────────────────────────────────────────────────────

/// SeamlessM4T feature extractor frame length (samples).
const int featExtractorFrameLen = 400;

/// SeamlessM4T feature extractor hop length (samples).
const int featExtractorHopLen = 160;

/// Diagnostic switch for the seam-recovery path. When `true`, every commit logs
/// its frame layout (`fs`/`fe`), the leading decoded tokens with their peak
/// frame *relative to frameStart* (so a peak at `@0`/`@1` sits in the unstable
/// left-edge zone), the re-decoded seam overlap, and the suffix-prefix dedup
/// result. This pinpoints whether a dropped leading phoneme (e.g. the وَ in
/// وَأَرْسَلْنَا → "رسَلنَ") is filtered by the main decode, missed by the seam
/// re-decode, or eaten by the dedup. Toggle off in production.
const bool kStreamerSeamDebug = true;

/// SeamlessM4T feature extractor stride (frames merged into chunks).
const int featExtractorStride = 2;

/// Samples of audio per CTC output frame (`featExtractorHopLen *
/// featExtractorStride` = 160 × 2 = 320 = 20 ms).
///
/// **Frame-tiling invariant:** consecutive commits emit non-overlapping,
/// gapless absolute CTC frames *iff* every committed chunk length is a multiple
/// of this. `samplesToCtcFrames` is non-additive (floor-divide + the −400
/// feature-window offset), but for a chunk length `T` that is a multiple of 320
/// the carry cancels and `f(leftCtx + T) − f(leftCtx) == T / 320` exactly — so
/// the chunk occupies precisely `T / 320` frames regardless of the left-context
/// size, and no boundary frame is skipped or double-decoded. A chunk length
/// that is *not* a multiple of 320 silently drops or duplicates ~one phoneme's
/// frame at the commit seam. [AdaptiveStreamingMuaalem] asserts this on every
/// milestone commit.
const int ctcFrameStrideSamples = featExtractorHopLen * featExtractorStride;

/// Wav2Vec2-BERT adapter convolution kernel.
const int adapterKernel = 3;

/// Wav2Vec2-BERT adapter convolution stride.
const int adapterStride = 2;

/// Wav2Vec2-BERT adapter convolution padding.
const int adapterPad = adapterKernel ~/ 2;

/// Wav2Vec2-BERT adapter layer count.
const int adapterLayers = 1;

/// CTC blank token id (PAD_TOKEN_IDX in the upstream Python).
const int blankId = 0;

/// Translates `nSamples` of raw audio to the count of CTC output frames
/// the model will produce.
///
/// Faithful port of `samples_to_ctc_frames`:
///   1. Feature extractor: `(n - frameLen) // hop + 1` frames, then
///      halved by stride.
///   2. Adapter convolution: `((L + 2P - K) // S) + 1`, applied once.
int samplesToCtcFrames(int nSamples) {
  if (nSamples < featExtractorFrameLen) return 0;
  var featLen = (nSamples - featExtractorFrameLen) ~/ featExtractorHopLen + 1;
  featLen = featLen ~/ featExtractorStride;
  if (featLen <= 0) return 0;
  // NOTE: The adapter convolution loop is removed here because the ONNX model's
  // output time dimension matches the post-feature-extractor length exactly.
  /*
  for (var i = 0; i < adapterLayers; i++) {
    final canvas = featLen + 2 * adapterPad;
    featLen = (canvas - adapterKernel) ~/ adapterStride + 1;
    if (featLen <= 0) return 0;
  }
  */
  return featLen;
}

// ─────────────────────────────────────────────────────────────────────────
//  Model interface + output types
// ─────────────────────────────────────────────────────────────────────────

/// One CTC level's output: ids, peak frame indices, optional per-id
/// probabilities, decoded text.
@immutable
class PhonemeUnit {
  /// Builds a phoneme unit.
  const PhonemeUnit({
    required this.ids,
    required this.text,
    this.frames = const <int>[],
    this.probabilities = const <double>[],
  });

  /// Decoded token IDs.
  final List<int> ids;

  /// Concatenated string of vocab[id] for each id.
  final String text;

  /// CTC peak frame index for each decoded id. Same length as [ids]
  /// when populated; may be empty if the model wasn't asked for them.
  final List<int> frames;

  /// Per-id maximum softmax probability. Same length as [ids] when
  /// populated.
  final List<double> probabilities;
}

/// One sifat level's output: ids and probabilities (no text, no frames).
@immutable
class SifaUnit {
  /// Builds a sifat unit.
  const SifaUnit({required this.ids, required this.probabilities});

  /// Sifat label IDs (one per phoneme chunk in this level).
  final List<int> ids;

  /// Per-id probability.
  final List<double> probabilities;
}

/// Full multi-level output of one inference call.
///
/// Mirrors the Python `MuaalemOutput`:
///   - `phonemes`: the phoneme level (with frames + text).
///   - `sifat`: per-sifat-level outputs keyed by level name.
@immutable
class MuaalemOutput {
  /// Builds a full inference result.
  const MuaalemOutput({
    required this.phonemes,
    this.sifat = const <String, SifaUnit>{},
  });

  /// Phoneme-level output.
  final PhonemeUnit phonemes;

  /// Sifat-level outputs keyed by level name (e.g. `'hams_or_jahr'`).
  /// Empty if the caller didn't request sifat decoding.
  final Map<String, SifaUnit> sifat;
}

/// Abstract recitation model. Implement this in the Flutter app by
/// wrapping your existing `mualem_model.dart` + `ctc_decoder.dart` +
/// `feature_extractor.dart`.
abstract class RecitationModel {
  /// Runs inference on [audio] and decodes the result, restricting CTC
  /// emission to the frame range `[frameStart, frameEnd)`.
  ///
  /// `frameStart` / `frameEnd` are CTC-level indices (not sample
  /// indices). They define which frames contribute decoded tokens; any
  /// CTC peaks outside this range are filtered out by the decoder.
  ///
  /// The implementation MUST cache the raw logits internally so a
  /// subsequent call to [decodeFromLastLogits] can re-decode a
  /// different frame range without re-running inference.
  MuaalemOutput run({
    required Float32List audio,
    required int frameStart,
    required int frameEnd,
  });

  /// Re-decodes a different `(frameStart, frameEnd)` range from the
  /// logits cached during the most recent [run] call. Used by the
  /// streamer for seam recovery.
  ///
  /// Returns `null` if no cached logits are available.
  PhonemeUnit? decodeFromLastLogits({
    required int frameStart,
    required int frameEnd,
  });

  /// Returns the vocabulary string for `(level, id)`. The streamer uses
  /// `level = 'phonemes'`.
  String vocabLookup(String level, int id);
}

// ─────────────────────────────────────────────────────────────────────────
//  Window + result types
// ─────────────────────────────────────────────────────────────────────────

/// One window of audio passed to inference, plus its CTC-frame
/// emission bounds.
@immutable
class Window {
  /// Builds a window.
  const Window({
    required this.audio,
    required this.frameStart,
    required this.frameEnd,
    this.isFinal = false,
  });

  /// `Float32List` of `left_ctx + chunk_used + lookahead + right_pad`.
  final Float32List audio;

  /// CTC frame index (inclusive) where emission begins.
  final int frameStart;

  /// CTC frame index (exclusive) where emission ends.
  final int frameEnd;

  /// `true` only on the last window of a session (set by [flush]).
  final bool isFinal;
}

/// One [process]/[flush] call's outcome.
@immutable
class StreamingResult {
  /// Builds a streaming result.
  const StreamingResult({
    required this.text,
    required this.tokenIds,
    required this.isFinal,
    required this.fullText,
    required this.windowTimeS,
    this.muaalemOutputs = const <MuaalemOutput>[],
  });

  /// Newly committed text in this call. Empty if no commit happened.
  final String text;

  /// Newly committed token IDs in this call. Empty if no commit.
  final List<int> tokenIds;

  /// `true` for the final emission (from [flush]).
  final bool isFinal;

  /// Streamer's accumulated text across all commits in the session.
  final String fullText;

  /// Audio time covered by the windows that triggered commits in this
  /// call. Useful for refund computation when an emission is undone.
  final double windowTimeS;

  /// Raw model outputs for the windows that triggered commits — handy
  /// for sifat readout in the session.
  final List<MuaalemOutput> muaalemOutputs;
}

/// Per-milestone diagnostic info, passed to [AdaptiveStreamingMuaalem.onMilestone]
/// when set.
@immutable
class MilestoneInfo {
  /// Builds a milestone info record.
  const MilestoneInfo({
    required this.targetLen,
    required this.chunkLen,
    required this.text,
    required this.shouldCommit,
    required this.reason,
    required this.trailingRun,
    required this.lastFrame,
    required this.frameEnd,
    required this.expansionCount,
  });

  /// Window's chunk-used sample count at this milestone.
  final int targetLen;

  /// Total samples in the buffer at this milestone.
  final int chunkLen;

  /// Decoded text at this milestone.
  final String text;

  /// Whether the streamer committed at this milestone.
  final bool shouldCommit;

  /// Commit/expand reason (see [AdaptiveStreamingMuaalem._shouldCommit]).
  final String reason;

  /// Trailing identical-token run length in the decoded ids.
  final int trailingRun;

  /// Last decoded peak frame (-1 if no tokens decoded).
  final int lastFrame;

  /// Window's `frame_end`.
  final int frameEnd;

  /// Expansion counter at this milestone (0-based).
  final int expansionCount;
}

// ─────────────────────────────────────────────────────────────────────────
//  AdaptiveConfig
// ─────────────────────────────────────────────────────────────────────────

/// Configuration for [AdaptiveStreamingMuaalem]. All fields are read at
/// the point of use — mutate freely between [AdaptiveStreamingMuaalem.process]
/// calls to widen the decode budget when a Madd is anticipated.
class AdaptiveConfig {
  /// Builds an adaptive config. All fields have empirically-chosen
  /// defaults; see field-level docs for tuning notes.
  AdaptiveConfig({
    this.baseChunkS = 1.5,
    this.expansionS = 0.5,
    this.maxExpansions = 3,
    this.rightPadS = 0.05,
    this.rightLookaheadS = 0.5,
    this.leftContextS = 1.0,
    this.edgeFrames = 3,
    this.minTrailingRunToExpand = 2,
    this.seamOverlapFrames = 10,
    this.seamMatchWindow = 6,
    this.samplingRate = 16000,
  });

  /// Initial chunk size at the first decode milestone (seconds).
  double baseChunkS;

  /// Amount of audio added on each expansion (seconds).
  double expansionS;

  /// Hard cap on expansions per commit (bounds latency).
  int maxExpansions;

  /// Small zero-pad appended to the window's right edge to soften the
  /// convolutional encoder's boundary. Pad frames are NOT in the
  /// emission range. 0.05 s is the sweet spot: long enough to keep
  /// edge frames clean, short enough not to cue "end of speech".
  double rightPadS;

  /// Real (non-padded) future audio appended as encoder-only right
  /// context. 0.5 s is the empirical sweet spot for Quran (pronunciation
  /// errors are dominated by Madd boundary phonemes, so lookahead is
  /// consistently accuracy-positive). Set to 0 to disable.
  double rightLookaheadS;

  /// Committed audio kept as left context for subsequent windows. 1.0 s
  /// gives seam recovery enough settled history before the overlap
  /// region. Going below 0.75 s causes seam recovery to misfire.
  double leftContextS;

  /// CTC frames at the right edge that count as the "boundary risk
  /// zone". If the last peak lands in this zone, expand.
  int edgeFrames;

  /// If the decoded sequence ends in a run of this many or more
  /// identical tokens, expand even if the last peak isn't near the
  /// edge. Catches in-progress elongations whose peaks settled inside
  /// the chunk (because trailing right-pad silence cued "end of
  /// speech"). Set to 0 to disable.
  int minTrailingRunToExpand;

  /// After each chunk decode, re-decode the last N CTC frames of the
  /// left_ctx region to recover phonemes whose peaks land just before
  /// `frameStart`. 10 frames (~400 ms) covers the common case. Going
  /// much wider risks duplicating already-emitted tokens.
  int seamOverlapFrames;

  /// Trailing previously-emitted tokens to consider for the
  /// suffix-prefix overlap match. Conservative default (6) avoids
  /// spurious matches.
  int seamMatchWindow;

  /// Audio sample rate. Fixed at 16 kHz for the Muaalem model.
  int samplingRate;

  /// Base chunk size in samples.
  int get baseChunkSamples => (baseChunkS * samplingRate).toInt();

  /// Expansion step size in samples.
  int get expansionSamples => (expansionS * samplingRate).toInt();

  /// Right pad in samples.
  int get rightPadSamples => (rightPadS * samplingRate).toInt();

  /// Lookahead in samples.
  int get rightLookaheadSamples =>
      (rightLookaheadS * samplingRate).toInt();

  /// Left context in samples.
  int get leftSamples => (leftContextS * samplingRate).toInt();

  /// Upper bound on the chunk size including all expansions (samples).
  int get maxChunkSamples =>
      baseChunkSamples + maxExpansions * expansionSamples;

  /// Worst-case end-to-end latency in seconds.
  double get worstCaseLatencyS =>
      baseChunkS + maxExpansions * expansionS + rightLookaheadS;
}

// ─────────────────────────────────────────────────────────────────────────
//  AdaptiveChunkBuffer
// ─────────────────────────────────────────────────────────────────────────

/// Audio buffer with partial-commit semantics for adaptive windowing.
///
/// State
/// ─────
///   - `leftCtx`: last `cfg.leftSamples` of committed audio (history).
///   - `chunk`: uncommitted audio accumulated since the last commit.
///   - `hasRealLeftCtx`: false until the first commit; gates
///     left-padding (first window omits the all-zero left context to
///     avoid encoder hallucinations from silence).
class AdaptiveChunkBuffer {
  /// Builds a buffer using the given config.
  AdaptiveChunkBuffer(this.cfg);

  /// Reference to the streamer's config (mutable).
  final AdaptiveConfig cfg;

  /// Committed-audio history retained as encoder left context.
  List<double> leftCtx = <double>[];

  /// Uncommitted audio since the last commit.
  List<double> chunk = <double>[];

  /// `false` before the first commit; gates left-padding in windows.
  bool hasRealLeftCtx = false;

  /// Appends new audio to the chunk.
  void push(Float32List audio) {
    chunk.addAll(audio);
  }

  /// Current uncommitted sample count.
  int chunkSamples() => chunk.length;

  /// Builds a [Window] using the first [chunkUseSamples] of the chunk.
  ///
  /// Window layout: `[leftCtx?] + chunk[..chunkUseSamples] + [lookahead]
  /// + [rightPad zeros]`. Returns `null` if the chunk is empty or the
  /// requested size is non-positive.
  Window? buildWindow({
    required int chunkUseSamples,
    int lookaheadSamples = 0,
  }) {
    if (chunkUseSamples <= 0 || chunk.isEmpty) return null;

    final n = math.min(chunkUseSamples, chunk.length);
    final chunkUsed = chunk.sublist(0, n);

    // Real future audio as encoder-only right context.
    var lookahead = const <double>[];
    if (lookaheadSamples > 0 && chunk.length > n) {
      final lookaheadEnd = math.min(chunk.length, n + lookaheadSamples);
      lookahead = chunk.sublist(n, lookaheadEnd);
    }

    final rightPad = List<double>.filled(cfg.rightPadSamples, 0.0);

    final int frameStart;
    final int frameEnd;
    final List<double> windowAudio;

    if (hasRealLeftCtx && leftCtx.isNotEmpty) {
      windowAudio = <double>[...leftCtx, ...chunkUsed, ...lookahead, ...rightPad];
      frameStart = samplesToCtcFrames(leftCtx.length);
      frameEnd = samplesToCtcFrames(leftCtx.length + chunkUsed.length);
    } else {
      windowAudio = <double>[...chunkUsed, ...lookahead, ...rightPad];
      frameStart = 0;
      frameEnd = samplesToCtcFrames(chunkUsed.length);
    }

    // Defensive: ensure at least one frame in the emission range.
    final clampedEnd = math.max(frameEnd, frameStart + 1);

    return Window(
      audio: Float32List.fromList(windowAudio),
      frameStart: frameStart,
      frameEnd: clampedEnd,
    );
  }

  /// Commits the first [n] samples of the chunk:
  ///   - Append to `leftCtx` (keep only the last `cfg.leftSamples`).
  ///   - Remove from `chunk`.
  void commitFirstN(int n) {
    if (n <= 0 || chunk.isEmpty) return;
    final take = math.min(n, chunk.length);
    final committed = chunk.sublist(0, take);

    final List<double> combined;
    if (hasRealLeftCtx) {
      combined = <double>[...leftCtx, ...committed];
    } else {
      combined = List<double>.from(committed);
      hasRealLeftCtx = true;
    }

    if (cfg.leftSamples > 0) {
      leftCtx = combined.length > cfg.leftSamples
          ? combined.sublist(combined.length - cfg.leftSamples)
          : combined;
    } else {
      leftCtx = <double>[];
    }
    chunk = chunk.sublist(take);
  }

  /// Clears all buffered audio and history.
  void reset() {
    leftCtx = <double>[];
    chunk = <double>[];
    hasRealLeftCtx = false;
  }
}

// ─────────────────────────────────────────────────────────────────────────
//  AdaptiveStreamingMuaalem
// ─────────────────────────────────────────────────────────────────────────

/// Streaming wrapper with adaptive chunk expansion.
///
/// Usage
/// ─────
/// ```dart
/// final streamer = AdaptiveStreamingMuaalem(model: model, cfg: AdaptiveConfig());
/// streamer.reset();
/// for (final chunk in micStream) {
///   final result = streamer.process(chunk);
///   if (result.text.isNotEmpty) print(result.text);
/// }
/// final tail = streamer.flush();
/// ```
class AdaptiveStreamingMuaalem {
  /// Builds the streamer. Call [reset] before [process].
  AdaptiveStreamingMuaalem({required this.model, required this.cfg});

  /// The model used for inference.
  final RecitationModel model;

  /// Mutable config — fields can be changed between [process] calls.
  final AdaptiveConfig cfg;

  /// Optional milestone callback for diagnostics. Set this to log
  /// per-milestone commit/expand decisions.
  void Function(MilestoneInfo)? onMilestone;

  /// Whether the streamer's most recent decode triggered the
  /// trailing-identical-tokens heuristic (H2). Read by the session as
  /// an "is the user currently sustaining a Madd?" signal.
  bool isElongating = false;

  AdaptiveChunkBuffer? _buffer;
  final List<int> _accumulatedIds = <int>[];

  List<int> _tentativeIds = <int>[];
  List<int> _tentativeFrames = <int>[];
  String _tentativeText = '';

  int _expansionCount = 0;

  // Lifetime expansion-reason counters (reset only in reset()).
  int nH1OnlyExpansions = 0;
  int nH2OnlyExpansions = 0;
  int nH1H2BothExpansions = 0;
  int nForceCommitted = 0;

  // Tail of recently emitted tokens for seam recovery alignment.
  List<int> _lastEmittedIds = <int>[];

  /// Streamer's accumulated text across all commits.
  String get fullText {
    final buf = StringBuffer();
    for (final id in _accumulatedIds) {
      buf.write(model.vocabLookup('phonemes', id));
    }
    return buf.toString();
  }

  /// `fullText` plus any tentative (uncommitted) text — useful for
  /// eager UI feedback.
  String get tentativeText => fullText + _tentativeText;

  /// Worst-case latency in seconds (sum of base, all expansions, and
  /// lookahead).
  double get latencyS => cfg.worstCaseLatencyS;

  /// Resets all state. Call before the first [process].
  void reset() {
    _buffer = AdaptiveChunkBuffer(cfg);
    _accumulatedIds.clear();
    _tentativeIds = <int>[];
    _tentativeFrames = <int>[];
    _tentativeText = '';
    _expansionCount = 0;
    nH1OnlyExpansions = 0;
    nH2OnlyExpansions = 0;
    nH1H2BothExpansions = 0;
    nForceCommitted = 0;
    _lastEmittedIds = <int>[];
    isElongating = false;
  }

  /// Feeds a chunk of mono float32 audio in [-1, 1]. Returns
  /// any newly committed tokens / text.
  StreamingResult process(Float32List audio) {
    final buffer = _buffer;
    if (buffer == null) {
      throw StateError('Call reset() before process()');
    }
    buffer.push(audio);
    return _maybeDecodeLoop();
  }

  /// Final emission: decodes whatever's left in the chunk and commits.
  StreamingResult flush() {
    final buffer = _buffer;
    if (buffer == null) {
      throw StateError('Call reset() before flush()');
    }

    if (buffer.chunkSamples() == 0) {
      return StreamingResult(
        text: '',
        tokenIds: const <int>[],
        isFinal: true,
        fullText: fullText,
        windowTimeS: 0.0,
      );
    }

    final win = buffer.buildWindow(
      chunkUseSamples: buffer.chunkSamples(),
    );
    if (win == null) {
      return StreamingResult(
        text: '',
        tokenIds: const <int>[],
        isFinal: true,
        fullText: fullText,
        windowTimeS: 0.0,
      );
    }
    final finalWin = Window(
      audio: win.audio,
      frameStart: win.frameStart,
      frameEnd: win.frameEnd,
      isFinal: true,
    );
    final (out, ids, text) = _runInference(finalWin);

    final seamIds = _recoverSeamTokens(finalWin);
    final seamText = _idsToText(seamIds);

    buffer.commitFirstN(buffer.chunkSamples());
    _expansionCount = 0;
    _tentativeIds = <int>[];
    _tentativeFrames = <int>[];
    _tentativeText = '';

    final fullIds = <int>[...seamIds, ...ids];
    final fullTextChunk = seamText + text;
    _accumulatedIds.addAll(fullIds);
    _lastEmittedIds = _trimTail(
      <int>[..._lastEmittedIds, ...fullIds],
      math.max(cfg.seamMatchWindow, 1),
    );

    return StreamingResult(
      text: fullTextChunk,
      tokenIds: fullIds,
      isFinal: true,
      fullText: fullText,
      windowTimeS: finalWin.audio.length / cfg.samplingRate,
      muaalemOutputs: <MuaalemOutput>[out],
    );
  }

  /// Computes how much audio time (seconds) the first [chars]
  /// characters of [tentativeText] account for, measured within the
  /// current chunk.
  ///
  /// Used by the session to "refund" audio when a tentative emission
  /// is undone (e.g. the phrase classifier decided the just-tentative
  /// phonemes were actually noise).
  double getTentativeTimeConsumed(int chars) {
    if (chars <= 0 || _tentativeIds.isEmpty || _tentativeFrames.isEmpty) {
      return 0.0;
    }
    var charCount = 0;
    var lastFrame = -1;
    for (var idx = 0; idx < _tentativeIds.length; idx++) {
      final tokenStr = model.vocabLookup('phonemes', _tentativeIds[idx]);
      charCount += tokenStr.length;
      if (idx < _tentativeFrames.length) {
        lastFrame = _tentativeFrames[idx];
      }
      if (charCount >= chars) break;
    }
    if (lastFrame < 0) return 0.0;

    final buffer = _buffer;
    final chunkStartFrame =
        (buffer != null && buffer.hasRealLeftCtx)
            ? samplesToCtcFrames(buffer.leftCtx.length)
            : 0;
    final framesInChunk = math.max(0, lastFrame - chunkStartFrame);
    return framesInChunk * 0.04; // each 1s = 25 CTC Frame -> CTC Frame = 40ms
  }

  // ── Internals ────────────────────────────────────────────────────────

  StreamingResult _maybeDecodeLoop() {
    final emittedOutputs = <MuaalemOutput>[];
    final emittedIds = <int>[];
    var emittedText = '';
    var coveredS = 0.0;

    final buffer = _buffer!;

    while (true) {
      final chunkLen = buffer.chunkSamples();
      var targetLen =
          cfg.baseChunkSamples + _expansionCount * cfg.expansionSamples;
      if (targetLen > cfg.maxChunkSamples) targetLen = cfg.maxChunkSamples;

      // Frame-tiling tripwire: a milestone commit of a chunk whose length is
      // not a multiple of the CTC frame stride silently drops or duplicates a
      // boundary frame (see [ctcFrameStrideSamples]). baseChunkSamples and
      // expansionSamples must be chosen so this holds (e.g. baseChunkS=0.75 →
      // 12000 would FAIL). The flush path is exempt — it's the final commit.
      assert(
        targetLen % ctcFrameStrideSamples == 0,
        'targetLen ($targetLen) must be a multiple of the CTC frame stride '
        '($ctcFrameStrideSamples): baseChunkSamples=${cfg.baseChunkSamples}, '
        'expansionSamples=${cfg.expansionSamples}. A non-aligned chunk drops '
        'a frame at every commit seam.',
      );

      // We need the chunk's audio AND the requested lookahead audio
      // before we can run a deterministic decode at this milestone.
      final neededLen = targetLen + cfg.rightLookaheadSamples;
      if (chunkLen < neededLen) break;

      final win = buffer.buildWindow(
        chunkUseSamples: targetLen,
        lookaheadSamples: cfg.rightLookaheadSamples,
      );
      if (win == null) break;

      final (out, ids, text) = _runInference(win);
      final frames = out.phonemes.frames;

      _tentativeIds = List<int>.from(ids);
      _tentativeFrames = List<int>.from(frames);
      _tentativeText = text;

      final (shouldCommit, reason) = _shouldCommit(
        ids: ids,
        frames: frames,
        win: win,
        usedSamples: targetLen,
      );

      final cb = onMilestone;
      if (cb != null) {
        cb(MilestoneInfo(
          targetLen: targetLen,
          chunkLen: chunkLen,
          text: text,
          shouldCommit: shouldCommit,
          reason: reason,
          trailingRun: _trailingRunLength(ids),
          lastFrame: frames.isEmpty ? -1 : frames.last,
          frameEnd: win.frameEnd,
          expansionCount: _expansionCount,
        ),);
      }

      if (shouldCommit) {
        if (reason == 'max-expansions' || reason == 'max-chunk') {
          nForceCommitted += 1;
        }

        final seamIds = _recoverSeamTokens(win);
        final seamText = _idsToText(seamIds);

        buffer.commitFirstN(targetLen);
        _expansionCount = 0;
        _tentativeIds = <int>[];
        _tentativeFrames = <int>[];
        _tentativeText = '';

        final fullIds = <int>[...seamIds, ...ids];
        final fullTextChunk = seamText + text;
        _accumulatedIds.addAll(fullIds);
        _lastEmittedIds = _trimTail(
          <int>[..._lastEmittedIds, ...fullIds],
          math.max(cfg.seamMatchWindow, 1),
        );

        if (kStreamerSeamDebug) {
          // Leading main-decode tokens with peak frame RELATIVE to frameStart:
          // `@0`/`@1` ⇒ the peak sits at the unstable left edge of the emission
          // range (prone to drop/flicker); the seam re-decode is the only thing
          // that can recover a token whose peak fell just before frameStart.
          final lead = <String>[];
          for (var i = 0; i < ids.length && i < 5; i++) {
            final f = i < frames.length ? frames[i] : -1;
            lead.add('${model.vocabLookup('phonemes', ids[i])}@'
                '${f < 0 ? '?' : f - win.frameStart}');
          }
          // ignore: avoid_print
          print('[seam] COMMIT reason=$reason fs=${win.frameStart} '
              'fe=${win.frameEnd} lead=[${lead.join(' ')}] '
              'seam="$seamText" main="$text" committed="$fullTextChunk"');
        }

        emittedOutputs.add(out);
        emittedIds.addAll(fullIds);
        emittedText += fullTextChunk;
        coveredS += win.audio.length / cfg.samplingRate;
        // loop continues — more audio may already be buffered
      } else {
        if (reason == 'h1') {
          nH1OnlyExpansions += 1;
        } else if (reason == 'h2') {
          nH2OnlyExpansions += 1;
        } else if (reason == 'h1+h2') {
          nH1H2BothExpansions += 1;
        }
        _expansionCount += 1;
        // loop continues — next iteration uses a larger target_len
      }
    }

    return StreamingResult(
      text: emittedText,
      tokenIds: emittedIds,
      isFinal: false,
      fullText: fullText,
      windowTimeS: coveredS,
      muaalemOutputs: emittedOutputs,
    );
  }

  List<int> _recoverSeamTokens(Window win) {
    if (cfg.seamOverlapFrames <= 0) return const <int>[];
    if (win.frameStart <= 0) return const <int>[];
    if (_lastEmittedIds.isEmpty) return const <int>[];

    final ovStart = math.max(0, win.frameStart - cfg.seamOverlapFrames);
    final ovEnd = win.frameStart;
    if (ovEnd <= ovStart) return const <int>[];

    final reDecoded = model.decodeFromLastLogits(
      frameStart: ovStart,
      frameEnd: ovEnd,
    );
    if (reDecoded == null || reDecoded.ids.isEmpty) {
      if (kStreamerSeamDebug) {
        // ignore: avoid_print
        print('[seam] ov=[$ovStart,$ovEnd) '
            'prevTail="${_idsToText(_lastEmittedIds)}" '
            'overlap=<none> recovered=<none>');
      }
      return const <int>[];
    }

    final recovered = _suffixPrefixRecover(
      prevTail: _lastEmittedIds,
      overlapTokens: reDecoded.ids,
      matchWindow: cfg.seamMatchWindow,
    );
    if (kStreamerSeamDebug) {
      // ignore: avoid_print
      print('[seam] ov=[$ovStart,$ovEnd) '
          'prevTail="${_idsToText(_lastEmittedIds)}" '
          'overlap="${_idsToText(reDecoded.ids)}" '
          'recovered="${_idsToText(recovered)}"');
    }
    return recovered;
  }

  /// Finds the longest `k` such that `prevTail[-k:] == overlapTokens[:k]`,
  /// bounded by `matchWindow` and the shorter of the two lists. Returns
  /// `overlapTokens[k:]` — the "newly recovered" tokens beyond the
  /// match. Returns empty if no positive-length match exists.
  static List<int> _suffixPrefixRecover({
    required List<int> prevTail,
    required List<int> overlapTokens,
    required int matchWindow,
  }) {
    if (prevTail.isEmpty || overlapTokens.isEmpty) {
      return const <int>[];
    }
    final maxBack = <int>[
      prevTail.length,
      matchWindow,
      overlapTokens.length,
    ].reduce(math.min);
    for (var k = maxBack; k >= 1; k--) {
      final prevSuffix = prevTail.sublist(prevTail.length - k);
      final overlapPrefix = overlapTokens.sublist(0, k);
      if (_listEquals(prevSuffix, overlapPrefix)) {
        return overlapTokens.sublist(k);
      }
    }
    return const <int>[];
  }

  (MuaalemOutput, List<int>, String) _runInference(Window win) {
    final out = model.run(
      audio: win.audio,
      frameStart: win.frameStart,
      frameEnd: win.frameEnd,
    );
    final ids = List<int>.from(out.phonemes.ids);
    final text = _idsToText(ids);
    return (out, ids, text);
  }

  String _idsToText(List<int> ids) {
    final buf = StringBuffer();
    for (final id in ids) {
      buf.write(model.vocabLookup('phonemes', id));
    }
    return buf.toString();
  }

  /// Returns `(shouldCommit, reason)` for the just-decoded window.
  (bool, String) _shouldCommit({
    required List<int> ids,
    required List<int> frames,
    required Window win,
    required int usedSamples,
  }) {
    // H2 computed up-front and published via isElongating — so the
    // session can read it as a signal even on iterations where we hit
    // a safety cap. The caps still always apply; isElongating is
    // informational, never a bypass.
    var h2 = false;
    if (cfg.minTrailingRunToExpand > 0) {
      final trailingRun = _trailingRunLength(ids);
      if (trailingRun >= cfg.minTrailingRunToExpand) {
        h2 = true;
      }
    }
    isElongating = h2;

    // Hard safety caps — always honored.
    if (_expansionCount >= cfg.maxExpansions) return (true, 'max-expansions');
    if (usedSamples >= cfg.maxChunkSamples) return (true, 'max-chunk');
    if (ids.isEmpty) return (true, 'no-tokens');

    // H1: peak frame near right edge.
    var h1 = false;
    if (frames.isNotEmpty) {
      final lastFrame = frames.last;
      final edgeThreshold = win.frameEnd - cfg.edgeFrames;
      if (lastFrame >= edgeThreshold) h1 = true;
    }

    if (h1 && h2) return (false, 'h1+h2');
    if (h1) return (false, 'h1');
    if (h2) return (false, 'h2');
    return (true, 'safely-inside');
  }

  static int _trailingRunLength(List<int> ids) {
    if (ids.isEmpty) return 0;
    final last = ids.last;
    var n = 1;
    for (var i = ids.length - 2; i >= 0; i--) {
      if (ids[i] == last) {
        n += 1;
      } else {
        break;
      }
    }
    return n;
  }

  static List<int> _trimTail(List<int> source, int keep) {
    if (source.length <= keep) return List<int>.from(source);
    return source.sublist(source.length - keep);
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ─────────────────────────────────────────────────────────────────────────
//  Utility: latency-targeted config builder
// ─────────────────────────────────────────────────────────────────────────

/// Builds an [AdaptiveConfig] whose worst-case latency equals
/// [targetLatencyS] (excluding lookahead).
///
/// Solves `base + maxExpansions * (base/3) == target` with `expansion =
/// base / 3` (each step adds ~1/3 of base).
AdaptiveConfig pickAdaptiveConfigForLatency({
  required double targetLatencyS,
  int maxExpansions = 3,
}) {
  if (targetLatencyS < 0.5) {
    throw ArgumentError('targetLatencyS must be >= 0.5 s for adaptive mode');
  }
  if (maxExpansions < 0) {
    throw ArgumentError('maxExpansions must be >= 0');
  }
  final baseChunkS = targetLatencyS / (1.0 + maxExpansions / 3.0);
  final expansionS = baseChunkS / 3.0;
  return AdaptiveConfig(
    baseChunkS: baseChunkS,
    expansionS: expansionS,
    maxExpansions: maxExpansions,
  );
}
