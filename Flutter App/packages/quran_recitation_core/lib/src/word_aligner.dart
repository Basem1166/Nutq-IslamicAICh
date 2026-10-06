/// Pure logic that maps a phonetized reference ayah onto per-word spans
/// and scores a heard phrase against a range of those words.
///
/// Two primitives
/// ──────────────
///   - [buildWordSpans]: splits the ayah on whitespace, then for each
///     word computes its character span in the Uthmani text, its phoneme
///     span in the reference phoneme string, and the slice of per-chunk
///     reference sifat. Run once per ayah; cheap thereafter.
///   - [alignPhraseToWords]: given a freshly-spoken phrase and a
///     contiguous range of candidate words, finds which spans of the
///     phrase correspond to which words and returns per-word PER.
///
/// Why chunked phonemes for scoring
/// ────────────────────────────────
/// QPS uses run-length encoding for Madds and Ghunnas (e.g. 4-beat Madd
/// = `ااا ا`). Edit distance on raw characters counts each beat as a
/// separate error and overweights long Madds. Edit distance on
/// `chunkPhonemes` output (one entry per Uthmani letter group) yields
/// a PER that scales with the letter count, not the beat count.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'phoneme_chunking.dart';
import 'phoneme_mapping.dart';
import 'sequence_matcher.dart';
import 'sifat.dart';

/// All reference information needed to score one ayah word.
///
/// Positions are absolute (indices into the full ayah's Uthmani text
/// and phoneme string respectively), so callers that need to delegate
/// to a whole-ayah explainer (e.g. `quran_transcript.explain_error`)
/// can slice the global mappings array with these.
@immutable
class WordSpan {
  /// Constructs a word span. All collection inputs are stored as-is —
  /// caller is responsible for not mutating them after construction.
  const WordSpan({
    required this.wordIdx,
    required this.uthmaniText,
    required this.uthmaniSpan,
    required this.phonemeText,
    required this.phonemeSpan,
    required this.chunks,
    required this.chunkPhonemeStarts,
    required this.sifatRefs,
  });

  /// Index of this word in the ayah (0-based).
  final int wordIdx;

  /// The word itself (as it appears in the Uthmani text).
  final String uthmaniText;

  /// Half-open `(start, end)` of this word in the FULL Uthmani ayah text.
  final (int, int) uthmaniSpan;

  /// Reference phonemes for this word.
  final String phonemeText;

  /// Half-open `(start, end)` of this word in the full reference phoneme
  /// string.
  final (int, int) phonemeSpan;

  /// `chunkPhonemes(phonemeText)`. Cached at build time.
  final List<String> chunks;

  /// Start index of each chunk WITHIN [phonemeText] (0-based).
  ///
  /// `chunkPhonemeStarts[k]` is where `chunks[k]` begins inside
  /// `phonemeText`. Useful for mapping a chunk-level edit back to a
  /// character span the UI can highlight.
  final List<int> chunkPhonemeStarts;

  /// Reference sifat for this word's chunks. Empty if no sifat were
  /// supplied to [buildWordSpans], OR if the per-word chunk count and
  /// the sifat slice disagree (we leave it empty rather than misalign).
  final List<SifaSnapshot> sifatRefs;

  /// Number of chunks in this word.
  int get nChunks => chunks.length;
}

/// Outcome of matching one heard word's phonemes against a single
/// [WordSpan].
@immutable
class WordMatch {
  /// Constructs a word match.
  const WordMatch({
    required this.wordIdx,
    required this.hypPhonemes,
    required this.hypChunks,
    required this.per,
    required this.nChunkEdits,
    required this.matched,
  });

  /// Index of the matched word in the ayah.
  final int wordIdx;

  /// The slice of the phrase hypothesis attributed to this word.
  final String hypPhonemes;

  /// `chunkPhonemes(hypPhonemes)`.
  final List<String> hypChunks;

  /// Chunked-level Levenshtein PER ∈ [0, ∞), typically [0, 1].
  final double per;

  /// Absolute chunk-level edit count (a `double` because length-mismatch
  /// substitutions contribute fractional partial penalties — see
  /// [_chunkedPer]).
  final double nChunkEdits;

  /// `true` if a clear alignment was found (PER below the "matched"
  /// threshold). `false` indicates this is likely noise that happened
  /// to be attributed here by the greedy split.
  final bool matched;
}

/// Result of aligning a phrase against a contiguous window of word
/// spans.
@immutable
class PhraseToWordsAlignment {
  /// Constructs an alignment result.
  const PhraseToWordsAlignment({
    required this.wordMatches,
    required this.leftoverHyp,
    required this.overallPer,
    required this.confidence,
  });

