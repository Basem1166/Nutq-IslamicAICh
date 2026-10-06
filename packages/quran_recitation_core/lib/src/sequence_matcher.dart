/// A subset of Python's `difflib.SequenceMatcher` ported to Dart.
///
/// The word aligner uses this to find character-level correspondences
/// between the reference phoneme string and a heard phrase, then
/// interpolates the gaps to map every reference character to a phrase
/// character. Only the `getMatchingBlocks` API is required.
///
/// What's faithful to CPython's `difflib`
/// ──────────────────────────────────────
///   - Ratcliff–Obershelp longest-matching-block recursion.
///   - Output's terminating sentinel `(a.length, b.length, 0)`.
///   - Sort order: ascending by `(i, j)`.
///   - Adjacent-block fusion (CPython's "monotonic" pass).
///   - `autojunk=False` semantics (no automatic blacklisting of common
///     items in `b`).
///
/// What's intentionally NOT ported
/// ───────────────────────────────
///   - `get_opcodes`, `get_grouped_opcodes`, `ratio`, `quick_ratio`,
///     `real_quick_ratio` — unused by the recitation aligner.
///   - The `isjunk` callback (junk-aware match-finding) — the caller
///     is always strict.
///
/// Validated against the Python reference on representative strings —
/// see `test/sequence_matcher_test.dart`.
library;

import 'package:meta/meta.dart';

/// One matching block in [SequenceMatcher.getMatchingBlocks]:
/// `a[i..i+size]` equals `b[j..j+size]`.
@immutable
class MatchingBlock {
  /// Constructs a matching block.
  const MatchingBlock(this.i, this.j, this.size);

  /// Start index of the match in the first sequence.
  final int i;

  /// Start index of the match in the second sequence.
  final int j;

  /// Length of the match. `0` only on the terminating sentinel.
  final int size;

  @override
  String toString() => 'MatchingBlock(i: $i, j: $j, size: $size)';
}

/// Finds matching subsequences between two strings.
///
/// Construct with `SequenceMatcher(a, b)` then call [getMatchingBlocks].
/// The matcher caches the result; subsequent calls are O(1).
class SequenceMatcher {
  /// Constructs the matcher for two strings.
  SequenceMatcher(this.a, this.b);

  /// First sequence.
  final String a;

  /// Second sequence.
  final String b;

  Map<int, List<int>>? _b2j;
  List<MatchingBlock>? _matchingBlocks;

  /// Returns matching blocks in ascending `(i, j)` order, terminated by a
  /// sentinel block `(a.length, b.length, 0)`.
  ///
  /// Caches the result; subsequent calls return the same list instance.
  List<MatchingBlock> getMatchingBlocks() {
    final cached = _matchingBlocks;
    if (cached != null) return cached;
    _b2j = _buildBIndex();
    final matching = <MatchingBlock>[];
    // Recursion via an explicit work stack: each entry is the half-open
    // rectangle (alo, ahi, blo, bhi) still to process.
    final queue = <(int, int, int, int)>[(0, a.length, 0, b.length)];
    while (queue.isNotEmpty) {
      final (alo, ahi, blo, bhi) = queue.removeLast();
      final block = _findLongestMatch(alo, ahi, blo, bhi);
      if (block.size > 0) {
        matching.add(block);
        if (alo < block.i && blo < block.j) {
          queue.add((alo, block.i, blo, block.j));
        }
        if (block.i + block.size < ahi && block.j + block.size < bhi) {
          queue.add((
            block.i + block.size,
            ahi,
            block.j + block.size,
            bhi,
          ),);
        }
      }
    }
    matching.sort((x, y) {
      final di = x.i - y.i;
      if (di != 0) return di;
      final dj = x.j - y.j;
      if (dj != 0) return dj;
      return x.size - y.size;
    });
    // CPython fuses adjacent blocks: `(i, j, k1) + (i+k1, j+k1, k2)` →
    // `(i, j, k1+k2)`. Required for byte-for-byte fixture parity.
    final fused = <MatchingBlock>[];
    var ci = 0;
    var cj = 0;
    var ck = 0;
    for (final m in matching) {
      if (ci + ck == m.i && cj + ck == m.j) {
        ck += m.size;
      } else {
        if (ck > 0) fused.add(MatchingBlock(ci, cj, ck));
        ci = m.i;
        cj = m.j;
        ck = m.size;
      }
    }
    if (ck > 0) fused.add(MatchingBlock(ci, cj, ck));
    fused.add(MatchingBlock(a.length, b.length, 0));
    return _matchingBlocks = List<MatchingBlock>.unmodifiable(fused);
  }

  /// Builds the character→indices index of `b`.
  Map<int, List<int>> _buildBIndex() {
    final index = <int, List<int>>{};
    for (var j = 0; j < b.length; j++) {
      (index[b.codeUnitAt(j)] ??= <int>[]).add(j);
    }
    return index;
  }

  /// Finds the longest matching block within `a[alo..ahi]` and
  /// `b[blo..bhi]`.
  ///
  /// Direct port of CPython's `_find_longest_match` (the modern,
  /// non-junk-aware path used when `autojunk=False`).
  MatchingBlock _findLongestMatch(int alo, int ahi, int blo, int bhi) {
    final b2j = _b2j!;
    var besti = alo;
    var bestj = blo;
    var bestSize = 0;

    // j2len[j] = length of the longest match ending at (i-1, j); rebuilt
    // each iteration of i.
    var j2len = <int, int>{};
    for (var i = alo; i < ahi; i++) {
      final newJ2Len = <int, int>{};
      final js = b2j[a.codeUnitAt(i)];
      if (js != null) {
        for (final j in js) {
          if (j < blo) continue;
          if (j >= bhi) break;
          final k = (j2len[j - 1] ?? 0) + 1;
          newJ2Len[j] = k;
          if (k > bestSize) {
            besti = i - k + 1;
            bestj = j - k + 1;
            bestSize = k;
          }
        }
      }
      j2len = newJ2Len;
    }
    return MatchingBlock(besti, bestj, bestSize);
  }
}
