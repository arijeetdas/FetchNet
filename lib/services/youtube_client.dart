import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/youtube_models.dart';
import 'web_session.dart';

/// Reads YouTube's own web data (home feed, search, watch page) with the
/// built-in browser's sign-in, so results are personalised like on
/// youtube.com.
class YouTubeClient {
  static const _origin = 'https://www.youtube.com';
  static const _fallbackClientVersion = '2.20261101.00.00';

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);

  _Session? _session;

  // ───── Public API ─────

  /// The recommended feed of the signed-in account.
  Future<YtPage> home() async {
    final html = await _get('$_origin/');
    _session = _Session.parse(html) ?? _session;
    final data = _initialData(html);
    if (data == null) throw const YtException('Couldn\'t read YouTube\'s home page.');
    return _page(data['contents']);
  }

  Future<YtPage> search(String query) async {
    final json = await _post('search', {'query': query});
    return _page(json['contents']);
  }

  /// Next page of a home feed, search or related list.
  Future<YtPage> more(YtFeedKind kind, String token) async {
    final endpoint = switch (kind) {
      YtFeedKind.home => 'browse',
      YtFeedKind.search => 'search',
      YtFeedKind.related => 'next',
    };
    final json = await _post(endpoint, {'continuation': token});
    json.remove('responseContext');
    json.remove('frameworkUpdates');
    return _page(json);
  }

  Future<YtWatchInfo> watch(String id) async {
    Map<String, dynamic>? data;
    try {
      data = await _post('next', {'videoId': id});
    } catch (_) {
      final html = await _get('$_origin/watch?v=$id');
      _session ??= _Session.parse(html);
      data = _initialData(html);
    }
    if (data == null) throw const YtException('Couldn\'t load this video.');
    return _watchInfo(id, data);
  }

  /// Name, handle and photo of the signed-in YouTube account.
  Future<GoogleProfile?> accountMenu() async {
    final json = await _post('account/account_menu', {});
    final header = _first(json, 'activeAccountHeaderRenderer');
    if (header is! Map) return null;
    final name = _text(header['accountName']);
    if (name == null) return null;
    return GoogleProfile(
      name: name,
      email: _text(header['email']) ?? _text(header['channelHandle']),
      avatarUrl: _thumb(header['accountPhoto']),
    );
  }

  /// Forget the cached YouTube session (after sign-in / sign-out).
  void reset() => _session = null;

  // ───── HTTP ─────

  Future<Map<String, String>> _cookies() async {
    final list = await WebSession.cookiesFor('$_origin/');
    return {for (final c in list) c.name: '${c.value}'};
  }

  static String _cookieHeader(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Future<String> _get(String url) async {
    try {
      final cookies = await _cookies();
      final req = await _http.getUrl(Uri.parse(url));
      req.headers
        ..set(HttpHeaders.userAgentHeader, WebSession.desktopUserAgent)
        ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9')
        ..set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
      if (cookies.isNotEmpty) req.headers.set(HttpHeaders.cookieHeader, _cookieHeader(cookies));
      final res = await req.close().timeout(const Duration(seconds: 25));
      final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      if (res.statusCode != 200) throw YtException('YouTube answered with error ${res.statusCode}.');
      return body;
    } on YtException {
      rethrow;
    } on TimeoutException {
      throw const YtException('YouTube took too long to answer.');
    } on SocketException {
      throw const YtException('Couldn\'t reach YouTube. Check your internet connection.');
    } catch (e) {
      throw YtException('Couldn\'t reach YouTube ($e).');
    }
  }

  Future<_Session> _ensureSession() async {
    final s = _session;
    if (s != null) return s;
    try {
      final html = await _get('$_origin/');
      return _session = _Session.parse(html) ?? _Session.fallback();
    } catch (_) {
      return _Session.fallback();
    }
  }

  /// `SAPISIDHASH ...` authorisation, as youtube.com sends it.
  static String? _authorization(Map<String, String> cookies) {
    final ts = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final parts = <String>[];
    for (final (scheme, name) in const [
      ('SAPISIDHASH', 'SAPISID'),
      ('SAPISID1PHASH', '__Secure-1PAPISID'),
      ('SAPISID3PHASH', '__Secure-3PAPISID'),
    ]) {
      final sid = cookies[name];
      if (sid == null || sid.isEmpty) continue;
      final hash = sha1.convert(utf8.encode('$ts $sid $_origin')).toString();
      parts.add('$scheme ${ts}_$hash');
    }
    return parts.isEmpty ? null : parts.join(' ');
  }

  Future<Map<String, dynamic>> _post(String endpoint, Map<String, dynamic> body) async {
    final session = await _ensureSession();
    try {
      final cookies = await _cookies();
      final key = session.apiKey == null ? '' : '&key=${session.apiKey}';
      final req = await _http.postUrl(Uri.parse('$_origin/youtubei/v1/$endpoint?prettyPrint=false$key'));
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.userAgentHeader, WebSession.desktopUserAgent)
        ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9')
        ..set('Origin', _origin)
        ..set('X-Origin', _origin)
        ..set(HttpHeaders.refererHeader, '$_origin/')
        ..set('X-Youtube-Client-Name', '1')
        ..set('X-Youtube-Client-Version', session.clientVersion)
        ..set('X-Goog-AuthUser', session.sessionIndex ?? '0');
      if (session.visitorData != null) req.headers.set('X-Goog-Visitor-Id', session.visitorData!);
      if (session.delegatedSessionId != null) req.headers.set('X-Goog-PageId', session.delegatedSessionId!);
      final auth = _authorization(cookies);
      if (auth != null) req.headers.set(HttpHeaders.authorizationHeader, auth);
      if (cookies.isNotEmpty) req.headers.set(HttpHeaders.cookieHeader, _cookieHeader(cookies));
      req.add(utf8.encode(jsonEncode({'context': session.context, ...body})));
      final res = await req.close().timeout(const Duration(seconds: 25));
      final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      if (res.statusCode != 200) throw YtException('YouTube answered with error ${res.statusCode}.');
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw const YtException('YouTube sent an unexpected answer.');
      return decoded.cast<String, dynamic>();
    } on YtException {
      rethrow;
    } on TimeoutException {
      throw const YtException('YouTube took too long to answer.');
    } on SocketException {
      throw const YtException('Couldn\'t reach YouTube. Check your internet connection.');
    } catch (e) {
      throw YtException('Couldn\'t read YouTube\'s answer ($e).');
    }
  }

  // ───── Page data ─────

  static Map<String, dynamic>? _initialData(String html) {
    for (final marker in const ['var ytInitialData = ', 'window["ytInitialData"] = ', 'ytInitialData = ']) {
      final i = html.indexOf(marker);
      if (i < 0) continue;
      final json = extractJsonObject(html, i + marker.length);
      if (json != null) return json;
    }
    return null;
  }

  @visibleForTesting
  static YtPage parseFeed(dynamic root) => _page(root);

  @visibleForTesting
  static YtWatchInfo parseWatch(String id, Map<String, dynamic> data) => _watchInfo(id, data);

  static YtPage _page(dynamic root) {
    final out = <YtVideo>[];
    final seen = <String>{};
    String? token;
    _walk(root, (v) {
      if (seen.add('${v.isShort ? 's' : 'v'}${v.id}')) out.add(v);
    }, (t) => token = t);
    return YtPage(items: out, continuation: token);
  }

  static YtWatchInfo _watchInfo(String id, Map<String, dynamic> data) {
    final results = _dig(data, ['contents', 'twoColumnWatchNextResults']);
    final primary = _first(results?['results'], 'videoPrimaryInfoRenderer');
    final secondary = _first(results?['results'], 'videoSecondaryInfoRenderer');
    final owner = secondary is Map ? _dig(secondary, ['owner', 'videoOwnerRenderer']) : null;
    final related = _page(results?['secondaryResults']);
    String? views;
    String? published;
    String? title;
    if (primary is Map) {
      title = _text(primary['title']);
      final vc = _dig(primary, ['viewCount', 'videoViewCountRenderer']);
      views = _text(vc?['viewCount']) ?? _text(vc?['shortViewCount']);
      published = _text(primary['relativeDateText']) ?? _text(primary['dateText']);
    }
    String? description;
    if (secondary is Map) {
      description = _text(secondary['attributedDescription']) ?? _text(secondary['description']);
    }
    return YtWatchInfo(
      id: id,
      title: title ?? 'YouTube video',
      channel: _text(owner?['title']),
      channelAvatar: _thumb(owner?['thumbnail']),
      subscribers: _text(owner?['subscriberCountText']),
      views: views,
      published: published,
      description: description,
      related: related.items.where((v) => v.id != id).toList(),
      relatedContinuation: related.continuation,
    );
  }

  // ───── Walking YouTube's renderer tree ─────

  static const _skip = {
    'adSlotRenderer',
    'promotedVideoRenderer',
    'promotedSparklesWebRenderer',
    'searchPyvRenderer',
    'adSlotAndLayoutRenderer',
    'compactPromotedVideoRenderer',
    'frameworkUpdates',
    'responseContext',
    'header',
    'topbar',
  };

  static void _walk(dynamic node, void Function(YtVideo) onVideo, void Function(String) onToken) {
    if (node is List) {
      for (final e in node) {
        _walk(e, onVideo, onToken);
      }
      return;
    }
    if (node is! Map) return;
    for (final entry in node.entries) {
      final key = entry.key;
      final value = entry.value;
      if (_skip.contains(key)) continue;
      if (value is! Map && value is! List) continue;
      switch (key) {
        case 'videoRenderer' || 'compactVideoRenderer' || 'gridVideoRenderer' || 'videoWithContextRenderer':
          final v = _videoRenderer(value);
          if (v != null) onVideo(v);
        case 'lockupViewModel':
          final v = _lockup(value);
          if (v != null) onVideo(v);
        case 'reelItemRenderer':
          final v = _reelItem(value);
          if (v != null) onVideo(v);
        case 'shortsLockupViewModel':
          final v = _shortsLockup(value);
          if (v != null) onVideo(v);
        case 'continuationItemRenderer':
          final cmd = _first(value, 'continuationCommand');
          final token = cmd is Map ? cmd['token'] : null;
          if (token is String && token.isNotEmpty) onToken(token);
        default:
          _walk(value, onVideo, onToken);
      }
    }
  }

  static YtVideo? _videoRenderer(dynamic v) {
    if (v is! Map) return null;
    final id = v['videoId'];
    if (id is! String || id.isEmpty) return null;
    final title = _text(v['title']) ?? _text(v['headline']);
    if (title == null) return null;
    String? duration = _text(v['lengthText']);
    var live = false;
    final overlays = v['thumbnailOverlays'];
    if (overlays is List) {
      for (final o in overlays.whereType<Map>()) {
        final ts = o['thumbnailOverlayTimeStatusRenderer'];
        if (ts is Map) {
          duration ??= _text(ts['text']);
          if ('${ts['style']}'.contains('LIVE')) live = true;
        }
      }
    }
    final badges = v['badges'];
    if (badges is List && jsonEncode(badges).contains('LIVE')) live = true;
    final views = _text(v['shortViewCountText']) ?? _text(v['viewCountText']);
    if (views != null && views.contains('watching')) live = true;
    return YtVideo(
      id: id,
      title: title,
      thumbnail: _thumb(v['thumbnail']) ?? 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      channel: _text(v['ownerText']) ?? _text(v['longBylineText']) ?? _text(v['shortBylineText']),
      channelAvatar: _thumb(_dig(v, ['channelThumbnailSupportedRenderers', 'channelThumbnailWithLinkRenderer', 'thumbnail'])) ??
          _thumb(v['channelThumbnail']),
      views: views,
      published: _text(v['publishedTimeText']),
      duration: live ? null : duration,
      isLive: live,
    );
  }

  static YtVideo? _lockup(dynamic v) {
    if (v is! Map) return null;
    final type = '${v['contentType'] ?? ''}';
    if (type.isNotEmpty && type != 'LOCKUP_CONTENT_TYPE_VIDEO') return null;
    var id = v['contentId'];
    if (id is! String || id.length != 11) {
      final we = _first(v['rendererContext'], 'watchEndpoint');
      id = we is Map ? we['videoId'] : null;
    }
    if (id is! String || id.length != 11) return null;
    final meta = _dig(v, ['metadata', 'lockupMetadataViewModel']);
    final title = _text(meta?['title']);
    if (title == null) return null;
    final rows = <List<String>>[];
    final rowList = _dig(meta, ['metadata', 'contentMetadataViewModel', 'metadataRows']);
    if (rowList is List) {
      for (final row in rowList.whereType<Map>()) {
        final parts = row['metadataParts'];
        if (parts is! List) continue;
        rows.add([
          for (final part in parts.whereType<Map>()) ?_text(part['text']),
        ]);
      }
    }
    final image = v['contentImage'];
    String? duration;
    var live = false;
    for (final badge in _all(image, 'thumbnailBadgeViewModel')) {
      final text = _text(badge['text']);
      final style = '${badge['badgeStyle'] ?? ''}';
      if (style.contains('LIVE') || text == 'LIVE') {
        live = true;
      } else if (text != null && RegExp(r'^\d+(:\d{2})+$').hasMatch(text)) {
        duration ??= text;
      }
    }
    final stats = rows.length > 1 ? rows[1] : const <String>[];
    return YtVideo(
      id: id,
      title: title,
      thumbnail: _sources(image) ?? 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      channel: rows.isNotEmpty && rows.first.isNotEmpty ? rows.first.first : null,
      channelAvatar: _sources(meta?['image']),
      views: stats.isNotEmpty ? stats.first : null,
      published: stats.length > 1 ? stats[1] : null,
      duration: live ? null : duration,
      isLive: live,
    );
  }

  static YtVideo? _reelItem(dynamic v) {
    if (v is! Map) return null;
    final id = v['videoId'];
    if (id is! String || id.isEmpty) return null;
    return YtVideo(
      id: id,
      title: _text(v['headline']) ?? 'Short',
      thumbnail: _thumb(v['thumbnail']) ?? 'https://i.ytimg.com/vi/$id/oardefault.jpg',
      views: _text(v['viewCountText']),
      isShort: true,
    );
  }

  static YtVideo? _shortsLockup(dynamic v) {
    if (v is! Map) return null;
    final rwe = _first(v['onTap'], 'reelWatchEndpoint');
    var id = rwe is Map ? rwe['videoId'] : null;
    if (id is! String) {
      final entity = '${v['entityId'] ?? ''}';
      final m = RegExp(r'([\w-]{11})$').firstMatch(entity);
      id = m?.group(1);
    }
    if (id is! String) return null;
    final overlay = v['overlayMetadata'];
    return YtVideo(
      id: id,
      title: _text(overlay is Map ? overlay['primaryText'] : null) ?? 'Short',
      thumbnail: _sources(v['thumbnail']) ?? 'https://i.ytimg.com/vi/$id/oardefault.jpg',
      views: _text(overlay is Map ? overlay['secondaryText'] : null),
      isShort: true,
    );
  }

  // ───── JSON helpers ─────

  static dynamic _dig(dynamic node, List<String> path) {
    var cur = node;
    for (final key in path) {
      if (cur is! Map) return null;
      cur = cur[key];
    }
    return cur;
  }

  /// First value stored under [key] anywhere below [node].
  static dynamic _first(dynamic node, String key) {
    if (node is Map) {
      if (node.containsKey(key)) return node[key];
      for (final v in node.values) {
        final r = _first(v, key);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _first(v, key);
        if (r != null) return r;
      }
    }
    return null;
  }

  static Iterable<Map> _all(dynamic node, String key) sync* {
    if (node is Map) {
      for (final e in node.entries) {
        if (e.key == key && e.value is Map) {
          yield e.value as Map;
        } else {
          yield* _all(e.value, key);
        }
      }
    } else if (node is List) {
      for (final v in node) {
        yield* _all(v, key);
      }
    }
  }

  static String? _text(dynamic n) {
    if (n == null) return null;
    String? s;
    if (n is String) {
      s = n;
    } else if (n is Map) {
      if (n['simpleText'] is String) {
        s = n['simpleText'] as String;
      } else if (n['runs'] is List) {
        s = (n['runs'] as List).whereType<Map>().map((r) => '${r['text'] ?? ''}').join();
      } else if (n['content'] is String) {
        s = n['content'] as String;
      }
    }
    s = s?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  static String? _fixUrl(dynamic u) {
    if (u is! String || u.isEmpty) return null;
    return u.startsWith('//') ? 'https:$u' : u;
  }

  /// Largest thumbnail of a `{thumbnails: [...]}` node.
  static String? _thumb(dynamic node) {
    final list = node is Map ? node['thumbnails'] : null;
    if (list is! List || list.isEmpty) return null;
    final last = list.whereType<Map>().lastOrNull;
    return _fixUrl(last?['url']);
  }

  /// Largest image of the first `sources: [...]` list below [node].
  static String? _sources(dynamic node) {
    final list = _first(node, 'sources');
    if (list is! List || list.isEmpty) return null;
    final last = list.whereType<Map>().lastOrNull;
    return _fixUrl(last?['url']);
  }
}

