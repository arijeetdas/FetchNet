import 'dart:io';

import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/core/app_services.dart';
import 'package:fetchnet/core/theme.dart';
import 'package:fetchnet/features/downloads/downloads_screen.dart';
import 'package:fetchnet/models/download_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppServices> services(WidgetTester tester, {bool files = true}) async {
    SharedPreferences.setMockInitialValues({});
    final s = AppServices.create(await AppPrefs.load());
    final tmp = Directory.systemTemp.createTempSync('downloads_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    await tester.runAsync(() async {
      await s.storage.chooseFolder(tmp.path);
      if (!files) return;
      final now = DateTime.now();
      for (final (i, (name, kind)) in [
        ('Video/Clip.mp4', MediaKind.video),
        ('Audio/Song.mp3', MediaKind.audio),
        ('Audio/Song from a video.webm', MediaKind.audio),
      ].indexed) {
        final f = File('${tmp.path}/$name')..writeAsStringSync('x');
        await s.history.add(HistoryEntry(
          id: '$i',
          url: 'https://example.com/$i',
          title: name,
          fileName: name,
          kind: kind,
          quality: '',
          status: DownloadStatus.completed,
          createdAt: now,
          completedAt: now,
          filePath: f.path,
        ));
      }
    });
    tester.view.physicalSize = const Size(412, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
      services: s,
      child: MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: DownloadsScreen())),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    return s;
  }

  testWidgets('saved files filter by kind', (tester) async {
    await services(tester);
    expect(find.text('Clip.mp4'), findsOneWidget);
    expect(find.text('Song.mp3'), findsOneWidget);

    // A song saved as .webm still counts as music.
    await tester.tap(find.text('Music').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Clip.mp4'), findsNothing);
    expect(find.text('Song.mp3'), findsOneWidget);
    expect(find.text('Song from a video.webm'), findsOneWidget);

    await tester.tap(find.text('Pictures'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No pictures yet'), findsOneWidget);
    await tester.tap(find.text('Show everything'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Clip.mp4'), findsOneWidget);
  });

  testWidgets('empty page offers to find something', (tester) async {
    final s = await services(tester, files: false);
    expect(find.text('Nothing here yet'), findsOneWidget);
    s.tabRequest.value = 2;
    await tester.tap(find.text('Find something to download'));
    expect(s.tabRequest.value, 0);
  });
}
