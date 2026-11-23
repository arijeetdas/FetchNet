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
    // No --force-keyframes-at-cuts: yt-dlp would re-encode the part while
    // downloading it (minutes for a VP9 clip). The direct cut (see
    // streamClipArgs) is the exact one; this is its fallback.
    return ['--download-sections', '*${sectionTime(start!)}-${sectionTime(end!)}'];
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

/// The 9:16 filter graph of [shortsArgs] (output `[v]`) for the video at
/// [input]: the whole picture, scaled to the width, on black or on a blurred
/// copy of itself. Never upscales: the canvas is at most 1080×1920 and no
/// wider than the clip is tall.
String shortsGraph(VideoShape shape, ShortsBackground background, {String input = '[0:v]'}) {
  int even(num v) => (v / 2).floor() * 2;
  final w = even(shape.height < 1080 ? shape.height : 1080).clamp(240, 1080);
  final h = even(w * 16 / 9);
  final fg = '${input}scale=$w:-2:flags=lanczos,setsar=1';
  final String graph;
  if (background == ShortsBackground.blur) {
    // Blurred at a quarter size (fast), then stretched back.
    final bw = even(w / 4), bh = even(h / 4);
    graph =
        '${input}scale=$bw:$bh:force_original_aspect_ratio=increase,crop=$bw:$bh,boxblur=14:2,'
        'scale=$w:$h,setsar=1,eq=brightness=-0.08[bg];'
        '$fg[fg];[bg][fg]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2,format=yuv420p[v]';
  } else {
    graph = '$fg,pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p[v]';
  }
  return graph;
}

/// FFmpeg arguments that turn a landscape clip into a 9:16 portrait video
/// for Shorts / Reels without cropping it (see [shortsGraph]).
List<String> shortsArgs({
  required String input,
  required String output,
  required VideoShape shape,
  required ShortsBackground background,
  String preset = 'veryfast',
}) {
  final graph = shortsGraph(shape, background);
  return [
    '-hide_banner', '-y', '-i', input, //
    '-filter_complex', graph,
    '-map', '[v]', '-map', '0:a?',
    '-c:v', 'libx264', '-preset', preset, '-crf', '20',
    '-c:a', 'aac', '-b:a', '192k',
    '-movflags', '+faststart',
    '-progress', 'pipe:1', '-nostats',
    output,
  ];
}

