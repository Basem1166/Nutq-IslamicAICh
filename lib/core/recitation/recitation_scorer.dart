import 'dart:math' as math;

import 'package:characters/characters.dart';

import '../phonetizer_service.dart';
import 'ctc_decoder.dart';
import 'grouped_recitation_scorer.dart' show chunkWordsOf, isChunkStartToken;
import 'sifat_mapping.dart';

/// Splits [text] into Unicode grapheme clusters (what a human sees as
/// individual characters). This handles Arabic base letters + combining
/// diacritics correctly so that e.g. "بِسْمِ" yields 4 clusters, not 6 code
/// units.
List<String> graphemeClusters(String text) =>
    text.characters.toList(growable: false);

/// Remaps word indices from the phoneme-word space (`nWords`) onto the
/// displayed verse-word space (`verseWordCount`). Used as the whole-word
/// fallback when the two word counts disagree and per-character highlighting
/// can't be mapped. Shared by [RecitationScorer] and [GroupedRecitationScorer].
Set<int> remapWords(Set<int> words, int nWords, int verseWordCount) {
  if (verseWordCount <= 0 || nWords <= 0 || nWords == verseWordCount) {
    return words
        .where((w) => w < (verseWordCount <= 0 ? nWords : verseWordCount))
        .toSet();
  }
  return words
      .map((w) =>
          (w * verseWordCount / nWords).round().clamp(0, verseWordCount - 1))
      .toSet();
}

/// Compares the model's audio-derived phonemes/sifat against the Phonetizer's
/// text-derived *expected* phonemes/sifat and produces an overall accuracy plus
/// per-word right/wrong flags for [ErrorAnalysisPage].
///
/// Pipeline (see plan §4):
///   1. char-level align expected vs predicted phoneme streams -> accuracy,
///   2. fold alignment mismatches back onto words (expected string keeps
///      word-separating spaces) -> per-word error ratios,
///   3. frame-level align core letters to compare the 10 sifat heads; a word
///      whose letters are right but whose sifat are wrong is still a tajweed
///      error and gets flagged.
class RecitationScorer {
  RecitationScorer._();

  static RecitationScore score({
    required PhonemeDecodeResult decoded,
    required PhonetizerResult expected,
    required List<String> verseWords,
    bool chunkBasedSifat = false,
  }) {
    final verseWordCount = verseWords.length;

    // ---- Expected side: chars + per-char word index + position within word.
    final expChars = <String>[];
    final expWordOf = <int>[];
    final expPosInWord = <int>[];
    final wordCounter = <int, int>{};
    var word = 0;
    var pendingNewWord = false;
    var seenChar = false;
    for (final rune in expected.phonemes.runes) {
      final ch = String.fromCharCode(rune);
      if (_isWhitespace(rune)) {
        if (seenChar) pendingNewWord = true;
        continue;
      }
      if (pendingNewWord) {
        word++;
        pendingNewWord = false;
      }
      seenChar = true;
      final pos = wordCounter[word] ?? 0;
      wordCounter[word] = pos + 1;
      expChars.add(ch);
      expWordOf.add(word);
      expPosInWord.add(pos);
    }
    final nWords = expChars.isEmpty ? 0 : (expWordOf.last + 1);

    // ---- Predicted side: collapsed phoneme string -> chars.
    final predictedPhonemes = decoded.phonemes;
    final predChars = predictedPhonemes.runes
        .map((r) => String.fromCharCode(r))
        .toList(growable: false);

    // ---- 1: phoneme alignment -> accuracy.
    final ops = _align(expChars, predChars);
    final editDistance = ops.where((o) => o.kind != _Kind.match).length;
    final accuracy = expChars.isEmpty
        ? 0.0
        : (1.0 - editDistance / expChars.length).clamp(0.0, 1.0);

    // ---- 2: fold each mismatch onto a FRACTIONAL position within its word.
    // The displayed verse is Uthmani script while the alignment runs on the
    // Phonetizer's phonetic string, so the two have different per-word character
    // counts. A fraction in [0, 1) maps cleanly from one onto the other below.
    final perWordTotal = List<int>.filled(nWords, 0);
    for (final w in expWordOf) {
      perWordTotal[w]++;
    }
    final wrongFractions = <int, List<double>>{};
    void markWrong(int w, int pos) {
      if (w < 0 || w >= perWordTotal.length) return;
      final total = perWordTotal[w];
      (wrongFractions[w] ??= <double>[]).add(total > 0 ? pos / total : 0.0);
    }

    var lastWord = 0;
    var lastPos = 0;
    for (final op in ops) {
      switch (op.kind) {
        case _Kind.match:
          lastWord = expWordOf[op.expIndex];
          lastPos = expPosInWord[op.expIndex];
          break;
        case _Kind.sub:
        case _Kind.del:
          lastWord = expWordOf[op.expIndex];
          lastPos = expPosInWord[op.expIndex];
          markWrong(lastWord, lastPos);
          break;
        case _Kind.ins:
          if (nWords > 0) markWrong(lastWord, lastPos);
          break;
      }
    }

    // ---- 3: sifat comparison — tracked on its OWN fraction channel so the UI
    // can render tajweed-only mismatches (amber) apart from pronunciation
    // errors (red). [wrongFractions] above is pronunciation-only.
    final sifat = _compareSifat(
      expected: expected,
      predictedSegments: decoded.segments,
      expChars: expChars,
      expWordOf: expWordOf,
      chunkBasedSifat: chunkBasedSifat,
    );
    final sifatFractions = sifat.wrongFractionsByWord;

    // ---- Map fractional positions onto the displayed word's grapheme clusters.
    final Map<int, Set<int>> wrongCharIndicesByWord;
    final Map<int, Set<int>> sifatCharIndicesByWord;
    final tappable = <int>{};
    if (nWords == verseWordCount) {
      wrongCharIndicesByWord = mapFractionsToClusters(wrongFractions, verseWords);
      sifatCharIndicesByWord = mapFractionsToClusters(sifatFractions, verseWords);
      tappable
        ..addAll(wrongCharIndicesByWord.keys)
        ..addAll(sifatCharIndicesByWord.keys);
    } else {
      // Word counts disagree (rare): fall back to whole-word flags.
      wrongCharIndicesByWord = <int, Set<int>>{};
      sifatCharIndicesByWord = <int, Set<int>>{};
      tappable
        ..addAll(remapWords(wrongFractions.keys.toSet(), nWords, verseWordCount))
        ..addAll(
            remapWords(sifatFractions.keys.toSet(), nWords, verseWordCount));
    }

    return RecitationScore(
      accuracy: accuracy,
      wrongWordIndices: tappable,
      wrongCharIndicesByWord: wrongCharIndicesByWord,
      sifatCharIndicesByWord: sifatCharIndicesByWord,
      sifat: sifat,
      expectedPhonemes: expected.phonemes,
      predictedPhonemes: predictedPhonemes,
      expectedWordCount: nWords,
    );
  }

