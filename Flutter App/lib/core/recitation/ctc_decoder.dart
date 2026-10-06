import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

/// Greedy CTC decoding for the Mualem multilevel-CTC outputs.
///
/// Loads `vocab.json` (the per-level `{token: id}` maps) and decodes each
/// head's `[time][vocab]` logits exactly like the Python reference
/// `ctc_greedy_decode` in `New folder/run_model.py`:
///   argmax per timestep -> collapse consecutive duplicates -> drop blank (0)
///   -> map id -> token -> join.
class CtcDecoder {
  static const String vocabAsset = 'assets/models/vocab.json';
  static const int blankId = 0; // [PAD] / CTC blank

  /// level name -> (id -> token)
  final Map<String, Map<int, String>> _idToToken;

  CtcDecoder._(this._idToToken);

  /// Builds a decoder from an explicit `level -> (id -> token)` map, for
  /// pure-Dart unit tests that can't load the `vocab.json` asset.
  @visibleForTesting
  CtcDecoder.forTesting(Map<String, Map<int, String>> idToToken)
      : _idToToken = idToToken;

  /// The level names present in the vocab (e.g. phonemes, ghonna, ...).
  Iterable<String> get levels => _idToToken.keys;

  /// Loads and inverts `vocab.json` from assets (root isolate only).
  static Future<CtcDecoder> load() async {
    final jsonStr = await rootBundle.loadString(vocabAsset);
    return fromVocabJson(jsonStr);
  }

  /// Builds a decoder from the raw `vocab.json` text — safe in any isolate.
  /// The worker-isolate path reads the asset on the root isolate and passes
  /// the string here.
  static CtcDecoder fromVocabJson(String jsonStr) {
    final raw = json.decode(jsonStr) as Map<String, dynamic>;
    final idToToken = <String, Map<int, String>>{};
    raw.forEach((level, tokenMap) {
      final inverted = <int, String>{};
      (tokenMap as Map<String, dynamic>).forEach((token, id) {
        inverted[(id as num).toInt()] = token;
      });
      idToToken[level] = inverted;
    });
    return CtcDecoder._(idToToken);
  }

  /// Maps an id to its token for [level] (or null if unknown). Used by the
  /// scorer to translate per-frame argmax ids into vocab tokens.
  String? tokenFor(String level, int id) => _idToToken[level]?[id];

  /// Decodes every level in [logitsByLevel] -> `{ level: decodedString }`.
  Map<String, String> decodeAll(Map<String, List<List<double>>> logitsByLevel) {
    final out = <String, String>{};
    logitsByLevel.forEach((level, logits) {
      out[level] = decodeLevel(level, logits);
    });
    return out;
  }

  /// Segments the phoneme head's frame path into one [PhonemeSegment] per
  /// emitted phoneme, reading each sifat head's majority class over the
  /// segment's frames.
  ///
  /// Why: each head is CTC-decoded independently into a collapsed string of a
  /// different length, so the sifat heads can't be zipped to the phonemes. To
  /// get a sifat vector *aligned to each phoneme*, we use the phoneme head's
  /// argmax path to carve the time axis into phoneme spans, then take the mode
  /// (majority non-blank class) of every sifat head over each span.
  List<PhonemeSegment> segmentByPhoneme(
    Map<String, List<List<double>>> logitsByLevel,
  ) {
    final phonemeLogits = logitsByLevel['phonemes'];
    if (phonemeLogits == null || phonemeLogits.isEmpty) {
      return const <PhonemeSegment>[];
    }
    // Greedy per-frame argmax path for the phoneme head.
    final phonemePath = List<int>.generate(
        phonemeLogits.length, (i) => _argmax(phonemeLogits[i]));
    return _segmentsFromPhonemePath(logitsByLevel, phonemePath);
  }

