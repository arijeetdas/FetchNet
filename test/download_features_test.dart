import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/engine/engine.dart';
import 'package:fetchnet/models/download_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/download_manager.dart';
import 'package:fetchnet/services/extra_settings.dart';
import 'package:fetchnet/services/history_store.dart';
import 'package:fetchnet/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A yt-dlp run that ends when the test says so.
class _Run extends EngineRun {
  _Run(this.args);

  final List<String> args;
  final _lines = StreamController<String>.broadcast();
  final _done = Completer<EngineResult>();

  void finish(int code, {String stderr = ''}) {
    if (!_done.isCompleted) _done.complete(EngineResult(exitCode: code, stdout: '', stderr: stderr));
  }

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<EngineResult> get done => _done.future;

  @override
  Future<void> cancel() async => finish(EngineRun.cancelledExitCode);
}

class _Engine extends YtDlpEngine {
  _Engine(super.prefs) {
    status.value = const EngineStatus(state: EngineState.ready, ffmpegAvailable: true);
  }

  /// Every run started, by task id (a resumed task starts again).
  final Map<String, List<_Run>> runs = {};

  _Run last(String id) => runs[id]!.last;
  int get running => runs.values.expand((r) => r).where((r) => !r._done.isCompleted).length;

  @override
  Future<void> initialize() async {}

  @override
  Future<EngineResult> run(List<String> args, {String? id}) async =>
      const EngineResult(exitCode: 1, stdout: '', stderr: 'not in tests');

  @override
  EngineRun start(String id, List<String> args) {
    final run = _Run(args);
    (runs[id] ??= []).add(run);
    return run;
  }

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<String> update() async => '';
}

/// Storage in a temporary folder (no path_provider in tests).
class _Storage extends StorageService {
  _Storage(this.root);

  final Directory root;

  @override
  String? get downloadDir => root.path;

  @override
  Future<String?> ensureDownloadDir({bool requestPermission = false}) async => root.path;

  @override
  String? dirForKind(MediaKind? kind) => root.path;

