import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedBookmark {
  const SavedBookmark({
    required this.surahNumber,
    required this.ayahNumber,
    required this.savedAt,
  });

  final int surahNumber;
  final int ayahNumber;
  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
    'surahNumber': surahNumber,
    'ayahNumber': ayahNumber,
    'savedAt': savedAt.toIso8601String(),
  };

  factory SavedBookmark.fromJson(Map<String, dynamic> json) {
    return SavedBookmark(
      surahNumber: json['surahNumber'] as int,
      ayahNumber: json['ayahNumber'] as int,
      savedAt: DateTime.parse(json['savedAt'] as String),
    );
  }
}

class SavedBookmarksStore {
  SavedBookmarksStore._();

  static final SavedBookmarksStore instance = SavedBookmarksStore._();

  static const String _storageKey = 'saved_bookmarks';

  final ValueNotifier<List<SavedBookmark>> bookmarks =
      ValueNotifier<List<SavedBookmark>>(<SavedBookmark>[]);

  SharedPreferences? _preferences;
  bool _loaded = false;
  bool _loading = false;

  Future<void> ensureLoaded() async {
    if (_loaded || _loading) {
      return;
    }

    _loading = true;
    _preferences ??= await SharedPreferences.getInstance();
    final raw = _preferences!.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw) as List<dynamic>;
      // Dedupe by (surah, ayah) keeping the most recent (first) entry.
      final seen = <String>{};
      bookmarks.value = decoded
          .map((entry) => SavedBookmark.fromJson(entry as Map<String, dynamic>))
          .where((b) => seen.add('${b.surahNumber}:${b.ayahNumber}'))
          .toList();
    }
    _loaded = true;
    _loading = false;
  }

  bool isAyahSaved(int surahNumber, int ayahNumber) {
    return bookmarks.value.any(
      (bookmark) =>
          bookmark.surahNumber == surahNumber &&
          bookmark.ayahNumber == ayahNumber,
    );
  }

  /// Adds or removes a bookmark for a single ayah. Returns true if the ayah is
  /// saved afterwards.
  Future<bool> toggleAyahBookmark({
    required int surahNumber,
    required int ayahNumber,
  }) async {
    await ensureLoaded();
    final current = List<SavedBookmark>.from(bookmarks.value);
    final existingIndex = current.indexWhere(
      (bookmark) =>
          bookmark.surahNumber == surahNumber &&
          bookmark.ayahNumber == ayahNumber,
    );
    final nowSaved = existingIndex < 0;
    if (nowSaved) {
      current.insert(
        0,
        SavedBookmark(
          surahNumber: surahNumber,
          ayahNumber: ayahNumber,
          savedAt: DateTime.now(),
        ),
      );
    } else {
      current.removeAt(existingIndex);
    }
    bookmarks.value = current;
    await _persist();
    return nowSaved;
  }

  Future<void> removeBookmark(int surahNumber, int ayahNumber) async {
    await ensureLoaded();
    final current = List<SavedBookmark>.from(bookmarks.value)
      ..removeWhere(
        (bookmark) =>
            bookmark.surahNumber == surahNumber &&
            bookmark.ayahNumber == ayahNumber,
      );
    bookmarks.value = current;
    await _persist();
  }

  Future<void> clear() async {
    await ensureLoaded();
    bookmarks.value = <SavedBookmark>[];
    await _persist();
  }

  /// Restores a previously cleared/removed list, e.g. for an "Undo" action.
  Future<void> restoreAll(List<SavedBookmark> items) async {
    await ensureLoaded();
    bookmarks.value = List<SavedBookmark>.from(items);
    await _persist();
  }

  Future<void> _persist() async {
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences!.setString(
      _storageKey,
      jsonEncode(bookmarks.value.map((bookmark) => bookmark.toJson()).toList()),
    );
  }
}
