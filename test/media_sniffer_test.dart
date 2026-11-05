import 'package:fetchnet/features/browser/media_sniffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('videos are classified as video', () {
    expect(MediaSniffer.classify('https://cdn.example.com/v/clip.mp4?token=1'), SniffedKind.video);
    expect(MediaSniffer.classify('https://cdn.example.com/v/clip.webm'), SniffedKind.video);
    expect(MediaSniffer.classify('https://x.example/stream?mime=video%2Fmp4&id=3'), SniffedKind.video);
    // Extension-less URL loaded by a <video> element.
    expect(MediaSniffer.classify('https://media.example/play/abc123', hint: 'video'), SniffedKind.video);
    expect(MediaSniffer.classify('https://media.example/p/abc', contentType: 'video/mp4'), SniffedKind.video);
  });

  test('streams and audio', () {
    expect(MediaSniffer.classify('https://e.example/hls/chunklist_b800.m3u8'), SniffedKind.hls);
    expect(MediaSniffer.classify('https://e.example/manifest.mpd'), SniffedKind.dash);
    expect(MediaSniffer.classify('https://e.example/a/song.mp3'), SniffedKind.audio);
    expect(MediaSniffer.classify('https://e.example/x', contentType: 'application/vnd.apple.mpegurl'), SniffedKind.hls);
    expect(MediaSniffer.classify('https://e.example/dash_audio/track.mp4'), SniffedKind.audio);
  });

  test('segments are skipped, playlists are not', () {
    expect(MediaSniffer.isSegment('https://e.example/hls/seg-12-v1.ts'), isTrue);
    expect(MediaSniffer.isSegment('https://e.example/dash/chunk-stream0-00012.m4s'), isTrue);
    expect(MediaSniffer.isSegment('https://e.example/v/segment5.mp4'), isTrue);
    expect(MediaSniffer.isSegment('https://e.example/v/init-stream0.m4s'), isTrue);
    expect(MediaSniffer.isSegment('https://e.example/hls/chunklist_b800.m3u8'), isFalse);
    expect(MediaSniffer.isSegment('https://e.example/v/clip.mp4'), isFalse);
  });

  test('byte-range pieces collapse to one file', () {
    final a = MediaSniffer.normalize('https://scontent.example/v/1.mp4?_nc_ht=x&bytestart=0&byteend=900');
    final b = MediaSniffer.normalize('https://scontent.example/v/1.mp4?_nc_ht=x&bytestart=901&byteend=2000');
    expect(a, b);
    expect(a, 'https://scontent.example/v/1.mp4?_nc_ht=x');
  });

  test('non-media is ignored', () {
    expect(MediaSniffer.classify('https://e.example/app.js'), isNull);
    expect(MediaSniffer.worthProbing('https://e.example/logo.png'), isFalse);
    expect(MediaSniffer.worthProbing('https://e.example/video/play?id=9'), isTrue);
  });

  test('content decides audio vs video', () {
    List<int> box(String handler) => [0, 0, 0, 33, ...'hdlr'.codeUnits, 0, 0, 0, 0, 0, 0, 0, 0, ...handler.codeUnits];
    final audioMp4 = [...'....ftypisom'.codeUnits, ...box('soun')];
    final videoMp4 = [...'....ftypisom'.codeUnits, ...box('vide'), ...box('soun')];
    expect(MediaSniffer.kindFromBytes(audioMp4), SniffedKind.audio);
    expect(MediaSniffer.kindFromBytes(videoMp4), SniffedKind.video);
    expect(MediaSniffer.kindFromBytes([0x1A, 0x45, 0xDF, 0xA3, ...'....A_OPUS'.codeUnits]), SniffedKind.audio);
    expect(MediaSniffer.kindFromBytes([0x1A, 0x45, 0xDF, 0xA3, ...'..V_VP9..A_OPUS'.codeUnits]), SniffedKind.video);
    expect(MediaSniffer.kindFromBytes([...'ID3'.codeUnits, 4, 0, 0, 0]), SniffedKind.audio);
    expect(MediaSniffer.kindFromBytes([0xFF, 0xFB, 0x90, 0x64]), SniffedKind.audio);
    expect(MediaSniffer.kindFromBytes([...'....ftypisom'.codeUnits, ...'mdat'.codeUnits]), isNull);
  });

  test('playlists and manifests', () {
    const audioMaster = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"\naudio/128k.m3u8\n';
    const videoMaster =
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"\nv/360.m3u8\n';
    const audioMedia = '#EXTM3U\n#EXTINF:6.0,\nseg0.aac\n#EXTINF:6.0,\nseg1.aac\n';
    expect(MediaSniffer.kindFromHlsPlaylist(audioMaster), SniffedKind.audio);
    expect(MediaSniffer.kindFromHlsPlaylist(videoMaster), SniffedKind.video);
    expect(MediaSniffer.kindFromHlsPlaylist(audioMedia), SniffedKind.audio);
    expect(MediaSniffer.kindFromDashManifest('<AdaptationSet contentType="audio" mimeType="audio/mp4">'), SniffedKind.audio);
    expect(MediaSniffer.kindFromDashManifest('<AdaptationSet mimeType="video/mp4">'), SniffedKind.video);
  });
}
