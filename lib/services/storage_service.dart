import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/platform/native_bridge.dart';

/// Owns the `Download/FetchNet` folder and file naming rules.
class StorageService extends ChangeNotifier {
  String? _downloadDir;
  String? _error;

  /// Absolute path of the FetchNet download folder, once resolved.
  String? get downloadDir => _downloadDir;

  /// Why the folder could not be created, if it couldn't.
  String? get error => _error;

  bool get isReady => _downloadDir != null && _error == null;

  /// Resolves and creates the download folder. Safe to call repeatedly.
  Future<String?> ensureDownloadDir({bool requestPermission = false}) async {
    if (kIsWeb) {
      _error = 'Downloads are not available on the web.';
      notifyListeners();
      return null;
    }
    try {
      if (Platform.isAndroid) {
        if (await NativeBridge.needsLegacyStoragePermission()) {
          if (!requestPermission) {
            _error = 'Storage permission is needed to save into the Download folder.';
            notifyListeners();
            return null;
          }
          final granted = await NativeBridge.requestPermission('storage');
          if (!granted) {
            _error = 'Storage permission was denied. FetchNet can\'t save downloads without it.';
            notifyListeners();
            return null;
          }
        }
        final result = await NativeBridge.androidDownloadDirectory();
        if (result == null || !result.exists) {
          _error = 'Couldn\'t create the Download/FetchNet folder.';
          _downloadDir = result?.path;
          notifyListeners();
          return null;
        }
        _downloadDir = result.path;
      } else {
        Directory? base;
        try {
          base = await getDownloadsDirectory();
        } catch (_) {}
        base ??= Directory(p.join(_homeDir(), 'Downloads'));
        final dir = Directory(p.join(base.path, 'FetchNet'));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        _downloadDir = dir.path;
      }
      _error = null;
      notifyListeners();
      return _downloadDir;
    } catch (e) {
      _error = 'Couldn\'t prepare the download folder: $e';
      notifyListeners();
      return null;
    }
  }

  /// Private scratch space for partial downloads, cookies, etc.
  Future<Directory> workDir(String name) async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'fetchnet', name));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _homeDir() =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.current.path;

  // ───── File names ─────

  static final _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
  static const _reservedWindows = {
    'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8',
    'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// Turns any text (usually the video title) into a safe file base name.
  static String sanitizeFileName(String input, {int maxLength = 120}) {
    var name = input
        .replaceAll(_illegal, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    if (_reservedWindows.contains(name.toUpperCase())) name = '${name}_';
    if (name.length > maxLength) name = name.substring(0, maxLength).trimRight();
    return name;
  }

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// A tidy random name such as `FetchNet_Video_20261105_K7QM`.
  static String randomFileName({required bool audio, bool thumbnail = false}) {
    final now = DateTime.now();
    final date =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rnd = Random();
    final tag = List.generate(4, (_) => _alphabet[rnd.nextInt(_alphabet.length)]).join();
    return 'FetchNet_${thumbnail ? 'Thumbnail' : audio ? 'Audio' : 'Video'}_${date}_$tag';
  }

  /// True when a file with this base name (any extension) is already in the
  /// download folder.
  bool baseNameTaken(String baseName) {
    final dir = _downloadDir;
    if (dir == null) return false;
    final wanted = baseName.toLowerCase();
    try {
      for (final entity in Directory(dir).listSync(followLinks: false)) {
        if (entity is! File) continue;
        if (p.basenameWithoutExtension(entity.path).toLowerCase() == wanted) return true;
      }
    } catch (_) {}
    return false;
  }

  /// `name`, or `name (2)`, `name (3)`, ... — the first one not in use.
  String uniqueBaseName(String baseName, {Set<String> alsoTaken = const {}}) {
    bool taken(String n) => baseNameTaken(n) || alsoTaken.contains(n.toLowerCase());
    if (!taken(baseName)) return baseName;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$baseName ($i)';
      if (!taken(candidate)) return candidate;
    }
    return '$baseName ${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Whether [path] is a file that still exists directly inside the
  /// FetchNet download folder.
  bool isInDownloadDir(String path) {
    final dir = _downloadDir;
    if (dir == null) return false;
    return p.equals(p.dirname(path), dir) && File(path).existsSync();
  }
}