  /// Carves a per-frame phoneme-id [phonemePath] into one [PhonemeSegment] per
  /// emitted (collapsed, non-blank) phoneme, reading each sifat head's majority
  /// class over the segment's frames. The path may come from greedy argmax
  /// ([segmentByPhoneme]) or from a beam hypothesis' forced alignment
  /// ([decodeResultFor]) — both routes produce identical-shaped segments so the
  /// scorers stay agnostic to which decode produced them.
  List<PhonemeSegment> _segmentsFromPhonemePath(
    Map<String, List<List<double>>> logitsByLevel,
    List<int> phonemePath,
  ) {
    final t = phonemePath.length;
    if (t == 0) return const <PhonemeSegment>[];

    final sifatPaths = <String, List<int>>{};
    logitsByLevel.forEach((level, logits) {
      if (level == 'phonemes') return;
      final len = logits.length < t ? logits.length : t;
      sifatPaths[level] =
          List<int>.generate(len, (i) => _argmax(logits[i]), growable: false);
    });

    final segments = <PhonemeSegment>[];
    var i = 0;
    while (i < t) {
      final id = phonemePath[i];
      final start = i;
      while (i < t && phonemePath[i] == id) {
        i++;
      }
      final end = i; // exclusive
      if (id == blankId) continue;

      final sifat = <String, String>{};
      sifatPaths.forEach((level, path) {
        final token = _modeToken(level, path, start, end);
        if (token != null) sifat[level] = token;
      });

      segments.add(PhonemeSegment(
        phonemeId: id,
        phonemeToken: _idToToken['phonemes']?[id] ?? '[$id]',
        startFrame: start,
        endFrame: end,
        sifat: sifat,
      ));
    }
    return segments;
  }

  // --- Phoneme decode results (greedy / beam) -------------------------------

  /// Greedy decode: argmax-collapse the phoneme head and read sifat off the same
  /// frame path. `result.phonemes` is byte-for-byte what `decodeLevel('phonemes',
  /// …)` returns, so this preserves the app's existing behavior.
  PhonemeDecodeResult greedyDecodeResult(
    Map<String, List<List<double>>> logitsByLevel,
  ) {
    final segments = segmentByPhoneme(logitsByLevel);
    return PhonemeDecodeResult(
      phonemes: segments.map((s) => s.phonemeToken).join(),
      segments: segments,
    );
  }

  /// Builds a [PhonemeDecodeResult] for an arbitrary [phonemeTokenIds] sequence
  /// (e.g. a beam-search hypothesis) by CTC forced-aligning it back to the
  /// phoneme logits, then segmenting that path so the sifat stay consistent with
  /// the (possibly non-greedy) phoneme string.
  PhonemeDecodeResult decodeResultFor(
    Map<String, List<List<double>>> logitsByLevel,
    List<int> phonemeTokenIds,
  ) {
    final phonemeLogits = logitsByLevel['phonemes'];
    if (phonemeLogits == null || phonemeLogits.isEmpty) {
      return const PhonemeDecodeResult(phonemes: '', segments: <PhonemeSegment>[]);
    }
    final path = forcedAlignPath(phonemeLogits, phonemeTokenIds);
    final segments = _segmentsFromPhonemePath(logitsByLevel, path);
    return PhonemeDecodeResult(
      phonemes: segments.map((s) => s.phonemeToken).join(),
      segments: segments,
    );
  }

