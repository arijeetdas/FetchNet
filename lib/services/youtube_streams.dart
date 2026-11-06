import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../models/media_info.dart';
import 'fetch_service.dart';

/// One playable stream from yt-dlp's format list.
@immutable
class YtStream {
  const YtStream({
    required this.url,
    required this.headers,
    required this.hasVideo,
    required this.hasAudio,
    this.height,
    this.width,
    this.fps,
    this.codec,
    this.bitrate,
    this.sizeBytes,
  });

  final String url;
  final Map<String, String> headers;
  final bool hasVideo;
  final bool hasAudio;
  final int? height;
  final int? width;
  final int? fps;
  final String? codec;

  /// kbps.
  final double? bitrate;
  final int? sizeBytes;

  /// Quality named after the shorter side (a vertical Short is "1080p").
  int get resolution {
    final h = height ?? 0;
    final w = width ?? 0;
    return (w > 0 && w < h) ? w : h;
  }

  /// `1080p60`, `720p`.
  String get label => '${resolution}p${fps != null && fps! > 30 ? fps : ''}';

  String? get badge => resolution >= 2160
      ? '4K'
      : resolution >= 1440
          ? '2K'
          : resolution >= 720
              ? 'HD'
              : null;
}

/// Everything needed to play (and download) one video.
@immutable
class YtStreams {
  const YtStreams({required this.info, required this.video, this.audio, this.muxed, required this.resolvedAt});

  /// yt-dlp's full answer, reused by the download popup.
  final MediaInfo info;

  /// Best video stream per quality, highest first.
  final List<YtStream> video;

  /// Best audio-only stream.
  final YtStream? audio;

  /// Best stream carrying both (fallback when video and audio can't be paired).
  final YtStream? muxed;
  final DateTime resolvedAt;

  bool get isEmpty => video.isEmpty && audio == null && muxed == null;

  /// The quality closest to [height] without going over (0 = [auto]).
  YtStream? videoFor(int height, {required int auto}) {
    if (video.isEmpty) return muxed;
    final target = height <= 0 ? auto : height;
    for (final v in video) {
      if (v.resolution <= target) return v;
    }
    return video.last;
  }

  @visibleForTesting
  static YtStreams fromInfo(MediaInfo info) => _build(info);

