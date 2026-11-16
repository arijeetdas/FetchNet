import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../engine/engine.dart';
import '../engine/gallery_engine.dart';
import '../models/gallery_models.dart';
import 'fetch_service.dart';

/// Looks up posts and galleries with gallery-dl (`gallery-dl -j`).
///
/// Like [FetchService] for yt-dlp, a lookup runs anonymously first. When the
/// site refuses it or wants a sign-in, it runs once more with the built-in
/// browser's cookies for the site (the same [CookieArgsProvider]).
class GalleryService {
  GalleryService(this.engine, this._prefs, {this.cookieArgs});

  final GalleryDlEngine engine;
  final AppPrefs _prefs;
  final CookieArgsProvider? cookieArgs;

  /// Files listed per lookup; a bigger gallery says it has more.
  static const maxFiles = 400;

  /// Posts listed for a profile / board link.
  static const maxChildren = 200;

  static Duration get _limit =>
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ? const Duration(seconds: 150) : const Duration(seconds: 90);

  final Set<String> _running = {};
  int _generation = 0;
  int _seq = 0;

  /// Settings → Images & posts, and an engine that can run here.
  bool get enabled => engine.isSupported && _prefs.galleryEnabled;

  /// What gallery-dl found at [url]. [requestArgs] are yt-dlp style (from
  /// Browser Mode); the post keeps them for its downloads.
  Future<GalleryPost> fetch(String url, {List<String> requestArgs = const []}) async {
    final generation = _generation;
    try {
      return await _fetchOnce(url, requestArgs);
    } on FetchException catch (e) {
      final provider = cookieArgs;
      if (e.cancelled || provider == null || requestArgs.contains('--cookies') || !_worthRetrying(e)) rethrow;
      final extra = await provider(url);
      if (generation != _generation) throw FetchException('Cancelled', cancelled: true);
      if (extra.isEmpty) rethrow;
      return _fetchOnce(url, [...requestArgs, ...extra]);
    }
  }

  /// Unsupported links and network trouble won't change with a sign-in.
  static bool _worthRetrying(FetchException e) {
    if (e is GalleryFetchException && GalleryExit.has(e.exitCode, GalleryExit.unsupported)) return false;
    final m = e.message.toLowerCase();
    return !(m.contains('unsupported url') ||
        m.contains('getaddrinfo') ||
        m.contains('timed out') ||
        m.contains('network is unreachable') ||
        m.contains('no media'));
  }

  Future<GalleryPost> _fetchOnce(String url, List<String> requestArgs) async {
    await _waitForEngine();
    final id = 'gdl-info-${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
    _running.add(id);
    final result = await engine
        .run([
          '-j',
          '--range', '1-$maxFiles',
          '--child-range', '1-$maxChildren',
          ...galleryRequestArgs(requestArgs),
          '--',
          url,
        ], id: id)
        .timeout(_limit, onTimeout: () {
          unawaited(engine.cancel(id));
          return const EngineResult(exitCode: EngineRun.cancelledExitCode, stdout: '', stderr: 'timeout');
        });
    final wasCancelled = !_running.remove(id);
    if (wasCancelled) throw FetchException('Cancelled', cancelled: true);
    if (result.cancelled && result.stderr == 'timeout') {
      throw GalleryFetchException('The site took too long to answer.',
          hint: 'The site is slow right now. Try again in a moment.', exitCode: 1);
    }
    if (result.cancelled) throw FetchException('Cancelled', cancelled: true);

    final signedIn = requestArgs.contains('--cookies');
    GalleryPost? post;
    try {
      post = GalleryPost.parse(result.stdout, sourceUrl: url, requestArgs: requestArgs, limit: maxFiles);
    } on FormatException {
      post = null;
    }
    if (post != null && !post.isEmpty) return post;
    // A lookup (-j) always exits with 0: its error is inside the JSON, as
    // `ErrorClass: message`. Its class tells a sign-in apart from the rest.
    final reported = GalleryPost.errorIn(result.stdout);
    final raw = reported ??
        (result.ok ? 'No images or files were found in this post.' : extractGalleryError(result.stderr));
    final message = raw.replaceFirst(RegExp(r'^[A-Za-z]+(Error|Exception|Required|Extraction):\s*'), '');
    var exitCode = result.ok ? 0 : result.exitCode;
    if (needsSignIn(raw)) exitCode |= GalleryExit.auth;
    throw GalleryFetchException(
      message,
      hint: friendlyGalleryHint(message, exitCode: exitCode, signedIn: signedIn),
      exitCode: exitCode,
    );
  }

  /// gallery-dl's way of saying the site wants a signed-in visitor:
  /// `AuthRequired`, `AuthorizationError`, `AuthenticationError`, or a
  /// redirect to the login page (Instagram, Threads).
  @visibleForTesting
  static bool needsSignIn(String error) {
    final e = error.toLowerCase();
    return RegExp(r'^auth(required|orizationerror|enticationerror)\b').hasMatch(e) ||
        e.contains('redirect to login') ||
        e.contains('/accounts/login') ||
        e.contains('login required') ||
        e.contains('authenticated cookies') ||
        e.contains('credentials required') ||
        isSignInError(e);
  }

