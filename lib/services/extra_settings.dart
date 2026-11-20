import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_info.dart';

/// How downloaded subtitles are saved.
enum SubtitleMode {
  /// Next to the video, as their own files.
  file,

  /// Inside the video file (needs FFmpeg); no separate files.
  embed,

  /// Both.
  both,
}

/// Subtitle file format.
enum SubtitleFormat {
  srt('SRT', '.srt · works with almost every player'),
  vtt('VTT', '.vtt · web players and browsers'),
  ass('ASS', '.ass · keeps styling (anime, karaoke)'),
  best('Original', 'Whatever the site provides, unconverted');

  const SubtitleFormat(this.label, this.detail);

  final String label;
  final String detail;
}

/// Audio format of the quick download preset.
enum AudioPreset {
  mp3High('MP3 · 320 kbps'),
  mp3Medium('MP3 · 192 kbps'),
  mp3Low('MP3 · 128 kbps'),
  m4a('M4A · AAC'),
  original('Original · no re-encoding');

  const AudioPreset(this.label);

  final String label;
}

/// Settings → Extra Settings: subtitles, quick download presets, download
/// limits and copied-link detection. Kept in SharedPreferences; listeners
/// hear about every change.
class ExtraSettings extends ChangeNotifier {
  ExtraSettings(this._prefs);

  final SharedPreferences _prefs;

  static const _kSubs = 'extra.subtitles.enabled';
  static const _kSubsFormat = 'extra.subtitles.format';
  static const _kSubsLangs = 'extra.subtitles.languages';
  static const _kSubsAuto = 'extra.subtitles.auto_captions';
  static const _kSubsMode = 'extra.subtitles.mode';
  static const _kPresetVideo = 'extra.preset.video_height';
  static const _kPresetAudio = 'extra.preset.audio';
  static const _kPresetKind = 'extra.preset.kind';
  static const _kWifiOnly = 'extra.downloads.wifi_only';
  static const _kSpeedLimit = 'extra.downloads.speed_limit_kbps';
  static const _kMaxConcurrent = 'extra.downloads.max_concurrent';
  static const _kClipboard = 'extra.clipboard.detect';

  /// Highest number of downloads at once (the rest wait in the queue).
  static const maxConcurrentLimit = 10;

  /// Speed limits offered, in KB/s (0 = no limit).
  static const speedLimits = [0, 256, 512, 1024, 2048, 5120, 10240];

  /// Video heights of the quick preset (0 = best available).
  static const videoPresets = [0, 2160, 1440, 1080, 720, 480, 360];

  /// Languages offered for subtitles (code, name); `all` takes every one.
  static const subtitleLanguages = [
    ('all', 'All available'),
    ('en', 'English'),
    ('hi', 'Hindi'),
    ('bn', 'Bengali'),
    ('es', 'Spanish'),
    ('pt', 'Portuguese'),
    ('fr', 'French'),
    ('de', 'German'),
    ('it', 'Italian'),
    ('ar', 'Arabic'),
    ('ru', 'Russian'),
    ('ja', 'Japanese'),
    ('ko', 'Korean'),
    ('zh', 'Chinese'),
    ('id', 'Indonesian'),
    ('tr', 'Turkish'),
  ];

  // ───── Subtitles ─────

  bool get subtitles => _prefs.getBool(_kSubs) ?? false;

  SubtitleFormat get subtitleFormat =>
      SubtitleFormat.values.asNameMap()[_prefs.getString(_kSubsFormat)] ?? SubtitleFormat.srt;

  /// Language codes (`en`, `hi`, ...) or `all`.
  List<String> get subtitleLanguageCodes {
    final saved = _prefs.getStringList(_kSubsLangs);
    return saved == null || saved.isEmpty ? const ['en'] : saved;
  }

  /// Also take the site's automatic captions (YouTube) when a language has
  /// no subtitles of its own.
  bool get autoCaptions => _prefs.getBool(_kSubsAuto) ?? true;

