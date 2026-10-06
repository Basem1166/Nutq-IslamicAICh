import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the local (on-device) account profile. The app has no auth backend, so
/// "signing in" simply means storing a display name. Mirrors the
/// [SavedBookmarksStore] singleton/SharedPreferences convention.
class UserProfileStore {
  UserProfileStore._();

  static final UserProfileStore instance = UserProfileStore._();

  static const String _nameKey = 'profile_name';

  /// The current display name, or null when no profile is set yet (signed out).
  final ValueNotifier<String?> name = ValueNotifier<String?>(null);

  SharedPreferences? _prefs;
  bool _loaded = false;

  bool get isSignedIn => (name.value ?? '').trim().isNotEmpty;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _prefs ??= await SharedPreferences.getInstance();
    final stored = _prefs!.getString(_nameKey);
    name.value = (stored != null && stored.trim().isNotEmpty) ? stored : null;
    _loaded = true;
  }

  Future<void> saveName(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_nameKey, trimmed);
    name.value = trimmed;
  }

  Future<void> signOut() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_nameKey);
    name.value = null;
  }
}
