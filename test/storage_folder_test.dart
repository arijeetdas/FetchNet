import 'dart:io';

import 'package:fetchnet/features/settings/save_location_card.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late SharedPreferences prefs;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fetchnet_folder_test');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('chooseFolder', () {
    test('makes all three subfolders in a new folder', () async {
      final storage = StorageService(prefs);
      final target = p.join(tmp.path, 'Clips');
      final change = await storage.chooseFolder(target);
      expect(change.ok, isTrue);
      expect(change.created, ['Images', 'Audio', 'Video']);
      for (final f in ['Images', 'Audio', 'Video']) {
        expect(Directory(p.join(target, f)).existsSync(), isTrue);
      }
      expect(storage.downloadDir, p.normalize(target));
      expect(storage.isCustom, isTrue);
      expect(prefs.getString('downloads.custom_dir'), p.normalize(target));
    });

    test('makes only the missing subfolders and keeps what is there', () async {
      final target = Directory(p.join(tmp.path, 'Media'))..createSync();
      final audio = Directory(p.join(target.path, 'Audio'))..createSync();
      final song = File(p.join(audio.path, 'song.mp3'))..writeAsStringSync('tune');
      final storage = StorageService(prefs);
      final change = await storage.chooseFolder(target.path);
      expect(change.ok, isTrue);
      expect(change.created, ['Images', 'Video']);
      expect(song.readAsStringSync(), 'tune');
      expect(audio.listSync().map((e) => p.basename(e.path)), ['song.mp3'], reason: 'no test files left behind');
    });

    test('nothing is made when every subfolder is there', () async {
      final target = p.join(tmp.path, 'Full');
      for (final f in ['Images', 'Audio', 'Video']) {
        Directory(p.join(target, f)).createSync(recursive: true);
      }
      final change = await StorageService(prefs).chooseFolder(target);
      expect(change.ok, isTrue);
      expect(change.created, isEmpty);
    });

    test('a folder that cannot be made is refused and nothing changes', () async {
      final blocker = File(p.join(tmp.path, 'blocker'))..writeAsStringSync('');
      final storage = StorageService(prefs);
      final change = await storage.chooseFolder(p.join(blocker.path, 'inside'));
      expect(change.ok, isFalse);
      expect(change.error, contains('can\'t be used'));
      expect(storage.isCustom, isFalse);
      expect(storage.downloadDir, isNull);
    });

    test('without settings storage it reports an error', () async {
      final change = await StorageService().chooseFolder(tmp.path);
      expect(change.ok, isFalse);
    });

    test('the chosen folder is used again on the next start', () async {
      final target = p.join(tmp.path, 'Saved');
      await StorageService(prefs).chooseFolder(target);
      Directory(p.join(target, 'Video')).deleteSync();
      final next = StorageService(prefs);
      expect(await next.ensureDownloadDir(), p.normalize(target));
      expect(next.customProblem, isNull);
      expect(Directory(p.join(target, 'Video')).existsSync(), isTrue, reason: 'a removed subfolder is made again');
    });
  });

  test('useDefaultFolder forgets the chosen folder', () async {
    final storage = StorageService(prefs);
    await storage.chooseFolder(p.join(tmp.path, 'Mine'));
    try {
      await storage.useDefaultFolder();
    } catch (_) {
      // The default folder needs the platform's Downloads path.
    }
    expect(storage.isCustom, isFalse);
    expect(prefs.getString('downloads.custom_dir'), isNull);
  });

  test('shortName shows the end of the folder', () async {
    final storage = StorageService(prefs);
    expect(storage.shortName(), 'Download/FetchNet');
    final target = p.join(tmp.path, 'Media', 'Clips');
    await storage.chooseFolder(target);
    expect(storage.shortName(), 'Media/Clips');
    expect(storage.shortName(MediaKind.audio), 'Media/Clips/Audio');
    expect(storage.shortName(MediaKind.thumbnail), 'Media/Clips/Images');
  });

  group('folderPathOf', () {
    test('phone storage folders', () {
      expect(
        folderPathOf(Uri.parse('content://com.android.externalstorage.documents/tree/primary%3ADownload%2FClips')),
        '/storage/emulated/0/Download/Clips',
      );
      expect(folderPathOf(Uri.parse('content://com.android.externalstorage.documents/tree/primary%3ADocuments')),
          '/storage/emulated/0/Documents');
      expect(folderPathOf(Uri.parse('content://com.android.externalstorage.documents/tree/primary%3A')), '/storage/emulated/0');
    });

    test('the Downloads app', () {
      expect(folderPathOf(Uri.parse('content://com.android.providers.downloads.documents/tree/downloads')),
          '/storage/emulated/0/Download');
      expect(
        folderPathOf(Uri.parse('content://com.android.providers.downloads.documents/tree/raw%3A%2Fstorage%2Femulated%2F0%2FDownload%2FX')),
        '/storage/emulated/0/Download/X',
      );
    });

    test('memory cards and other apps are refused', () {
      expect(folderPathOf(Uri.parse('content://com.android.externalstorage.documents/tree/1A2B-3C4D%3AMusic')), isNull);
      expect(folderPathOf(Uri.parse('content://com.google.android.apps.docs.storage/tree/abc')), isNull);
      expect(folderPathOf(Uri.parse('https://example.com/x')), isNull);
    });

    test('file paths as they are', () {
      final dir = p.join(Directory.systemTemp.path, 'x');
      expect(folderPathOf(Uri.file(dir)), dir);
      expect(folderPathOf(Uri(path: '/home/me/Videos')), '/home/me/Videos');
    });
  });
}
