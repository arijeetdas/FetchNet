import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import 'android_engine.dart';
import 'desktop_engine.dart';

enum EngineState { initializing, installing, updating, ready, error, unsupported }

@immutable
class EngineStatus {
  const EngineStatus({
    required this.state,
    this.version,
    this.progress,
    this.message,
    this.ffmpegAvailable = false,
    this.jsRuntime,
  });

  final EngineState state;

  /// yt-dlp version, e.g. `2026.10.22`.
  final String? version;

  /// 0..1 while installing / updating, when known.
  final double? progress;
  final String? message;

  /// Whether FFmpeg is available (merging HD formats, audio conversion).
  final bool ffmpegAvailable;

  /// JavaScript runtime used for sites like YouTube (`quickjs`, `deno`, `node`).
  final String? jsRuntime;

  bool get isReady => state == EngineState.ready || state == EngineState.updating;

  EngineStatus copyWith({
    EngineState? state,
    String? version,
    double? progress,
    bool clearProgress = false,
    String? message,
    bool clearMessage = false,
    bool? ffmpegAvailable,
    String? jsRuntime,
  }) {
    return EngineStatus(
      state: state ?? this.state,
      version: version ?? this.version,
      progress: clearProgress ? null : (progress ?? this.progress),
      message: clearMessage ? null : (message ?? this.message),
      ffmpegAvailable: ffmpegAvailable ?? this.ffmpegAvailable,
      jsRuntime: jsRuntime ?? this.jsRuntime,
    );
  }
}

/// Output of one yt-dlp run.
@immutable
class EngineResult {
  const EngineResult({required this.exitCode, required this.stdout, required this.stderr});

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get cancelled => exitCode == EngineRun.cancelledExitCode;
  bool get ok => exitCode == 0;
}

/// A streaming yt-dlp run (downloads).
abstract class EngineRun {
  static const cancelledExitCode = -2;

  /// Every stdout line as it is printed.
  Stream<String> get lines;

  /// Completes when yt-dlp exits.
  Future<EngineResult> get done;

  Future<void> cancel();
}

/// Optional add-ons a desktop install can download.
enum EngineComponent { ffmpeg, jsRuntime }

/// Runs yt-dlp on the current platform.
abstract class YtDlpEngine {
  YtDlpEngine(this.prefs);

  final AppPrefs prefs;

  final ValueNotifier<EngineStatus> status =
      ValueNotifier(const EngineStatus(state: EngineState.initializing));

  /// Progress of a component install (desktop only), `null` when idle.
  final ValueNotifier<({EngineComponent component, double? progress, String label})?> componentInstall =
      ValueNotifier(null);

  bool get isSupported => true;

  /// Whether this platform can install [EngineComponent]s on demand.
  bool get canInstallComponents => false;

  Future<void> initialize();

  /// Runs yt-dlp with [args] to completion.
  Future<EngineResult> run(List<String> args, {String? id});

  /// Starts yt-dlp with [args], streaming its output.
  EngineRun start(String id, List<String> args);

  /// Cancels a run started with [id] (via [run] or [start]).
  Future<void> cancel(String id);

  /// Updates yt-dlp. Returns a human readable result.
  Future<String> update();

  Future<void> installComponent(EngineComponent component) async {}

  /// Updates in the background when the user allows it and the last check is
  /// more than a day old.
  Future<void> maybeAutoUpdate() async {
    if (!prefs.autoUpdateEngine) return;
    final last = prefs.lastEngineUpdateCheck;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 24)) return;
    try {
      await update();
    } catch (_) {}
  }

  static YtDlpEngine create(AppPrefs prefs) {
    if (kIsWeb) return UnsupportedEngine(prefs, 'Downloading isn\'t available in the web version.');
    if (Platform.isAndroid) return AndroidEngine(prefs);
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) return DesktopEngine(prefs);
    return UnsupportedEngine(
      prefs,
      'iOS doesn\'t allow apps to run the yt-dlp engine, so downloading isn\'t available on this device.',
    );
  }
}

class UnsupportedEngine extends YtDlpEngine {
  UnsupportedEngine(super.prefs, this.reason) {
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
  EngineRun start(String id, List<String> args) => _FailedRun(reason);

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<String> update() async => reason;
}

class _FailedRun extends EngineRun {
  _FailedRun(this.reason);
  final String reason;

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Future<EngineResult> get done async => EngineResult(exitCode: -1, stdout: '', stderr: reason);

  @override
  Future<void> cancel() async {}
}

/// Pulls the most useful error text out of yt-dlp's stderr.
String extractEngineError(String stderr) {
  final lines = stderr.split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final errors = lines.where((l) => l.startsWith('ERROR:')).toList();
  var message = errors.isNotEmpty ? errors.last : (lines.isNotEmpty ? lines.last : 'Unknown error');
  message = message.replaceFirst(RegExp(r'^ERROR:\s*'), '');
  message = message.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '');
  // Drop "[youtube] abc123: " style prefixes.
  message = message.replaceFirst(RegExp(r'^[\w-]{6,}:\s+'), '');
  return message;
}

/// A friendlier explanation for common yt-dlp failures, or `null`.
String? friendlyEngineHint(String error) {
  final e = error.toLowerCase();
  if (e.contains('unsupported url')) {
    return 'This site isn\'t supported directly. Open it in Browser Mode so FetchNet can find the media on the page.';
  }
  if (e.contains('sign in') || e.contains('login') || e.contains('log in') || e.contains('cookies') ||
      e.contains('confirm you') || e.contains('age')) {
    return 'This video needs you to be signed in. Open it in Browser Mode, sign in, then grab it from there.';
  }
  if (e.contains('private')) return 'This video is private.';
  if (e.contains('403') || e.contains('forbidden')) {
    return 'The site refused the request. Browser Mode often works around this.';
  }
  if (e.contains('unable to download webpage') || e.contains('getaddrinfo') || e.contains('timed out') ||
      e.contains('network is unreachable')) {
    return 'Couldn\'t reach the site. Check your internet connection and try again.';
  }
  if (e.contains('no video formats') || e.contains('no media')) {
    return 'No downloadable media was found. Try Browser Mode and play the video there.';
  }
  return null;
}
