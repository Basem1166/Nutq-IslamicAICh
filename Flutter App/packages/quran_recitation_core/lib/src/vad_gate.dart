/// Voice-activity-detection gate.
///
/// Why an explicit gate exists
/// ───────────────────────────
///   - **Don't burn compute on silence.** The CTC model decodes whatever
///     audio we hand it. Piping silence through produces garbage tokens
///     and burns GPU time we don't get back. A frame-level gate prevents
///     this cheaply.
///   - **Phrase boundaries are the decision point for the classifier.**
///     The three-hypothesis classifier (continuation / repetition /
///     next-ayah) runs on "what the user just said since the last
///     silence." Without a VAD, we have no natural way to delimit these
///     phrases — the streamer's commits are shaped by acoustic context,
///     not by the user's intent.
///
/// Backend abstraction
/// ───────────────────
/// [VadGate] uses a [VadBackend] for the actual P(speech) prediction.
/// The core package only ships a [MockVadBackend] for testing — the
/// Silero ONNX backend lives in the Flutter app where `onnxruntime` is
/// already available (same pattern as the phonetizer adapter).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Silero VAD's fixed window size at 16 kHz (32 ms).
const int sileroWindow16k = 512;

/// Silero VAD's fixed window size at 8 kHz (32 ms).
const int sileroWindow8k = 256;

/// Transition type emitted by [VadGate].
enum VadEventType {
  /// Speech onset confirmed (continuous speech ≥ minSpeechMs).
  speechStart,

  /// Continuous silence ≥ minSilenceMs after speech — the natural
  /// place to run the phrase classifier.
  phraseBoundary;

  /// JSON value (snake_case, matches Python literal).
  String get jsonValue => switch (this) {
        VadEventType.speechStart => 'speech_start',
        VadEventType.phraseBoundary => 'phrase_boundary',
      };
}

/// One transition detected by [VadGate].
///
/// [audioOffsetSamples] is the sample index within the chunk passed to
/// [VadGate.process] where the transition occurred. Useful if the caller
/// wants to slice the chunk into pre- and post-transition halves before
/// forwarding to the streamer.
@immutable
class VadEvent {
  /// Constructs a VAD event.
  const VadEvent({
    required this.type,
    required this.audioOffsetSamples,
    required this.timestampSeconds,
    required this.speechProbability,
  });

  /// What transition fired.
  final VadEventType type;

  /// Sample index within the current [VadGate.process] chunk.
  final int audioOffsetSamples;

  /// Session-relative seconds when the transition fired.
  final double timestampSeconds;

  /// VAD probability at the transitioning window. ∈ [0, 1].
  final double speechProbability;

  @override
  String toString() =>
      'VadEvent(${type.jsonValue}, offset=$audioOffsetSamples, '
      't=${timestampSeconds.toStringAsFixed(3)}s, p=$speechProbability)';
}

/// Backend that scores 32 ms windows for P(speech).
///
/// Implementations
/// ───────────────
///   - [MockVadBackend] — amplitude-thresholded; for tests.
///   - A user-supplied Silero-ONNX implementation in the Flutter app.
///
/// The backend owns any internal state (e.g. Silero's LSTM hidden
/// state). [reset] clears it.
abstract class VadBackend {
  /// Audio sample rate the backend expects.
  int get sampleRate;

  /// Number of samples per probability call.
  int get windowSize;

  /// Returns P(speech) ∈ [0, 1] for one window of [windowSize] float32
  /// samples in [-1, 1].
  double probability(Float32List window);

  /// Clears any internal state across windows.
  void reset();
}

/// Trivial amplitude-thresholded backend useful for tests and bring-up.
///
/// Returns `1.0` if mean absolute amplitude exceeds [threshold], else
/// `0.0`. No state; [reset] is a no-op.
class MockVadBackend implements VadBackend {
  /// Builds a mock backend.
  MockVadBackend({this.sampleRate = 16000, this.threshold = 0.05})
      : windowSize =
            sampleRate == 16000 ? sileroWindow16k : sileroWindow8k;

  @override
  final int sampleRate;

  @override
  final int windowSize;

  /// Mean-absolute-value threshold above which a window is "speech".
  final double threshold;

