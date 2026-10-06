/// Per-word result types: [TajweedRuleRef], [PhonemeError], [WordResult],
/// and the [WordStatus] enum.
///
/// These are output-facing — they're what the session hands back to a UI
/// after scoring each emitted word. Every type has a [toJson] for the
/// Flutter / web renderer and a `fromJson` for round-trip persistence.
library;

import 'package:meta/meta.dart';

import 'sifat.dart';

/// Status of a single emitted word after classification.
enum WordStatus {
  /// PER ≤ session correct-threshold; no errors.
  correct,

  /// PER above the correct-threshold but below the noise-threshold.
  errors,

  /// Eagerly emitted with partial confidence; may be upgraded later.
  incomplete,

  /// PER ≥ lock-threshold; ayah is held on this word pending
  /// re-recitation.
  locked,

  /// Auto-skipped (e.g. ayah finalized while still unconfirmed).
  skipped;

  /// JSON value matching the Python `WordStatus` literal.
  String get jsonValue => name;

  /// Inverse of [jsonValue] — parses a Python-emitted string.
  static WordStatus fromJson(String value) => switch (value) {
        'correct' => WordStatus.correct,
        'errors' => WordStatus.errors,
        'incomplete' => WordStatus.incomplete,
        'locked' => WordStatus.locked,
        'skipped' => WordStatus.skipped,
        _ => throw ArgumentError.value(value, 'value', 'Unknown WordStatus'),
      };
}

/// Phoneme-error severity. Matches the phonetizer's `error_type` literal.
enum ErrorType {
  /// A tajweed rule was violated (Madd length, Ghunna, etc.).
  tajweed,

  /// A non-tajweed mistake — wrong consonant, missing letter.
  normal,

  /// A tashkeel (diacritic) mistake — wrong vowel.
  tashkeel;

  /// JSON value matching the Python literal.
  String get jsonValue => name;

  /// Inverse of [jsonValue].
  static ErrorType fromJson(String value) => switch (value) {
        'tajweed' => ErrorType.tajweed,
        'normal' => ErrorType.normal,
        'tashkeel' => ErrorType.tashkeel,
        _ => throw ArgumentError.value(value, 'value', 'Unknown ErrorType'),
      };
}

/// Speech-side error kind: how the model deviated from the reference.
enum SpeechErrorType {
  /// Model emitted phonemes that weren't in the reference.
  insert,

  /// Model omitted phonemes that were in the reference.
  delete,

  /// Model emitted different phonemes than expected.
  replace;

  /// JSON value matching the Python literal.
  String get jsonValue => name;

  /// Inverse of [jsonValue].
  static SpeechErrorType fromJson(String value) => switch (value) {
        'insert' => SpeechErrorType.insert,
        'delete' => SpeechErrorType.delete,
        'replace' => SpeechErrorType.replace,
        _ => throw ArgumentError.value(
            value,
            'value',
            'Unknown SpeechErrorType',
          ),
      };
}

/// Compact view of a tajweed rule attached to a [PhonemeError].
@immutable
class TajweedRuleRef {
  /// Builds a rule reference. All length fields are optional and only
  /// populated for length-bearing rules (Madds, Ghunnas).
  const TajweedRuleRef({
    required this.nameAr,
    required this.nameEn,
    this.tag,
    this.expectedLen,
    this.actualLen,
  });

  /// Parses a JSON map produced by [toJson].
  factory TajweedRuleRef.fromJson(Map<String, dynamic> json) => TajweedRuleRef(
        nameAr: json['name_ar'] as String,
        nameEn: json['name_en'] as String,
        tag: json['tag'] as String?,
        expectedLen: json['expected_len'] as int?,
        actualLen: json['actual_len'] as int?,
      );

  /// Arabic display name (e.g. `'مَد منفصل'`).
  final String nameAr;

  /// English display name (e.g. `'Madd Munfasil'`).
  final String nameEn;

  /// Machine tag from the phonetizer, if any (e.g. `'madd_monfasel'`).
  final String? tag;

  /// Expected length in harakat for length-bearing rules; `null`
  /// otherwise.
  final int? expectedLen;

  /// Detected length in harakat if the model emitted a deviation;
  /// `null` when the rule wasn't a length error.
  final int? actualLen;

  /// JSON form matching the Python `TajweedRuleRef.to_dict()` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name_ar': nameAr,
        'name_en': nameEn,
        'tag': tag,
        'expected_len': expectedLen,
        'actual_len': actualLen,
      };
}