  SubtitleMode get subtitleMode => SubtitleMode.values.asNameMap()[_prefs.getString(_kSubsMode)] ?? SubtitleMode.file;

  /// "Merge into the video": the subtitles become a track of the video file
  /// (FFmpeg keeps their timing, so they stay in sync).
  bool get mergeSubtitles => subtitleMode != SubtitleMode.file;

  /// With [mergeSubtitles]: also keep the separate subtitle files.
  bool get keepSubtitleFiles => subtitleMode == SubtitleMode.both;

  Future<void> setMergeSubtitles(bool merge) =>
      setSubtitleMode(!merge ? SubtitleMode.file : (keepSubtitleFiles ? SubtitleMode.both : SubtitleMode.embed));

  Future<void> setKeepSubtitleFiles(bool keep) =>
      setSubtitleMode(!mergeSubtitles ? SubtitleMode.file : (keep ? SubtitleMode.both : SubtitleMode.embed));

  Future<void> setSubtitles(bool v) => _set(() => _prefs.setBool(_kSubs, v));
  Future<void> setSubtitleFormat(SubtitleFormat v) => _set(() => _prefs.setString(_kSubsFormat, v.name));
  Future<void> setSubtitleLanguageCodes(List<String> v) => _set(() => _prefs.setStringList(_kSubsLangs, v));
  Future<void> setAutoCaptions(bool v) => _set(() => _prefs.setBool(_kSubsAuto, v));
  Future<void> setSubtitleMode(SubtitleMode v) => _set(() => _prefs.setString(_kSubsMode, v.name));

  // ───── Quick download presets ─────

  /// Preferred video height (0 = best available).
  int get presetVideoHeight => _prefs.getInt(_kPresetVideo) ?? 1080;

  AudioPreset get presetAudio => AudioPreset.values.asNameMap()[_prefs.getString(_kPresetAudio)] ?? AudioPreset.mp3High;

  /// What several videos of a playlist or channel download as.
  MediaKind get presetKind => _prefs.getString(_kPresetKind) == 'audio' ? MediaKind.audio : MediaKind.video;

  Future<void> setPresetVideoHeight(int v) => _set(() => _prefs.setInt(_kPresetVideo, v));
  Future<void> setPresetAudio(AudioPreset v) => _set(() => _prefs.setString(_kPresetAudio, v.name));
  Future<void> setPresetKind(MediaKind v) =>
      _set(() => _prefs.setString(_kPresetKind, v == MediaKind.audio ? 'audio' : 'video'));

  // ───── Downloads ─────

  /// Downloads wait while the phone is on mobile data.
  bool get wifiOnly => _prefs.getBool(_kWifiOnly) ?? false;

  /// Per-download speed limit in KB/s (0 = none).
  int get speedLimitKbps => _prefs.getInt(_kSpeedLimit) ?? 0;

  /// Downloads running at once (1–[maxConcurrentLimit]).
  int get maxConcurrent => (_prefs.getInt(_kMaxConcurrent) ?? 3).clamp(1, maxConcurrentLimit);

  Future<void> setWifiOnly(bool v) => _set(() => _prefs.setBool(_kWifiOnly, v));
  Future<void> setSpeedLimitKbps(int v) => _set(() => _prefs.setInt(_kSpeedLimit, v));
  Future<void> setMaxConcurrent(int v) => _set(() => _prefs.setInt(_kMaxConcurrent, v.clamp(1, maxConcurrentLimit)));

  // ───── Copied links ─────

  /// Home offers a link found on the clipboard.
  bool get detectClipboard => _prefs.getBool(_kClipboard) ?? true;

  Future<void> setDetectClipboard(bool v) => _set(() => _prefs.setBool(_kClipboard, v));

  // ───── Lyrics ─────

  static const _kLyrics = 'extra.lyrics.enabled';
  static const _kLyricsMode = 'extra.lyrics.mode';