  /// CTC **prefix beam search** over the phoneme head's `[time][vocab]` logits,
  /// returning up to [nBest] hypotheses (collapsed token-id sequences) ranked by
  /// log-probability. Operates in log space and applies a per-frame log-softmax
  /// first (the model emits raw, unnormalized logits). Standard
  /// Graves/Hannun formulation: each prefix tracks the probability of paths
  /// ending in blank (`pb`) vs ending in a real token (`pnb`).
  List<BeamHypothesis> beamSearchNBest(
    List<List<double>> phonemeLogits, {
    int beamWidth = 50,
    int nBest = 8,
  }) {
    if (phonemeLogits.isEmpty) return const <BeamHypothesis>[];
    const ninf = double.negativeInfinity;

    var beam = <String, _BeamEntry>{
      '': _BeamEntry(const <int>[], 0.0, ninf),
    };

    for (final step in phonemeLogits) {
      final lp = _logSoftmax(step);
      final next = <String, _BeamEntry>{};
      _BeamEntry entryFor(String key, List<int> prefix) =>
          next[key] ??= _BeamEntry(prefix, ninf, ninf);

      beam.forEach((key, e) {
        final pTotal = _logSumExp(e.pb, e.pnb);

        // Emit blank: stays the same prefix, now ending in blank.
        final blankE = entryFor(key, e.prefix);
        blankE.pb = _logSumExp(blankE.pb, pTotal + lp[blankId]);

        final last = e.prefix.isEmpty ? -1 : e.prefix.last;
        for (var c = 1; c < lp.length; c++) {
          final addLp = lp[c];
          if (c == last) {
            // Repeat of the last token: collapses onto the same prefix (only the
            // non-blank-ending mass can repeat without a separating blank)...
            final sameE = entryFor(key, e.prefix);
            sameE.pnb = _logSumExp(sameE.pnb, e.pnb + addLp);
            // ...while the blank-ending mass genuinely extends the prefix.
            final ext = List<int>.from(e.prefix)..add(c);
            final extE = entryFor('$key,$c', ext);
            extE.pnb = _logSumExp(extE.pnb, e.pb + addLp);
          } else {
            final ext = List<int>.from(e.prefix)..add(c);
            final extE = entryFor('$key,$c', ext);
            extE.pnb = _logSumExp(extE.pnb, pTotal + addLp);
          }
        }
      });

      final entries = next.entries.toList()
        ..sort((a, b) => _logSumExp(b.value.pb, b.value.pnb)
            .compareTo(_logSumExp(a.value.pb, a.value.pnb)));
      beam = <String, _BeamEntry>{};
      for (var i = 0; i < entries.length && i < beamWidth; i++) {
        beam[entries[i].key] = entries[i].value;
      }
    }

    final finals = beam.values.toList()
      ..sort((a, b) =>
          _logSumExp(b.pb, b.pnb).compareTo(_logSumExp(a.pb, a.pnb)));
    final out = <BeamHypothesis>[];
    for (var i = 0; i < finals.length && i < nBest; i++) {
      out.add(BeamHypothesis(
        List<int>.unmodifiable(finals[i].prefix),
        _logSumExp(finals[i].pb, finals[i].pnb),
      ));
    }
    return out;
  }

  /// CTC Viterbi forced alignment of a collapsed [targetIds] sequence onto the
  /// `[time][vocab]` [phonemeLogits]. Returns a per-frame phoneme-id path that,
  /// when run through the usual collapse+drop-blank, reproduces [targetIds]. Used
  /// to derive frame spans (hence sifat) for a beam hypothesis.
  List<int> forcedAlignPath(
    List<List<double>> phonemeLogits,
    List<int> targetIds,
  ) {
    final tFrames = phonemeLogits.length;
    if (tFrames == 0) return const <int>[];
    if (targetIds.isEmpty) return List<int>.filled(tFrames, blankId);

    // Blank-extended label sequence: blank, l0, blank, l1, ..., blank.
    final ext = <int>[];
    for (final id in targetIds) {
      ext..add(blankId)..add(id);
    }
    ext.add(blankId);
    final s = ext.length;
    const ninf = double.negativeInfinity;

    final dp = List.generate(tFrames, (_) => List<double>.filled(s, ninf));
    final back = List.generate(tFrames, (_) => List<int>.filled(s, -1));

    final lp0 = _logSoftmax(phonemeLogits[0]);
    dp[0][0] = lp0[ext[0]];
    if (s > 1) dp[0][1] = lp0[ext[1]];

    for (var t = 1; t < tFrames; t++) {
      final lp = _logSoftmax(phonemeLogits[t]);
      for (var i = 0; i < s; i++) {
        var best = dp[t - 1][i];
        var bestPrev = i;
        if (i >= 1 && dp[t - 1][i - 1] > best) {
          best = dp[t - 1][i - 1];
          bestPrev = i - 1;
        }
        final canSkip = i >= 2 && ext[i] != blankId && ext[i] != ext[i - 2];
        if (canSkip && dp[t - 1][i - 2] > best) {
          best = dp[t - 1][i - 2];
          bestPrev = i - 2;
        }
        if (best == ninf) continue;
        dp[t][i] = best + lp[ext[i]];
        back[t][i] = bestPrev;
      }
    }

    var endI = s - 1;
    if (s >= 2 && dp[tFrames - 1][s - 2] > dp[tFrames - 1][s - 1]) endI = s - 2;

    final pathExt = List<int>.filled(tFrames, 0);
    var cur = endI;
    for (var t = tFrames - 1; t >= 0; t--) {
      pathExt[t] = cur;
      final prev = back[t][cur];
      if (prev >= 0) cur = prev;
    }
    return List<int>.generate(tFrames, (t) => ext[pathExt[t]], growable: false);
  }

