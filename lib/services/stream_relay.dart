import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// One stream of a video, as yt-dlp lists it (`-j`): where it is, how to
/// ask for it, and what's in it.
class StreamSource {
  const StreamSource({
    required this.url,
    required this.protocol,
    this.headers = const {},
    this.ext = '',
    this.vcodec,
    this.acodec,
    this.width,
    this.height,
  });

  final Uri url;
  final String protocol;
  final Map<String, String> headers;
  final String ext;
  final String? vcodec;
  final String? acodec;
  final int? width;
  final int? height;

  bool get hasVideo => vcodec != null && vcodec != 'none';
  bool get hasAudio => acodec != null && acodec != 'none';

  /// A plain file over HTTP(S): read through [StreamRelay].
  bool get progressive => protocol == 'https' || protocol == 'http';

  /// An HLS playlist: FFmpeg reads its pieces itself.
  bool get playlist => protocol.startsWith('m3u8');

  /// Whether FFmpeg can read it straight away.
  bool get usable => (progressive || playlist) && (url.scheme == 'https' || url.scheme == 'http');

  /// FFmpeg's input options with [headers] (for a link it reads itself).
  List<String> get ffmpegHeaders {
    final h = {...headers};
    final agent = h.remove('User-Agent');
    return [
      if (agent != null) ...['-user_agent', agent],
      if (h.isNotEmpty) ...['-headers', h.entries.map((e) => '${e.key}: ${e.value}\r\n').join()],
    ];
  }

  static StreamSource? fromFormat(Map<String, dynamic> f) {
    final url = Uri.tryParse('${f['url'] ?? ''}');
    if (url == null || !url.hasScheme) return null;
    final headers = <String, String>{};
    final h = f['http_headers'];
    if (h is Map) {
      h.forEach((k, v) {
        if (k is String && v != null) headers[k] = '$v';
      });
    }
    // yt-dlp lists a format's cookies apart from its headers, as
    // "name=value; Domain=…; Path=/; …" for each one.
    final cookie = cookieHeader('${f['cookies'] ?? ''}');
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    int? n(Object? v) => v is num ? v.toInt() : null;
    String? codec(Object? v) => v is String && v.isNotEmpty ? v : null;
    return StreamSource(
      url: url,
      protocol: '${f['protocol'] ?? url.scheme}',
      headers: headers,
      ext: '${f['ext'] ?? ''}',
      vcodec: codec(f['vcodec']),
      acodec: codec(f['acodec']),
      width: n(f['width']),
      height: n(f['height']),
    );
  }

  /// A `Cookie` header from yt-dlp's cookie string.
  static String cookieHeader(String raw) {
    const attributes = {'domain', 'path', 'expires', 'max-age', 'secure', 'httponly', 'samesite', 'version', 'comment'};
    return [
      for (final part in raw.split(';'))
        if (part.contains('=') && !attributes.contains(part.split('=').first.trim().toLowerCase())) part.trim(),
    ].join('; ');
  }
}

/// The streams a clip or snapshot needs, from yt-dlp's JSON for the chosen
/// format (`-j`): its video, its audio (the same stream when they come
/// together) and the tags for a song.
class ResolvedStreams {
  const ResolvedStreams({this.video, this.audio, this.metadata = const {}});

  final StreamSource? video;
  final StreamSource? audio;
  final Map<String, String> metadata;

  /// `null` when the JSON has no streams.
  static ResolvedStreams? fromInfo(Map<String, dynamic> info) {
    final requested = info['requested_formats'];
    final List<StreamSource?> listed = requested is List
        ? [for (final f in requested.whereType<Map>()) StreamSource.fromFormat(f.cast<String, dynamic>())]
        : [StreamSource.fromFormat(info)];
    final formats = listed.whereType<StreamSource>().toList();
    if (formats.isEmpty) return null;
    final video = formats.where((f) => f.hasVideo).firstOrNull;
    // A separate audio stream, else the sound inside the video.
    final audio = formats.where((f) => f.hasAudio && !f.hasVideo).firstOrNull ?? formats.where((f) => f.hasAudio).firstOrNull;
    String? text(String key) => info[key] is String && (info[key] as String).trim().isNotEmpty ? info[key] as String : null;
    return ResolvedStreams(
      // Formats that don't say what they hold (some sites) count as video.
      video: video ?? (audio == null ? formats.first : null),
      audio: audio,
      metadata: {
        'title': ?(text('track') ?? text('title')),
        'artist': ?(text('artist') ?? text('creator') ?? text('uploader')),
        'album': ?text('album'),
      },
    );
  }
}