  /// Songs downloaded as audio get their synced lyrics (when LRCLIB has
  /// them).
  bool get lyrics => _prefs.getBool(_kLyrics) ?? false;

  /// Inside the song, as a `.lrc` file next to it, or both (same choices as
  /// subtitles).
  SubtitleMode get lyricsMode => SubtitleMode.values.asNameMap()[_prefs.getString(_kLyricsMode)] ?? SubtitleMode.embed;
  bool get mergeLyrics => lyricsMode != SubtitleMode.file;
  bool get keepLyricsFile => lyricsMode == SubtitleMode.both;

  Future<void> setLyrics(bool v) => _set(() => _prefs.setBool(_kLyrics, v));
  Future<void> setLyricsMode(SubtitleMode v) => _set(() => _prefs.setString(_kLyricsMode, v.name));
  Future<void> setMergeLyrics(bool merge) =>
      setLyricsMode(!merge ? SubtitleMode.file : (keepLyricsFile ? SubtitleMode.both : SubtitleMode.embed));
  Future<void> setKeepLyricsFile(bool keep) =>
      setLyricsMode(!mergeLyrics ? SubtitleMode.file : (keep ? SubtitleMode.both : SubtitleMode.embed));

  // ───── Browser Mode ─────

  static const _kBlockAds = 'extra.browser.block_ads';

  /// Browser Mode blocks ads, trackers and pop-ups of the sites it opens.
  bool get blockAds => _prefs.getBool(_kBlockAds) ?? true;

  Future<void> setBlockAds(bool v) => _set(() => _prefs.setBool(_kBlockAds, v));

  static const _kClipboardLast = 'extra.clipboard.last_offered';

  /// The copied link offered last: each link is offered once.
  String? get lastOfferedLink => _prefs.getString(_kClipboardLast);
  Future<void> setLastOfferedLink(String url) => _prefs.setString(_kClipboardLast, url);

  Future<void> _set(Future<bool> Function() write) async {
    await write();
    notifyListeners();
  }

  /// yt-dlp / gallery-dl rate (`512K`, `2M`), or `null` without a limit.
  String? get rateArg {
    final k = speedLimitKbps;
    if (k <= 0) return null;
    return k % 1024 == 0 ? '${k ~/ 1024}M' : '${k}K';
  }

  static String speedLabel(int kbps) => kbps <= 0
      ? 'No limit'
      : kbps % 1024 == 0
          ? '${kbps ~/ 1024} MB/s'
          : '$kbps KB/s';

  static String videoPresetLabel(int height) => height <= 0 ? 'Best available' : '${height}p';
}

// ───── Subtitles for yt-dlp ─────

/// yt-dlp arguments that save subtitles with a video download, following
/// [settings]. [languages]: the exact tracks picked for one video (its
/// result view); otherwise the languages of the settings. Empty when
/// subtitles are off or the download isn't a video.
List<String> subtitleArgs(
  ExtraSettings settings, {
  required DownloadOption option,
  required bool ffmpeg,
  List<String>? languages,
}) {
  if (!settings.subtitles || option.kind != MediaKind.video || option.directUrl != null || option.gallery != null) {
    return const [];
  }
  final picked = languages;
  if (picked != null && picked.isEmpty) return const [];
  final codes = picked ??
      (settings.subtitleLanguageCodes.contains('all')
          ? const ['all']
          // `en` also takes `en-US`, `en-GB`, ...
          : [for (final c in settings.subtitleLanguageCodes) '$c(-.+)?']);
  final langs = [...codes, '-live_chat'].join(',');

  final format = settings.subtitleFormat;
  final formatArgs = switch (format) {
    SubtitleFormat.best => const ['--sub-format', 'best'],
    _ => ['--sub-format', '${format.name}/best', if (ffmpeg) ...['--convert-subs', format.name]],
  };
  // Embedding needs FFmpeg (and an MP4 / MKV, which FFmpeg merges to).
  final mode = ffmpeg ? settings.subtitleMode : SubtitleMode.file;
  final modeArgs = switch (mode) {
    SubtitleMode.file => const ['--write-subs'],
    // yt-dlp keeps the files it wrote unless told otherwise.
    SubtitleMode.embed => const ['--write-subs', '--embed-subs', '--compat-options', 'no-keep-subs'],
    SubtitleMode.both => const ['--write-subs', '--embed-subs'],
  };
  return [
    ...modeArgs,
    // Only for languages without subtitles of their own when picked from
    // settings; a track picked by name may be an automatic one.
    if (settings.autoCaptions || picked != null) '--write-auto-subs',
    '--sub-langs', langs,
    ...formatArgs,
  ];
}

