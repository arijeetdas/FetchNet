import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
import 'gallery_engine.dart';
import 'installer.dart';

/// gallery-dl on Android: the official Python package from PyPI, run by the
/// Python 3.12 that youtubedl-android already bundles for yt-dlp (see
/// `GalleryDl.kt`). Nothing extra ships in the APK.
///
/// gallery-dl and its dependencies (all pure Python) are unpacked into
/// `files/gallery-dl/site-<time>/`; `current.json` names the folder in use.
/// Updates unpack a fresh folder, test it, and only then switch to it, so a
/// broken update never replaces a working install.
class GalleryAndroidEngine extends GalleryDlEngine {
  GalleryAndroidEngine(super.prefs, this._ytdlp);

  final YtDlpEngine _ytdlp;

  static const _channel = MethodChannel('fetchnet/gallerydl');
  static const _events = EventChannel('fetchnet/gallerydl/events');

  /// gallery-dl plus what `requests` needs; every one has a pure-Python wheel.
  static const packages = ['gallery-dl', 'requests', 'urllib3', 'idna', 'certifi', 'charset-normalizer'];

  /// The bundled interpreter.
  static const _python = (3, 12);

  final Map<String, _AndroidGalleryRun> _runs = {};
  StreamSubscription<dynamic>? _eventSub;
  Future<void>? _initFuture;
  Directory? _root;
  String? _site;
  Map<String, String> _versions = const {};

