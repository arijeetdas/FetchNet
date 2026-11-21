import 'dart:convert';

import 'package:fetchnet/models/download_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/extra_settings.dart';
import 'package:fetchnet/services/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Is it a song?', () {
    test('sites that know the song say its artist and title', () {
      final q = LyricsQuery.fromInfo(MediaInfo(
        url: 'u',
        title: 'Yellow',
        duration: 269,
        raw: const {'artist': 'Coldplay, Someone', 'track': 'Yellow', 'album': 'Parachutes'},
      ))!;
      expect([q.artist, q.track, q.album, q.duration], ['Coldplay', 'Yellow', 'Parachutes', 269]);
    });

    test('an "Artist - Title" music video, cleaned up', () {
      final q = LyricsQuery.fromInfo(MediaInfo(
        url: 'u',
        title: 'Coldplay - Yellow (Official Video) [4K] ft. Guest',
        duration: 270,
        raw: const {},
      ))!;
      expect(q.artist, 'Coldplay');
      expect(q.track, 'Yellow');
    });

    test('an artist\'s "Topic" channel names the artist', () {
      final q = LyricsQuery.fromTitle('Yellow', uploader: 'Coldplay - Topic', duration: 266)!;
      expect([q.artist, q.track], ['Coldplay', 'Yellow']);
    });

    test('podcasts, mixes and plain titles aren\'t songs', () {
      expect(LyricsQuery.fromTitle('My trip to the mountains', uploader: 'Someone', duration: 300), isNull);
      expect(LyricsQuery.fromTitle('DJ - 3 hour mix', duration: 3 * 3600), isNull);
      expect(LyricsQuery.fromTitle('Intro - sound', duration: 10), isNull);
    });
  });

  group('LRCLIB', () {
    String results(List<Map<String, Object?>> r) => jsonEncode(r);

    test('picks synced lyrics by the same artist and length', () async {
      final service = LyricsService(get: (uri) async {
        expect(uri.host, 'lrclib.net');
        return results([
          {'artistName': 'Coldplay', 'trackName': 'Yellow (Live)', 'duration': 320.0, 'syncedLyrics': '[00:01.00] live'},
          {'artistName': 'Other Band', 'trackName': 'Yellow', 'duration': 269.0, 'syncedLyrics': '[00:01.00] other'},
          {'artistName': 'Coldplay', 'trackName': 'Yellow', 'duration': 271.0, 'syncedLyrics': '[00:33.44] Look at the stars'},
          {'artistName': 'Coldplay', 'trackName': 'Yellow', 'duration': 269.0, 'syncedLyrics': null, 'plainLyrics': 'x'},
        ]);
      });
      final lrc = await service.synced(const LyricsQuery(artist: 'Coldplay', track: 'Yellow', duration: 269));
      expect(lrc, '[00:33.44] Look at the stars');
    });

    // LRCLIB answers each search with these songs (as it would for words
    // they share).
    LyricsService library(List<Map<String, Object?>> songs, {List<Uri>? asked}) => LyricsService(get: (uri) async {
          asked?.add(uri);
          return results(songs);
        });

    test('a label\'s upload ("Song - Movie | Cast | Singer"): the song, by a singer named in the title', () async {
      final q = LyricsQuery.fromInfo(MediaInfo(
        url: 'u',
        title: 'Kesariya - Brahmāstra | Ranbir Kapoor, Alia Bhatt | Pritam | Arijit Singh | Amitabh Bhattacharya| 4K',
        uploader: 'Sony Music India',
        duration: 172,
        raw: const {'categories': ['Music']},
      ))!;
      expect(q.confident, isFalse);
      final asked = <Uri>[];
      final m = await library([
        {'artistName': 'Someone', 'trackName': 'Brahmastra', 'duration': 172.0, 'syncedLyrics': '[00:01.00] wrong'},
        {'artistName': 'Pritam, Arijit Singh', 'trackName': 'Kesariya (From "Brahmastra")', 'duration': 172.3, 'syncedLyrics': '[00:09.40] right'},
      ], asked: asked).find(q);
      expect(m!.lyrics, '[00:09.40] right');
      expect(m.strong, isTrue);
      expect(asked, isNotEmpty);
    });

    test('the song named first wins over the movie\'s title track', () async {
      final q = LyricsQuery.fromTitle(
        'Channa Mereya - Lyric Video | Ae Dil Hai Mushkil | Karan Johar | Ranbir | Anushka | Pritam | Arijit',
        uploader: 'Sony Music India',
        duration: 345,
      )!;
      final lrc = await library([
        {'artistName': 'Arijit Singh', 'trackName': 'Ae Dil Hai Mushkil', 'duration': 315.0, 'syncedLyrics': '[00:25.00] title track'},
        {'artistName': 'Arijit Singh', 'trackName': 'Channa Mereya', 'duration': 287.0, 'syncedLyrics': '[00:20.00] channa'},
      ]).synced(q);
      expect(lrc, '[00:20.00] channa');
    });

    test('a playlist\'s song (only its title and channel are known)', () async {
      final q = LyricsQuery.fromTitle('Aashiqui 2: Tum Hi Ho 8K Full Song | Arijit Singh | Mithoon', uploader: 'T-Series', duration: 299)!;
      final lrc = await library([
        {'artistName': 'Arijit Singh', 'trackName': 'Tum Hi Ho', 'duration': 261.0, 'syncedLyrics': '[00:11.20] Hum tere bin'},
      ]).synced(q);
      expect(lrc, '[00:11.20] Hum tere bin');
    });

    test('not a song: a video whose title shares words with one gets nothing', () async {
      final q = LyricsQuery.fromTitle('iPhone 16 Review: Worth It? | Tech Talk', uploader: 'Tech Talk', duration: 600)!;
      expect(
        await library([
          {'artistName': 'Fifth Harmony', 'trackName': 'Worth It', 'duration': 224.0, 'syncedLyrics': '[00:01.00] x'},
        ]).synced(q),
        isNull,
      );
    });

    test('a queued song saved by an older FetchNet still looks its lyrics up', () {
      final q = LyricsQuery.fromJson({'artist': 'Coldplay', 'track': 'Yellow', 'duration': 269})!;
      expect([q.artist, q.track, q.confident], ['Coldplay', 'Yellow', true]);
      final again = LyricsQuery.fromJson(LyricsQuery.fromTitle('Song | Movie | Singer', duration: 200)!.toJson())!;
      expect(again.title, 'Song | Movie | Singer');
      expect(LyricsQuery.fromJson({'album': 'x'}), isNull);
    });

    test('nothing that matches: no lyrics', () async {
      final service = LyricsService(get: (_) async => results([
            {'artistName': 'Someone Else', 'trackName': 'Other', 'duration': 100.0, 'syncedLyrics': '[00:01.00] x'},
          ]));
      expect(await service.synced(const LyricsQuery(artist: 'Coldplay', track: 'Yellow')), isNull);
      expect(await LyricsService(get: (_) async => null).synced(const LyricsQuery(artist: 'a', track: 'b')), isNull);
    });
  });

  test('lyrics reach FFmpeg as one quoted value (quotes and new lines kept)', () {
    final args = lyricsEmbedArgs("[00:01.00] It's \"here\"\n[00:02.00] Two", formatArgs: const ['-x']);
    expect(args.first, '--embed-metadata');
    expect(args[1], '--postprocessor-args');
    expect(args[2], startsWith("Metadata+ffmpeg_o:-metadata 'lyrics=[00:01.00] It'\"'\"'s"));
    expect(lyricsEmbedArgs('x', formatArgs: const ['--embed-metadata']).first, '--postprocessor-args');
    expect(args, hasLength(3));
  });

  test('a queued song keeps its lyrics settings across restarts', () {
    final task = DownloadTask(
      id: 't',
      url: 'u',
      title: 'Yellow',
      fileBaseName: 'Yellow',
      option: const DownloadOption(kind: MediaKind.audio, label: 'MP3', extension: 'mp3', formatArgs: []),
      requestArgs: const [],
      lyrics: const LyricsQuery(artist: 'Coldplay', track: 'Yellow', duration: 269),
      lyricsMode: 'both',
    );
    final back = DownloadTask.fromJson(jsonDecode(jsonEncode(task.toJson())) as Map<String, dynamic>)!;
    expect(back.lyrics!.artist, 'Coldplay');
    expect(back.lyrics!.duration, 269);
    expect(back.lyricsMode, 'both');
  });

  test('lyrics picked on Home stay with the queued song', () {
    final task = DownloadTask(
      id: 't',
      url: 'u',
      title: 'Yellow',
      fileBaseName: 'Yellow',
      option: const DownloadOption(kind: MediaKind.audio, label: 'MP3', extension: 'mp3', formatArgs: []),
      requestArgs: const [],
      lyricsText: "[00:33.44] Look at the stars\n[00:37.00] Look how they shine",
      lyricsMode: 'embed',
    );
    final back = DownloadTask.fromJson(jsonDecode(jsonEncode(task.toJson())) as Map<String, dynamic>)!;
    expect(back.lyricsText, task.lyricsText);
    expect(back.lyrics, isNull);
  });

  group('Picking lyrics on Home', () {
    final songs = [
      {'id': 1, 'artistName': 'Coldplay', 'trackName': 'Yellow', 'albumName': 'Parachutes', 'duration': 269.0, 'syncedLyrics': '[00:33.44] Look at the stars'},
      {'id': 2, 'artistName': 'Coldplay', 'trackName': 'Yellow', 'albumName': 'Live', 'duration': 300.0, 'plainLyrics': 'Look at the stars'},
      {'id': 3, 'artistName': 'Someone', 'trackName': 'Yellow Submarine', 'duration': 160.0, 'syncedLyrics': '[00:01.00] In the town'},
      {'id': 4, 'artistName': 'Coldplay', 'trackName': 'Yellow', 'instrumental': true, 'duration': 269.0},
    ];
    final service = LyricsService(get: (_) async => jsonEncode(songs));

    test('the lookup picks synced lyrics and lists the other results too', () async {
      final r = await service.lookup(const LyricsQuery(artist: 'Coldplay', track: 'Yellow', duration: 269, title: 'Coldplay - Yellow'));
      expect(r.best!.album, 'Parachutes');
      expect(r.best!.synced, isTrue);
      // The plain version that fits, then what doesn't; never the instrumental.
      expect([for (final m in r.matches) '${m.track}/${m.album}/${m.synced}'], [
        'Yellow/Parachutes/true',
        'Yellow/Live/false',
        'Yellow Submarine/null/true',
      ]);
    });

    test('a search lists synced lyrics first, then the closest in length', () async {
      final found = await service.search('yellow', duration: 300);
      expect(found.first.synced, isTrue);
      expect(found.last.synced, isFalse);
      expect(await service.search('  '), isEmpty);
    });

    test('the same lyrics listed twice are still two choices (only one is picked)', () {
      final a = LyricsMatch.fromResult({'id': 10, 'artistName': 'Coldplay', 'trackName': 'Yellow', 'albumName': 'Parachutes', 'syncedLyrics': '[00:01.00] x'})!;
      final b = LyricsMatch.fromResult({'id': 11, 'artistName': 'Coldplay', 'trackName': 'Yellow', 'albumName': 'Singles', 'syncedLyrics': '[00:01.00] x'})!;
      expect(a.sameAs(b), isFalse);
      expect(a.sameAs(LyricsMatch.fromResult({'id': 10, 'artistName': 'Coldplay', 'trackName': 'Yellow', 'syncedLyrics': '[00:01.00] x'})!), isTrue);
      final file = LyricsMatch.fromFile('a.lrc', '[00:01.00] x')!;
      expect(file.sameAs(a), isFalse);
      expect(file.sameAs(LyricsMatch.fromFile('a.lrc', '[00:01.00] x')!), isTrue);
    });

    test('a .lrc file keeps its tags and timing; a .txt is plain lyrics', () {
      final lrc = LyricsMatch.fromFile('My song.lrc', '﻿[ti:Yellow]\r\n[ar:Coldplay]\r\n[00:33.44] Look at the stars\r\n[04:20.00] Yellow')!;
      expect([lrc.track, lrc.artist, lrc.synced, lrc.imported, lrc.duration], ['Yellow', 'Coldplay', true, true, 260]);
      expect(lrc.lyrics.startsWith('[ti:Yellow]'), isTrue);
      final txt = LyricsMatch.fromFile('words.txt', 'Look at the stars\nLook how they shine')!;
      expect([txt.track, txt.artist, txt.synced], ['words', '', false]);
      expect(LyricsMatch.fromFile('empty.lrc', '  \n '), isNull);
    });
  });

  test('settings: lyrics inside the song, as a file, or both', () async {
    SharedPreferences.setMockInitialValues({});
    final s = ExtraSettings(await SharedPreferences.getInstance());
    expect(s.lyrics, isFalse);
    expect(s.mergeLyrics, isTrue);
    await s.setKeepLyricsFile(true);
    expect(s.lyricsMode, SubtitleMode.both);
    await s.setMergeLyrics(false);
    expect(s.lyricsMode, SubtitleMode.file);
  });

  test('a playlist\'s size estimate follows the preset', () async {
    SharedPreferences.setMockInitialValues({});
    final s = ExtraSettings(await SharedPreferences.getInstance());
    expect(presetBitrateKbps(s, MediaKind.video), 4500);
    await s.setPresetVideoHeight(720);
    expect(presetBitrateKbps(s, MediaKind.video), 2600);
    await s.setPresetAudio(AudioPreset.mp3Medium);
    expect(presetBitrateKbps(s, MediaKind.audio), 192);
  });
}