  /// One match per word that consumed some of the phrase. Trailing
  /// empty matches are dropped; the list may be shorter than the
  /// candidate window.
  final List<WordMatch> wordMatches;

  /// Phrase hypothesis not attributed to any matched word (typically
  /// content past the last word the phrase reached).
  final String leftoverHyp;

  /// Weighted average of per-word PERs (weighted by reference chunk
  /// count).
  final double overallPer;

  /// `1 − overallPer`, clamped to [0, 1].
  final double confidence;
}

/// Slices the ayah's reference into per-word spans.
///
/// Parameters
/// ──────────
///   - [uthmaniText]: the ayah's full Uthmani text (whitespace-separated
///     words).
///   - [refPhonemes]: the full phoneme string returned by the
///     phonetizer.
///   - [mappings]: per-Uthmani-character [PhonemeMapping]s, same length
///     as [uthmaniText]. `null` entries (or entries with `deleted=true`)
///     are skipped when computing word phoneme bounds.
///   - [refSifatChunks]: optional list of per-chunk reference sifat. If
///     provided, must satisfy
///     `refSifatChunks.length == chunkPhonemes(refPhonemes).length`.
///     Each word gets a slice of this list; if the slice length doesn't
///     match the word's chunk count, that word's [WordSpan.sifatRefs]
///     is left empty (alignment is presumed broken — better empty than
///     misaligned).
List<WordSpan> buildWordSpans({
  required String uthmaniText,
  required String refPhonemes,
  required List<PhonemeMapping?> mappings,
  List<SifaSnapshot>? refSifatChunks,
}) {
  if (mappings.length != uthmaniText.length) {
    throw ArgumentError(
      'mappings length (${mappings.length}) must equal '
      'uthmaniText length (${uthmaniText.length})',
    );
  }

  // 1) Find word boundaries (character spans of non-whitespace runs).
  final wordCharSpans = <(int, int)>[];
  var i = 0;
  final n = uthmaniText.length;
  while (i < n) {
    while (i < n && _isWhitespace(uthmaniText.codeUnitAt(i))) {
      i++;
    }
    if (i >= n) break;
    final wordStart = i;
    while (i < n && !_isWhitespace(uthmaniText.codeUnitAt(i))) {
      i++;
    }
    wordCharSpans.add((wordStart, i));
  }

  // 2) Pre-compute chunk-start indices for the FULL ref phonemes — so we
  //    can map a phoneme-range slice → chunk-range slice without
  //    re-chunking each word individually.
  final fullChunks = chunkPhonemes(refPhonemes);
  final fullChunkStarts = <int>[];
  var cursor = 0;
  for (final ch in fullChunks) {
    var idx = refPhonemes.indexOf(ch, cursor);
    if (idx < 0) {
      // Defensive: shouldn't happen since chunks come from refPhonemes
      // verbatim.
      idx = cursor;
    }
    fullChunkStarts.add(idx);
    cursor = idx + ch.length;
  }

  // 3) Build a WordSpan for each word.
  final spans = <WordSpan>[];
  for (var wIdx = 0; wIdx < wordCharSpans.length; wIdx++) {
    final (uStart, uEnd) = wordCharSpans[wIdx];

    // Locate phoneme span — first non-deleted mapping forward from
    // uStart, last non-deleted mapping backward from uEnd-1.
    int? pStart;
    for (var c = uStart; c < uEnd; c++) {
      final m = mappings[c];
      if (m == null || m.deleted) continue;
      pStart = m.start;
      break;
    }
    int? pEnd;
    for (var c = uEnd - 1; c >= uStart; c--) {
      final m = mappings[c];
      if (m == null || m.deleted) continue;
      pEnd = m.end;
      break;
    }

    if (pStart == null || pEnd == null) {
      // Entire word deleted (very unusual — maybe pure tatweel). Emit
      // an empty WordSpan and move on.
      spans.add(WordSpan(
        wordIdx: wIdx,
        uthmaniText: uthmaniText.substring(uStart, uEnd),
        uthmaniSpan: (uStart, uEnd),
        phonemeText: '',
        phonemeSpan: const (0, 0),
        chunks: const <String>[],
        chunkPhonemeStarts: const <int>[],
        sifatRefs: const <SifaSnapshot>[],
      ),);
      continue;
    }

    final wordPhonemes = refPhonemes.substring(pStart, pEnd);
    final wordChunks = chunkPhonemes(wordPhonemes);

    // Per-word local chunk-start indices (within wordPhonemes).
    final localChunkStarts = <int>[];
    var localCursor = 0;
    for (final ch in wordChunks) {
      var idx = wordPhonemes.indexOf(ch, localCursor);
      if (idx < 0) idx = localCursor;
      localChunkStarts.add(idx);
      localCursor = idx + ch.length;
    }

    // Slice the global sifat-chunks list to this word.
    var sifatSlice = const <SifaSnapshot>[];
    if (refSifatChunks != null) {
      int? firstGlobalChunk;
      int? lastGlobalChunk;
      for (var gIdx = 0; gIdx < fullChunkStarts.length; gIdx++) {
        final gStart = fullChunkStarts[gIdx];
        if (gStart >= pStart && gStart < pEnd) {
          firstGlobalChunk ??= gIdx;
          lastGlobalChunk = gIdx;
        }
      }
      if (firstGlobalChunk != null && lastGlobalChunk != null) {
        final candidate = refSifatChunks.sublist(
          firstGlobalChunk,
          lastGlobalChunk + 1,
        );
        sifatSlice = candidate.length == wordChunks.length
            ? List<SifaSnapshot>.unmodifiable(candidate)
            : const <SifaSnapshot>[];
      }
    }

    spans.add(WordSpan(
      wordIdx: wIdx,
      uthmaniText: uthmaniText.substring(uStart, uEnd),
      uthmaniSpan: (uStart, uEnd),
      phonemeText: wordPhonemes,
      phonemeSpan: (pStart, pEnd),
      chunks: List<String>.unmodifiable(wordChunks),
      chunkPhonemeStarts: List<int>.unmodifiable(localChunkStarts),
      sifatRefs: sifatSlice,
    ),);
  }

  return List<WordSpan>.unmodifiable(spans);
}

