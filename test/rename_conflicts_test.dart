import 'dart:io';

import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/core/app_services.dart';
import 'package:fetchnet/core/theme.dart';
import 'package:fetchnet/features/home/rename_dialog.dart';
import 'package:fetchnet/models/download_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/extra_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppServices services;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    services = AppServices.create(await AppPrefs.load());
    dir = Directory.systemTemp.createTempSync('fetchnet-rename-');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  HistoryEntry entry(String name, {String url = 'https://example.com/other', String? path, MediaKind kind = MediaKind.video}) =>
      HistoryEntry(
        id: 'h-$name-$url',
        url: url,
        title: name,
        fileName: name,
        kind: kind,
        quality: '1080p',
        status: DownloadStatus.completed,
        createdAt: DateTime(2026, 11, 1),
        filePath: path,
      );

  const option = DownloadOption(kind: MediaKind.video, label: '1080p', extension: 'mp4', formatArgs: []);

  /// Opens the dialog for a video titled [title].
  Future<void> open(WidgetTester tester, String title, {String url = 'https://example.com/v'}) async {
    final info = MediaInfo(url: url, title: title, raw: const {});
    await tester.pumpWidget(AppScope(
      services: services,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showRenameDialog(context, info: info, option: option),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a name in History whose file was deleted must be changed', (tester) async {
    await tester.runAsync(() => services.history.add(entry('Beach day', path: p.join(dir.path, 'gone.mp4'))));
    await open(tester, 'Beach day');
    expect(find.textContaining('its file was deleted'), findsOneWidget);
    expect(find.text('Use "Beach day (2)"'), findsOneWidget);

    // Download keeps asking while the name is taken.
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.textContaining('its file was deleted'), findsOneWidget);

    // A new name clears it, and downloads.
    await tester.enterText(find.byType(TextField), 'Beach day at sunset');
    await tester.pumpAndSettle();
    expect(find.textContaining('its file was deleted'), findsNothing);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a name in History with its file still there is taken too', (tester) async {
    final file = File(p.join(dir.path, 'Lake.mp4'))..writeAsStringSync('x');
    await tester.runAsync(() => services.history.add(entry('Lake', path: file.path)));
    await open(tester, 'Lake');
    expect(find.text('A download in your History already uses this name.'), findsOneWidget);
  });

  testWidgets('the same video saved under another name: says so, and offers to download again', (tester) async {
    final file = File(p.join(dir.path, 'My clip.mp4'))..writeAsStringSync('x');
    await tester.runAsync(() => services.history.add(entry('My clip', url: 'https://example.com/v', path: file.path)));
    await open(tester, 'Original title');
    expect(find.textContaining('You already saved this video as “My clip.mp4”'), findsOneWidget);
    expect(find.text('Download again'), findsOneWidget);
    // The name itself is free.
    expect(find.textContaining('already uses this name'), findsNothing);
  });

  testWidgets('audio of a video saved before isn\'t a copy, and its name is free', (tester) async {
    final file = File(p.join(dir.path, 'Song.mp3'))..writeAsStringSync('x');
    await tester.runAsync(
      () => services.history.add(entry('Song', url: 'https://example.com/v', path: file.path, kind: MediaKind.audio)),
    );
    await open(tester, 'Song');
    expect(find.textContaining('You already saved'), findsNothing);
    expect(find.textContaining('already uses this name'), findsNothing);
  });

  test('downloads queued without the dialog skip History\'s names', () async {
    await services.history.add(entry('Beach day', path: p.join(dir.path, 'gone.mp4')));
    expect(services.downloads.takenNames(MediaKind.video), contains('beach day'));
    expect(services.downloads.takenNames(MediaKind.audio), isNot(contains('beach day')));
  });

  test('Merge into the video and Also keep separate files map to how subtitles are saved', () async {
    final s = ExtraSettings(await SharedPreferences.getInstance());
    expect(s.mergeSubtitles, isFalse);
    await s.setMergeSubtitles(true);
    expect(s.subtitleMode, SubtitleMode.embed);
    await s.setKeepSubtitleFiles(true);
    expect(s.subtitleMode, SubtitleMode.both);
    await s.setMergeSubtitles(false);
    expect(s.subtitleMode, SubtitleMode.file);
    expect(s.keepSubtitleFiles, isFalse);
  });
}
