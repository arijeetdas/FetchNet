import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/core/app_services.dart';
import 'package:fetchnet/core/theme.dart';
import 'package:fetchnet/engine/engine.dart';
import 'package:fetchnet/features/home/home_screen.dart';
import 'package:fetchnet/features/home/media_result_view.dart';
import 'package:fetchnet/features/home/post_result_view.dart';
import 'package:fetchnet/models/gallery_models.dart';
import 'package:fetchnet/models/media_info.dart';
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

  Future<void> pump(WidgetTester tester, Size size, Widget home, {bool dark = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(
      services: services,
      child: MaterialApp(theme: dark ? AppTheme.dark() : AppTheme.light(), home: home),
    ));
    // Let the entrance animations finish (the living logo keeps going, so
    // no pumpAndSettle).
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget scrolling(Widget child) => Scaffold(
        body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
      );

  const sizes = [('phone', Size(360, 800)), ('desktop', Size(1280, 900))];

  for (final (name, size) in sizes) {
    testWidgets('Home shows engine setup, the link dock and the sites on a $name screen', (tester) async {
      services.engine.status.value = const EngineStatus(state: EngineState.installing, progress: 0.4);
      services.gallery.engine.status.value =
          const EngineStatus(state: EngineState.error, message: 'Couldn\'t set up gallery-dl: no connection');
      await pump(tester, size, const Scaffold(body: HomeScreen()), dark: name == 'desktop');
      expect(tester.takeException(), isNull);

      expect(find.text('Downloading yt-dlp · 40%'), findsOneWidget);
      expect(find.text('Images & posts aren\'t ready'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Paste a link. Pick a quality. Done.'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Thumbnails & tags'), 200, scrollable: find.byType(Scrollable).first);
      expect(tester.takeException(), isNull);

      // Typing a link shows where it's from; Fetch waits for yt-dlp.
      await tester.enterText(find.byType(TextField), 'https://youtu.be/dQw4w9WgXcQ');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('YouTube'), findsWidgets);
      expect(find.text('Waiting for yt-dlp…'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Browser Mode'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Popular sites'), findsOneWidget);
      expect(find.text('Add site'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a ready engine clears the deck on a $name screen', (tester) async {
      services.engine.status.value = const EngineStatus(state: EngineState.ready, version: '2026.11.01', ffmpegAvailable: true);
      services.gallery.engine.status.value = const EngineStatus(state: EngineState.ready, version: '1.32.20');
      await pump(tester, size, const Scaffold(body: HomeScreen()));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('yt-dlp ·'), findsNothing);
      await tester.enterText(find.byType(TextField), 'https://example.com/v');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Fetch'), findsOneWidget);
    });

    testWidgets('a video offers quality, format and size cards on a $name screen', (tester) async {
      services.engine.status.value = const EngineStatus(state: EngineState.ready, ffmpegAvailable: true);
      const json = '''
{"title":"Demo video with a long title that needs to wrap onto more than one line","webpage_url":"https://example.com/v",
 "duration":100,"extractor_key":"Example","uploader":"Someone","view_count":123456,
 "formats":[
  {"format_id":"a1","vcodec":"none","acodec":"opus","abr":130,"ext":"webm","filesize":1600000},
  {"format_id":"v4","vcodec":"avc1","acodec":"none","height":2160,"fps":60,"ext":"mp4","filesize":250000000},
  {"format_id":"v1","vcodec":"avc1","acodec":"none","height":1080,"fps":60,"ext":"mp4","filesize":50000000},
  {"format_id":"v3","vcodec":"avc1","acodec":"none","height":720,"fps":30,"ext":"mp4","filesize":20000000},
  {"format_id":"v2","vcodec":"avc1","acodec":"mp4a","height":360,"fps":30,"ext":"mp4","filesize":8000000}
 ]}''';
      final info = MediaInfo.parse(json, sourceUrl: 'https://example.com/v');
      await pump(tester, size, scrolling(MediaResultView(info: info)));
      expect(tester.takeException(), isNull);

      expect(find.text('Pick a quality'), findsOneWidget);
      expect(find.text('2160p'), findsOneWidget);
      expect(find.text('4K'), findsOneWidget);
      // The quick download preset (1080p by default) is picked first.
      expect(find.textContaining('Download 1080p'), findsOneWidget);
      // "Best available" picks the highest.
      await services.extras.setPresetVideoHeight(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Download 2160p'), findsOneWidget);

      // Picking another card updates the button.
      await tester.tap(find.text('720p'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Download 720p'), findsOneWidget);

      // The Audio segment slides over to the formats.
      await tester.tap(find.text('Audio'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Pick a format'), findsOneWidget);
      expect(find.text('MP3'), findsWidgets);
      expect(find.text('M4A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a post lists, filters and picks its files on a $name screen', (tester) async {
      services.gallery.engine.status.value = const EngineStatus(state: EngineState.ready);
      final post = GalleryPost(
        url: 'https://example.com/p/1',
        title: 'A trip to the mountains',
        author: 'someone',
        site: 'Example',
        description: 'Five files from the weekend.',
        items: [
          for (var i = 1; i <= 4; i++)
            GalleryItem(
              index: i,
              url: 'https://example.com/$i.jpg',
              kind: GalleryItemKind.image,
              extension: 'jpg',
              width: 1080,
              height: 1350,
              sizeBytes: 400000,
            ),
          const GalleryItem(
            index: 5,
            url: 'https://example.com/5.mp4',
            kind: GalleryItemKind.video,
            extension: 'mp4',
            duration: 12,
            sizeBytes: 3000000,
          ),
        ],
      );
      final semantics = tester.ensureSemantics();
      await pump(tester, size, scrolling(PostResultView(post: post, onOpenChild: (_) {})));
      expect(tester.takeException(), isNull);

      expect(find.text('5 of 5 selected'), findsOneWidget);
      expect(find.textContaining('Download 5 files'), findsOneWidget);

      // Tap a file to leave it out.
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Image 2')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('4 of 5 selected'), findsOneWidget);

      // Filter to videos, then select none of them.
      await tester.tap(find.text('Video'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('None'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('3 of 5 selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }
}
