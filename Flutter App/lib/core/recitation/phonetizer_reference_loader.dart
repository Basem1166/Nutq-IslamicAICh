import 'package:flutter/foundation.dart';
import 'package:quran_recitation_core/quran_recitation_core.dart';

import '../phonetizer_service.dart';

/// [AyahReferenceLoader] backed by the app's Chaquopy [PhonetizerService].
///
/// For each `(sura, ayah)` it fetches the Uthmani text and the phonetizer's
/// phoneme + sifat output, then builds the per-word reference spans the
/// streaming session aligns against.
///
/// Uses Path B (`adaptPhonetizerResultFromSpacedPhonemes`): the phonetizer is
/// called with `removeSpaces: false` so word-level mappings can be synthesised
/// from whitespace. If the Python side is later patched to emit per-char
/// `mappings`, [PhonetizerResult.mappings] is non-empty and Path A is used
/// automatically.
class PhonetizerReferenceLoader implements AyahReferenceLoader {
  const PhonetizerReferenceLoader();

  @override
  Future<AyahReference> load({required int sura, required int ayah}) async {
    final uthmaniText =
        await PhonetizerService.uthmaniTextAt(surah: sura, ayah: ayah);
    final result = await PhonetizerService.phonetize(
      uthmaniText: uthmaniText,
    );

    PhonetizerAdapterResult adapted;
    if (result.mappings.isNotEmpty) {
      debugPrint('[PhonetizerReferenceLoader] Using Path A: Exact character mappings from Python');
      adapted = adaptPhonetizerResult(
        phonemes: result.phonemes,
        sifat: result.sifat,
        mappings: result.mappings,
      );
    } else {
      debugPrint('[PhonetizerReferenceLoader] Using Path B: Fallback whitespace-synthesised mappings');
      final fallback = adaptPhonetizerResultFromSpacedPhonemes(
        uthmaniText: uthmaniText,
        phonemes: result.phonemes,
        sifat: result.sifat,
      );
      if (fallback == null) {
        throw Exception('Path B failed: word count mismatch between Uthmani text and phonemes.');
      }
      adapted = fallback;
    }

    return AyahReference(
      sura: sura,
      ayah: ayah,
      uthmaniText: uthmaniText,
      refPhonemes: adapted.refPhonemes,
      spans: buildWordSpans(
        uthmaniText: uthmaniText,
        refPhonemes: adapted.refPhonemes,
        mappings: adapted.mappings,
        refSifatChunks: adapted.refSifatChunks,
      ),
    );
  }
}
