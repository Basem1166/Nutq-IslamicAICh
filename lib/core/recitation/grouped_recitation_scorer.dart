import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../phonetizer_service.dart';
import 'ctc_decoder.dart';
import 'recitation_scorer.dart';
import 'sifat_mapping.dart';

/// An opt-in, group-based alternative to [RecitationScorer], ported from the
/// Python reference comparison. Where [RecitationScorer] runs two independent
/// Needleman–Wunsch alignments (one over phoneme chars, a separate one over
/// core letters for sifat), this scorer runs ONE `diff_match_patch` char-diff
/// and maps it onto **phoneme groups** (a core letter + an optional residual,
/// per the Phonetizer's `chunk_phoneme_units`). Each group is tagged
/// `exact`/`partial`/`insert`/`delete`; the sifat of a group are compared off
/// that same alignment, so the phoneme diff and the sifat scoring stay
/// consistent. A `partial` group whose ref starts with a madd letter is treated
/// as `exact` (mirrors the reference).
///
/// It returns the same [RecitationScore] shape the UI already consumes, so it
/// can be swapped in for [RecitationScorer] behind an A/B toggle.
class GroupedRecitationScorer {
  GroupedRecitationScorer._();

  static RecitationScore score({
    required PhonemeDecodeResult decoded,
    required PhonetizerResult expected,
    required List<String> verseWords,
  }) {
    final verseWordCount = verseWords.length;

    // ---- Expected side: chunks (text + English classes + verse-word index).
    final exp = _buildExpectedGroups(expected);
    final refTexts = exp.map((g) => g.text).toList(growable: false);
    final nWords = exp.isEmpty ? 0 : (exp.map((g) => g.word).reduce(_maxInt) + 1);

    // Per-ref fractional position within its word, for grapheme highlighting.
    final wordCount = <int, int>{};
    for (final g in exp) {
      if (g.word >= 0) wordCount[g.word] = (wordCount[g.word] ?? 0) + 1;
    }
    final wordSeen = <int, int>{};
    final refFraction = List<double>.filled(exp.length, 0.0);
    for (var k = 0; k < exp.length; k++) {
      final w = exp[k].word;
      if (w < 0) continue;
      final pos = wordSeen[w] ?? 0;
      wordSeen[w] = pos + 1;
      final total = wordCount[w] ?? 1;
      refFraction[k] = total > 0 ? pos / total : 0.0;
    }

    // ---- Predicted side: decoded phoneme string -> chunks + per-chunk sifat.
    final predString = decoded.phonemes;
    final predChunks = chunkPhonemeUnits(predString);
    final predClasses = _predictedChunkClasses(decoded.segments);

    // ---- One char-diff, segmented onto the two group lists, then merged.
    final diffs = diff(refTexts.join(), predChunks.join());
    final groups = mergeSamePhonemeGroup(
      segmentGroups(refTexts, predChunks, diffs),
    );

    // ---- Single pass over the tagged groups -> accuracy, wrong words, sifat.
    final agree = <String, int>{for (final h in kSifatHeads) h: 0};
    final total = <String, int>{for (final h in kSifatHeads) h: 0};
    final sifatDiffs = <SifatDiff>[];
    final wrongWords = <int>{};
    // Two separate channels: pronunciation (phoneme) errors -> red, and
    // tajweed-only (sifat) mismatches on correctly-pronounced letters -> amber.
    final phonemeFractions = <int, List<double>>{};
    final sifatFractions = <int, List<double>>{};
    var exactCount = 0;
    var lastWord = 0;
    var lastFrac = 0.0;

    void markPhoneme(int w, double frac) {
      if (w < 0 || w >= nWords) return;
      (phonemeFractions[w] ??= <double>[]).add(frac);
    }

    void markSifat(int w, double frac) {
      if (w < 0 || w >= nWords) return;
      (sifatFractions[w] ??= <double>[]).add(frac);
    }

    for (final g in groups) {
      final exactish = groupIsExactish(g);
      if (exactish) exactCount++;

      if (g.refIdx >= 0) {
        final w = exp[g.refIdx].word;
        final frac = refFraction[g.refIdx];
        lastWord = w;
        lastFrac = frac;

        if (exactish && g.outIdx >= 0) {
          // Compare the 10 sifat heads on this aligned (exact-ish) group.
          final ev = exp[g.refIdx].classes;
          final pv = (g.outIdx < predClasses.length)
              ? predClasses[g.outIdx]
              : const <String, String>{};
          final mismatched = <String>[];
          for (final head in kSifatHeads) {
            final e = ev[head];
            final p = pv[head];
            if (e == null || p == null) continue;
            total[head] = total[head]! + 1;
            if (e == p) {
              agree[head] = agree[head]! + 1;
            } else {
              mismatched.add(head);
            }
          }
          if (mismatched.isNotEmpty) {
            sifatDiffs.add(SifatDiff(
              phoneme: _firstLetter(g.ref),
              word: w,
              mismatchedHeads: mismatched,
              expected: {for (final h in mismatched) h: ev[h] ?? ''},
              predicted: {for (final h in mismatched) h: pv[h] ?? ''},
            ));
            if (w >= 0) wrongWords.add(w);
            markSifat(w, frac);
          }
        } else if (!exactish) {
          // delete (missing) or non-madd partial (substituted) phoneme.
          markPhoneme(w, frac);
        }
      } else {
        // insert: extra predicted phoneme with no expected counterpart.
        markPhoneme(lastWord, lastFrac);
      }
    }

    // ---- Group-exact accuracy: exact (incl. madd-partial) / expected groups.
    final accuracy =
        exp.isEmpty ? 0.0 : (exactCount / exp.length).clamp(0.0, 1.0);

    // ---- Sifat per-head + overall accuracy.
    final perHead = <String, double>{
      for (final h in kSifatHeads)
        h: total[h]! == 0 ? 1.0 : agree[h]! / total[h]!,
    };
    final summedTotal = total.values.fold<int>(0, (a, b) => a + b);
    final summedAgree = agree.values.fold<int>(0, (a, b) => a + b);
    final overall = summedTotal == 0 ? 1.0 : summedAgree / summedTotal;

    // ---- Map fractional positions onto displayed grapheme clusters.
    final Map<int, Set<int>> wrongCharIndicesByWord;
    final Map<int, Set<int>> sifatCharIndicesByWord;
    final tappable = <int>{};
    if (nWords == verseWordCount) {
      wrongCharIndicesByWord =
          mapFractionsToClusters(phonemeFractions, verseWords);
      sifatCharIndicesByWord =
          mapFractionsToClusters(sifatFractions, verseWords);
      tappable
        ..addAll(wrongCharIndicesByWord.keys)
        ..addAll(sifatCharIndicesByWord.keys);
    } else {
      // Word counts disagree (rare): fall back to whole-word flags.
      wrongCharIndicesByWord = <int, Set<int>>{};
      sifatCharIndicesByWord = <int, Set<int>>{};
      tappable
        ..addAll(
            remapWords(phonemeFractions.keys.toSet(), nWords, verseWordCount))
        ..addAll(
            remapWords(sifatFractions.keys.toSet(), nWords, verseWordCount));
    }

    return RecitationScore(
      accuracy: accuracy,
      wrongWordIndices: tappable,
      wrongCharIndicesByWord: wrongCharIndicesByWord,
      sifatCharIndicesByWord: sifatCharIndicesByWord,
      sifat: SifatComparison(
        perHeadAccuracy: perHead,
        overall: overall,
        diffs: sifatDiffs,
        wrongWords: wrongWords,
      ),
      expectedPhonemes: expected.phonemes,
      predictedPhonemes: predString,
      expectedWordCount: nWords,
    );
  }

