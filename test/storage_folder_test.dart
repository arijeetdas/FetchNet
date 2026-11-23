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
    test('makes a FetchNet folder in the chosen one, with its three subfolders', () async {
      final storage = StorageService(prefs);
      final picked = p.join(tmp.path, 'Clips');
      final fetchNet = p.join(picked, 'FetchNet');
      final change = await storage.chooseFolder(picked);
      expect(change.ok, isTrue);
      expect(change.created, ['FetchNet', 'Images', 'Audio', 'Video']);
      for (final f in ['Images', 'Audio', 'Video']) {
        expect(Directory(p.join(fetchNet, f)).existsSync(), isTrue);
        expect(Directory(p.join(picked, f)).existsSync(), isFalse, reason: 'never straight in the chosen folder');
      }
      expect(storage.downloadDir, fetchNet);
      expect(storage.isCustom, isTrue);
      expect(prefs.getString('downloads.custom_dir'), fetchNet);
    });

    test('a folder that already is a FetchNet folder is used as it is', () async {
      final picked = p.join(tmp.path, 'Media', 'FetchNet');
      final storage = StorageService(prefs);
      await storage.chooseFolder(picked);
      expect(storage.downloadDir, p.normalize(picked));
      expect(Directory(p.join(picked, 'FetchNet')).existsSync(), isFalse);
      expect(StorageService.fetchNetFolderIn('${p.join(tmp.path, 'x', 'fetchnet')}${p.separator}'), p.join(tmp.path, 'x', 'fetchnet'));
    });

    test('makes only the missing folders and keeps what is there', () async {
      final picked = Directory(p.join(tmp.path, 'Media'))..createSync();
      final audio = Directory(p.join(picked.path, 'FetchNet', 'Audio'))..createSync(recursive: true);
      final song = File(p.join(audio.path, 'song.mp3'))..writeAsStringSync('tune');
      final storage = StorageService(prefs);
      final change = await storage.chooseFolder(picked.path);
      expect(change.ok, isTrue);
      expect(change.created, ['Images', 'Video']);
      expect(song.readAsStringSync(), 'tune');
      expect(audio.listSync().map((e) => p.basename(e.path)), ['song.mp3'], reason: 'no test files left behind');
    });

    test('nothing is made when every folder is there', () async {
      final picked = p.join(tmp.path, 'Full');
      for (final f in ['Images', 'Audio', 'Video']) {
        Directory(p.join(picked, 'FetchNet', f)).createSync(recursive: true);
      }
      final change = await StorageService(prefs).chooseFolder(picked);
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
      final picked = p.join(tmp.path, 'Saved');
      final fetchNet = p.join(picked, 'FetchNet');
      await StorageService(prefs).chooseFolder(picked);
      Directory(p.join(fetchNet, 'Video')).deleteSync();
      final next = StorageService(prefs);
      expect(await next.ensureDownloadDir(), fetchNet);
      expect(next.customProblem, isNull);
      expect(Directory(p.join(fetchNet, 'Video')).existsSync(), isTrue, reason: 'a removed subfolder is made again');
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
    await storage.chooseFolder(p.join(tmp.path, 'Media', 'Clips'));
    expect(storage.shortName(), 'Clips/FetchNet');
    expect(storage.shortName(MediaKind.audio), 'Clips/FetchNet/Audio');
    expect(storage.shortName(MediaKind.thumbnail), 'Clips/FetchNet/Images');
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
