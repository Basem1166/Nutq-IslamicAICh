/// A [VadBackend] whose per-window P(speech) is driven by a script, so a
/// test can place `speechStart` / `phraseBoundary` events at exact points.
///
/// [MockVadBackend] (shipped by the core package) thresholds raw
/// amplitude, which is great for "is this buffer loud" but awkward when a
/// test needs a boundary to fire after a *precise* amount of silence. This
/// backend instead returns a scripted probability for each successive
/// [windowSize]-sample window: push `1.0` for speech windows and `0.0`
/// for silence windows. Once the script is exhausted it holds the last
/// value (default `0.0`), so trailing silence keeps reading as silence.
library;

import 'dart:typed_data';

import 'package:quran_recitation_core/quran_recitation_core.dart';

/// Scriptable VAD backend: one probability per processed window.
class ScriptedVadBackend implements VadBackend {
  ScriptedVadBackend({this.sampleRate = 16000});

  @override
  final int sampleRate;

  @override
  int get windowSize => sampleRate == 16000 ? sileroWindow16k : sileroWindow8k;

  final List<double> _probs = <double>[];
  int _cursor = 0;
  double _hold = 0.0;

  /// Queues [n] windows that read as speech (`1.0`).
  void pushSpeech(int n) {
    for (var i = 0; i < n; i++) {
      _probs.add(1.0);
    }
  }

  /// Queues [n] windows that read as silence (`0.0`).
  void pushSilence(int n) {
    for (var i = 0; i < n; i++) {
      _probs.add(0.0);
    }
  }

  @override
  double probability(Float32List window) {
    if (_cursor < _probs.length) {
      _hold = _probs[_cursor++];
      return _hold;
    }
    return _hold; // hold last scripted value once the script runs out
  }

  @override
  void reset() {
    // NOTE: cursor is intentionally NOT rewound. RecitationSession.reset
    // (via startAyah / _applyAyahReference) calls VadGate.reset which calls
    // this. A test scripts the whole session timeline up-front, so rewinding
    // here would replay window 0 after startAyah and desync the script.
    _hold = 0.0;
  }
}
