import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nutq/core/recitation/grouped_recitation_scorer.dart';

// Handy code points used across the tests.
const String _baa = 'ب'; // ب  (core)
const String _taa = 'ت'; // ت  (core)
const String _kaf = 'ك'; // ك  (core)
const String _alif = 'ا'; // ا  (core, madd)
const String _yaaMadd = 'ۦ'; // ۦ  (core, madd)
const String _fatha = 'َ'; // َ  (residual)
const String _damma = 'ُ'; // ُ  (residual)

void main() {
  group('PhonemeGroup.tag', () {
    test('truth table', () {
      expect(PhonemeGroup(ref: _baa, out: _baa).tag, 'exact');
      expect(PhonemeGroup(ref: _baa, out: '').tag, 'delete');
      expect(PhonemeGroup(ref: '', out: _baa).tag, 'insert');
      expect(PhonemeGroup(ref: _baa, out: _taa).tag, 'partial');
    });
  });

  group('chunkPhonemeUnits', () {
    test('core + single residual per chunk', () {
      expect(chunkPhonemeUnits('$_baa$_fatha$_taa$_damma'),
          ['$_baa$_fatha', '$_taa$_damma']);
    });

    test('drops word-separating spaces', () {
      expect(chunkPhonemeUnits(' $_baa$_fatha $_taa '),
          ['$_baa$_fatha', _taa]);
    });

    test('drops an orphan leading residual', () {
      expect(chunkPhonemeUnits('$_fatha$_baa'), [_baa]);
    });

    test('groups a run of the identical core letter', () {
      expect(chunkPhonemeUnits('$_baa$_baa$_fatha'), ['$_baa$_baa$_fatha']);
    });
  });

  group('segmentGroups', () {
    test('EQUAL only -> all exact, indices aligned', () {
      final groups = segmentGroups(
        [_baa, _taa, _kaf],
        [_baa, _taa, _kaf],
        [Diff(DIFF_EQUAL, '$_baa$_taa$_kaf')],
      );
      expect(groups.map((g) => g.tag), ['exact', 'exact', 'exact']);
      expect(groups.map((g) => g.refIdx), [0, 1, 2]);
      expect(groups.map((g) => g.outIdx), [0, 1, 2]);
    });

    test('pure DELETE -> missing groups (out empty)', () {
      final groups = segmentGroups(
        [_baa, _taa],
        const <String>[],
        [Diff(DIFF_DELETE, '$_baa$_taa')],
      );
      expect(groups.map((g) => g.tag), ['delete', 'delete']);
      expect(groups.every((g) => g.out.isEmpty && g.outIdx == -1), isTrue);
    });

    test('pure INSERT -> extra groups (ref empty)', () {
      final groups = segmentGroups(
        const <String>[],
        [_baa, _taa],
        [Diff(DIFF_INSERT, '$_baa$_taa')],
      );
      expect(groups.map((g) => g.tag), ['insert', 'insert']);
      expect(groups.every((g) => g.ref.isEmpty && g.refIdx == -1), isTrue);
    });

    test('substitution via EQUAL+DELETE merges into one partial', () {
      // ref chunk "بَ" (core+harakat) vs predicted "ب": dmp emits EQUAL "ب"
      // then DELETE "َ".
      final refChunk = '$_baa$_fatha';
      final segmented = segmentGroups(
        [refChunk],
        [_baa],
        [Diff(DIFF_EQUAL, _baa), Diff(DIFF_DELETE, _fatha)],
      );
      final merged = mergeSamePhonemeGroup(segmented);
      expect(merged.length, 1);
      expect(merged.single.tag, 'partial');
      expect(merged.single.ref, refChunk);
      expect(merged.single.out, _baa);
      expect(merged.single.refIdx, 0);
      expect(merged.single.outIdx, 0);
    });

    test('does not index past an exhausted out list', () {
      // More ref groups than predicted chunks: extra refs become deletes.
      final groups = segmentGroups(
        [_baa, _taa, _kaf],
        [_baa],
        [Diff(DIFF_EQUAL, _baa), Diff(DIFF_DELETE, '$_taa$_kaf')],
      );
      expect(groups.map((g) => g.tag), ['exact', 'delete', 'delete']);
    });
  });

  group('mergeSamePhonemeGroup', () {
    test('merges insert+delete when ref contains out', () {
      final merged = mergeSamePhonemeGroup([
        PhonemeGroup(out: _baa, outIdx: 0),
        PhonemeGroup(ref: '$_baa$_fatha', refIdx: 0),
      ]);
      expect(merged.length, 1);
      expect(merged.single.tag, 'partial');
      expect(merged.single.ref, '$_baa$_fatha');
      expect(merged.single.out, _baa);
    });

    test('does not merge across an empty (delete) side', () {
      // exact group followed by a delete must stay two groups.
      final merged = mergeSamePhonemeGroup([
        PhonemeGroup(ref: _baa, out: _baa, refIdx: 0, outIdx: 0),
        PhonemeGroup(ref: _taa, refIdx: 1),
      ]);
      expect(merged.length, 2);
      expect(merged.map((g) => g.tag), ['exact', 'delete']);
    });

    test('does not merge unrelated adjacent groups', () {
      final merged = mergeSamePhonemeGroup([
        PhonemeGroup(ref: _baa, refIdx: 0),
        PhonemeGroup(out: _taa, outIdx: 0),
      ]);
      expect(merged.length, 2);
      expect(merged.map((g) => g.tag), ['delete', 'insert']);
    });
  });

  group('groupIsExactish (madd special case)', () {
    test('exact is always exactish', () {
      expect(groupIsExactish(PhonemeGroup(ref: _baa, out: _baa)), isTrue);
    });

    test('partial starting with a madd letter counts as exact', () {
      expect(
          groupIsExactish(PhonemeGroup(ref: '$_alif$_fatha', out: _alif)),
          isTrue);
      expect(
          groupIsExactish(PhonemeGroup(ref: '$_yaaMadd$_fatha', out: _yaaMadd)),
          isTrue);
    });

    test('partial starting with a non-madd letter is not exact', () {
      expect(
          groupIsExactish(PhonemeGroup(ref: '$_baa$_fatha', out: _baa)),
          isFalse);
    });

    test('insert and delete are never exactish', () {
      expect(groupIsExactish(PhonemeGroup(ref: _baa, out: '')), isFalse);
      expect(groupIsExactish(PhonemeGroup(ref: '', out: _baa)), isFalse);
    });
  });
}
