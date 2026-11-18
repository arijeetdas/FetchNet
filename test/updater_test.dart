import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/core/app_services.dart';
import 'package:fetchnet/core/theme.dart';
import 'package:fetchnet/features/shell/updater_dialog.dart';
import 'package:fetchnet/services/app_updater.dart';
import 'package:fetchnet/services/update_service.dart';
import 'package:fetchnet/services/windows_self_update.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../tool/changelog_markdown.dart';

/// The shape the website publishes at /update-manifest.json.
const _manifest = '''
{
  "schema": 1,
  "platforms": {
    "android": {
      "versionName": "1.3.0", "buildNo": 5, "notes": null,
      "downloads": {
        "universal": { "url": "https://www.dropbox.com/scl/fi/a/FetchNet-v1.3.0-Universal.apk?dl=1" },
        "arm64-v8a": { "url": "https://www.dropbox.com/scl/fi/b/FetchNet-v1.3.0-arm64-v8a.apk?dl=1" },
        "armeabi-v7a": { "url": "https://www.dropbox.com/scl/fi/c/FetchNet-v1.3.0-armeabi-v7a.apk?dl=1" },
        "x86_64": { "url": "https://www.dropbox.com/scl/fi/d/FetchNet-v1.3.0-x86_64.apk?dl=1" }
      }
    },
    "windows": {
      "versionName": "1.3.0", "buildNo": 5, "notes": null,
      "downloads": { "installer": { "url": "https://www.dropbox.com/scl/fi/e/FetchNet-v1.3.0-Windows-Installer.exe?dl=1" } }
    }
  }
}''';

