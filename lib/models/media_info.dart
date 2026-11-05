import 'dart:convert';

enum MediaKind { video, audio }

/// One selectable download choice ("1080p", "MP3 · 320 kbps", ...).
class DownloadOption {
  const DownloadOption({
    required this.kind,
    required this.label,
    required this.formatArgs,
    required this.extension,
    this.detail,
    this.badge,
    this.sizeBytes,
    this.needsMerge = false,
  });

  final MediaKind kind;

  /// Main label, e.g. `1080p` or `MP3`.
  final String label;

  /// Secondary text, e.g. `60 fps · MP4` or `320 kbps`.
  final String? detail;

  /// Small highlight, e.g. `4K`, `HD`, `Best`.
  final String? badge;

  /// Estimated output size.
  final int? sizeBytes;

  /// Expected final file extension (for the rename dialog).
  final String extension;

  /// yt-dlp arguments that select / convert the format.
  final List<String> formatArgs;

  /// Whether video and audio are downloaded separately and merged.
  final bool needsMerge;
}

/// One entry of a playlist / channel URL.
class PlaylistEntry {
  const PlaylistEntry({required this.url, required this.title, this.duration, this.thumbnail});

  final String url;
  final String title;
  final double? duration;
  final String? thumbnail;
}

/// What yt-dlp reported for a link (`yt-dlp -J`).
class MediaInfo {
  MediaInfo({
    required this.url,
    required this.title,
    required this.raw,
    this.thumbnail,
    this.uploader,
    this.duration,
    this.extractor,
    this.viewCount,
    this.isLive = false,
    this.entries = const [],
    this.requestArgs = const [],
    this.preferAudio = false,
  });

  /// The URL yt-dlp should be given when downloading.
  final String url;
  final String title;
  final String? thumbnail;
  final String? uploader;
  final double? duration;
  final String? extractor;
  final int? viewCount;
  final bool isLive;

  /// Non-empty when the link was a playlist.
  final List<PlaylistEntry> entries;

  /// Extra yt-dlp arguments needed to reach this media again (cookies,
  /// referer, user agent from Browser Mode).
  final List<String> requestArgs;

  /// Open the result on the Audio tab (media picked as audio in Browser Mode).
  final bool preferAudio;

  final Map<String, dynamic> raw;

  bool get isPlaylist => entries.isNotEmpty;

