import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the last surah:ayah the user read or practiced, so the home page
/// and recitation screen resume there, plus a per-surah reading history.
/// Mirrors the [SavedBookmarksStore] singleton/SharedPreferences convention.
class RecitationProgressStore {
  RecitationProgressStore._();

  static final RecitationProgressStore instance = RecitationProgressStore._();

  static const String _surahKey = 'recitation_last_surah';
  static const String _ayahKey = 'recitation_last_ayah';
  static const String _historyKey = 'reading_history';

  /// Maximum number of surahs kept in [history].
  static const int maxHistory = 50;

  SharedPreferences? _prefs;

  /// The latest known position, or null until first loaded/saved. Lets the home
  /// page reflect the resume point reactively.
  final ValueNotifier<RecitationPosition?> last =
      ValueNotifier<RecitationPosition?>(null);

  /// One entry per surah, most recently read first.
  final ValueNotifier<List<ReadingHistoryEntry>> history =
      ValueNotifier<List<ReadingHistoryEntry>>(<ReadingHistoryEntry>[]);

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

    final raw = _prefs!.getString(_historyKey);
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw) as List<dynamic>;
      history.value = decoded
          .map((e) => ReadingHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } else if (surah != null && ayah != null) {
      // Seed from the pre-history single position.
      history.value = [ReadingHistoryEntry(surah, ayah, DateTime.now())];
    }
    return position;
  }

  /// The last read ayah of [surah], or null if it was never opened.
  int? lastAyahOf(int surah) {
    for (final entry in history.value) {
      if (entry.surah == surah) return entry.ayah;
    }
    return null;
  }

  Future<void> save(int surah, int ayah) async {
    _prefs ??= await SharedPreferences.getInstance();
    last.value = RecitationPosition(surah, ayah);
    history.value = [
      ReadingHistoryEntry(surah, ayah, DateTime.now()),
      ...history.value.where((entry) => entry.surah != surah),
    ].take(maxHistory).toList();
    await _prefs!.setInt(_surahKey, surah);
    await _prefs!.setInt(_ayahKey, ayah);
    await _prefs!.setString(
      _historyKey,
      jsonEncode(history.value.map((entry) => entry.toJson()).toList()),
    );
  }
}

class RecitationPosition {
  const RecitationPosition(this.surah, this.ayah);
  final int surah;
  final int ayah;
}

class ReadingHistoryEntry {
  const ReadingHistoryEntry(this.surah, this.ayah, this.updatedAt);

  final int surah;
  final int ayah;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'surah': surah,
    'ayah': ayah,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ReadingHistoryEntry.fromJson(Map<String, dynamic> json) {
    return ReadingHistoryEntry(
      json['surah'] as int,
      json['ayah'] as int,
      DateTime.parse(json['updatedAt'] as String),
    );
  }
}