  @override
  Future<void> initialize() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    _eventSub ??= _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    status.value = const EngineStatus(state: EngineState.initializing, message: 'Waiting for yt-dlp…');
    try {
      // gallery-dl runs on the Python youtubedl-android unpacks on its start.
      await _waitForYtDlp();
      _root = Directory(p.join((await getApplicationSupportDirectory()).path, 'gallery-dl'))..createSync(recursive: true);
      _loadManifest();
      if (_site == null) {
        status.value = const EngineStatus(
          state: EngineState.installing,
          progress: 0,
          message: 'Downloading gallery-dl for images and posts (one-time setup)…',
        );
        await _install(await _resolve(), (progress) => status.value = status.value.copyWith(progress: progress));
      }
      _cleanOldSites();
      status.value = EngineStatus(state: EngineState.ready, version: _versions['gallery-dl']);
      unawaited(maybeAutoUpdate());
    } catch (e) {
      _initFuture = null;
      status.value = EngineStatus(state: EngineState.error, message: 'Couldn\'t set up gallery-dl: ${_short(e)}');
    }
  }

  Future<void> _waitForYtDlp() async {
    unawaited(_ytdlp.initialize());
    final s = _ytdlp.status;
    if (s.value.isReady) return;
    final done = Completer<void>();
    void listener() {
      if ((s.value.isReady || s.value.state == EngineState.error) && !done.isCompleted) done.complete();
    }

    s.addListener(listener);
    try {
      listener();
      await done.future.timeout(const Duration(minutes: 5));
    } finally {
      s.removeListener(listener);
    }
    if (!s.value.isReady) throw StateError('yt-dlp (and its Python) didn\'t start');
  }

  File get _manifest => File(p.join(_root!.path, 'current.json'));

  void _loadManifest() {
    try {
      final json = jsonDecode(_manifest.readAsStringSync());
      final dir = json['site'] as String?;
      if (dir != null && Directory(dir).existsSync() && Directory(p.join(dir, 'gallery_dl')).existsSync()) {
        _site = dir;
        _versions = (json['versions'] as Map).map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {}
  }

  /// Removes package folders other than the one in use.
  void _cleanOldSites() {
    try {
      for (final e in _root!.listSync()) {
        if (e is Directory && p.basename(e.path).startsWith('site-') && e.path != _site) e.deleteSync(recursive: true);
        if (e is Directory && p.basename(e.path).startsWith('wheels-')) e.deleteSync(recursive: true);
      }
    } catch (_) {}
  }

  // ───── Installing ─────

  /// The newest wheel of every package that runs on the bundled Python.
  Future<Map<String, PyWheel>> _resolve() async {
    final out = <String, PyWheel>{};
    for (final name in packages) {
      final json = jsonDecode(await _fetchText(Uri.parse('https://pypi.org/pypi/$name/json')));
      final wheel = PyWheel.pick(json, python: _python);
      if (wheel == null) throw InstallException('no compatible $name package on PyPI');
      out[name] = wheel;
    }
    return out;
  }

  Future<void> _install(Map<String, PyWheel> wheels, void Function(double? progress) onProgress) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final wheelDir = Directory(p.join(_root!.path, 'wheels-$stamp'))..createSync(recursive: true);
    final site = Directory(p.join(_root!.path, 'site-$stamp'))..createSync(recursive: true);
    try {
      var i = 0;
      for (final entry in wheels.entries) {
        final w = entry.value;
        final file = File(p.join(wheelDir.path, w.filename));
        await Installer.download(
          [Source.url('PyPI', w.url)],
          file,
          minBytes: 1024,
          onProgress: (progress) => onProgress(((progress ?? 0) + i) / wheels.length),
          validate: (f) async {
            final actual = (await sha256.bind(f.openRead()).first).toString();
            if (actual != w.sha256) throw InstallException('${w.filename} doesn\'t match its PyPI checksum');
          },
        );
        // A wheel is a zip of the package's files, ready to import.
        await extractFileToDisk(file.path, site.path);
        i++;
      }
      onProgress(null);
      // Only a working install replaces the current one.
      final test = await _call('run', {'id': 'gdl-test-$stamp', 'args': ['--version'], 'site': site.path});
      if (test.exitCode != 0 || test.stdout.trim().isEmpty) {
        throw InstallException('gallery-dl doesn\'t start: ${_short(test.stderr.isEmpty ? test.stdout : test.stderr)}');
      }
      _manifest.writeAsStringSync(jsonEncode({
        'site': site.path,
        'versions': {for (final e in wheels.entries) e.key: e.value.version},
      }));
      _site = site.path;
      _versions = {for (final e in wheels.entries) e.key: e.value.version};
    } catch (_) {
      try {
        site.deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      try {
        wheelDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<String> update() async {
    await initialize();
    final previous = status.value;
    if (previous.state != EngineState.ready) return 'gallery-dl is busy, try again in a moment.';
    status.value = previous.copyWith(state: EngineState.updating, message: 'Checking for a new gallery-dl…');
    try {
      final latest = await _resolve();
      final before = _versions['gallery-dl'];
      final changed = latest.entries.any((e) => _versions[e.key] != e.value.version);
      if (changed) {
        await _install(latest, (progress) {
          status.value = status.value.copyWith(progress: progress, message: 'Downloading the latest gallery-dl…');
        });
      }
      await prefs.markGalleryUpdateChecked();
      final after = _versions['gallery-dl'];
      status.value = previous.copyWith(state: EngineState.ready, version: after, clearMessage: true, clearProgress: true);
      if (!changed || after == before) return 'gallery-dl is already up to date (${after ?? 'latest'}).';
      return 'gallery-dl updated to ${after ?? 'the latest version'}.';
    } catch (e) {
      status.value = previous.copyWith(state: EngineState.ready, clearMessage: true, clearProgress: true);
      return 'Update failed: ${_short(e)}';
    }
  }

  Future<String> _fetchText(Uri uri) async {
    final client = HttpClient()..userAgent = 'FetchNet';
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  // ───── Running ─────

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final id = raw['id']?.toString();
    final run = id == null ? null : _runs[id];
    if (run == null) return;
    switch (raw['type']) {
      case 'line':
        run._lines.add(raw['line']?.toString() ?? '');
      case 'exit':
        _runs.remove(id);
        run._finish(EngineResult(
          exitCode: (raw['exitCode'] as num?)?.toInt() ?? -1,
          stdout: raw['out']?.toString() ?? '',
          stderr: raw['err']?.toString() ?? '',
        ));
    }
  }

  Future<EngineResult> _call(String method, Map<String, Object?> args) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(method, args);
      return EngineResult(
        exitCode: (result?['exitCode'] as num?)?.toInt() ?? -1,
        stdout: result?['out']?.toString() ?? '',
        stderr: result?['err']?.toString() ?? '',
      );
    } on PlatformException catch (e) {
      return EngineResult(exitCode: -1, stdout: '', stderr: e.message ?? e.code);
    } on MissingPluginException {
      return const EngineResult(exitCode: -1, stdout: '', stderr: 'gallery-dl isn\'t available in this build.');
    }
  }

  @override
  Future<EngineResult> run(List<String> args, {String? id}) async {
    await initialize();
    final site = _site;
    if (site == null) return EngineResult(exitCode: -1, stdout: '', stderr: status.value.message ?? 'gallery-dl is not installed.');
    return _call('run', {
      'id': id ?? 'gdl-${DateTime.now().microsecondsSinceEpoch}',
      'args': [...GalleryDlEngine.baseArgs, ...args],
      'site': site,
    });
  }

  @override
  EngineRun start(String id, List<String> args) {
    final run = _AndroidGalleryRun(() => cancel(id));
    _runs[id] = run;
    () async {
      await initialize();
      final site = _site;
      if (site == null) {
        _runs.remove(id);
        run._finish(EngineResult(exitCode: -1, stdout: '', stderr: status.value.message ?? 'gallery-dl is not installed.'));
        return;
      }
      try {
        await _channel.invokeMethod('start', {
          'id': id,
          'args': [...GalleryDlEngine.baseArgs, ...args],
          'site': site,
        });
      } catch (e) {
        _runs.remove(id);
        run._finish(EngineResult(exitCode: -1, stdout: '', stderr: e is PlatformException ? (e.message ?? e.code) : '$e'));
      }
    }();
    return run;
  }

  @override
  Future<void> cancel(String id) async {
    try {
      await _channel.invokeMethod('cancel', {'id': id});
    } catch (_) {}
  }

  String _short(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}

/// One pure-Python wheel chosen from PyPI's JSON API.
class PyWheel {
  const PyWheel({required this.version, required this.filename, required this.url, required this.sha256});

  final String version;
  final String filename;
  final String url;
  final String sha256;

  /// The newest release of a package (PyPI's `/pypi/<name>/json`) that has a
  /// `py3-none-any` wheel and supports [python].
  static PyWheel? pick(Object? json, {required (int, int) python}) {
    if (json is! Map) return null;
    final releases = json['releases'];
    final latest = (json['info'] as Map?)?['version'] as String?;
    final candidates = <String>[
      ?latest,
      if (releases is Map) ...(releases.keys.map((k) => '$k').toList()..sort(compareVersions)).reversed,
    ];
    for (final version in candidates) {
      if (RegExp(r'(a|b|rc|dev)\d*$|\.dev', caseSensitive: false).hasMatch(version)) continue;
      final files = version == latest && json['urls'] is List ? json['urls'] as List : (releases is Map ? releases[version] : null);
      if (files is! List) continue;
      for (final f in files.whereType<Map>()) {
        final name = '${f['filename'] ?? ''}';
        if (f['packagetype'] != 'bdist_wheel' || !RegExp(r'-py3(\.py\d)?-none-any\.whl$|-py2\.py3-none-any\.whl$').hasMatch(name)) {
          continue;
        }
        if (f['yanked'] == true) continue;
        if (!supportsPython('${f['requires_python'] ?? ''}', python)) continue;
        final sha = (f['digests'] as Map?)?['sha256'];
        final url = f['url'];
        if (sha is! String || url is! String) continue;
        return PyWheel(version: version, filename: name, url: url, sha256: sha.toLowerCase());
      }
    }
    return null;
  }

  /// Whether a `requires_python` specifier (`>=3.8`, `>=3.9,<4`) allows
  /// [python]. Unknown parts are ignored.
  static bool supportsPython(String spec, (int, int) python) {
    for (final raw in spec.split(',')) {
      final m = RegExp(r'^\s*(>=|<=|>|<|==|!=)\s*(\d+)(?:\.(\d+|\*))?').firstMatch(raw);
      if (m == null) continue;
      final major = int.parse(m.group(2)!);
      final minor = int.tryParse(m.group(3) ?? '');
      final cmp = python.$1 != major ? python.$1.compareTo(major) : (minor == null ? 0 : python.$2.compareTo(minor));
      final ok = switch (m.group(1)) {
        '>=' => cmp >= 0,
        '>' => cmp > 0,
        '<=' => cmp <= 0,
        '<' => cmp < 0,
        '==' => m.group(3) == '*' || minor == null ? python.$1 == major : cmp == 0,
        '!=' => m.group(3) == '*' ? python.$1 != major || python.$2 != (minor ?? -1) : cmp != 0,
        _ => true,
      };
      if (!ok) return false;
    }
    return true;
  }

  /// Compares dotted version numbers (`1.32.20` > `1.9`).
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v.split(RegExp(r'[.+-]')).map((e) => int.tryParse(e) ?? 0).toList();
    final pa = parts(a);
    final pb = parts(b);
    for (var i = 0; i < pa.length || i < pb.length; i++) {
      final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
      if (d != 0) return d.sign;
    }
    return 0;
  }
}

class _AndroidGalleryRun extends EngineRun {
  _AndroidGalleryRun(this._cancel);

  final Future<void> Function() _cancel;
  final StreamController<String> _lines = StreamController.broadcast();
  final Completer<EngineResult> _done = Completer();

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
  Future<void> cancel() => _cancel();
}
