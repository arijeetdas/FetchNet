import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/engine/engine.dart';
import 'package:fetchnet/models/creator_job.dart';
import 'package:fetchnet/models/download_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/audio_tags.dart';
import 'package:fetchnet/services/download_manager.dart';
import 'package:fetchnet/services/extra_settings.dart';
import 'package:fetchnet/services/history_store.dart';
import 'package:fetchnet/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'stream_relay_test.dart' show Site, fetch;

/// A yt-dlp run that ends when the test says so.
class _Run extends EngineRun {
  _Run(this.args);

  final List<String> args;
  final _lines = StreamController<String>.broadcast();
  final _done = Completer<EngineResult>();

  void finish(int code, {String stderr = '', String stdout = ''}) {
    if (!_done.isCompleted) _done.complete(EngineResult(exitCode: code, stdout: stdout, stderr: stderr));
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

  /// FFmpeg / ffprobe runs, in order ([_Run.args] starts with 'probe' for
  /// ffprobe).
  final List<_Run> ffmpegRuns = [];

  @override
  EngineRun startFfmpeg(String id, List<String> args, {bool probe = false}) {
    final run = _Run([if (probe) 'probe', ...args]);
    ffmpegRuns.add(run);
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

    group('Lyrics picked on Home', () {
      const song = DownloadOption(kind: MediaKind.audio, label: 'MP3', extension: 'mp3', formatArgs: ['-x', '--embed-metadata']);
      const lrc = '[00:01.00] First line\n[00:02.00] Second line';

      Future<DownloadTask> download(List<int> fileBytes, {String mode = 'embed', String ext = 'mp3'}) async {
        await extras.setLyrics(true);
        await extras.setLyricsMode(SubtitleMode.values.byName(mode));
        await manager.enqueue(
          info: MediaInfo(url: 'https://example.com/song', title: 'Song', raw: const {}),
          option: song,
          fileBaseName: 'Song',
          lyricsText: lrc,
        );
        await _settle();
        final task = manager.tasks.single;
        final run = engine.last(task.id);
        // They reach FFmpeg as the song's lyrics tag (not for a file only).
        final at = run.args.indexOf('--postprocessor-args');
        if (mode == 'file') {
          expect(at, -1);
        } else {
          expect(run.args[at + 1], contains('lyrics=[00:01.00] First line'));
        }
        final out = File(p.join(root.path, 'Song.$ext'))..writeAsBytesSync(fileBytes);
        run._lines.add('FNFILE|${out.path}');
        await _settle();
        run.finish(0);
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return task;
      }

      List<int> id3WithLyrics(String text) {
        final data = [3, ...latin1.encode('eng'), 0, ...utf8.encode(text)];
        final frame = [...latin1.encode('USLT'), 0, 0, 0, data.length, 0, 0, ...data];
        final n = frame.length;
        return [...latin1.encode('ID3'), 3, 0, 0, (n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127, ...frame, 0xFF, 0xFB, 0, 0];
      }

      test('inside the song: no .lrc when the song has them', () async {
        await download(id3WithLyrics(lrc));
        expect(File(p.join(root.path, 'Song.lrc')).existsSync(), isFalse);
      });

      test('an MP3 that came out without them (FFmpeg 7): FetchNet writes them in', () async {
        await download(const [0xFF, 0xFB, 0x90, 0x00]);
        expect(AudioTags.readSync(p.join(root.path, 'Song.mp3')).lyrics, lrc);
        expect(File(p.join(root.path, 'Song.lrc')).existsSync(), isFalse);
      });

      test('another format that came out without them: a .lrc next to it', () async {
        await download(const [0x1A, 0x45, 0xDF, 0xA3], ext: 'webm');
        final lrcFile = File(p.join(root.path, 'Song.lrc'));
        expect(lrcFile.existsSync(), isTrue);
        expect(lrcFile.readAsStringSync(), lrc);
      });

      test('as a file: the .lrc is written', () async {
        await download(const [0xFF, 0xFB, 0x90, 0x00], mode: 'file');
        expect(File(p.join(root.path, 'Song.lrc')).readAsStringSync(), lrc);
      });
    });

    group('Creator jobs', () {
      const clipVideo = DownloadOption(kind: MediaKind.video, label: '1080p', extension: 'mp4', formatArgs: ['-f', 'b']);

      Future<void> pause() async {
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
      }

      Future<_Run> nextFfmpeg(int count) async {
        for (var i = 0; i < 100 && engine.ffmpegRuns.length < count; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(engine.ffmpegRuns, hasLength(count));
        return engine.ffmpegRuns.last;
      }

      /// Starts [job]. The direct cut lists the streams first; unless
      /// [direct], that listing fails here, so the part download (its
      /// fallback) is the run returned.
      Future<(DownloadTask, _Run)> start(CreatorJob job, {DownloadOption option = clipVideo, bool direct = false}) async {
        await manager.enqueue(
          info: MediaInfo(url: 'https://example.com/v', title: 'Video', raw: const {}),
          option: option,
          fileBaseName: 'Video',
          creator: job,
        );
        await _settle();
        final task = manager.tasks.single;
        final listing = engine.last(task.id);
        expect(listing.args, containsAllInOrder(['-j', '--', 'https://example.com/v']));
        if (direct) return (task, listing);
        listing.finish(1, stderr: 'ERROR: no streams in tests');
        await pause();
        return (task, engine.last(task.id));
      }

      String landscape = jsonEncode({
        'streams': [
          {'width': 1920, 'height': 1080},
        ],
      });

      test('a clip downloads only its part; a landscape one is made 9:16 and replaces it', () async {
        final (task, run) = await start(const CreatorJob.clip(
          start: Duration(seconds: 70),
          end: Duration(seconds: 100),
          shorts: true,
          background: ShortsBackground.blur,
        ));
        expect(run.args, containsAllInOrder(['--download-sections', '*70-100']));
        // yt-dlp re-encoding the part as it downloads is far too slow.
        expect(run.args, isNot(contains('--force-keyframes-at-cuts')));
        final clip = File(p.join(root.path, 'Video.webm'))..writeAsStringSync('clip');
        run._lines.add('FNFILE|${clip.path}');
        await _settle();
        run.finish(0);

        // ffprobe: landscape.
        final probe = await nextFfmpeg(1);
        expect(probe.args.first, 'probe');
        probe.finish(0, stdout: landscape);
        // FFmpeg: the Short, with progress.
        final convert = await nextFfmpeg(2);
        expect(convert.args, contains('libx264'));
        expect(task.stage, 'Making it 9:16 for Shorts & Reels…');
        convert._lines.add('out_time_us=15000000');
        await pause();
        expect(task.progress, closeTo(0.5, 0.01));
        File(convert.args.last).writeAsStringSync('short');
        convert.finish(0);
        await pause();

        expect(File(p.join(root.path, 'Video.mp4')).readAsStringSync(), 'short');
        expect(clip.existsSync(), isFalse);
        final entry = HistoryStore(prefs).entries.first;
        expect(entry.filePath, p.join(root.path, 'Video.mp4'));
        expect(entry.quality, contains('Clip 1:10–1:40 · 9:16'));
      });

      test('a portrait clip stays as it is', () async {
        final (_, run) = await start(const CreatorJob.clip(start: Duration.zero, end: Duration(seconds: 10), shorts: true));
        final clip = File(p.join(root.path, 'Video.mp4'))..writeAsStringSync('portrait');
        run._lines.add('FNFILE|${clip.path}');
        await _settle();
        run.finish(0);
        final probe = await nextFfmpeg(1);
        probe.finish(0, stdout: jsonEncode({'streams': [{'width': 1080, 'height': 1920}]}));
        await pause();
        expect(engine.ffmpegRuns, hasLength(1));
        expect(clip.readAsStringSync(), 'portrait');
        expect(HistoryStore(prefs).entries.first.status, DownloadStatus.completed);
      });

      test("a clip FFmpeg can't convert is kept as downloaded", () async {
        final (_, run) = await start(const CreatorJob.clip(start: Duration.zero, end: Duration(seconds: 10), shorts: true));
        final clip = File(p.join(root.path, 'Video.mp4'))..writeAsStringSync('clip');
        run._lines.add('FNFILE|${clip.path}');
        await _settle();
        run.finish(0);
        (await nextFfmpeg(1)).finish(0, stdout: landscape);
        (await nextFfmpeg(2)).finish(1, stderr: 'Unknown encoder');
        await pause();
        expect(clip.readAsStringSync(), 'clip');
        expect(HistoryStore(prefs).entries.first.status, DownloadStatus.completed);
      });

      test('a snapshot: a piece in a work folder, only the picture is saved', () async {
        const option = DownloadOption(kind: MediaKind.thumbnail, label: 'Snapshot', extension: 'jpg', formatArgs: ['-f', 'bv*/b']);
        final (task, run) = await start(const CreatorJob.snapshot(at: Duration(seconds: 42)), option: option);
        expect(run.args, containsAllInOrder(['--download-sections', '*42-44']));
        final home = run.args[run.args.indexOf('-P') + 1].substring('home:'.length);
        expect(p.isWithin(root.path, home) && home != root.path, isTrue);
        final piece = File(p.join(home, 'Video.webm'))..writeAsStringSync('piece');
        run._lines.add('FNFILE|${piece.path}');
        await _settle();
        run.finish(0);
        final grab = await nextFfmpeg(1);
        expect(grab.args, containsAllInOrder(['-frames:v', '1']));
        expect(grab.args.last, p.join(root.path, 'Video.jpg'));
        File(grab.args.last).writeAsStringSync('picture');
        grab.finish(0);
        await pause();
        final entry = HistoryStore(prefs).entries.first;
        expect(entry.filePath, p.join(root.path, 'Video.jpg'));
        expect(entry.quality, contains('Snapshot at 0:42'));
        expect(task.status, DownloadStatus.completed);
      });

      test('a part downloading through FFmpeg shows its progress', () async {
        const merged = DownloadOption(kind: MediaKind.video, label: '1080p', extension: 'mp4', formatArgs: ['-f', 'bv+ba'], needsMerge: true);
        final (task, run) = await start(const CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100)), option: merged);
        run._lines.add('[download] Destination: /x/Video.f137.mp4');
        await _settle();
        expect(task.stage, 'Cutting the video…');
        run._lines.add('frame=  240 fps= 33 q=28.0 size=  1024KiB time=00:00:15.00 bitrate=1706.1kbits/s');
        await pause();
        expect(task.progress, closeTo(0.25, 0.01)); // half the video part
        run._lines.add('[download] Destination: /x/Video.f140.m4a');
        run._lines.add('size=  100KiB time=00:00:30.00 bitrate=128.0kbits/s');
        await pause();
        expect(task.stage, 'Cutting the audio…');
        expect(task.progress, closeTo(0.99, 0.01));
        run.finish(1, stderr: 'stop');
        await pause();
      });

      test("when FFmpeg can't download just the part: the whole video, cut on the device", () async {
        final (task, run) = await start(const CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100)));
        run.finish(1, stderr: 'ERROR: ffmpeg exited with code 1');
        await pause();
        final whole = engine.last(task.id);
        expect(identical(whole, run), isFalse);
        expect(whole.args, isNot(contains('--download-sections')));
        expect(task.stage, 'Downloading the whole video to cut it…');
        final home = whole.args[whole.args.indexOf('-P') + 1].substring('home:'.length);
        expect(home, isNot(root.path));
        final full = File(p.join(home, 'Video.webm'))..writeAsStringSync('whole');
        whole._lines.add('FNFILE|${full.path}');
        await _settle();
        whole.finish(0);
        final cut = await nextFfmpeg(1);
        expect(cut.args, containsAllInOrder(['-ss', '70', '-i', full.path, '-t', '30']));
        expect(cut.args, contains('libx264')); // exact cuts
        expect(cut.args.last, p.join(root.path, 'Video.mp4'));
        File(cut.args.last).writeAsStringSync('clip');
        cut.finish(0);
        await pause();
        expect(HistoryStore(prefs).entries.first.filePath, p.join(root.path, 'Video.mp4'));
        expect(HistoryStore(prefs).entries.first.status, DownloadStatus.completed);
      });

      test('a snapshot whose piece never arrived: the whole video, then the frame at the moment', () async {
        const option = DownloadOption(kind: MediaKind.thumbnail, label: 'Snapshot', extension: 'jpg', formatArgs: ['-f', 'bv*/b']);
        final (task, run) = await start(const CreatorJob.snapshot(at: Duration(seconds: 42)), option: option);
        // yt-dlp said it was done, but no file came out.
        run._lines.add('FNFILE|${p.join(root.path, 'missing.mp4')}');
        await _settle();
        run.finish(0);
        await pause();
        final whole = engine.last(task.id);
        expect(whole.args, isNot(contains('--download-sections')));
        final home = whole.args[whole.args.indexOf('-P') + 1].substring('home:'.length);
        final full = File(p.join(home, 'Video.mp4'))..writeAsStringSync('whole');
        whole._lines.add('FNFILE|${full.path}');
        await _settle();
        whole.finish(0);
        final grab = await nextFfmpeg(1);
        expect(grab.args, containsAllInOrder(['-ss', '42', '-i', full.path, '-frames:v', '1']));
        File(grab.args.last).writeAsStringSync('picture');
        grab.finish(0);
        await pause();
        expect(HistoryStore(prefs).entries.first.filePath, p.join(root.path, 'Video.jpg'));
      });

      group('cut straight from the streams', () {
        late Site site;

        setUp(() async => site = await Site.start(200000));
        tearDown(() => site.close());

        Map<String, dynamic> stream(String vcodec, String acodec, {String ext = 'mp4'}) => {
          'url': '${site.url}',
          'protocol': 'http',
          'vcodec': vcodec,
          'acodec': acodec,
          'ext': ext,
          'width': 1920,
          'height': 1080,
          'http_headers': {'User-Agent': 'FetchNet test'},
        };

        /// The stream FFmpeg is given: through the relay, which serves the
        /// site's file.
        Future<String> readsRelay(_Run ffmpeg, {int index = 0}) async {
          final inputs = [for (var i = 0; i < ffmpeg.args.length; i++) if (ffmpeg.args[i] == '-i') ffmpeg.args[i + 1]];
          final local = Uri.parse(inputs[index]);
          expect(local.host, '127.0.0.1');
          final (status, _, body) = await fetch(local, range: 'bytes=100-');
          expect(status, HttpStatus.partialContent);
          expect(body, site.data.sublist(100));
          expect(site.agents.toSet(), {'FetchNet test'});
          return inputs[index];
        }

        test('a snapshot: only the video is listed, and FFmpeg seeks in it', () async {
          const option = DownloadOption(kind: MediaKind.thumbnail, label: 'Snapshot', extension: 'jpg', formatArgs: ['-f', 'bv*+ba/b']);
          final (task, listing) = await start(const CreatorJob.snapshot(at: Duration(seconds: 42)), option: option, direct: true);
          expect(listing.args, containsAllInOrder(['-f', 'bv*/b']));
          expect(task.stage, 'Finding the moment…');
          listing._lines.add(jsonEncode(stream('vp9', 'none', ext: 'webm')));
          listing.finish(0);
          final grab = await nextFfmpeg(1);
          final input = await readsRelay(grab);
          expect(grab.args, containsAllInOrder(['-ss', '42', '-i', input, '-frames:v', '1']));
          expect(p.dirname(grab.args.last), root.path);
          File(grab.args.last).writeAsStringSync('picture');
          grab.finish(0);
          await pause();
          final entry = HistoryStore(prefs).entries.first;
          expect(entry.filePath, p.join(root.path, 'Video.jpg'));
          expect(File(entry.filePath!).readAsStringSync(), 'picture');
          expect(engine.runs[task.id], hasLength(1)); // no part download
          expect(root.listSync().whereType<File>().map((f) => p.basename(f.path)), ['Video.jpg']);
        });

        test('an exact clip: copied out of the streams, then encoded from that copy', () async {
          final (task, listing) = await start(const CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100)), direct: true);
          listing._lines.add(jsonEncode({
            'title': 'Video',
            'requested_formats': [stream('av01', 'none'), stream('none', 'opus', ext: 'webm')],
          }));
          listing.finish(0);
          final copy = await nextFfmpeg(1);
          await readsRelay(copy);
          await readsRelay(copy, index: 1);
          expect(copy.args, containsAllInOrder(['-c', 'copy']));
          expect(p.isWithin(p.join(root.path, '.work'), copy.args.last), isTrue);
          expect(task.stage, 'Downloading the clip…');
          copy._lines.add('out_time_us=15000000');
          await pause();
          expect(task.progress, closeTo(0.15, 0.01)); // half the copy (first 30 %)
          File(copy.args.last).writeAsStringSync('part');
          copy.finish(0);

          final encode = await nextFfmpeg(2);
          expect(encode.args, containsAllInOrder(['-i', copy.args.last, '-t', '30']));
          expect(encode.args, contains('libx264'));
          expect(encode.args, isNot(contains('-filter_complex')));
          expect(task.stage, 'Cutting it exactly…');
          encode._lines.add('out_time_us=15000000');
          await pause();
          expect(task.progress, closeTo(0.65, 0.01));
          File(encode.args.last).writeAsStringSync('clip');
          encode.finish(0);
          await pause();

          final entry = HistoryStore(prefs).entries.first;
          expect(entry.filePath, p.join(root.path, 'Video.mp4'));
          expect(File(entry.filePath!).readAsStringSync(), 'clip');
          expect(File(copy.args.last).existsSync(), isFalse); // the copy is cleaned up
          expect(engine.ffmpegRuns, hasLength(2)); // no separate 9:16 pass
        });

        test('a 9:16 clip is made in the same encode; cuts not exact: one copy', () async {
          final (_, listing) = await start(
            const CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100), shorts: true, background: ShortsBackground.blur),
            direct: true,
          );
          listing._lines.add(jsonEncode(stream('avc1', 'mp4a.40.2')));
          listing.finish(0);
          final copy = await nextFfmpeg(1);
          expect(copy.args, containsAllInOrder(['-map', '0:v:0', '-map', '0:a:0?'])); // one stream with both
          File(copy.args.last).writeAsStringSync('part');
          copy.finish(0);
          final encode = await nextFfmpeg(2);
          expect(encode.args, contains('-filter_complex'));
          File(encode.args.last).writeAsStringSync('short');
          encode.finish(0);
          await pause();
          expect(File(p.join(root.path, 'Video.mp4')).readAsStringSync(), 'short');
        });

