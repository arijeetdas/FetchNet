/// What fills the space around a landscape clip made portrait (9:16).
enum ShortsBackground {
  black('Black', 'Black bars above and below the video'),
  blur('Blurred video', 'The same video, enlarged and blurred, like YouTube');

  const ShortsBackground(this.label, this.detail);

  final String label;
  final String detail;
}

/// Snapshot picture format.
enum SnapshotFormat {
  jpg('JPG', 'Smaller files, shares anywhere'),
  png('PNG', 'Lossless, larger files');

  const SnapshotFormat(this.label, this.detail);

  final String label;
  final String detail;

  String get extension => name;
}

/// A creator's download: a clip of a video or song (optionally made 9:16
/// for Shorts / Reels), or one frame of a video (a snapshot).
class CreatorJob {
  const CreatorJob.clip({
    required Duration this.start,
    required Duration this.end,
    this.exactCuts = true,
    this.shorts = false,
    this.background = ShortsBackground.black,
  }) : snapshotAt = null,
       snapshotFormat = SnapshotFormat.jpg;

  const CreatorJob.snapshot({required Duration at, this.snapshotFormat = SnapshotFormat.jpg})
    : snapshotAt = at,
      start = null,
      end = null,
      exactCuts = true,
      shorts = false,
      background = ShortsBackground.black;

  final Duration? start;
  final Duration? end;
  final bool exactCuts;

  /// Make a landscape clip 9:16 portrait.
  final bool shorts;
  final ShortsBackground background;

  final Duration? snapshotAt;
  final SnapshotFormat snapshotFormat;

  bool get isSnapshot => snapshotAt != null;
  bool get isClip => start != null && end != null;
  Duration get length => isClip ? end! - start! : Duration.zero;

  /// How long the piece yt-dlp downloads for a snapshot (cut exactly at
  /// [snapshotAt], so its first frame is the moment).
  static const snapshotSpan = Duration(seconds: 2);

  /// yt-dlp arguments: download only this part.
  List<String> ytDlpArgs() {
    if (isSnapshot) {
      final at = snapshotAt!;
      return ['--download-sections', '*${sectionTime(at)}-${sectionTime(at + snapshotSpan)}', '--force-keyframes-at-cuts'];
    }
    if (!isClip) return const [];
    return ['--download-sections', '*${sectionTime(start!)}-${sectionTime(end!)}', if (exactCuts) '--force-keyframes-at-cuts'];
  }

  /// "Clip 1:10–1:40 · 9:16" / "Snapshot at 0:42" for History.
  String describe() {
    if (isSnapshot) return 'Snapshot at ${clockLabel(snapshotAt!)} · ${snapshotFormat.label}';
    return ['Clip ${clockLabel(start!)}–${clockLabel(end!)}', if (shorts) '9:16'].join(' · ');
  }

  /// "(clip 1m10s-1m40s)" / "(at 0m42s)", for file names (no colons:
  /// Windows doesn't allow them).
  String nameSuffix() => isSnapshot ? '(at ${fileTime(snapshotAt!)})' : '(clip ${fileTime(start!)}-${fileTime(end!)})';

  Map<String, dynamic> toJson() => {
    if (start != null) 'start': start!.inMilliseconds,
    if (end != null) 'end': end!.inMilliseconds,
    if (isClip) 'exact': exactCuts,
    if (shorts) 'shorts': background.name,
    if (snapshotAt != null) 'snapshot': snapshotAt!.inMilliseconds,
    if (snapshotAt != null) 'format': snapshotFormat.name,
  };

  static CreatorJob? fromJson(Object? j) {
    if (j is! Map) return null;
    Duration? ms(Object? v) => v is num ? Duration(milliseconds: v.toInt()) : null;
    final snap = ms(j['snapshot']);
    if (snap != null) {
      return CreatorJob.snapshot(at: snap, snapshotFormat: SnapshotFormat.values.asNameMap()[j['format']] ?? SnapshotFormat.jpg);
    }
    final start = ms(j['start']), end = ms(j['end']);
    if (start == null || end == null || end <= start) return null;
    final shorts = j['shorts'];
    return CreatorJob.clip(
      start: start,
      end: end,
      exactCuts: j['exact'] != false,
      shorts: shorts is String,
      background: ShortsBackground.values.asNameMap()[shorts] ?? ShortsBackground.black,
    );
  }
}

/// Seconds for yt-dlp's --download-sections ("70.5").
String sectionTime(Duration d) {
  final ms = d.inMilliseconds;
  final s = ms ~/ 1000, rest = ms % 1000;
  return rest == 0 ? '$s' : '$s.${rest.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '')}';
}

/// "1:05", "1:02:03", "0:07.5".
String clockLabel(Duration d) {
  final total = d.inMilliseconds;
  final h = total ~/ 3600000, m = (total % 3600000) ~/ 60000, s = (total % 60000) ~/ 1000, tenth = (total % 1000) ~/ 100;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  final base = h > 0 ? '$h:$mm:${s.toString().padLeft(2, '0')}' : '$mm:${s.toString().padLeft(2, '0')}';
  return tenth > 0 ? '$base.$tenth' : base;
}

/// "1m10s", "1h02m03s" (file names).
String fileTime(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  return h > 0 ? '${h}h${m.toString().padLeft(2, '0')}m${s.toString().padLeft(2, '0')}s' : '${m}m${s.toString().padLeft(2, '0')}s';
}

