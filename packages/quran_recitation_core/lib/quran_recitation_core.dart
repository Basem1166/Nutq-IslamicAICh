/// Pure-Dart core for the live Quran recitation feedback engine.
///
/// This library exports the types and pure-algorithm functions that the
/// session orchestrator (and any UI on top of it) consume. It has no
/// dependencies on Flutter, audio I/O, or any ML runtime — those live in
/// adapter packages that depend on this one.
///
/// Three layers of API
/// ───────────────────
///
/// **1. Output types** (what the UI renders)
///   - [SifaSnapshot], [SifaDiff], [SifatAccuracy], [SifatLevelAccuracy]
///   - [TajweedRuleRef], [PhonemeError], [ErrorType], [SpeechErrorType]
///   - [WordResult], [WordStatus]
///   - [AyahResult], [AyahStatus]
///   - [PhraseAlignment], [PhraseDecision]
///
/// **2. Phonetizer interop** (the shape your phonetizer service must
/// produce)
///   - [PhonemeMapping]
///   - [PhonetizerAdapterResult], [adaptPhonetizerResult],
///     [adaptPhonetizerResultFromSpacedPhonemes],
///     [phonemeMappingsFromService], [sifaSnapshotsFromService],
///     [synthesizeMappingsFromSpacedPhonemes]
///
/// **3. Pure algorithms** (used by the session)
///   - [chunkPhonemes] — letter-group tokenisation of QPS strings
///   - [buildWordSpans] — per-word reference span construction
///   - [alignPhraseToWords] — heard-phrase ↔ word alignment
///   - [classifyPhrase] — 3-hypothesis phrase-boundary decision
///   - [computeSifatAccuracy] — per-phrase sifat accuracy metric
///   - [SequenceMatcher] — `difflib.SequenceMatcher` subset (re-exported
///     for callers that want to do their own alignment)
///
/// **4. Streaming + VAD**
///   - [AdaptiveStreamingMuaalem], [AdaptiveConfig], [RecitationModel] —
///     the adaptive streamer and the model interface it drives.
///   - [VadGate], [VadBackend], [MockVadBackend] — voice-activity gate
///     with the Silero ONNX backend living in the Flutter app.
///
/// **5. Orchestration**
///   - [RecitationSession], [SessionConfig], [AyahReference],
///     [AyahReferenceLoader] — the top-level lifecycle.
///
/// All output types have `toJson` for serialisation to the UI (and
/// `fromJson` for round-trip / persistence). JSON keys are snake_case
/// matching the Python reference shape so logs are diffable across
/// implementations.
library quran_recitation_core;

export 'src/ayah_result.dart';
export 'src/phoneme_chunking.dart';
export 'src/phoneme_mapping.dart';
export 'src/phonetizer_adapter.dart';
export 'src/phrase_alignment.dart';
export 'src/phrase_classifier.dart';
export 'src/recitation_session.dart';
export 'src/sequence_matcher.dart';
export 'src/sifat.dart';
export 'src/streaming_inference.dart';
export 'src/vad_gate.dart';
export 'src/word_aligner.dart';
export 'src/word_result.dart';