  // --- Sifat heads: align core letters, compare normalized classes. ---------

  static SifatComparison _compareSifat({
    required PhonetizerResult expected,
    required List<PhonemeSegment> predictedSegments,
    required List<String> expChars,
    required List<int> expWordOf,
    required bool chunkBasedSifat,
  }) {
    // Expected per-chunk sifat (English) + the word each chunk belongs to.
    // The k-th Phonetizer chunk lines up with the k-th expected *core letter*.
    final coreWords = <int>[];
    for (var i = 0; i < expChars.length; i++) {
      if (_isCoreLetter(expChars[i].runes.first)) coreWords.add(expWordOf[i]);
    }
    // Opt-in fix: derive each chunk's verse word the way GroupedRecitationScorer
    // does — by chunking the *spaced* phonetic string — instead of the
    // `_isCoreLetter` core-letter scan, which misclassifies madd letters
    // (waw_madd/yaa_madd/kasheeda) and shifts every subsequent word index,
    // mis-attributing (and dropping) most sifat diffs.
    final chunkWords =
        chunkBasedSifat ? chunkWordsOf(expected.phonemes) : const <int>[];
    int wordOfChunk(int k) => chunkBasedSifat
        ? (k < chunkWords.length ? chunkWords[k] : -1)
        : (k < coreWords.length ? coreWords[k] : -1);
    final expEntries = <_SifatEntry>[];
    for (var k = 0; k < expected.sifat.length; k++) {
      final m = expected.sifat[k];
      final chunk = (m['phonemes'] as String?) ?? '';
      if (chunk.isEmpty) continue;
      final letter = String.fromCharCode(chunk.runes.first);
      final classes = <String, String>{};
      for (final head in kSifatHeads) {
        final v = m[head];
        if (v is String) classes[head] = v;
      }
      expEntries.add(_SifatEntry(letter, classes, wordOfChunk(k)));
    }

    // Predicted per-core-letter sifat (Arabic -> normalized English). The
    // deepened path uses the chunk-start test (shared with the grouped scorer),
    // which keeps the madd letters that `_isCoreLetter` drops — without them the
    // predicted and expected letter lists diverge and far fewer letters get
    // their sifat compared, so Legacy+ surfaced fewer tajweed diffs.
    final predEntries = <_SifatEntry>[];
    for (final seg in predictedSegments) {
      final isCore = chunkBasedSifat
          ? isChunkStartToken(seg.phonemeToken)
          : (seg.phonemeToken.isNotEmpty &&
              _isCoreLetter(seg.phonemeToken.runes.first));
      if (!isCore) continue;
      final classes = <String, String>{};
      seg.sifat.forEach((head, arabic) {
        classes[head] = normalizeSifatToken(head, arabic);
      });
      predEntries.add(_SifatEntry(seg.phonemeToken, classes, -1));
    }

    final ops = _align(
      expEntries.map((e) => e.letter).toList(growable: false),
      predEntries.map((e) => e.letter).toList(growable: false),
    );

    final agree = <String, int>{for (final h in kSifatHeads) h: 0};
    final total = <String, int>{for (final h in kSifatHeads) h: 0};
    final diffs = <SifatDiff>[];
    final wrongWords = <int>{};

    for (final op in ops) {
      if (op.kind != _Kind.match) continue; // only compare aligned letters
      final e = expEntries[op.expIndex];
      final p = predEntries[op.predIndex];
      final mismatched = <String>[];
      for (final head in kSifatHeads) {
        final ev = e.classes[head];
        final pv = p.classes[head];
        if (ev == null || pv == null) continue;
        total[head] = total[head]! + 1;
        if (ev == pv) {
          agree[head] = agree[head]! + 1;
        } else {
          mismatched.add(head);
        }
      }
      if (mismatched.isNotEmpty) {
        diffs.add(SifatDiff(
          phoneme: e.letter,
          word: e.word,
          mismatchedHeads: mismatched,
          expected: {for (final h in mismatched) h: e.classes[h] ?? ''},
          predicted: {for (final h in mismatched) h: p.classes[h] ?? ''},
        ));
        if (e.word >= 0) wrongWords.add(e.word);
      }
    }

    final perHead = <String, double>{
      for (final h in kSifatHeads)
        h: total[h]! == 0 ? 1.0 : agree[h]! / total[h]!,
    };
    final summedTotal = total.values.fold<int>(0, (a, b) => a + b);
    final summedAgree = agree.values.fold<int>(0, (a, b) => a + b);
    final overall = summedTotal == 0 ? 1.0 : summedAgree / summedTotal;

    return SifatComparison(
      perHeadAccuracy: perHead,
      overall: overall,
      diffs: diffs,
      wrongWords: wrongWords,
    );
  }

