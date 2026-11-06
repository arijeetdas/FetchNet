import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The built-in browser's profile, shared by every web view in FetchNet.
///
/// Cookies, local storage and sign-ins persist between launches like in a
/// regular browser, so a site the user signed in to once stays signed in and
/// its cookies can be handed to yt-dlp.
class WebSession {
  WebSession._();

  static WebViewEnvironment? _environment;
  static CookieManager? _cookieManager;
  static String? _mobileUserAgent;
  static String _chromeMajor = '141';

  /// Windows only: the WebView2 environment with a fixed, writable profile
  /// folder. `null` elsewhere (Android / Apple web views persist on their own).
  static WebViewEnvironment? get environment => _environment;

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  static bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Call once before the first web view is created.
  static Future<void> initialize() async {
    if (!isSupported) return;
    if (Platform.isWindows) {
      try {
        final support = await getApplicationSupportDirectory();
        final dir = Directory(p.join(support.path, 'WebView2'));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        _environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: dir.path),
        ).timeout(const Duration(seconds: 10));
      } catch (_) {
        _environment = null;
      }
    }
    if (Platform.isAndroid) {
      try {
        final ua = await InAppWebViewController.getDefaultUserAgent().timeout(const Duration(seconds: 5));
        _mobileUserAgent = cleanUserAgent(ua);
        final major = RegExp(r'Chrome/(\d+)').firstMatch(ua)?.group(1);
        if (major != null) _chromeMajor = major;
      } catch (_) {}
    }
  }

  /// Drops the Android WebView markers (`; wv`, `Version/4.0`) so sites such
  /// as Google sign-in treat the browser like regular Chrome.
  static String cleanUserAgent(String ua) =>
      ua.replaceAll('; wv)', ')').replaceAll(RegExp(r'Version/\d+(\.\d+)*\s+'), '');

  /// User agent for the built-in browser, or `''` for the platform default.
  static String get userAgent => _mobileUserAgent ?? '';

  /// A desktop Chrome user agent ("Desktop view" and server requests).
  static String get desktopUserAgent =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/$_chromeMajor.0.0.0 Safari/537.36';

  /// Settings every FetchNet web view starts from.
  static InAppWebViewSettings baseSettings({bool desktop = false}) => InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        cacheEnabled: true,
        incognito: false,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
        userAgent: desktop ? desktopUserAgent : userAgent,
        preferredContentMode: desktop ? UserPreferredContentMode.DESKTOP : UserPreferredContentMode.RECOMMENDED,
        useWideViewPort: true,
        loadWithOverviewMode: true,
        // Android adds `X-Requested-With: <package>` to every request by
        // default, which Google uses to refuse sign-in from embedded browsers.
        requestedWithHeaderOriginAllowList: const {},
        allowsInlineMediaPlayback: true,
        isInspectable: kDebugMode,
      );

  static CookieManager get cookies =>
      _cookieManager ??= CookieManager.instance(webViewEnvironment: _environment);

  /// Every cookie the browser would send to [url].
  static Future<List<Cookie>> cookiesFor(String url) async {
    if (!isSupported) return const [];
    try {
      return await cookies.getCookies(url: WebUri(url)).timeout(const Duration(seconds: 8));
    } catch (_) {
      return const [];
    }
  }

  /// A `Cookie:` header value with the browser's cookies for [urls].
  static Future<String> cookieHeader(List<String> urls) async {
    final values = <String, String>{};
    for (final u in urls) {
      for (final c in await cookiesFor(u)) {
        values.putIfAbsent(c.name, () => '${c.value}');
      }
    }
    return values.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Persists cookies to disk now (Android writes them lazily).
  static Future<void> flush() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await cookies.flush();
    } catch (_) {}
  }

  /// `example.com` for `www.example.com`, `bbc.co.uk` for `www.bbc.co.uk`.
  static String baseDomain(String host) {
    final labels = host.toLowerCase().split('.').where((e) => e.isNotEmpty).toList();
    if (labels.length <= 2) return labels.join('.');
    const secondLevel = {'co', 'com', 'net', 'org', 'gov', 'ac', 'edu', 'ne', 'or', 'go'};
    final take = secondLevel.contains(labels[labels.length - 2]) && labels.last.length == 2 ? 3 : 2;
    return labels.sublist(labels.length - take).join('.');
  }

  static int _expirySeconds(int? raw) {
    if (raw == null || raw <= 0) return 0;
    // Android reports milliseconds, WebView2 seconds.
    return raw > 100000000000 ? raw ~/ 1000 : raw;
  }

  /// Writes the browser's cookies for [urls] in the Netscape format yt-dlp
  /// reads. Returns the file path, or `null` when there are no cookies.
  static Future<String?> exportCookies(List<String> urls, Directory dir) async {
    final lines = <String>{};
    for (final u in urls) {
      final uri = Uri.tryParse(u);
      if (uri == null || uri.host.isEmpty) continue;
      for (final c in await cookiesFor(u)) {
        final known = c.domain != null && c.domain!.isNotEmpty;
        // Older Android web views don't report the domain: share the cookie
        // with the whole site so yt-dlp sends it wherever the browser would.
        final domain = known ? c.domain! : '.${baseDomain(uri.host)}';
        final sub = domain.startsWith('.') ? 'TRUE' : 'FALSE';
        final path = (c.path == null || c.path!.isEmpty) ? '/' : c.path!;
        final secure = (c.isSecure ?? false) ? 'TRUE' : 'FALSE';
        final prefix = (c.isHttpOnly ?? false) ? '#HttpOnly_' : '';
        final value = '${c.value}'.replaceAll(RegExp(r'[\r\n\t]'), '');
        lines.add(['$prefix$domain', sub, path, secure, '${_expirySeconds(c.expiresDate)}', c.name, value].join('\t'));
      }
    }
    if (lines.isEmpty) return null;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cleanOldCookieFiles(dir);
    final file = File(p.join(dir.path, 'cookies-${DateTime.now().microsecondsSinceEpoch}.txt'));
    await file.writeAsString('# Netscape HTTP Cookie File\n${lines.join('\n')}\n');
    return file.path;
  }

  static void _cleanOldCookieFiles(Directory dir) {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 2));
      for (final f in dir.listSync().whereType<File>()) {
        if (f.statSync().modified.isBefore(cutoff)) f.deleteSync();
      }
    } catch (_) {}
  }

  /// yt-dlp arguments that hand it the browser's cookies for [url]'s site,
  /// or an empty list when the browser has none.
  static Future<List<String>> cookieArgs(String url, Directory dir) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return const [];
    final base = baseDomain(uri.host);
    final urls = {url, 'https://${uri.host}/', 'https://$base/', 'https://www.$base/'}.toList();
    final path = await exportCookies(urls, dir);
    return path == null ? const [] : ['--cookies', path];
  }

  /// Removes every cookie the browser holds for [urls].
  static Future<void> deleteCookies(List<String> urls) async {
    if (!isSupported) return;
    for (final u in urls) {
      final uri = Uri.tryParse(u);
      if (uri == null || uri.host.isEmpty) continue;
      final url = WebUri(u);
      for (final c in await cookiesFor(u)) {
        final path = (c.path == null || c.path!.isEmpty) ? '/' : c.path!;
        try {
          if (!Platform.isAndroid) {
            await cookies.deleteCookie(url: url, name: c.name, domain: c.domain, path: path);
            continue;
          }
          // Android can only expire cookies by overwriting them. Cover both the
          // host-only and the domain-wide variant when the domain is unknown.
          final domains = <String?>{
            if (c.domain != null && c.domain!.isNotEmpty) c.domain else ...[null, '.${baseDomain(uri.host)}'],
          };
          for (final d in domains) {
            if (c.name.startsWith('__Host-') && d != null) continue;
            await cookies.setCookie(
              url: url,
              name: c.name,
              value: 'deleted',
              domain: d,
              path: c.name.startsWith('__Host-') ? '/' : path,
              maxAge: -1,
              isSecure: true,
            );
          }
        } catch (_) {}
      }
    }
    await flush();
  }
}

/// YouTube page hosts that open FetchNet's YouTube view (not YouTube Music).
bool isYouTubeHost(String host) {
  final h = host.toLowerCase();
  return h == 'youtube.com' || h == 'www.youtube.com' || h == 'm.youtube.com' || h == 'youtu.be' || h == 'www.youtu.be';
}

bool isYouTubeUrl(String? url) {
  if (url == null) return false;
  final uri = Uri.tryParse(url);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && isYouTubeHost(uri.host);
}
