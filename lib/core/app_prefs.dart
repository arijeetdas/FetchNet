import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Typed access to everything FetchNet keeps in SharedPreferences.
class AppPrefs {
  AppPrefs._(this._prefs);

  final SharedPreferences _prefs;

  static Future<AppPrefs> load() async => AppPrefs._(await SharedPreferences.getInstance());

  static const _kWelcomeSeen = 'onboarding.welcome_seen';
  static const _kDisclaimerAccepted = 'onboarding.disclaimer_accepted';
  static const _kDisclaimerAcceptedAt = 'onboarding.disclaimer_accepted_at';
  static const _kThemeMode = 'settings.theme_mode';
  static const _kAutoUpdateEngine = 'settings.auto_update_engine';
  static const _kLastEngineUpdateCheck = 'engine.last_update_check';
  static const _kHistory = 'downloads.history';

  // ───── Onboarding ─────
  bool get welcomeSeen => _prefs.getBool(_kWelcomeSeen) ?? false;
  Future<void> setWelcomeSeen() => _prefs.setBool(_kWelcomeSeen, true);

  bool get disclaimerAccepted => _prefs.getBool(_kDisclaimerAccepted) ?? false;
  Future<void> acceptDisclaimer() async {
    await _prefs.setBool(_kDisclaimerAccepted, true);
    await _prefs.setString(_kDisclaimerAcceptedAt, DateTime.now().toIso8601String());
  }

  // ───── Settings ─────
  ThemeMode get themeMode => switch (_prefs.getString(_kThemeMode)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
  Future<void> setThemeMode(ThemeMode mode) => _prefs.setString(_kThemeMode, mode.name);

  bool get autoUpdateEngine => _prefs.getBool(_kAutoUpdateEngine) ?? true;
  Future<void> setAutoUpdateEngine(bool value) => _prefs.setBool(_kAutoUpdateEngine, value);

  DateTime? get lastEngineUpdateCheck {
    final ms = _prefs.getInt(_kLastEngineUpdateCheck);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> markEngineUpdateChecked() =>
      _prefs.setInt(_kLastEngineUpdateCheck, DateTime.now().millisecondsSinceEpoch);

  // ───── Download history (JSON list) ─────
  List<String> get historyJson => _prefs.getStringList(_kHistory) ?? const [];
  Future<void> setHistoryJson(List<String> value) => _prefs.setStringList(_kHistory, value);
}