  // --- Expected groups: chunk text + classes + verse-word index. ------------

  static List<_ExpGroup> _buildExpectedGroups(PhonetizerResult expected) {
    // Word index per expected chunk, recovered by chunking the *spaced*
    // phonetic string the same way the Phonetizer's `chunk_phoneme_units` does.
    final chunkWords = chunkWordsOf(expected.phonemes);
    final out = <_ExpGroup>[];
    for (var k = 0; k < expected.sifat.length; k++) {
      final m = expected.sifat[k];
      final chunk = (m['phonemes'] as String?) ?? '';
      if (chunk.isEmpty) continue;
      final classes = <String, String>{};
      for (final head in kSifatHeads) {
        final v = m[head];
        if (v is String) classes[head] = v;
      }
      out.add(_ExpGroup(
        chunk,
        classes,
        k < chunkWords.length ? chunkWords[k] : -1,
      ));
    }
    return out;
  }

  // --- Predicted per-chunk sifat (Arabic -> normalized English). ------------

  static List<Map<String, String>> _predictedChunkClasses(
    List<PhonemeSegment> predictedSegments,
  ) {
    final out = <Map<String, String>>[];
    for (final seg in predictedSegments) {
      final token = seg.phonemeToken;
      if (token.isEmpty) continue;
      // Only core-letter segments start a chunk (residual/harakat segments are
      // folded into the preceding chunk's text and carry no sifat of interest).
      if (_isResidual(token.runes.first) || _isSpace(token.runes.first)) {
        continue;
      }
      final classes = <String, String>{};
      seg.sifat.forEach((head, arabic) {
        classes[head] = normalizeSifatToken(head, arabic);
      });
      out.add(classes);
    }
    return out;
  }