/// Aligns [phraseHyp] against `wordSpans[startIdx .. startIdx + maxWords]`.
///
/// Uses [SequenceMatcher] on characters to find which spans of the
/// phrase correspond to which words, then computes per-word chunked PER.
PhraseToWordsAlignment alignPhraseToWords({
  required String phraseHyp,
  required List<WordSpan> wordSpans,
  required int startIdx,
  int maxWords = 0,
}) {
  if (phraseHyp.trim().isEmpty) {
    return const PhraseToWordsAlignment(
      wordMatches: <WordMatch>[],
      leftoverHyp: '',
      overallPer: 1.0,
      confidence: 0.0,
    );
  }

  final endIdx = maxWords <= 0
      ? wordSpans.length
      : (startIdx + maxWords).clamp(0, wordSpans.length);
  final candidates = wordSpans.sublist(startIdx, endIdx);
  if (candidates.isEmpty) {
    return PhraseToWordsAlignment(
      wordMatches: const <WordMatch>[],
      leftoverHyp: phraseHyp,
      overallPer: 1.0,
      confidence: 0.0,
    );
  }

  // Concatenated ref phonemes across candidate words, plus cumulative
  // boundary indices.
  final refBuf = StringBuffer();
  final boundaries = <int>[];
  for (final ws in candidates) {
    refBuf.write(ws.phonemeText);
    boundaries.add(refBuf.length);
  }
  final refPhonemesConcat = refBuf.toString();

  final nPhrase = phraseHyp.length;
  if (nPhrase == 0) {
    return PhraseToWordsAlignment(
      wordMatches: const <WordMatch>[],
      leftoverHyp: phraseHyp,
      overallPer: 1.0,
      confidence: 0.0,
    );
  }

  final sm = SequenceMatcher(refPhonemesConcat, phraseHyp);
  final blocks = sm.getMatchingBlocks();

  // Per-ref-char → estimated phrase-char-index. Initially fill via the
  // matching blocks, then interpolate the gaps linearly (monotonic).
  final refToPhrase = List<int?>.filled(refPhonemesConcat.length, null);
  for (final block in blocks) {
    for (var k = 0; k < block.size; k++) {
      final idx = block.i + k;
      if (idx < refToPhrase.length) {
        refToPhrase[idx] = block.j + k;
      }
    }
  }
  _interpolateAlignment(refToPhrase, nPhrase: nPhrase);

  // Ignore up to 4 chars of leading noise (carryover from previous word
  // or imprecise VAD cut) before the first real match.
  var prevWordEndPhraseIdx = 0;
  if (blocks.isNotEmpty &&
      blocks.first.i == 0 &&
      blocks.first.j > 0 &&
      blocks.first.j <= 4) {
    prevWordEndPhraseIdx = blocks.first.j;
  }

  // Compute per-word phrase ranges using the boundaries.
  final wordMatches = <WordMatch>[];
  for (var wPos = 0; wPos < candidates.length; wPos++) {
    final ws = candidates[wPos];
    final refCharEnd = boundaries[wPos];
    int phraseEnd;
    if (refCharEnd - 1 < 0) {
      phraseEnd = prevWordEndPhraseIdx;
    } else {
      phraseEnd = (refToPhrase[refCharEnd - 1] ?? prevWordEndPhraseIdx) + 1;
    }
    if (phraseEnd < prevWordEndPhraseIdx) phraseEnd = prevWordEndPhraseIdx;
    if (phraseEnd > nPhrase) phraseEnd = nPhrase;

    // Include leading noise in the very first word's matched string so
    // it gets consumed (and not silently dropped), EXCEPT for the small
    // leading noise (<= 4 chars) we explicitly detected and chose to ignore.
    final startCh = prevWordEndPhraseIdx;
    final wordPhraseHyp = phraseHyp.substring(startCh, phraseEnd);
    final wordPhraseChunks = chunkPhonemes(wordPhraseHyp);
    final (per, nEdits) = _chunkedPer(ws.chunks, wordPhraseChunks);
    wordMatches.add(WordMatch(
      wordIdx: ws.wordIdx,
      hypPhonemes: wordPhraseHyp,
      hypChunks: wordPhraseChunks,
      per: per,
      nChunkEdits: nEdits,
      matched: per < 1.5,
    ),);
    prevWordEndPhraseIdx = phraseEnd;

    // Madd-aware boundary: if this word's reference ends in an elongation run
    // (a madd), drop any immediately-following heard beats of that SAME letter
    // before the next word starts. They are surplus elongation of THIS word's
    // madd — e.g. a 4-beat madd munfasil كَفَرُوا heard as "كَفَرُۥۥۥۥ" vs the
    // 2-beat in-isolation reference "كَفَرُۥۥ" — i.e. correct recitation, not the
    // next word's content. Without this drop the surplus "ۥۥ" spills onto the
    // next word's front (إِنْ → "ۥۥءِن") and inflates its PER (1 insertion over a
    // 2-chunk ref = 0.50). The cap stops the drop at the next word's matched
    // content so a next word that legitimately starts with the same madd letter
    // keeps its own beats.
    final maddChar = _trailingMaddChar(ws.chunks);
    if (maddChar != null) {
      final cap = wPos + 1 < candidates.length
          ? (refToPhrase[boundaries[wPos]] ?? nPhrase)
          : nPhrase;
      while (prevWordEndPhraseIdx < cap &&
          prevWordEndPhraseIdx < nPhrase &&
          phraseHyp.codeUnitAt(prevWordEndPhraseIdx) == maddChar) {
        prevWordEndPhraseIdx++;
      }
    }
  }

  final leftoverHyp = phraseHyp.substring(prevWordEndPhraseIdx);

  // Trim trailing empty word_matches (phrase ended before reaching them).
  while (wordMatches.isNotEmpty && wordMatches.last.hypChunks.isEmpty) {
    wordMatches.removeLast();
    candidates.removeLast();
  }

  if (candidates.isEmpty) {
    return PhraseToWordsAlignment(
      wordMatches: const <WordMatch>[],
      leftoverHyp: phraseHyp,
      overallPer: 1.0,
      confidence: 0.0,
    );
  }

  final totalRefChunks =
      candidates.fold<int>(0, (sum, w) => sum + w.chunks.length);
  final totalEdits =
      wordMatches.fold<double>(0.0, (sum, m) => sum + m.nChunkEdits);
  final overallPer = totalEdits / (totalRefChunks == 0 ? 1 : totalRefChunks);
  final confidence = (1.0 - overallPer).clamp(0.0, 1.0);

  return PhraseToWordsAlignment(
    wordMatches: List<WordMatch>.unmodifiable(wordMatches),
    leftoverHyp: leftoverHyp,
    overallPer: overallPer,
    confidence: confidence,
  );
}

