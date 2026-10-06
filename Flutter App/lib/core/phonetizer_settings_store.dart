import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user-configurable phonetizer (moshaf) attributes.
///
/// Defaults match [PhonetizerService._defaultMoshafAttr].
/// All four lengths are constrained to the integer range 2–6 units as defined
/// by the underlying Python phonetizer.
class PhonetizerSettingsStore {
  PhonetizerSettingsStore._();

  static final PhonetizerSettingsStore instance = PhonetizerSettingsStore._();

  // SharedPreferences keys
  static const String _kMaddMonfasel = 'phonetizer_madd_monfasel_len';
  static const String _kMaddMottasel = 'phonetizer_madd_mottasel_len';
  static const String _kMaddMottaselWaqf = 'phonetizer_madd_mottasel_waqf';
  static const String _kMaddAared = 'phonetizer_madd_aared_len';

  // Defaults (must match PhonetizerService._defaultMoshafAttr)
  static const int _defaultMaddMonfasel = 4;
  static const int _defaultMaddMottasel = 4;
  static const int _defaultMaddMottaselWaqf = 4;
  static const int _defaultMaddAared = 6;

  // Valid range for every madd length
  static const int minLen = 2;
  static const int maxLen = 6;

  final ValueNotifier<int> maddMonfaselLen =
      ValueNotifier<int>(_defaultMaddMonfasel);
  final ValueNotifier<int> maddMottaselLen =
      ValueNotifier<int>(_defaultMaddMottasel);
  final ValueNotifier<int> maddMottaselWaqf =
      ValueNotifier<int>(_defaultMaddMottaselWaqf);
  final ValueNotifier<int> maddAaredLen =
      ValueNotifier<int>(_defaultMaddAared);

  SharedPreferences? _prefs;
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _prefs ??= await SharedPreferences.getInstance();
    maddMonfaselLen.value =
        _prefs!.getInt(_kMaddMonfasel) ?? _defaultMaddMonfasel;
    maddMottaselLen.value =
        _prefs!.getInt(_kMaddMottasel) ?? _defaultMaddMottasel;
    maddMottaselWaqf.value =
        _prefs!.getInt(_kMaddMottaselWaqf) ?? _defaultMaddMottaselWaqf;
    maddAaredLen.value = _prefs!.getInt(_kMaddAared) ?? _defaultMaddAared;
    _loaded = true;
  }

  /// Returns the current settings as a map ready to pass as [moshafAttr].
  Map<String, dynamic> toMoshafAttr() => <String, dynamic>{
    'madd_monfasel_len': maddMonfaselLen.value,
    'madd_mottasel_len': maddMottaselLen.value,
    'madd_mottasel_waqf': maddMottaselWaqf.value,
    'madd_aared_len': maddAaredLen.value,
  };

  Future<void> setMaddMonfaselLen(int value) async {
    maddMonfaselLen.value = value.clamp(minLen, maxLen);
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setInt(_kMaddMonfasel, maddMonfaselLen.value);
  }

  Future<void> setMaddMottaselLen(int value) async {
    maddMottaselLen.value = value.clamp(minLen, maxLen);
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setInt(_kMaddMottasel, maddMottaselLen.value);
  }

  Future<void> setMaddMottaselWaqf(int value) async {
    maddMottaselWaqf.value = value.clamp(minLen, maxLen);
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setInt(_kMaddMottaselWaqf, maddMottaselWaqf.value);
  }

  Future<void> setMaddAaredLen(int value) async {
    maddAaredLen.value = value.clamp(minLen, maxLen);
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setInt(_kMaddAared, maddAaredLen.value);
  }

  Future<void> resetToDefaults() async {
    await Future.wait([
      setMaddMonfaselLen(_defaultMaddMonfasel),
      setMaddMottaselLen(_defaultMaddMottasel),
      setMaddMottaselWaqf(_defaultMaddMottaselWaqf),
      setMaddAaredLen(_defaultMaddAared),
    ]);
  }
}
