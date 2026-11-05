import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
import 'installer.dart';

/// yt-dlp on Windows / macOS / Linux: the official standalone binary,
/// downloaded on first launch (keeps the installer small) and run as a
/// child process. FFmpeg and a JavaScript runtime are optional add-ons.
class DesktopEngine extends YtDlpEngine {
  DesktopEngine(super.prefs);

  late final Directory _binDir;
  String? _ytdlp;
  String? _ffmpegDir;
  ({String name, String path})? _js;
  final Map<String, Process> _processes = {};
  Future<void>? _initFuture;

  bool get _isWindows => Platform.isWindows;
  String _exe(String name) => _isWindows ? '$name.exe' : name;

  @override
  bool get canInstallComponents => true;

  @override
  Future<void> initialize() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    status.value = const EngineStatus(state: EngineState.initializing, message: 'Looking for yt-dlp…');
    try {
      final support = await getApplicationSupportDirectory();
      _binDir = Directory(p.join(support.path, 'bin'));
      if (!_binDir.existsSync()) _binDir.createSync(recursive: true);
      Installer.cleanLeftovers(_binDir);

      final managed = File(p.join(_binDir.path, _exe('yt-dlp')));
      if (managed.existsSync()) {
        _ytdlp = managed.path;
      } else {
        _ytdlp = await _which('yt-dlp');
      }
      if (_ytdlp == null) {
        await _installYtDlp();
        _ytdlp = managed.path;
      }
      await _detectComponents();
      final version = await _version();
      status.value = EngineStatus(
        state: EngineState.ready,
        version: version,
        ffmpegAvailable: _ffmpegDir != null,
        jsRuntime: _js?.name,
      );
      unawaited(maybeAutoUpdate());
    } catch (e) {
      _initFuture = null;
      status.value = EngineStatus(state: EngineState.error, message: 'Couldn\'t set up yt-dlp: ${_short(e)}');
    }
  }

  Future<void> _detectComponents() async {
    final ffmpeg = File(p.join(_binDir.path, _exe('ffmpeg')));
    if (ffmpeg.existsSync()) {
      _ffmpegDir = _binDir.path;
    } else {
      final found = await _which('ffmpeg');
      _ffmpegDir = found == null ? null : p.dirname(found);
    }

    final deno = File(p.join(_binDir.path, _exe('deno')));
    if (deno.existsSync()) {
      _js = (name: 'deno', path: deno.path);
    } else {
      _js = null;
      for (final name in const ['deno', 'node', 'bun']) {
        final found = await _which(name);
        if (found != null) {
          _js = (name: name, path: found);
          break;
        }
      }
    }
  }

  Future<String?> _version() async {
    final result = await _rawRun(['--version']);
    final v = result.stdout.trim();
    return v.isEmpty ? null : v.split(RegExp(r'\s')).first;
  }

  /// Finds [name] on PATH (plus the usual Homebrew folders that GUI apps on
  /// macOS don't inherit).
  Future<String?> _which(String name) async {
    final candidates = <String>[];
    final pathEnv = Platform.environment['PATH'] ?? '';
    candidates.addAll(pathEnv.split(_isWindows ? ';' : ':').where((e) => e.trim().isNotEmpty));
    if (Platform.isMacOS) candidates.addAll(['/opt/homebrew/bin', '/usr/local/bin']);
    if (Platform.isLinux) candidates.addAll(['/usr/local/bin', '/usr/bin', p.join(_home, '.local', 'bin')]);
    final names = _isWindows ? ['$name.exe', '$name.cmd'] : [name];
    for (final dir in candidates) {
      for (final n in names) {
        final f = File(p.join(dir.trim(), n));
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }

  String get _home => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  Future<String> _arch() async {
    if (_isWindows) {
      final a = (Platform.environment['PROCESSOR_ARCHITEW6432'] ?? Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '')
          .toUpperCase();
      return a.contains('ARM') ? 'arm64' : 'x64';
    }
    try {
      final r = await Process.run('uname', ['-m']);
      final m = r.stdout.toString().trim();
      return (m == 'arm64' || m == 'aarch64') ? 'arm64' : 'x64';
    } catch (_) {
      return 'x64';
    }
  }

  // ───── Installing ─────

  static const _ytdlpStable = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download';
  static const _ytdlpNightly = 'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download';

  Future<String> _ytdlpAsset() async {
    if (Platform.isWindows) return 'yt-dlp.exe';
    if (Platform.isMacOS) return 'yt-dlp_macos';
    return await _arch() == 'arm64' ? 'yt-dlp_linux_aarch64' : 'yt-dlp_linux';
  }

  /// Downloads a verified yt-dlp binary and installs it as the managed copy.
  Future<String?> _downloadYtDlp(void Function(double? progress) onProgress) async {
    final asset = await _ytdlpAsset();
    final work = await _workDir('ytdlp');
    try {
      final file = File(p.join(work.path, _exe('yt-dlp')));
      await Installer.download(
        [Source.url('yt-dlp (stable)', '$_ytdlpStable/$asset'), Source.url('yt-dlp (nightly)', '$_ytdlpNightly/$asset')],
        file,
        minBytes: 1024 * 1024,
        onProgress: onProgress,
        validate: (f) async {
          if (!await Installer.verify(f.path, ['--version'])) {
            throw InstallException('the downloaded yt-dlp doesn\'t run');
          }
        },
      );
      final target = p.join(_binDir.path, _exe('yt-dlp'));
      await Installer.place(file, target);
      _ytdlp = target;
      return await _version();
    } finally {
      _deleteDir(work);
    }
  }

  Future<void> _installYtDlp() async {
    status.value = const EngineStatus(
      state: EngineState.installing,
      progress: 0,
      message: 'Downloading the yt-dlp engine (one-time setup)…',
    );
    await _downloadYtDlp((progress) => status.value = status.value.copyWith(progress: progress));
  }

  /// Archives to download for a component, each with mirrors, and the
  /// executables to take from them.
  Future<List<({List<Source> sources, List<String> exes})>> _componentParts(EngineComponent component) async {
    final arch = await _arch();
    if (component == EngineComponent.jsRuntime) {
      final asset = Platform.isWindows
          ? 'deno-x86_64-pc-windows-msvc.zip'
          : Platform.isMacOS
              ? 'deno-${arch == 'arm64' ? 'aarch64' : 'x86_64'}-apple-darwin.zip'
              : 'deno-${arch == 'arm64' ? 'aarch64' : 'x86_64'}-unknown-linux-gnu.zip';
      return [
        (
          sources: [
            Source.url('GitHub', 'https://github.com/denoland/deno/releases/latest/download/$asset'),
            Source('dl.deno.land', () async {
              final version = (await _fetchText(Uri.parse('https://dl.deno.land/release-latest.txt'))).trim();
              return Uri.parse('https://dl.deno.land/release/$version/$asset');
            }),
          ],
          exes: ['deno'],
        ),
      ];
    }
    const ytdlpBuilds = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest';
    const btbnBuilds = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest';
    if (Platform.isWindows) {
      final name = 'ffmpeg-master-latest-${arch == 'arm64' ? 'winarm64' : 'win64'}-gpl.zip';
      return [
        (
          sources: [
            Source.url('yt-dlp FFmpeg builds', '$ytdlpBuilds/$name'),
            Source.url('BtbN FFmpeg builds', '$btbnBuilds/$name'),
            if (arch != 'arm64')
              Source.url('gyan.dev', 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'),
          ],
          exes: ['ffmpeg', 'ffprobe'],
        ),
      ];
    }
    if (Platform.isLinux) {
      final name = 'ffmpeg-master-latest-${arch == 'arm64' ? 'linuxarm64' : 'linux64'}-gpl.tar.xz';
      return [
        (
          sources: [
            Source.url('yt-dlp FFmpeg builds', '$ytdlpBuilds/$name'),
            Source.url('BtbN FFmpeg builds', '$btbnBuilds/$name'),
          ],
          exes: ['ffmpeg', 'ffprobe'],
        ),
      ];
    }
    final a = arch == 'arm64' ? 'arm64' : 'amd64';
    const riedl = 'https://ffmpeg.martin-riedl.de/redirect/latest/macos';
    return [
      for (final tool in ['ffmpeg', 'ffprobe'])
        (
          sources: [
            Source.url('martin-riedl.de (release)', '$riedl/$a/release/$tool.zip'),
            Source.url('martin-riedl.de (snapshot)', '$riedl/$a/snapshot/$tool.zip'),
          ],
          exes: [tool],
        ),
    ];
  }

  @override
  Future<void> installComponent(EngineComponent component) async {
    if (componentInstall.value != null) return;
    await initialize();
    final label = component == EngineComponent.ffmpeg ? 'FFmpeg' : 'Deno (JavaScript runtime)';
    void report(String text, double? progress) =>
        componentInstall.value = (component: component, progress: progress, label: text);
    report('Downloading $label…', 0);
    final work = await _workDir('component-${component.name}');
    try {
      final parts = await _componentParts(component);
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final versionArg = component == EngineComponent.ffmpeg ? '-version' : '--version';
        final archive = File(p.join(work.path, 'part$i.download'));
        final out = Directory(p.join(work.path, 'x$i'));
        // Each source is downloaded, unpacked and test-run; a source whose
        // archive or binaries are broken is skipped for the next one.
        await Installer.download(
          part.sources,
          archive,
          minBytes: 1024 * 1024,
          onProgress: (progress) => report('Downloading $label…', ((progress ?? 0) + i) / parts.length),
          validate: (file) async {
            report('Unpacking $label…', null);
            if (out.existsSync()) out.deleteSync(recursive: true);
            final ext = (await _sniffArchive(file)) ?? '.zip';
            final named = file.renameSync('${file.path}$ext');
            try {
              await Installer.extract(named.path, out.path);
            } finally {
              named.renameSync(file.path);
            }
            for (final exe in part.exes) {
              final found = Installer.find(out, _exe(exe));
              if (found == null) throw InstallException('${_exe(exe)} is missing from the download');
              report('Checking $label…', null);
              if (!await Installer.verify(found.path, [versionArg])) {
                throw InstallException('${_exe(exe)} doesn\'t run on this computer');
              }
            }
          },
        );
        for (final exe in part.exes) {
          await Installer.place(Installer.find(out, _exe(exe))!, p.join(_binDir.path, _exe(exe)));
        }
      }
      await _detectComponents();
      status.value = status.value.copyWith(ffmpegAvailable: _ffmpegDir != null, jsRuntime: _js?.name);
    } finally {
      componentInstall.value = null;
      _deleteDir(work);
    }
  }

  /// `.zip` or `.tar.xz`, from the file's magic bytes.
  Future<String?> _sniffArchive(File file) async {
    final raf = await file.open();
    try {
      final head = await raf.read(6);
      if (head.length >= 2 && head[0] == 0x50 && head[1] == 0x4B) return '.zip';
      if (head.length >= 6 && head[0] == 0xFD && head[1] == 0x37 && head[2] == 0x7A) return '.tar.xz';
      return null;
    } finally {
      await raf.close();
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

  Future<Directory> _workDir(String name) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'fetchnet', '$name-${DateTime.now().millisecondsSinceEpoch}'));
    dir.createSync(recursive: true);
    return dir;
  }

  void _deleteDir(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // ───── Running ─────

  Map<String, String> get _env => {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'};

  List<String> _withRuntimeArgs(List<String> args) => [
        if (_ffmpegDir != null) ...['--ffmpeg-location', _ffmpegDir!],
        if (_js != null && _js!.name != 'deno') ...['--js-runtimes', '${_js!.name}:${_js!.path}'],
        if (_js != null && _js!.name == 'deno') ...['--js-runtimes', 'deno:${_js!.path}'],
        ...args,
      ];

  Future<EngineResult> _rawRun(List<String> args) async {
    final exe = _ytdlp;
    if (exe == null) return const EngineResult(exitCode: -1, stdout: '', stderr: 'yt-dlp is not installed.');
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
  Future<EngineResult> run(List<String> args, {String? id}) async {
    await initialize();
    final run = start(id ?? 'run-${DateTime.now().microsecondsSinceEpoch}', args, collectStdout: true);
    return run.done;
  }

  @override
  EngineRun start(String id, List<String> args, {bool collectStdout = false}) {
    final run = _DesktopRun(() => cancel(id));
    () async {
      await initialize();
      final exe = _ytdlp;
      if (exe == null) {
        run._finish(const EngineResult(exitCode: -1, stdout: '', stderr: 'yt-dlp is not installed.'));
        return;
      }
      try {
        final process = await Process.start(exe, _withRuntimeArgs(args), environment: _env);
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
        // Post-processing progress (merging, converting) is printed to stderr.
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
      // Kill the whole tree: yt-dlp spawns FFmpeg for merging.
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill(ProcessSignal.sigterm);
    }
  }

  @override
  Future<String> update() async {
    await initialize();
    final previous = status.value;
    if (previous.state != EngineState.ready) return 'The engine is busy, try again in a moment.';
    status.value = previous.copyWith(state: EngineState.updating, message: 'Updating yt-dlp…');
    try {
      final before = await _version();
      final managed = p.isWithin(_binDir.path, _ytdlp ?? '');
      var updated = false;

      // 1. yt-dlp's own updater (fast, verifies signatures).
      if (managed) {
        try {
          final r = await _rawRun(['-U']).timeout(const Duration(minutes: 3));
          final out = '${r.stdout}\n${r.stderr}';
          if (r.ok && out.contains('up to date')) {
            await prefs.markEngineUpdateChecked();
            status.value = previous.copyWith(state: EngineState.ready, version: before, clearMessage: true);
            return 'yt-dlp is already up to date (${before ?? 'latest'}).';
          }
          updated = r.ok && await Installer.verify(_ytdlp!, ['--version']);
        } catch (_) {}
      }

      // 2. Fallback (or a yt-dlp found on PATH, which -U can't touch): fetch
      // a fresh verified binary and switch to the managed copy.
      String? after;
      if (updated) {
        after = await _version();
      } else {
        after = await _downloadYtDlp((progress) {
          status.value = status.value.copyWith(progress: progress, message: 'Downloading the latest yt-dlp…');
        });
      }
      await prefs.markEngineUpdateChecked();
      status.value = previous.copyWith(state: EngineState.ready, version: after, clearMessage: true, clearProgress: true);
      if (after != null && after == before) return 'yt-dlp is already up to date ($after).';
      return 'yt-dlp updated to ${after ?? 'the latest version'}.';
    } catch (e) {
      status.value = previous.copyWith(state: EngineState.ready, clearMessage: true, clearProgress: true);
      return 'Update failed: ${_short(e)}';
    }
  }

  String _short(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}

class _DesktopRun extends EngineRun {
  _DesktopRun(this._cancel);

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