  @override
  double probability(Float32List window) {
    var sum = 0.0;
    for (final s in window) {
      sum += s < 0 ? -s : s;
    }
    final mean = sum / window.length;
    return mean > threshold ? 1.0 : 0.0;
  }

  @override
  void reset() {}
}

/// Stateful voice-activity gate that yields transition events.
///
/// Tunable parameters
/// ──────────────────
///   - [threshold]: P(speech) above this counts as speech. 0.5 is a
///     safe default for Silero.
///   - [minSilenceMs]: continuous silence of at least this duration
///     emits a `phraseBoundary` event. 500 ms is a typical between-word
///     or between-ayah pause.
///   - [minSpeechMs]: require this much speech before declaring
///     `speechStart`. Suppresses lip-smacks / coughs.
///   - [preSpeechPadMs]: when speech-start fires, the caller can use
///     [recentAudio] to grab a bit of audio from *before* the trigger
///     (avoids clipping the first phoneme).
///   - [energySpeechFloor]: RMS floor that overrides the backend's
///     "this is silence" verdict when we're inside an utterance and
///     audio is still loud. Rescues sustained Madd vowels that Silero
///     misclassifies. 0.01 sits well clear of digital silence (< 0.001)
///     and below typical speech RMS (0.2–0.4). Set to 0 to disable.
class VadGate {
  /// Builds a VAD gate. The [backend] is owned by the gate — call
  /// [reset] to clear it between sessions.
  VadGate({
    required this.backend,
    this.threshold = 0.5,
    int minSilenceMs = 500,
    int minSpeechMs = 100,
    int preSpeechPadMs = 300,
    this.energySpeechFloor = 0.01,
  })  : sampleRate = backend.sampleRate,
        windowSize = backend.windowSize,
        minSilenceSamples = minSilenceMs * backend.sampleRate ~/ 1000,
        minSpeechSamples = minSpeechMs * backend.sampleRate ~/ 1000,
        preSpeechPadSamples = preSpeechPadMs * backend.sampleRate ~/ 1000 {
    _recentMaxSamples = math.max(preSpeechPadSamples, windowSize * 4);
    _recent = Float32List(0);
    _leftover = Float32List(0);
  }

  /// Underlying backend.
  final VadBackend backend;

  /// `P(speech) ≥` threshold counts as speech.
  final double threshold;

  /// RMS override floor (see [VadGate] doc).
  final double energySpeechFloor;

  /// Audio sample rate (mirrored from [backend]).
  final int sampleRate;

  /// Window size in samples (mirrored from [backend]).
  final int windowSize;

  /// Continuous silence at or above this triggers a phrase boundary.
  /// Mutable: the session's Madd-anticipation logic stretches it while a
  /// long elongation is expected, then restores the baseline.
  int minSilenceSamples;

  /// Continuous speech at or above this triggers speech_start.
  final int minSpeechSamples;

  /// Pre-roll length [recentAudio] can return.
  final int preSpeechPadSamples;

  late final int _recentMaxSamples;

  /// Whether the gate currently believes we're inside an utterance.
  bool isSpeech = false;

  /// VAD probability at the most recently processed window.
  double lastProb = 0.0;

  Float32List _recent = Float32List(0);
  Float32List _leftover = Float32List(0);
  int _silenceRunSamples = 0;
  int _speechRunSamples = 0;
  int _absoluteSample = 0;
  // Start in silence — no boundary to emit until speech has happened.
  bool _phraseBoundaryEmitted = true;

  /// Clears all internal state including the backend's.
  void reset() {
    _recent = Float32List(0);
    _leftover = Float32List(0);
    isSpeech = false;
    _silenceRunSamples = 0;
    _speechRunSamples = 0;
    _absoluteSample = 0;
    lastProb = 0.0;
    _phraseBoundaryEmitted = true;
    backend.reset();
  }