  // --- Needleman–Wunsch alignment over token lists. -------------------------

  static List<_Op> _align(List<String> a, List<String> b) {
    final m = a.length;
    final n = b.length;
    final cost = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
    for (var i = 0; i <= m; i++) {
      cost[i][0] = i;
    }
    for (var j = 0; j <= n; j++) {
      cost[0][j] = j;
    }
    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        final c = a[i - 1] == b[j - 1] ? 0 : 1;
        cost[i][j] = math.min(
          cost[i - 1][j - 1] + c,
          math.min(cost[i - 1][j] + 1, cost[i][j - 1] + 1),
        );
      }
    }

    final ops = <_Op>[];
    var i = m;
    var j = n;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0) {
        final c = a[i - 1] == b[j - 1] ? 0 : 1;
        if (cost[i][j] == cost[i - 1][j - 1] + c) {
          ops.add(_Op(c == 0 ? _Kind.match : _Kind.sub, i - 1, j - 1));
          i--;
          j--;
          continue;
        }
      }
      if (i > 0 && cost[i][j] == cost[i - 1][j] + 1) {
        ops.add(_Op(_Kind.del, i - 1, -1));
        i--;
        continue;
      }
      ops.add(_Op(_Kind.ins, -1, j - 1));
      j--;
    }
    return ops.reversed.toList(growable: false);
  }

  // --- Unicode helpers. -----------------------------------------------------

  static bool _isWhitespace(int cp) => cp == 0x20 || cp == 0x09 || cp == 0x0A || cp == 0x0D || cp == 0xA0;

  /// True for an Arabic *letter* (a phoneme carrier), false for combining
  /// harakat/marks and tatweel — which the Phonetizer groups into the letter's
  /// chunk rather than emitting as standalone sifat carriers.
  static bool _isCoreLetter(int cp) {
    if (_isWhitespace(cp)) return false;
    if (cp == 0x0640) return false; // tatweel ـ
    // Arabic combining marks (harakat, tanwin, shadda, small Quranic marks).
    if (cp >= 0x0610 && cp <= 0x061A) return false;
    if (cp >= 0x064B && cp <= 0x065F) return false;
    if (cp == 0x0670) return false;
    if (cp >= 0x06D6 && cp <= 0x06DC) return false;
    if (cp >= 0x06DF && cp <= 0x06E8) return false;
    if (cp >= 0x06EA && cp <= 0x06ED) return false;
    if (cp >= 0x08D3 && cp <= 0x08FF) return false;
    return true;
  }
}