        test('cuts that needn\'t be exact are the copy itself', () async {
          final (_, listing) = await start(
            const CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100), exactCuts: false),
            direct: true,
          );
          listing._lines.add(jsonEncode(stream('avc1', 'mp4a.40.2')));
          listing.finish(0);
          final copy = await nextFfmpeg(1);
          expect(p.dirname(copy.args.last), root.path);
          File(copy.args.last).writeAsStringSync('clip');
          copy.finish(0);
          await pause();
          expect(engine.ffmpegRuns, hasLength(1));
          expect(File(p.join(root.path, 'Video.mp4')).readAsStringSync(), 'clip');
          expect(root.listSync().whereType<File>().map((f) => p.basename(f.path)), ['Video.mp4']);
        });

        test("a song's part is saved as its format asks", () async {
          const mp3 = DownloadOption(kind: MediaKind.audio, label: 'MP3', extension: 'mp3', formatArgs: ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '320K']);
          final (_, listing) = await start(const CreatorJob.clip(start: Duration(seconds: 10), end: Duration(seconds: 40)), option: mp3, direct: true);
          listing._lines.add(jsonEncode({...stream('none', 'opus', ext: 'webm'), 'title': 'Song', 'artist': 'Band'}));
          listing.finish(0);
          final cut = await nextFfmpeg(1);
          await readsRelay(cut);
          expect(cut.args, containsAllInOrder(['-c:a', 'libmp3lame', '-b:a', '320k']));
          expect(cut.args, containsAllInOrder(['-metadata', 'title=Song', '-metadata', 'artist=Band']));
          File(cut.args.last).writeAsStringSync('song');
          cut.finish(0);
          await pause();
          expect(HistoryStore(prefs).entries.first.filePath, p.join(root.path, 'Video.mp3'));
        });

        test('when the direct cut fails, the part download takes over', () async {
          final (task, listing) = await start(const CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100)), direct: true);
          listing._lines.add(jsonEncode(stream('avc1', 'mp4a.40.2')));
          listing.finish(0);
          final copy = await nextFfmpeg(1);
          copy.finish(1, stderr: 'Connection refused');
          await pause();
          final part = engine.last(task.id);
          expect(identical(part, listing), isFalse);
          expect(part.args, containsAllInOrder(['--download-sections', '*70-100']));
          expect(root.listSync().whereType<File>(), isEmpty); // nothing left behind
          part.finish(1, stderr: 'stop');
          await pause();
        });

        test('a stream FFmpeg can\'t read here (DASH pieces) goes straight to the part download', () async {
          final (task, listing) = await start(const CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100)), direct: true);
          listing._lines.add(jsonEncode({...stream('avc1', 'mp4a'), 'protocol': 'http_dash_segments'}));
          listing.finish(0);
          await pause();
          expect(engine.ffmpegRuns, isEmpty);
          expect(engine.last(task.id).args, contains('--download-sections'));
          engine.last(task.id).finish(1, stderr: 'stop');
          await pause();
        });

        test('paused while cutting: resumes with the direct cut again', () async {
          final (task, listing) = await start(const CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100)), direct: true);
          listing._lines.add(jsonEncode(stream('avc1', 'mp4a.40.2')));
          listing.finish(0);
          await nextFfmpeg(1);
          await manager.pause(task);
          await pause();
          expect(task.status, DownloadStatus.paused);
          manager.resume(task);
          await pause();
          expect(engine.last(task.id).args, contains('-j'));
          engine.last(task.id).finish(1, stderr: 'stop');
          await pause();
        });
      });

      test("an audio clip gets no lyrics (their times wouldn't match)", () async {
        await extras.setLyrics(true);
        await manager.enqueue(
          info: MediaInfo(url: 'https://example.com/s', title: 'Artist - Song', raw: const {}, duration: 200),
          option: audio,
          fileBaseName: 'Song',
          lyricsText: '[00:01.00] hi',
          creator: const CreatorJob.clip(start: Duration(seconds: 10), end: Duration(seconds: 40)),
        );
        await _settle();
        final task = manager.tasks.single;
        expect(task.lyrics, isNull);
        expect(task.lyricsText, isNull);
        expect(engine.last(task.id).args, isNot(contains('--postprocessor-args')));
      });
    });
  });
}
