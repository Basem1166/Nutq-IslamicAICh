/// [PhraseDecision] enum and [PhraseAlignment] result type.
///
/// `PhraseAlignment` is what the phrase classifier returns after deciding
/// whether the just-spoken phrase is a continuation, a repetition, the
/// start of the next ayah, ambiguous, or noise.
library;

import 'package:meta/meta.dart';

/// What the phrase represents in relation to the in-progress ayah.
enum PhraseDecision {
  /// Continues the recitation forward from `currentWordIdx`.
  continuation,

  /// Re-recites one or more earlier words in the same ayah.
  repetition,

  /// Starts the next ayah.
  nextAyah,

  /// No hypothesis scored well — hold state, do not advance.
  ambiguous,

  /// Phrase doesn't match anything (silence / noise / unrelated
  /// speech).
  noise;

  /// JSON value matching the Python literal (snake_case for
  /// `next_ayah`).
  String get jsonValue => switch (this) {
        PhraseDecision.continuation => 'continuation',
        PhraseDecision.repetition => 'repetition',
        PhraseDecision.nextAyah => 'next_ayah',
        PhraseDecision.ambiguous => 'ambiguous',
        PhraseDecision.noise => 'noise',
      };

  /// Inverse of [jsonValue] — parses a Python-emitted string.
  static PhraseDecision fromJson(String value) => switch (value) {
        'continuation' => PhraseDecision.continuation,
        'repetition' => PhraseDecision.repetition,
        'next_ayah' => PhraseDecision.nextAyah,
        'ambiguous' => PhraseDecision.ambiguous,
        'noise' => PhraseDecision.noise,
        _ => throw ArgumentError.value(
            value,
            'value',
            'Unknown PhraseDecision',
          ),
      };
}

/// Output of the phrase classifier — the chosen hypothesis plus its
/// per-word PER list and overall confidence.
@immutable
class PhraseAlignment {
  /// Builds an alignment. `perPerWord` is empty for `noise` / `ambiguous`
  /// outcomes where no words matched.
  const PhraseAlignment({
    required this.decision,
    required this.startWordIdx,
    required this.endWordIdx,
    required this.perPerWord,
    required this.overallPer,
    required this.confidence,
    this.nextAyahFirstWordPer,
  });

  /// Parses a JSON map produced by [toJson].
  factory PhraseAlignment.fromJson(Map<String, dynamic> json) =>
      PhraseAlignment(
        decision: PhraseDecision.fromJson(json['decision'] as String),
        startWordIdx: json['start_word_idx'] as int,
        endWordIdx: json['end_word_idx'] as int,
        perPerWord: ((json['per_per_word'] as List<dynamic>?) ??
                const <dynamic>[])
            .map((e) => (e as num).toDouble())
            .toList(growable: false),
        overallPer: (json['overall_per'] as num).toDouble(),
        confidence: (json['confidence'] as num).toDouble(),
        nextAyahFirstWordPer:
            (json['next_ayah_first_word_per'] as num?)?.toDouble(),
      );

  /// The chosen hypothesis.
  final PhraseDecision decision;

  /// Index of the first matched word (in the current ayah unless
  /// [decision] is `nextAyah`, in which case it refers to the next
  /// ayah).
  final int startWordIdx;

  /// Exclusive end index of the matched range.
  final int endWordIdx;

  /// PER for each matched word (length == endWordIdx − startWordIdx).
  final List<double> perPerWord;

  /// Combined PER across matched words, weighted by reference chunk
  /// count.
  final double overallPer;

  /// `1 − overallPer`, clamped to [0, 1].
  final double confidence;

  /// PER of the next-ayah-first-word hypothesis (H3), if it was
  /// evaluated. Useful for tracing why a `continuation` was preferred
  /// over a close `nextAyah`.
  final double? nextAyahFirstWordPer;

  /// JSON form matching the Python `PhraseAlignment.to_dict()` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'decision': decision.jsonValue,
        'start_word_idx': startWordIdx,
        'end_word_idx': endWordIdx,
        'per_per_word': perPerWord,
        'overall_per': overallPer,
        'confidence': confidence,
        'next_ayah_first_word_per': nextAyahFirstWordPer,
      };
}
