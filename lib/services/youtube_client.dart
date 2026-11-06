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

  Future<YtPage> search(String query, {String? params}) async {
    final json = await _post('search', {'query': query, 'params': ?params});
    return _page(json['contents']);
  }

  /// Any browse page (feeds, channel tabs, destination channels).
  Future<YtPage> browse(String browseId, {String? params}) async {
    final json = await _post('browse', {'browseId': browseId, 'params': ?params});
    return _page(json['contents']);
  }

  /// Videos from the channels the account follows, newest first.
  Future<YtPage> subscriptions() => browse('FEsubscriptions');

  /// YouTube's Music destination.
  Future<YtPage> music() => _atLeast(browse(_musicChannel), () => search('official music video', params: _thisWeekByViews));

  /// What's popular now. YouTube retired its Trending page, so this mixes
  /// the destination channels (News, Sports, Live, Music) like Explore does.
  Future<YtPage> trending(YtTrendingTopic topic) async {
    if (topic != YtTrendingTopic.now) {
      final page = browse(topic.channelId!);
      return topic == YtTrendingTopic.gaming
          ? _atLeast(page, () => search('gaming', params: _thisWeekByViews))
          : page;
    }
    final pages = await Future.wait([
      for (final id in [YtTrendingTopic.news.channelId!, YtTrendingTopic.sports.channelId!, _musicChannel, YtTrendingTopic.live.channelId!])
        browse(id).then<YtPage?>((p) => p).catchError((Object _) => null),
    ]);
    final lists = [for (final p in pages) if (p != null) p.items.where((v) => !v.isShort).toList()];
    if (lists.isEmpty) throw const YtException('Couldn\'t load what\'s trending.');
    final seen = <String>{};
    final mixed = <YtVideo>[];
    for (var i = 0; lists.any((l) => i < l.length); i++) {
      for (final l in lists) {
        if (i < l.length && seen.add(l[i].id)) mixed.add(l[i]);
      }
    }
    return YtPage(items: mixed);
  }

  /// Sort by views, uploaded this week, videos only.
  static const _thisWeekByViews = 'CAMSBAgDEAE%3D';
  static const _musicChannel = 'UC-9-kyTW8ZkZNDHQJ6FgpwQ';

  /// [primary], topped up from [fallback] when it brings back too little.
  static Future<YtPage> _atLeast(Future<YtPage> primary, Future<YtPage> Function() fallback, {int min = 8}) async {
    YtPage? first;
    try {
      first = await primary;
      if (first.items.length >= min) return first;
    } catch (_) {}
    try {
      final extra = await fallback();
      final seen = <String>{};
      return YtPage(
        items: [...?first?.items, ...extra.items].where((v) => seen.add(v.id)).toList(),
        continuation: first?.continuation ?? extra.continuation,
      );
    } catch (_) {
      if (first != null) return first;
      rethrow;
    }
  }

  /// Search suggestions for what's typed so far (empty on any failure).
  Future<List<String>> suggestions(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final uri = Uri.https('suggestqueries.google.com', '/complete/search', {
        'client': 'firefox',
        'ds': 'yt',
        'hl': 'en',
        'ie': 'utf-8',
        'oe': 'utf-8',
        'q': q,
      });
      final req = await _http.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, WebSession.desktopUserAgent);
      final res = await req.close().timeout(const Duration(seconds: 6));
      final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      if (res.statusCode != 200) return const [];
      return parseSuggestions(body);
    } catch (_) {
      return const [];
    }
  }

  @visibleForTesting
  static List<String> parseSuggestions(String body) {
    try {
      final data = jsonDecode(body);
      if (data is! List || data.length < 2 || data[1] is! List) return const [];
      return [
        for (final s in data[1] as List)
          if (s is String && s.trim().isNotEmpty) s.trim()
          else if (s is List && s.isNotEmpty && s.first is String) (s.first as String).trim(),
      ].take(10).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Channels the account follows, most relevant first.
  Future<List<YtChannel>> subscribedChannels() async {
    final json = await _post('browse', {'browseId': 'FEchannels'});
    final out = <YtChannel>[];
    final seen = <String>{};
    for (final key in const ['channelRenderer', 'gridChannelRenderer']) {
      for (final c in _all(json['contents'], key)) {
        final id = c['channelId'];
        final name = _text(c['title']);
        if (id is! String || name == null || !seen.add(id)) continue;
        // On this page `subscriberCountText` often holds the @handle.
        final a = _text(c['subscriberCountText']);
        final b = _text(c['videoCountText']);
        out.add(YtChannel(
          id: id,
          name: name,
          avatar: _thumb(c['thumbnail']),
          handle: a != null && a.startsWith('@') ? a : null,
          subscribers: [a, b].whereType<String>().firstWhere((t) => t.contains('subscriber'), orElse: () => '').nullIfEmpty,
          subscribed: true,
        ));
      }
    }
    return out;
  }

  /// A channel's header and uploads.
  Future<YtChannelPage> channel(String channelId) async {
    final home = await _post('browse', {'browseId': channelId});
    final tabs = {
      for (final t in _all(home['contents'], 'tabRenderer'))
        _tabName(t): _dig(t, ['endpoint', 'browseEndpoint', 'params']) as String?,
    };
    _postsParams ??= tabs['posts'];
    final header = _channelHeader(channelId, home);
    YtPage videos = _page(home['contents']);
    final videosParams = tabs['videos'];
    if (videosParams != null) {
      try {
        videos = await browse(channelId, params: videosParams);
      } catch (_) {}
    }
    return YtChannelPage(channel: header, videos: videos, postsParams: tabs['posts']);
  }

  /// Posts tab params, learnt from the first channel page opened.
  static String? _postsParams;
  static const _defaultPostsParams = 'EgVwb3N0c_IGBAoCSgA%3D';

  static String _tabName(Map tab) {
    final url = '${_dig(tab, ['endpoint', 'commandMetadata', 'webCommandMetadata', 'url']) ?? ''}';
    final last = url.split('/').last.toLowerCase();
    if (last == 'community') return 'posts';
    if (last.isNotEmpty) return last;
    return '${tab['title'] ?? ''}'.toLowerCase();
  }

  /// One channel's posts.
  Future<List<YtPost>> channelPosts(String channelId, {String? params}) async {
    final json = await _post('browse', {'browseId': channelId, 'params': params ?? _postsParams ?? _defaultPostsParams});
    return parsePosts(json['contents']);
  }

  /// Recent posts of the first [channels] the account follows, newest first.
  Future<List<YtPost>> subscriptionPosts(List<YtChannel> channels, {int max = 10}) async {
    final picked = channels.take(max).toList();
    final results = <List<YtPost>>[];
    // A few at a time: YouTube rate-limits bursts.
    for (var i = 0; i < picked.length; i += 4) {
      final batch = picked.skip(i).take(4);
      results.addAll(await Future.wait(
        batch.map((c) => channelPosts(c.id).catchError((Object _) => const <YtPost>[])),
      ));
    }
    final seen = <String>{};
    final all = [for (final l in results) ...l.take(6)].where((p) => seen.add(p.id)).toList()
      ..sort((a, b) => a.age.compareTo(b.age));
    return all;
  }

  /// Follows or unfollows a channel.
  Future<void> setSubscribed(String channelId, bool subscribe) async {
    await _post(subscribe ? 'subscription/subscribe' : 'subscription/unsubscribe', {
      'channelIds': [channelId],
      'params': subscribe ? 'EgIIAhgA' : 'CgIIAhgA',
    });
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
    String? likes;
    if (primary is Map) {
      title = _text(primary['title']);
      final vc = _dig(primary, ['viewCount', 'videoViewCountRenderer']);
      views = _text(vc?['viewCount']) ?? _text(vc?['shortViewCount']);
      published = _text(primary['relativeDateText']) ?? _text(primary['dateText']);
      final entity = _first(primary, 'likeCountEntity');
      likes = entity is Map ? _text(entity['likeCountIfIndifferent']) : null;
      if (likes == null) {
        final like = _first(primary, 'likeButtonViewModel');
        final t = _first(like, 'title');
        if (t is String && RegExp(r'\d').hasMatch(t)) likes = t;
      }
    }
    String? description;
    if (secondary is Map) {
      description = _text(secondary['attributedDescription']) ?? _text(secondary['description']);
    }
    final sub = secondary is Map ? _first(secondary['subscribeButton'], 'subscribeButtonRenderer') : null;
    var channelId = _dig(owner, ['navigationEndpoint', 'browseEndpoint', 'browseId']);
    if (channelId is! String && sub is Map) channelId = sub['channelId'];
    return YtWatchInfo(
      id: id,
      title: title ?? 'YouTube video',
      channel: _text(owner?['title']),
      channelId: channelId is String ? channelId : null,
      channelAvatar: _thumb(owner?['thumbnail']),
      subscribers: _text(owner?['subscriberCountText']),
      subscribed: _subscribedState(data, sub),
      views: views,
      published: published,
      likes: likes,
      description: description,
      related: related.items.where((v) => v.id != id).toList(),
      relatedContinuation: related.continuation,
    );
  }

  /// `subscribed` from the classic button, else from the entity store.
  static bool? _subscribedState(Map<String, dynamic> data, dynamic button) {
    if (button is Map && button['subscribed'] is bool) return button['subscribed'] as bool;
    final entity = _first(data['frameworkUpdates'], 'subscriptionStateEntity');
    if (entity is Map && entity['subscribed'] is bool) return entity['subscribed'] as bool;
    return null;
  }

  @visibleForTesting
  static YtChannel parseChannelHeader(String channelId, Map<String, dynamic> data) => _channelHeader(channelId, data);

  static YtChannel _channelHeader(String channelId, Map<String, dynamic> data) {
    final meta = _dig(data, ['metadata', 'channelMetadataRenderer']);
    final header = data['header'];
    final model = _first(header, 'pageHeaderViewModel');
    final classic = _first(header, 'c4TabbedHeaderRenderer');
    final parts = <String>[
      for (final p in _all(_first(model, 'contentMetadataViewModel'), 'text')) ?_text(p),
    ];
    final name = _text(meta?['title']) ?? _text(_dig(model, ['title', 'dynamicTextViewModel', 'text'])) ?? _text(classic?['title']);
    return YtChannel(
      id: (meta?['externalId'] as String?) ?? channelId,
      name: name ?? 'Channel',
      avatar: _thumb(meta?['avatar']) ?? _sources(_first(model, 'avatarViewModel')) ?? _thumb(classic?['avatar']),
      handle: parts.firstWhere((p) => p.startsWith('@'), orElse: () => '').nullIfEmpty ?? _text(classic?['channelHandleText']),
      subscribers: parts.firstWhere((p) => p.contains('subscriber'), orElse: () => '').nullIfEmpty ??
          _text(classic?['subscriberCountText']),
      banner: _sources(_first(model, 'imageBannerViewModel')) ?? _thumb(classic?['banner']),
      subscribed: _subscribedState(data, _first(header, 'subscribeButtonRenderer')),
    );
  }

  @visibleForTesting
  static List<YtPost> parsePosts(dynamic root) {
    final out = <YtPost>[];
    final seen = <String>{};
    for (final p in _all(root, 'backstagePostRenderer')) {
      final id = p['postId'];
      final author = _text(p['authorText']);
      if (id is! String || author == null || !seen.add(id)) continue;
      final attachment = p['backstageAttachment'];
      final images = <String>[
        for (final img in _all(attachment, 'backstageImageRenderer')) ?_thumb(img['image']),
      ];
      YtVideo? video;
      final vr = _first(attachment, 'videoRenderer');
      if (vr != null) video = _videoRenderer(vr);
      out.add(YtPost(
        id: id,
        author: author,
        authorAvatar: _thumb(p['authorThumbnail']),
        channelId: _dig(p, ['authorEndpoint', 'browseEndpoint', 'browseId']) as String?,
        text: _text(p['contentText']),
        published: _text(p['publishedTimeText']),
        likes: _text(p['voteCount']),
        images: images,
        video: video,
      ));
    }
    return out;
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

/// Chips on the Trending tab, backed by YouTube's destination channels.
enum YtTrendingTopic {
  now('Now', null),
  news('News', 'UCYfdidRxbB8Qhf0Nx7ioOYw'),
  sports('Sports', 'UCEgdi0XIXXZ-qJOFPf4JSKw'),
  live('Live', 'UC4R8DWoMoI7CAwX8_LjQHig'),
  gaming('Gaming', 'UCOpNcN46UbXVtpKMrmU4Abg');

  const YtTrendingTopic(this.label, this.channelId);

  final String label;
  final String? channelId;
}

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

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
