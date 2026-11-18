import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../engine/installer.dart';
import 'update_service.dart';

/// How a Windows update is installed.
@immutable
class WindowsUpdatePlan {
  const WindowsUpdatePlan({required this.downloadKey, required this.useInstaller});

  /// `zip` or `installer` (keys of [PlatformUpdate.downloads]).
  final String downloadKey;

  /// The installed copy can't be written (Program Files) or there is no
  /// zip: the downloaded installer updates FetchNet instead.
  final bool useInstaller;
}

/// Chrome-style updates on Windows: the release zip is unzipped and put in
/// place while FetchNet runs, then Relaunch starts the new version.
///
/// Windows lets a running program's files be renamed (not deleted), so every
/// current file is renamed to `*.fnold` and the new one moved in. Each step
/// goes to a journal (`%LOCALAPPDATA%\FetchNet\update-journal.txt`):
/// - a failure part-way rolls back at once;
/// - the C++ launcher (windows/runner/main.cpp) reads the journal on every
///   start: an update cut off part-way is rolled back, and so is a new
///   version that fails to start twice;
/// - once the new version is up, [confirmStartup] removes the old files.
class WindowsSelfUpdate {
  WindowsSelfUpdate._();

  static const backupSuffix = '.fnold';

  /// Inno Setup's uninstall entry for FetchNet (AppId in FetchNet.iss).
  static const _uninstallKey =
      r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{B7E42D91-6F83-4A2C-9D15-E8B3C71A604F}_is1';

  static String get installDir => p.dirname(Platform.resolvedExecutable);

  static File get journal {
    final base = Platform.environment['LOCALAPPDATA'] ?? p.join(Platform.environment['USERPROFILE'] ?? '', 'AppData', 'Local');
    return File(p.join(base, 'FetchNet', 'update-journal.txt'));
  }

  /// Zip when FetchNet's folder is writable and the site has a zip;
  /// otherwise the installer.
  static Future<WindowsUpdatePlan> plan(PlatformUpdate update) async {
    final writable = _writable(installDir);
    if (writable && update.downloads.containsKey('zip')) {
      return const WindowsUpdatePlan(downloadKey: 'zip', useInstaller: false);
    }
    return const WindowsUpdatePlan(downloadKey: 'installer', useInstaller: true);
  }