/// One subtitle track a video offers.
class SubtitleTrack {
  const SubtitleTrack({required this.code, required this.name, required this.automatic});

  /// yt-dlp's language key (`en`, `en-US`, `hi-orig`, ...).
  final String code;
  final String name;

  /// Generated by the site (YouTube's automatic captions).
  final bool automatic;
}

/// The subtitle tracks of a video: its own subtitles, then the automatic
/// captions worth offering (the original language, and those [wanted]).
List<SubtitleTrack> subtitleTracksOf(MediaInfo info, {List<String> wanted = const []}) {
  String nameOf(Object? list, String code) {
    if (list is List && list.isNotEmpty && list.first is Map) {
      final n = (list.first as Map)['name'];
      if (n is String && n.trim().isNotEmpty) return n.trim();
    }
    return code;
  }

  final tracks = <SubtitleTrack>[];
  final own = info.raw['subtitles'];
  final ownCodes = <String>{};
  if (own is Map) {
    for (final e in own.entries) {
      final code = '${e.key}';
      if (code == 'live_chat') continue;
      ownCodes.add(code);
      tracks.add(SubtitleTrack(code: code, name: nameOf(e.value, code), automatic: false));
    }
  }
  final auto = info.raw['automatic_captions'];
  if (auto is Map) {
    final language = info.raw['language']?.toString();
    for (final e in auto.entries) {
      final code = '${e.key}';
      final base = code.split('-').first;
      if (ownCodes.any((c) => c.split('-').first == base)) continue;
      final original = code.endsWith('-orig') || (language != null && code == language);
      final asked = wanted.contains('all') ? original : wanted.contains(base);
      if (!original && !asked) continue;
      if (original && code != '$base-orig' && auto.containsKey('$base-orig')) continue;
      tracks.add(SubtitleTrack(code: code, name: nameOf(e.value, code), automatic: true));
    }
  }
  return tracks;
}

/// Which of [tracks] the settings pick for a video.
Set<String> defaultSubtitlePicks(List<SubtitleTrack> tracks, ExtraSettings settings) {
  final wanted = settings.subtitleLanguageCodes;
  final all = wanted.contains('all');
  return {
    for (final t in tracks)
      if ((all && !t.automatic) ||
          (all && t.automatic && t.code.endsWith('-orig') && settings.autoCaptions) ||
          (wanted.contains(t.code.split('-').first) && (!t.automatic || settings.autoCaptions)))
        t.code,
  };
}

// ───── Quick download presets ─────

/// A video download at the preset height, for videos whose formats weren't
/// looked up (several of a playlist at once).
DownloadOption presetVideoOption(int height, {required bool ffmpeg}) {
  final h = height <= 0 ? null : height;
  final cap = h == null ? '' : '[height<=$h]';
  return DownloadOption(
    kind: MediaKind.video,
    label: h == null ? 'Best' : '${h}p',
    detail: ffmpeg ? 'MP4' : null,
    extension: 'mp4',
    needsMerge: ffmpeg,
    formatArgs: ffmpeg
        ? ['-f', 'bv*$cap[ext=mp4]+ba[ext=m4a]/bv*$cap+ba/b$cap/bv*+ba/b', '--merge-output-format', 'mp4']
        : ['-f', 'b$cap/b'],
  );
}

