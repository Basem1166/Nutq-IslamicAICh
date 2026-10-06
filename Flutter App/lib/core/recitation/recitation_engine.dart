import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:quran_recitation_core/quran_recitation_core.dart';

import '../phonetizer_service.dart';
import 'audio_recorder.dart';
import 'ctc_decoder.dart';
import 'feature_extractor.dart';
import 'grouped_recitation_scorer.dart';
import 'mualem_model.dart';
import 'recitation_model_adapter.dart';
import 'recitation_scorer.dart';
import 'silero_vad_backend.dart';

/// Load-once facade over the whole on-device recitation pipeline.
///
/// Owns the 35 MB ONNX model + vocab so they load a single time for the app's
/// lifetime (mirrors the app's `SavedBookmarksStore.instance` singleton style).
/// Call [ensureLoaded] when the recitation UI opens — never from `main()`,
/// which would block the first frame.
class RecitationEngine {
  RecitationEngine._();
  static final RecitationEngine instance = RecitationEngine._();

  final MualemModel _model = MualemModel();
  final MualemFeatureExtractor _extractor = MualemFeatureExtractor();
  CtcDecoder? _decoder;
  SileroVadBackend? _vadBackend;
  Future<void>? _loading;

  bool get isLoaded =>
      _model.isLoaded && _decoder != null && _vadBackend != null;

  /// Idempotent: loads the vocab + model + VAD once; concurrent callers share
  /// the same in-flight future.
  Future<void> ensureLoaded() {
    if (isLoaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      _decoder = await CtcDecoder.load();
      await _model.load();
      _vadBackend = await SileroVadBackend.load();
    } catch (e) {
      _loading = null; // allow a retry after a failed load
      rethrow;
    }
  }

  /// Builds a fresh [VadGate] over the load-once Silero backend for a new
  /// streaming session. Call [ensureLoaded] first. The session resets the gate
  /// (and thus the backend's LSTM state) on `startAyah`.
  VadGate buildVadGate() {
    final backend = _vadBackend;
    if (backend == null) {
      throw const RecitationException(
        'VAD not ready; call ensureLoaded() first.',
      );
    }
    // Disable the RMS energy-floor override. That floor (default 0.01) was a
    // crutch for the *old* broken Silero path, which collapsed P(speech) to
    // ~0.0005 for all audio — including sustained Madd vowels — so the gate
    // needed an energy backstop to avoid cutting elongations short. Now that
    // the 64-sample-context fix makes Silero score speech correctly (silence
    // ~0.001, speech ~0.99), the floor does the opposite harm: trailing
    // ambient noise (RMS 0.06–0.13) sits above 0.01, so it overrides Silero's
    // correct "silence" verdict, keeps the gate open, and the phrase boundary
    // never fires — the final word is never classified and post-word noise is
    // decoded as garbage. Let Silero govern; the session's reference-driven
    // Madd anticipation already stretches the silence window for expected
    // elongations.
    return VadGate(backend: backend, energySpeechFloor: 0.0);
  }

  /// Runs the full pipeline on a recorded WAV clip and scores it against the
  /// Phonetizer's expected output for the target verse.
  ///
  /// Throws [RecitationException] for user-actionable problems (clip too short,
  /// engine not ready).
  Future<RecitationAnalysis> analyze({
    required String wavPath,
    required PhonetizerResult expected,
    required List<String> verseWords,
  }) async {
    await ensureLoaded();
    final decoder = _decoder;
    if (decoder == null) {
      throw const RecitationException('Model not ready.');
    }

    final waveform = await AudioRecorderService.readWavAsFloat32(wavPath);
    final features = _extractor.extract(waveform);
    if (features.seqLen == 0) {
      throw const RecitationException(
        'Clip too short — record at least ~0.5 s.',
      );
    }

    final logits = _model.run(features);
    final phonemeLogits = logits['phonemes'] ?? const <List<double>>[];

    // Three CTC decode variants from the single inference. Each feeds BOTH
    // scorers, so the UI can A/B both the decode (greedy/beam/beam+ref) and the
    // scorer (legacy/grouped) with no re-recording / re-inference.
    final greedy = decoder.greedyDecodeResult(logits);
    final nbest = decoder.beamSearchNBest(phonemeLogits);
    final beam = nbest.isEmpty
        ? greedy
        : decoder.decodeResultFor(logits, nbest.first.tokenIds);
    final beamRescored = nbest.isEmpty
        ? greedy
        : decoder.decodeResultFor(
            logits, _rescoreToExpected(decoder, nbest, expected.phonemes));

    ScorerPair scoreBoth(PhonemeDecodeResult d) => ScorerPair(
          legacy: RecitationScorer.score(
              decoded: d, expected: expected, verseWords: verseWords),
          legacyFixed: RecitationScorer.score(
              decoded: d,
              expected: expected,
              verseWords: verseWords,
              chunkBasedSifat: true),
          grouped: GroupedRecitationScorer.score(
              decoded: d, expected: expected, verseWords: verseWords),
        );

    final analysis = RecitationAnalysis({
      DecodeMode.greedy: scoreBoth(greedy),
      DecodeMode.beam: scoreBoth(beam),
      DecodeMode.beamRescored: scoreBoth(beamRescored),
    });

    if (kDebugMode) {
      // Step-3 vocab-parity validation aid: eyeball expected vs predicted, and
      // how each decode mode changes the predicted string + accuracy.
      debugPrint('[recitation] expected : ${expected.phonemes}');
      for (final mode in DecodeMode.values) {
        final pair = analysis.forMode(mode);
        debugPrint('[recitation] ${mode.name}: "${pair.legacy.predictedPhonemes}" '
            'legacy=${pair.legacy.accuracy.toStringAsFixed(3)} '
            'legacy+=${pair.legacyFixed.accuracy.toStringAsFixed(3)} '
            'grouped=${pair.grouped.accuracy.toStringAsFixed(3)}');
      }
    }
    return analysis;
  }

