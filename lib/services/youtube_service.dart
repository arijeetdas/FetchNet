import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/app_prefs.dart';
import '../models/youtube_models.dart';
import 'web_session.dart';
import 'youtube_client.dart';

/// Google sign-in for YouTube (kept in the built-in browser's cookie jar) and
/// the YouTube settings.
class YouTubeService extends ChangeNotifier {
  YouTubeService(this._prefs, this.client) {
    final raw = _prefs.youtubeAccountJson;
    if (raw != null) {
      try {
        _profile = GoogleProfile.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
      } catch (_) {}
    }
    _signedIn = _profile != null;
  }

  final AppPrefs _prefs;
  final YouTubeClient client;

  GoogleProfile? _profile;
  bool _signedIn = false;
  bool _busy = false;
  bool _refreshing = false;

  /// Google's sign-in page, returning to YouTube afterwards.
  static const signInUrl = 'https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true'
      '&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den'
      '%26next%3Dhttps%253A%252F%252Fwww.youtube.com%252F&hl=en';

  static const _cookieUrls = [
    'https://www.youtube.com/',
    'https://m.youtube.com/',
    'https://youtube.com/',
    'https://accounts.youtube.com/',
    'https://accounts.google.com/',
    'https://www.google.com/',
    'https://google.com/',
    'https://myaccount.google.com/',
  ];

  bool get isSupported => WebSession.isSupported;
  bool get signedIn => _signedIn;
  GoogleProfile? get profile => _profile;

  /// Signing out is in progress.
  bool get busy => _busy;

  // ───── Settings ─────

  bool get thumbnailDownloads => _prefs.youtubeThumbnailDownloads;
  Future<void> setThumbnailDownloads(bool value) async {
    await _prefs.setYoutubeThumbnailDownloads(value);
    notifyListeners();
  }

  bool get showTags => _prefs.youtubeShowTags;
  Future<void> setShowTags(bool value) async {
    await _prefs.setYoutubeShowTags(value);
    notifyListeners();
  }

  bool get musicCoverArt => _prefs.youtubeMusicCoverArt;
  Future<void> setMusicCoverArt(bool value) async {
    await _prefs.setYoutubeMusicCoverArt(value);
    notifyListeners();
  }

  bool get videoCoverArt => _prefs.youtubeVideoCoverArt;
  Future<void> setVideoCoverArt(bool value) async {
    await _prefs.setYoutubeVideoCoverArt(value);
    notifyListeners();
  }

  bool get autoplay => _prefs.youtubeAutoplay;
  Future<void> setAutoplay(bool value) async {
    await _prefs.setYoutubeAutoplay(value);
    notifyListeners();
  }

  /// Preferred playback height; 0 = automatic.
  int get quality => _prefs.youtubeQuality;
  Future<void> setQuality(int value) async {
    await _prefs.setYoutubeQuality(value);
    notifyListeners();
  }

  // ───── Search history ─────

  static const _maxHistory = 30;

  List<String> get searchHistory => _prefs.youtubeSearchHistory;

