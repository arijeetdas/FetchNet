import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

enum SniffedKind { video, audio, hls, dash }

class SniffedMedia {
  SniffedMedia({required this.url, required this.kind, this.sizeBytes, this.mime});

  final String url;
  final SniffedKind kind;
  final int? sizeBytes;
  final String? mime;

  bool get isAudio => kind == SniffedKind.audio;

  String get label => switch (kind) {
        SniffedKind.video => 'Video',
        SniffedKind.audio => 'Audio',
        SniffedKind.hls => 'Video stream',
        SniffedKind.dash => 'Video stream',
      };

  /// Short format tag, e.g. `MP4`, `HLS`, `M4A`.
  String get format {
    if (kind == SniffedKind.hls) return 'HLS';
    if (kind == SniffedKind.dash) return 'DASH';
    final ext = MediaSniffer.extensionOf(url);
    if (ext != null && ext.length <= 4) return ext.toUpperCase();
    final sub = mime?.split('/').last.split(';').first;
    return (sub == null || sub.isEmpty) ? (isAudio ? 'AUDIO' : 'VIDEO') : sub.toUpperCase();
  }
}

/// Finds downloadable video / audio among the requests a web page makes.
///
/// Signals, in order: the response Content-Type (probed for ambiguous URLs),
/// the file extension, a `mime=` query parameter, and the element or
/// request type that loaded it (`<video>`, `<audio>`).
class MediaSniffer {
  MediaSniffer({required this.onChanged});

  final void Function() onChanged;

  /// Detected media keyed by normalized URL, in discovery order.
  final LinkedHashMap<String, SniffedMedia> found = LinkedHashMap();

  String? userAgent;
  String? referer;

  final Set<String> _seen = {};
  final Queue<Future<void> Function()> _jobs = Queue();
  int _inFlight = 0;
  int _probes = 0;
  int _refines = 0;
  int _generation = 0;

  static const _maxFound = 80;
  static const _maxProbes = 40;
  static const _maxRefines = 40;
  static const _maxConcurrentProbes = 3;

  static const videoExt = {'mp4', 'm4v', 'webm', 'mov', 'mkv', 'flv', '3gp', 'avi', 'ogv', 'wmv'};
  static const audioExt = {'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wav', 'weba', 'wma'};
  static const _segmentExt = {'ts', 'm4s', 'm4f', 'cmfv', 'cmfa', 'key', 'vtt', 'webvtt', 'srt'};
  static const _notMediaExt = {
    'js', 'mjs', 'css', 'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp', 'avif', 'ico', 'woff', 'woff2', 'ttf', 'otf',
    'json', 'html', 'htm', 'txt', 'map', 'php', 'wasm',
  };
  static final _numberedSegment =
      RegExp(r'(?:^|[/_-])(?:seg|segment|frag|fragment|chunk|part)[-_]?\d+[^/]*$', caseSensitive: false);
  static final _initSegment = RegExp(r'/init[^/]*\.(?:mp4|m4s|m4a)$', caseSensitive: false);
  static final _mediaHint =
      RegExp(r'video|media|stream|play|hls|dash|vod|movie|clip|manifest|playlist|master|audio|mp4|m3u8',
          caseSensitive: false);
  static const _rangeParams = {'bytestart', 'byteend', 'range', 'rn', 'rbuf', 'bytes', '_nc_rid'};

  /// Forget everything (new page loaded).
  void reset() {
    _generation++;
    found.clear();
    _seen.clear();
    _jobs.clear();
    _probes = 0;
    _refines = 0;
    onChanged();
  }

