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
      bookmarks.value = decoded
          .map((entry) => SavedBookmark.fromJson(entry as Map<String, dynamic>))
          .toList();
    }
    _loaded = true;
    _loading = false;
  }

  bool isSaved(int surahNumber) {
    return bookmarks.value.any(
      (bookmark) => bookmark.surahNumber == surahNumber,
    );
  }

  SavedBookmark? bookmarkForSurah(int surahNumber) {
    for (final bookmark in bookmarks.value) {
      if (bookmark.surahNumber == surahNumber) {
        return bookmark;
      }
    }
    return null;
  }

  Future<void> toggleSurahBookmark({
    required int surahNumber,
    required int ayahNumber,
  }) async {
    await ensureLoaded();

    final current = List<SavedBookmark>.from(bookmarks.value);
    final existingIndex = current.indexWhere(
      (bookmark) => bookmark.surahNumber == surahNumber,
    );

    if (existingIndex >= 0) {
      current.removeAt(existingIndex);
    } else {
      current.insert(
        0,
        SavedBookmark(
          surahNumber: surahNumber,
          ayahNumber: ayahNumber,
          savedAt: DateTime.now(),
        ),
      );
    }

    bookmarks.value = current;
    await _persist();
  }

  Future<void> removeSurah(int surahNumber) async {
    await ensureLoaded();
    final current = List<SavedBookmark>.from(bookmarks.value)
      ..removeWhere((bookmark) => bookmark.surahNumber == surahNumber);
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