  static String _firstLetter(String s) =>
      s.isEmpty ? '' : String.fromCharCode(s.runes.first);

  static int _maxInt(int a, int b) => a > b ? a : b;
}

// ---------------------------------------------------------------------------
// Phonetic classification (ported from `sifat.py` / `load_alphabet.py`).
//
// A "residual" is a combining mark that attaches to a core letter: the three
// harakat plus the qlqla/sakt/dama-mokhtalasa/fatha-momala marks. Everything
// else (non-space) is a core/chunk-starting letter. NOTE this deliberately does
// NOT reuse `RecitationScorer`'s `_isCoreLetter`, whose broad Unicode ranges
// misclassify the madd letters yaa_madd (U+06E6) / waw_madd (U+06E5) and
// alif_momala/kasheeda (U+0640) — all of which must count as core here.
const Set<int> _residualCodepoints = <int>{
  0x064E, // fatha
  0x064F, // damma
  0x0650, // kasra
  0x0687, // qlqla mark (small geem above)
  0x06DC, // sakt (small high seen)
  0x0619, // dama mokhtalasa (small damma)
  0x06EA, // fatha momala (imala sign)
};

/// The chunk-initial letters treated as "exact" even on a `partial` tag.
const Set<int> _maddFirstCodepoints = <int>{
  0x0627, // alif ا
  0x06E6, // yaa_madd (small yaa sila)
  0x06E5, // waw_madd (small waw)
};

bool _isResidual(int cp) => _residualCodepoints.contains(cp);

/// True when [token] starts a predicted phoneme chunk — i.e. its first rune is
/// a core letter, neither a residual mark nor whitespace. Shared with
/// [RecitationScorer]'s deepened (chunk-based) sifat alignment so its predicted
/// letter list includes the madd letters that `_isCoreLetter` drops.
bool isChunkStartToken(String token) {
  if (token.isEmpty) return false;
  final cp = token.runes.first;
  return !_isResidual(cp) && !_isSpace(cp);
}

/// True when a group counts as correct for scoring: an `exact` match, or a
/// `partial` whose expected chunk starts with a madd letter (alif / yaa_madd /
/// waw_madd) — mirrors the Python reference's madd special case.
@visibleForTesting
bool groupIsExactish(PhonemeGroup g) {
  if (g.tag == 'exact') return true;
  if (g.tag == 'partial' &&
      g.ref.isNotEmpty &&
      _maddFirstCodepoints.contains(g.ref.runes.first)) {
    return true;
  }
  return false;
}

bool _isSpace(int cp) =>
    cp == 0x20 || cp == 0x09 || cp == 0x0A || cp == 0x0D || cp == 0xA0;

/// Splits a phonetic string into phoneme groups: a run of one identical core
/// letter followed by an optional single residual mark. Mirrors the Python
/// `chunk_phoneme_units` regex `((?:ch+)[residuals]?)`. Spaces and orphan
/// residuals (no preceding core) are dropped.
@visibleForTesting
List<String> chunkPhonemeUnits(String text) {
  final runes = text.runes.toList(growable: false);
  final chunks = <String>[];
  var i = 0;
  while (i < runes.length) {
    final cp = runes[i];
    if (_isSpace(cp) || _isResidual(cp)) {
      i++;
      continue;
    }
    final buf = StringBuffer()..writeCharCode(cp);
    var j = i + 1;
    while (j < runes.length && runes[j] == cp) {
      buf.writeCharCode(runes[j]);
      j++;
    }
    if (j < runes.length && _isResidual(runes[j])) {
      buf.writeCharCode(runes[j]);
      j++;
    }
    chunks.add(buf.toString());
    i = j;
  }
  return chunks;
}

/// Walks [phonetic] (which may contain word-separating spaces) and returns the
/// verse-word index of each emitted phoneme chunk, in order. Shared with
/// [RecitationScorer]'s opt-in chunk-based sifat word attribution so the two
/// scorers agree on which verse word a chunk belongs to.
List<int> chunkWordsOf(String phonetic) {
  final runes = phonetic.runes.toList(growable: false);
  final words = <int>[];
  var word = 0;
  var seenChar = false;
  var pendingNewWord = false;
  var i = 0;
  while (i < runes.length) {
    final cp = runes[i];
    if (_isSpace(cp)) {
      if (seenChar) pendingNewWord = true;
      i++;
      continue;
    }
    if (_isResidual(cp)) {
      // Orphan residual (no preceding core) — skip, like the regex does.
      i++;
      continue;
    }
    if (pendingNewWord) {
      word++;
      pendingNewWord = false;
    }
    seenChar = true;
    // Consume a run of the identical core char + an optional single residual.
    var j = i + 1;
    while (j < runes.length && runes[j] == cp) {
      j++;
    }
    if (j < runes.length && _isResidual(runes[j])) j++;
    words.add(word);
    i = j;
  }
  return words;
}

