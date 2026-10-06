/// Per-ayah aggregate state: [AyahStatus] enum + [AyahResult].
///
/// The session mutates an [AyahResult] over the lifetime of a recitation
/// attempt (appending [WordResult]s, advancing [AyahResult.currentWordIdx],
/// updating the running hypothesis). Identity fields ([AyahResult.sura],
/// [AyahResult.ayah], [AyahResult.uthmaniText], [AyahResult.refPhonemes])
/// are `final`; progress fields are mutable to match the Python dataclass
/// shape.
library;

import 'word_result.dart';

/// Status of an [AyahResult] across its lifetime.
enum AyahStatus {
  /// Active recitation; not yet complete or locked.
  inProgress,

  /// Every word emitted, no outstanding lock.
  complete,

  /// Word 0 PER above the lock threshold — can't advance from the
  /// start. Kept separate from [locked] because the demo / UI presents
  /// a different message ("start over") for this case.
  lockedOnFirstWord,

  /// Some non-zero word locked due to high PER.
  locked,

  /// Session finalized without reaching [complete] (user gave up / timed
  /// out).
  abandoned;

  /// JSON value matching the Python `AyahStatus` literal (snake_case).
  String get jsonValue => switch (this) {
        AyahStatus.inProgress => 'in_progress',
        AyahStatus.complete => 'complete',
        AyahStatus.lockedOnFirstWord => 'locked_on_first_word',
        AyahStatus.locked => 'locked',
        AyahStatus.abandoned => 'abandoned',
      };

  /// Inverse of [jsonValue] — parses a Python-emitted string.
  static AyahStatus fromJson(String value) => switch (value) {
        'in_progress' => AyahStatus.inProgress,
        'complete' => AyahStatus.complete,
        'locked_on_first_word' => AyahStatus.lockedOnFirstWord,
        'locked' => AyahStatus.locked,
        'abandoned' => AyahStatus.abandoned,
        _ => throw ArgumentError.value(value, 'value', 'Unknown AyahStatus'),
      };
}

/// Aggregate result of one ayah's recitation attempt.
///
/// Mutability
/// ──────────
/// The session progressively builds this object as audio arrives:
///   - [wordResults] grows as words are emitted (use [List.add]).
///   - [currentWordIdx], [status], [hypPhonemes], [overallPer] are
///     reassigned as state evolves.
///
/// Identity fields ([sura], [ayah], [uthmaniText], [refPhonemes]) are
/// `final`.
class AyahResult {
  /// Creates a new ayah result in [AyahStatus.inProgress].
  AyahResult({
    required this.sura,
    required this.ayah,
    required this.uthmaniText,
    required this.refPhonemes,
    List<WordResult>? wordResults,
    this.overallPer = 0.0,
    this.status = AyahStatus.inProgress,
    this.currentWordIdx = 0,
    this.hypPhonemes = '',
  }) : wordResults = wordResults ?? <WordResult>[];

  /// Parses a JSON map produced by [toJson].
  factory AyahResult.fromJson(Map<String, dynamic> json) => AyahResult(
        sura: json['sura'] as int,
        ayah: json['ayah'] as int,
        uthmaniText: json['uthmani_text'] as String,
        refPhonemes: json['ref_phonemes'] as String,
        wordResults: ((json['word_results'] as List<dynamic>?) ??
                const <dynamic>[])
            .map((e) => WordResult.fromJson(e as Map<String, dynamic>))
            .toList(),
        overallPer: (json['overall_per'] as num?)?.toDouble() ?? 0.0,
        status: AyahStatus.fromJson(
          (json['status'] as String?) ?? 'in_progress',
        ),
        currentWordIdx: (json['current_word_idx'] as int?) ?? 0,
        hypPhonemes: (json['hyp_phonemes'] as String?) ?? '',
      );

  /// Sura number (1-114).
  final int sura;

  /// Ayah number within the sura (1-based).
  final int ayah;

  /// Full Uthmani text of the ayah.
  final String uthmaniText;

  /// Full reference phonemes for the ayah (from the phonetizer).
  final String refPhonemes;

  /// Words emitted so far. Append to grow.
  final List<WordResult> wordResults;

  /// Phoneme error rate across all emitted words, weighted by ref
  /// chunks. Recomputed by the session after every word emission.
  double overallPer;

  /// Current disposition of the ayah.
  AyahStatus status;

  /// Next word the session expects (0-based). Incremented on emission.
  int currentWordIdx;

  /// Streamer's accumulated hypothesis up to the current moment.
  String hypPhonemes;

  /// JSON form matching the Python `AyahResult.to_dict()` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'sura': sura,
        'ayah': ayah,
        'uthmani_text': uthmaniText,
        'ref_phonemes': refPhonemes,
        'word_results': wordResults.map((w) => w.toJson()).toList(),
        'overall_per': overallPer,
        'status': status.jsonValue,
        'current_word_idx': currentWordIdx,
        'hyp_phonemes': hypPhonemes,
      };
}
