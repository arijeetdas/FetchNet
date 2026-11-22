import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/platform/native_bridge.dart';
import '../models/media_info.dart';

/// The subfolders of the FetchNet folder: every file goes into the one for
/// its type.
enum MediaFolder {
  images('Images'),
  audio('Audio'),
  video('Video');

  const MediaFolder(this.folderName);

  /// `Images`, `Audio`, `Video`.
  final String folderName;

  static const _imageExt = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'bmp', 'heic', 'heif', 'jxl', 'tif', 'tiff', 'jfif', 'svg',
  };
  static const _audioExt = {'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wav', 'weba', 'wma', 'alac', 'aiff'};

  /// The folder for a download of [kind]. A post (several files) has no
  /// single folder: each of its files goes by [forExtension].
  static MediaFolder forKind(MediaKind kind) => switch (kind) {
        MediaKind.image || MediaKind.thumbnail => images,
        MediaKind.audio => audio,
        // Subtitles sit next to the videos they belong to.
        MediaKind.video || MediaKind.post || MediaKind.subtitle => video,
      };

  /// The folder for a file with this extension (`jpg`, `.mp3`, ...).
  /// Anything that isn't a picture or audio counts as video.
  static MediaFolder forExtension(String ext) {
    final e = ext.toLowerCase().replaceFirst('.', '');
    if (_imageExt.contains(e)) return images;
    if (_audioExt.contains(e)) return audio;
    return video;
  }
}

/// What happened when a save location was chosen.
class FolderChange {
  const FolderChange({this.error, this.created = const []});

  /// Why the folder can't be used (nothing changed), or `null`.
  final String? error;

  /// The subfolders that were missing and were made (`Audio`, `Video`).
  final List<String> created;

  bool get ok => error == null;
}

/// Owns the FetchNet folder (`Download/FetchNet` unless the user picks
/// another, see [chooseFolder]) with its `Images`, `Audio` and `Video`
/// subfolders, and file naming rules.
class StorageService extends ChangeNotifier {
  StorageService([this._store]);

  final SharedPreferences? _store;
  String? _downloadDir;
  String? _error;

  static const _kCustomDir = 'downloads.custom_dir';

  /// The folder the user chose, or `null` for the default.
  String? get customDir => _store?.getString(_kCustomDir);
  bool get isCustom => customDir != null;

