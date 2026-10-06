/// [PhonemeMapping]: per-Uthmani-character position in the reference
/// phoneme string.
///
/// This is the interface the word aligner expects from your phonetizer
/// service. The service must produce one [PhonemeMapping] (or `null`)
/// per character of the Uthmani text — the aligner uses these to slice
/// the full reference phoneme string into per-word ranges.
///
/// Adapter pattern
/// ───────────────
/// If your phonetizer service returns a different shape (e.g. JSON
/// objects, a `(start, end, deleted)` triple list), write a thin adapter
/// that converts to `List<PhonemeMapping?>` before calling
/// `buildWordSpans`. Keeping this type minimal avoids coupling the
/// recitation core to any specific phonetizer implementation.
library;

import 'package:meta/meta.dart';

/// Phoneme-string slice produced by one Uthmani character.
@immutable
class PhonemeMapping {
  /// Builds a mapping. `start` is inclusive, `end` is exclusive.
  /// `deleted` defaults to `false`; set it for sukoon / tatweel-style
  /// chars that produce no phonemes.
  const PhonemeMapping({
    required this.start,
    required this.end,
    this.deleted = false,
  });

  /// Convenience: build a mapping from a `(start, end)` record.
  ///
  /// Use when adapting from a service that returns positions as
  /// 2-tuples.
  factory PhonemeMapping.fromPos(
    (int, int) pos, {
    bool deleted = false,
  }) =>
      PhonemeMapping(start: pos.$1, end: pos.$2, deleted: deleted);

  /// Parses a JSON map produced by [toJson].
  factory PhonemeMapping.fromJson(Map<String, dynamic> json) => PhonemeMapping(
        start: json['start'] as int,
        end: json['end'] as int,
        deleted: (json['deleted'] as bool?) ?? false,
      );

  /// Inclusive start position in the reference phoneme string.
  final int start;

  /// Exclusive end position in the reference phoneme string.
  final int end;

  /// `true` if the character produced no phonemes (sukoon, tatweel,
  /// etc). A deleted mapping has `start == end` — the same insertion
  /// point where any phonemes WOULD have appeared.
  final bool deleted;

  /// JSON form for serialization.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'start': start,
        'end': end,
        'deleted': deleted,
      };
}