  /// Reranks the beam [nbest] by edit distance to the expected phonemes and
  /// returns the closest hypothesis' token ids. This recovers near-miss phonemes
  /// argmax dropped without forcing the expected sequence — a hypothesis the
  /// acoustic model never proposed can't win, so real errors still surface.
  static List<int> _rescoreToExpected(
    CtcDecoder decoder,
    List<BeamHypothesis> nbest,
    String expectedPhonemes,
  ) {
    final ref = expectedPhonemes.replaceAll(RegExp(r'\s+'), '');
    var bestIds = nbest.first.tokenIds;
    var bestDist = 1 << 30;
    for (final h in nbest) {
      final cand =
          h.tokenIds.map((id) => decoder.tokenFor('phonemes', id) ?? '').join();
      final d = _editDistance(cand, ref);
      if (d < bestDist) {
        bestDist = d;
        bestIds = h.tokenIds;
      }
    }
    return bestIds;
  }

  /// Levenshtein distance over Unicode code points.
  static int _editDistance(String a, String b) {
    final ra = a.runes.toList(growable: false);
    final rb = b.runes.toList(growable: false);
    final m = ra.length;
    final n = rb.length;
    if (m == 0) return n;
    if (n == 0) return m;
    var prev = List<int>.generate(n + 1, (j) => j);
    var curr = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      curr[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = ra[i - 1] == rb[j - 1] ? 0 : 1;
        curr[j] = math.min(
            prev[j - 1] + cost, math.min(prev[j] + 1, curr[j - 1] + 1));
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[n];
  }

  /// Builds a [RecitationModelAdapter] over the loaded model/decoder/extractor
  /// for the live streaming path. Call [ensureLoaded] first.
  RecitationModelAdapter buildStreamingModel() {
    final decoder = _decoder;
    if (!_model.isLoaded || decoder == null) {
      throw const RecitationException(
        'Model not ready; call ensureLoaded() first.',
      );
    }
    return RecitationModelAdapter(
      model: _model,
      decoder: decoder,
      extractor: _extractor,
    );
  }

  /// Frees the ONNX sessions. The singleton can be reloaded via [ensureLoaded].
  void dispose() {
    _model.dispose();
    _vadBackend?.dispose();
    _vadBackend = null;
    _decoder = null;
    _loading = null;
  }
}

/// The legacy + grouped scorings for a single decode mode.
class ScorerPair {
  const ScorerPair({
    required this.legacy,
    required this.legacyFixed,
    required this.grouped,
  });

  /// The original two-alignment [RecitationScorer] result.
  final RecitationScore legacy;

  /// The two-alignment [RecitationScorer] with chunk-based sifat handling
  /// (`chunkBasedSifat: true`) — attributes sifat diffs to the correct word AND
  /// keeps madd letters in the predicted letter list so far more letters get
  /// their sifat compared (closes most of the detail gap vs the grouped scorer).
  final RecitationScore legacyFixed;

  /// The group-based [GroupedRecitationScorer] result.
  final RecitationScore grouped;
}

/// All scorings of one recitation, computed from a single model inference: one
/// [ScorerPair] per [DecodeMode]. The UI toggles which decode mode and which
/// scorer it displays, with no re-inference.
class RecitationAnalysis {
  const RecitationAnalysis(this.byMode);

  final Map<DecodeMode, ScorerPair> byMode;

  /// The pair for [mode], falling back to greedy if (somehow) absent.
  ScorerPair forMode(DecodeMode mode) =>
      byMode[mode] ?? byMode[DecodeMode.greedy]!;

  /// Back-compat greedy-mode accessors.
  RecitationScore get legacy => byMode[DecodeMode.greedy]!.legacy;
  RecitationScore get grouped => byMode[DecodeMode.greedy]!.grouped;
}

/// A user-actionable failure from [RecitationEngine.analyze].
class RecitationException implements Exception {
  const RecitationException(this.message);
  final String message;
  @override
  String toString() => message;
}
