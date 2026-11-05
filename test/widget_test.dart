import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sanitizeFileName strips illegal characters', () {
    expect(StorageService.sanitizeFileName('  My: "Video" / Part?1. '), 'My Video Part 1');
    expect(StorageService.sanitizeFileName('CON'), 'CON_');
  });

  test('randomFileName has the expected shape', () {
    expect(StorageService.randomFileName(audio: true), matches(RegExp(r'^FetchNet_Audio_\d{8}_[A-Z0-9]{4}$')));
  });

  test('MediaInfo builds video and audio options', () {
    const json = '''
{"title":"Demo","webpage_url":"https://example.com/v","duration":100,"extractor_key":"Example",
 "formats":[
  {"format_id":"a1","vcodec":"none","acodec":"opus","abr":130,"ext":"webm","filesize":1600000},
  {"format_id":"v1","vcodec":"avc1","acodec":"none","height":1080,"fps":60,"ext":"mp4","filesize":50000000},
  {"format_id":"v2","vcodec":"avc1","acodec":"mp4a","height":360,"fps":30,"ext":"mp4","filesize":8000000}
 ]}''';
    final info = MediaInfo.parse(json, sourceUrl: 'https://example.com/v');
    final withFfmpeg = info.videoOptions(ffmpeg: true);
    expect(withFfmpeg.map((o) => o.label), ['1080p', '360p']);
    expect(withFfmpeg.first.needsMerge, isTrue);
    expect(withFfmpeg.first.sizeBytes, 51600000);
    // Without FFmpeg only the muxed 360p stream can be saved.
    expect(info.videoOptions(ffmpeg: false).map((o) => o.label), ['360p']);
    expect(info.audioOptions(ffmpeg: true).first.extension, 'mp3');
    expect(info.audioOptions(ffmpeg: false).single.extension, 'webm');
  });

  test('vertical videos are named by their shorter side', () {
    const json = '''
{"title":"Short","webpage_url":"https://example.com/s","duration":30,
 "formats":[
  {"format_id":"v1","vcodec":"avc1","acodec":"none","width":1080,"height":1920,"fps":60,"ext":"mp4","filesize":19000000},
  {"format_id":"v2","vcodec":"avc1","acodec":"none","width":720,"height":1280,"fps":30,"ext":"mp4","filesize":9000000},
  {"format_id":"a1","vcodec":"none","acodec":"mp4a","abr":128,"ext":"m4a","filesize":500000}
 ]}''';
    final options = MediaInfo.parse(json, sourceUrl: 'x').videoOptions(ffmpeg: true);
    expect(options.map((o) => o.label), ['1080p', '720p']);
    expect(options.map((o) => o.badge), ['HD', 'HD']);
    // The selector still targets the real stream height.
    expect(options.first.formatArgs[1], contains('height=1920'));
  });
}
