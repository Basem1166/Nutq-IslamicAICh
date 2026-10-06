/// Sifat (articulation attribute) types and per-phrase accuracy metric.
///
/// The Quran Phonetic Script encodes 10 articulation attributes (sifat)
/// per phoneme group: hams/jahr, shidda/rakhawa, etc. Each attribute is
/// a short string label drawn from a small closed vocabulary. This file
/// defines the JSON-friendly carrier ([SifaSnapshot]), the diff type
/// ([SifaDiff]), and the per-phrase accuracy metric
/// ([computeSifatAccuracy]) that mirrors the offline sweep's
/// `compute_sifat_accuracy`.
library;

import 'package:meta/meta.dart';

/// Canonical order of the 10 sifat attribute names.
///
/// These are JSON snake_case strings — they double as the keys of
/// [SifaSnapshot.toJson], the keys returned by
/// [computeSifatAccuracy]'s `perLevel`, and the right answers for the
/// `attribute` argument of [SifaSnapshot.valueOf].
const List<String> sifatAttributes = <String>[
  'hams_or_jahr',
  'shidda_or_rakhawa',
  'tafkheem_or_taqeeq',
  'itbaq',
  'safeer',
  'qalqla',
  'tikraar',
  'tafashie',
  'istitala',
  'ghonna',
];

/// All sifat for one phoneme group, in JSON-friendly form.
///
/// Mirrors the per-letter-group output of `chunkPhonemes`: each Uthmani
/// letter (with its diacritic / Madd run) maps to one snapshot. Used
/// for both the reference (per-chunk truth from the phonetizer) and the
/// prediction (one snapshot per model commit chunk).
@immutable
class SifaSnapshot {
  /// Builds a snapshot. Unset attributes are reported as `null` and are
  /// skipped by [computeSifatAccuracy].
  const SifaSnapshot({
    required this.phonemeGroup,
    this.hamsOrJahr,
    this.shiddaOrRakhawa,
    this.tafkheemOrTaqeeq,
    this.itbaq,
    this.safeer,
    this.qalqla,
    this.tikraar,
    this.tafashie,
    this.istitala,
    this.ghonna,
    this.confidence = const <String, double>{},
  });

  /// Parses a JSON map produced by [toJson].
  factory SifaSnapshot.fromJson(Map<String, dynamic> json) {
    final rawConfidence = json['confidence'] as Map<String, dynamic>?;
    return SifaSnapshot(
      phonemeGroup: json['phoneme_group'] as String,
      hamsOrJahr: json['hams_or_jahr'] as String?,
      shiddaOrRakhawa: json['shidda_or_rakhawa'] as String?,
      tafkheemOrTaqeeq: json['tafkheem_or_taqeeq'] as String?,
      itbaq: json['itbaq'] as String?,
      safeer: json['safeer'] as String?,
      qalqla: json['qalqla'] as String?,
      tikraar: json['tikraar'] as String?,
      tafashie: json['tafashie'] as String?,
      istitala: json['istitala'] as String?,
      ghonna: json['ghonna'] as String?,
      confidence: rawConfidence == null
          ? const <String, double>{}
          : rawConfidence.map(
              (k, v) => MapEntry(k, (v as num).toDouble()),
            ),
    );
  }

  /// The phoneme group this snapshot describes (e.g. `'قَ'`, `'اااا'`).
  final String phonemeGroup;

  /// `'hams'` or `'jahr'` — voicing.
  final String? hamsOrJahr;

  /// `'shadeed'`, `'between'`, or `'rikhw'` — articulatory tightness.
  final String? shiddaOrRakhawa;

  /// `'mofakham'` or `'moraqaq'` — heaviness.
  final String? tafkheemOrTaqeeq;

  /// `'motbaq'` or `'monfateh'` — tongue concavity.
  final String? itbaq;

  /// `'safeer'` or `'no_safeer'` — whistling sibilance.
  final String? safeer;