/// One aligned pair from the group segmentation. `ref` is the expected chunk
/// (empty for an insert), `out` the predicted chunk (empty for a delete);
/// `refIdx`/`outIdx` index back into the expected/predicted group lists (-1
/// when that side is absent).
class PhonemeGroup {
  PhonemeGroup({
    this.ref = '',
    this.out = '',
    this.refIdx = -1,
    this.outIdx = -1,
  });

  String ref;
  String out;
  int refIdx;
  int outIdx;

  /// `exact` (ref == out), `delete` (out empty), `insert` (ref empty), or
  /// `partial` (both present but differ).
  String get tag {
    if (ref == out) return 'exact';
    if (out.isEmpty) return 'delete';
    if (ref.isEmpty) return 'insert';
    return 'partial';
  }
}

/// Walks the char-[diffs] and zips the [refGroups]/[outGroups] chunk lists onto
/// them, emitting one [PhonemeGroup] per closed group pair. Faithful port of
/// the Python `segment_groups`: ref chars advance on EQUAL+DELETE, out chars on
/// EQUAL+INSERT, and a group on either side closes once enough chars have
/// accumulated to cover it.
@visibleForTesting
List<PhonemeGroup> segmentGroups(
  List<String> refGroups,
  List<String> outGroups,
  List<Diff> diffs,
) {
  var refCounter = 0;
  var refPtr = 0;
  var refGroupIdx = 0;
  var outCounter = 0;
  var outPtr = 0;
  var outGroupIdx = 0;

  final pairs = <PhonemeGroup>[];
  for (final d in diffs) {
    final len = d.text.length;
    if (d.operation == DIFF_EQUAL) {
      refCounter += len;
      outCounter += len;
    } else if (d.operation == DIFF_INSERT) {
      outCounter += len;
    } else {
      // DIFF_DELETE
      refCounter += len;
    }

    var refHasMatch = true;
    var outHasMatch = true;
    while (refHasMatch || outHasMatch) {
      final pair = PhonemeGroup();
      if (refGroupIdx < refGroups.length) {
        if ((refCounter - refPtr) >= refGroups[refGroupIdx].length) {
          pair.ref = refGroups[refGroupIdx];
          pair.refIdx = refGroupIdx;
          refPtr += refGroups[refGroupIdx].length;
          refGroupIdx++;
        } else {
          refHasMatch = false;
        }
      } else {
        refHasMatch = false;
      }

      if (outGroupIdx < outGroups.length) {
        if ((outCounter - outPtr) >= outGroups[outGroupIdx].length) {
          pair.out = outGroups[outGroupIdx];
          pair.outIdx = outGroupIdx;
          outPtr += outGroups[outGroupIdx].length;
          outGroupIdx++;
        } else {
          outHasMatch = false;
        }
      } else {
        outHasMatch = false;
      }

      if (pair.ref.isNotEmpty || pair.out.isNotEmpty) {
        pairs.add(pair);
      }
    }
  }
  return pairs;
}

/// Merges adjacent groups where one side's (non-empty) string is contained in
/// the neighbor's, collapsing a delete+insert pair into a single `partial`.
/// Faithful port of the Python `merge_same_phoneme_group`. The non-empty guard
/// is implicit: a side's index is -1 (and its string empty) when it was never
/// filled, so the substring test only fires when both sides are real.
@visibleForTesting
List<PhonemeGroup> mergeSamePhonemeGroup(List<PhonemeGroup> groups) {
  if (groups.isEmpty) return groups;
  final outs = <PhonemeGroup>[groups[0]];
  var prev = 0;
  for (var curr = 1; curr < groups.length; curr++) {
    final p = groups[prev];
    final c = groups[curr];
    if (p.outIdx != -1 && c.refIdx != -1 && c.ref.contains(p.out)) {
      // prev's predicted chunk is part of curr's expected chunk.
      outs.removeLast();
      outs.add(PhonemeGroup(
        ref: c.ref,
        refIdx: c.refIdx,
        out: p.out,
        outIdx: p.outIdx,
      ));
    } else if (p.refIdx != -1 && c.outIdx != -1 && c.out.contains(p.ref)) {
      // prev's expected chunk is part of curr's predicted chunk.
      outs.removeLast();
      outs.add(PhonemeGroup(
        ref: p.ref,
        refIdx: p.refIdx,
        out: c.out,
        outIdx: c.outIdx,
      ));
    } else {
      outs.add(c);
    }
    prev = curr;
  }
  return outs;
}

/// Expected phoneme chunk + its English sifat classes + verse-word index.
class _ExpGroup {
  const _ExpGroup(this.text, this.classes, this.word);
  final String text;
  final Map<String, String> classes;
  final int word;
}