  @override
  Future<Directory> workDir(String name) async {
    final d = Directory(p.join(root.path, '.work', name));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late AppPrefs prefs;
  late ExtraSettings extras;
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPrefs.load();
    extras = ExtraSettings(prefs.store);
    root = Directory.systemTemp.createTempSync('fetchnet-test-');
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  const video = DownloadOption(kind: MediaKind.video, label: '1080p', extension: 'mp4', formatArgs: ['-f', 'b']);
  const audio = DownloadOption(kind: MediaKind.audio, label: 'MP3', extension: 'mp3', formatArgs: ['-x']);

  group('Subtitles', () {
    test('are off until turned on, and only for videos', () async {
      expect(subtitleArgs(extras, option: video, ffmpeg: true), isEmpty);
      await extras.setSubtitles(true);
      expect(subtitleArgs(extras, option: audio, ffmpeg: true), isEmpty);
      expect(subtitleArgs(extras, option: video, ffmpeg: true), isNotEmpty);
    });

    test('follow the format, languages and how they are saved', () async {
      await extras.setSubtitles(true);
      var args = subtitleArgs(extras, option: video, ffmpeg: true);
      expect(args, containsAllInOrder(['--write-subs', '--write-auto-subs', '--sub-langs', 'en(-.+)?,-live_chat']));
      expect(args, containsAllInOrder(['--sub-format', 'srt/best', '--convert-subs', 'srt']));
      expect(args, isNot(contains('--embed-subs')));

      await extras.setSubtitleFormat(SubtitleFormat.vtt);
      await extras.setSubtitleLanguageCodes(['en', 'hi']);
      await extras.setAutoCaptions(false);
      await extras.setSubtitleMode(SubtitleMode.embed);
      args = subtitleArgs(extras, option: video, ffmpeg: true);
      expect(args, containsAllInOrder(['--sub-langs', 'en(-.+)?,hi(-.+)?,-live_chat']));
      expect(args, containsAllInOrder(['--embed-subs', '--compat-options', 'no-keep-subs']));
      expect(args, isNot(contains('--write-auto-subs')));
      expect(args, containsAllInOrder(['--sub-format', 'vtt/best', '--convert-subs', 'vtt']));

      // Without FFmpeg: nothing to convert or embed with, so plain files.
      args = subtitleArgs(extras, option: video, ffmpeg: false);
      expect(args, isNot(contains('--embed-subs')));
      expect(args, isNot(contains('--convert-subs')));
      expect(args, contains('--write-subs'));

      await extras.setSubtitleLanguageCodes(['all']);
      args = subtitleArgs(extras, option: video, ffmpeg: true);
      expect(args, containsAllInOrder(['--sub-langs', 'all,-live_chat']));
    });

    test('a video\'s own picks replace the settings, and none means none', () async {
      await extras.setSubtitles(true);
      expect(subtitleArgs(extras, option: video, ffmpeg: true, languages: const []), isEmpty);
      final args = subtitleArgs(extras, option: video, ffmpeg: true, languages: const ['en-US', 'hi-orig']);
      expect(args, containsAllInOrder(['--sub-langs', 'en-US,hi-orig,-live_chat']));
    });

    test('tracks: a video\'s own subtitles, then useful automatic captions', () async {
      final info = MediaInfo(url: 'u', title: 't', raw: {
        'language': 'hi',
        'subtitles': {
          'en-US': [
            {'name': 'English (US)'},
          ],
          'live_chat': [{}],
        },
        'automatic_captions': {
          'en': [{}],
          'hi-orig': [
            {'name': 'Hindi (Original)'},
          ],
          'hi': [{}],
          'fr': [{}],
          'de': [{}],
        },
      });
      final tracks = subtitleTracksOf(info, wanted: const ['en', 'fr']);
      expect([for (final t in tracks) t.code], ['en-US', 'hi-orig', 'fr']);
      expect(tracks.first.name, 'English (US)');
      expect(tracks.first.automatic, isFalse);
      expect(tracks[1].automatic, isTrue);

      await extras.setSubtitleLanguageCodes(['en', 'fr']);
      expect(defaultSubtitlePicks(tracks, extras), {'en-US', 'fr'});
      await extras.setAutoCaptions(false);
      expect(defaultSubtitlePicks(tracks, extras), {'en-US'});
    });
  });

  group('Quick download presets', () {
    final videos = [
      for (final h in [2160, 1440, 1080, 720, 360])
        DownloadOption(kind: MediaKind.video, label: '${h}p', extension: 'mp4', formatArgs: const []),
    ];

    test('pick the preset quality, or the closest one below it', () {
      expect(presetVideoIndex(videos, 0), 0);
      expect(presetVideoIndex(videos, 1080), 2);
      expect(presetVideoIndex(videos, 480), 4);
      expect(presetVideoIndex(videos, 240), 4);
    });

    test('pick the preset audio format', () {
      const audios = [
        DownloadOption(kind: MediaKind.audio, label: 'MP3', detail: '320 kbps', extension: 'mp3', formatArgs: []),
        DownloadOption(kind: MediaKind.audio, label: 'MP3', detail: '192 kbps', extension: 'mp3', formatArgs: []),
        DownloadOption(kind: MediaKind.audio, label: 'M4A', extension: 'm4a', formatArgs: []),
      ];
      expect(presetAudioIndex(audios, AudioPreset.mp3Medium), 1);
      expect(presetAudioIndex(audios, AudioPreset.m4a), 2);
      expect(presetAudioIndex(audios, AudioPreset.original), 0);
    });

    test('download options for videos that weren\'t looked up', () {
      final v = presetVideoOption(720, ffmpeg: true);
      expect(v.formatArgs.join(' '), contains('[height<=720]'));
      expect(v.formatArgs, containsAllInOrder(['--merge-output-format', 'mp4']));
      expect(presetVideoOption(0, ffmpeg: false).formatArgs, ['-f', 'b/b']);
      expect(presetAudioOption(AudioPreset.mp3Low, ffmpeg: true).formatArgs, contains('128K'));
      expect(presetAudioOption(AudioPreset.mp3Low, ffmpeg: false).label, 'Original');
    });

    test('settings keep their values', () async {
      expect(extras.maxConcurrent, 3);
      await extras.setMaxConcurrent(25);
      expect(extras.maxConcurrent, ExtraSettings.maxConcurrentLimit);
      await extras.setSpeedLimitKbps(2048);
      expect(extras.rateArg, '2M');
      await extras.setSpeedLimitKbps(512);
      expect(extras.rateArg, '512K');
    });
  });

  group('Playlists', () {
    test('a page lists its videos; a channel\'s tabs are lists of their own', () {
      final info = MediaInfo.parse(
        jsonEncode({
          '_type': 'playlist',
          'title': 'Someone - Videos',
          'playlist_count': 1234,
          'entries': [
            {'url': 'https://www.youtube.com/watch?v=a', 'title': 'A', 'id': 'a', 'view_count': 5, 'channel': 'Someone'},
            {'url': 'https://www.youtube.com/@someone/shorts', 'title': 'Shorts', '_type': 'url', 'ie_key': 'YoutubeTab'},
          ],
        }),
        sourceUrl: 'https://www.youtube.com/@someone/videos',
      );
      expect(info.isPlaylist, isTrue);
      expect(info.playlistCount, 1234);
      expect(info.entries.first.isList, isFalse);
      expect(info.entries.first.channel, 'Someone');
      expect(info.entries.last.isList, isTrue);
    });
  });

  group('Saved queue', () {
    test('tasks round-trip; running ones restart, cookies aren\'t kept', () {
      final task = DownloadTask(
        id: 'dl-1',
        url: 'https://example.com/v',
        title: 'T',
        fileBaseName: 'T',
        option: const DownloadOption(
          kind: MediaKind.post,
          label: 'Files',
          extension: '',
          formatArgs: [],
          gallery: GalleryDownload(count: 3, range: '1-3'),
        ),
        requestArgs: ['--cookies', '/tmp/c.txt', '--user-agent', 'UA'],
        subtitleArgs: ['--write-subs'],
      )..status = DownloadStatus.downloading;
      final back = DownloadTask.fromJson(jsonDecode(jsonEncode(task.toJson())) as Map<String, dynamic>)!;
      expect(back.status, DownloadStatus.queued);
      expect(back.requestArgs, ['--user-agent', 'UA']);
      expect(back.subtitleArgs, ['--write-subs']);
      expect(back.option.gallery!.range, '1-3');
      expect(back.option.kind, MediaKind.post);

      task.status = DownloadStatus.paused;
      expect(DownloadTask.fromJson(task.toJson())!.status, DownloadStatus.paused);
    });
  });

  group('Download queue', () {
    late _Engine engine;
    late DownloadManager manager;
    var saved = <String>[];
    var wifi = true;

    DownloadManager create() => DownloadManager(
          engine: engine,
          storage: _Storage(root),
          history: HistoryStore(prefs),
          settings: extras,
          queueStore: QueueStore(load: () => saved, save: (v) async => saved = v),
          onWifi: () async => wifi,
        );

    setUp(() {
      engine = _Engine(prefs);
      saved = [];
      wifi = true;
      manager = create();
    });

    Future<void> enqueue(String name, {List<String> subtitleArgs = const []}) => manager.enqueue(
          info: MediaInfo(url: 'https://example.com/$name', title: name, raw: const {}),
          option: video,
          fileBaseName: name,
          subtitleArgs: subtitleArgs,
        );

    test('runs as many at once as the setting allows, live', () async {
      await extras.setMaxConcurrent(2);
      for (final n in ['a', 'b', 'c', 'd']) {
        await enqueue(n);
      }
      await _settle();
      expect(engine.running, 2);
      expect(manager.tasks.where((t) => t.status == DownloadStatus.queued), hasLength(2));

      await extras.setMaxConcurrent(4);
      await _settle();
      expect(engine.running, 4);
    });

    test('pause keeps the partial download; resume carries on in the same folder', () async {
      await enqueue('a');
      await _settle();
      final task = manager.tasks.single;
      final first = engine.last(task.id);
      final temp = first.args[first.args.indexOf('-P', first.args.indexOf('-P') + 1) + 1];
      File(p.join(temp.substring('temp:'.length), 'a.mp4.part')).writeAsStringSync('half');

      await manager.pause(task);
      await _settle();
      expect(task.status, DownloadStatus.paused);
      expect(saved.single, contains('"status":"paused"'));
      expect(File(p.join(temp.substring('temp:'.length), 'a.mp4.part')).existsSync(), isTrue);

      manager.resume(task);
      await _settle();
      expect(task.isRunning, isTrue);
      expect(engine.runs[task.id], hasLength(2));
      expect(engine.last(task.id).args, contains(temp));
    });

    test('waits for yt-dlp, then starts', () async {
      engine.status.value = const EngineStatus(state: EngineState.installing);
      await enqueue('a');
      await _settle();
      expect(engine.running, 0);
      expect(manager.tasks.single.stage, 'Waiting for yt-dlp…');
      engine.status.value = const EngineStatus(state: EngineState.ready, ffmpegAvailable: true);
      await _settle();
      expect(engine.running, 1);
    });

    test('Wi-Fi only: waits on mobile data', () async {
      await extras.setWifiOnly(true);
      wifi = false;
      await enqueue('a');
      await _settle();
      expect(engine.running, 0);
      expect(manager.tasks.single.stage, 'Waiting for Wi-Fi');
    });

    test('a speed limit reaches yt-dlp', () async {
      await extras.setSpeedLimitKbps(1024);
      await enqueue('a');
      await _settle();
      expect(engine.last(manager.tasks.single.id).args, containsAllInOrder(['--limit-rate', '1M']));
    });

    test('refused subtitles: the video downloads without them', () async {
      await enqueue('a', subtitleArgs: const ['--write-subs', '--sub-langs', 'en']);
      await _settle();
      final task = manager.tasks.single;
      expect(engine.last(task.id).args, contains('--write-subs'));
      engine.last(task.id).finish(1, stderr: 'ERROR: Unable to download video subtitles for \'en\': HTTP Error 429');
      await _settle();
      expect(engine.runs[task.id], hasLength(2));
      expect(engine.last(task.id).args, isNot(contains('--write-subs')));
      expect(task.stage, 'Retrying without subtitles…');
    });

    test('the queue survives a restart', () async {
      await extras.setMaxConcurrent(1);
      await enqueue('a');
      await enqueue('b');
      await _settle();
      await manager.pause(manager.tasks.firstWhere((t) => t.status == DownloadStatus.queued));
      await _settle();
      expect(saved, hasLength(2));

      // A new run of the app.
      engine = _Engine(prefs);
      manager = create();
      await manager.restore();
      await _settle();
      expect(manager.tasks, hasLength(2));
      expect(manager.tasks.where((t) => t.status == DownloadStatus.paused), hasLength(1));
      expect(engine.running, 1);
    });
  });
}