  static YtStreams _build(MediaInfo info) {
    final formats = info.raw['formats'];
    final list = formats is List ? formats.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const <Map<String, dynamic>>[];
    final duration = info.duration;
    final videoBest = <int, (Map<String, dynamic>, double)>{};
    Map<String, dynamic>? audioBest;
    var audioRank = double.negativeInfinity;
    Map<String, dynamic>? muxedBest;
    var muxedRank = double.negativeInfinity;

    for (final f in list) {
      final url = f['url'];
      if (url is! String || !url.startsWith('http')) continue;
      final protocol = '${f['protocol'] ?? 'https'}';
      if (protocol != 'https' && protocol != 'http') continue;
      final ext = '${f['ext'] ?? ''}';
      if (ext == 'mhtml') continue; // storyboards
      final vcodec = '${f['vcodec'] ?? 'none'}';
      final acodec = '${f['acodec'] ?? 'none'}';
      final hasVideo = vcodec != 'none';
      final hasAudio = acodec != 'none';
      final note = '${f['format_note'] ?? ''}'.toLowerCase();
      final drc = '${f['format_id'] ?? ''}'.contains('drc');
      if (hasVideo && !hasAudio) {
        final h = (f['height'] as num?)?.toInt() ?? 0;
        if (h <= 0) continue;
        // Smooth first, then the codec phones decode in hardware.
        final codecRank = vcodec.startsWith('avc1') ? 3 : vcodec.startsWith('vp') ? 2 : 1;
        final rank = ((f['fps'] as num?)?.toDouble() ?? 30) * 10 + codecRank;
        final cur = videoBest[h];
        if (cur == null || rank > cur.$2) videoBest[h] = (f, rank);
      } else if (!hasVideo && hasAudio) {
        // The original language beats dubs; then bitrate.
        final lang = (f['language_preference'] as num?)?.toDouble() ?? 0;
        final rank = lang * 10000 + ((f['abr'] ?? f['tbr'] ?? 0) as num).toDouble() - (drc ? 1 : 0) -
            (note.contains('dubbed') ? 5000 : 0);
        if (rank > audioRank) {
          audioRank = rank;
          audioBest = f;
        }
      } else if (hasVideo && hasAudio) {
        final rank = ((f['height'] as num?)?.toDouble() ?? 0);
        if (rank > muxedRank) {
          muxedRank = rank;
          muxedBest = f;
        }
      }
    }

    YtStream stream(Map<String, dynamic> f) {
      final headers = <String, String>{};
      final h = f['http_headers'];
      if (h is Map) {
        for (final e in h.entries) {
          headers['${e.key}'] = '${e.value}';
        }
      }
      final tbr = (f['tbr'] as num?)?.toDouble();
      final size = (f['filesize'] ?? f['filesize_approx']) as num?;
      return YtStream(
        url: f['url'] as String,
        headers: headers,
        hasVideo: '${f['vcodec'] ?? 'none'}' != 'none',
        hasAudio: '${f['acodec'] ?? 'none'}' != 'none',
        height: (f['height'] as num?)?.toInt(),
        width: (f['width'] as num?)?.toInt(),
        fps: (f['fps'] as num?)?.round(),
        codec: '${f['vcodec'] == 'none' ? f['acodec'] : f['vcodec']}'.split('.').first,
        bitrate: tbr ?? (f['abr'] as num?)?.toDouble(),
        sizeBytes: size?.toInt() ?? (tbr != null && duration != null ? (tbr * 125 * duration).round() : null),
      );
    }

    final heights = videoBest.keys.toList()..sort((a, b) => b.compareTo(a));
    final audio = audioBest == null ? null : stream(audioBest);
    final muxed = muxedBest == null ? null : stream(muxedBest);
    return YtStreams(
      info: info,
      // Video-only streams are useless without an audio track to pair them with.
      video: audio == null ? [?muxed] : [for (final h in heights) stream(videoBest[h]!.$1)],
      audio: audio,
      muxed: muxed,
      resolvedAt: DateTime.now(),
    );
  }
}

/// One yt-dlp lookup in flight, and how many callers still wait for it.
class _Lookup {
  _Lookup(this.fetcher);

  final FetchService fetcher;
  late final Future<YtStreams> future;
  int waiting = 0;
}

/// Asks yt-dlp for a video's streams (no ads: these are the raw media
/// files) and keeps them for a while so playback, quality changes and the
/// download popup share one lookup.
///
/// Every lookup has its own yt-dlp run: when nobody waits for it any more
/// (the user moved on to another video) it is stopped, so abandoned lookups
/// never pile up and slow the next one down.
class YtStreamResolver {
  YtStreamResolver(this._newFetcher, this._engine);

  final FetchService Function() _newFetcher;
  final YtDlpEngine _engine;

  final Map<String, YtStreams> _cache = {};
  final Map<String, _Lookup> _pending = {};

  /// Stream URLs stop working after about six hours.
  static const _ttl = Duration(hours: 3);
  static const _maxCached = 12;

  /// Playback needs neither the HLS / DASH manifests (the same qualities
  /// exist as plain files) nor translated subtitles: skipping them makes the
  /// lookup about a fifth faster.
  static const _fastArgs = ['--extractor-args', 'youtube:skip=hls,dash,translated_subs'];

  /// yt-dlp runs Python, which is much slower on phones.
  static Duration get _limit =>
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ? const Duration(seconds: 120) : const Duration(seconds: 60);

  static String watchUrl(String id) => 'https://www.youtube.com/watch?v=$id';

