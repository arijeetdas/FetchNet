import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/core/app_services.dart';
import 'package:fetchnet/core/theme.dart';
import 'package:fetchnet/engine/engine.dart';
import 'package:fetchnet/features/settings/engines_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppServices services;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Services only; the engines aren't started (no network in tests).
    services = AppServices.create(await AppPrefs.load());
  });

  Future<void> pumpScreen(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
      services: services,
      child: MaterialApp(theme: AppTheme.light(), home: const EnginesScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final (name, size) in [('phone', const Size(360, 800)), ('desktop', const Size(1280, 900))]) {
    testWidgets('both engines, their facts, updates and links fit a $name screen', (tester) async {
      services.engine.status.value = const EngineStatus(state: EngineState.ready, version: '2026.11.01');
      services.gallery.engine.status.value =
          const EngineStatus(state: EngineState.error, message: 'Couldn\'t set up gallery-dl: no connection');
      await pumpScreen(tester, size);
      expect(tester.takeException(), isNull);

      expect(find.text('Video & audio · yt-dlp'.toUpperCase()), findsOneWidget);
      expect(find.text('Images & posts · gallery-dl'.toUpperCase()), findsOneWidget);
      expect(find.text('2026.11.01'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Check for updates'), findsOneWidget);

      // A failed setup offers a retry instead.
      await tester.scrollUntilVisible(find.text('Retry setup'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Needs attention'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('codeberg.org/mikf/gallery-dl'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Source code'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('gallery-dl turned off says so and can\'t be updated', (tester) async {
    await services.prefs.setGalleryEnabled(false);
    services.engine.status.value = const EngineStatus(state: EngineState.ready, version: '2026.11.01');
    services.gallery.engine.status.value = const EngineStatus(state: EngineState.ready, version: '1.32.20');
    await pumpScreen(tester, const Size(390, 844));
    await tester.scrollUntilVisible(
      find.textContaining('Turn on "Images & posts"'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Off'), findsOneWidget);
  });
}
