import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/creator_job.dart';

/// Settings → Creator Settings: clips of videos and songs, Shorts / Reels
/// conversion and snapshots. Everything is off until turned on. Works on
/// any site yt-dlp can cut (YouTube and most others); needs FFmpeg.
class CreatorSettings extends ChangeNotifier {
  CreatorSettings(this._prefs);

  final SharedPreferences _prefs;

  static const _kVideoClips = 'creator.clips.video';
  static const _kAudioClips = 'creator.clips.audio';
  static const _kExactCuts = 'creator.clips.exact_cuts';
  static const _kShorts = 'creator.shorts.enabled';
  static const _kShortsBackground = 'creator.shorts.background';
  static const _kSnapshots = 'creator.snapshots.enabled';
  static const _kSnapshotFormat = 'creator.snapshots.format';

  /// Video downloads can be a part of the video.
  bool get videoClips => _prefs.getBool(_kVideoClips) ?? false;

  /// Audio downloads can be a part of the song.
  bool get audioClips => _prefs.getBool(_kAudioClips) ?? false;

  /// Cuts exactly where asked (a second or two around each cut is
  /// re-encoded), instead of at the nearest keyframe.
  bool get exactCuts => _prefs.getBool(_kExactCuts) ?? true;

  /// Landscape video clips become 9:16 portrait for Shorts and Reels.
  bool get shorts => _prefs.getBool(_kShorts) ?? false;

  /// What fills the space around a landscape clip made portrait.
  ShortsBackground get shortsBackground => ShortsBackground.values.asNameMap()[_prefs.getString(_kShortsBackground)] ?? ShortsBackground.black;

  /// The Thumbnail tab can save a frame of the video.
  bool get snapshots => _prefs.getBool(_kSnapshots) ?? false;

  SnapshotFormat get snapshotFormat => SnapshotFormat.values.asNameMap()[_prefs.getString(_kSnapshotFormat)] ?? SnapshotFormat.jpg;

  Future<void> setVideoClips(bool v) => _set(() => _prefs.setBool(_kVideoClips, v));
  Future<void> setAudioClips(bool v) => _set(() => _prefs.setBool(_kAudioClips, v));
  Future<void> setExactCuts(bool v) => _set(() => _prefs.setBool(_kExactCuts, v));
  Future<void> setShorts(bool v) => _set(() => _prefs.setBool(_kShorts, v));
  Future<void> setShortsBackground(ShortsBackground v) => _set(() => _prefs.setString(_kShortsBackground, v.name));
  Future<void> setSnapshots(bool v) => _set(() => _prefs.setBool(_kSnapshots, v));
  Future<void> setSnapshotFormat(SnapshotFormat v) => _set(() => _prefs.setString(_kSnapshotFormat, v.name));

  Future<void> _set(Future<bool> Function() write) async {
    await write();
    notifyListeners();
  }
}
