import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Why an install / update could not complete, after every source and retry.
class InstallException implements Exception {
  InstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One download source; [resolve] may look up a version first (e.g. Deno's
/// `release-latest.txt`), so it is evaluated only when the source is tried.
class Source {
  Source(this.name, this.resolve);

  Source.url(this.name, String url) : resolve = (() async => Uri.parse(url));

  final String name;
  final Future<Uri> Function() resolve;
}

typedef ProgressCallback = void Function(double? progress);

/// Robust file installation: mirrors, retries with resume, stall detection,
/// verification and atomic replacement.
class Installer {
  Installer._();

  static const _userAgent = 'FetchNet';
  static const _attemptsPerSource = 3;
  static const _stallTimeout = Duration(seconds: 45);

  /// Downloads from the first [sources] entry that works into [target].
  /// [validate] can reject a finished download (e.g. corrupt archive), which
  /// moves on to the next source.
  static Future<String> download(
    List<Source> sources,
    File target, {
    ProgressCallback? onProgress,
    Future<void> Function(File file)? validate,
    int minBytes = 1024,
  }) async {
    final errors = <String>[];
    for (final source in sources) {
      Uri uri;
      try {
        uri = await source.resolve();
      } catch (e) {
        errors.add('${source.name}: $e');
        continue;
      }
      for (var attempt = 1; attempt <= _attemptsPerSource; attempt++) {
        try {
          await _downloadOnce(uri, target, onProgress: onProgress, resume: attempt > 1, minBytes: minBytes);
          if (validate != null) await validate(target);
          return source.name;
        } on _NotRetryable catch (e) {
          errors.add('${source.name}: ${e.message}');
          break;
        } catch (e) {
          if (attempt == _attemptsPerSource) errors.add('${source.name}: ${_short(e)}');
          await Future<void>.delayed(Duration(seconds: attempt * attempt));
        }
      }
      _tryDelete(File('${target.path}.part'));
    }
    throw InstallException(
      'Couldn\'t download it from any source. Check your internet connection and try again.\n${errors.join('\n')}',
    );
  }

  static Future<void> _downloadOnce(
    Uri uri,
    File target, {
    ProgressCallback? onProgress,
    required bool resume,
    required int minBytes,
  }) async {
    final part = File('${target.path}.part');
    var existing = resume && part.existsSync() ? part.lengthSync() : 0;
    if (!resume) _tryDelete(part);

    final client = HttpClient()
      ..userAgent = _userAgent
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 10;
      if (existing > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      final response = await request.close().timeout(const Duration(seconds: 30));

      if (response.statusCode == 404 || response.statusCode == 410) {
        throw _NotRetryable('not found (HTTP ${response.statusCode})');
      }
      if (response.statusCode == 416) {
        // Range not satisfiable: the part file is stale; start over.
        _tryDelete(part);
        throw HttpException('restart download');
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (response.statusCode == 200) existing = 0; // server ignored the range

      final remaining = response.contentLength;
      final total = remaining > 0 ? remaining + existing : -1;
      final sink = part.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
      var received = existing;
      var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        await for (final chunk in response.timeout(_stallTimeout)) {
          sink.add(chunk);
          received += chunk.length;
          final now = DateTime.now();
          if (onProgress != null && now.difference(lastReport) > const Duration(milliseconds: 150)) {
            lastReport = now;
            onProgress(total > 0 ? received / total : null);
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (total > 0 && received != total) {
        throw HttpException('incomplete download ($received of $total bytes)');
      }
      if (received < minBytes) {
        _tryDelete(part);
        throw _NotRetryable('file is too small ($received bytes)');
      }
      onProgress?.call(1);
      _tryDelete(target);
      await part.rename(target.path);
    } finally {
      client.close(force: true);
    }
  }

  /// Extracts [archive] into [outDir]: the OS tool first (fast, low memory),
  /// then a pure-Dart fallback in a background isolate.
  static Future<void> extract(String archive, String outDir) async {
    Directory(outDir).createSync(recursive: true);
    if (await _systemExtract(archive, outDir)) return;
    await _isolateExtract(archive, outDir);
  }

  static Future<bool> _systemExtract(String archive, String outDir) async {
    final lower = archive.toLowerCase();
    final zip = lower.endsWith('.zip');
    final List<(String, List<String>)> attempts;
    if (Platform.isWindows) {
      final tar = p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'tar.exe');
      attempts = [(tar, ['-xf', archive, '-C', outDir])];
    } else if (Platform.isMacOS) {
      attempts = zip
          ? [('ditto', ['-x', '-k', archive, outDir]), ('unzip', ['-o', '-q', archive, '-d', outDir])]
          : [('tar', ['-xf', archive, '-C', outDir])];
    } else {
      attempts = zip
          ? [('unzip', ['-o', '-q', archive, '-d', outDir]), ('bsdtar', ['-xf', archive, '-C', outDir])]
          : [('tar', ['-xf', archive, '-C', outDir])];
    }
    for (final (exe, args) in attempts) {
      try {
        final r = await Process.run(exe, args).timeout(const Duration(minutes: 5));
        if (r.exitCode == 0) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Top-level-style helper: the isolate closure only captures two strings
  /// (capturing `this` of an engine is what used to break FFmpeg installs).
  static Future<void> _isolateExtract(String archive, String outDir) {
    return Isolate.run(() => extractFileToDisk(archive, outDir));
  }

  /// Finds a file named [name] anywhere under [dir].
  static File? find(Directory dir, String name) {
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is File && p.basename(e.path).toLowerCase() == name.toLowerCase()) return e;
      }
    } catch (_) {}
    return null;
  }

  /// True when [exe] runs and exits 0 with [args] (e.g. `-version`).
  static Future<bool> verify(String exe, List<String> args) async {
    try {
      await makeExecutable(exe);
      final r = await Process.run(exe, args).timeout(const Duration(seconds: 60));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> makeExecutable(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['+x', path]);
      if (Platform.isMacOS) await Process.run('xattr', ['-d', 'com.apple.quarantine', path]);
    } catch (_) {}
  }

  /// Atomically places [source] at [target]. A running target (Windows locks
  /// executables in use) is renamed aside first, so updates never fail
  /// because a download is using the old binary.
  static Future<void> place(File source, String target) async {
    final staged = File('$target.new');
    _tryDelete(staged);
    await source.copy(staged.path);
    await makeExecutable(staged.path);
    final existing = File(target);
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        if (existing.existsSync()) {
          final old = File('$target.old-${DateTime.now().millisecondsSinceEpoch}');
          try {
            existing.renameSync(old.path);
          } catch (_) {
            existing.deleteSync();
          }
          _tryDelete(old);
        }
        staged.renameSync(target);
        return;
      } catch (e) {
        if (attempt == 5) throw InstallException('Couldn\'t replace ${p.basename(target)}: ${_short(e)}');
        // Antivirus scanners briefly lock fresh executables.
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }
  }

  /// Removes leftovers of earlier replacements (`*.old-*`, `*.new`, `*.part`).
  static void cleanLeftovers(Directory dir) {
    try {
      for (final e in dir.listSync()) {
        final name = p.basename(e.path);
        if (e is File && (name.contains('.old-') || name.endsWith('.new') || name.endsWith('.part'))) _tryDelete(e);
      }
    } catch (_) {}
  }

  static void _tryDelete(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}

class _NotRetryable implements Exception {
  _NotRetryable(this.message);

  final String message;
}