/// An audio download in the preset format (without FFmpeg: the original
/// audio, which needs no conversion).
DownloadOption presetAudioOption(AudioPreset preset, {required bool ffmpeg}) {
  const meta = ['--embed-metadata'];
  if (!ffmpeg) {
    return const DownloadOption(
      kind: MediaKind.audio,
      label: 'Original',
      extension: 'm4a',
      formatArgs: ['-f', 'ba[ext=m4a]/ba/b'],
    );
  }
  return switch (preset) {
    AudioPreset.mp3High => const DownloadOption(
        kind: MediaKind.audio,
        label: 'MP3',
        detail: '320 kbps',
        extension: 'mp3',
        formatArgs: ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '320K', ...meta],
      ),
    AudioPreset.mp3Medium => const DownloadOption(
        kind: MediaKind.audio,
        label: 'MP3',
        detail: '192 kbps',
        extension: 'mp3',
        formatArgs: ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '192K', ...meta],
      ),
    AudioPreset.mp3Low => const DownloadOption(
        kind: MediaKind.audio,
        label: 'MP3',
        detail: '128 kbps',
        extension: 'mp3',
        formatArgs: ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '128K', ...meta],
      ),
    AudioPreset.m4a => const DownloadOption(
        kind: MediaKind.audio,
        label: 'M4A',
        detail: 'AAC',
        extension: 'm4a',
        formatArgs: ['-f', 'ba[ext=m4a]/ba/b', '-x', '--audio-format', 'm4a', ...meta],
      ),
    AudioPreset.original => const DownloadOption(
        kind: MediaKind.audio,
        label: 'Original',
        extension: 'm4a',
        formatArgs: ['-f', 'ba/b', '-x', '--audio-format', 'best', ...meta],
      ),
  };
}

/// Typical bitrate (kbps, picture and sound) of a download made with the
/// quick download preset, to estimate sizes from a video's length.
int presetBitrateKbps(ExtraSettings s, MediaKind kind) {
  if (kind == MediaKind.audio) {
    return switch (s.presetAudio) {
      AudioPreset.mp3High => 320,
      AudioPreset.mp3Medium => 192,
      AudioPreset.mp3Low => 128,
      AudioPreset.m4a || AudioPreset.original => 140,
    };
  }
  final h = s.presetVideoHeight <= 0 ? 1080 : s.presetVideoHeight;
  if (h >= 2160) return 18000;
  if (h >= 1440) return 9000;
  if (h >= 1080) return 4500;
  if (h >= 720) return 2600;
  if (h >= 480) return 1300;
  if (h >= 360) return 800;
  return 400;
}

/// Index of the option in [options] (a result's video qualities, highest
/// first) the preset picks: the highest at or below [height].
int presetVideoIndex(List<DownloadOption> options, int height) {
  if (height <= 0 || options.isEmpty) return 0;
  for (final (i, o) in options.indexed) {
    final p = int.tryParse(o.label.replaceAll(RegExp(r'p$'), ''));
    if (p != null && p <= height) return i;
  }
  return options.length - 1;
}

/// Index of the option in [options] (a result's audio formats) matching
/// [preset], or 0.
int presetAudioIndex(List<DownloadOption> options, AudioPreset preset) {
  bool matches(DownloadOption o) => switch (preset) {
        AudioPreset.mp3High => o.label == 'MP3' && (o.detail ?? '').startsWith('320'),
        AudioPreset.mp3Medium => o.label == 'MP3' && (o.detail ?? '').startsWith('192'),
        AudioPreset.mp3Low => o.label == 'MP3' && (o.detail ?? '').startsWith('128'),
        AudioPreset.m4a => o.label == 'M4A',
        AudioPreset.original => o.label == 'Original',
      };
  final i = options.indexWhere(matches);
  return i < 0 ? 0 : i;
}
