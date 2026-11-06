import 'dart:async';
import 'dart:convert';

import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/engine/engine.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/models/youtube_models.dart';
import 'package:fetchnet/services/fetch_service.dart';
import 'package:fetchnet/services/youtube_client.dart';
import 'package:fetchnet/services/youtube_streams.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _format(String id, {String vcodec = 'none', String acodec = 'none', int? height, int? width, num? fps,
    num? abr, num? lang, String protocol = 'https', String ext = 'mp4'}) => {
      'format_id': id,
      'url': 'https://rr1.googlevideo.com/videoplayback?itag=$id',
      'protocol': protocol,
      'ext': ext,
      'vcodec': vcodec,
      'acodec': acodec,
      'height': ?height,
      'width': ?width,
      'fps': ?fps,
      'abr': ?abr,
      'tbr': abr ?? (height == null ? null : height * 2),
      'language_preference': ?lang,
      'http_headers': {'User-Agent': 'UA'},
    };

MediaInfo _info(List<Map<String, dynamic>> formats) => MediaInfo.parse(
      jsonEncode({'id': 'dQw4w9WgXcQ', 'title': 'T', 'duration': 100, 'extractor_key': 'Youtube', 'formats': formats}),
      sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    );

/// Engine whose runs finish when the test says so.
class _FakeEngine extends YtDlpEngine {
  _FakeEngine(super.prefs);

  final Map<String, Completer<EngineResult>> runs = {};
  final Map<String, List<String>> argsOf = {};
  final List<String> cancelled = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<EngineResult> run(List<String> args, {String? id}) {
    argsOf[id!] = args;
    return (runs[id] = Completer()).future;
  }

  @override
  EngineRun start(String id, List<String> args) => throw UnimplementedError();

  @override
  Future<void> cancel(String id) async {
    cancelled.add(id);
    runs[id]?.complete(const EngineResult(exitCode: EngineRun.cancelledExitCode, stdout: '', stderr: ''));
  }

  @override
  Future<String> update() async => '';
}

