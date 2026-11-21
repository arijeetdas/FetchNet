import 'package:fetchnet/models/download_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask _task({bool merge = false, int? size}) => DownloadTask(
      id: 't',
      url: 'u',
      title: 'Video',
      fileBaseName: 'Video',
      option: DownloadOption(kind: MediaKind.video, label: '720p', extension: 'mp4', formatArgs: const [], needsMerge: merge, sizeBytes: size),
      requestArgs: const [],
    );

void main() {
  // yt-dlp's progress for a real HLS stream (64 fragments): only an
  // estimate of the size, which it recomputes with every fragment.
  const hls = [
    (1024, 17434368, 0, 64),
    (261120, 25757440, 0, 64),
    (1372860, 21585408, 4, 64),
    (2632648, 21497173, 8, 64),
    (3497636, 20234816, 11, 64),
    (4162216, 20323766, 13, 64),
    (5076460, 20215175, 16, 64),
    (6033568, 20463424, 19, 64),
    (7145024, 20644296, 22, 64),
    (8046860, 20798237, 25, 64),
    (8769156, 20903881, 27, 64),
    (9767812, 21154972, 30, 64),
    (11077044, 21612303, 33, 64),
    (12280620, 21990593, 36, 64),
    (13289804, 21656096, 39, 64),
    (14161560, 21883969, 42, 64),
    (15790744, 22909713, 44, 64),
    (16587492, 22581418, 47, 64),
    (17178900, 22326179, 49, 64),
    (17960476, 22039218, 52, 64),
    (19102928, 22603301, 54, 64),
    (19906520, 22780195, 56, 64),
    (21028616, 23030941, 59, 64),
    (21966192, 22833825, 61, 64),
  ];

  test('a stream in fragments: the percentage only goes up, and the size stays put', () {
    final task = _task();
    final shownSizes = <int>{};
    var last = 0.0;
    for (final (done, estimate, fragment, fragments) in hls) {
      task.reportProgress(downloaded: done, estimatedTotal: estimate, fragmentIndex: fragment.toDouble(), fragmentCount: fragments.toDouble());
      expect(task.progress, greaterThanOrEqualTo(last), reason: 'at $done bytes');
      last = task.progress!;
      shownSizes.add(task.totalBytes!);
      expect(task.totalIsEstimate, isTrue);
      expect(task.downloadedBytes, done);
    }
    // yt-dlp's estimate changed 24 times; the size shown, only for real
    // changes (17.4 MB at the very start, then ~21.6 MB, ~22.9 MB).
    expect(shownSizes.length, lessThanOrEqualTo(4));
    expect(last, greaterThan(0.9));
    expect(last, lessThan(1)); // not "done" until yt-dlp is
  });

  test('video + audio: one size and one percentage for both', () {
    // The format list said ~110 MB (100 MB video + 10 MB audio).
    final task = _task(merge: true, size: 110000000);
    task.reportProgress(downloaded: 50000000, exactTotal: 98000000);
    expect(task.totalBytes, 110000000);
    expect(task.totalIsEstimate, isTrue); // the audio's size is a guess still
    expect(task.progress, closeTo(0.445, 0.01));
    task.reportProgress(downloaded: 98000000, exactTotal: 98000000);
    final videoDone = task.progress!;
    // The audio starts: its bytes count from zero, the total becomes exact.
    task.reportProgress(downloaded: 100000, exactTotal: 9000000);
    expect(task.partIndex, 1);
    expect(task.totalBytes, 107000000);
    expect(task.totalIsEstimate, isFalse);
    expect(task.downloadedBytes, 98100000);
    expect(task.progress, greaterThanOrEqualTo(videoDone));
    task.reportProgress(downloaded: 9000000, exactTotal: 9000000);
    expect(task.progress, 1);
  });

  test('video + audio without sizes in the format list: each part fills half', () {
    final task = _task(merge: true);
    task.reportProgress(downloaded: 40, exactTotal: 100);
    expect(task.progress, 0.2);
    expect(task.totalBytes, 100); // this part's own size ("Downloading video")
    task.reportProgress(downloaded: 100, exactTotal: 100);
    task.reportProgress(downloaded: 5, exactTotal: 10);
    expect(task.partIndex, 1);
    expect(task.progress, 0.75);
    expect(task.totalBytes, 110);
  });

  test('a fragment retried halfway isn\'t taken for the audio starting', () {
    final task = _task(merge: true, size: 1000);
    task.reportProgress(downloaded: 400, exactTotal: 900);
    final before = task.progress!;
    task.reportProgress(downloaded: 150, exactTotal: 900);
    expect(task.partIndex, 0);
    expect(task.progress, before);
  });

  test('a retry starts the numbers over', () {
    final task = _task()..reportProgress(downloaded: 50, exactTotal: 100);
    task.resetProgress();
    expect([task.progress, task.totalBytes, task.downloadedBytes, task.partIndex], [null, null, null, 0]);
    task.reportProgress(downloaded: 10, exactTotal: 100);
    expect(task.progress, 0.1);
  });
}