enum YtFeedKind { home, search, related }

/// Request context from youtube.com's `ytcfg`.
class _Session {
  _Session({
    required this.context,
    required this.clientVersion,
    this.apiKey,
    this.visitorData,
    this.sessionIndex,
    this.delegatedSessionId,
  });

  final Map<String, dynamic> context;
  final String clientVersion;
  final String? apiKey;
  final String? visitorData;
  final String? sessionIndex;
  final String? delegatedSessionId;

  factory _Session.fallback() => _Session(
        context: {
          'client': {'clientName': 'WEB', 'clientVersion': YouTubeClient._fallbackClientVersion, 'hl': 'en', 'gl': 'US'},
        },
        clientVersion: YouTubeClient._fallbackClientVersion,
      );

  static _Session? parse(String html) {
    final cfg = <String, dynamic>{};
    const marker = 'ytcfg.set({';
    var i = html.indexOf(marker);
    while (i >= 0) {
      final json = extractJsonObject(html, i + marker.length - 1);
      if (json != null) cfg.addAll(json);
      i = html.indexOf(marker, i + marker.length);
    }
    final context = cfg['INNERTUBE_CONTEXT'];
    if (context is! Map) return null;
    final client = context['client'];
    final version = (client is Map ? client['clientVersion'] : null) ?? cfg['INNERTUBE_CLIENT_VERSION'];
    return _Session(
      context: context.cast<String, dynamic>(),
      clientVersion: '${version ?? YouTubeClient._fallbackClientVersion}',
      apiKey: cfg['INNERTUBE_API_KEY'] as String?,
      visitorData: (client is Map ? client['visitorData'] : null) as String? ?? cfg['VISITOR_DATA'] as String?,
      sessionIndex: cfg['SESSION_INDEX']?.toString(),
      delegatedSessionId: cfg['DELEGATED_SESSION_ID'] as String?,
    );
  }
}

/// Parses the JSON object that starts at (or after) [start] in [source],
/// matching braces while respecting strings.
Map<String, dynamic>? extractJsonObject(String source, int start) {
  final open = source.indexOf('{', start);
  if (open < 0 || open - start > 4) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = open; i < source.length; i++) {
    final ch = source.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == 0x5C) {
        escaped = true;
      } else if (ch == 0x22) {
        inString = false;
      }
      continue;
    }
    if (ch == 0x22) {
      inString = true;
    } else if (ch == 0x7B) {
      depth++;
    } else if (ch == 0x7D) {
      depth--;
      if (depth == 0) {
        try {
          final decoded = jsonDecode(source.substring(open, i + 1));
          return decoded is Map ? decoded.cast<String, dynamic>() : null;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}
