import 'dart:io';
import 'dart:typed_data';

import 'package:fetchnet/services/stream_relay.dart';
import 'package:flutter_test/flutter_test.dart';

/// A site serving one file, answering byte ranges (unless [ranges] is off),
/// and noting what it was asked.
class Site {
  Site._(this._server, this.data, this.ranges);

  static Future<Site> start(int size, {bool ranges = true}) async {
    final data = Uint8List.fromList(List.generate(size, (i) => i % 251));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = Site._(server, data, ranges);
    server.listen(site._handle);
    return site;
  }

  final HttpServer _server;
  final Uint8List data;
  final bool ranges;

  /// "from-to" of each request (`null`: no range).
  final asked = <String?>[];
  final agents = <String?>[];
  final cookies = <String?>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/video.mp4');

  Future<void> _handle(HttpRequest req) async {
    final range = req.headers.value(HttpHeaders.rangeHeader);
    asked.add(range?.replaceFirst('bytes=', ''));
    agents.add(req.headers.value(HttpHeaders.userAgentHeader));
    cookies.add(req.headers.value(HttpHeaders.cookieHeader));
    final res = req.response;
    final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range ?? '');
    if (!ranges || m == null) {
      res.contentLength = data.length;
      res.add(data);
      await res.close();
      return;
    }
    final from = int.parse(m.group(1)!);
    final to = m.group(2)!.isEmpty ? data.length - 1 : int.parse(m.group(2)!).clamp(0, data.length - 1);
    res
      ..statusCode = HttpStatus.partialContent
      ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-$to/${data.length}')
      ..contentLength = to - from + 1;
    res.add(data.sublist(from, to + 1));
    await res.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// Reads [url] as FFmpeg would, with an optional Range header.
Future<(int, Map<String, String>, Uint8List)> fetch(Uri url, {String? range, String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, url);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final bytes = BytesBuilder();
    await for (final c in res) {
      bytes.add(c);
    }
    final headers = <String, String>{};
    res.headers.forEach((k, v) => headers[k] = v.join(','));
    return (res.statusCode, headers, bytes.takeBytes());
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('StreamRelay', () {
    late Site site;
    late StreamRelay relay;
    var relayed = 0;

    setUp(() async {
      site = await Site.start(100000);
      relayed = 0;
      relay = StreamRelay(chunkSize: 16384, onBytes: (n) => relayed += n);
    });

    tearDown(() async {
      await relay.close();
      await site.close();
    });

    test('serves the file from where FFmpeg asks, fetched in closed ranges', () async {
      final local = (await relay.add(site.url, headers: const {'User-Agent': 'FetchNet test', 'Cookie': 'a=1'}))!;
      expect(local.host, '127.0.0.1');

      final (status, headers, body) = await fetch(local, range: 'bytes=1000-');
      expect(status, HttpStatus.partialContent);
      expect(headers[HttpHeaders.contentRangeHeader], 'bytes 1000-99999/100000');
      expect(body, site.data.sublist(1000));
      expect(relayed, 99000);

      // Every request to the site: a closed range, no bigger than a chunk,
      // with the stream's headers.
      for (final r in site.asked) {
        final parts = r!.split('-').map(int.parse).toList();
        expect(parts[1] - parts[0] + 1, lessThanOrEqualTo(16384));
      }
      expect(site.agents.toSet(), {'FetchNet test'});
      expect(site.cookies.toSet(), {'a=1'});
    });

    test('closed and last-bytes ranges, the whole file, and HEAD', () async {
      final local = (await relay.add(site.url))!;
      expect((await fetch(local, range: 'bytes=10-19')).$3, site.data.sublist(10, 20));
      expect((await fetch(local, range: 'bytes=-5')).$3, site.data.sublist(99995));
      final whole = await fetch(local);
      expect(whole.$1, HttpStatus.ok);
      expect(whole.$3, site.data);
      final head = await fetch(local, method: 'HEAD');
      expect(head.$2[HttpHeaders.contentLengthHeader], '100000');
      expect(head.$2[HttpHeaders.acceptRangesHeader], 'bytes');
      expect((await fetch(local, range: 'bytes=200000-')).$1, HttpStatus.requestedRangeNotSatisfiable);
    });

    test('only its own links are served', () async {
      final local = (await relay.add(site.url))!;
      final wrong = local.replace(pathSegments: ['nope', ...local.pathSegments.skip(1)]);
      expect((await fetch(wrong)).$1, HttpStatus.notFound);
    });

    test("a site that doesn't answer ranges is left to FFmpeg", () async {
      final plain = await Site.start(1000, ranges: false);
      addTearDown(plain.close);
      expect(await relay.add(plain.url), isNull);
    });

    test('FFmpeg stopping early (a seek) is fine', () async {
      final local = (await relay.add(site.url))!;
      final client = HttpClient();
      final req = await client.getUrl(local);
      final res = await req.close();
      await res.first; // a little, then gone
      client.close(force: true);
      // Still serving.
      expect((await fetch(local, range: 'bytes=0-9')).$3, site.data.sublist(0, 10));
    });
  });

  group('ResolvedStreams', () {
    test('separate video and audio, with headers, cookies and tags', () {
      final r = ResolvedStreams.fromInfo({
        'title': 'Song title',
        'uploader': 'Channel',
        'requested_formats': [
          {
            'url': 'https://v.example/1',
            'protocol': 'https',
            'vcodec': 'vp9',
            'acodec': 'none',
            'width': 1920,
            'height': 1080,
            'ext': 'webm',
            'http_headers': {'User-Agent': 'UA', 'Accept': '*/*'},
            'cookies': 'SID=abc; Domain=.example; Path=/; Secure; Expires=123; HSID=def; Domain=.example',
          },
          {'url': 'https://a.example/2', 'protocol': 'https', 'vcodec': 'none', 'acodec': 'opus', 'ext': 'webm'},
        ],
      })!;
      expect(r.video!.url.host, 'v.example');
      expect(r.video!.width, 1920);
      expect(r.video!.headers['Cookie'], 'SID=abc; HSID=def');
      expect(r.audio!.acodec, 'opus');
      expect(r.metadata, {'title': 'Song title', 'artist': 'Channel'});
      expect(r.video!.usable, isTrue);
      expect(r.video!.ffmpegHeaders, ['-user_agent', 'UA', '-headers', 'Accept: */*\r\nCookie: SID=abc; HSID=def\r\n']);
    });

    test('one stream with both, and playlists', () {
      final both = ResolvedStreams.fromInfo({'url': 'https://x/1.mp4', 'protocol': 'https', 'vcodec': 'avc1', 'acodec': 'mp4a.40.2'})!;
      expect(identical(both.video, both.audio), isTrue);
      final hls = ResolvedStreams.fromInfo({'url': 'https://x/1.m3u8', 'protocol': 'm3u8_native', 'vcodec': 'avc1', 'acodec': 'mp4a'})!;
      expect(hls.video!.playlist, isTrue);
      expect(hls.video!.usable, isTrue);
      final dash = ResolvedStreams.fromInfo({'url': 'https://x/m.mpd', 'protocol': 'http_dash_segments', 'vcodec': 'avc1'})!;
      expect(dash.video!.usable, isFalse);
      expect(ResolvedStreams.fromInfo({'title': 'no streams'}), isNull);
    });
  });
}