  Future<void> _waitForEngine() async {
    unawaited(engine.initialize());
    final s = engine.status;
    if (s.value.isReady) return;
    if (s.value.state == EngineState.unsupported) {
      throw GalleryFetchException(s.value.message ?? 'gallery-dl isn\'t available here.', exitCode: -1);
    }
    final done = Completer<void>();
    void listener() {
      if ((s.value.isReady || s.value.state == EngineState.error) && !done.isCompleted) done.complete();
    }

    s.addListener(listener);
    try {
      listener();
      await done.future.timeout(const Duration(minutes: 3));
    } on TimeoutException {
      throw GalleryFetchException('gallery-dl is still being set up. Try again in a moment.', exitCode: -1);
    } finally {
      s.removeListener(listener);
    }
    if (!s.value.isReady) {
      throw GalleryFetchException(s.value.message ?? 'gallery-dl isn\'t ready.', exitCode: -1);
    }
  }

  Future<void> cancel() async {
    _generation++;
    final ids = _running.toList();
    _running.clear();
    await Future.wait(ids.map(engine.cancel));
  }

  // ───── Supported sites ─────

  Future<Set<String>?>? _hostsLoad;

  /// Whether gallery-dl has an extractor for [url]'s site (from its example
  /// URLs, cached per gallery-dl version). `null` while unknown.
  Future<bool?> supports(String url) async {
    final host = Uri.tryParse(url)?.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    if (host == null || host.isEmpty) return false;
    final hosts = await (_hostsLoad ??= _loadHosts());
    if (hosts == null) {
      _hostsLoad = null;
      return null;
    }
    return hosts.any((h) => host == h || host.endsWith('.$h'));
  }

  Future<Set<String>?> _loadHosts() async {
    final status = engine.status.value;
    if (!status.isReady) return null;
    if (status.version != null && _prefs.galleryHostsVersion == status.version && _prefs.galleryHosts.isNotEmpty) {
      return _prefs.galleryHosts.toSet();
    }
    final result = await engine.run(['--list-extractors'], id: 'gdl-extractors-${DateTime.now().microsecondsSinceEpoch}');
    if (!result.ok) return null;
    final hosts = hostsFromExtractorList(result.stdout);
    if (hosts.isEmpty) return null;
    if (status.version != null) await _prefs.setGalleryHosts(status.version!, hosts.toList()..sort());
    return hosts;
  }

  /// Site hosts from `gallery-dl --list-extractors` ("Example : https://…"
  /// lines). Placeholder labels (`https://BLOG.tumblr.com`) are dropped.
  @visibleForTesting
  static Set<String> hostsFromExtractorList(String output) {
    final hosts = <String>{};
    for (final m in RegExp(r'^Example\s*:\s*https?://([^/\s?#]+)', multiLine: true).allMatches(output)) {
      final labels = m.group(1)!.split(':').first.split('.');
      while (labels.length > 2 && RegExp(r'^[A-Z0-9_-]+$').hasMatch(labels.first) && RegExp(r'[A-Z]').hasMatch(labels.first)) {
        labels.removeAt(0);
      }
      if (labels.any((l) => RegExp(r'[A-Z]').hasMatch(l))) continue;
      final host = labels.join('.').toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
      if (host.contains('.') && !RegExp(r'^\d+(\.\d+)+$').hasMatch(host)) hosts.add(host);
    }
    // YouTube stays with yt-dlp and FetchNet's YouTube view.
    hosts.removeWhere((h) => h == 'youtube.com' || h == 'youtu.be' || h.endsWith('.youtube.com'));
    return hosts;
  }
}

/// A gallery-dl lookup failure with its exit status.
class GalleryFetchException extends FetchException {
  GalleryFetchException(super.message, {super.hint, required this.exitCode});

  final int exitCode;

  bool get unsupported => GalleryExit.has(exitCode, GalleryExit.unsupported);

  /// The site wants a signed-in visitor (Browser Mode sign-in helps).
  bool get needsSignIn => GalleryExit.has(exitCode, GalleryExit.auth);
}

/// Which failure to explain when both engines failed. yt-dlp only reads
/// video and audio, so for a post of pictures (Instagram, X, ...) its
/// "no video in this post" / "unsupported URL" says nothing about why the
/// post can't be read: gallery-dl's reason does (usually: sign in to the
/// site in Browser Mode). gallery-dl's sign-in request wins too. yt-dlp's
/// error stays when gallery-dl doesn't know the site at all.
bool galleryErrorExplainsBetter(FetchException yt, FetchException gallery) {
  if (gallery is! GalleryFetchException || gallery.unsupported) return false;
  if (gallery.needsSignIn) return true;
  final m = yt.message.toLowerCase();
  return m.contains('unsupported url') ||
      m.contains('no video') ||
      m.contains('no media') ||
      m.contains('no formats') ||
      m.contains('empty media response') ||
      m.contains('requested format is not available');
}
