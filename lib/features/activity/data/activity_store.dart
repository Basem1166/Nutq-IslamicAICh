import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A lightweight snapshot of the user's practice activity, surfaced on the home
/// page and the profile page.
class ActivitySummary {
  const ActivitySummary({
    required this.currentStreak,
    required this.todayMinutes,
    required this.goalMinutes,
  });

  final int currentStreak;
  final int todayMinutes;
  final int goalMinutes;

  static const ActivitySummary empty = ActivitySummary(
    currentStreak: 0,
    todayMinutes: 0,
    goalMinutes: ActivityStore.goalMinutes,
  );
}

/// Tracks how long the user practices each day and derives the streak + daily
/// goal progress. Persists a `{ 'yyyy-MM-dd': seconds }` map via
/// SharedPreferences, mirroring the [SavedBookmarksStore] convention.
class ActivityStore {
  ActivityStore._();

  static final ActivityStore instance = ActivityStore._();

  /// Daily practice target in minutes. A constant for now (no settings UI).
  static const int goalMinutes = 15;

  static const String _storageKey = 'activity_by_day';

  final ValueNotifier<ActivitySummary> summary =
      ValueNotifier<ActivitySummary>(ActivitySummary.empty);

  /// date key (yyyy-MM-dd) -> total seconds practiced that day.
  final Map<String, int> _secondsByDay = <String, int>{};

  SharedPreferences? _prefs;
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _secondsByDay
        ..clear()
        ..addAll(decoded.map((key, value) => MapEntry(key, (value as num).toInt())));
    }
    _loaded = true;
    _recompute();
  }

  Future<void> recordSession(Duration duration) async {
    if (duration.inSeconds <= 0) return;
    await ensureLoaded();
    final key = _dayKey(DateTime.now());
    _secondsByDay[key] = (_secondsByDay[key] ?? 0) + duration.inSeconds;
    await _persist();
    _recompute();
  }

  void _recompute() {
    final now = DateTime.now();
    final todaySeconds = _secondsByDay[_dayKey(now)] ?? 0;
    summary.value = ActivitySummary(
      currentStreak: _computeStreak(now),
      todayMinutes: (todaySeconds / 60).round(),
      goalMinutes: goalMinutes,
    );
  }

  /// Consecutive days (ending today) with any practice. If today has none but
  /// yesterday does, the run is anchored at yesterday so an active streak isn't
  /// reset to 0 until the day ends.
  int _computeStreak(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    var cursor = today;
    if ((_secondsByDay[_dayKey(today)] ?? 0) == 0) {
      cursor = today.subtract(const Duration(days: 1));
    }
    var streak = 0;
    while ((_secondsByDay[_dayKey(cursor)] ?? 0) > 0) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  Future<void> _persist() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_storageKey, jsonEncode(_secondsByDay));
  }

  String _dayKey(DateTime date) {
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '${date.year}-$m-$d';
  }
}
