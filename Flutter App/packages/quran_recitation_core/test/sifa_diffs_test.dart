import 'package:quran_recitation_core/quran_recitation_core.dart';
import 'package:test/test.dart';

/// Builds a snapshot for [group] setting only the attributes given in
/// [attrs] (keyed by their [sifatAttributes] name). Keeps tests terse.
SifaSnapshot _snap(
  String group,
  Map<String, String> attrs, {
  Map<String, double> confidence = const <String, double>{},
}) =>
    SifaSnapshot(
      phonemeGroup: group,
      hamsOrJahr: attrs['hams_or_jahr'],
      shiddaOrRakhawa: attrs['shidda_or_rakhawa'],
      tafkheemOrTaqeeq: attrs['tafkheem_or_taqeeq'],
      itbaq: attrs['itbaq'],
      safeer: attrs['safeer'],
      qalqla: attrs['qalqla'],
      tikraar: attrs['tikraar'],
      tafashie: attrs['tafashie'],
      istitala: attrs['istitala'],
      ghonna: attrs['ghonna'],
      confidence: confidence,
    );

void main() {
  group('computeSifaDiffs', () {
    test('returns no diffs when aligned chunks agree', () {
      final ref = <SifaSnapshot>[
        _snap('قَ', {'hams_or_jahr': 'jahr'}),
        _snap('لَ', {'hams_or_jahr': 'jahr'}),
      ];
      final pred = <SifaSnapshot>[
        _snap('قَ', {'hams_or_jahr': 'jahr'}),
        _snap('لَ', {'hams_or_jahr': 'jahr'}),
      ];

      expect(computeSifaDiffs(ref: ref, predicted: pred), isEmpty);
    });

    test('labels a real mismatch by the reference chunk', () {
      final ref = <SifaSnapshot>[
        _snap('قَ', {'hams_or_jahr': 'jahr'}),
        _snap('لَ', {'hams_or_jahr': 'jahr'}),
      ];
      final pred = <SifaSnapshot>[
        _snap('قَ', {'hams_or_jahr': 'jahr'}),
        _snap('لَ', {'hams_or_jahr': 'hams'},
            confidence: {'hams_or_jahr': 0.8},),
      ];

      final diffs = computeSifaDiffs(ref: ref, predicted: pred);
      expect(diffs, hasLength(1));
      expect(diffs.single.chunkIdx, 1);
      expect(diffs.single.phonemeGroup, 'لَ');
      expect(diffs.single.attribute, 'hams_or_jahr');
      expect(diffs.single.expected, 'jahr');
      expect(diffs.single.predicted, 'hams');
      expect(diffs.single.confidence, 0.8);
    });

    test(
        'leading spillover chunk produces no spurious diff and no '
        'wrong-word label (Bug C regression)', () {
      // Reference word: three chunks.
      final ref = <SifaSnapshot>[
        _snap('قَ', {'hams_or_jahr': 'jahr'}),
        _snap('اا', {'ghonna': 'not_maghnoon'}),
        _snap('لَ', {'hams_or_jahr': 'jahr'}),
      ];
      // Predicted slice carries a leading spillover chunk ('خ') from the
      // previous word at a streaming seam. The real chunks all agree with
      // the reference.
      final pred = <SifaSnapshot>[
        _snap('خ', {'hams_or_jahr': 'hams'}), // spillover — not in ref
        _snap('قَ', {'hams_or_jahr': 'jahr'}),
        _snap('اا', {'ghonna': 'not_maghnoon'}),
        _snap('لَ', {'hams_or_jahr': 'jahr'}),
      ];

      // Index-zipping (the old behaviour) would pair قَ↔خ, اا↔قَ, لَ↔اا and
      // surface spurious diffs labelled with the wrong group. Alignment
      // pairs only equal groups, so there are no diffs at all.
      expect(computeSifaDiffs(ref: ref, predicted: pred), isEmpty);
    });

    test(
        'with leading spillover, a genuine mismatch is still labelled by '
        'the correct reference chunk', () {
      final ref = <SifaSnapshot>[
        _snap('قَ', {'hams_or_jahr': 'jahr'}),
        _snap('لَ', {'hams_or_jahr': 'jahr'}),
      ];
      final pred = <SifaSnapshot>[
        _snap('خ', {'hams_or_jahr': 'hams'}), // spillover
        _snap('قَ', {'hams_or_jahr': 'jahr'}),
        _snap('لَ', {'hams_or_jahr': 'hams'}), // genuine mismatch
      ];

      final diffs = computeSifaDiffs(ref: ref, predicted: pred);
      expect(diffs, hasLength(1));
      // chunkIdx is the REFERENCE index of لَ (1), not a predicted index (2).
      expect(diffs.single.chunkIdx, 1);
      expect(diffs.single.phonemeGroup, 'لَ');
      expect(diffs.single.expected, 'jahr');
      expect(diffs.single.predicted, 'hams');
    });

    test('skips attributes that either side leaves unset (null)', () {
      final ref = <SifaSnapshot>[
        _snap('رَ', {'tikraar': 'mokarar'}),
      ];
      // Predicted leaves tikraar unset → no comparison, no diff.
      final pred = <SifaSnapshot>[
        _snap('رَ', {'hams_or_jahr': 'jahr'}),
      ];

      expect(computeSifaDiffs(ref: ref, predicted: pred), isEmpty);
    });

    test('returns empty for empty inputs', () {
      expect(
        computeSifaDiffs(ref: const [], predicted: const []),
        isEmpty,
      );
      expect(
        computeSifaDiffs(
          ref: const [],
          predicted: [_snap('قَ', {'hams_or_jahr': 'jahr'})],
        ),
        isEmpty,
      );
      expect(
        computeSifaDiffs(
          ref: [_snap('قَ', {'hams_or_jahr': 'jahr'})],
          predicted: const [],
        ),
        isEmpty,
      );
    });
  });
}
