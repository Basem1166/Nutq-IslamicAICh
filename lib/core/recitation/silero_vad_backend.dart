import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:quran_recitation_core/quran_recitation_core.dart';

/// Silero VAD v5 ONNX backend for [VadGate].
///
/// The core `quran_recitation_core` package only ships [MockVadBackend]; the
/// real Silero model lives here in the app, where `onnxruntime` is available
/// (same split as the Mualem model + phonetizer). Drop the official
/// `silero_vad.onnx` (from snakers4/silero-vad) under [_assetPath].
///
/// Model I/O (Silero v5, combined state):
///   inputs  — `input` float32 `[1, 512]`, `state` float32 `[2, 1, 128]`,
///             `sr` int64 scalar
///   outputs — `output` float32 `[1, 1]` (P(speech)),
///             `stateN` float32 `[2, 1, 128]`
///
/// The LSTM [_state] persists across [probability] calls and is zeroed by
/// [reset]. Inference is synchronous (mirrors `MualemModel.run`), so the gate
/// can call [probability] inline as audio chunks arrive on the UI isolate.
class SileroVadBackend implements VadBackend {
  SileroVadBackend._(this._session, this._inputName, this._stateName,
      this._srName, this._probOutIdx, this._stateOutIdx);

  static const String assetPath = 'assets/models/silero_vad.onnx';

  /// Silero's combined LSTM state is `[2, 1, 128]` → 256 floats.
  static const int _stateLen = 2 * 1 * 128;

  /// Silero v5 prepends a 64-sample context (the tail of the previous window)
  /// to each 16 kHz window, so the model's `input` tensor is actually
  /// `[1, 64 + 512] = [1, 576]`. Without this the STFT is computed on a
  /// malformed frame and P(speech) collapses to ~0 for all audio. See the
  /// official OnnxWrapper: `x = cat([context, x]); context = x[..., -64:]`.
  static const int _contextLen = 64;

  final OrtSession _session;
  final String _inputName;
  final String _stateName;
  final String _srName;
  final int _probOutIdx;
  final int _stateOutIdx;

  /// Persistent LSTM hidden/cell state, flattened `[2,1,128]`.
  final Float32List _state = Float32List(_stateLen);

  /// Persistent 64-sample context carried from the previous window's tail,
  /// prepended to the next window to form the model's 576-sample input.
  /// Zeroed on [reset].
  final Float32List _context = Float32List(_contextLen);

  /// Scratch buffer for the `[context | window]` concat, reused per call.
  final Float32List _input = Float32List(_contextLen + sileroWindow16k);

  /// `sr` never changes, so build the (rank-0 int64) tensor once and reuse it.
  OrtValueTensor? _srTensor;

  @override
  int get sampleRate => 16000;

  @override
  int get windowSize => sileroWindow16k;

  /// Loads the ONNX model from assets and returns a ready backend.
  ///
  /// Must run on an isolate where `rootBundle` works (the root isolate). The
  /// worker-isolate path reads the asset on the root isolate and uses
  /// [fromBytes] instead.
  static Future<SileroVadBackend> load() async {
    final raw = await rootBundle.load(assetPath);
    final bytes = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
    return fromBytes(bytes);
  }

  /// Builds a backend from pre-read model bytes — safe in any isolate.
  static SileroVadBackend fromBytes(Uint8List bytes) {
    OrtEnv.instance.init();
    final session = OrtSession.fromBuffer(bytes, OrtSessionOptions());

    // Resolve I/O names defensively: exporters have shipped both `state`/`sr`
    // and (older) `h`/`c` graphs. We require the v5 combined-state graph.
    final inputs = session.inputNames;
    final outputs = session.outputNames;
    String pick(List<String> names, String want, List<String> fallbacks) {
      if (names.contains(want)) return want;
      for (final f in fallbacks) {
        if (names.contains(f)) return f;
      }
      throw StateError(
        'Silero VAD model missing "$want" (have: $names). Use the v5 '
        'combined-state silero_vad.onnx from snakers4/silero-vad.',
      );
    }

    final inputName = pick(inputs, 'input', const []);
    final stateName = pick(inputs, 'state', const []);
    final srName = pick(inputs, 'sr', const ['sample_rate']);
    final probIdx = outputs.indexOf('output');
    final stateIdx = outputs.indexOf('stateN');
    if (probIdx < 0 || stateIdx < 0) {
      throw StateError(
        'Silero VAD model missing "output"/"stateN" (have: $outputs).',
      );
    }
    return SileroVadBackend._(
        session, inputName, stateName, srName, probIdx, stateIdx);
  }

  @override
  double probability(Float32List window) {
    assert(
      window.length == windowSize,
      'Silero expects $windowSize-sample windows, got ${window.length}',
    );

    // Build the 576-sample input: 64-sample context from the previous window
    // followed by this 512-sample window. Silero v5 requires this — passing a
    // bare 512-sample window makes P(speech) collapse to ~0 for all audio.
    _input.setRange(0, _contextLen, _context);
    _input.setRange(_contextLen, _input.length, window);

    final inputTensor =
        OrtValueTensor.createTensorWithDataList(_input, [1, _input.length]);
    final stateTensor =
        OrtValueTensor.createTensorWithDataList(_state, [2, 1, 128]);
    final srTensor = _srTensor ??= OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(<int>[sampleRate]),
      <int>[],
    );

    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = _session.run(runOptions, {
        _inputName: inputTensor,
        _stateName: stateTensor,
        _srName: srTensor,
      });
      _absorbState(outputs[_stateOutIdx]?.value);
      final prob = _readProbability(outputs[_probOutIdx]?.value);

      // Carry this window's last 64 samples as the next call's context
      // (mirrors `self._context = x[..., -context_size:]`).
      _context.setRange(
          0, _contextLen, window, window.length - _contextLen);

      return prob;
    } finally {
      inputTensor.release();
      stateTensor.release();
      runOptions.release();
      if (outputs != null) {
        for (final o in outputs) {
          o?.release();
        }
      }
    }
  }

  /// Copies the model's `stateN` output (`[2,1,128]` nested) back into [_state].
  void _absorbState(Object? stateN) {
    if (stateN is! List) {
      throw StateError('Silero stateN output was not a tensor: $stateN');
    }
    var k = 0;
    for (final layer in stateN) {
      final batch = (layer as List).first as List; // [128]
      for (final v in batch) {
        _state[k++] = (v as num).toDouble();
      }
    }
    assert(k == _stateLen, 'stateN had $k elements, expected $_stateLen');
  }

  /// Extracts the scalar P(speech) from the `output` tensor (`[1,1]` nested).
  static double _readProbability(Object? output) {
    if (output is! List) {
      throw StateError('Silero output was not a tensor: $output');
    }
    final row = output.first as List; // [1]
    return (row.first as num).toDouble();
  }

  @override
  void reset() {
    for (var i = 0; i < _state.length; i++) {
      _state[i] = 0;
    }
    for (var i = 0; i < _context.length; i++) {
      _context[i] = 0;
    }
  }

  /// Frees the ONNX session and the cached `sr` tensor.
  void dispose() {
    _srTensor?.release();
    _srTensor = null;
    _session.release();
  }
}
