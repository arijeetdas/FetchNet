import 'dart:io';

import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/core/app_services.dart';
import 'package:fetchnet/core/theme.dart';
import 'package:fetchnet/features/history/clear_history_dialog.dart';
import 'package:fetchnet/features/history/history_screen.dart';
import 'package:fetchnet/models/download_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('historyGroupOf', () {
    final now = DateTime(2026, 11, 23, 10);
    test('recent days', () {
      expect(historyGroupOf(DateTime(2026, 11, 23, 0, 5), now), 'Today');
      expect(historyGroupOf(DateTime(2026, 11, 22, 23, 59), now), 'Yesterday');
      expect(historyGroupOf(DateTime(2026, 11, 17), now), 'Last 7 days');
      expect(historyGroupOf(DateTime(2026, 11, 2), now), 'Earlier this month');
    });
    test('older ones by month', () {
      expect(historyGroupOf(DateTime(2026, 10, 30), now), 'October 2026');
      expect(historyGroupOf(DateTime(2025, 1, 4), now), 'January 2025');
    });
  });

  testWidgets('filters, search and the details sheet', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('history_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final song = File('${tmp.path}/Song.mp3')..writeAsStringSync('x');
    SharedPreferences.setMockInitialValues({});
    final services = AppServices.create(await AppPrefs.load());
    final now = DateTime.now();
    await services.history.add(HistoryEntry(
      id: 'f',
      url: 'https://example.com/v',
      title: 'Broken video',
      fileName: 'Broken',
      kind: MediaKind.video,
      quality: '1080p',
      status: DownloadStatus.failed,
      createdAt: now,
      error: 'HTTP Error 403: Forbidden',
    ));
    await services.history.add(HistoryEntry(
      id: 's',
      url: 'https://example.com/a',
      title: 'Nice song',
      fileName: 'Song',
      kind: MediaKind.audio,
      quality: 'MP3',
      status: DownloadStatus.completed,
      createdAt: now,
      completedAt: now,
      filePath: song.path,
    ));
    tester.view.physicalSize = const Size(412, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
      services: services,
      child: MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: HistoryScreen())),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Nice song'), findsOneWidget);
    expect(find.text('Broken video'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);

    // Only the failed one.
    await tester.tap(find.text('Failed').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Nice song'), findsNothing);
    expect(find.text('Broken video'), findsOneWidget);

    // Its details say why it failed and offer to try again.
    await tester.tap(find.text('Broken video'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Why it failed'), findsOneWidget);
    expect(find.text('HTTP Error 403: Forbidden'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    // Remove takes it out of the history.
    await tester.ensureVisible(find.text('Remove'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Remove'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(services.history.entries.map((e) => e.id), ['s']);

    // A search with no match offers to show everything.
    await tester.tap(find.text('All').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'nothing like this');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No matches'), findsOneWidget);
    await tester.tap(find.text('Show everything'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Nice song'), findsOneWidget);

    // A saved song plays from its details.
    await tester.tap(find.text('Nice song'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Delete file'), findsOneWidget);
  });

  testWidgets('Clear removes only what was picked, and Undo puts it back', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final services = AppServices.create(await AppPrefs.load());
    final now = DateTime.now();
    HistoryEntry entry(String id, DownloadStatus status, {int daysAgo = 0}) => HistoryEntry(
          id: id,
          url: 'https://example.com/$id',
          title: 'Item $id',
          fileName: id,
          kind: MediaKind.video,
          quality: '720p',
          status: status,
          createdAt: now.subtract(Duration(days: daysAgo)),
        );
    for (final e in [
      entry('old', DownloadStatus.cancelled, daysAgo: 45),
      entry('failed', DownloadStatus.failed, daysAgo: 1),
      entry('gone', DownloadStatus.completed),
    ]) {
      await services.history.add(e);
    }
    tester.view.physicalSize = const Size(412, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
      services: services,
      child: MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: HistoryScreen())),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('Clear'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Clear history'), findsOneWidget);
    expect(find.text('Clear 3'), findsOneWidget);

    await tester.tap(find.text(ClearScope.unfinished.title));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Clear 2'), findsOneWidget);
    await tester.tap(find.text('Clear 2'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(services.history.entries.map((e) => e.id), ['gone']);
    expect(find.text('Cleared 2 downloads from history'), findsOneWidget);

    await services.history.restore([entry('old', DownloadStatus.cancelled, daysAgo: 45), entry('failed', DownloadStatus.failed, daysAgo: 1)]);
    expect(services.history.entries.map((e) => e.id), ['gone', 'failed', 'old']);
    await tester.pump(const Duration(seconds: 6));
  });

  test('clear scopes', () {
    final now = DateTime(2026, 11, 23);
    HistoryEntry e(DownloadStatus s, DateTime at, {String? path}) => HistoryEntry(
          id: '$s$at',
          url: 'u',
          title: 't',
          fileName: 'f',
          kind: MediaKind.audio,
          quality: '',
          status: s,
          createdAt: at,
          filePath: path,
        );
    final recentSaved = e(DownloadStatus.completed, DateTime(2026, 11, 20), path: Directory.systemTemp.path);
    final missing = e(DownloadStatus.completed, DateTime(2026, 11, 20), path: '/no/such/file.mp3');
    final failed = e(DownloadStatus.failed, DateTime(2026, 9, 1));
    expect(ClearScope.unfinished.picks(failed, now), isTrue);
    expect(ClearScope.unfinished.picks(missing, now), isFalse);
    expect(ClearScope.missing.picks(missing, now), isTrue);
    expect(ClearScope.older.picks(failed, now), isTrue);
    expect(ClearScope.older.picks(recentSaved, now), isFalse);
    expect(ClearScope.everything.picks(recentSaved, now), isTrue);
  });
}
