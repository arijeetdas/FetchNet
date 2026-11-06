import 'package:fetchnet/models/download_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/history_store.dart';
import 'package:fetchnet/widgets/motion/motion_core.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';

HistoryEntry entry(String id, DownloadStatus status, String? path, int minute) => HistoryEntry(
      id: id,
      url: 'https://example.com/$id',
      title: id,
      fileName: id,
      kind: MediaKind.video,
      quality: '1080p',
      status: status,
      createdAt: DateTime(2026, 1, 1, 12, minute),
      filePath: path,
    );

void main() {
  group('keyframes', () {
    const frames = [Kf(0, 0), Kf(50, 10), Kf(100, 0)];

    test('hits keyframe values exactly and holds outside the range', () {
      expect(keyframes(frames, 0), 0);
      expect(keyframes(frames, 50), 10);
      expect(keyframes(frames, 100), 0);
      expect(keyframes(frames, 150), 0);
    });

    test('linear segments interpolate; per-keyframe curves apply to their segment', () {
      expect(keyframes(frames, 25, curve: Curves.linear), closeTo(5, 1e-9));
      const custom = [Kf(0, 0, Curves.easeIn), Kf(100, 1)];
      expect(keyframes(custom, 50, curve: Curves.linear), closeTo(Curves.easeIn.transform(0.5), 1e-9));
    });

    test('loops are seamless: the end of a cycle equals its start', () {
      // A whole number of cycles lands on the seam (0% ≡ 100%, floating point either side).
      final seam = loopPercent(4.8 * 3, 4.8);
      expect(seam < 1e-6 || seam > 100 - 1e-6, isTrue);
      expect(keyframes(frames, seam), closeTo(keyframes(frames, 0), 1e-4));
      expect(loopPercent(-1.2, 4.8), closeTo(75, 1e-9));
    });
  });

  group('history duplicates', () {
    test('one record per saved file, newest kept; failures and ids untouched', () {
      final list = [
        entry('new', DownloadStatus.completed, '/dl/Song.mp3', 30),
        entry('fail', DownloadStatus.failed, null, 20),
        entry('old', DownloadStatus.completed, '/dl/Song.mp3', 10),
        entry('other', DownloadStatus.completed, '/dl/Clip.mp4', 5),
        entry('new', DownloadStatus.completed, '/dl/Song.mp3', 1),
      ];
      expect(HistoryStore.dedupe(list).map((e) => e.id), ['new', 'fail', 'other']);
    });
  });
}
