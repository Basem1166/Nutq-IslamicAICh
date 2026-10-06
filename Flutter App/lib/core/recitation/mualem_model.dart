import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import 'feature_extractor.dart';

/// Loads and runs the Mualem multilevel-CTC ONNX model.
///
/// Single input `input_features` of shape `[1, seqLen, 160]`; 11 named outputs
/// (one CTC head per Tajweed level), each `[1, time, vocab]`. The result maps
/// each level name to its `[time][vocab]` logits.
class MualemModel {
  // ConvInteger-free build: the original int8-dynamic export used ConvInteger
  // ops that ONNX Runtime can't execute. This variant keeps MatMulInteger (int8,
  // ORT-supported) but converts the 48 Conv layers back to float Conv.
  static const String assetPath =
      'assets/models/IslamAiConvfix.onnx';
  static const String _inputName = 'input_features';

  OrtSession? _session;

  bool get isLoaded => _session != null;

  /// Initializes the ORT environment and loads the model from assets.
  ///
  /// Must run on an isolate where `rootBundle` works (i.e. the root isolate).
  /// In a spawned isolate, load the bytes on the root isolate and use
  /// [loadFromBytes] instead.
  Future<void> load() async {
    if (_session != null) return;
    final raw = await rootBundle.load(assetPath);
    final bytes = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
    loadFromBytes(bytes);
  }

  /// Loads the model from pre-read bytes — safe to call in any isolate.
  ///
  /// `rootBundle` is unavailable in spawned isolates (it needs
  /// `ServicesBinding.instance`), so the worker-isolate path reads the asset
  /// on the root isolate and hands the [Uint8List] here.
  void loadFromBytes(Uint8List bytes) {
    if (_session != null) return;
    OrtEnv.instance.init();
    final options = OrtSessionOptions();
    _session = OrtSession.fromBuffer(bytes, options);
  }

  /// Runs inference and returns `{ levelName: [time][vocab] logits }`.
  Map<String, List<List<double>>> run(FeatureResult features) {
    final session = _session;
    if (session == null) {
      throw StateError('Model not loaded; call load() first');
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      features.features,
      [1, features.seqLen, MualemFeatureExtractor.numMelBins * MualemFeatureExtractor.stride],
    );
    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = session.run(runOptions, {_inputName: inputTensor});
      final names = session.outputNames;
      final result = <String, List<List<double>>>{};
      for (var i = 0; i < outputs.length; i++) {
        final value = outputs[i]?.value;
        // Each output is [1, time, vocab]; strip the batch dim.
        if (value is List && value.isNotEmpty) {
          result[names[i]] = _to2dDouble(value[0]);
        }
      }
      return result;
    } finally {
      inputTensor.release();
      runOptions.release();
      if (outputs != null) {
        for (final o in outputs) {
          o?.release();
        }
      }
    }
  }

  /// Coerces a `[time][vocab]` nested list of nums into `List<List<double>>`.
  static List<List<double>> _to2dDouble(dynamic timeAxis) {
    final t = timeAxis as List;
    return List<List<double>>.generate(
      t.length,
      (i) => List<double>.from((t[i] as List).map((e) => (e as num).toDouble())),
      growable: false,
    );
  }

  void dispose() {
    _session?.release();
    _session = null;
  }
}
