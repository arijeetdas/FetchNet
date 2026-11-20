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
