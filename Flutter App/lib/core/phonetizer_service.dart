import 'package:flutter/services.dart';
import 'dart:convert';

class PhonetizerResult {
  const PhonetizerResult({
    required this.phonemes,
    required this.sifat,
    this.mappings = const <Map<String, dynamic>?>[],
  });

  factory PhonetizerResult.fromJson(Map<dynamic, dynamic> json) {
    final phonemes = json['phonemes'] as String? ?? '';
    final sifat = (json['sifat'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();

    // Optional per-Uthmani-char phoneme mappings (Path A). Absent until the
    // Python phonetizer is patched to emit them; the streaming reference loader
    // falls back to whitespace-synthesised mappings when this is empty.
    final mappings = (json['mappings'] as List? ?? const [])
        .map<Map<String, dynamic>?>(
          (item) => item is Map ? item.cast<String, dynamic>() : null,
        )
        .toList();

    return PhonetizerResult(
      phonemes: phonemes,
      sifat: sifat,
      mappings: mappings,
    );
  }

  final String phonemes;
  final List<Map<String, dynamic>> sifat;

  /// Per-Uthmani-char phoneme position mappings. Empty unless the Python side
  /// emits `mappings` (Path A); the loader synthesises word-level mappings from
  /// spaced phonemes otherwise (Path B).
  final List<Map<String, dynamic>?> mappings;
}

class PhonetizerService {
  PhonetizerService._();

  static const MethodChannel _channel = MethodChannel('phonetizer');
  static const Map<String, dynamic> _defaultMoshafAttr = <String, dynamic>{
    'rewaya': 'hafs',
    'madd_monfasel_len': 4,
    'madd_mottasel_len': 4,
    'madd_mottasel_waqf': 4,
    'madd_aared_len': 6,
  };

  static Future<PhonetizerResult> phonetize({
    required String uthmaniText,
    Map<String, dynamic> moshafAttr = const <String, dynamic>{},
    bool removeSpaces = false,
  }) async {
    final mergedAttr = <String, dynamic>{..._defaultMoshafAttr, ...moshafAttr};

    print('Phonetizer mergedAttr: $mergedAttr');

    final responseText = await _channel
        .invokeMethod<String>('phonetize', <String, dynamic>{
          'uthmaniText': uthmaniText,
          'moshafAttr': mergedAttr,
          'removeSpaces': removeSpaces,
        });

    if (responseText == null) {
      throw PlatformException(
        code: 'PHONETIZER_NULL',
        message: 'The phonetizer returned no result.',
      );
    }

    final decoded = jsonDecode(responseText);
    if (decoded is! Map) {
      throw PlatformException(
        code: 'PHONETIZER_BAD_RESPONSE',
        message: 'The phonetizer returned an invalid response.',
      );
    }

    return PhonetizerResult.fromJson(decoded.cast<dynamic, dynamic>());
  }

  /// Load the bundled Quran JSON and phonetize by `surah` and `ayah` (1-based).
  static Future<PhonetizerResult> phonetizeByLocation({
    required int surah,
    required int ayah,
    Map<String, dynamic> moshafAttr = const <String, dynamic>{},
    bool removeSpaces = false,
  }) async {
    final uthmani = await uthmaniTextAt(surah: surah, ayah: ayah);
    return phonetize(
      uthmaniText: uthmani,
      moshafAttr: moshafAttr,
      removeSpaces: removeSpaces,
    );
  }

  /// Decoded Quran JSON, cached so repeated lookups don't re-parse the
  /// multi-megabyte asset (decoding it per ayah janks the UI thread badly).
  static Map<dynamic, dynamic>? _quranCache;
  static Future<Map<dynamic, dynamic>>? _quranLoading;

  static Future<Map<dynamic, dynamic>> _loadQuran() {
    final cached = _quranCache;
    if (cached != null) return Future<Map<dynamic, dynamic>>.value(cached);
    return _quranLoading ??= () async {
      final jsonStr = await rootBundle.loadString(
        'assets/quran/quran-uthmani-imlaey.json',
      );
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) {
        throw PlatformException(
          code: 'QURAN_BAD_FORMAT',
          message: 'Quran JSON is not an object',
        );
      }
      _quranCache = decoded;
      _quranLoading = null;
      return decoded;
    }();
  }

  /// Returns the `@uthmani` text for `surah`/`ayah` (1-based) from the bundled
  /// Quran JSON. Throws a [PlatformException] if the location is invalid.
  static Future<String> uthmaniTextAt({
    required int surah,
    required int ayah,
  }) async {
    final decoded = await _loadQuran();

    try {
      final suras = (decoded['quran'] as Map?)?['sura'] as List?;
      if (suras == null || surah < 1 || surah > suras.length) {
        throw PlatformException(
          code: 'QURAN_SURAH_NOT_FOUND',
          message: 'Surah $surah not found',
        );
      }

      final suraObj = suras[surah - 1] as Map;
      final ayas = (suraObj['aya'] as List?);
      if (ayas == null || ayah < 1 || ayah > ayas.length) {
        throw PlatformException(
          code: 'QURAN_AYAH_NOT_FOUND',
          message: 'Ayah $ayah not found in surah $surah',
        );
      }

      final ayObj = ayas[ayah - 1] as Map;
      final uthmani = ayObj['@uthmani'] as String?;
      if (uthmani == null || uthmani.isEmpty) {
        throw PlatformException(
          code: 'QURAN_UTHMANI_EMPTY',
          message: 'No @uthmani text for $surah:$ayah',
        );
      }
      return uthmani;
    } catch (e) {
      if (e is PlatformException) rethrow;
      throw PlatformException(
        code: 'QURAN_PARSE_ERROR',
        message: 'Failed to parse Quran JSON',
        details: e.toString(),
      );
    }
  }
}