/// One phoneme-level discrepancy with positions in both the Uthmani word
/// and the reference phoneme string.
///
/// Positions are word-local (re-based from whole-ayah positions when the
/// phonetizer's `ReciterError` is converted). UI uses these to highlight
/// the exact character spans of the error.
@immutable
class PhonemeError {
  /// Builds a phoneme error record.
  const PhonemeError({
    required this.errorType,
    required this.speechErrorType,
    required this.expectedPhonemes,
    required this.predictedPhonemes,
    required this.uthmaniSpan,
    required this.phonemeSpan,
    this.refTajweedRules = const <TajweedRuleRef>[],
    this.insertedTajweedRules = const <TajweedRuleRef>[],
    this.replacedTajweedRules = const <TajweedRuleRef>[],
    this.missingTajweedRules = const <TajweedRuleRef>[],
  });

  /// Parses a JSON map produced by [toJson].
  factory PhonemeError.fromJson(Map<String, dynamic> json) {
    List<TajweedRuleRef> rules(String key) =>
        ((json[key] as List<dynamic>?) ?? const <dynamic>[])
            .map((e) => TajweedRuleRef.fromJson(e as Map<String, dynamic>))
            .toList(growable: false);

    final us = json['uthmani_span'] as List<dynamic>;
    final ps = json['phoneme_span'] as List<dynamic>;
    return PhonemeError(
      errorType: ErrorType.fromJson(json['error_type'] as String),
      speechErrorType:
          SpeechErrorType.fromJson(json['speech_error_type'] as String),
      expectedPhonemes: json['expected_phonemes'] as String,
      predictedPhonemes: json['predicted_phonemes'] as String,
      uthmaniSpan: (us[0] as int, us[1] as int),
      phonemeSpan: (ps[0] as int, ps[1] as int),
      refTajweedRules: rules('ref_tajweed_rules'),
      insertedTajweedRules: rules('inserted_tajweed_rules'),
      replacedTajweedRules: rules('replaced_tajweed_rules'),
      missingTajweedRules: rules('missing_tajweed_rules'),
    );
  }

  /// Severity category from the phonetizer.
  final ErrorType errorType;

  /// What the speech model did at this position (insert/delete/replace).
  final SpeechErrorType speechErrorType;

  /// What the reference says should have been there.
  final String expectedPhonemes;

  /// What the model heard.
  final String predictedPhonemes;

  /// Half-open `(start, end)` indices into the WORD's Uthmani text.
  final (int, int) uthmaniSpan;

  /// Half-open `(start, end)` indices into the WORD's reference phonemes.
  final (int, int) phonemeSpan;

  /// Tajweed rules attached to the reference span at this error.
  final List<TajweedRuleRef> refTajweedRules;

  /// Rules the model added that weren't in the reference.
  final List<TajweedRuleRef> insertedTajweedRules;

  /// Rules the model swapped for a different rule.
  final List<TajweedRuleRef> replacedTajweedRules;

  /// Rules the model dropped entirely.
  final List<TajweedRuleRef> missingTajweedRules;

  /// JSON form matching the Python `PhonemeError.to_dict()` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'error_type': errorType.jsonValue,
        'speech_error_type': speechErrorType.jsonValue,
        'expected_phonemes': expectedPhonemes,
        'predicted_phonemes': predictedPhonemes,
        'uthmani_span': <int>[uthmaniSpan.$1, uthmaniSpan.$2],
        'phoneme_span': <int>[phonemeSpan.$1, phonemeSpan.$2],
        'ref_tajweed_rules': refTajweedRules.map((r) => r.toJson()).toList(),
        'inserted_tajweed_rules':
            insertedTajweedRules.map((r) => r.toJson()).toList(),
        'replaced_tajweed_rules':
            replacedTajweedRules.map((r) => r.toJson()).toList(),
        'missing_tajweed_rules':
            missingTajweedRules.map((r) => r.toJson()).toList(),
      };
}

/// Result of scoring the user's recitation of one word against the
/// reference.
///
/// [per] is the phoneme error rate on the chunked-phoneme level (not raw
/// char), so Madd-length errors count proportionally rather than as N
/// single-char errors.
@immutable
class WordResult {
  /// Builds a word result. All collection fields default to empty.
  const WordResult({
    required this.wordIdx,
    required this.uthmaniWord,
    required this.uthmaniSpanInAyah,
    required this.refPhonemes,
    required this.hypPhonemes,
    required this.per,
    required this.status,
    this.phonemeErrors = const <PhonemeError>[],
    this.sifatReference = const <SifaSnapshot>[],
    this.sifatPredicted = const <SifaSnapshot>[],
    this.sifatDiffs = const <SifaDiff>[],
    this.confidence = 0.0,
    this.nRepetitions = 1,
  });

