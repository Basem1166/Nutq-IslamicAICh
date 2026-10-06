import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the last surah:ayah the user practiced, so the recitation screen
/// resumes there. Mirrors the [SavedBookmarksStore] singleton/SharedPreferences
/// convention.
class RecitationProgressStore {
  RecitationProgressStore._();

  static final RecitationProgressStore instance = RecitationProgressStore._();

  static const String _surahKey = 'recitation_last_surah';
  static const String _ayahKey = 'recitation_last_ayah';

  SharedPreferences? _prefs;

  /// The latest known position, or null until first loaded/saved. Lets the home
  /// page reflect the resume point reactively.
  final ValueNotifier<RecitationPosition?> last =
      ValueNotifier<RecitationPosition?>(null);

  /// The last saved position, or the given defaults if nothing is stored yet.
  Future<RecitationPosition> loadLast({
    int defaultSurah = 1,
    int defaultAyah = 1,
  }) async {
    _prefs ??= await SharedPreferences.getInstance();
    final surah = _prefs!.getInt(_surahKey);
    final ayah = _prefs!.getInt(_ayahKey);
    final position = (surah == null || ayah == null)
        ? RecitationPosition(defaultSurah, defaultAyah)
        : RecitationPosition(surah, ayah);
    last.value = position;
    return position;
  }

  Future<void> save(int surah, int ayah) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setInt(_surahKey, surah);
    await _prefs!.setInt(_ayahKey, ayah);
    last.value = RecitationPosition(surah, ayah);
  }
}

class RecitationPosition {
  const RecitationPosition(this.surah, this.ayah);
  final int surah;
  final int ayah;
}