  /// Feeds a chunk of mono float32 audio in [-1, 1] and returns any
  /// transition events that fired within the chunk.
  ///
  /// Audio shorter than a window is buffered internally and processed
  /// on the next call. Audio longer than a window is split into
  /// non-overlapping windows; the remainder is buffered.
  List<VadEvent> process(Float32List audioChunk) {
    // Update the recent ring.
    _recent = _concat(_recent, audioChunk);
    if (_recent.length > _recentMaxSamples) {
      _recent = Float32List.sublistView(
        _recent,
        _recent.length - _recentMaxSamples,
      );
      // sublistView shares the underlying buffer; copy so subsequent
      // grows don't disturb the original.
      _recent = Float32List.fromList(_recent);
    }

    // Concatenate leftover + new audio, segment into windows.
    final buf = _concat(_leftover, audioChunk);
    final nWindows = buf.length ~/ windowSize;
    final events = <VadEvent>[];

    for (var i = 0; i < nWindows; i++) {
      final start = i * windowSize;
      final window = Float32List.sublistView(buf, start, start + windowSize);
      var prob = backend.probability(window);

      // Energy-floor override (see VadGate doc): if backend thinks this
      // window is silence but we're inside an utterance and the window
      // is still loud, treat it as speech. Rescues sustained Madd
      // vowels that Silero misclassifies.
      if (isSpeech && prob < threshold && energySpeechFloor > 0.0) {
        final rms = _rms(window);
        if (rms >= energySpeechFloor) {
          // Lift to "barely speech" — keeps the silence-run counter
          // reset; doesn't pretend to be a confident detection.
          prob = math.max(prob, threshold);
        }
      }

      lastProb = prob;

      // Where in audioChunk this window's END lies — for event offsets.
      var windowEndInChunk = (i + 1) * windowSize - _leftover.length;
      if (windowEndInChunk < 0) windowEndInChunk = 0;
      if (windowEndInChunk > audioChunk.length) {
        windowEndInChunk = audioChunk.length;
      }

      _updateState(prob, windowEndInChunk, events);
      _absoluteSample += windowSize;
    }

    // Keep the unprocessed tail for next call.
    final tailStart = nWindows * windowSize;
    if (tailStart >= buf.length) {
      _leftover = Float32List(0);
    } else {
      _leftover = Float32List.fromList(
        Float32List.sublistView(buf, tailStart),
      );
    }

    return events;
  }

  /// Returns the last [ms] of audio observed (capped at what's in the
  /// recent ring). Use this to pre-pad the streamer when
  /// `speechStart` fires so we don't lose the leading edge of the first
  /// word.
  Float32List recentAudio(int ms) {
    final n = ms * sampleRate ~/ 1000;
    final take = math.min(n, _recent.length);
    if (take <= 0) return Float32List(0);
    return Float32List.fromList(
      Float32List.sublistView(_recent, _recent.length - take),
    );
  }

  void _updateState(
    double prob,
    int offsetInChunk,
    List<VadEvent> events,
  ) {
    final isSpeechFrame = prob >= threshold;

    if (isSpeechFrame) {
      _speechRunSamples += windowSize;
      _silenceRunSamples = 0;

      if (!isSpeech && _speechRunSamples >= minSpeechSamples) {
        isSpeech = true;
        _phraseBoundaryEmitted = false;
        events.add(VadEvent(
          type: VadEventType.speechStart,
          audioOffsetSamples: offsetInChunk,
          timestampSeconds: _absoluteSample / sampleRate,
          speechProbability: prob,
        ),);
      }
    } else {
      _silenceRunSamples += windowSize;
      _speechRunSamples = 0;

      if (isSpeech && _silenceRunSamples >= minSilenceSamples) {
        isSpeech = false;
      }

      if (!isSpeech &&
          !_phraseBoundaryEmitted &&
          _silenceRunSamples >= minSilenceSamples) {
        _phraseBoundaryEmitted = true;
        events.add(VadEvent(
          type: VadEventType.phraseBoundary,
          audioOffsetSamples: offsetInChunk,
          timestampSeconds: _absoluteSample / sampleRate,
          speechProbability: prob,
        ),);
      }
    }
  }

  /// RMS of a window — `sqrt(mean(x^2))`.
  static double _rms(Float32List window) {
    var sumSq = 0.0;
    for (final s in window) {
      sumSq += s * s;
    }
    return math.sqrt(sumSq / window.length);
  }

  /// Float32List concatenation (the SDK doesn't ship a `+` for typed
  /// data). Allocates a new buffer; small enough for our chunk sizes.
  static Float32List _concat(Float32List a, Float32List b) {
    if (a.isEmpty) return Float32List.fromList(b);
    if (b.isEmpty) return Float32List.fromList(a);
    final out = Float32List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, a.length + b.length, b);
    return out;
  }
}