  /// `'moqalqal'` or `'not_moqalqal'` — echo on sukoon.
  final String? qalqla;

  /// `'mokarar'` or `'not_mokarar'` — trilling (raa only).
  final String? tikraar;

  /// `'motafashie'` or `'not_motafashie'` — air spread (sheen only).
  final String? tafashie;

  /// `'mostateel'` or `'not_mostateel'` — elongation (dad only).
  final String? istitala;

  /// `'maghnoon'` or `'not_maghnoon'` — nasalisation.
  final String? ghonna;

  /// Per-attribute model confidence ∈ [0, 1]. Only populated for
  /// predicted sifat snapshots emitted by the streamer; empty for
  /// reference snapshots from the phonetizer.
  final Map<String, double> confidence;

  /// Returns the value of [attribute] (one of [sifatAttributes]), or
  /// `null` if not set / not a recognised name.
  String? valueOf(String attribute) => switch (attribute) {
        'hams_or_jahr' => hamsOrJahr,
        'shidda_or_rakhawa' => shiddaOrRakhawa,
        'tafkheem_or_taqeeq' => tafkheemOrTaqeeq,
        'itbaq' => itbaq,
        'safeer' => safeer,
        'qalqla' => qalqla,
        'tikraar' => tikraar,
        'tafashie' => tafashie,
        'istitala' => istitala,
        'ghonna' => ghonna,
        _ => null,
      };

  /// JSON form matching the Python `SifaSnapshot.to_dict()` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'phoneme_group': phonemeGroup,
        'hams_or_jahr': hamsOrJahr,
        'shidda_or_rakhawa': shiddaOrRakhawa,
        'tafkheem_or_taqeeq': tafkheemOrTaqeeq,
        'itbaq': itbaq,
        'safeer': safeer,
        'qalqla': qalqla,
        'tikraar': tikraar,
        'tafashie': tafashie,
        'istitala': istitala,
        'ghonna': ghonna,
        'confidence': confidence,
      };
}

/// One sifat attribute that the model heard differently from the
/// reference.
@immutable
class SifaDiff {
  /// Records a single per-attribute mismatch.
  const SifaDiff({
    required this.chunkIdx,
    required this.phonemeGroup,
    required this.attribute,
    required this.expected,
    required this.predicted,
    this.confidence,
  });

  /// Parses a JSON map produced by [toJson].
  factory SifaDiff.fromJson(Map<String, dynamic> json) => SifaDiff(
        chunkIdx: json['chunk_idx'] as int,
        phonemeGroup: json['phoneme_group'] as String,
        attribute: json['attribute'] as String,
        expected: json['expected'] as String?,
        predicted: json['predicted'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble(),
      );

  /// Index into the word's phoneme-chunk list (0-based).
  final int chunkIdx;

  /// The phoneme group at [chunkIdx].
  final String phonemeGroup;

  /// One of [sifatAttributes].
  final String attribute;

  /// Reference value, or `null` if the reference left this attribute
  /// unset.
  final String? expected;

  /// Predicted value, or `null` if the model didn't emit one.
  final String? predicted;

  /// Model confidence for [predicted], if available.
  final double? confidence;

  /// JSON form matching the Python `SifaDiff.to_dict()` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'chunk_idx': chunkIdx,
        'phoneme_group': phonemeGroup,
        'attribute': attribute,
        'expected': expected,
        'predicted': predicted,
        'confidence': confidence,
      };
}

/// Result of [computeSifatAccuracy].
@immutable
class SifatAccuracy {
  /// Constructs an accuracy result. Use [empty] for the no-data case.
  const SifatAccuracy({
    required this.macroAccuracy,
    required this.nAligned,
    required this.perLevel,
  });

  /// All-zero result: no chunks aligned, no levels recorded.
  const SifatAccuracy.empty()
      : macroAccuracy = 0.0,
        nAligned = 0,
        perLevel = const <String, SifatLevelAccuracy>{};

  /// Mean of per-level accuracies across the 10 sifat (only levels with
  /// at least one comparison count toward the mean).
  final double macroAccuracy;

