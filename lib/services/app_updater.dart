import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/platform/device_environment.dart';
import 'update_service.dart';
import 'windows_self_update.dart';

enum UpdaterPhase {
  /// Nothing started yet.
  idle,

  /// Downloading the update ([AppUpdater.progress]).
  downloading,

  /// Unzipping and putting the new files in place (Windows), or handing the
  /// APK to Android's installer.
  installing,

  /// Android: FetchNet may not install apps yet ("Install unknown apps").
  needsPermission,

  /// Android: the system installer is open, waiting for the user.
  waitingForUser,

  /// Desktop: the new version is in place (or its installer is ready); a
  /// relaunch finishes the update.
  readyToRelaunch,

  /// Something failed: the update page on the website is the way out.
  failed,
}

/// Downloads and installs FetchNet updates from the links on the website.
///
/// Android: the APK goes to Android's package installer. Windows: the zip is
/// unzipped over the installed copy while FetchNet runs, then Relaunch (like
/// Chrome); an install the app can't write to (Program Files) runs the
/// installer instead. Whatever fails, [UpdaterPhase.failed] offers the
/// website's update page, as before.
class AppUpdater extends ChangeNotifier {
  AppUpdater(this.updates);

  final UpdateService updates;

  static const _channel = MethodChannel('fetchnet/updater');
  static const _events = EventChannel('fetchnet/updater/events');

  UpdaterPhase _phase = UpdaterPhase.idle;
  double? _progress;
  int? _received;
  int? _total;
  double? _speed;
  String? _message;
  String? _file;
  bool _cancelled = false;
  HttpClient? _http;
  StreamSubscription<dynamic>? _installEvents;
  AppLifecycleListener? _resumeListener;
  WindowsUpdatePlan? _windowsPlan;

  UpdaterPhase get phase => _phase;
  double? get progress => _progress;
  int? get receivedBytes => _received;
  int? get totalBytes => _total;

  /// Bytes per second.
  double? get speed => _speed;

  /// What went wrong ([UpdaterPhase.failed]) or what's happening.
  String? get message => _message;

  bool get busy =>
      _phase == UpdaterPhase.downloading || _phase == UpdaterPhase.installing || _phase == UpdaterPhase.waitingForUser;

  /// Desktop: the relaunch runs the installer (not the swapped files).
  bool get relaunchRunsInstaller => _windowsPlan?.useInstaller ?? false;

  /// Whether this platform can update in the app (others use the website).
  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  void _set(UpdaterPhase phase, {String? message}) {
    _phase = phase;
    _message = message;
    notifyListeners();
  }

  /// Puts the updater in [phase] (tests).
  @visibleForTesting
  void debugSet(UpdaterPhase phase, {String? message, double? progress, int? received, int? total, double? speed}) {
    _progress = progress;
    _received = received;
    _total = total;
    _speed = speed;
    _set(phase, message: message);
  }

  /// Back to the start (after a failure, to try again).
  void reset() {
    if (busy) return;
    _progress = _received = _total = null;
    _speed = null;
    _set(UpdaterPhase.idle);
  }

  /// Downloads the latest release and installs it.
  Future<void> start() async {
    if (busy || _phase == UpdaterPhase.readyToRelaunch) return;
    final update = updates.update;
    if (!supported || update == null) {
      _set(UpdaterPhase.failed, message: 'This update can only be downloaded from the website.');
      return;
    }
    _cancelled = false;
    try {
      final String key;
      if (Platform.isAndroid) {
        await DeviceEnvironment.ensureLoaded();
        key = UpdateService.androidDownloadKey(
          installedType: DeviceEnvironment.installedApkType,
          abis: DeviceEnvironment.supportedAbis,
          available: update.downloads.keys,
        );
      } else {
        _windowsPlan = await WindowsSelfUpdate.plan(update);
        key = _windowsPlan!.downloadKey;
      }
      final url = update.downloads[key];
      if (url == null) {
        _set(UpdaterPhase.failed, message: 'This update isn\'t available to download in the app yet.');
        return;
      }
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'updates', '${update.release.buildNumber}'))
        ..createSync(recursive: true);
      final name = _fileName(url, fallback: 'FetchNet-${update.release.versionName}-$key');
      final file = File(p.join(dir.path, name));
      _set(UpdaterPhase.downloading);
      await _download(url, file);
      if (_cancelled) return;
      _checkKind(file, name);
      _file = file.path;