// ─────────────────────────────────────────────────────────────────────────
//  Helpers (private)
// ─────────────────────────────────────────────────────────────────────────

/// Levenshtein on the chunked-phoneme level. Returns (PER, editCount).
///
/// Operates on chunks-as-tokens so each Uthmani letter contributes one
/// unit of normalization, regardless of how many beats it expands to.
///
/// Substitutions where ref and hyp share the same character set but differ
/// in length (e.g. a Madd of 4 `ا` heard as 6 `ا`) get a *partial* penalty
/// of `0.25` per extra character, capped at `1.0`, rather than a full
/// substitution cost. This stops minor elongation-length errors from being
/// scored as outright wrong letters.
(double, double) _chunkedPer(List<String> refChunks, List<String> hypChunks) {
  final nRef = refChunks.length;
  if (nRef == 0) {
    return hypChunks.isEmpty ? (0.0, 0.0) : (1.0, hypChunks.length.toDouble());
  }
  // Classic two-row Levenshtein with partial substitution penalty for
  // length mismatches.
  var prev = List<double>.generate(hypChunks.length + 1, (i) => i.toDouble());
  var cur = List<double>.filled(hypChunks.length + 1, 0.0);
  for (var i = 1; i <= nRef; i++) {
    cur[0] = i.toDouble();
    final ri = refChunks[i - 1];
    for (var j = 1; j <= hypChunks.length; j++) {
      final hj = hypChunks[j - 1];
      final double cost;
      if (ri == hj) {
        cost = 0.0;
      } else if (_sameCharSet(ri, hj)) {
        // Partial penalty: 0.25 per character difference, capped at 1.0.
        // E.g. getting 4 'ا' instead of 6 'ا' (diff 2 chars) = 0.5 penalty.
        cost = math.min(1.0, 0.25 * (ri.length - hj.length).abs());
      } else {
        cost = 1.0;
      }
      final insert = cur[j - 1] + 1.0;
      final delete = prev[j] + 1.0;
      final substitute = prev[j - 1] + cost;
      var best = insert;
      if (delete < best) best = delete;
      if (substitute < best) best = substitute;
      cur[j] = best;
    }
    final tmp = prev;
    prev = cur;
    cur = tmp;
  }
  final edits = prev[hypChunks.length];
  return (edits / nRef, edits);
}

