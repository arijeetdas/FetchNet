import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import 'engine.dart';
import 'gallery_android_engine.dart';
import 'gallery_desktop_engine.dart';

/// gallery-dl: images, galleries and posts. yt-dlp stays in charge of video
/// and audio; gallery-dl only adds what yt-dlp can't read (or only partly).
///
/// It is installed and kept up to date the same way as yt-dlp, without app
/// updates: the official standalone build on computers, the official Python
/// package on Android (run by the Python bundled with yt-dlp there).
abstract class GalleryDlEngine {
  GalleryDlEngine(this.prefs);

  final AppPrefs prefs;

  final ValueNotifier<EngineStatus> status =
      ValueNotifier(const EngineStatus(state: EngineState.initializing, message: 'Waiting for yt-dlp…'));

  bool get isSupported => true;

  Future<void> initialize();

  /// Runs gallery-dl with [args] to completion.
  Future<EngineResult> run(List<String> args, {String? id});

  /// Starts gallery-dl with [args], streaming its output.
  EngineRun start(String id, List<String> args);

  Future<void> cancel(String id);

  /// Updates gallery-dl. Returns a human readable result.
  Future<String> update();

  /// Daily background update, under the same "Keep engines up to date"
  /// switch as yt-dlp.
  Future<void> maybeAutoUpdate() async {
    if (!prefs.autoUpdateEngine) return;
    final last = prefs.lastGalleryUpdateCheck;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 24)) return;
    try {
      await update();
    } catch (_) {}
  }

  /// Options every run gets: no user config files (predictable output), no
  /// prompts, no colours.
  static const baseArgs = ['--config-ignore', '--no-input', '--no-colors'];

  static GalleryDlEngine create(AppPrefs prefs, YtDlpEngine ytdlp) {
    if (kIsWeb) return UnsupportedGalleryEngine(prefs, 'Not available in the web version.');
    if (Platform.isAndroid) return GalleryAndroidEngine(prefs, ytdlp);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) return GalleryDesktopEngine(prefs);
    return UnsupportedGalleryEngine(prefs, 'gallery-dl isn\'t available on this device.');
  }
}

class UnsupportedGalleryEngine extends GalleryDlEngine {
  UnsupportedGalleryEngine(super.prefs, this.reason) {
    status.value = EngineStatus(state: EngineState.unsupported, message: reason);
  }

  final String reason;

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<EngineResult> run(List<String> args, {String? id}) async =>
      EngineResult(exitCode: -1, stdout: '', stderr: reason);

  @override
  EngineRun start(String id, List<String> args) => FailedEngineRun(reason);

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<String> update() async => reason;
}

/// gallery-dl's exit status is a set of flags.
class GalleryExit {
  GalleryExit._();

  static const httpError = 4;
  static const challenge = 8;
  static const auth = 16;
  static const input = 32;
  static const unsupported = 64;

  static bool has(int code, int flag) => code > 0 && (code & flag) != 0;
}

/// The most useful error line in gallery-dl's output
/// (`[instagram][error] AuthorizationError: …`).
String extractGalleryError(String stderr) {
  final lines = stderr.split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final errors = lines.where((l) => RegExp(r'^\[[^\]]+\]\[error\]', caseSensitive: false).hasMatch(l)).toList();
  var message = errors.isNotEmpty
      ? errors.last
      : lines.lastWhere((l) => !l.startsWith('FN'), orElse: () => 'Unknown error');
  message = message.replaceFirst(RegExp(r'^(\[[^\]]+\])+\s*'), '');
  message = message.replaceFirst(RegExp(r'^[A-Za-z]+(Error|Exception|Required):\s*'), '');
  return message.trim().isEmpty ? 'Unknown error' : message.trim();
}

/// A friendlier explanation for a gallery-dl failure, or `null`.
/// [signedIn]: the failed run already carried the browser's sign-in.
String? friendlyGalleryHint(String error, {int exitCode = 1, bool signedIn = false}) {
  final e = error.toLowerCase();
  if (GalleryExit.has(exitCode, GalleryExit.unsupported) || e.contains('unsupported url')) {
    return 'gallery-dl doesn\'t know this site. Open it in Browser Mode to grab the media on the page.';
  }
  if (GalleryExit.has(exitCode, GalleryExit.auth) || isSignInError(e) || e.contains('nsfw') ||
      e.contains('authorization') || e.contains('credentials') || e.contains('401')) {
    return signedIn
        ? 'The site still refused, even with your sign-in from Browser Mode. Sign in there again, then try again.'
        : 'The site only shows this post to signed-in visitors. Open it in Browser Mode and sign in once, then try '
            'again. Or save the pictures it shows from Media found there.';
  }
  if (GalleryExit.has(exitCode, GalleryExit.challenge) || e.contains('cloudflare') || e.contains('challenge')) {
    return 'The site is checking for bots. Open it in Browser Mode once, then try again.';
  }
  if (e.contains('403') || e.contains('forbidden')) {
    return signedIn ? 'The site refused the request. Try again in a moment.' : 'The site refused the request. Signing in through Browser Mode often helps.';
  }
  if (e.contains('404') || e.contains('could not be found') || e.contains('not found')) {
    return 'The post was not found. It may have been deleted or made private.';
  }
  if (e.contains('429') || e.contains('rate limit') || e.contains('too many requests')) {
    return 'The site is limiting requests. Wait a few minutes, then try again.';
  }
  if (e.contains('getaddrinfo') || e.contains('timed out') || e.contains('connection') || e.contains('network')) {
    return 'Couldn\'t reach the site. Check your internet connection and try again.';
  }
  return null;
}

/// yt-dlp style request arguments (cookies, user agent from Browser Mode)
/// in gallery-dl's spelling. Unknown options are dropped.
List<String> galleryRequestArgs(List<String> ytdlpArgs) {
  const keep = {'--cookies', '--cookies-from-browser', '--user-agent'};
  const skipValue = {'--referer', '--extractor-args', '--add-header', '--add-headers'};
  final out = <String>[];
  for (var i = 0; i < ytdlpArgs.length; i++) {
    final a = ytdlpArgs[i];
    if (keep.contains(a) && i + 1 < ytdlpArgs.length) {
      out
        ..add(a)
        ..add(ytdlpArgs[++i]);
    } else if (skipValue.contains(a)) {
      i++;
    }
  }
  return out;
}