  Future<void> rememberSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final list = [q, ...searchHistory.where((e) => e.toLowerCase() != q.toLowerCase())].take(_maxHistory).toList();
    await _prefs.setYoutubeSearchHistory(list);
    notifyListeners();
  }

  Future<void> forgetSearch(String query) async {
    await _prefs.setYoutubeSearchHistory(searchHistory.where((e) => e != query).toList());
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    await _prefs.setYoutubeSearchHistory(const []);
    notifyListeners();
  }

  // ───── Session ─────

  /// Whether the browser holds a signed-in YouTube session.
  static Future<bool> hasSession() async {
    final cookies = await WebSession.cookiesFor('https://www.youtube.com/');
    return cookies.any((c) => (c.name == 'SAPISID' || c.name == '__Secure-3PAPISID') && '${c.value}'.isNotEmpty);
  }

  /// Re-reads the sign-in state and the account's name, email and photo.
  Future<void> refresh() async {
    if (!isSupported || _refreshing) return;
    _refreshing = true;
    try {
      if (!await hasSession()) {
        if (_signedIn || _profile != null) await _clear();
        return;
      }
      if (!_signedIn) {
        _signedIn = true;
        client.reset();
        notifyListeners();
      }
      final profile = await _fetchProfile();
      if (profile != null) {
        _profile = profile;
        await _prefs.setYoutubeAccountJson(jsonEncode(profile.toJson()));
        notifyListeners();
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<GoogleProfile?> _fetchProfile() async {
    try {
      final p = await _listAccounts();
      if (p != null) return p;
    } catch (_) {}
    try {
      return await client.accountMenu();
    } catch (_) {
      return null;
    }
  }

  /// The account chooser data Chrome uses: name, email and photo.
  Future<GoogleProfile?> _listAccounts() async {
    final cookie = await WebSession.cookieHeader(['https://accounts.google.com/']);
    if (cookie.isEmpty) return null;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await http.postUrl(
        Uri.parse('https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard'),
      );
      req.headers
        ..set(HttpHeaders.userAgentHeader, WebSession.desktopUserAgent)
        ..set(HttpHeaders.cookieHeader, cookie)
        ..set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded');
      req.write(' ');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      if (res.statusCode != 200) return null;
      return parseListAccounts(body);
    } finally {
      http.close(force: true);
    }
  }

  @visibleForTesting
  static GoogleProfile? parseListAccounts(String body) {
    var text = body.trim();
    if (text.startsWith(")]}'")) text = text.substring(4).trim();
    final data = jsonDecode(text);
    if (data is! List || data.length < 2 || data[1] is! List) return null;
    final accounts = (data[1] as List).whereType<List>().where((a) => a.length > 4 && '${a[3]}'.contains('@')).toList();
    if (accounts.isEmpty) return null;
    // Entries flagged as signed out (index 14) are listed after active ones.
    final active = accounts.firstWhere((a) => !(a.length > 14 && a[14] == 1), orElse: () => accounts.first);
    final email = '${active[3]}';
    final name = active[2] is String && (active[2] as String).isNotEmpty ? active[2] as String : email;
    final photo = active[4] is String ? sizedPhoto(active[4] as String) : null;
    return GoogleProfile(name: name, email: email, avatarUrl: photo);
  }

  /// Asks Google's image server for a sharper avatar.
  static String sizedPhoto(String url, {int size = 256}) {
    final u = url.startsWith('//') ? 'https:$url' : url;
    if (RegExp(r'=s\d+(-[a-z]+)*$').hasMatch(u)) return u.replaceFirst(RegExp(r'=s\d+(-[a-z]+)*$'), '=s$size-c');
    if (RegExp(r'/s\d+(-[a-z]+)*/').hasMatch(u)) return u.replaceFirst(RegExp(r'/s\d+(-[a-z]+)*/'), '/s$size-c/');
    return u;
  }

  /// Called by the sign-in page once Google hands back to YouTube.
  Future<void> completeSignIn() async {
    client.reset();
    _signedIn = true;
    notifyListeners();
    await WebSession.flush();
    await refresh();
  }

  Future<void> signOut() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await _serverLogout();
      await WebSession.deleteCookies(_cookieUrls);
      if (await hasSession()) {
        // Last resort: the plugin's own per-domain removal.
        for (final u in _cookieUrls) {
          final host = Uri.parse(u).host;
          for (final d in {null, host, '.${WebSession.baseDomain(host)}'}) {
            try {
              await WebSession.cookies.deleteCookies(url: WebUri(u), domain: d);
            } catch (_) {}
          }
        }
        await WebSession.flush();
      }
    } finally {
      client.reset();
      await _clear(notify: false);
      _busy = false;
      notifyListeners();
    }
  }

  /// Ends the session on Google's side, using the browser's own cookies.
  Future<void> _serverLogout() async {
    final done = Completer<void>();
    HeadlessInAppWebView? view;
    try {
      view = HeadlessInAppWebView(
        webViewEnvironment: WebSession.environment,
        initialSettings: WebSession.baseSettings(),
        initialUrlRequest: URLRequest(
          url: WebUri('https://accounts.google.com/Logout?service=youtube&continue=https://www.youtube.com/&hl=en'),
        ),
        onLoadStop: (c, url) {
          if (url != null && isYouTubeHost(url.host) && !done.isCompleted) done.complete();
        },
      );
      await view.run();
      await done.future.timeout(const Duration(seconds: 12), onTimeout: () {});
    } catch (_) {
    } finally {
      try {
        await view?.dispose();
      } catch (_) {}
    }
  }

  Future<void> _clear({bool notify = true}) async {
    _profile = null;
    _signedIn = false;
    await _prefs.setYoutubeAccountJson(null);
    if (notify) notifyListeners();
  }
}