/// FFmpeg arguments that save a frame of [input] as a picture: the first,
/// or the one at [seek] (a whole download cut on the device).
List<String> snapshotArgs({
  required String input,
  required String output,
  required SnapshotFormat format,
  Duration? seek,
  List<String> inputOptions = const [],
}) => [
  '-hide_banner', '-y', ...inputOptions, if (seek != null) ...['-ss', sectionTime(seek)], '-i', input, //
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
List<String> cutArgs({
  required String input,
  required String output,
  required CreatorJob job,
  required bool video,
  String preset = 'veryfast',
}) => [
  '-hide_banner', '-y', '-ss', sectionTime(job.start!), '-i', input, '-t', sectionTime(job.length), //
  '-map', '0:v?', '-map', '0:a?',
  if (video && job.exactCuts) ...[
    '-c:v',
    'libx264',
    '-preset',
    preset,
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

/// A stream FFmpeg reads: a link (a file served by FetchNet's relay, or a
/// playlist) and the options that go before its `-i` (headers, timeouts).
class FfInput {
  const FfInput(this.url, [this.options = const []]);

  final String url;
  final List<String> options;
}

/// What an audio clip is saved as, from the download's yt-dlp arguments
/// (`-x --audio-format mp3 --audio-quality 320K`).
class AudioTarget {
  const AudioTarget({this.format, this.quality});

  /// `mp3`, `m4a`… `null` or `best`: the stream's own format.
  final String? format;

  /// `320K` (a bitrate) or `0`–`10` (VBR quality), as yt-dlp takes it.
  final String? quality;

  static AudioTarget fromArgs(List<String> args) {
    String? after(String flag) {
      final i = args.indexOf(flag);
      return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
    }

    if (!args.contains('-x') && !args.contains('--extract-audio')) return const AudioTarget();
    return AudioTarget(format: after('--audio-format'), quality: after('--audio-quality'));
  }

  /// The extension and FFmpeg codec arguments for a stream in [codec]
  /// (yt-dlp's acodec: `opus`, `mp4a.40.2`) from a file of [sourceExt]:
  /// copied when it already is what's asked for.
  (String, List<String>) encode({required String? codec, required String sourceExt}) {
    final c = (codec ?? '').toLowerCase();
    final q = quality;
    final bitrate = q != null && RegExp(r'^\d+[kK]$').hasMatch(q) ? q.toLowerCase() : null;
    final vbr = q != null && RegExp(r'^\d+$').hasMatch(q) ? q : null;
    List<String> rate(String fallback) => bitrate != null
        ? ['-b:a', bitrate]
        : vbr != null
            ? ['-q:a', vbr]
            : ['-b:a', fallback];
    switch (format) {
      case 'mp3':
        return ('mp3', c == 'mp3' && q == null ? const ['-c:a', 'copy'] : ['-c:a', 'libmp3lame', ...rate('192k')]);
      case 'm4a' || 'aac':
        return ('m4a', c.startsWith('mp4a') && bitrate == null ? const ['-c:a', 'copy'] : ['-c:a', 'aac', '-b:a', bitrate ?? '192k']);
      case 'opus':
        return ('opus', c == 'opus' && bitrate == null ? const ['-c:a', 'copy'] : ['-c:a', 'libopus', '-b:a', bitrate ?? '160k']);
      case 'vorbis':
        return ('ogg', c == 'vorbis' && q == null ? const ['-c:a', 'copy'] : ['-c:a', 'libvorbis', ...rate('192k')]);
      case 'flac':
        return ('flac', const ['-c:a', 'flac']);
      case 'wav':
        return ('wav', const ['-c:a', 'pcm_s16le']);
      case 'alac':
        return ('m4a', const ['-c:a', 'alac']);
      default:
        // As it is: Opus into .opus, AAC into .m4a, anything else into its
        // own kind of file.
        if (c == 'opus') return ('opus', const ['-c:a', 'copy']);
        if (c.startsWith('mp4a')) return ('m4a', const ['-c:a', 'copy']);
        if (c == 'mp3') return ('mp3', const ['-c:a', 'copy']);
        return (sourceExt.isEmpty ? 'mka' : sourceExt, const ['-c:a', 'copy']);
    }
  }
}

/// FFmpeg arguments that copy [job]'s part straight out of the streams,
/// without re-encoding: FFmpeg seeks to the start in each stream (reading
/// only that part) and stops at the end. The video begins at the keyframe
/// before the start; those frames are kept but marked to be skipped (an MP4
/// edit list), so players, and [clipEncodeArgs], start at the very start.
///
/// [audio] is a separate audio stream; without it the video's own sound is
/// used. This is the clip itself when cuts needn't be exact, else the part
/// [clipEncodeArgs] encodes (FFmpeg reading a stream while it encodes keeps
/// downloading far past the end).
List<String> streamCopyArgs({required FfInput video, required FfInput? audio, required CreatorJob job, required String output}) {
  final inputs = [video, ?audio];
  final start = sectionTime(job.start!);
  // Each input stops a little after the end too.
  final read = sectionTime(job.length + const Duration(seconds: 2));
  return [
    '-hide_banner', '-y', //
    for (final i in inputs) ...[...i.options, '-ss', start, '-t', read, '-i', i.url],
    '-t', sectionTime(job.length),
    '-map', '0:v:0', '-map', '${inputs.length - 1}:a:0?',
    '-c', 'copy',
    '-movflags', '+faststart',
    '-progress', 'pipe:1', '-nostats',
    output,
  ];
}

/// FFmpeg arguments that encode a part copied by [streamCopyArgs] into the
/// clip, from its very first frame to the end: H.264 + AAC, made 9:16 for
/// Shorts & Reels when [shape] is landscape.
List<String> clipEncodeArgs({
  required String input,
  required CreatorJob job,
  required String output,
  VideoShape? shape,
  String preset = 'veryfast',
}) {
  final shorts = job.shorts && shape != null && shape.landscape;
  return [
    '-hide_banner', '-y', '-i', input, //
    '-t', sectionTime(job.length),
    if (shorts) ...['-filter_complex', shortsGraph(shape, job.background), '-map', '[v]'] else ...['-map', '0:v:0'],
    '-map', '0:a:0?',
    '-c:v', 'libx264', '-preset', preset, '-crf', shorts ? '20' : '18', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '192k',
    '-avoid_negative_ts', 'make_zero',
    '-movflags', '+faststart',
    '-progress', 'pipe:1', '-nostats',
    output,
  ];
}

/// FFmpeg arguments that save [job]'s part of a song straight from its
/// stream, with [audioCodec] (see [AudioTarget]) and its tags.
List<String> streamAudioClipArgs({
  required FfInput audio,
  required CreatorJob job,
  required String output,
  List<String> audioCodec = const ['-c:a', 'copy'],
  Map<String, String> metadata = const {},
}) {
  final lower = output.toLowerCase();
  return [
    '-hide_banner', '-y', //
    ...audio.options, '-ss', sectionTime(job.start!), '-t', sectionTime(job.length + const Duration(seconds: 2)), '-i', audio.url,
    '-t', sectionTime(job.length),
    '-map', '0:a:0', '-vn', ...audioCodec,
    for (final MapEntry(:key, :value) in metadata.entries)
      if (value.trim().isNotEmpty) ...['-metadata', '$key=${value.trim()}'],
    '-avoid_negative_ts', 'make_zero',
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) ...['-movflags', '+faststart'],
    if (lower.endsWith('.mp3')) ...['-id3v2_version', '3'],
    '-progress', 'pipe:1', '-nostats',
    output,
  ];
}

/// [formatArgs] with only the video of each choice (`137+140/b` → `137/b`):
/// a snapshot needs no sound.
List<String> videoOnlyFormatArgs(List<String> formatArgs) {
  final i = formatArgs.indexOf('-f');
  if (i < 0 || i + 1 >= formatArgs.length) return formatArgs;
  final selector = formatArgs[i + 1].split('/').map((alt) => alt.split('+').first).toSet().join('/');
  return [...formatArgs.sublist(0, i + 1), selector, ...formatArgs.sublist(i + 2)];
}

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
