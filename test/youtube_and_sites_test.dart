import 'package:fetchnet/features/youtube/youtube_screen.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/sites_service.dart';
import 'package:fetchnet/services/web_session.dart';
import 'package:fetchnet/services/youtube_client.dart';
import 'package:fetchnet/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebSession', () {
    test('baseDomain keeps the registrable domain', () {
      expect(WebSession.baseDomain('www.youtube.com'), 'youtube.com');
      expect(WebSession.baseDomain('m.facebook.com'), 'facebook.com');
      expect(WebSession.baseDomain('www.bbc.co.uk'), 'bbc.co.uk');
      expect(WebSession.baseDomain('x.com'), 'x.com');
    });

    test('cleanUserAgent removes the WebView markers', () {
      const ua = 'Mozilla/5.0 (Linux; Android 15; Pixel 9; wv) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Version/4.0 Chrome/141.0.7390.122 Mobile Safari/537.36';
      final clean = WebSession.cleanUserAgent(ua);
      expect(clean, isNot(contains('; wv')));
      expect(clean, isNot(contains('Version/4.0')));
      expect(clean, contains('Chrome/141.0.7390.122 Mobile Safari/537.36'));
    });

    test('YouTube links are recognised (not YouTube Music)', () {
      expect(isYouTubeUrl('https://www.youtube.com/watch?v=abc'), isTrue);
      expect(isYouTubeUrl('https://m.youtube.com/'), isTrue);
      expect(isYouTubeUrl('https://youtu.be/dQw4w9WgXcQ'), isTrue);
      expect(isYouTubeUrl('https://music.youtube.com/'), isFalse);
      expect(isYouTubeUrl('https://notyoutube.com/'), isFalse);
    });
  });

  group('YouTube links', () {
    test('parseYouTubeLink finds videos and searches', () {
      expect(parseYouTubeLink('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3').videoId, 'dQw4w9WgXcQ');
      expect(parseYouTubeLink('https://youtu.be/dQw4w9WgXcQ').videoId, 'dQw4w9WgXcQ');
      expect(parseYouTubeLink('https://www.youtube.com/shorts/dQw4w9WgXcQ').videoId, 'dQw4w9WgXcQ');
      expect(parseYouTubeLink('https://www.youtube.com/results?search_query=lofi+beats').query, 'lofi beats');
      final home = parseYouTubeLink('https://www.youtube.com/');
      expect(home.videoId, isNull);
      expect(home.query, isNull);
    });
  });

  group('Sites', () {
    const extractors = {'youtube', 'twitter', 'Dailymotion', 'DailymotionPlaylist', 'vimeo', 'twitch:stream', 'BBC', 'generic'};

    test('isSupportedBy matches extractor names', () {
      expect(SitesService.isSupportedBy('www.dailymotion.com', extractors), isTrue);
      expect(SitesService.isSupportedBy('vimeo.com', extractors), isTrue);
      expect(SitesService.isSupportedBy('www.twitch.tv', extractors), isTrue);
      expect(SitesService.isSupportedBy('www.bbc.co.uk', extractors), isTrue);
      expect(SitesService.isSupportedBy('x.com', extractors), isTrue);
      expect(SitesService.isSupportedBy('example.com', extractors), isFalse);
      expect(SitesService.isSupportedBy('generic.com', extractors), isFalse);
    });

    test('site name comes from og:site_name, then the title', () {
      expect(
        SitesService.siteNameFromHtml('<meta content="Dailymotion" property="og:site_name">', 'dailymotion'),
        'Dailymotion',
      );
      expect(
        SitesService.siteNameFromHtml('<title>Watch great videos - Vimeo</title>', 'vimeo'),
        'Vimeo',
      );
      expect(SitesService.siteNameFromHtml('<p>no title</p>', 'x'), isNull);
    });

    test('icons prefer apple-touch-icon and skip SVG', () {
      const html = '<link rel="icon" href="/fav.svg" type="image/svg+xml">'
          '<link rel="icon" sizes="192x192" href="/icon-192.png">'
          '<link rel="apple-touch-icon" sizes="180x180" href="/apple.png">';
      expect(SitesService.iconsFromHtml(html), ['/apple.png', '/icon-192.png']);
    });
  });

  group('Google account', () {
    test('parseListAccounts reads name, email and a sharper photo', () {
      const body = '["gaia.l.a.r",[["gaia.l.a",1,"Ada Lovelace","ada@example.com",'
          '"https://lh3.googleusercontent.com/a/photo=s48-c",1,1,0,null,1,"123",null,null,null,null,1]]]';
      final p = YouTubeService.parseListAccounts(body)!;
      expect(p.name, 'Ada Lovelace');
      expect(p.email, 'ada@example.com');
      expect(p.avatarUrl, 'https://lh3.googleusercontent.com/a/photo=s256-c');
    });

    test('parseListAccounts returns null without accounts', () {
      expect(YouTubeService.parseListAccounts('["gaia.l.a.r",[]]'), isNull);
    });
  });

  group('YouTube data', () {
    test('extractJsonObject handles braces inside strings', () {
      const html = 'var ytInitialData = {"a":"}{","b":{"c":[1,2]}};</script>';
      final json = extractJsonObject(html, html.indexOf('{'));
      expect(json, {'a': '}{', 'b': {'c': [1, 2]}});
    });

    test('parseFeed reads classic and lockup cards, shorts and the continuation', () {
      final data = {
        'richGridRenderer': {
          'contents': [
            {
              'richItemRenderer': {
                'content': {
                  'videoRenderer': {
                    'videoId': 'aaaaaaaaaaa',
                    'title': {'runs': [{'text': 'Classic video'}]},
                    'thumbnail': {'thumbnails': [{'url': '//i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg'}]},
                    'ownerText': {'runs': [{'text': 'Channel A'}]},
                    'shortViewCountText': {'simpleText': '1.2M views'},
                    'publishedTimeText': {'simpleText': '2 days ago'},
                    'lengthText': {'simpleText': '12:34'},
                  },
                },
              },
            },
            {
              'richItemRenderer': {
                'content': {
                  'lockupViewModel': {
                    'contentId': 'bbbbbbbbbbb',
                    'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
                    'contentImage': {
                      'thumbnailViewModel': {
                        'image': {'sources': [{'url': 'https://i.ytimg.com/vi/bbbbbbbbbbb/hq.jpg'}]},
                        'overlays': [
                          {
                            'thumbnailBottomOverlayViewModel': {
                              'badges': [
                                {'thumbnailBadgeViewModel': {'text': '3:05'}},
                              ],
                            },
                          },
                        ],
                      },
                    },
                    'metadata': {
                      'lockupMetadataViewModel': {
                        'title': {'content': 'Lockup video'},
                        'metadata': {
                          'contentMetadataViewModel': {
                            'metadataRows': [
                              {'metadataParts': [{'text': {'content': 'Channel B'}}]},
                              {
                                'metadataParts': [
                                  {'text': {'content': '5K views'}},
                                  {'text': {'content': '1 hour ago'}},
                                ],
                              },
                            ],
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
            {
              'richItemRenderer': {
                'content': {
                  'lockupViewModel': {'contentId': 'PLxyz', 'contentType': 'LOCKUP_CONTENT_TYPE_PLAYLIST'},
                },
              },
            },
            {
              'richSectionRenderer': {
                'content': {
                  'richShelfRenderer': {
                    'contents': [
                      {
                        'richItemRenderer': {
                          'content': {
                            'shortsLockupViewModel': {
                              'entityId': 'shorts-shelf-item-ccccccccccc',
                              'overlayMetadata': {
                                'primaryText': {'content': 'A short'},
                                'secondaryText': {'content': '9K views'},
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            },
            {'richItemRenderer': {'content': {'adSlotRenderer': {'videoId': 'ddddddddddd'}}}},
            {
              'continuationItemRenderer': {
                'continuationEndpoint': {'continuationCommand': {'token': 'NEXT'}},
              },
            },
          ],
        },
      };
      final page = YouTubeClient.parseFeed(data);
      expect(page.items.map((v) => v.id), ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc']);
      final classic = page.items[0];
      expect(classic.title, 'Classic video');
      expect(classic.thumbnail, 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg');
      expect(classic.stats, '1.2M views · 2 days ago');
      expect(classic.duration, '12:34');
      final lockup = page.items[1];
      expect(lockup.channel, 'Channel B');
      expect(lockup.views, '5K views');
      expect(lockup.duration, '3:05');
      expect(page.items[2].isShort, isTrue);
      expect(page.continuation, 'NEXT');
    });
  });

  group('MediaInfo YouTube helpers', () {
    test('tags, id and thumbnail candidates', () {
      const json = '{"id":"dQw4w9WgXcQ","title":"T","extractor_key":"Youtube",'
          '"webpage_url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","tags":["Music","music","Pop"," "],'
          '"thumbnails":[{"url":"https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"}]}';
      final info = MediaInfo.parse(json, sourceUrl: 'https://youtu.be/dQw4w9WgXcQ');
      expect(info.isYouTube, isTrue);
      expect(info.tags, ['Music', 'Pop']);
      final candidates = info.youtubeThumbnailCandidates;
      expect(candidates.first.url, 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg');
      expect(candidates.any((c) => c.extension == 'webp'), isTrue);
    });
  });
}
