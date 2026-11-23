import 'dart:convert';

import 'package:fetchnet/models/creator_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Times', () {
    test('typed times', () {
      expect(parseClock('1:05'), const Duration(seconds: 65));
      expect(parseClock('1:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(parseClock('65'), const Duration(seconds: 65));
      expect(parseClock('0:07,5'), const Duration(milliseconds: 7500));
      expect(parseClock('1:75'), isNull);
      expect(parseClock('abc'), isNull);
      expect(parseClock(''), isNull);
    });

    test('labels, file names and yt-dlp sections', () {
      expect(clockLabel(const Duration(seconds: 65)), '1:05');
      expect(clockLabel(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      expect(clockLabel(const Duration(milliseconds: 7500)), '0:07.5');
      expect(fileTime(const Duration(seconds: 70)), '1m10s');
      expect(fileTime(const Duration(hours: 1, seconds: 3)), '1h00m03s');
      expect(sectionTime(const Duration(seconds: 70)), '70');
      expect(sectionTime(const Duration(milliseconds: 70250)), '70.25');
    });
  });

  group('Jobs', () {
    test("a clip's part download (the direct cut's fallback) never re-encodes in yt-dlp", () {
      const clip = CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100));
      expect(clip.ytDlpArgs(), ['--download-sections', '*70-100']);
      const quick = CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100), exactCuts: false);
      expect(quick.ytDlpArgs(), ['--download-sections', '*70-100']);
      expect(clip.length, const Duration(seconds: 30));
      expect(clip.nameSuffix(), '(clip 1m10s-1m40s)');
      expect(clip.describe(), 'Clip 1:10–1:40');
    });

    test('a snapshot downloads two seconds from its moment', () {
      const snap = CreatorJob.snapshot(at: Duration(seconds: 42), snapshotFormat: SnapshotFormat.png);
      expect(snap.ytDlpArgs(), ['--download-sections', '*42-44', '--force-keyframes-at-cuts']);
      expect(snap.describe(), 'Snapshot at 0:42 · PNG');
      expect(snap.nameSuffix(), '(at 0m42s)');
    });

    test('jobs survive a restart (the queue is saved)', () {
      const short = CreatorJob.clip(start: Duration(seconds: 1), end: Duration(seconds: 9), shorts: true, background: ShortsBackground.blur);
      final back = CreatorJob.fromJson(jsonDecode(jsonEncode(short.toJson())))!;
      expect([back.start, back.end, back.shorts, back.background, back.exactCuts], [short.start, short.end, true, ShortsBackground.blur, true]);
      const snap = CreatorJob.snapshot(at: Duration(milliseconds: 1500), snapshotFormat: SnapshotFormat.png);
      final snapBack = CreatorJob.fromJson(jsonDecode(jsonEncode(snap.toJson())))!;
      expect([snapBack.snapshotAt, snapBack.snapshotFormat], [snap.snapshotAt, SnapshotFormat.png]);
      expect(CreatorJob.fromJson({'start': 5, 'end': 2}), isNull);
    });
  });

  group('Shorts & Reels', () {
    test('a phone video recorded sideways counts as it is shown', () {
      final turned = VideoShape.fromProbe({
        'streams': [
          {
            'width': 1920,
            'height': 1080,
            'side_data_list': [
              {'rotation': -90},
            ],
          },
        ],
      })!;
      expect([turned.width, turned.height, turned.landscape], [1080, 1920, false]);
      final flat = VideoShape.fromProbe({
        'streams': [
          {'width': 1280, 'height': 720},
        ],
      })!;
      expect(flat.landscape, isTrue);
      expect(VideoShape.fromProbe({'streams': []}), isNull);
    });

    String filter(List<String> args) => args[args.indexOf('-filter_complex') + 1];

    test('the canvas is 9:16, at most 1080x1920, and never upscales', () {
      for (final (w, h, cw, ch) in [(1920, 1080, 1080, 1920), (3840, 2160, 1080, 1920), (1280, 720, 720, 1280), (854, 480, 480, 852)]) {
        final args = shortsArgs(input: 'in', output: 'out.mp4', shape: VideoShape(w, h), background: ShortsBackground.black);
        expect(filter(args), contains('scale=$cw:-2'), reason: '${w}x$h');
        expect(filter(args), contains('pad=$cw:$ch'), reason: '${w}x$h');
      }
    });

    test('black bars or a blurred copy; H.264 + AAC with progress', () {
      final black = shortsArgs(input: 'in', output: 'out.mp4', shape: const VideoShape(1920, 1080), background: ShortsBackground.black);
      expect(filter(black), contains('color=black'));
      expect(filter(black), isNot(contains('boxblur')));
      final blur = shortsArgs(input: 'in', output: 'out.mp4', shape: const VideoShape(1920, 1080), background: ShortsBackground.blur);
      expect(filter(blur), contains('boxblur'));
      expect(filter(blur), contains('overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2'));
      expect(blur, containsAllInOrder(['-c:v', 'libx264', '-c:a', 'aac', '-progress', 'pipe:1', 'out.mp4']));
    });

    test('a snapshot is the first frame (JPG at high quality)', () {
      expect(snapshotArgs(input: 'in', output: 'a.jpg', format: SnapshotFormat.jpg), containsAllInOrder(['-frames:v', '1', '-q:v', '2', 'a.jpg']));
      expect(snapshotArgs(input: 'in', output: 'a.png', format: SnapshotFormat.png), isNot(contains('-q:v')));
    });
  });

  group('Direct cuts', () {
    const clip = CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100));
    const v = FfInput('http://127.0.0.1:1/t/0', ['-rw_timeout', '30000000']);
    const a = FfInput('http://127.0.0.1:1/t/1');

    test('the part is copied out of each stream, read only around it', () {
      final args = streamCopyArgs(video: v, audio: a, job: clip, output: 'part.mp4');
      expect(args, containsAllInOrder(['-rw_timeout', '30000000', '-ss', '70', '-t', '32', '-i', v.url, '-ss', '70', '-t', '32', '-i', a.url]));
      expect(args, containsAllInOrder(['-t', '30', '-map', '0:v:0', '-map', '1:a:0?', '-c', 'copy']));
      // Kept timestamps: the MP4 edit list starts players at the start.
      expect(args, isNot(contains('-avoid_negative_ts')));
      expect(args.last, 'part.mp4');
      // A video with its own sound.
      expect(streamCopyArgs(video: v, audio: null, job: clip, output: 'p.mp4'), containsAllInOrder(['-map', '0:v:0', '-map', '0:a:0?']));
    });

    test('exact cuts and 9:16 are encoded from the local copy', () {
      final exact = clipEncodeArgs(input: 'part.mp4', job: clip, output: 'out.mp4', preset: 'superfast');
      expect(exact, containsAllInOrder(['-i', 'part.mp4', '-t', '30', '-map', '0:v:0', '-c:v', 'libx264', '-preset', 'superfast']));
      expect(exact, isNot(contains('-ss')));
      const shorts = CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100), shorts: true);
      final made = clipEncodeArgs(input: 'part.mp4', job: shorts, output: 'out.mp4', shape: const VideoShape(1920, 1080));
      expect(made, containsAllInOrder(['-filter_complex', shortsGraph(const VideoShape(1920, 1080), ShortsBackground.black), '-map', '[v]']));
      // Already portrait: no 9:16 graph.
      expect(clipEncodeArgs(input: 'p', job: shorts, output: 'o.mp4', shape: const VideoShape(1080, 1920)), isNot(contains('-filter_complex')));
    });

    test("a song's part, saved as its format asks, with its tags", () {
      final args = streamAudioClipArgs(
        audio: a,
        job: clip,
        output: 'song.mp3',
        audioCodec: const ['-c:a', 'libmp3lame', '-b:a', '320k'],
        metadata: const {'title': 'Song', 'artist': 'Band', 'album': ' '},
      );
      expect(args, containsAllInOrder(['-ss', '70', '-t', '32', '-i', a.url, '-t', '30', '-map', '0:a:0', '-vn', '-c:a', 'libmp3lame']));
      expect(args, containsAllInOrder(['-metadata', 'title=Song', '-metadata', 'artist=Band']));
      expect(args.where((x) => x.startsWith('album=')), isEmpty);
      expect(args, containsAllInOrder(['-id3v2_version', '3']));
    });

    test('audio targets: converted, or copied when already right', () {
      void same((String, List<String>) got, String ext, List<String> args) {
        expect(got.$1, ext);
        expect(got.$2, args);
      }

      const mp3 = AudioTarget(format: 'mp3', quality: '320K');
      same(mp3.encode(codec: 'opus', sourceExt: 'webm'), 'mp3', ['-c:a', 'libmp3lame', '-b:a', '320k']);
      same(const AudioTarget(format: 'mp3', quality: '2').encode(codec: 'opus', sourceExt: 'webm'), 'mp3', ['-c:a', 'libmp3lame', '-q:a', '2']);
      same(const AudioTarget(format: 'm4a').encode(codec: 'mp4a.40.2', sourceExt: 'm4a'), 'm4a', ['-c:a', 'copy']);
      expect(const AudioTarget(format: 'm4a').encode(codec: 'opus', sourceExt: 'webm').$2, contains('aac'));
      same(const AudioTarget().encode(codec: 'opus', sourceExt: 'webm'), 'opus', ['-c:a', 'copy']);
      same(const AudioTarget(format: 'best').encode(codec: 'mp4a.40.5', sourceExt: 'm4a'), 'm4a', ['-c:a', 'copy']);
      expect(AudioTarget.fromArgs(const ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '192K']).quality, '192K');
      expect(AudioTarget.fromArgs(const ['-f', 'ba']).format, isNull);
    });

    test('a snapshot downloads only video', () {
      expect(videoOnlyFormatArgs(const ['-f', '137+140/bv*+ba/b', '--merge-output-format', 'mp4']), ['-f', '137/bv*/b', '--merge-output-format', 'mp4']);
      expect(videoOnlyFormatArgs(const ['-x']), ['-x']);
    });

    test('a snapshot seeks in the stream itself', () {
      final args = snapshotArgs(input: v.url, inputOptions: v.options, output: 'a.jpg', format: SnapshotFormat.jpg, seek: const Duration(seconds: 42));
      expect(args, containsAllInOrder(['-rw_timeout', '30000000', '-ss', '42', '-i', v.url, '-frames:v', '1']));
    });
  });
}
