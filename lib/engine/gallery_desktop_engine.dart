import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
import 'gallery_engine.dart';
import 'installer.dart';

/// gallery-dl on Windows / macOS / Linux: the official standalone build,
/// downloaded into FetchNet's `bin` folder beside yt-dlp and run as a child
/// process. A gallery-dl found on PATH is used as is.
class GalleryDesktopEngine extends GalleryDlEngine {
  GalleryDesktopEngine(super.prefs);

  late final Directory _binDir;
  String? _exePath;
  final Map<String, Process> _processes = {};
  Future<void>? _initFuture;

  /// SHA-256 the stable release publishes for the file being downloaded.
  String? _expectedSha;

  bool get _isWindows => Platform.isWindows;
  String get _exeName => _isWindows ? 'gallery-dl.exe' : 'gallery-dl';

  @override
  Future<void> initialize() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    status.value = const EngineStatus(state: EngineState.initializing, message: 'Looking for gallery-dl…');
    try {
      final support = await getApplicationSupportDirectory();
      _binDir = Directory(p.join(support.path, 'bin'));
      if (!_binDir.existsSync()) _binDir.createSync(recursive: true);
      final managed = File(p.join(_binDir.path, _exeName));
      _exePath = managed.existsSync() ? managed.path : await _which('gallery-dl');
      if (_exePath == null) {
        status.value = const EngineStatus(
          state: EngineState.installing,
          progress: 0,
          message: 'Downloading gallery-dl for images and posts (one-time setup)…',
        );
        await _download((progress) => status.value = status.value.copyWith(progress: progress));
      }
      status.value = EngineStatus(state: EngineState.ready, version: await _version());
      unawaited(maybeAutoUpdate());
    } catch (e) {
      _initFuture = null;
      status.value = EngineStatus(state: EngineState.error, message: 'Couldn\'t set up gallery-dl: ${_short(e)}');
    }
  }

  Future<String?> _which(String name) async {
    final pathEnv = Platform.environment['PATH'] ?? '';
    final dirs = [
      ...pathEnv.split(_isWindows ? ';' : ':').where((e) => e.trim().isNotEmpty),
      if (Platform.isMacOS) ...['/opt/homebrew/bin', '/usr/local/bin'],
      if (Platform.isLinux) ...['/usr/local/bin', '/usr/bin', p.join(Platform.environment['HOME'] ?? '', '.local', 'bin')],
    ];
    final names = _isWindows ? ['$name.exe'] : [name];
    for (final dir in dirs) {
      for (final n in names) {
        final f = File(p.join(dir.trim(), n));
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }

  Future<String?> _version() async {
    final r = await _rawRun(['--version']);
    final v = r.stdout.trim();
    return v.isEmpty ? null : v.split(RegExp(r'\s')).first;
  }

  // ───── Installing ─────

  Future<bool> _isArm() async {
    if (_isWindows) {
      final a = (Platform.environment['PROCESSOR_ARCHITEW6432'] ?? Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '');
      return a.toUpperCase().contains('ARM');
    }
    try {
      final r = await Process.run('uname', ['-m']);
      final m = r.stdout.toString().trim();
      return m == 'arm64' || m == 'aarch64';
    } catch (_) {
      return false;
    }
  }

  /// Stable builds come from gallery-dl's Codeberg releases (Windows x64 also
  /// runs on Windows on ARM); nightly builds from gallery-dl's own build
  /// repository on GitHub, the only source with a macOS build.
  Future<List<Source>> _sources() async {
    final arm = await _isArm();
    final stable = _isWindows
        ? 'gallery-dl.exe'
        : (Platform.isLinux && !arm)
            ? 'gallery-dl.bin'
            : null;
    final nightly = _isWindows
        ? 'gallery-dl_windows.exe'
        : Platform.isMacOS
            ? 'gallery-dl_macos'
            : (Platform.isLinux && !arm)
                ? 'gallery-dl_linux'
                : null;
    return [
      if (stable != null)
        Source('gallery-dl (stable)', () async {
          final release = await _codebergRelease();
          final url = release.assets[stable];
          if (url == null) throw InstallException('$stable is missing from the latest release');
          _expectedSha = release.sums[stable];
          return Uri.parse(url);
        }),
      if (nightly != null)
        Source('gallery-dl (nightly)', () async {
          _expectedSha = null;
          return Uri.parse('https://github.com/gdl-org/builds/releases/latest/download/$nightly');
        }),
    ];
  }

  Future<({Map<String, String> assets, Map<String, String> sums})> _codebergRelease() async {
    final json = jsonDecode(await _fetchText(Uri.parse('https://codeberg.org/api/v1/repos/mikf/gallery-dl/releases/latest')));
    final assets = <String, String>{};
    for (final a in (json is Map ? json['assets'] as List? : null) ?? const []) {
      if (a is Map && a['name'] is String && a['browser_download_url'] is String) {
        assets[a['name'] as String] = a['browser_download_url'] as String;
      }
    }
    final sums = <String, String>{};
    final sumsUrl = assets['SHA256SUMS'];
    if (sumsUrl != null) {
      try {
        for (final line in (await _fetchText(Uri.parse(sumsUrl))).split('\n')) {
          final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$').firstMatch(line.trim());
          if (m != null) sums[m.group(2)!] = m.group(1)!.toLowerCase();
        }
      } catch (_) {}
    }
    return (assets: assets, sums: sums);
  }

  /// Downloads a verified gallery-dl and installs it as the managed copy.
  Future<void> _download(void Function(double? progress) onProgress) async {
    final sources = await _sources();
    if (sources.isEmpty) {
      throw InstallException('there is no gallery-dl build for this computer. Install gallery-dl with your package manager');
    }
    final work = Directory(p.join((await getTemporaryDirectory()).path, 'fetchnet', 'gallerydl-${DateTime.now().millisecondsSinceEpoch}'))
      ..createSync(recursive: true);
    try {
      final file = File(p.join(work.path, _exeName));
      await Installer.download(
        sources,
        file,
        minBytes: 1024 * 1024,
        onProgress: onProgress,
        validate: (f) async {
          final expected = _expectedSha;
          if (expected != null) {
            final actual = (await sha256.bind(f.openRead()).first).toString();
            if (actual != expected) throw InstallException('the download doesn\'t match its published checksum');
          }
          if (!await Installer.verify(f.path, ['--version'])) {
            throw InstallException('the downloaded gallery-dl doesn\'t run');
          }
        },
      );
      final target = p.join(_binDir.path, _exeName);
      await Installer.place(file, target);
      _exePath = target;
    } finally {
      try {
        work.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Future<String> _fetchText(Uri uri) async {
    final client = HttpClient()..userAgent = 'FetchNet';
    try {
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String> update() async {
    await initialize();
    final previous = status.value;
    if (previous.state != EngineState.ready) return 'gallery-dl is busy, try again in a moment.';
    status.value = previous.copyWith(state: EngineState.updating, message: 'Updating gallery-dl…');
    try {
      final before = await _version();
      final managed = p.isWithin(_binDir.path, _exePath ?? '');
      var updated = false;
      // gallery-dl's own updater first (standalone builds only).
      if (managed) {
        try {
          final r = await _rawRun(['--update']).timeout(const Duration(minutes: 3));
          updated = r.ok && await Installer.verify(_exePath!, ['--version']);
        } catch (_) {}
      }
      if (!updated) {
        await _download((progress) {
          status.value = status.value.copyWith(progress: progress, message: 'Downloading the latest gallery-dl…');
        });
      }
      final after = await _version();
      await prefs.markGalleryUpdateChecked();
      status.value = previous.copyWith(state: EngineState.ready, version: after, clearMessage: true, clearProgress: true);
      if (after != null && after == before) return 'gallery-dl is already up to date ($after).';
      return 'gallery-dl updated to ${after ?? 'the latest version'}.';
    } catch (e) {
      status.value = previous.copyWith(state: EngineState.ready, clearMessage: true, clearProgress: true);
      return 'Update failed: ${_short(e)}';
    }
  }

  // ───── Running ─────

  Map<String, String> get _env => {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'};

  Future<EngineResult> _rawRun(List<String> args) async {
    final exe = _exePath;
    if (exe == null) return const EngineResult(exitCode: -1, stdout: '', stderr: 'gallery-dl is not installed.');
    final r = await Process.run(
      exe,
      args,
      environment: _env,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    return EngineResult(exitCode: r.exitCode, stdout: r.stdout.toString(), stderr: r.stderr.toString());
  }

  @override
  Future<EngineResult> run(List<String> args, {String? id}) =>
      _start(id ?? 'gdl-${DateTime.now().microsecondsSinceEpoch}', args, collectStdout: true).done;

  @override
  EngineRun start(String id, List<String> args) => _start(id, args, collectStdout: false);

  _GalleryRun _start(String id, List<String> args, {required bool collectStdout}) {
    final run = _GalleryRun(() => cancel(id));
    () async {
      await initialize();
      final exe = _exePath;
      if (exe == null || status.value.state == EngineState.error) {
        run._finish(EngineResult(exitCode: -1, stdout: '', stderr: status.value.message ?? 'gallery-dl is not installed.'));
        return;
      }
      try {
        final process = await Process.start(exe, [...GalleryDlEngine.baseArgs, ...args], environment: _env);
        _processes[id] = process;
        final out = StringBuffer();
        final err = StringBuffer();
        final outDone = process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen((line) {
          if (collectStdout) out.writeln(line);
          run._lines.add(line);
        }).asFuture<void>();
        final errDone = process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen((line) {
          err.writeln(line);
          run._lines.add(line);
        }).asFuture<void>();
        final code = await process.exitCode;
        await Future.wait([outDone, errDone]).catchError((_) => <void>[]);
        _processes.remove(id);
        run._finish(EngineResult(
          exitCode: run._cancelled ? EngineRun.cancelledExitCode : code,
          stdout: out.toString(),
          stderr: err.toString(),
        ));
      } catch (e) {
        _processes.remove(id);
        run._finish(EngineResult(exitCode: -1, stdout: '', stderr: _short(e)));
      }
    }();
    return run;
  }

  @override
  Future<void> cancel(String id) async {
    final process = _processes[id];
    if (process == null) return;
    if (_isWindows) {
      // gallery-dl may hand videos to yt-dlp / FFmpeg: end the whole tree.
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill(ProcessSignal.sigterm);
    }
  }

  String _short(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}

class _GalleryRun extends EngineRun {
  _GalleryRun(this._cancel);

  final Future<void> Function() _cancel;
  final StreamController<String> _lines = StreamController.broadcast();
  final Completer<EngineResult> _done = Completer();
  bool _cancelled = false;

  void _finish(EngineResult result) {
    if (_done.isCompleted) return;
    _done.complete(result);
    _lines.close();
  }

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<EngineResult> get done => _done.future;

  @override
  Future<void> cancel() {
    _cancelled = true;
    return _cancel();
  }
}
