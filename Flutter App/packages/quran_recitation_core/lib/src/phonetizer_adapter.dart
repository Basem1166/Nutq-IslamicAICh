/// Adapter from the phonetizer service's JSON output to the recitation
/// core's typed inputs.
///
/// What this module assumes about your service
/// ───────────────────────────────────────────
/// The Flutter `PhonetizerService.phonetize()` method invokes a Python
/// pipeline (via MethodChannel + Chaquopy) and returns:
///
///   {
///     "phonemes": "<full phoneme string>",
///     "sifat":    [ {phonemes, hams_or_jahr, ...}, ... ],   // 1 per chunk
///     "mappings": [ {pos: [s, e], deleted: bool}, ... ],    // 1 per
///                                                             // Uthmani char
///   }
///
/// Note the field name discrepancy: each sifat entry uses `phonemes`
/// (singular: the chunk text itself), while the core's [SifaSnapshot]
/// uses `phonemeGroup`. The adapter handles the rename.
///
/// If your service hasn't been updated to include `mappings` yet, use
/// [synthesizeMappingsFromSpacedPhonemes] as a stopgap.
library;

import 'package:meta/meta.dart';

import 'phoneme_mapping.dart';
import 'sifat.dart';

// ─────────────────────────────────────────────────────────────────────────
//  Convenience holder
// ─────────────────────────────────────────────────────────────────────────

/// All three artifacts the phonetizer produces for one ayah.
///
/// Build this once per ayah, then pass to `buildWordSpans`:
///
/// ```dart
/// final adapted = adaptPhonetizerResult(
///   phonemes: serviceResult.phonemes,
///   sifat: serviceResult.sifat,
///   mappings: serviceResult.mappings,    // requires Path A
/// );
/// final spans = buildWordSpans(
///   uthmaniText: ayah.uthmaniText,
///   refPhonemes: adapted.refPhonemes,
///   mappings: adapted.mappings,
///   refSifatChunks: adapted.refSifatChunks,
/// );
/// ```
@immutable
class PhonetizerAdapterResult {
  /// Builds the result.
  const PhonetizerAdapterResult({
    required this.refPhonemes,
    required this.mappings,
    required this.refSifatChunks,
  });

  /// Full reference phoneme string for the ayah (with or without spaces;
  /// the aligner doesn't care, but spaces must be present if you want
  /// to use [synthesizeMappingsFromSpacedPhonemes]).
  final String refPhonemes;

  /// Per-character phoneme positions for the original Uthmani text.
  /// Length equals the Uthmani text length. `null` entries (if any)
  /// are treated as "unknown" by the aligner and silently skipped.
  final List<PhonemeMapping?> mappings;

  /// Per-chunk reference sifat. Length equals
  /// `chunkPhonemes(refPhonemes).length`.
  final List<SifaSnapshot> refSifatChunks;
}

// ─────────────────────────────────────────────────────────────────────────
//  Path A — rigorous: assumes the service returns `mappings`
// ─────────────────────────────────────────────────────────────────────────

/// Adapts a full phonetizer service response to a
/// [PhonetizerAdapterResult].
///
/// Inputs come straight from the parsed JSON: `phonemes` as a string,
/// `sifat` and `mappings` as `List<dynamic>` (whose elements are
/// `Map<dynamic, dynamic>` from `jsonDecode`).
PhonetizerAdapterResult adaptPhonetizerResult({
  required String phonemes,
  required List<dynamic> sifat,
  required List<dynamic> mappings,
}) =>
    PhonetizerAdapterResult(
      refPhonemes: phonemes,
      mappings: phonemeMappingsFromService(mappings),
      refSifatChunks: sifaSnapshotsFromService(sifat),
    );

/// Converts the service's `mappings` list to `List<PhonemeMapping?>`.
///
/// Each entry is expected to be `{"pos": [start, end], "deleted": bool}`.
/// Any extra fields (e.g. `tajweed_rules`) are silently ignored.
List<PhonemeMapping?> phonemeMappingsFromService(List<dynamic> raw) =>
    raw
        .map<PhonemeMapping?>((entry) {
          if (entry == null) return null;
          final m = entry as Map<dynamic, dynamic>;
          final pos = m['pos'] as List<dynamic>;
          return PhonemeMapping(
            start: (pos[0] as num).toInt(),
            end: (pos[1] as num).toInt(),
            deleted: (m['deleted'] as bool?) ?? false,
          );
        })
        .toList(growable: false);

/// Converts the service's `sifat` list to `List<SifaSnapshot>`.
///
/// Handles the field-name difference: the service uses `phonemes`
/// (the chunk text), while the core uses `phonemeGroup`.
List<SifaSnapshot> sifaSnapshotsFromService(List<dynamic> raw) =>
    raw.map<SifaSnapshot>(_oneSifaFromService).toList(growable: false);