  YtStreams? cached(String id) {
    final s = _cache[id];
    if (s == null) return null;
    if (DateTime.now().difference(s.resolvedAt) > _ttl) {
      _cache.remove(id);
      return null;
    }
    return s;
  }

  /// Whether [id] is being looked up right now.
  bool isPending(String id) => _pending.containsKey(id);

  /// The streams of [id]. A caller that stops waiting before it completes
  /// calls [release].
  Future<YtStreams> resolve(String id, {bool refresh = false}) {
    if (!refresh) {
      final hit = cached(id);
      if (hit != null) return SynchronousFuture(hit);
    }
    var lookup = _pending[id];
    if (lookup == null) {
      final l = lookup = _Lookup(_newFetcher());
      _pending[id] = l;
      l.future = _resolve(id, l.fetcher).whenComplete(() {
        if (_pending[id] == l) _pending.remove(id);
      });
    }
    lookup.waiting++;
    return lookup.future;
  }

  /// The caller of [resolve] no longer needs [id]. A lookup nobody waits for
  /// is stopped.
  void release(String id) {
    final l = _pending[id];
    if (l == null) return;
    if (--l.waiting > 0) return;
    _pending.remove(id);
    unawaited(l.fetcher.cancel());
  }

  Future<YtStreams> _resolve(String id, FetchService fetcher) async {
    await _waitForEngine();
    Future<MediaInfo> lookUp(List<String> args) => fetcher.fetch(watchUrl(id), requestArgs: args).timeout(
          _limit,
          onTimeout: () {
            unawaited(fetcher.cancel());
            throw FetchException(
              'YouTube took too long to answer.',
              hint: 'YouTube is slow to answer right now. Try again in a moment.',
            );
          },
        );
    var info = await lookUp(_fastArgs);
    var streams = YtStreams._build(_withoutLookupArgs(info));
    if (streams.isEmpty) {
      // Live streams only come as HLS: ask again with the manifests.
      info = await lookUp(const []);
      streams = YtStreams._build(info);
    }
    if (streams.isEmpty) {
      throw FetchException('No playable streams were found for this video.', hint: 'Try again in a moment.');
    }
    _cache[id] = streams;
    while (_cache.length > _maxCached) {
      _cache.remove(_cache.keys.first);
    }
    return streams;
  }

  /// The lookup shortcut must not follow the info into downloads (it would
  /// hide the HLS formats of live streams there).
  static MediaInfo _withoutLookupArgs(MediaInfo info) {
    final args = [...info.requestArgs];
    final i = args.indexOf(_fastArgs.first);
    if (i < 0 || i + 1 >= args.length || args[i + 1] != _fastArgs.last) return info;
    args.removeRange(i, i + 2);
    return MediaInfo(
      url: info.url,
      title: info.title,
      raw: info.raw,
      thumbnail: info.thumbnail,
      uploader: info.uploader,
      duration: info.duration,
      extractor: info.extractor,
      viewCount: info.viewCount,
      isLive: info.isLive,
      entries: info.entries,
      requestArgs: args,
      preferAudio: info.preferAudio,
    );
  }

  /// On first launch yt-dlp may still be installing.
  Future<void> _waitForEngine() async {
    final status = _engine.status;
    if (status.value.isReady) return;
    if (status.value.state == EngineState.unsupported) {
      throw FetchException(status.value.message ?? 'Playback isn\'t available on this device.');
    }
    final done = Completer<void>();
    void listener() {
      final s = status.value;
      if ((s.isReady || s.state == EngineState.error || s.state == EngineState.unsupported) && !done.isCompleted) {
        done.complete();
      }
    }

    status.addListener(listener);
    try {
      await done.future.timeout(const Duration(minutes: 3));
    } on TimeoutException {
      throw FetchException('The yt-dlp engine is still getting ready. Try again in a moment.');
    } finally {
      status.removeListener(listener);
    }
    if (!status.value.isReady) {
      throw FetchException(status.value.message ?? 'The yt-dlp engine isn\'t ready.');
    }
  }

}
