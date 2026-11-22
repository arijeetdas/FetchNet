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
    test('a clip downloads only its part, exactly when asked', () {
      const clip = CreatorJob.clip(start: Duration(seconds: 70), end: Duration(seconds: 100));
      expect(clip.ytDlpArgs(), ['--download-sections', '*70-100', '--force-keyframes-at-cuts']);
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
}