  static String? extensionOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final dot = last.lastIndexOf('.');
    if (dot < 0 || dot == last.length - 1) return null;
    return last.substring(dot + 1).toLowerCase();
  }

  /// Drops fragments and byte-range parameters so the pieces of one file
  /// collapse into one URL for the whole file.
  static String normalize(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final params = Map.of(uri.queryParametersAll)..removeWhere((k, _) => _rangeParams.contains(k.toLowerCase()));
    return uri.replace(queryParameters: params.isEmpty ? null : params, fragment: '').toString().replaceAll(RegExp(r'[?#]+$'), '');
  }

  /// A piece of a segmented stream (useless on its own).
  static bool isSegment(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final ext = extensionOf(url);
    if (ext != null && _segmentExt.contains(ext)) return true;
    final path = uri.path;
    if (_initSegment.hasMatch(path)) return true;
    if (ext != null && (videoExt.contains(ext) || audioExt.contains(ext) || ext == 'ts') && _numberedSegment.hasMatch(path)) {
      return true;
    }
    return false;
  }

  /// Classifies from the URL and the loading context alone (no network).
  static SniffedKind? classify(String url, {String? hint, String? contentType}) {
    final ct = contentType?.toLowerCase().split(';').first.trim();
    if (ct != null && ct.isNotEmpty) {
      if (ct.contains('mpegurl')) return SniffedKind.hls;
      if (ct.contains('dash+xml')) return SniffedKind.dash;
      if (ct == 'video/mp2t') return null; // HLS segment
      if (ct.startsWith('video/')) return SniffedKind.video;
      if (ct.startsWith('audio/')) return SniffedKind.audio;
      if (ct == 'application/octet-stream' || ct == 'binary/octet-stream') {
        // Fall through to the URL signals.
      } else {
        return null;
      }
    }
    final ext = extensionOf(url);
    if (ext == 'm3u8' || ext == 'm3u') return SniffedKind.hls;
    if (ext == 'mpd') return SniffedKind.dash;
    if (ext != null && videoExt.contains(ext)) {
      // DASH audio tracks are often .mp4 files with "audio" in the path.
      final lower = url.toLowerCase();
      if (hint == 'audio' || RegExp(r'[/_.-]audio[/_.-]|dash_audio|audio_only').hasMatch(lower)) {
        return SniffedKind.audio;
      }
      return SniffedKind.video;
    }
    if (ext != null && audioExt.contains(ext)) return SniffedKind.audio;
    final mime = Uri.tryParse(url)?.queryParameters['mime']?.toLowerCase();
    if (mime != null) {
      if (mime.startsWith('video')) return SniffedKind.video;
      if (mime.startsWith('audio')) return SniffedKind.audio;
    }
    if (hint == 'video') return SniffedKind.video;
    if (hint == 'audio') return SniffedKind.audio;
    return null;
  }

  /// Worth a HEAD request to find out what it is.
  static bool worthProbing(String url, {String? hint}) {
    final ext = extensionOf(url);
    if (ext != null && _notMediaExt.contains(ext)) return false;
    if (hint == 'video' || hint == 'audio') return true;
    return _mediaHint.hasMatch(url);
  }

  /// Feeds one URL the page requested. [hint] is the element / initiator
  /// type (`video`, `audio`, `xmlhttprequest`, ...).
  void consider(String rawUrl, {String? hint}) {
    if (!rawUrl.startsWith('http')) return;
    final url = normalize(rawUrl);
    // The page later told us a <video> element plays no picture: it's audio.
    final known = found[url];
    if (known != null && hint == 'audio' && known.kind == SniffedKind.video) {
      found[url] = SniffedMedia(url: url, kind: SniffedKind.audio, sizeBytes: known.sizeBytes, mime: known.mime);
      onChanged();
      return;
    }
    if (!_seen.add(url) || found.length >= _maxFound) return;
    final host = Uri.tryParse(url)?.host ?? '';
    // YouTube streams are split and signed: "Grab this page" handles YouTube.
    if (host.endsWith('googlevideo.com')) return;
    if (isSegment(url)) return;
    final kind = classify(url, hint: hint);
    if (kind != null) {
      _add(SniffedMedia(url: url, kind: kind));
    } else if (worthProbing(url, hint: hint) && _probes < _maxProbes) {
      _probes++;
      final generation = _generation;
      _enqueue(() async {
        final head = await _probe(url);
        if (generation != _generation || head == null) return;
        final kind = classify(url, hint: hint, contentType: head.contentType);
        if (kind == null) return;
        // Skip tiny clips (ads, UI sounds) when the size is known.
        if (head.length != null && head.length! > 0 && head.length! < 120 * 1024 &&
            kind != SniffedKind.hls && kind != SniffedKind.dash) {
          return;
        }
        _add(SniffedMedia(url: url, kind: kind, sizeBytes: head.length, mime: head.contentType));
      });
    }
  }

  void _add(SniffedMedia media) {
    found[media.url] = media;
    onChanged();
    // Anything not already known to be audio gets its content checked:
    // audio-only .mp4 / .webm tracks and audio HLS look like video otherwise.
    if (!media.isAudio && _refines < _maxRefines) {
      _refines++;
      final generation = _generation;
      _enqueue(() async {
        final refined = await _refine(media);
        if (generation != _generation || refined == null) return;
        final current = found[media.url];
        if (current == null) return;
        if (refined.kind != current.kind || (current.sizeBytes == null && refined.sizeBytes != null)) {
          found[media.url] = refined;
          onChanged();
        }
      });
    }
  }

  void _enqueue(Future<void> Function() job) {
    _jobs.add(job);
    _pumpJobs();
  }

  void _pumpJobs() {
    while (_inFlight < _maxConcurrentProbes && _jobs.isNotEmpty) {
      final job = _jobs.removeFirst();
      _inFlight++;
      job().catchError((_) {}).whenComplete(() {
        _inFlight--;
        _pumpJobs();
      });
    }
  }

  /// Looks inside the media to tell video from audio-only.
  Future<SniffedMedia?> _refine(SniffedMedia m) async {
    if (m.kind == SniffedKind.hls || m.kind == SniffedKind.dash) {
      final r = await _fetchRange(m.url, null, 256 * 1024);
      if (r == null) return null;
      final text = latin1.decode(r.bytes, allowInvalid: true);
      final kind = m.kind == SniffedKind.hls ? kindFromHlsPlaylist(text) : kindFromDashManifest(text);
      if (kind != SniffedKind.audio) return null;
      return SniffedMedia(url: m.url, kind: SniffedKind.audio, mime: m.mime);
    }
    final r = await _fetchRange(m.url, 'bytes=0-131071', 131072);
    if (r == null) return null;
    var kind = kindFromBytes(r.bytes);
    final size = r.total ?? m.sizeBytes;
    // Progressive MP4 with its index ("moov") at the end: read the tail too.
    if (kind == null && _isIsoMedia(r.bytes) && !_containsAscii(r.bytes, 'moov')) {
      final tail = await _fetchRange(m.url, 'bytes=-262144', 262144);
      if (tail != null) kind = kindFromBytes(tail.bytes);
    }
    return SniffedMedia(url: m.url, kind: kind ?? m.kind, sizeBytes: size, mime: m.mime);
  }

  /// Reads up to [maxBytes] (never more), optionally with a Range header.
  Future<({List<int> bytes, int? total})?> _fetchRange(String url, String? range, int maxBytes) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      if (userAgent != null) req.headers.set(HttpHeaders.userAgentHeader, userAgent!);
      if (referer != null) req.headers.set(HttpHeaders.refererHeader, referer!);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode >= 400) return null;
      // A suffix range the server ignored would start at byte 0: useless.
      if (range != null && range.startsWith('bytes=-') && res.statusCode != 206) return null;
      int? total;
      final cr = res.headers.value(HttpHeaders.contentRangeHeader);
      if (cr != null && cr.contains('/')) total = int.tryParse(cr.split('/').last);
      if (total == null && res.statusCode == 200 && res.contentLength > 0) total = res.contentLength;
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 8))) {
        final room = maxBytes - bytes.length;
        bytes.addAll(chunk.length > room ? chunk.sublist(0, room) : chunk);
        if (bytes.length >= maxBytes) break;
      }
      return (bytes: bytes, total: total);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static bool _isIsoMedia(List<int> b) =>
      b.length > 12 && _containsAscii(b.sublist(0, math.min(b.length, 64)), 'ftyp');

  static bool _containsAscii(List<int> b, String s) => latin1.decode(b, allowInvalid: true).contains(s);

  static final _mkvVideo = RegExp(r'V_(VP8|VP9|AV1|MPEG4|MPEGH|THEORA|MS/VFW)');
  static final _mkvAudio = RegExp(r'A_(OPUS|VORBIS|AAC|MPEG|FLAC|AC3|EAC3|DTS|PCM)');
  static final _hlsVideoCodec = RegExp(r'avc1|avc3|hvc1|hev1|dvh1|vp09|vp9|av01|mp4v');
  static final _audioSegment = RegExp(r'[.](aac|mp3|m4a|ac3|ec3|opus|flac)([?]|$)', caseSensitive: false);

  /// Video vs audio from the first (or last) bytes of a media file.
  static SniffedKind? kindFromBytes(List<int> b) {
    if (b.length < 4) return null;
    final text = latin1.decode(b, allowInvalid: true);
    // MP4 / MOV / 3GP: track handler types inside 'hdlr' boxes.
    var video = false;
    var audio = false;
    for (var i = text.indexOf('hdlr'); i >= 0 && i + 16 <= text.length; i = text.indexOf('hdlr', i + 4)) {
      final handler = text.substring(i + 12, i + 16);
      if (handler == 'vide') video = true;
      if (handler == 'soun') audio = true;
    }
    if (video) return SniffedKind.video;
    if (audio) return SniffedKind.audio;
    // Matroska / WebM: codec IDs.
    if (_mkvVideo.hasMatch(text)) return SniffedKind.video;
    if (_mkvAudio.hasMatch(text)) return SniffedKind.audio;
    // Ogg.
    if (text.startsWith('OggS')) {
      if (text.contains('theora')) return SniffedKind.video;
      if (text.contains('OpusHead') || text.contains('vorbis') || text.contains('FLAC')) return SniffedKind.audio;
    }
    // MP3 (ID3 tag or MPEG frame sync), ADTS AAC, FLAC, WAV.
    if (text.startsWith('ID3') || text.startsWith('fLaC') || (text.startsWith('RIFF') && text.contains('WAVE'))) {
      return SniffedKind.audio;
    }
    if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return SniffedKind.audio;
    return null;
  }

  /// `audio` for an HLS playlist with no video renditions.
  static SniffedKind? kindFromHlsPlaylist(String text) {
    final lines = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final variants = lines.where((l) => l.startsWith('#EXT-X-STREAM-INF')).toList();
    if (variants.isNotEmpty) {
      final hasVideo = variants.any((l) => l.contains('RESOLUTION=') || _hlsVideoCodec.hasMatch(l));
      return hasVideo ? SniffedKind.video : SniffedKind.audio;
    }
    final segments = lines.where((l) => !l.startsWith('#')).toList();
    if (segments.isNotEmpty && segments.every(_audioSegment.hasMatch)) return SniffedKind.audio;
    return null;
  }

  /// `audio` for a DASH manifest without video adaptation sets.
  static SniffedKind? kindFromDashManifest(String text) {
    if (RegExp(r'contentType="video"|mimeType="video/').hasMatch(text)) return SniffedKind.video;
    if (RegExp(r'contentType="audio"|mimeType="audio/').hasMatch(text)) return SniffedKind.audio;
    return null;
  }

  /// HEAD (or a 1-byte ranged GET) to read Content-Type / size.
  Future<({String? contentType, int? length})?> _probe(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      Future<HttpClientResponse> send(String method) async {
        final req = await client.openUrl(method, Uri.parse(url));
        req.followRedirects = true;
        if (userAgent != null) req.headers.set(HttpHeaders.userAgentHeader, userAgent!);
        if (referer != null) req.headers.set(HttpHeaders.refererHeader, referer!);
        if (method == 'GET') req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        return req.close().timeout(const Duration(seconds: 6));
      }

      var res = await send('HEAD');
      if (res.statusCode >= 400 || res.headers.contentType == null) {
        res = await send('GET');
      }
      if (res.statusCode >= 400) return null;
      int? length = res.contentLength > 1 ? res.contentLength : null;
      final range = res.headers.value(HttpHeaders.contentRangeHeader);
      if (range != null && range.contains('/')) length = int.tryParse(range.split('/').last) ?? length;
      return (contentType: res.headers.value(HttpHeaders.contentTypeHeader), length: length);
    } catch (_) {
      return null;
    } finally {
      // Never download the body.
      client.close(force: true);
    }
  }
}
