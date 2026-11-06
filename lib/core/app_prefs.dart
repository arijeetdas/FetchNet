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
  static const _kShowAnimations = 'settings.show_animations';
  static const _kLastEngineUpdateCheck = 'engine.last_update_check';
  static const _kHistory = 'downloads.history';
  static const _kYtThumbnails = 'youtube.thumbnail_downloads';
  static const _kYtTags = 'youtube.show_tags';
  static const _kYtAccount = 'youtube.account';
  static const _kYtSearchHistory = 'youtube.search_history';
  static const _kYtAutoplay = 'youtube.autoplay';
  static const _kYtQuality = 'youtube.quality';
  static const _kYtMusicCover = 'youtube.music_cover_art';
  static const _kYtVideoCover = 'youtube.video_cover_art';
  static const _kSites = 'home.sites';
  static const _kExtractors = 'engine.extractors';
  static const _kExtractorsVersion = 'engine.extractors_version';

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

  bool get showAnimations => _prefs.getBool(_kShowAnimations) ?? true;
  Future<void> setShowAnimations(bool value) => _prefs.setBool(_kShowAnimations, value);

  bool get autoUpdateEngine => _prefs.getBool(_kAutoUpdateEngine) ?? true;
  Future<void> setAutoUpdateEngine(bool value) => _prefs.setBool(_kAutoUpdateEngine, value);

  DateTime? get lastEngineUpdateCheck {
    final ms = _prefs.getInt(_kLastEngineUpdateCheck);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> markEngineUpdateChecked() =>
      _prefs.setInt(_kLastEngineUpdateCheck, DateTime.now().millisecondsSinceEpoch);

  // ───── YouTube ─────
  bool get youtubeThumbnailDownloads => _prefs.getBool(_kYtThumbnails) ?? false;
  Future<void> setYoutubeThumbnailDownloads(bool value) => _prefs.setBool(_kYtThumbnails, value);

  bool get youtubeShowTags => _prefs.getBool(_kYtTags) ?? false;
  Future<void> setYoutubeShowTags(bool value) => _prefs.setBool(_kYtTags, value);

  /// Recent YouTube searches, newest first.
  List<String> get youtubeSearchHistory => _prefs.getStringList(_kYtSearchHistory) ?? const [];
  Future<void> setYoutubeSearchHistory(List<String> value) => _prefs.setStringList(_kYtSearchHistory, value);

  /// Play the first "Up next" video when one ends.
  bool get youtubeAutoplay => _prefs.getBool(_kYtAutoplay) ?? true;
  Future<void> setYoutubeAutoplay(bool value) => _prefs.setBool(_kYtAutoplay, value);

  /// Preferred playback height (e.g. 720); 0 picks automatically.
  int get youtubeQuality => _prefs.getInt(_kYtQuality) ?? 0;
  Future<void> setYoutubeQuality(int value) => _prefs.setInt(_kYtQuality, value);

  /// music.youtube.com audio downloads get the square album cover embedded.
  bool get youtubeMusicCoverArt => _prefs.getBool(_kYtMusicCover) ?? true;
  Future<void> setYoutubeMusicCoverArt(bool value) => _prefs.setBool(_kYtMusicCover, value);

  /// Audio downloads of YouTube videos get the thumbnail as cover art.
  bool get youtubeVideoCoverArt => _prefs.getBool(_kYtVideoCover) ?? true;
  Future<void> setYoutubeVideoCoverArt(bool value) => _prefs.setBool(_kYtVideoCover, value);

  /// Last known Google account profile (JSON), shown while offline.
  String? get youtubeAccountJson => _prefs.getString(_kYtAccount);
  Future<void> setYoutubeAccountJson(String? value) =>
      value == null ? _prefs.remove(_kYtAccount) : _prefs.setString(_kYtAccount, value);

  // ───── Home sites (JSON list, user-added only) ─────
  List<String> get sitesJson => _prefs.getStringList(_kSites) ?? const [];
  Future<void> setSitesJson(List<String> value) => _prefs.setStringList(_kSites, value);

  // ───── yt-dlp extractor names, cached per yt-dlp version ─────
  String? get extractorsVersion => _prefs.getString(_kExtractorsVersion);
  List<String> get extractors => _prefs.getStringList(_kExtractors) ?? const [];
  Future<void> setExtractors(String version, List<String> names) async {
    await _prefs.setStringList(_kExtractors, names);
    await _prefs.setString(_kExtractorsVersion, version);
  }

  // ───── Download history (JSON list) ─────
  List<String> get historyJson => _prefs.getStringList(_kHistory) ?? const [];
  Future<void> setHistoryJson(List<String> value) => _prefs.setStringList(_kHistory, value);
}