  /// Number of (ref, hyp) chunk pairs the Levenshtein aligner produced.
  /// Bounded above by `min(refLength, hypLength)`.
  final int nAligned;

  /// Per-attribute breakdown keyed by [sifatAttributes].
  final Map<String, SifatLevelAccuracy> perLevel;

  /// JSON form matching the Python shape:
  /// `{macro_accuracy, n_aligned, per_level: {attr: {accuracy, matches, total}}}`.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'macro_accuracy': macroAccuracy,
        'n_aligned': nAligned,
        'per_level': perLevel.map((k, v) => MapEntry(k, v.toJson())),
      };
}

/// One attribute's accuracy in a [SifatAccuracy] result.
@immutable
class SifatLevelAccuracy {
  /// Constructs a per-level accuracy entry.
  const SifatLevelAccuracy({
    required this.accuracy,
    required this.matches,
    required this.total,
  });

  /// `matches / max(total, 1)` ∈ [0, 1].
  final double accuracy;

  /// Number of aligned pairs where ref and hyp values matched.
  final int matches;

  /// Number of aligned pairs where both ref and hyp had a non-null
  /// value. Pairs where either side is `null` are skipped.
  final int total;

  /// JSON form: `{accuracy, matches, total}`.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'accuracy': accuracy,
        'matches': matches,
        'total': total,
      };
}

/// Computes sifat-level accuracy of predicted vs reference snapshots.
///
/// Mirrors the offline sweep's `compute_sifat_accuracy`, scoped to the
/// per-phrase / per-ayah aggregation pattern used by the session.
///
/// Algorithm
/// ─────────
///   1. Align [ref] and [hyp] by `phonemeGroup` using Levenshtein-min
///      on the group sequence — chunk insertions / deletions don't
///      count toward accuracy, only chunks that pair up via the
///      alignment do.
///   2. For each aligned pair `(refChunk, hypChunk)`, and for each of
///      the 10 [sifatAttributes], compare the string values. Pairs
///      where either side is `null` are skipped.
///   3. Per-level accuracy = matches / total comparisons. Macro
///      accuracy = arithmetic mean over levels with at least one
///      comparison.
///
/// Returns [SifatAccuracy.empty] when either list is empty or no
/// chunks could be aligned.
SifatAccuracy computeSifatAccuracy({
  required List<SifaSnapshot> ref,
  required List<SifaSnapshot> hyp,
}) {
  if (ref.isEmpty || hyp.isEmpty) return const SifatAccuracy.empty();
  final pairs = _alignSifaGroups(ref, hyp);
  if (pairs.isEmpty) return const SifatAccuracy.empty();

  final perLevel = <String, SifatLevelAccuracy>{};
  final accs = <double>[];
  for (final attr in sifatAttributes) {
    var matches = 0;
    var total = 0;
    for (final pair in pairs) {
      final r = ref[pair.refIdx].valueOf(attr);
      final h = hyp[pair.hypIdx].valueOf(attr);
      if (r == null && h == null) continue;
      total += 1;
      if (r != null && h != null && r == h) matches += 1;
    }
    final acc = total == 0 ? 0.0 : matches / total;
    perLevel[attr] = SifatLevelAccuracy(
      accuracy: acc,
      matches: matches,
      total: total,
    );
    if (total > 0) accs.add(acc);
  }
  final macro =
      accs.isEmpty ? 0.0 : accs.reduce((a, b) => a + b) / accs.length;
  return SifatAccuracy(
    macroAccuracy: macro,
    nAligned: pairs.length,
    perLevel: perLevel,
  );
}