SifaSnapshot _oneSifaFromService(dynamic entry) {
  final m = entry as Map<dynamic, dynamic>;
  return SifaSnapshot(
    phonemeGroup: m['phonemes'] as String,
    hamsOrJahr: m['hams_or_jahr'] as String?,
    shiddaOrRakhawa: m['shidda_or_rakhawa'] as String?,
    tafkheemOrTaqeeq: m['tafkheem_or_taqeeq'] as String?,
    itbaq: m['itbaq'] as String?,
    safeer: m['safeer'] as String?,
    qalqla: m['qalqla'] as String?,
    tikraar: m['tikraar'] as String?,
    tafashie: m['tafashie'] as String?,
    istitala: m['istitala'] as String?,
    ghonna: m['ghonna'] as String?,
  );
}

// ─────────────────────────────────────────────────────────────────────────
//  Path B — fallback: synthesize mappings from spaced phonemes alone
// ─────────────────────────────────────────────────────────────────────────

/// Synthesizes per-character [PhonemeMapping]s from an Uthmani text and a
/// space-preserved phoneme string.
///
/// Use this when your phonetizer service does NOT yet expose mappings.
/// Requires:
///   - The service was called with `removeSpaces: false` (the default).
///   - The phoneme string contains the same separator character between
///     words as the Uthmani text (the configured `alph.uthmani.space` —
///     typically ASCII space).
///   - Both texts split on whitespace into the same number of words.
///   - No word collapses entirely under phonetic transformation
///     (which can happen for mid-sentence hamzat-wasl in rare cases).
///
/// Algorithm
/// ─────────
///   1. Split both strings on whitespace.
///   2. For each Uthmani word, assign its character range to the
///      corresponding phoneme word's range, distributing positions
///      linearly inside the word.
///   3. Whitespace characters get `deleted: true` mappings.
///
/// The distribution is uniform: each Uthmani char's `(start, end)` is
/// proportional to its index within the word. This is good enough for
/// word-level slicing in `buildWordSpans` (which only inspects the
/// FIRST non-deleted start and the LAST non-deleted end), but is NOT
/// accurate at the character level — don't use it for character-level
/// error explanation.
///
/// Returns `null` (signaling "fall back to nothing") if word counts
/// disagree. Callers should treat that as an error condition.
List<PhonemeMapping?>? synthesizeMappingsFromSpacedPhonemes({
  required String uthmaniText,
  required String refPhonemes,
}) {
  // Word-span helper (matches the splitter used in buildWordSpans).
  List<(int, int)> wordSpansOf(String s) {
    final spans = <(int, int)>[];
    var i = 0;
    final n = s.length;
    while (i < n) {
      while (i < n && _isWs(s.codeUnitAt(i))) {
        i++;
      }
      if (i >= n) break;
      final start = i;
      while (i < n && !_isWs(s.codeUnitAt(i))) {
        i++;
      }
      spans.add((start, i));
    }
    return spans;
  }

  final uWords = wordSpansOf(uthmaniText);
  final pWords = wordSpansOf(refPhonemes);
  if (uWords.length != pWords.length) return null;

  final mappings = List<PhonemeMapping?>.filled(uthmaniText.length, null);

  for (var w = 0; w < uWords.length; w++) {
    final (uStart, uEnd) = uWords[w];
    final (pStart, pEnd) = pWords[w];
    final uLen = uEnd - uStart;
    final pLen = pEnd - pStart;

    if (uLen == 0) continue;

    // Distribute phoneme positions linearly across the word's chars.
    // Char k in the Uthmani word gets:
    //   start = pStart + floor(k * pLen / uLen)
    //   end   = pStart + floor((k + 1) * pLen / uLen)
    for (var k = 0; k < uLen; k++) {
      final s = pStart + (k * pLen) ~/ uLen;
      final e = pStart + ((k + 1) * pLen) ~/ uLen;
      mappings[uStart + k] = PhonemeMapping(start: s, end: e);
    }
  }

  // Fill whitespace positions with deleted mappings, pointing at the
  // most recent non-ws phoneme position (or 0 at the start).
  var lastPhonemePos = 0;
  for (var i = 0; i < uthmaniText.length; i++) {
    if (mappings[i] != null) {
      lastPhonemePos = mappings[i]!.end;
      continue;
    }
    mappings[i] = PhonemeMapping(
      start: lastPhonemePos,
      end: lastPhonemePos,
      deleted: true,
    );
  }

  return mappings;
}

/// Convenience: full Path-B adaptation in one call.
///
/// Combines [synthesizeMappingsFromSpacedPhonemes] with
/// [sifaSnapshotsFromService]. Returns `null` if word-count disagreement
/// prevents synthesis.
PhonetizerAdapterResult? adaptPhonetizerResultFromSpacedPhonemes({
  required String uthmaniText,
  required String phonemes,
  required List<dynamic> sifat,
}) {
  final synthesized = synthesizeMappingsFromSpacedPhonemes(
    uthmaniText: uthmaniText,
    refPhonemes: phonemes,
  );
  if (synthesized == null) return null;
  return PhonetizerAdapterResult(
    refPhonemes: phonemes,
    mappings: synthesized,
    refSifatChunks: sifaSnapshotsFromService(sifat),
  );
}

bool _isWs(int cu) =>
    cu == 0x20 || cu == 0x09 || cu == 0x0A || cu == 0x0D || cu == 0xA0;