/// Serves remote files to FFmpeg on this device (127.0.0.1) and fetches
/// them in closed byte ranges, a couple at a time.
///
/// FFmpeg asks for "everything from byte N"; sites like YouTube hold such a
/// request to about the video's own speed, while closed ranges of a few MB
/// come at full speed (15–30× faster when measured). Ranges grow to
/// [chunkSize]: small enough not to fetch much past what FFmpeg reads. Seeking works as
/// usual: each FFmpeg request is answered from its own position.
class StreamRelay {
  StreamRelay({this.chunkSize = 4 << 20, this.readAhead = 2, this.onBytes, this.onRequest, HttpClient? client})
      : _client = client ?? HttpClient() {
    _client
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 20);
  }

  /// The largest range asked of the site at once.
  final int chunkSize;

  /// Ranges fetched ahead of FFmpeg.
  final int readAhead;

  /// Bytes passed on to FFmpeg (to tell a stalled download from a slow one).
  final void Function(int bytes)? onBytes;

  /// Each range FFmpeg asks for (for tests and checks).
  final void Function(String stream, int from, int to)? onRequest;

  final HttpClient _client;
  final _sources = <String, _Source>{};
  final _token = List.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  HttpServer? _server;
  var _closed = false;

  /// A link on this device for [url] (fetched with [headers]), or `null`
  /// when the site doesn't answer byte ranges (FFmpeg then reads [url]
  /// itself).
  Future<Uri?> add(Uri url, {Map<String, String> headers = const {}}) async {
    final info = await _probe(url, headers);
    if (info == null || _closed) return null;
    final server = _server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_sources.isEmpty) server.listen(_handle, onError: (_) {});
    final id = '${_sources.length}';
    _sources[id] = _Source(url, headers, info.$1, info.$2);
    return Uri.parse('http://127.0.0.1:${server.port}/$_token/$id');
  }

  Future<void> close() async {
    _closed = true;
    await _server?.close(force: true);
    _client.close(force: true);
  }

  /// The file's size and type, when the site answers a byte range.
  Future<(int, String?)?> _probe(Uri url, Map<String, String> headers) async {
    try {
      final req = await _client.getUrl(url);
      _setHeaders(req, headers);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final res = await req.close().timeout(const Duration(seconds: 20));
      await res.drain<void>().timeout(const Duration(seconds: 10));
      if (res.statusCode != HttpStatus.partialContent) return null;
      final range = res.headers.value(HttpHeaders.contentRangeHeader) ?? '';
      final total = int.tryParse(range.split('/').last.trim());
      if (total == null || total <= 0) return null;
      return (total, res.headers.value(HttpHeaders.contentTypeHeader));
    } catch (_) {
      return null;
    }
  }

  static void _setHeaders(HttpClientRequest req, Map<String, String> headers) {
    headers.forEach((k, v) {
      try {
        req.headers.set(k, v);
      } catch (_) {}
    });
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final parts = req.uri.pathSegments;
    final source = parts.length == 2 && parts[0] == _token ? _sources[parts[1]] : null;
    if (source == null || (req.method != 'GET' && req.method != 'HEAD')) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final size = source.size;
    var from = 0, to = size - 1;
    final range = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(req.headers.value(HttpHeaders.rangeHeader)?.trim() ?? '');
    if (range != null) {
      final a = int.tryParse(range.group(1)!), b = int.tryParse(range.group(2)!);
      if (a == null && b != null) {
        from = max(0, size - b); // the last b bytes
      } else {
        from = a ?? 0;
        if (b != null) to = min(b, size - 1);
      }
    }
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, source.type ?? 'application/octet-stream');
    if (from >= size || from > to) {
      res
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
      await res.close();
      return;
    }
    res
      ..statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent
      ..contentLength = to - from + 1;
    if (range != null) res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-$to/$size');
    onRequest?.call(parts[1], from, to);
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }

    // Small ranges first (FFmpeg often reads a little, then jumps), growing
    // to [chunkSize]; then a couple ahead of FFmpeg.
    final pending = Queue<Future<Uint8List>>();
    var next = from, chunk = min(512 << 10, chunkSize), sent = 0;
    void fill() {
      final ahead = sent >= (2 << 20) ? readAhead : 1;
      while (!_closed && pending.length < ahead && next <= to) {
        final end = min(next + chunk - 1, to);
        // Handled here too: a range ahead that fails while FFmpeg has
        // stopped reading (or the relay is closed) isn't an app error.
        pending.add(_fetch(source, next, end)..ignore());
        next = end + 1;
        chunk = min(chunk * 2, chunkSize);
      }
    }

    try {
      fill();
      while (pending.isNotEmpty) {
        final data = await pending.removeFirst();
        res.add(data);
        await res.flush();
        sent += data.length;
        onBytes?.call(data.length);
        fill();
      }
      await res.close();
    } catch (_) {
      // FFmpeg moved on (a seek) or the site failed: drop the rest.
      for (final f in pending) {
        f.ignore();
      }
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// Bytes [from]–[to] of [source], tried three times.
  Future<Uint8List> _fetch(_Source source, int from, int to) async {
    for (var attempt = 0;; attempt++) {
      try {
        final req = await _client.getUrl(source.url);
        _setHeaders(req, source.headers);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.statusCode != HttpStatus.partialContent) {
          await res.drain<void>().catchError((_) {});
          throw HttpException('The site answered ${res.statusCode}.');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final c in res.timeout(const Duration(seconds: 30))) {
          bytes.add(c);
        }
        final data = bytes.takeBytes();
        if (data.length != to - from + 1) throw const HttpException('The site sent part of the range.');
        return data;
      } catch (_) {
        if (attempt >= 2 || _closed) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
  }
}

class _Source {
  _Source(this.url, this.headers, this.size, this.type);

  final Uri url;
  final Map<String, String> headers;
  final int size;
  final String? type;
}
