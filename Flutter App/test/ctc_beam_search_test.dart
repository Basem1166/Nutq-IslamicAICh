import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nutq/core/recitation/ctc_decoder.dart';

/// Phoneme vocab: 0 = blank/[PAD], 1 = A, 2 = B.
CtcDecoder _decoder() => CtcDecoder.forTesting({
      'phonemes': {0: '[PAD]', 1: 'A', 2: 'B'},
    });

/// A single timestep's logits == log of the given probabilities, so the
/// decoder's per-frame log-softmax recovers (a renormalized) [probs].
List<double> _frame(List<double> probs) =>
    probs.map((p) => math.log(p <= 0 ? 1e-9 : p)).toList(growable: false);

void main() {
  group('CTC beam search vs greedy', () {
    // Hannun's canonical example: per-frame argmax is blank at both steps, so
    // greedy collapses to "" — but the labeling "A" carries more total mass
    // (0.4·0.4 + 0.4·0.6 + 0.6·0.4 = 0.64 > 0.6·0.6 = 0.36).
    final logits = [
      _frame([0.6, 0.4, 0.0]), // blank, A, B
      _frame([0.6, 0.4, 0.0]),
    ];

    test('greedy collapses to empty, beam recovers "A"', () {
      final d = _decoder();
      expect(d.greedyDecodeResult({'phonemes': logits}).phonemes, '');

      final nbest = d.beamSearchNBest(logits);
      expect(nbest, isNotEmpty);
      expect(nbest.first.tokenIds, [1]); // "A"
    });

    test('N-best is ranked by log-prob (rescoring has alternatives)', () {
      final d = _decoder();
      final nbest = d.beamSearchNBest(logits, nBest: 4);
      expect(nbest.length, greaterThanOrEqualTo(2));
      for (var i = 1; i < nbest.length; i++) {
        expect(nbest[i - 1].logProb, greaterThanOrEqualTo(nbest[i].logProb));
      }
    });
  });

  group('forced alignment', () {
    test('path collapses back to its target', () {
      final d = _decoder();
      final logits = [
        _frame([0.6, 0.4, 0.0]),
        _frame([0.6, 0.4, 0.0]),
        _frame([0.1, 0.1, 0.8]), // B
      ];
      final path = d.forcedAlignPath(logits, [1, 2]); // A, B
      // Collapse consecutive duplicates, drop blank (0).
      final collapsed = <int>[];
      var prev = -1;
      for (final id in path) {
        if (id != prev && id != 0) collapsed.add(id);
        prev = id;
      }
      expect(collapsed, [1, 2]);
    });

    test('decodeResultFor renders the forced-aligned target string', () {
      final d = _decoder();
      final logits = [
        _frame([0.6, 0.4, 0.0]),
        _frame([0.1, 0.1, 0.8]),
      ];
      final res = d.decodeResultFor({'phonemes': logits}, [1, 2]);
      expect(res.phonemes, 'AB');
      expect(res.segments.map((s) => s.phonemeToken).join(), 'AB');
    });
  });

  group('greedy decode result consistency', () {
    test('phonemes equals legacy decodeLevel output', () {
      final d = _decoder();
      final logits = [
        _frame([0.1, 0.8, 0.1]), // A
        _frame([0.1, 0.8, 0.1]), // A (collapses)
        _frame([0.7, 0.2, 0.1]), // blank
        _frame([0.1, 0.1, 0.8]), // B
      ];
      final res = d.greedyDecodeResult({'phonemes': logits});
      expect(res.phonemes, d.decodeLevel('phonemes', logits));
      expect(res.phonemes, 'AB');
    });
  });
}