  /// Set when the chosen folder couldn't be used (a removed drive, a folder
  /// without write access): downloads go to the default folder meanwhile.
  String? get customProblem => _customProblem;
  String? _customProblem;

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
    // The folder the user chose, when it can still be written to.
    final custom = customDir;
    if (custom != null) {
      if (!await _permitted(requestPermission)) return null;
      final problem = await _usable(custom);
      if (problem == null) {
        _downloadDir = custom;
        _error = null;
        _customProblem = null;
        for (final f in MediaFolder.values) {
          dirFor(f);
        }
        notifyListeners();
        return _downloadDir;
      }
      _customProblem = 'Couldn\'t use $custom ($problem). Saving to the default folder for now.';
    }
    return _ensureDefault(requestPermission: requestPermission);
  }

  /// The default folder: `Download/FetchNet` (Android), `Downloads/FetchNet`
  /// (computers).
  Future<String?> _ensureDefault({required bool requestPermission}) async {
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
      // Images, Audio and Video are there from the start.
      for (final f in MediaFolder.values) {
        dirFor(f);
      }
      notifyListeners();
      return _downloadDir;
    } catch (e) {
      _error = 'Couldn\'t prepare the download folder: $e';
      notifyListeners();
      return null;
    }
  }

  /// Android 10 and older: the storage permission (asked when [ask]).
  Future<bool> _permitted(bool ask) async {
    if (!Platform.isAndroid || !await NativeBridge.needsLegacyStoragePermission()) return true;
    if (ask && await NativeBridge.requestPermission('storage')) return true;
    _error = ask
        ? 'Storage permission was denied. FetchNet can\'t save downloads without it.'
        : 'Storage permission is needed to save into the Download folder.';
    notifyListeners();
    return false;
  }

  /// Where apps may save on Android 11 and newer (any kind of file): the
  /// Download and Documents folders of the phone's storage.
  static const androidSaveRoots = ['Download', 'Documents'];

  /// The phone's shared storage (`/storage/emulated/0`).
  static const _androidStorage = '/storage/emulated/0';

  /// Why [path] can't hold FetchNet's downloads, or `null` when it can:
  /// it's made if missing, its missing subfolders too, and a test file of
  /// each kind (picture, song, video) is written and removed, which is how
  /// Android shows which folders accept which files.
  Future<String?> _usable(String path) async {
    if (Platform.isAndroid) {
      final norm = p.normalize(path);
      final allowed = androidSaveRoots.any((r) => p.equals(norm, '$_androidStorage/$r') || p.isWithin('$_androidStorage/$r', norm));
      if (!allowed) return 'Android only lets apps save inside the Download or Documents folder';
    }
    try {
      final root = Directory(path);
      if (!root.existsSync()) root.createSync(recursive: true);
      for (final (folder, ext) in [(MediaFolder.images, 'jpg'), (MediaFolder.audio, 'mp3'), (MediaFolder.video, 'mp4')]) {
        final dir = Directory(p.join(path, folder.folderName));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final probe = File(p.join(dir.path, '.fetchnet-write-test.$ext'));
        probe.writeAsStringSync('');
        probe.deleteSync();
      }
      return null;
    } on FileSystemException catch (e) {
      final os = e.osError?.message;
      return os == null || os.isEmpty ? 'it can\'t be written to' : 'it can\'t be written to: $os';
    } catch (e) {
      return 'it can\'t be written to';
    }
  }

  /// Saves downloads in [path] from now on (files already saved stay where
  /// they are). Only the subfolders that are missing (`Images`, `Audio`,
  /// `Video`) are made; existing ones are kept as they are.
  Future<FolderChange> chooseFolder(String path) async {
    final store = _store;
    if (store == null) return const FolderChange(error: 'Settings aren\'t available.');
    final target = p.normalize(path);
    if (!await _permitted(true)) return FolderChange(error: _error);
    final missing = [for (final f in MediaFolder.values) if (!Directory(p.join(target, f.folderName)).existsSync()) f.folderName];
    final problem = await _usable(target);
    if (problem == null) {
      await store.setString(_kCustomDir, target);
      _downloadDir = target;
      _error = null;
      _customProblem = null;
      notifyListeners();
      return FolderChange(created: missing);
    }
    // Leave nothing behind in a folder that can't be used.
    for (final name in missing) {
      try {
        final d = Directory(p.join(target, name));
        if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
      } catch (_) {}
    }
    return FolderChange(error: 'This folder can\'t be used: $problem.');
  }

  /// Back to the default folder (`Download/FetchNet`).
  Future<String?> useDefaultFolder() async {
    await _store?.remove(_kCustomDir);
    _customProblem = null;
    return ensureDownloadDir(requestPermission: true);
  }

  /// "Download/FetchNet", "Media/Clips": the end of the folder's path, for
  /// short messages.
  String shortName([MediaKind? kind]) {
    final root = _downloadDir;
    if (root == null) return 'Download/FetchNet';
    final parts = p.split(root).where((s) => s.isNotEmpty && s != p.separator && !s.endsWith(':\\')).toList();
    final tail = parts.length <= 2 ? parts : parts.sublist(parts.length - 2);
    final base = tail.isEmpty ? root : tail.join('/');
    return kind == null ? base : '$base/${MediaFolder.forKind(kind).folderName}';
  }

  /// The folder as people know it: "Internal storage › Download › FetchNet"
  /// on Android, the full path elsewhere.
  String displayPath([String? path]) {
    final root = path ?? _downloadDir;
    if (root == null) return '';
    if (!kIsWeb && Platform.isAndroid && root.startsWith(_androidStorage)) {
      final rest = root.substring(_androidStorage.length).split('/').where((s) => s.isNotEmpty);
      return ['Internal storage', ...rest].join(' › ');
    }
    return root;
  }

  /// `Download/FetchNet/Images` (or `Audio`, `Video`), created when missing.
  /// `null` until the FetchNet folder is ready.
  String? dirFor(MediaFolder folder) {
    final root = _downloadDir;
    if (root == null) return null;
    final dir = Directory(p.join(root, folder.folderName));
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (_) {}
    return dir.path;
  }

  /// The folder a download of [kind] is saved in (the FetchNet folder itself
  /// when [kind] is `null`).
  String? dirForKind(MediaKind? kind) => kind == null ? _downloadDir : dirFor(MediaFolder.forKind(kind));

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

  /// A tidy random name such as `FetchNet_Video_20261105_K7QM`. [label]
  /// overrides the kind word (`Image`, `Post`).
  static String randomFileName({required bool audio, bool thumbnail = false, String? label}) {
    final now = DateTime.now();
    final date =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final rnd = Random();
    final tag = List.generate(4, (_) => _alphabet[rnd.nextInt(_alphabet.length)]).join();
    return 'FetchNet_${label ?? (thumbnail ? 'Thumbnail' : audio ? 'Audio' : 'Video')}_${date}_$tag';
  }

  /// The folders a download of [kind] may write into: its type folder, or
  /// all three for a post (its files are spread by type). `null` checks the
  /// FetchNet folder itself.
  List<String> _foldersFor(MediaKind? kind) {
    if (kind == MediaKind.post) return [for (final f in MediaFolder.values) ?dirFor(f)];
    return [?dirForKind(kind)];
  }

  /// True when a file with this base name (any extension) is already in the
  /// folder a download of [kind] goes to. With [folders], a folder of that
  /// name counts too (the name of a post's folder).
  bool baseNameTaken(String baseName, {MediaKind? kind, bool folders = false}) {
    final wanted = baseName.toLowerCase();
    for (final dir in _foldersFor(kind)) {
      try {
        for (final entity in Directory(dir).listSync(followLinks: false)) {
          if (entity is Directory) {
            if (folders && p.basename(entity.path).toLowerCase() == wanted) return true;
            continue;
          }
          if (entity is! File) continue;
          if (p.basenameWithoutExtension(entity.path).toLowerCase() == wanted) return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// `name`, or `name (2)`, `name (3)`, ... — the first one not in use in
  /// the folder for [kind].
  String uniqueBaseName(String baseName, {Set<String> alsoTaken = const {}, MediaKind? kind, bool folders = false}) {
    bool taken(String n) => baseNameTaken(n, kind: kind, folders: folders) || alsoTaken.contains(n.toLowerCase());
    if (!taken(baseName)) return baseName;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$baseName ($i)';
      if (!taken(candidate)) return candidate;
    }
    return '$baseName ${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Whether [path] is a file that still exists in the FetchNet folder: in
  /// a type folder (`Images/a.jpg`), a post's folder there
  /// (`Images/Post/a.jpg`), or the FetchNet folder itself (downloads saved
  /// before the type folders existed, and their post folders).
  bool isInDownloadDir(String path) {
    final dir = _downloadDir;
    if (dir == null || !p.isWithin(dir, path)) return false;
    final depth = p.split(p.relative(path, from: dir)).length;
    return depth <= 3 && File(path).existsSync();
  }
}