  List<Map<String, dynamic>> get _formats {
    final list = raw['formats'];
    if (list is List && list.isNotEmpty) {
      return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    // Single-format extractors put the format fields at the top level.
    if (raw['url'] != null) return [raw];
    return const [];
  }

  static MediaInfo parse(String json, {required String sourceUrl, List<String> requestArgs = const []}) {
    // yt-dlp may print warnings before the JSON on some platforms.
    final start = json.indexOf('{');
    final end = json.lastIndexOf('}');
    if (start < 0 || end <= start) throw const FormatException('yt-dlp returned no data.');
    final map = (jsonDecode(json.substring(start, end + 1)) as Map).cast<String, dynamic>();

    final entries = <PlaylistEntry>[];
    if (map['_type'] == 'playlist' && map['entries'] is List) {
      for (final e in (map['entries'] as List).whereType<Map>()) {
        final url = (e['url'] ?? e['webpage_url'])?.toString();
        if (url == null) continue;
        entries.add(PlaylistEntry(
          url: url,
          title: (e['title'] ?? e['id'] ?? 'Untitled').toString(),
          duration: (e['duration'] as num?)?.toDouble(),
          thumbnail: _bestThumb(e.cast<String, dynamic>()),
        ));
      }
    }

    return MediaInfo(
      url: (map['webpage_url'] ?? map['original_url'] ?? sourceUrl).toString(),
      title: (map['title'] ?? map['fulltitle'] ?? map['id'] ?? 'Untitled').toString(),
      thumbnail: _bestThumb(map),
      uploader: (map['uploader'] ?? map['channel'] ?? map['creator'] ?? map['playlist_uploader'])?.toString(),
      duration: (map['duration'] as num?)?.toDouble(),
      extractor: (map['extractor_key'] ?? map['extractor'])?.toString(),
      viewCount: (map['view_count'] as num?)?.toInt(),
      isLive: map['is_live'] == true,
      entries: entries,
      requestArgs: requestArgs,
      raw: map,
    );
  }

  static String? _bestThumb(Map<String, dynamic> map) {
    final t = map['thumbnail']?.toString();
    if (t != null && t.startsWith('http')) return t;
    final thumbs = map['thumbnails'];
    if (thumbs is List && thumbs.isNotEmpty) {
      final last = thumbs.whereType<Map>().lastWhere((e) => e['url'] != null, orElse: () => const {});
      final url = last['url']?.toString();
      if (url != null && url.startsWith('http')) return url;
    }
    return null;
  }

  // ───── Options ─────

  static bool _hasVideo(Map<String, dynamic> f) {
    final v = f['vcodec']?.toString();
    if (v == 'none') return false;
    return v != null || f['height'] != null || f['width'] != null;
  }

  static bool _hasAudio(Map<String, dynamic> f) {
    final a = f['acodec']?.toString();
    if (a == 'none') return false;
    // Unknown codec info usually means a muxed stream (HLS, direct mp4).
    return true;
  }

  static int? _size(Map<String, dynamic> f, double? duration) {
    final s = (f['filesize'] ?? f['filesize_approx']) as num?;
    if (s != null && s > 0) return s.toInt();
    final tbr = (f['tbr'] as num?)?.toDouble();
    if (tbr != null && duration != null && duration > 0) return (tbr * 1000 / 8 * duration).round();
    return null;
  }

  Map<String, dynamic>? get _bestAudioOnly {
    final audio = _formats.where((f) => !_hasVideo(f) && _hasAudio(f) && f['acodec'] != null).toList();
    if (audio.isEmpty) return null;
    double score(Map<String, dynamic> f) => ((f['abr'] ?? f['tbr'] ?? 0) as num).toDouble();
    audio.sort((a, b) => score(b).compareTo(score(a)));
    return audio.first;
  }

  bool get hasAudio => _formats.isEmpty || _formats.any(_hasAudio);

  /// Video qualities, highest first.
  List<DownloadOption> videoOptions({required bool ffmpeg}) {
    final formats = _formats.where(_hasVideo).toList();
    final bestAudio = _bestAudioOnly;
    final audioSize = bestAudio == null ? null : _size(bestAudio, duration);

    // Best format per height.
    final byHeight = <int, Map<String, dynamic>>{};
    for (final f in formats) {
      final h = (f['height'] as num?)?.toInt();
      if (h == null || h <= 0) continue;
      final merge = !_hasAudio(f);
      if (merge && !ffmpeg) continue; // can't merge without FFmpeg
      final current = byHeight[h];
      double rank(Map<String, dynamic> x) =>
          ((x['fps'] ?? 0) as num).toDouble() * 10000 + ((x['tbr'] ?? 0) as num).toDouble();
      if (current == null || rank(f) > rank(current)) byHeight[h] = f;
    }

    final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
    final options = <DownloadOption>[];
    for (final h in heights) {
      final f = byHeight[h]!;
      final fps = (f['fps'] as num?)?.round();
      final merge = !_hasAudio(f);
      final videoSize = _size(f, duration);
      final size = videoSize == null ? null : videoSize + (merge ? (audioSize ?? 0) : 0);
      final selector = ffmpeg
          ? 'bv*[height=$h][ext=mp4]+ba[ext=m4a]/bv*[height=$h]+ba/b[height=$h]/bv*[height<=$h]+ba/b[height<=$h]/b'
          : 'b[height=$h]/b[height<=$h]/b';
      options.add(DownloadOption(
        kind: MediaKind.video,
        label: '${h}p',
        detail: [if (fps != null && fps > 30) '$fps fps', ffmpeg ? 'MP4' : (f['ext'] ?? 'video').toString().toUpperCase()]
            .join(' · '),
        badge: h >= 2160
            ? '4K'
            : h >= 1440
                ? '2K'
                : h >= 720
                    ? 'HD'
                    : null,
        sizeBytes: size,
        extension: ffmpeg ? 'mp4' : (f['ext'] ?? 'mp4').toString(),
        needsMerge: merge,
        formatArgs: ['-f', selector, if (ffmpeg) ...['--merge-output-format', 'mp4']],
      ));
    }

    if (options.isEmpty && (formats.isNotEmpty || _formats.isEmpty)) {
      options.add(DownloadOption(
        kind: MediaKind.video,
        label: 'Best available',
        detail: 'Highest quality the site offers',
        badge: 'Best',
        extension: ffmpeg ? 'mp4' : 'video',
        needsMerge: ffmpeg,
        formatArgs: ffmpeg ? ['-f', 'bv*+ba/b', '--merge-output-format', 'mp4'] : ['-f', 'b'],
      ));
    }
    return options;
  }

  /// Audio choices.
  List<DownloadOption> audioOptions({required bool ffmpeg}) {
    if (!hasAudio) return const [];
    final best = _bestAudioOnly;
    final abr = (best?['abr'] as num?)?.round();
    final codec = best == null ? null : _codecName(best);
    final bestSize = best == null ? null : _size(best, duration);
    int? estimate(int kbps) => duration == null ? null : (kbps * 1000 / 8 * duration!).round();

    if (!ffmpeg) {
      if (best == null) return const [];
      final ext = (best['ext'] ?? 'm4a').toString();
      return [
        DownloadOption(
          kind: MediaKind.audio,
          label: 'Original',
          detail: [ext.toUpperCase(), if (abr != null) '$abr kbps'].join(' · '),
          badge: 'Best',
          sizeBytes: bestSize,
          extension: ext,
          formatArgs: ['-f', '${best['format_id'] ?? 'ba'}/ba'],
        ),
      ];
    }

    const meta = ['--embed-metadata'];
    return [
      DownloadOption(
        kind: MediaKind.audio,
        label: 'MP3',
        detail: '320 kbps · plays everywhere',
        badge: 'Best',
        sizeBytes: estimate(320),
        extension: 'mp3',
        formatArgs: const ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '320K', ...meta],
      ),
      DownloadOption(
        kind: MediaKind.audio,
        label: 'MP3',
        detail: '192 kbps',
        sizeBytes: estimate(192),
        extension: 'mp3',
        formatArgs: const ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '192K', ...meta],
      ),
      DownloadOption(
        kind: MediaKind.audio,
        label: 'MP3',
        detail: '128 kbps · smallest',
        sizeBytes: estimate(128),
        extension: 'mp3',
        formatArgs: const ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '128K', ...meta],
      ),
      DownloadOption(
        kind: MediaKind.audio,
        label: 'M4A',
        detail: 'AAC · great for Apple devices',
        sizeBytes: estimate(abr ?? 160),
        extension: 'm4a',
        formatArgs: const ['-f', 'ba[ext=m4a]/ba/b', '-x', '--audio-format', 'm4a', ...meta],
      ),
      if (best != null)
        DownloadOption(
          kind: MediaKind.audio,
          label: 'Original',
          detail: [codec ?? 'Source', if (abr != null) '$abr kbps', 'no re-encoding'].join(' · '),
          sizeBytes: bestSize,
          extension: _originalAudioExt(best),
          formatArgs: ['-f', '${best['format_id'] ?? 'ba'}/ba/b', '-x', '--audio-format', 'best', ...meta],
        ),
    ];
  }

  static String? _codecName(Map<String, dynamic> f) {
    final c = f['acodec']?.toString().toLowerCase() ?? '';
    if (c.startsWith('opus')) return 'Opus';
    if (c.startsWith('mp4a') || c.contains('aac')) return 'AAC';
    if (c.startsWith('mp3')) return 'MP3';
    if (c.startsWith('vorbis')) return 'Vorbis';
    if (c.startsWith('flac')) return 'FLAC';
    return f['ext']?.toString().toUpperCase();
  }

  static String _originalAudioExt(Map<String, dynamic> f) {
    final c = f['acodec']?.toString().toLowerCase() ?? '';
    if (c.startsWith('opus')) return 'opus';
    if (c.startsWith('mp4a')) return 'm4a';
    if (c.startsWith('vorbis')) return 'ogg';
    return (f['ext'] ?? 'm4a').toString();
  }
}