enum _Kind { match, sub, ins, del }

class _Op {
  const _Op(this.kind, this.expIndex, this.predIndex);
  final _Kind kind;
  final int expIndex; // -1 if N/A
  final int predIndex; // -1 if N/A
}

class _SifatEntry {
  const _SifatEntry(this.letter, this.classes, this.word);
  final String letter;
  final Map<String, String> classes; // head -> English class
  final int word; // expected verse-word index, or -1
}

/// Maps each word's fractional error positions (in [0, 1)) onto grapheme-cluster
/// indices of the displayed [verseWords]. Shared by both scorers so the phoneme
/// and sifat error channels map the same way. Returns word -> cluster indices,
/// dropping words that fall outside the displayed verse.
Map<int, Set<int>> mapFractionsToClusters(
  Map<int, List<double>> fractions,
  List<String> verseWords,
) {
  final out = <int, Set<int>>{};
  fractions.forEach((w, fr) {
    if (w < 0 || w >= verseWords.length) return;
    final clusters = graphemeClusters(verseWords[w]).length;
    if (clusters == 0) return;
    final set = <int>{};
    for (final f in fr) {
      set.add((f * clusters).floor().clamp(0, clusters - 1));
    }
    if (set.isNotEmpty) out[w] = set;
  });
  return out;
}

/// Final result handed to the UI.
class RecitationScore {
  const RecitationScore({
    required this.accuracy,
    required this.wrongWordIndices,
    required this.wrongCharIndicesByWord,
    required this.sifatCharIndicesByWord,
    required this.sifat,
    required this.expectedPhonemes,
    required this.predictedPhonemes,
    required this.expectedWordCount,
  });

  /// Overall phoneme accuracy in [0, 1] (1 - phoneme error rate).
  final double accuracy;

  /// Verse-word indices that have at least one error (tappable in UI).
  final Set<int> wrongWordIndices;

  /// For each wrong word, the grapheme-cluster indices with a **pronunciation
  /// (phoneme) error** — the letter itself was wrong/missing/extra. Rendered in
  /// red. When empty for a word in [wrongWordIndices] (rare fallback) the whole
  /// word is treated as a phoneme error.
  final Map<int, Set<int>> wrongCharIndicesByWord;

  /// For each word, the grapheme-cluster indices whose letter was pronounced
  /// correctly but whose **tajweed (sifat) attributes** differ. Rendered in
  /// amber — a softer signal than a pronunciation error. A cluster present in
  /// both maps is a phoneme error (red wins).
  final Map<int, Set<int>> sifatCharIndicesByWord;

  final SifatComparison sifat;

  /// Raw strings, for the step-3 vocab-parity validation logging.
  final String expectedPhonemes;
  final String predictedPhonemes;
  final int expectedWordCount;
}



class SifatComparison {
  const SifatComparison({
    required this.perHeadAccuracy,
    required this.overall,
    required this.diffs,
    required this.wrongWords,
  });

  /// head name -> accuracy in [0, 1] over aligned phonemes.
  final Map<String, double> perHeadAccuracy;
  final double overall;
  final List<SifatDiff> diffs;

  /// Verse-word indices that have at least one sifat mismatch.
  final Set<int> wrongWords;

  /// For each wrong word, the fractional positions (in [0, 1)) of the
  /// phoneme(s) that have sifat errors, so the scorer can map them onto
  /// grapheme-cluster indices in the displayed word.
  Map<int, List<double>> get wrongFractionsByWord {
    final result = <int, List<double>>{};
    for (final diff in diffs) {
      if (diff.word >= 0) {
        // We don't have per-phoneme position info in the sifat pipeline,
        // so we use 0.5 (middle of the word) as a reasonable default.
        // This will highlight the middle character of the displayed word.
        (result[diff.word] ??= <double>[]).add(0.5);
      }
    }
    return result;
  }
}

class SifatDiff {
  const SifatDiff({
    required this.phoneme,
    required this.word,
    required this.mismatchedHeads,
    required this.expected,
    required this.predicted,
  });

  final String phoneme;

  /// Expected verse-word index this phoneme belongs to (or -1).
  final int word;
  final List<String> mismatchedHeads;
  final Map<String, String> expected; // head -> expected English class
  final Map<String, String> predicted; // head -> predicted English class
}