/// QPS long-vowel (madd) letters that are run-length encoded for elongation:
/// alif `ا`, waw `و`, ya `ي`, and the small waw/ya `ۥ`/`ۦ`. A word whose final
/// chunk is a pure run of one of these is holding a madd whose surplus heard
/// beats belong to it, not to the following word.
const String _maddLetters = 'اويۥۦ';
final Set<int> _maddCodeUnits = _maddLetters.codeUnits.toSet();

/// If [chunks]' final chunk is a pure run (length ≥ 2, no diacritic) of a
/// single [madd letter][_maddLetters], returns that letter's code unit;
/// otherwise `null`. Used to decide whether trailing surplus heard beats are
/// this word's madd over-elongation (drop them) vs the next word's content.
int? _trailingMaddChar(List<String> chunks) {
  if (chunks.isEmpty) return null;
  final last = chunks.last;
  if (last.length < 2) return null;
  final c = last.codeUnitAt(0);
  if (!_maddCodeUnits.contains(c)) return null;
  for (var k = 1; k < last.length; k++) {
    if (last.codeUnitAt(k) != c) return null;
  }
  return c;
}

/// Whether [a] and [b] contain the same set of Unicode code points
/// (ignoring count and order). Mirrors Python's `set(a) == set(b)`.
bool _sameCharSet(String a, String b) {
  final sa = a.runes.toSet();
  final sb = b.runes.toSet();
  if (sa.length != sb.length) return false;
  return sa.containsAll(sb);
}

/// In-place: fill `null` gaps in [refToPhrase] with monotonic-clamped
/// linear interpolation.
void _interpolateAlignment(List<int?> refToPhrase, {required int nPhrase}) {
  final n = refToPhrase.length;
  if (n == 0) return;

  if (refToPhrase[n - 1] == null) {
    refToPhrase[n - 1] = nPhrase > 0 ? nPhrase - 1 : 0;
  }

  var lastKnown = 0;
  for (var i = 0; i < n; i++) {
    final v = refToPhrase[i];
    if (v == null) {
      refToPhrase[i] = lastKnown;
    } else {
      lastKnown = v;
    }
  }

  var runningMax = 0;
  for (var i = 0; i < n; i++) {
    final v = refToPhrase[i] ?? 0;
    if (v < runningMax) {
      refToPhrase[i] = runningMax;
    } else {
      runningMax = v;
    }
  }
}

/// Whitespace test matching Python's `str.isspace()` for the chars
/// `buildWordSpans` actually sees: ASCII space, tab, newline, carriage
/// return, and the Quran-text-relevant Unicode whitespace U+00A0 (NBSP).
bool _isWhitespace(int codeUnit) {
  return codeUnit == 0x20 || // space
      codeUnit == 0x09 || // tab
      codeUnit == 0x0A || // LF
      codeUnit == 0x0D || // CR
      codeUnit == 0xA0; // NBSP
}