void main() {
  group('Checking', () {
    const installed = AppRelease(versionName: '1.2.0', buildNumber: 4);

    test('compares build numbers (never the inflated split-APK version codes)', () {
      expect(UpdateService.compare(installed: installed, latest: const AppRelease(versionName: '1.3.0', buildNumber: 5)),
          UpdateState.available);
      expect(UpdateService.compare(installed: installed, latest: installed), UpdateState.upToDate);
      // An unreleased/modified build.
      expect(UpdateService.compare(installed: installed, latest: const AppRelease(versionName: '1.1.1', buildNumber: 3)),
          UpdateState.ahead);
    });

    test('reads this platform from the update manifest', () {
      final android = UpdateService.parseUpdateManifest(_manifest, 'android')!;
      expect(android.release.buildNumber, 5);
      expect(android.downloads.keys, containsAll(['universal', 'arm64-v8a', 'armeabi-v7a', 'x86_64']));
      expect(UpdateService.parseUpdateManifest(_manifest, 'windows')!.downloads.keys, ['installer']);
      expect(UpdateService.parseUpdateManifest(_manifest, 'macos'), isNull);
      expect(() => UpdateService.parseUpdateManifest('{"android": {}}', 'android'), throwsFormatException);
    });
  });

  group('Which APK the updater downloads', () {
    const all = ['universal', 'arm64-v8a', 'armeabi-v7a', 'x86_64'];
    const phone = ['arm64-v8a', 'armeabi-v7a', 'armeabi'];

    test('the same kind as installed: Android refuses a lower version code', () {
      // arm64 build 4 has code 2004: universal build 5 (code 5) would fail.
      expect(UpdateService.androidDownloadKey(installedType: 'arm64-v8a', abis: phone, available: all), 'arm64-v8a');
      // x86_64 (code 4xxx) on an ARM device: arm64 (2xxx) would fail.
      expect(UpdateService.androidDownloadKey(installedType: 'x86_64', abis: phone, available: all), 'x86_64');
      expect(UpdateService.androidDownloadKey(installedType: 'armeabi-v7a', abis: phone, available: all), 'armeabi-v7a');
    });

    test('universal may move up to the device\'s split (always a higher code)', () {
      expect(UpdateService.androidDownloadKey(installedType: 'universal', abis: phone, available: all), 'arm64-v8a');
      expect(UpdateService.androidDownloadKey(installedType: 'universal', abis: ['x86'], available: all), 'universal');
      expect(
        UpdateService.androidDownloadKey(installedType: 'universal', abis: phone, available: ['universal']),
        'universal',
      );
    });
  });

  group('Windows update', skip: !Platform.isWindows ? 'Windows only' : null, () {
    late Directory root;
    late Directory install;
    late File journal;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fetchnet-update-test');
      install = Directory(p.join(root.path, 'install'))..createSync();
      journal = File(p.join(root.path, 'journal.txt'));
      for (final (name, text) in [
        ('FetchNet.exe', 'old exe'),
        ('flutter_windows.dll', 'old dll'),
        ('data/app.so', 'old app'),
        ('data/icudtl.dat', 'old icu'),
        ('only-in-old.dll', 'stays'),
      ]) {
        File(p.join(install.path, name))
          ..createSync(recursive: true)
          ..writeAsStringSync(text);
      }
    });

    tearDown(() => root.deleteSync(recursive: true));

    String zipOf(Map<String, String> files) {
      final archive = Archive();
      for (final e in files.entries) {
        final bytes = utf8.encode(e.value);
        archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
      }
      final path = p.join(root.path, 'update', 'FetchNet-v1.3.0-Windows-x64.zip');
      File(path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      return path;
    }

    String read(String name) => File(p.join(install.path, name)).readAsStringSync();

    test('puts the new files in place, keeps the old ones until confirmed', () async {
      final zip = zipOf({
        'Release/FetchNet.exe': 'new exe',
        'Release/flutter_windows.dll': 'new dll',
        'Release/data/app.so': 'new app',
        'Release/data/icudtl.dat': 'new icu',
        'Release/new-plugin.dll': 'added',
      });
      await WindowsSelfUpdate.applyZip(
        zip,
        const AppRelease(versionName: '1.3.0', buildNumber: 5),
        targetDir: install.path,
        journalFile: journal,
        exePath: p.join(install.path, 'FetchNet.exe'),
      );
      expect(read('FetchNet.exe'), 'new exe');
      expect(read('data/app.so'), 'new app');
      expect(read('new-plugin.dll'), 'added');
      expect(read('only-in-old.dll'), 'stays');
      expect(read('FetchNet.exe${WindowsSelfUpdate.backupSuffix}'), 'old exe');
      final lines = journal.readAsLinesSync();
      expect(lines, contains('state=applied'));
      expect(lines.where((l) => l.contains('|')).length, 5);

      // The new version started fine: the old files and the journal go.
      WindowsSelfUpdate.confirmStartup(journalFile: journal, dir: install.path);
      expect(journal.existsSync(), isFalse);
      expect(File(p.join(install.path, 'FetchNet.exe${WindowsSelfUpdate.backupSuffix}')).existsSync(), isFalse);
      expect(read('FetchNet.exe'), 'new exe');
    });

    test('a zip that isn\'t a complete FetchNet changes nothing', () async {
      final zip = zipOf({'FetchNet.exe': 'new exe', 'flutter_windows.dll': 'new dll'});
      await expectLater(
        WindowsSelfUpdate.applyZip(
          zip,
          const AppRelease(versionName: '1.3.0', buildNumber: 5),
          targetDir: install.path,
          journalFile: journal,
          exePath: p.join(install.path, 'FetchNet.exe'),
        ),
        throwsFormatException,
      );
      expect(read('FetchNet.exe'), 'old exe');
      expect(journal.existsSync(), isFalse);
    });
  });

  group('Updater popup', () {
    late AppServices services;
    final notes = ChangelogMarkdown.parse(File('CHANGELOG.md').readAsStringSync()).first;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      services = AppServices.create(await AppPrefs.load());
      services.updates.debugSetResult(
        state: UpdateState.available,
        installed: const AppRelease(versionName: '1.1.1', buildNumber: 3),
        update: PlatformUpdate(
          release: AppRelease(versionName: notes.version, buildNumber: notes.build),
          notes: notes,
          downloads: const {'universal': 'https://example.com/FetchNet.apk', 'installer': 'https://example.com/s.exe'},
        ),
      );
    });

    Future<void> open(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(
        services: services,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(child: TextButton(onPressed: () => showUpdaterDialog(context), child: const Text('open'))),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 600));
    }

    final phases = <(UpdaterPhase, String)>[
      (UpdaterPhase.idle, 'Download update'),
      (UpdaterPhase.downloading, 'Cancel'),
      (UpdaterPhase.needsPermission, 'Allow & install'),
      (UpdaterPhase.readyToRelaunch, 'Relaunch'),
      (UpdaterPhase.failed, 'Try again'),
    ];
    for (final (name, size) in [('phone', const Size(360, 740)), ('landscape phone', const Size(844, 390))]) {
      testWidgets('every step fits a $name screen, with the website always one tap away', (tester) async {
        await open(tester, size);
        expect(find.text('Update available'), findsOneWidget);
        expect(find.textContaining('v1.1.1'), findsOneWidget);
        for (final (phase, button) in phases) {
          services.updater.debugSet(
            phase,
            message: phase == UpdaterPhase.failed ? 'The update couldn\'t be installed: no connection.' : null,
            progress: 0.42,
            received: 31000000,
            total: 74000000,
            speed: 4200000,
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull, reason: '$phase');
          if (AppUpdater.supported) {
            expect(find.text(button), findsOneWidget, reason: '$phase');
          }
          if (phase == UpdaterPhase.failed || phase == UpdaterPhase.needsPermission) {
            expect(find.text('Open the update page'), findsOneWidget, reason: '$phase');
          }
        }
      });
    }
  });
}
