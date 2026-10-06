/// Letter-group chunking of Quran Phonetic Script (QPS) strings.
///
/// The QPS uses run-length encoding for Madds and Ghunnas: a 4-beat Madd
/// on alif is `اااا`, a 6-beat held meem is `مممم`, and so on. Doing edit
/// distance on raw characters counts each beat as a separate error, which
/// over-penalises long vowels. The chunker collapses each Uthmani-letter
/// group (one core consonant or madd-letter, with its optional vowel
/// diacritic) into a single token, so a 4-beat alif becomes one chunk
/// `اااا` instead of four.
///
/// Faithful port of `imports/utils.chunck_phonemes`. Verified to produce
/// identical output to the Python reference on:
///
///   `قَاالَ`  → `[قَ, اا, لَ]`
///   `الٓمٓ`    → `[ا, ل, م]`
///   `اااا`    → `[اااا]`
///   …
///
/// The Python original was named `chunck_phonemes` (typo); the Dart port
/// uses the correct spelling [chunkPhonemes].
library;

/// Core letters in QPS — each token in a chunk starts with one of these,
/// optionally repeated for Madd / Ghunna length encoding.
///
/// Order does not matter to the regex but is preserved verbatim from the
/// Python reference (`QuranPhoneticScriptGroups.core`) for diffability.
const String _core = 'ءبتثجحخدذرزسشصضطظعغفقكلمنهوياۥۦ۾ںـٲ';

/// Residual diacritics that may follow a core run: short vowels (fatha,
/// dama, kasra), qalqala marker, sakt, etc.
const String _residuals = 'َُِڇؙ۪ۜ';

final RegExp _chunkRegex = _buildChunkRegex();

RegExp _buildChunkRegex() {
  // For each core letter c, allow runs `c+`; combine via alternation, then
  // optionally consume a single residual. Mirrors the Python regex:
  //   core_group = "|".join(f"{c}+" for c in core)
  //   re.findall(f"((?:{core_group})[{residuals}]?)", text)
  final coreAlternation = _core.split('').map((c) => '$c+').join('|');
  return RegExp('((?:$coreAlternation)[$_residuals]?)');
}

/// Chunks a QPS string into letter-groups.
///
/// Each chunk is one core letter run plus an optional residual diacritic.
/// Concatenating the result reproduces the input minus any characters
/// that were neither core nor residual (which shouldn't occur for
/// well-formed QPS — the regex silently drops them).
///
/// Returns an empty list for an empty input. The result is unmodifiable;
/// wrap in `List.of(...)` if you need to mutate.
List<String> chunkPhonemes(String phonetic) {
  if (phonetic.isEmpty) return const <String>[];
  return List<String>.unmodifiable(
    _chunkRegex.allMatches(phonetic).map((m) => m.group(0)!),
  );
}