  /// Parses a JSON map produced by [toJson].
  factory WordResult.fromJson(Map<String, dynamic> json) {
    final us = json['uthmani_span_in_ayah'] as List<dynamic>;
    List<T> parseList<T>(
      String key,
      T Function(Map<String, dynamic>) decode,
    ) =>
        ((json[key] as List<dynamic>?) ?? const <dynamic>[])
            .map((e) => decode(e as Map<String, dynamic>))
            .toList(growable: false);
    return WordResult(
      wordIdx: json['word_idx'] as int,
      uthmaniWord: json['uthmani_word'] as String,
      uthmaniSpanInAyah: (us[0] as int, us[1] as int),
      refPhonemes: json['ref_phonemes'] as String,
      hypPhonemes: json['hyp_phonemes'] as String,
      per: (json['per'] as num).toDouble(),
      status: WordStatus.fromJson(json['status'] as String),
      phonemeErrors: parseList('phoneme_errors', PhonemeError.fromJson),
      sifatReference: parseList('sifat_reference', SifaSnapshot.fromJson),
      sifatPredicted: parseList('sifat_predicted', SifaSnapshot.fromJson),
      sifatDiffs: parseList('sifat_diffs', SifaDiff.fromJson),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      nRepetitions: (json['n_repetitions'] as int?) ?? 1,
    );
  }

  /// Index of this word in the ayah's word list (0-based).
  final int wordIdx;

  /// The word as it appears in the Uthmani text.
  final String uthmaniWord;

  /// Half-open `(start, end)` of this word in the ayah's Uthmani text.
  final (int, int) uthmaniSpanInAyah;

  /// Reference phonemes for this word.
  final String refPhonemes;

  /// What the model heard for this word.
  final String hypPhonemes;

  /// Phoneme error rate (chunked Levenshtein) ∈ [0, ∞), typically
  /// [0, 1]. Values above 1 indicate the hypothesis is longer than the
  /// reference.
  final double per;

  /// Final disposition of this word.
  final WordStatus status;

  /// Per-error breakdowns, if the phonetizer was asked for them.
  final List<PhonemeError> phonemeErrors;

  /// Reference sifat per chunk (one snapshot per Uthmani letter group).
  final List<SifaSnapshot> sifatReference;

  /// Predicted sifat per chunk, aligned 1:1 with [sifatReference] when
  /// the chunk counts match; otherwise the order matches the model's
  /// commit order.
  final List<SifaSnapshot> sifatPredicted;

  /// Convenience: only the per-attribute mismatches between reference
  /// and prediction.
  final List<SifaDiff> sifatDiffs;

  /// Alignment confidence ∈ [0, 1]. Higher = more certain this hyp
  /// slice belongs to this word.
  final double confidence;

  /// Number of attempts on this word (incremented on lock-and-replace).
  final int nRepetitions;

  /// Copies this result with selected fields replaced.
  WordResult copyWith({
    int? wordIdx,
    String? uthmaniWord,
    (int, int)? uthmaniSpanInAyah,
    String? refPhonemes,
    String? hypPhonemes,
    double? per,
    WordStatus? status,
    List<PhonemeError>? phonemeErrors,
    List<SifaSnapshot>? sifatReference,
    List<SifaSnapshot>? sifatPredicted,
    List<SifaDiff>? sifatDiffs,
    double? confidence,
    int? nRepetitions,
  }) =>
      WordResult(
        wordIdx: wordIdx ?? this.wordIdx,
        uthmaniWord: uthmaniWord ?? this.uthmaniWord,
        uthmaniSpanInAyah: uthmaniSpanInAyah ?? this.uthmaniSpanInAyah,
        refPhonemes: refPhonemes ?? this.refPhonemes,
        hypPhonemes: hypPhonemes ?? this.hypPhonemes,
        per: per ?? this.per,
        status: status ?? this.status,
        phonemeErrors: phonemeErrors ?? this.phonemeErrors,
        sifatReference: sifatReference ?? this.sifatReference,
        sifatPredicted: sifatPredicted ?? this.sifatPredicted,
        sifatDiffs: sifatDiffs ?? this.sifatDiffs,
        confidence: confidence ?? this.confidence,
        nRepetitions: nRepetitions ?? this.nRepetitions,
      );

  /// JSON form matching the Python `WordResult.to_dict()` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'word_idx': wordIdx,
        'uthmani_word': uthmaniWord,
        'uthmani_span_in_ayah': <int>[
          uthmaniSpanInAyah.$1,
          uthmaniSpanInAyah.$2,
        ],
        'ref_phonemes': refPhonemes,
        'hyp_phonemes': hypPhonemes,
        'per': per,
        'status': status.jsonValue,
        'confidence': confidence,
        'n_repetitions': nRepetitions,
        'phoneme_errors': phonemeErrors.map((e) => e.toJson()).toList(),
        'sifat_reference': sifatReference.map((s) => s.toJson()).toList(),
        'sifat_predicted': sifatPredicted.map((s) => s.toJson()).toList(),
        'sifat_diffs': sifatDiffs.map((d) => d.toJson()).toList(),
      };
}