  static bool _writable(String dir) {
    final probe = File(p.join(dir, '.fetchnet-write-test-${DateTime.now().microsecondsSinceEpoch}'));
    try {
      probe.writeAsStringSync('ok', flush: true);
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Unzips [zipPath] and puts the new files in place. Throws (after rolling
  /// back) when anything fails.
  static Future<void> applyZip(
    String zipPath,
    AppRelease release, {
    @visibleForTesting String? targetDir,
    @visibleForTesting File? journalFile,
    @visibleForTesting String? exePath,
  }) async {
    final journal = journalFile ?? WindowsSelfUpdate.journal;
    final staged = Directory(p.join(p.dirname(zipPath), 'staged'));
    if (staged.existsSync()) staged.deleteSync(recursive: true);
    await Installer.extract(zipPath, staged.path);
    final root = _findRoot(staged);
    if (root == null) throw const FormatException('the update zip doesn\'t contain FetchNet.exe');
    for (final required in ['flutter_windows.dll', p.join('data', 'app.so'), p.join('data', 'icudtl.dat')]) {
      if (!File(p.join(root.path, required)).existsSync()) {
        throw FormatException('the update zip is missing $required');
      }
    }
    final target = targetDir ?? installDir;
    final exe = exePath ?? Platform.resolvedExecutable;
    final moves = <(String target, String backup)>[];
    void writeJournal(String state) {
      journal.parent.createSync(recursive: true);
      journal.writeAsStringSync([
        'FETCHNET-UPDATE 1',
        'state=$state',
        'launches=0',
        'version=$release',
        'exe=$exe',
        for (final (t, b) in moves) '$t|$b',
        '',
      ].join('\r\n'), flush: true);
    }

    final files = root.listSync(recursive: true, followLinks: false).whereType<File>().toList();
    try {
      writeJournal('applying');
      for (final file in files) {
        final rel = p.relative(file.path, from: root.path);
        final dest = p.join(target, rel);
        Directory(p.dirname(dest)).createSync(recursive: true);
        final backup = '$dest$backupSuffix';
        if (File(backup).existsSync()) File(backup).deleteSync();
        if (File(dest).existsSync()) {
          File(dest).renameSync(backup);
          moves.add((dest, backup));
        } else {
          moves.add((dest, ''));
        }
        writeJournal('applying');
        try {
          file.renameSync(dest);
        } on FileSystemException {
          file.copySync(dest);
        }
      }
      writeJournal('applied');
    } catch (e) {
      _rollBack(moves);
      try {
        journal.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      try {
        staged.deleteSync(recursive: true);
      } catch (_) {}
    }
    if (targetDir == null) await _setDisplayVersion(release.versionName);
  }

  static Directory? _findRoot(Directory dir) {
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path).toLowerCase() == 'fetchnet.exe') return e.parent;
    }
    return null;
  }

  static void _rollBack(List<(String target, String backup)> moves) {
    for (final (target, backup) in moves.reversed) {
      try {
        if (File(target).existsSync()) File(target).deleteSync();
      } catch (_) {
        try {
          File(target).renameSync('$target.fnfailed');
        } catch (_) {}
      }
      if (backup.isNotEmpty) {
        try {
          File(backup).renameSync(target);
        } catch (_) {}
      }
    }
  }

  /// Keeps "Apps & features" showing the installed version (per-user
  /// installs only; a per-machine entry needs the installer).
  static Future<void> _setDisplayVersion(String version) async {
    try {
      final query = await Process.run('reg', ['query', 'HKCU\\$_uninstallKey']);
      if (query.exitCode != 0) return;
      await Process.run('reg', ['add', 'HKCU\\$_uninstallKey', '/v', 'DisplayVersion', '/t', 'REG_SZ', '/d', version, '/f']);
    } catch (_) {}
  }

  /// Starts the new version and closes this one.
  static Future<void> relaunch() async {
    await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
    exit(0);
  }

  /// Runs the downloaded installer (it asks for permission when FetchNet is
  /// installed for all users), then closes FetchNet; the installer starts it
  /// again when it's done.
  static Future<void> runInstaller(String path) async {
    final quoted = path.replaceAll("'", "''");
    await Process.start(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Start-Process -FilePath '$quoted' -ArgumentList '/SILENT','/SUPPRESSMSGBOXES','/NORESTART','/CLOSEAPPLICATIONS'",
      ],
      mode: ProcessStartMode.detached,
    );
    // Leave before the installer replaces our files.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    exit(0);
  }

  /// Called once FetchNet is up after an update: the new version works, so
  /// the old files and the journal go.
  static void confirmStartup({@visibleForTesting File? journalFile, @visibleForTesting String? dir}) {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      final file = journalFile ?? journal;
      if (!file.existsSync()) return;
      final lines = file.readAsLinesSync();
      if (!lines.contains('state=applied')) return;
      for (final line in lines) {
        final bar = line.indexOf('|');
        if (bar < 0) continue;
        final backup = line.substring(bar + 1);
        if (backup.isEmpty) continue;
        try {
          if (File(backup).existsSync()) File(backup).deleteSync();
        } catch (_) {}
      }
      file.deleteSync();
    } catch (_) {}
    _cleanLeftovers(dir ?? installDir);
  }

  /// Leftovers (`*.fnold`, `*.fnfailed`) of past updates.
  static void _cleanLeftovers(String dir) {
    try {
      for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
        if (e is File && (e.path.endsWith(backupSuffix) || e.path.endsWith('.fnfailed'))) {
          try {
            e.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
