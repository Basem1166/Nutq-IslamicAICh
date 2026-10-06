# quran_recitation_core

Pure-Dart core for the live Quran recitation feedback engine. This package
exports the algorithmic primitives (phoneme chunking, word/phrase
alignment, phrase-boundary classification) and the output types that a UI
renders. It has **no dependencies on Flutter, audio I/O, or any ML
runtime** — those live in adapter packages that depend on this one.

## Why a separate core

Three reasons:

1. **Testable without a Flutter environment.** Run
   `dart test` from CI and prove the algorithm hasn't drifted from
   the Python reference. No emulator, no mic permissions, no model
   download.
2. **Reusable across surfaces.** The same core can drive a Flutter app, a
   Dart CLI tool, or a server-side validator.
3. **Smaller blast radius for changes.** When the ML side moves
   (a new model, a new feature extractor), only the adapter packages
   need to recompile.

## What's in here

| Module | Exports |
| --- | --- |
| `phoneme_chunking.dart` | `chunkPhonemes` |
| `phonetizer_adapter.dart` | `PhonetizerAdapterResult`, `adaptPhonetizerResult`, `adaptPhonetizerResultFromSpacedPhonemes`, `phonemeMappingsFromService`, `sifaSnapshotsFromService`, `synthesizeMappingsFromSpacedPhonemes` |
| `vad_gate.dart` | `VadGate`, `VadEvent`, `VadEventType`, `VadBackend`, `MockVadBackend` |
| `streaming_inference.dart` | `AdaptiveStreamingMuaalem`, `AdaptiveConfig`, `AdaptiveChunkBuffer`, `Window`, `StreamingResult`, `MilestoneInfo`, `RecitationModel`, `MuaalemOutput`, `PhonemeUnit`, `SifaUnit`, `samplesToCtcFrames`, `pickAdaptiveConfigForLatency` |
| `recitation_session.dart` | `RecitationSession`, `SessionConfig`, `AyahReference`, `AyahReferenceLoader` |
| `sifat.dart` | `sifatAttributes`, `SifaSnapshot`, `SifaDiff`, `SifatAccuracy`, `SifatLevelAccuracy`, `computeSifatAccuracy` |
| `word_result.dart` | `WordResult`, `WordStatus`, `PhonemeError`, `TajweedRuleRef`, `ErrorType`, `SpeechErrorType` |
| `ayah_result.dart` | `AyahResult`, `AyahStatus` |
| `phrase_alignment.dart` | `PhraseAlignment`, `PhraseDecision` |
| `phoneme_mapping.dart` | `PhonemeMapping` |
| `word_aligner.dart` | `WordSpan`, `WordMatch`, `PhraseToWordsAlignment`, `buildWordSpans`, `alignPhraseToWords` |
| `phrase_classifier.dart` | `PhraseClassifierConfig`, `classifyPhrase` |
| `sequence_matcher.dart` | `SequenceMatcher`, `MatchingBlock` |

Every output type has `toJson` (for sending to the UI) and `fromJson` (for
round-trip / persistence). JSON keys are snake_case to match the Python
reference, so live logs are diffable across both implementations.

## What's NOT in here

- **The phonetizer itself.** Your Chaquopy-backed `PhonetizerService`
  produces `refPhonemes`, the per-character `PhonemeMapping`s, and the
  per-chunk `SifaSnapshot` reference list. The
  [phonetizer_adapter] glue is included; the service implementation
  is not (it stays in your Flutter app since it depends on a Python
  bridge).
- **ONNX runtime.** Both the Silero VAD and the Muaalem model run via
  ONNX in the Flutter app. The core defines abstract backends
  ([VadBackend], [RecitationModel]); two reference adapters live under
  `integration_patches/` (`silero_vad_backend.dart`,
  `recitation_model_adapter.dart`).
- **The Flutter UI / mic capture.** The session is mic-agnostic;
  `feedAudio` takes a `Float32List`.
- **The session orchestrator.** Coming in a follow-up package
  (`quran_recitation_session`) once the streaming controller is ported.
- **The streaming controller, VAD, model wrapper, audio I/O.** These
  belong in `quran_recitation_engine` and the Flutter app package
  respectively.

## Usage example

```dart
import 'package:quran_recitation_core/quran_recitation_core.dart';

void main() {
  // Per ayah: build word spans once from the phonetizer's output.
  final spans = buildWordSpans(
    uthmaniText: 'مَالِكِ يَوْمِ الدِّينِ',
    refPhonemes: 'maalikiyawmiddiin',         // from your phonetizer
    mappings: phonetizerService.mappingsFor(  // adapt to PhonemeMapping
      ayah: '1:4',
    ),
    refSifatChunks: phonetizerService.sifatFor(ayah: '1:4'),
  );

  // Per phrase (between VAD silences):
  final phraseHyp = streamer.decodeSinceLastBoundary();
  final result = classifyPhrase(
    phraseHyp: phraseHyp,
    wordSpans: spans,
    currentWordIdx: session.currentWordIdx,
    nextAyahFirstWord: nextAyahSpans?.first,
  );

  switch (result.decision) {
    case PhraseDecision.continuation:
      // Emit matched words and advance currentWordIdx.
    case PhraseDecision.repetition:
      // Replace previously emitted word results for the matched range.
    case PhraseDecision.nextAyah:
      // Finalize this ayah, advance to the next.
    case PhraseDecision.ambiguous:
    case PhraseDecision.noise:
      // Hold state.
  }
}
```

## Testing

```sh
dart pub get
dart test
```

The test suite includes Python-parity fixtures generated from the
reference implementation. If a Dart change breaks one, the algorithm has
diverged — re-confirm the change in Python first before updating the
fixture.

## Versioning

Semantic versioning. The `0.x` series may break API as the session
port lands and we learn what the orchestrator actually needs.
