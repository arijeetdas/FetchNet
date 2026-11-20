import 'package:fetchnet/features/browser/ad_blocker.dart';
import 'package:fetchnet/features/browser/browser_files.dart';
import 'package:fetchnet/features/browser/media_sniffer.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Ad blocker', () {
    test('blocks ad, tracker and pop-up networks with their subdomains', () {
      expect(AdBlocker.isBlocked('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'), isTrue);
      expect(AdBlocker.isBlocked('https://www.google-analytics.com/analytics.js'), isTrue);
      expect(AdBlocker.isBlocked('https://c.popads.net/pop.js'), isTrue);
      expect(AdBlocker.isBlocked('https://a.exosrv.com/x'), isTrue);
    });

    test('leaves sites, sign-in and look-alike names alone', () {
      for (final url in [
        'https://www.google.com/search?q=x',
        'https://accounts.google.com/signin',
        'https://fonts.googleapis.com/css',
        'https://www.youtube.com/watch?v=x',
        'https://notpopads.net/',
        'https://example.com/ads/page',
      ]) {
        expect(AdBlocker.isBlocked(url), isFalse, reason: url);
      }
    });

    test('content blockers match what isBlocked does', () {
      final rules = [for (final b in AdBlocker.contentBlockers()) RegExp(b.trigger.urlFilter)];
      bool blocked(String url) => rules.any((r) => r.hasMatch(url));
      expect(blocked('https://securepubads.g.doubleclick.net/tag/js/gpt.js'), isTrue);
      expect(blocked('https://c.popads.net:443/pop.js'), isTrue);
      expect(blocked('https://www.example.com/doubleclick.net'), isFalse);
      expect(blocked('https://notpopads.net/'), isFalse);
      // Every host is in some rule.
      expect(AdBlocker.hosts.every((h) => blocked('https://$h/')), isTrue);
    });

    test('tells a site\'s own pop-ups from other sites', () {
      expect(AdBlocker.siteOf('https://www.example.com/a'), 'example.com');
      expect(AdBlocker.siteOf('https://cdn.player.example.com/a'), 'example.com');
      expect(AdBlocker.siteOf('https://www.bbc.co.uk/news'), 'bbc.co.uk');
      expect(AdBlocker.siteOf('https://example.com'), 'example.com');
    });
  });

  group('What Browser Mode downloads', () {
    test('video, audio, pictures, subtitles and streams; nothing else', () {
      expect(BrowserFileType.detect(url: 'https://x/a', mime: 'video/mp4'), BrowserFileType.video);
      expect(BrowserFileType.detect(url: 'https://x/a', mime: 'audio/mpeg'), BrowserFileType.audio);
      expect(BrowserFileType.detect(url: 'https://x/a', mime: 'image/webp'), BrowserFileType.image);
      expect(BrowserFileType.detect(url: 'https://x/a', mime: 'text/vtt'), BrowserFileType.subtitle);
      expect(BrowserFileType.detect(url: 'https://x/a', mime: 'application/vnd.apple.mpegurl'), BrowserFileType.stream);
      expect(BrowserFileType.detect(url: 'https://x/a.zip', mime: 'application/zip'), isNull);
      expect(BrowserFileType.detect(url: 'https://x/setup.exe'), isNull);
      expect(BrowserFileType.detect(url: 'https://x/a.pdf'), isNull);
      expect(BrowserFileType.detect(url: 'https://x/a', mime: 'image/svg+xml'), isNull);
    });

    test('a generic type falls back to the file name, then the URL', () {
      expect(
        BrowserFileType.detect(url: 'https://x/get?id=1', mime: 'application/octet-stream', fileName: 'Episode 1.mkv'),
        BrowserFileType.video,
      );
      expect(BrowserFileType.detect(url: 'https://x/subs/en.srt?t=1', mime: 'application/octet-stream'), BrowserFileType.subtitle);
      expect(BrowserFileType.detect(url: 'https://x/file', mime: 'application/octet-stream'), isNull);
    });

    test('file names from Content-Disposition', () {
      expect(BrowserFileType.fileNameFromDisposition('attachment; filename="Movie.mp4"'), 'Movie.mp4');
      expect(BrowserFileType.fileNameFromDisposition("attachment; filename*=UTF-8''My%20Song.mp3"), 'My Song.mp3');
      expect(BrowserFileType.fileNameFromDisposition(null), isNull);
      expect(BrowserFileType.extensionOf('https://x/y/video.MP4?a=b'), 'mp4');
      expect(BrowserFileType.extensionOf('https://x/page'), isNull);
    });

    test('subtitles are their own kind, saved with the videos', () {
      expect(BrowserFileType.subtitle.kind, MediaKind.subtitle);
      expect(BrowserFileType.stream.kind, MediaKind.video);
    });
  });

  group('Media detection', () {
    test('subtitle files and <track> elements are found; stream pieces aren\'t', () {
      expect(MediaSniffer.classify('https://cdn.x/subs/english.vtt'), SniffedKind.subtitle);
      expect(MediaSniffer.classify('https://cdn.x/s/en.srt?token=1'), SniffedKind.subtitle);
      expect(MediaSniffer.classify('https://cdn.x/caption', hint: 'track'), SniffedKind.subtitle);
      expect(MediaSniffer.classify('https://cdn.x/c', contentType: 'text/vtt; charset=utf-8'), SniffedKind.subtitle);
      expect(MediaSniffer.isSegment('https://cdn.x/hls/subs/segment-12.vtt'), isTrue);
      expect(MediaSniffer.isSegment('https://cdn.x/subs/english.vtt'), isFalse);
    });

    test('media an embedded player loads keeps the player\'s address', () {
      final sniffer = MediaSniffer(onChanged: () {})..referer = 'https://anime.example/watch/1';
      sniffer.consider('https://cdn.embed.example/v/master.m3u8', frame: 'https://embed.example/e/abc');
      final m = sniffer.found.values.single;
      expect(m.kind, SniffedKind.hls);
      expect(m.referer, 'https://embed.example/e/abc');
      sniffer.consider('https://cdn.example/clip.mp4');
      expect(sniffer.found.values.last.referer, 'https://anime.example/watch/1');
    });
  });
}
