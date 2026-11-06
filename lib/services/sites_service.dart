import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_prefs.dart';
import '../core/format.dart';
import '../engine/engine.dart';
import 'web_session.dart';

/// The four sites every FetchNet install starts with.
enum SiteBrand { youtube, instagram, facebook, x }

/// A shortcut on the Home screen's Sites panel.
class Site {
  const Site({required this.key, required this.name, required this.url, this.iconPath, this.brand});

  /// Registrable domain, e.g. `dailymotion.com`. Unique per list.
  final String key;
  final String name;
  final String url;

  /// Icon saved in the app's support folder (user-added sites).
  final String? iconPath;

  /// Set for the built-in sites, which can't be edited, moved or removed.
  final SiteBrand? brand;

  bool get isFixed => brand != null;

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'url': url,
        if (iconPath != null) 'iconPath': iconPath,
      };

  static Site? fromJson(Map<String, dynamic> j) {
    final key = j['key'];
    final name = j['name'];
    final url = j['url'];
    if (key is! String || name is! String || url is! String) return null;
    return Site(key: key, name: name, url: url, iconPath: j['iconPath'] as String?);
  }
}

enum PinOutcome { added, alreadyPinned, unsupported, invalid, engineNotReady }

class PinResult {
  const PinResult(this.outcome, {this.site});

  final PinOutcome outcome;
  final Site? site;

  String get message => switch (outcome) {
        PinOutcome.added => '${site?.name ?? 'Site'} added to your sites',
        PinOutcome.alreadyPinned => '${site?.name ?? 'This site'} is already in your sites',
        PinOutcome.unsupported => 'Platform not supported by yt-dlp',
        PinOutcome.invalid => 'That doesn\'t look like a website address',
        PinOutcome.engineNotReady => 'yt-dlp is still getting ready. Try again in a moment.',
      };
}

class SitesService extends ChangeNotifier {
  SitesService(this._prefs, this._engine) {
    for (final raw in _prefs.sitesJson) {
      try {
        final site = Site.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
        if (site != null && !_isFixedKey(site.key)) _custom.add(site);
      } catch (_) {}
    }
  }

  final AppPrefs _prefs;
  final YtDlpEngine _engine;
  final List<Site> _custom = [];
  Set<String>? _extractorCache;
  Future<Set<String>?>? _extractorLoad;

  static const fixed = [
    Site(key: 'youtube.com', name: 'YouTube', url: 'https://www.youtube.com/', brand: SiteBrand.youtube),
    Site(key: 'instagram.com', name: 'Instagram', url: 'https://www.instagram.com/', brand: SiteBrand.instagram),
    Site(key: 'facebook.com', name: 'Facebook', url: 'https://www.facebook.com/', brand: SiteBrand.facebook),
    Site(key: 'x.com', name: 'X', url: 'https://x.com/', brand: SiteBrand.x),
  ];

  /// Other domains of the built-in sites.
  static const _fixedAliases = {
    'youtu.be': 'youtube.com',
    'twitter.com': 'x.com',
    'fb.com': 'facebook.com',
    'fb.watch': 'facebook.com',
    'instagr.am': 'instagram.com',
  };

  /// Domains whose yt-dlp extractor goes by another name.
  static const _extractorAliases = {
    'x.com': 'twitter',
    'youtu.be': 'youtube',
    'fb.watch': 'facebook',
    'fb.com': 'facebook',
    'ok.ru': 'odnoklassniki',
    'redd.it': 'reddit',
    'vk.ru': 'vk',
    'vkvideo.ru': 'vk',
    'b23.tv': 'bilibili',
    't.me': 'telegram',
  };

  List<Site> get custom => List.unmodifiable(_custom);
  List<Site> get all => [...fixed, ..._custom];

  static bool _isFixedKey(String key) => fixed.any((s) => s.key == key) || _fixedAliases.containsKey(key);

  static Site? _fixedFor(String key) {
    final k = _fixedAliases[key] ?? key;
    return fixed.where((s) => s.key == k).firstOrNull;
  }

