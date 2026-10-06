/// A deterministic [AyahReferenceLoader] for tests.
///
/// The real loader runs the phonetizer to turn Uthmani text into a reference
/// phoneme string plus a per-character [PhonemeMapping] list. Tests don't need
/// any of that fidelity — they only need *word spans* whose `phonemeText` is
/// known, so a scripted recitation can be made to match (low PER) or mismatch
/// (high PER) a chosen word.
///
/// [fakeAyahReference] therefore treats the supplied text as BOTH the Uthmani
/// text and the reference phoneme string (1:1), builds an identity
/// [PhonemeMapping] for every non-space character, and lets the real
/// [buildWordSpans] do the splitting. That keeps the span/chunk machinery
/// under test real while removing the phonetizer + ONNX from the loop.
library;

import 'package:quran_recitation_core/quran_recitation_core.dart';

/// Builds an [AyahReference] whose words are the whitespace-separated tokens of
/// [text], with each word's reference phonemes equal to the word itself.
///
/// IMPORTANT: tokens must be **Quran Phonetic Script (QPS)** — i.e. real Arabic
/// letters from `chunkPhonemes`' core set (`قَ`, `لَ`, `رَ`, `اا`, …). The PER
/// the session scores against is computed on `chunkPhonemes` output, and that
/// chunker's regex only recognises Arabic core letters; ASCII tokens chunk to
/// *nothing*, so every PER collapses to 0 and no word can ever lock. (The
/// existing `sifa_diffs_test.dart` uses the same QPS convention.)
///
/// To exercise the Madd-stretch path, give a token a run of 4+ identical
/// letters (e.g. `'اااا'`), which `_maddRepeat` (`(.)\1{3,}`) in the session
/// detects as an elongation.
AyahReference fakeAyahReference({
  required int sura,
  required int ayah,
  required String text,
}) {
  final mappings = <PhonemeMapping?>[];
  for (var i = 0; i < text.length; i++) {
    final isSpace = text.codeUnitAt(i) == 0x20;
    // Identity map: character i produces phoneme [i, i+1). Spaces produce no
    // phonemes (deleted) so word boundaries carry no reference phonemes.
    mappings.add(
      isSpace ? PhonemeMapping(start: i, end: i, deleted: true)
              : PhonemeMapping(start: i, end: i + 1),
    );
  }
  final spans = buildWordSpans(
    uthmaniText: text,
    refPhonemes: text,
    mappings: mappings,
  );
  return AyahReference(
    sura: sura,
    ayah: ayah,
    uthmaniText: text,
    refPhonemes: text,
    spans: spans,
  );
}

/// An [AyahReferenceLoader] backed by a map of `(sura, ayah) -> text`.
class FakeReferenceLoader implements AyahReferenceLoader {
  FakeReferenceLoader(this._texts);

  /// `(sura, ayah)` → ayah text (used as both Uthmani and phonemes).
  final Map<(int, int), String> _texts;

  @override
  Future<AyahReference> load({required int sura, required int ayah}) async {
    final text = _texts[(sura, ayah)];
    if (text == null) {
      throw ArgumentError('No fake reference for $sura:$ayah');
    }
    return fakeAyahReference(sura: sura, ayah: ayah, text: text);
  }
}