      if (Platform.isAndroid) {
        await _installAndroid();
      } else {
        _set(UpdaterPhase.installing, message: _windowsPlan!.useInstaller ? null : 'Putting the new version in place…');
        if (!_windowsPlan!.useInstaller) {
          await WindowsSelfUpdate.applyZip(file.path, update.release);
        }
        _set(UpdaterPhase.readyToRelaunch);
      }
    } on _Cancelled {
      _set(UpdaterPhase.idle);
    } catch (e) {
      if (_cancelled) {
        _set(UpdaterPhase.idle);
        return;
      }
      _set(UpdaterPhase.failed, message: _describe(e));
    }
  }

  /// Stops a download in progress.
  void cancel() {
    if (_phase != UpdaterPhase.downloading) return;
    _cancelled = true;
    _http?.close(force: true);
    _set(UpdaterPhase.idle);
  }

  /// Desktop: starts the new version (or the installer) and closes this one.
  Future<void> relaunch() async {
    if (_phase != UpdaterPhase.readyToRelaunch) return;
    try {
      if (_windowsPlan?.useInstaller ?? false) {
        await WindowsSelfUpdate.runInstaller(_file!);
      } else {
        await WindowsSelfUpdate.relaunch();
      }
    } catch (e) {
      _set(UpdaterPhase.failed, message: _describe(e));
    }
  }

  /// Deletes downloaded updates of builds up to [installedBuild] (they are
  /// installed by now, or were superseded).
  static Future<void> cleanOldDownloads(int? installedBuild) async {
    if (kIsWeb || installedBuild == null) return;
    try {
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'updates'));
      if (!dir.existsSync()) return;
      for (final e in dir.listSync()) {
        final build = int.tryParse(p.basename(e.path));
        if (e is Directory && build != null && build <= installedBuild) e.deleteSync(recursive: true);
      }
    } catch (_) {}
  }

  // ───── Download ─────

  static String _fileName(String url, {required String fallback}) {
    final last = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    final name = last == null ? '' : Uri.decodeComponent(last).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return name.contains('.') ? name : fallback;
  }

  /// Downloads [url] into [target], resuming a partial download from an
  /// earlier attempt (Dropbox serves ranges).
  Future<void> _download(String url, File target) async {
    final part = File('${target.path}.part');
    if (target.existsSync()) {
      // Already downloaded by an earlier attempt.
      _received = _total = target.lengthSync();
      _progress = 1;
      notifyListeners();
      return;
    }
    for (var attempt = 1; ; attempt++) {
      if (_cancelled) throw _Cancelled();
      final http = _http = HttpClient()
        ..userAgent = 'FetchNet'
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 15);
      try {
        var existing = part.existsSync() ? part.lengthSync() : 0;
        final req = await http.getUrl(Uri.parse(url));
        req.followRedirects = true;
        req.maxRedirects = 10;
        if (existing > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.statusCode == 416) {
          part.deleteSync();
          throw const HttpException('restart');
        }
        if (res.statusCode != 200 && res.statusCode != 206) {
          throw HttpException('the download link answered with error ${res.statusCode}');
        }
        if (res.statusCode == 200) existing = 0;
        final total = res.contentLength > 0 ? res.contentLength + existing : null;
        _total = total;
        final sink = part.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
        var received = existing;
        var windowStart = DateTime.now();
        var windowBytes = 0;
        try {
          await for (final chunk in res.timeout(const Duration(seconds: 45))) {
            sink.add(chunk);
            received += chunk.length;
            windowBytes += chunk.length;
            final now = DateTime.now();
            final ms = now.difference(windowStart).inMilliseconds;
            if (ms >= 400) {
              _speed = windowBytes * 1000 / ms;
              windowStart = now;
              windowBytes = 0;
              _received = received;
              _progress = total == null ? null : (received / total).clamp(0, 1).toDouble();
              notifyListeners();
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (_cancelled) throw _Cancelled();
        if (total != null && received != total) throw HttpException('the download stopped at $received of $total bytes');
        part.renameSync(target.path);
        _received = received;
        _progress = 1;
        notifyListeners();
        return;
      } catch (e) {
        if (_cancelled || e is _Cancelled) throw _Cancelled();
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      } finally {
        http.close(force: true);
        _http = null;
      }
    }
  }

  /// A dead link often answers with a web page: make sure the file is the
  /// package it should be (an APK / zip starts with "PK", an .exe with "MZ").
  static void _checkKind(File file, String name) {
    final raf = file.openSync();
    try {
      final head = raf.readSync(2);
      final lower = name.toLowerCase();
      final ok = lower.endsWith('.exe') ? (head.length == 2 && head[0] == 0x4D && head[1] == 0x5A) : (head.length == 2 && head[0] == 0x50 && head[1] == 0x4B);
      if (!ok) {
        file.deleteSync();
        throw const FormatException('the download link didn\'t return the update file');
      }
    } finally {
      raf.closeSync();
    }
  }

  // ───── Android ─────

  Future<void> _installAndroid() async {
    _installEvents ??= _events.receiveBroadcastStream().listen(_onInstallEvent, onError: (_) {});
    _set(UpdaterPhase.installing, message: 'Opening Android\'s installer…');
    final result = await _channel.invokeMapMethod<String, dynamic>('install', {'path': _file});
    switch (result?['status']) {
      case 'needs_permission':
        _set(UpdaterPhase.needsPermission);
      case 'started':
        break; // Events report the rest.
      default:
        _set(UpdaterPhase.failed, message: result?['message']?.toString() ?? 'Android couldn\'t start the installer.');
    }
  }

  void _onInstallEvent(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['status']) {
      case 'pending_user':
        _set(UpdaterPhase.waitingForUser);
      case 'success':
        // Android replaces the app: this process ends right after.
        _set(UpdaterPhase.installing, message: 'Installing…');
      case 'failure':
        _set(UpdaterPhase.failed, message: raw['message']?.toString() ?? 'The update wasn\'t installed.');
      case 'cancelled':
        _set(UpdaterPhase.idle, message: 'The installation was cancelled.');
    }
  }

  /// Opens Android's "Install unknown apps" page for FetchNet; coming back
  /// to the app retries the install.
  Future<void> allowInstalls() async {
    _resumeListener?.dispose();
    _resumeListener = AppLifecycleListener(onResume: () async {
      _resumeListener?.dispose();
      _resumeListener = null;
      if (_phase == UpdaterPhase.needsPermission && _file != null) await _installAndroid();
    });
    try {
      await _channel.invokeMethod('openInstallPermission');
    } catch (_) {
      _set(UpdaterPhase.failed, message: 'Couldn\'t open Android\'s settings.');
    }
  }

  static String _describe(Object e) {
    final s = switch (e) {
      HttpException(:final message) => message,
      FormatException(:final message) => message,
      FileSystemException(:final message, :final osError) => osError == null ? message : '$message (${osError.message})',
      PlatformException(:final message, :final code) => message ?? code,
      _ => '$e',
    };
    final text = s.length > 160 ? '${s.substring(0, 160)}…' : s;
    return 'The update couldn\'t be installed: $text.';
  }

  @override
  void dispose() {
    _installEvents?.cancel();
    _resumeListener?.dispose();
    _http?.close(force: true);
    super.dispose();
  }
}

class _Cancelled implements Exception {}