void main() {
  group('Stream selection', () {
    test('pairs the best video per quality with the best audio, even when no track is "original"', () {
      final s = YtStreams.fromInfo(_info([
        _format('137', vcodec: 'avc1.640028', height: 1080, width: 1920, fps: 30),
        _format('248', vcodec: 'vp9', height: 1080, width: 1920, fps: 30, ext: 'webm'),
        _format('299', vcodec: 'avc1.64002a', height: 1080, width: 1920, fps: 60),
        _format('136', vcodec: 'avc1.4d401f', height: 720, width: 1280, fps: 30),
        _format('614', vcodec: 'vp09', height: 1080, protocol: 'm3u8_native'),
        _format('sb0', height: 90, ext: 'mhtml', protocol: 'mhtml'),
        // yt-dlp marks tracks that aren't the original language with -1.
        _format('140', acodec: 'mp4a.40.2', abr: 129, lang: -1),
        _format('251', acodec: 'opus', abr: 120, lang: -1, ext: 'webm'),
      ]));
      expect(s.video.map((v) => v.label), ['1080p60', '720p']);
      expect(s.video.first.codec, 'avc1');
      expect(s.audio?.codec, 'mp4a');
      expect(s.audio?.headers['User-Agent'], 'UA');
      expect(s.videoFor(0, auto: 720)?.label, '720p');
      expect(s.videoFor(1080, auto: 720)?.label, '1080p60');
      // Asking for more than exists gives the best; less than exists the lowest.
      expect(s.videoFor(2160, auto: 720)?.label, '1080p60');
      expect(s.videoFor(144, auto: 720)?.label, '720p');
    });

    test('original language beats dubbed audio', () {
      final s = YtStreams.fromInfo(_info([
        _format('136', vcodec: 'avc1', height: 720),
        _format('140-dub', acodec: 'mp4a', abr: 160, lang: -1),
        _format('140-orig', acodec: 'mp4a', abr: 128, lang: 10),
      ]));
      expect(s.audio?.url, contains('140-orig'));
    });

    test('falls back to a combined stream when there is no separate audio', () {
      final s = YtStreams.fromInfo(_info([
        _format('136', vcodec: 'avc1', height: 720),
        _format('18', vcodec: 'avc1', acodec: 'mp4a', height: 360),
      ]));
      expect(s.audio, isNull);
      expect(s.video.single.hasAudio, isTrue);
      expect(s.videoFor(0, auto: 1080)?.label, '360p');
    });

    test('vertical videos are named by their shorter side', () {
      final s = YtStreams.fromInfo(_info([
        _format('137', vcodec: 'avc1', height: 1920, width: 1080),
        _format('140', acodec: 'mp4a', abr: 128),
      ]));
      expect(s.video.single.label, '1080p');
      expect(s.video.single.badge, 'HD');
    });
  });

  group('YouTube data (new)', () {
    test('parseSuggestions reads both suggestion formats', () {
      expect(YouTubeClient.parseSuggestions('["lofi",["lofi songs","lofi beats"],[],{}]'), ['lofi songs', 'lofi beats']);
      expect(YouTubeClient.parseSuggestions('["a",[["a b",0],["a c",0]]]'), ['a b', 'a c']);
      expect(YouTubeClient.parseSuggestions('<html>'), isEmpty);
    });

    test('parsePosts reads text, images, an attached video and likes', () {
      final posts = YouTubeClient.parsePosts({
        'items': [
          {
            'backstagePostThreadRenderer': {
              'post': {
                'backstagePostRenderer': {
                  'postId': 'P1',
                  'authorText': {'runs': [{'text': 'Chan'}]},
                  'authorThumbnail': {'thumbnails': [{'url': '//yt3.ggpht.com/a=s48'}]},
                  'authorEndpoint': {'browseEndpoint': {'browseId': 'UC1'}},
                  'contentText': {'runs': [{'text': 'Hello '}, {'text': 'world'}]},
                  'publishedTimeText': {'runs': [{'text': '2 days ago'}]},
                  'voteCount': {'simpleText': '13K'},
                  'backstageAttachment': {
                    'postMultiImageRenderer': {
                      'images': [
                        {'backstageImageRenderer': {'image': {'thumbnails': [{'url': 'https://i/1.jpg'}]}}},
                        {'backstageImageRenderer': {'image': {'thumbnails': [{'url': 'https://i/2.jpg'}]}}},
                      ],
                    },
                  },
                },
              },
            },
          },
          {
            'backstagePostThreadRenderer': {
              'post': {
                'backstagePostRenderer': {
                  'postId': 'P2',
                  'authorText': {'simpleText': 'Chan'},
                  'publishedTimeText': {'simpleText': '1 hour ago'},
                  'backstageAttachment': {
                    'videoRenderer': {'videoId': 'dQw4w9WgXcQ', 'title': {'runs': [{'text': 'Vid'}]}},
                  },
                },
              },
            },
          },
        ],
      });
      expect(posts, hasLength(2));
      expect(posts.first.text, 'Hello world');
      expect(posts.first.authorAvatar, 'https://yt3.ggpht.com/a=s48');
      expect(posts.first.channelId, 'UC1');
      expect(posts.first.images, ['https://i/1.jpg', 'https://i/2.jpg']);
      expect(posts.first.likes, '13K');
      expect(posts.last.video?.id, 'dQw4w9WgXcQ');
      expect(posts.last.age < posts.first.age, isTrue);
    });

    test('parseChannelHeader reads the view-model header', () {
      final ch = YouTubeClient.parseChannelHeader('UCX', {
        'metadata': {
          'channelMetadataRenderer': {
            'title': 'MrBeast',
            'externalId': 'UCX6',
            'avatar': {'thumbnails': [{'url': 'https://yt3/a.jpg'}]},
          },
        },
        'header': {
          'pageHeaderRenderer': {
            'content': {
              'pageHeaderViewModel': {
                'metadata': {
                  'contentMetadataViewModel': {
                    'metadataRows': [
                      {'metadataParts': [{'text': {'content': '@MrBeast'}}]},
                      {'metadataParts': [{'text': {'content': '525M subscribers'}}, {'text': {'content': '1K videos'}}]},
                    ],
                  },
                },
                'banner': {'imageBannerViewModel': {'image': {'sources': [{'url': 'https://yt3/banner.jpg'}]}}},
              },
            },
          },
        },
      });
      expect(ch.id, 'UCX6');
      expect(ch.name, 'MrBeast');
      expect(ch.handle, '@MrBeast');
      expect(ch.subscribers, '525M subscribers');
      expect(ch.avatar, 'https://yt3/a.jpg');
      expect(ch.banner, 'https://yt3/banner.jpg');
    });

    test('parseWatch reads the channel id, subscription and likes', () {
      final info = YouTubeClient.parseWatch('dQw4w9WgXcQ', {
        'contents': {
          'twoColumnWatchNextResults': {
            'results': {
              'results': {
                'contents': [
                  {
                    'videoPrimaryInfoRenderer': {
                      'title': {'runs': [{'text': 'Never Gonna Give You Up'}]},
                      'videoActions': {'likeCountEntity': {'likeCountIfIndifferent': {'content': '19M'}}},
                    },
                  },
                  {
                    'videoSecondaryInfoRenderer': {
                      'owner': {
                        'videoOwnerRenderer': {
                          'title': {'runs': [{'text': 'Rick Astley'}]},
                          'subscriberCountText': {'simpleText': '4.56M subscribers'},
                          'navigationEndpoint': {'browseEndpoint': {'browseId': 'UCuAXFkgsw1L7xaCfnd5JJOw'}},
                        },
                      },
                      'subscribeButton': {'subscribeButtonRenderer': {'subscribed': true, 'channelId': 'UCuAXFkgsw1L7xaCfnd5JJOw'}},
                    },
                  },
                ],
              },
            },
          },
        },
      });
      expect(info.channelId, 'UCuAXFkgsw1L7xaCfnd5JJOw');
      expect(info.subscribed, isTrue);
      expect(info.likes, '19M');
      expect(info.copyWith(subscribed: false).subscribed, isFalse);
    });

    test('relative ages sort posts newest first', () {
      expect(parseRelativeAge('3 days ago'), const Duration(days: 3));
      expect(parseRelativeAge('2 weeks ago (edited)'), const Duration(days: 14));
      expect(parseRelativeAge('1 year ago') > parseRelativeAge('11 months ago'), isTrue);
      expect(parseRelativeAge(null) > parseRelativeAge('5 years ago'), isTrue);
    });
  });

  group('FetchService', () {
    test('overlapping fetches both complete; cancel stops every run', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = _FakeEngine(await AppPrefs.load());
      final fetcher = FetchService(engine);
      final a = fetcher.fetch('https://a.example/1');
      final b = fetcher.fetch('https://a.example/2');
      await Future<void>.delayed(Duration.zero);
      expect(engine.runs, hasLength(2));
      String json(String t) => jsonEncode({'id': t, 'title': t, 'formats': []});
      final ids = engine.runs.keys.toList();
      engine.runs[ids[1]]!.complete(EngineResult(exitCode: 0, stdout: json('two'), stderr: ''));
      engine.runs[ids[0]]!.complete(EngineResult(exitCode: 0, stdout: json('one'), stderr: ''));
      expect((await a).title, 'one');
      expect((await b).title, 'two');

      final c = fetcher.fetch('https://a.example/3');
      final d = fetcher.fetch('https://a.example/4');
      await Future<void>.delayed(Duration.zero);
      final cancelled = throwsA(isA<FetchException>().having((e) => e.cancelled, 'cancelled', true));
      final checks = [expectLater(c, cancelled), expectLater(d, cancelled)];
      await fetcher.cancel();
      await Future.wait(checks);
      expect(engine.cancelled, hasLength(2));
    });
  });

  group('Stream lookups', () {
    String ytJson(List<Map<String, dynamic>> formats) =>
        jsonEncode({'id': 'dQw4w9WgXcQ', 'title': 'T', 'duration': 10, 'extractor_key': 'Youtube', 'formats': formats});
    final playable = [
      _format('136', vcodec: 'avc1', height: 720),
      _format('140', acodec: 'mp4a', abr: 128),
    ];

    Future<(_FakeEngine, YtStreamResolver)> setUp() async {
      SharedPreferences.setMockInitialValues({});
      final engine = _FakeEngine(await AppPrefs.load());
      engine.status.value = const EngineStatus(state: EngineState.ready);
      return (engine, YtStreamResolver(() => FetchService(engine), engine));
    }

    Future<String> nextRun(_FakeEngine e, int count) async {
      for (var i = 0; i < 20 && e.runs.length < count; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      return e.runs.keys.last;
    }

    test('a lookup nobody waits for any more is stopped', () async {
      final (engine, resolver) = await setUp();
      final a = resolver.resolve('aaaaaaaaaaa');
      final cancelled = expectLater(a, throwsA(isA<FetchException>().having((e) => e.cancelled, 'cancelled', true)));
      final id = await nextRun(engine, 1);
      resolver.release('aaaaaaaaaaa');
      await cancelled;
      expect(engine.cancelled, [id]);
      expect(resolver.isPending('aaaaaaaaaaa'), isFalse);
    });

    test('a lookup keeps running while someone else still waits', () async {
      final (engine, resolver) = await setUp();
      final player = resolver.resolve('bbbbbbbbbbb');
      final sheet = resolver.resolve('bbbbbbbbbbb');
      final id = await nextRun(engine, 1);
      resolver.release('bbbbbbbbbbb');
      expect(engine.cancelled, isEmpty);
      engine.runs[id]!.complete(EngineResult(exitCode: 0, stdout: ytJson(playable), stderr: ''));
      expect((await player).video.single.label, '720p');
      expect(identical(await sheet, await player), isTrue);
      // Cached now: no new yt-dlp run.
      await resolver.resolve('bbbbbbbbbbb');
      expect(engine.runs, hasLength(1));
    });

    test('the fast lookup is used, but its shortcut never reaches downloads', () async {
      final (engine, resolver) = await setUp();
      final f = resolver.resolve('ccccccccccc');
      final id = await nextRun(engine, 1);
      expect(engine.argsOf[id], containsAllInOrder(['--extractor-args', 'youtube:skip=hls,dash,translated_subs']));
      engine.runs[id]!.complete(EngineResult(exitCode: 0, stdout: ytJson(playable), stderr: ''));
      expect((await f).info.requestArgs, isEmpty);
    });

    test('live streams (HLS only) are looked up again with the manifests', () async {
      final (engine, resolver) = await setUp();
      final f = resolver.resolve('ddddddddddd');
      final first = await nextRun(engine, 1);
      engine.runs[first]!.complete(EngineResult(exitCode: 0, stdout: ytJson(const []), stderr: ''));
      final second = await nextRun(engine, 2);
      expect(engine.argsOf[second], isNot(contains('--extractor-args')));
      final live = _format('95', vcodec: 'avc1', acodec: 'mp4a', height: 720, protocol: 'https');
      engine.runs[second]!.complete(EngineResult(exitCode: 0, stdout: ytJson([live]), stderr: ''));
      expect((await f).video.single.hasAudio, isTrue);
    });
  });
}