  static List<double> _logSoftmax(List<double> v) {
    if (v.isEmpty) return const <double>[];
    var maxV = v[0];
    for (final x in v) {
      if (x > maxV) maxV = x;
    }
    var sum = 0.0;
    for (final x in v) {
      sum += math.exp(x - maxV);
    }
    final logSum = maxV + math.log(sum);
    return List<double>.generate(v.length, (i) => v[i] - logSum,
        growable: false);
  }

  static double _logSumExp(double a, double b) {
    if (a == double.negativeInfinity) return b;
    if (b == double.negativeInfinity) return a;
    final m = a > b ? a : b;
    return m + math.log(math.exp(a - m) + math.exp(b - m));
  }

  /// Majority (mode) non-blank token for [level] over frames `[start, end)`.
  String? _modeToken(String level, List<int> path, int start, int end) {
    final counts = <int, int>{};
    final upper = end < path.length ? end : path.length;
    for (var i = start; i < upper; i++) {
      final id = path[i];
      if (id == blankId) continue;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    var bestId = -1;
    var bestCount = -1;
    counts.forEach((id, c) {
      if (c > bestCount) {
        bestCount = c;
        bestId = id;
      }
    });
    return _idToToken[level]?[bestId];
  }

  /// Greedy-decodes the `[frameStart, frameEnd)` slice of a head's
  /// `[time][vocab]` logits into discrete tokens.
  ///
  /// This is the streaming counterpart of [decodeLevel]: instead of a joined
  /// string it returns one [CtcToken] per emitted symbol, carrying the peak
  /// frame, the collapsed run's frame span, and the peak softmax probability.
  ///
  /// IMPORTANT — slice *then* collapse: the CTC run-collapse runs strictly
  /// inside `[frameStart, frameEnd)`, so a run straddling the slice boundary is
  /// cut at the edge (the in-range part becomes its own token). This mirrors
  /// the Python reference `GreedyCTCDecoder.__call__`, which slices
  /// `logits[frame_start:frame_end]` before argmax/collapse and reports each
  /// frame as `local_peak + frame_start`. The adaptive streamer's seam-recovery
  /// dedup (suffix-prefix matcher) is built around these boundary-cut token
  /// lists; collapsing over the *whole* window first and post-filtering by peak
  /// (as a prior version did) hands the matcher a different token shape than
  /// Python's, so re-decoded overlap runs slip through as duplicate tokens
  /// (`ممم`, `ۦۦۦۦ`) and boundary-straddling runs mis-substitute.
  ///
  /// `frameStart` / `frameEnd` are clamped to `[0, time]`. Passing the full
  /// range (`0`, `logits.length`) decodes everything.
  List<CtcToken> decodeTokens(
    List<List<double>> logits, {
    required int frameStart,
    required int frameEnd,
  }) {
    final t = logits.length;
    if (t == 0) return const <CtcToken>[];
    final lo = frameStart < 0 ? 0 : frameStart;
    final hi = frameEnd > t ? t : frameEnd;
    if (lo >= hi) return const <CtcToken>[];

    // Argmax path over the SLICE only (matches Python's
    // `logits[frame_start:frame_end]` before collapse).
    final path = List<int>.generate(hi - lo, (k) => _argmax(logits[lo + k]),
        growable: false);

    final tokens = <CtcToken>[];
    var i = 0; // index into `path` (0 == absolute frame `lo`)
    while (i < path.length) {
      final id = path[i];
      final startLocal = i;
      while (i < path.length && path[i] == id) {
        i++;
      }
      final endLocal = i; // exclusive
      if (id == blankId) continue;

      // Absolute frame span of this collapsed run within the slice.
      final start = lo + startLocal;
      final end = lo + endLocal;

      // Peak = frame within the run with the largest logit for this id.
      var peak = start;
      var peakVal = logits[start][id];
      for (var f = start + 1; f < end; f++) {
        final v = logits[f][id];
        if (v > peakVal) {
          peakVal = v;
          peak = f;
        }
      }

      tokens.add(CtcToken(
        id: id,
        peakFrame: peak,
        startFrame: start,
        endFrame: end,
        prob: _softmaxProb(logits[peak], id),
      ));
    }
    return tokens;
  }

  /// Majority non-blank class for [level] over frames `[start, end)`, with a
  /// representative softmax probability.
  ///
  /// Used to assign one sifat label (and confidence) to a phoneme chunk that
  /// spans those frames. Falls back to the blank id only when every frame in
  /// the span argmaxes to blank. `start`/`end` are clamped to the logits.
  CtcClass modeClassOverSpan(
    List<List<double>> logits,
    int start,
    int end,
  ) {
    final lo = start < 0 ? 0 : start;
    final hi = end > logits.length ? logits.length : end;
    if (hi <= lo) return const CtcClass(id: blankId, prob: 0.0);

    final counts = <int, int>{};
    for (var f = lo; f < hi; f++) {
      final id = _argmax(logits[f]);
      if (id == blankId) continue;
      counts[id] = (counts[id] ?? 0) + 1;
    }
    if (counts.isEmpty) {
      // All-blank span: report blank with the mean blank probability.
      var sum = 0.0;
      for (var f = lo; f < hi; f++) {
        sum += _softmaxProb(logits[f], blankId);
      }
      return CtcClass(id: blankId, prob: sum / (hi - lo));
    }

    var bestId = blankId;
    var bestCount = -1;
    counts.forEach((id, c) {
      if (c > bestCount) {
        bestCount = c;
        bestId = id;
      }
    });

    // Mean softmax prob of the chosen class over frames where it's argmax.
    var sum = 0.0;
    var n = 0;
    for (var f = lo; f < hi; f++) {
      if (_argmax(logits[f]) == bestId) {
        sum += _softmaxProb(logits[f], bestId);
        n++;
      }
    }
    return CtcClass(id: bestId, prob: n == 0 ? 0.0 : sum / n);
  }

  /// Windowed max-pooling over frames `[start, end)`.
  ///
  /// For each vocab index, it takes the maximum logit across the span, then
  /// returns the argmax of those pooled logits. Rescues sifat labels for short
  /// phonemes by ensuring the peak frame's high-confidence prediction is
  /// heard.
  CtcClass maxPoolClassOverSpan(
    List<List<double>> logits,
    int start,
    int end,
  ) {
    final lo = start < 0 ? 0 : start;
    final hi = end > logits.length ? logits.length : end;
    if (hi <= lo || logits.isEmpty) {
      return const CtcClass(id: blankId, prob: 0.0);
    }

    final vocabSize = logits[0].length;
    final pooled = List<double>.filled(vocabSize, double.negativeInfinity);

    for (var f = lo; f < hi; f++) {
      final step = logits[f];
      for (var v = 0; v < vocabSize; v++) {
        if (step[v] > pooled[v]) {
          pooled[v] = step[v];
        }
      }
    }

    // Argmax over non-blank ids (1..V-1).
    var bestId = blankId;
    var bestVal = double.negativeInfinity;
    for (var v = 1; v < vocabSize; v++) {
      if (pooled[v] > bestVal) {
        bestVal = pooled[v];
        bestId = v;
      }
    }

    // If no non-blank found (all pooled values are -inf or blank is higher),
    // report blank with its own pooled value.
    if (bestId == blankId) {
      return CtcClass(id: blankId, prob: _softmaxProb(pooled, blankId));
    }

    return CtcClass(id: bestId, prob: _softmaxProb(pooled, bestId));
  }

  /// Numerically-stable softmax probability of class [id] at one frame.
  static double _softmaxProb(List<double> logits, int id) {
    if (logits.isEmpty) return 0.0;
    var maxV = logits[0];
    for (var i = 1; i < logits.length; i++) {
      if (logits[i] > maxV) maxV = logits[i];
    }
    var sum = 0.0;
    for (final v in logits) {
      sum += math.exp(v - maxV);
    }
    if (sum <= 0) return 0.0;
    return math.exp(logits[id] - maxV) / sum;
  }

  /// Greedy-decodes a single head's `[time][vocab]` logits to a token string.
  String decodeLevel(String level, List<List<double>> logits) {
    final idToToken = _idToToken[level];
    if (idToToken == null) return '';

    final buf = StringBuffer();
    var prev = -1;
    for (final step in logits) {
      final id = _argmax(step);
      if (id != prev) {
        if (id != blankId) {
          buf.write(idToToken[id] ?? '[$id]');
        }
        prev = id;
      }
    }
    return buf.toString();
  }

  static int _argmax(List<double> v) {
    var best = 0;
    var bestVal = v.isEmpty ? double.negativeInfinity : v[0];
    for (var i = 1; i < v.length; i++) {
      if (v[i] > bestVal) {
        bestVal = v[i];
        best = i;
      }
    }
    return best;
  }
}

/// Which CTC decode feeds the scorers. [greedy] is per-frame argmax (the
/// original behavior); [beam] is the top prefix-beam hypothesis; [beamRescored]
/// is the beam N-best hypothesis closest (min edit distance) to the expected
/// phonemes — reranking only, so genuine recitation errors are never masked.
enum DecodeMode { greedy, beam, beamRescored }

/// A decoded phoneme string paired with its frame-consistent per-phoneme
/// [segments] (carrying sifat). Both fields derive from one phoneme-id path, so
/// `phonemes == segments.map((s) => s.phonemeToken).join()` always holds. This
/// is the single input both scorers consume, independent of [DecodeMode].
class PhonemeDecodeResult {
  const PhonemeDecodeResult({required this.phonemes, required this.segments});