/// Computes the per-attribute sifat mismatches between [ref] and
/// [predicted] snapshots.
///
/// Uses the **same** Levenshtein-over-`phonemeGroup` alignment as
/// [computeSifatAccuracy] (via the shared [_alignSifaGroups]) rather than
/// zipping the two lists positionally. This matters because the predicted
/// snapshots can carry chunks that belong to a neighbouring word
/// (streaming-seam spillover). With positional zipping, such an offset
/// surfaces every attribute as a spurious diff *and* labels each diff with
/// the wrong word's phoneme group — the "drawer shows another word's
/// chunks" bug. Aligning first means an unmatched predicted chunk simply
/// pairs with nothing, so it can neither invent a diff nor mislabel one.
///
/// Every [SifaDiff] is labelled by the **reference** chunk: `chunkIdx` is
/// the reference index and `phonemeGroup` is the reference group (which is
/// identical to the predicted group, since the aligner only pairs chunks
/// with equal `phonemeGroup`). `confidence` is taken from the predicted
/// snapshot when available.
///
/// Returns an empty list when either side is empty or nothing aligns.
List<SifaDiff> computeSifaDiffs({
  required List<SifaSnapshot> ref,
  required List<SifaSnapshot> predicted,
}) {
  if (ref.isEmpty || predicted.isEmpty) return const <SifaDiff>[];
  final pairs = _alignSifaGroups(ref, predicted);
  if (pairs.isEmpty) return const <SifaDiff>[];

  final diffs = <SifaDiff>[];
  for (final pair in pairs) {
    final r = ref[pair.refIdx];
    final p = predicted[pair.hypIdx];
    for (final attr in sifatAttributes) {
      final expected = r.valueOf(attr);
      final actual = p.valueOf(attr);
      if (expected == null || actual == null) continue;
      if (expected == actual) continue;
      diffs.add(SifaDiff(
        chunkIdx: pair.refIdx,
        phonemeGroup: r.phonemeGroup,
        attribute: attr,
        expected: expected,
        predicted: actual,
        confidence: p.confidence[attr],
      ),);
    }
  }
  return diffs;
}

/// One alignment pair between two SifaSnapshot lists.
@immutable
class _AlignPair {
  const _AlignPair(this.refIdx, this.hypIdx);
  final int refIdx;
  final int hypIdx;
}

/// Levenshtein-aligned (refIdx, hypIdx) pairs over phonemeGroup.
///
/// Pure port of the Python `_align_sifa_groups`. Standard min-edit DP
/// followed by a back-trace that picks the match transition when the
/// strings agree and the cost-equal predecessor was the diagonal.
List<_AlignPair> _alignSifaGroups(
  List<SifaSnapshot> ref,
  List<SifaSnapshot> hyp,
) {
  final n = ref.length;
  final m = hyp.length;
  if (n == 0 || m == 0) return const <_AlignPair>[];
  final dp = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
    growable: false,
  );
  for (var i = 1; i <= n; i++) {
    dp[i][0] = i;
  }
  for (var j = 1; j <= m; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      if (ref[i - 1].phonemeGroup == hyp[j - 1].phonemeGroup) {
        dp[i][j] = dp[i - 1][j - 1];
      } else {
        final del = dp[i - 1][j] + 1;
        final ins = dp[i][j - 1] + 1;
        final sub = dp[i - 1][j - 1] + 1;
        dp[i][j] = del < ins
            ? (del < sub ? del : sub)
            : (ins < sub ? ins : sub);
      }
    }
  }
  final aligned = <_AlignPair>[];
  var i = n;
  var j = m;
  while (i > 0 && j > 0) {
    if (ref[i - 1].phonemeGroup == hyp[j - 1].phonemeGroup &&
        dp[i][j] == dp[i - 1][j - 1]) {
      aligned.add(_AlignPair(i - 1, j - 1));
      i -= 1;
      j -= 1;
    } else if (dp[i - 1][j] <= dp[i][j - 1] &&
        dp[i - 1][j] <= dp[i - 1][j - 1]) {
      i -= 1;
    } else if (dp[i][j - 1] <= dp[i - 1][j - 1]) {
      j -= 1;
    } else {
      i -= 1;
      j -= 1;
    }
  }
  return aligned.reversed.toList(growable: false);
}