  /// Checks [input] (an address or link) against yt-dlp and adds it.
  Future<PinResult> pin(String input) async {
    final link = extractUrl(input.trim());
    final uri = link == null ? null : Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty || !uri.host.contains('.') || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const PinResult(PinOutcome.invalid);
    }
    final host = uri.host.toLowerCase();
    final key = WebSession.baseDomain(host);
    final builtIn = _fixedFor(key) ?? _fixedFor(host);
    if (builtIn != null) return PinResult(PinOutcome.alreadyPinned, site: builtIn);
    final existing = _custom.where((s) => s.key == key).firstOrNull;
    if (existing != null) return PinResult(PinOutcome.alreadyPinned, site: existing);

    final extractors = await _extractors();
    if (extractors == null) return const PinResult(PinOutcome.engineNotReady);
    if (!isSupportedBy(host, extractors)) return const PinResult(PinOutcome.unsupported);

    final siteUri = Uri(scheme: 'https', host: host, path: '/');
    final meta = await _fetchMeta(siteUri, key);
    final site = Site(key: key, name: meta.name, url: siteUri.toString(), iconPath: meta.iconPath);
    _custom.add(site);
    await _save();
    notifyListeners();
    return PinResult(PinOutcome.added, site: site);
  }

  Future<void> remove(Site site) async {
    _custom.removeWhere((s) => s.key == site.key);
    final icon = site.iconPath;
    if (icon != null) {
      try {
        final f = File(icon);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    await _save();
    notifyListeners();
  }

  /// Moves a user-added site within the user-added part of the list.
  Future<void> move(int from, int to) async {
    if (from < 0 || from >= _custom.length) return;
    final site = _custom.removeAt(from);
    _custom.insert(to.clamp(0, _custom.length), site);
    await _save();
    notifyListeners();
  }

  Future<void> _save() => _prefs.setSitesJson([for (final s in _custom) jsonEncode(s.toJson())]);

  // ───── yt-dlp support ─────

  Future<Set<String>?> _extractors() {
    final cached = _extractorCache;
    if (cached != null) return Future.value(cached);
    return _extractorLoad ??= _loadExtractors().whenComplete(() => _extractorLoad = null);
  }

  Future<Set<String>?> _loadExtractors() async {
    if (!_engine.isSupported) return null;
    if (!_engine.status.value.isReady) await _waitForEngine();
    final status = _engine.status.value;
    final stored = _prefs.extractors;
    if (status.version != null && _prefs.extractorsVersion == status.version && stored.isNotEmpty) {
      return _extractorCache = stored.toSet();
    }
    if (!status.isReady) return stored.isEmpty ? null : stored.toSet();
    final result = await _engine.run(['--list-extractors'], id: 'extractors-${DateTime.now().microsecondsSinceEpoch}');
    if (!result.ok) return stored.isEmpty ? null : stored.toSet();
    final names = result.stdout
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('[') && !e.contains('CURRENTLY BROKEN'))
        .toList();
    if (names.isEmpty) return stored.isEmpty ? null : stored.toSet();
    await _prefs.setExtractors(status.version ?? 'unknown', names);
    return _extractorCache = names.toSet();
  }

  Future<void> _waitForEngine() async {
    final ready = Completer<void>();
    void listener() {
      final s = _engine.status.value;
      if ((s.isReady || s.state == EngineState.error) && !ready.isCompleted) ready.complete();
    }

    _engine.status.addListener(listener);
    listener();
    await ready.future.timeout(const Duration(seconds: 30), onTimeout: () {});
    _engine.status.removeListener(listener);
  }

  /// Whether one of yt-dlp's extractors is named after [host]'s site.
  @visibleForTesting
  static bool isSupportedBy(String host, Set<String> extractors) {
    final base = WebSession.baseDomain(host);
    final key = (_extractorAliases[base] ?? _extractorAliases[host] ?? base.split('.').first)
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (key.isEmpty) return false;
    for (final raw in extractors) {
      final lower = raw.toLowerCase();
      if (lower == 'generic') continue;
      if (lower.contains(base)) return true;
      final name = lower.split(':').first.replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (name == key) return true;
      if (key.length >= 4 && name.startsWith(key)) return true;
    }
    return false;
  }

  // ───── Name & icon ─────

  Future<({String name, String? iconPath})> _fetchMeta(Uri site, String key) async {
    final label = key.split('.').first;
    final fallbackName = label.isEmpty ? key : label[0].toUpperCase() + label.substring(1);
    final http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = WebSession.desktopUserAgent;
    try {
      String? html;
      Uri base = site;
      try {
        final res = await _request(http, site);
        base = res.redirects.isNotEmpty ? site.resolveUri(res.redirects.last.location) : site;
        html = await _readText(res, maxBytes: 600 * 1024);
      } catch (_) {}

      final name = (html == null ? null : siteNameFromHtml(html, label)) ?? fallbackName;
      final candidates = <Uri>[
        if (html != null) ...iconsFromHtml(html).map(base.resolve),
        Uri.parse('https://www.google.com/s2/favicons?domain=${site.host}&sz=128'),
        site.resolve('/favicon.ico'),
      ];
      String? iconPath;
      for (final c in candidates) {
        iconPath = await _saveIcon(http, c, key);
        if (iconPath != null) break;
      }
      return (name: name, iconPath: iconPath);
    } finally {
      http.close(force: true);
    }
  }

  static Future<HttpClientResponse> _request(HttpClient http, Uri uri) async {
    final req = await http.getUrl(uri);
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    return req.close().timeout(const Duration(seconds: 12));
  }

  static Future<String> _readText(HttpClientResponse res, {required int maxBytes}) async {
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 12))) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) break;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<String?> _saveIcon(HttpClient http, Uri uri, String key) async {
    try {
      final res = await _request(http, uri);
      final type = res.headers.contentType?.mimeType ?? '';
      if (res.statusCode != 200 || (type.isNotEmpty && !type.startsWith('image/')) || type.contains('svg')) {
        await res.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 12))) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) return null;
      }
      if (bytes.length < 64) return null;
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'site_icons'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = switch (type) {
        'image/png' => 'png',
        'image/jpeg' => 'jpg',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        _ => uri.path.toLowerCase().endsWith('.ico') || type.contains('icon') ? 'ico' : 'png',
      };
      final file = File(p.join(dir.path, '${key.replaceAll(RegExp(r'[^a-z0-9.-]'), '_')}.$ext'));
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  static final _tagAttr = RegExp(r'''([\w:-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))''');

  static Map<String, String> _attrs(String tag) => {
        for (final m in _tagAttr.allMatches(tag)) m.group(1)!.toLowerCase(): m.group(3) ?? m.group(4) ?? m.group(5) ?? '',
      };

  static String _decode(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .trim();

  @visibleForTesting
  static String? siteNameFromHtml(String html, String label) {
    for (final m in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(html)) {
      final a = _attrs(m.group(0)!);
      final prop = (a['property'] ?? a['name'] ?? '').toLowerCase();
      if (prop == 'og:site_name' || prop == 'application-name' || prop == 'apple-mobile-web-app-title') {
        final v = _decode(a['content'] ?? '');
        if (v.isNotEmpty && v.length <= 32) return v;
      }
    }
    final t = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html)?.group(1);
    if (t == null) return null;
    final title = _decode(t.replaceAll(RegExp(r'\s+'), ' '));
    if (title.isEmpty) return null;
    final parts = title.split(RegExp(r'\s+[|\-–—·:]\s+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final named = parts.where((e) => e.toLowerCase().replaceAll(' ', '').contains(label.toLowerCase())).toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    final pick = named.isNotEmpty ? named.first : parts.first;
    return pick.length <= 32 ? pick : null;
  }

  /// Icon links from a page, sharpest first. SVG icons are skipped.
  @visibleForTesting
  static List<String> iconsFromHtml(String html) {
    final out = <(int, String)>[];
    for (final m in RegExp(r'<link\b[^>]*>', caseSensitive: false).allMatches(html)) {
      final a = _attrs(m.group(0)!);
      final rel = (a['rel'] ?? '').toLowerCase();
      final href = _decode(a['href'] ?? '');
      if (href.isEmpty || href.toLowerCase().contains('.svg') || (a['type'] ?? '').contains('svg')) continue;
      final size = int.tryParse(RegExp(r'(\d+)x\d+').firstMatch(a['sizes'] ?? '')?.group(1) ?? '') ?? 0;
      if (rel.contains('apple-touch-icon')) {
        out.add((1000 + size, href));
      } else if (rel.split(RegExp(r'\s+')).contains('icon') && size >= 64) {
        out.add((size, href));
      }
    }
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return [for (final e in out) e.$2];
  }
}