/// Reads "1:05", "1:02:03", "65", "1:05.5" (also with a comma); `null` when
/// it isn't a time.
Duration? parseClock(String text) {
  final t = text.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final parts = t.split(':');
  if (parts.length > 3) return null;
  var ms = 0.0;
  for (final part in parts) {
    final v = double.tryParse(part);
    if (v == null || v < 0) return null;
    ms = ms * 60 + v;
  }
  // Minutes and seconds after the first part must be under 60.
  for (final part in parts.skip(1)) {
    if ((double.tryParse(part) ?? 60) >= 60) return null;
  }
  return Duration(milliseconds: (ms * 1000).round());
}

/// A video's picture size as shown (rotation applied).
class VideoShape {
  const VideoShape(this.width, this.height);

  final int width;
  final int height;

  bool get landscape => width > height;

  /// From ffprobe's JSON (`-show_entries stream=width,height:stream_side_data=rotation:stream_tags=rotate`).
  static VideoShape? fromProbe(Map<String, dynamic> json) {
    final streams = json['streams'];
    if (streams is! List || streams.isEmpty || streams.first is! Map) return null;
    final s = (streams.first as Map).cast<String, dynamic>();
    final w = (s['width'] as num?)?.toInt(), h = (s['height'] as num?)?.toInt();
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    num? rotation;
    final side = s['side_data_list'];
    if (side is List) {
      for (final d in side) {
        if (d is Map && d['rotation'] is num) rotation = d['rotation'] as num;
      }
    }
    final tags = s['tags'];
    if (rotation == null && tags is Map) rotation = num.tryParse('${tags['rotate'] ?? ''}');
    final turned = rotation != null && (rotation.abs() % 180) == 90;
    return turned ? VideoShape(h, w) : VideoShape(w, h);
  }
}

/// FFmpeg arguments that turn a landscape clip into a 9:16 portrait video
/// for Shorts / Reels without cropping it: the whole picture, scaled to the
/// width, on black or on a blurred copy of itself. Never upscales: the
/// canvas is at most 1080×1920 and no wider than the clip is tall.
List<String> shortsArgs({required String input, required String output, required VideoShape shape, required ShortsBackground background}) {
  int even(num v) => (v / 2).floor() * 2;
  final w = even(shape.height < 1080 ? shape.height : 1080).clamp(240, 1080);
  final h = even(w * 16 / 9);
  final fg = '[0:v]scale=$w:-2:flags=lanczos,setsar=1';
  final String graph;
  if (background == ShortsBackground.blur) {
    // Blurred at a quarter size (fast), then stretched back.
    final bw = even(w / 4), bh = even(h / 4);
    graph =
        '[0:v]scale=$bw:$bh:force_original_aspect_ratio=increase,crop=$bw:$bh,boxblur=14:2,'
        'scale=$w:$h,setsar=1,eq=brightness=-0.08[bg];'
        '$fg[fg];[bg][fg]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2,format=yuv420p[v]';
  } else {
    graph = '$fg,pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p[v]';
  }
  return [
    '-hide_banner', '-y', '-i', input, //
    '-filter_complex', graph,
    '-map', '[v]', '-map', '0:a?',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
    '-c:a', 'aac', '-b:a', '192k',
    '-movflags', '+faststart',
    '-progress', 'pipe:1', '-nostats',
    output,
  ];
}

/// FFmpeg arguments that save a frame of [input] as a picture: the first,
/// or the one at [seek] (a whole download cut on the device).
List<String> snapshotArgs({required String input, required String output, required SnapshotFormat format, Duration? seek}) => [
  '-hide_banner', '-y', if (seek != null) ...['-ss', sectionTime(seek)], '-i', input, //
  '-frames:v', '1',
  if (format == SnapshotFormat.jpg) ...['-q:v', '2'],
  '-update', '1',
  output,
];

/// ffprobe arguments for [VideoShape.fromProbe].
List<String> probeArgs(String input) => [
  '-v', 'error', '-select_streams', 'v:0', //
  '-show_entries', 'stream=width,height:stream_side_data=rotation:stream_tags=rotate',
  '-of', 'json', input,
];

/// FFmpeg arguments that cut [job]'s part out of a whole download (when
/// yt-dlp couldn't download just the part). A video with exact cuts is
/// re-encoded (H.264 + AAC, MP4); otherwise the streams are copied as they
/// are, which cuts at the nearest keyframe.
List<String> cutArgs({required String input, required String output, required CreatorJob job, required bool video}) => [
  '-hide_banner', '-y', '-ss', sectionTime(job.start!), '-i', input, '-t', sectionTime(job.length), //
  '-map', '0:v?', '-map', '0:a?',
  if (video && job.exactCuts) ...[
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '18',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-b:a',
    '192k',
  ] else ...[
    '-c',
    'copy',
  ],
  '-avoid_negative_ts', 'make_zero',
  '-progress', 'pipe:1', '-nostats',
  output,
];

/// FFmpeg's "time=00:01:02.50" (its progress while yt-dlp has it download
/// a part).
final ffmpegTime = RegExp(r'time=(\d+):(\d{2}):(\d{2}(?:\.\d+)?)');

/// The time in an FFmpeg progress line, or `null`.
Duration? ffmpegTimeOf(String line) {
  final m = ffmpegTime.firstMatch(line);
  if (m == null) return null;
  final secs = int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + double.parse(m.group(3)!);
  return Duration(milliseconds: (secs * 1000).round());
}
