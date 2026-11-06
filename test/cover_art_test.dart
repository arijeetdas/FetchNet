import 'dart:convert';

import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/cover_art.dart';
import 'package:flutter_test/flutter_test.dart';

MediaInfo _info(String link, {String extractor = 'Youtube'}) => MediaInfo.parse(
      jsonEncode({
        'id': 'dQw4w9WgXcQ',
        'title': 'Song',
        'extractor_key': extractor,
        // yt-dlp reports www.youtube.com even for music links.
        'webpage_url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'original_url': link,
        'formats': [],
      }),
      sourceUrl: link,
    );

DownloadOption _audio(String ext) =>
    DownloadOption(kind: MediaKind.audio, label: ext.toUpperCase(), formatArgs: const [], extension: ext);

void main() {
  const music = 'https://music.youtube.com/watch?v=dQw4w9WgXcQ';
  const video = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

  test('music.youtube.com links are recognised', () {
    expect(_info(music).isYouTubeMusic, isTrue);
    expect(_info(video).isYouTubeMusic, isFalse);
    expect(_info('https://vimeo.com/1', extractor: 'Vimeo').isYouTubeMusic, isFalse);
  });

  test('YouTube Music audio gets a square album cover', () {
    final args = coverArtArgs(_info(music), _audio('mp3'), ffmpeg: true, music: true, video: false);
    expect(args, containsAllInOrder(['--embed-thumbnail', '--convert-thumbnails', 'jpg']));
    expect(args.join(' '), contains('crop='));
  });

  test('video audio gets the thumbnail as it is', () {
    final args = coverArtArgs(_info(video), _audio('m4a'), ffmpeg: true, music: false, video: true);
    expect(args, contains('--embed-thumbnail'));
    expect(args.join(' '), isNot(contains('crop=')));
  });

  test('each setting only covers its own kind of link', () {
    expect(coverArtArgs(_info(music), _audio('mp3'), ffmpeg: true, music: false, video: true), isEmpty);
    expect(coverArtArgs(_info(video), _audio('mp3'), ffmpeg: true, music: true, video: false), isEmpty);
  });

  test('nothing without FFmpeg, for video, for other formats or other sites', () {
    expect(coverArtArgs(_info(music), _audio('mp3'), ffmpeg: false, music: true, video: true), isEmpty);
    expect(coverArtArgs(_info(music), _audio('opus'), ffmpeg: true, music: true, video: true), isEmpty);
    final mp4 = const DownloadOption(kind: MediaKind.video, label: '720p', formatArgs: [], extension: 'mp4');
    expect(coverArtArgs(_info(video), mp4, ffmpeg: true, music: true, video: true), isEmpty);
    expect(
      coverArtArgs(_info('https://vimeo.com/1', extractor: 'Vimeo'), _audio('mp3'), ffmpeg: true, music: true, video: true),
      isEmpty,
    );
  });
}
