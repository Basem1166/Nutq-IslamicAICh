/// Deterministic fakes for driving [RecitationSession] / the adaptive
/// streamer without onnxruntime.
///
/// The real pipeline is: audio → ONNX CTC logits → decoded phoneme ids →
/// text. None of that is needed to exercise the *orchestration* logic in
/// `recitation_session.dart` (lock/clear, eager emission, Madd-stretch,
/// phrase classification). What the session actually depends on is the
/// **committed phoneme text** the streamer produces and the **frame**
/// metadata the streamer's commit heuristics read.
///
/// [ScriptedRecitationModel] decouples the two: the test pushes a queue of
/// phoneme strings (one per inference window) and the model hands them back
/// with frame indices placed *safely inside* the emission range, so the
/// adaptive streamer commits each window immediately (reason
/// `safely-inside`) with no expansion or seam recovery. That keeps the
/// harness robust — tests assert on lock state / word statuses / emitted
/// results, not on the streamer's internal chunk-timing.
library;

import 'dart:typed_data';

import 'package:quran_recitation_core/quran_recitation_core.dart';

/// A [RecitationModel] that emits a scripted sequence of phoneme strings,
/// one per [run] call, instead of running ONNX inference.
///
/// Vocabulary scheme
/// ─────────────────
/// Every phoneme is a single Unicode code unit and its vocab id IS its
/// code unit (`'ق'.codeUnitAt(0)`), so [vocabLookup] is a trivial
/// round-trip and any phoneme string the phonetizer produces can be
/// scripted verbatim. Multi-codepoint composed glyphs are split into their
/// constituent code units (matching how the streamer concatenates
/// per-id text).
///
/// Frames
/// ──────
/// Each decoded id gets a peak frame near the *start* of the window's
/// emission range, well clear of the right-edge "boundary risk" zone, and
/// the scripted ids never end in a repeated run. Both conditions make
/// [AdaptiveStreamingMuaalem] commit the window on the first milestone
/// rather than expanding, so one [run] == one commit == one scripted
/// phrase. Sifat output is omitted (the session tolerates absent sifat:
/// each attribute is left null).
class ScriptedRecitationModel implements RecitationModel {
  ScriptedRecitationModel();

  /// FIFO of phoneme strings to emit, one per [run]. When empty, [run]
  /// returns an empty output (no tokens) — which the streamer treats as a
  /// commit of nothing.
  final List<String> _scriptQueue = <String>[];

  /// Records every phoneme string actually handed to [run] (diagnostic).
  final List<String> consumed = <String>[];

  /// Phoneme text emitted by the most recent [run]; re-used for the seam
  /// re-decode path so [decodeFromLastLogits] never invents new tokens.
  String _lastEmitted = '';

  /// Enqueues [phonemes] to be emitted by a future [run] call.
  void pushPhonemes(String phonemes) => _scriptQueue.add(phonemes);

  /// Enqueues several windows at once.
  void pushAll(Iterable<String> windows) => _scriptQueue.addAll(windows);

  /// Number of windows still queued.
  int get pending => _scriptQueue.length;

  @override
  MuaalemOutput run({
    required Float32List audio,
    required int frameStart,
    required int frameEnd,
  }) {
    if (_scriptQueue.isEmpty) {
      _lastEmitted = '';
      return const MuaalemOutput(phonemes: PhonemeUnit(ids: <int>[], text: ''));
    }
    final phonemes = _scriptQueue.removeAt(0);
    consumed.add(phonemes);
    _lastEmitted = phonemes;
    return _outputFor(phonemes, frameStart: frameStart, frameEnd: frameEnd);
  }

  @override
  PhonemeUnit? decodeFromLastLogits({
    required int frameStart,
    required int frameEnd,
  }) {
    // Seam recovery re-decodes the OVERLAP region (just before frameStart).
    // Returning no tokens here is the safe choice: it means "nothing new
    // recovered", so the streamer never duplicates already-committed text.
    // The scripted model has no notion of overlapping frames, and the
    // suffix-prefix matcher would drop duplicates anyway.
    return null;
  }

  @override
  String vocabLookup(String level, int id) {
    if (level != 'phonemes') return '';
    return String.fromCharCode(id);
  }

  MuaalemOutput _outputFor(
    String phonemes, {
    required int frameStart,
    required int frameEnd,
  }) {
    final ids = phonemes.codeUnits;
    // Place every peak a couple of frames inside the emission range so the
    // streamer's H1 (peak-near-right-edge) check never fires; spread them
    // by one frame each but cap below the edge zone so even long strings
    // stay "safely inside".
    final safeCeil = frameEnd - frameStart > 8
        ? frameStart + (frameEnd - frameStart) ~/ 2
        : frameStart + 1;
    final frames = <int>[];
    for (var i = 0; i < ids.length; i++) {
      final f = frameStart + 1 + i;
      frames.add(f < safeCeil ? f : safeCeil);
    }
    final probs = List<double>.filled(ids.length, 0.99);
    return MuaalemOutput(
      phonemes: PhonemeUnit(
        ids: List<int>.from(ids),
        text: phonemes,
        frames: frames,
        probabilities: probs,
      ),
    );
  }

  /// Most recent emitted phoneme text (diagnostic / seam fallback).
  String get lastEmitted => _lastEmitted;
}