  final String phonemes;
  final List<PhonemeSegment> segments;
}

/// One CTC prefix-beam-search hypothesis: a collapsed phoneme-id sequence and
/// its total log-probability.
class BeamHypothesis {
  const BeamHypothesis(this.tokenIds, this.logProb);

  final List<int> tokenIds;
  final double logProb;
}

/// Mutable per-prefix beam state: probability of paths ending in blank (`pb`)
/// vs ending in a real (non-blank) token (`pnb`), in log space.
class _BeamEntry {
  _BeamEntry(this.prefix, this.pb, this.pnb);

  final List<int> prefix;
  double pb;
  double pnb;
}

/// One emitted phoneme from the model's frame path, with the sifat-head class
/// (raw Arabic vocab token) that was active during its frames.
class PhonemeSegment {
  const PhonemeSegment({
    required this.phonemeId,
    required this.phonemeToken,
    required this.startFrame,
    required this.endFrame,
    required this.sifat,
  });

  final int phonemeId;
  final String phonemeToken;
  final int startFrame;
  final int endFrame; // exclusive

  /// sifat head name -> majority class token (Arabic, e.g. `[مفخم]`).
  final Map<String, String> sifat;
}

/// One symbol emitted by [CtcDecoder.decodeTokens]: a collapsed CTC run with
/// its peak frame, run span, and peak softmax probability.
class CtcToken {
  const CtcToken({
    required this.id,
    required this.peakFrame,
    required this.startFrame,
    required this.endFrame,
    required this.prob,
  });

  /// Vocab id of the emitted token.
  final int id;

  /// Frame within the run with the highest logit for [id]. Reported in the
  /// same frame coordinates the streamer uses for `frameStart`/`frameEnd`.
  final int peakFrame;

  /// First frame of the collapsed run (inclusive).
  final int startFrame;

  /// One past the last frame of the collapsed run (exclusive).
  final int endFrame;

  /// Softmax probability of [id] at [peakFrame].
  final double prob;
}

/// A single decoded class plus its probability, returned by
/// [CtcDecoder.modeClassOverSpan].
class CtcClass {
  const CtcClass({required this.id, required this.prob});

  /// Vocab id of the majority class.
  final int id;

  /// Representative softmax probability of that class.
  final double prob;
}
