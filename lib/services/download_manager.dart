import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/format.dart';
import '../core/platform/native_bridge.dart';
import '../engine/engine.dart';
import '../models/download_models.dart';
import '../models/media_info.dart';
import 'history_store.dart';
import 'storage_service.dart';

/// Queues and runs downloads, tracks their progress and records history.
class DownloadManager extends ChangeNotifier {
  DownloadManager({required this.engine, required this.storage, required this.history});

  final YtDlpEngine engine;
  final StorageService storage;
  final HistoryStore history;

  static const _maxConcurrent = 3;

  final List<DownloadTask> _tasks = [];
  final Map<String, EngineRun> _runs = {};
  bool _askedNotificationPermission = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _notifyTimer;

  /// Active and failed tasks (completed / cancelled ones leave the list).
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  int get activeCount => _tasks.where((t) => t.isActive).length;

  /// Base names reserved by queued / running downloads.
  Set<String> get reservedNames =>
      _tasks.where((t) => t.isActive).map((t) => t.fileBaseName.toLowerCase()).toSet();

  /// History entries whose file still exists in the download folder under the
  /// name it was saved with.
  List<HistoryEntry> get completedFiles => history.entries
      .where((e) => e.status == DownloadStatus.completed && e.filePath != null && storage.isInDownloadDir(e.filePath!))
      .toList();

  Future<void> enqueue({
    required MediaInfo info,
    required DownloadOption option,
    required String fileBaseName,
  }) async {
    await _askNotificationPermissionOnce();
    final task = DownloadTask(
      id: 'dl-${DateTime.now().microsecondsSinceEpoch}',
      url: info.url,
      title: info.title,
      fileBaseName: fileBaseName,
      option: option,
      requestArgs: info.requestArgs,
      thumbnail: info.thumbnail,
      extractor: info.extractor,
    );
    _tasks.insert(0, task);
    notifyListeners();
    _pump();
  }

  Future<void> retry(DownloadTask failed) async {
    _tasks.remove(failed);
    final task = DownloadTask(
      id: 'dl-${DateTime.now().microsecondsSinceEpoch}',
      url: failed.url,
      title: failed.title,
      fileBaseName: storage.uniqueBaseName(failed.fileBaseName, alsoTaken: reservedNames),
      option: failed.option,
      requestArgs: failed.requestArgs,
      thumbnail: failed.thumbnail,
      extractor: failed.extractor,
    );
    _tasks.insert(0, task);
    notifyListeners();
    _pump();
  }

  void dismiss(DownloadTask task) {
    _tasks.remove(task);
    notifyListeners();
  }

  Future<void> cancel(DownloadTask task) async {
    if (task.status == DownloadStatus.queued) {
      task.status = DownloadStatus.cancelled;
      _tasks.remove(task);
      await _record(task);
      _finishNotification(task);
      notifyListeners();
      return;
    }
    task.stage = 'Cancelling…';
    notifyListeners();
    await _runs[task.id]?.cancel();
  }

  /// Deletes a downloaded file from disk (history keeps the record).
  Future<void> deleteFile(HistoryEntry entry) async {
    final path = entry.filePath;
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await NativeBridge.scanFile(path);
    notifyListeners();
  }

  Future<void> _askNotificationPermissionOnce() async {
    if (_askedNotificationPermission || kIsWeb || !Platform.isAndroid) return;
    _askedNotificationPermission = true;
    await NativeBridge.requestPermission('notifications');
  }

  void _pump() {
    final running = _tasks.where((t) =>
        t.status == DownloadStatus.starting ||
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.processing);
    var slots = _maxConcurrent - running.length;
    // Oldest first.
    for (final task in _tasks.reversed.toList()) {
      if (slots <= 0) break;
      if (task.status != DownloadStatus.queued) continue;
      slots--;
      unawaited(_run(task));
    }
    _syncNotifications();
  }

  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.starting;
    task.stage = 'Starting…';
    notifyListeners();

    final dir = storage.downloadDir ?? await storage.ensureDownloadDir(requestPermission: true);
    if (dir == null) {
      _fail(task, storage.error ?? 'The download folder isn\'t available.');
      return;
    }
    final temp = await storage.workDir('parts/${task.id}');

    final args = <String>[
      ...task.option.formatArgs,
      ...task.requestArgs,
      '--no-playlist',
      '--no-mtime',
      '--newline',
      '--progress',
      '--progress-delta', '0.5',
      '--progress-template',
      'download:FNPROG|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.fragment_index)s|%(progress.fragment_count)s',
      '--progress-template',
      'postprocess:FNPP|%(progress.postprocessor)s|%(progress.status)s',
      '--print', 'after_move:FNFILE|%(filepath)s',
      '-P', 'home:$dir',
      '-P', 'temp:${temp.path}',
      '-o', '${task.fileBaseName.replaceAll('%', '%%')}.%(ext)s',
      '--',
      task.url,
    ];

    final run = engine.start(task.id, args);
    _runs[task.id] = run;
    final sub = run.lines.listen((line) => _onLine(task, line));
    final result = await run.done;
    await sub.cancel();
    _runs.remove(task.id);
    unawaited(_cleanup(temp));

    if (result.cancelled || task.stage == 'Cancelling…') {
      task.status = DownloadStatus.cancelled;
      _tasks.remove(task);
      await _record(task);
      _finishNotification(task);
    } else if (result.ok) {
      await _complete(task, dir);
    } else {
      final message = extractEngineError(result.stderr.isEmpty ? result.stdout : result.stderr);
      _fail(task, message);
    }
    notifyListeners();
    _pump();
  }

  void _onLine(DownloadTask task, String line) {
    if (line.startsWith('FNPROG|')) {
      final parts = line.split('|');
      double? num(int i) => i < parts.length ? double.tryParse(parts[i]) : null;
      final downloaded = num(1)?.toInt();
      final total = (num(2) ?? num(3))?.toInt();
      final fragIndex = num(6);
      final fragCount = num(7);

      if (downloaded != null) {
        // A new part started (video finished, audio begins).
        if (task.lastPartBytes > 0 && downloaded < task.lastPartBytes * 0.5 && task.partIndex < task.expectedParts - 1) {
          task.partIndex++;
        }
        task.lastPartBytes = downloaded;
      }
      double? fraction;
      if (downloaded != null && total != null && total > 0) {
        fraction = (downloaded / total).clamp(0, 1).toDouble();
      } else if (fragIndex != null && fragCount != null && fragCount > 0) {
        fraction = (fragIndex / fragCount).clamp(0, 1).toDouble();
      }
      task.status = DownloadStatus.downloading;
      task.downloadedBytes = downloaded;
      task.totalBytes = total;
      task.speed = num(4);
      task.eta = num(5)?.round();
      task.progress = fraction == null ? null : ((task.partIndex + fraction) / task.expectedParts).clamp(0, 1).toDouble();
      final lastPartDone = fraction != null && fraction >= 0.999 && task.partIndex >= task.expectedParts - 1;
      task.stage = lastPartDone
          ? 'Finishing up…'
          : task.expectedParts > 1
              ? (task.partIndex == 0 ? 'Downloading video' : 'Downloading audio')
              : 'Downloading';
      _throttledNotify();
    } else if (line.startsWith('FNPP|')) {
      final parts = line.split('|');
      final pp = parts.length > 1 ? parts[1] : '';
      final label = switch (pp) {
        'Merger' => 'Merging video and audio…',
        'ExtractAudio' => 'Converting audio…',
        'FFmpegExtractAudio' => 'Converting audio…',
        'VideoConvertor' || 'FFmpegVideoConvertor' || 'VideoRemuxer' || 'FFmpegVideoRemuxer' => 'Converting video…',
        'Metadata' || 'FFmpegMetadata' => 'Adding metadata…',
        'MoveFiles' || 'MoveFilesAfterDownload' => 'Saving…',
        'FixupM3u8' || 'FFmpegFixupM3u8' || 'FixupM4a' || 'FFmpegFixupM4a' => 'Finishing up…',
        _ => 'Processing…',
      };
      task.status = DownloadStatus.processing;
      task.stage = label;
      task.progress = 1;
      _throttledNotify(force: true);
    } else if (line.startsWith('FNFILE|')) {
      task.filePath = line.substring('FNFILE|'.length).trim();
    }
  }

  Future<void> _complete(DownloadTask task, String dir) async {
    var path = task.filePath;
    if (path == null || !File(path).existsSync()) {
      // Fall back to finding the file by its chosen base name.
      try {
        path = Directory(dir)
            .listSync()
            .whereType<File>()
            .where((f) => p.basenameWithoutExtension(f.path) == task.fileBaseName)
            .map((f) => f.path)
            .firstOrNull;
      } catch (_) {
        path = null;
      }
    }
    if (path == null) {
      _fail(task, 'The download finished but the file couldn\'t be found.');
      return;
    }
    task.filePath = path;
    task.status = DownloadStatus.completed;
    task.progress = 1;
    await NativeBridge.scanFile(path);
    _tasks.remove(task);
    await _record(task);
    _finishNotification(task);
  }

  void _fail(DownloadTask task, String message) {
    task.status = DownloadStatus.failed;
    task.error = message;
    task.errorHint = friendlyEngineHint(message);
    task.stage = null;
    unawaited(_record(task));
    _finishNotification(task);
    notifyListeners();
  }

  Future<void> _record(DownloadTask task) async {
    int? size;
    final path = task.filePath;
    if (path != null) {
      try {
        size = File(path).lengthSync();
      } catch (_) {}
    }
    await history.add(HistoryEntry(
      id: task.id,
      url: task.url,
      title: task.title,
      fileName: task.fileBaseName,
      kind: task.option.kind,
      quality: [task.option.label, if (task.option.detail != null) task.option.detail!].join(' · '),
      status: task.status,
      createdAt: task.createdAt,
      completedAt: DateTime.now(),
      filePath: path,
      sizeBytes: size,
      thumbnail: task.thumbnail,
      extractor: task.extractor,
      error: task.error,
    ));
  }

  Future<void> _cleanup(Directory dir) async {
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  void _throttledNotify({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastNotify) > const Duration(milliseconds: 250)) {
      _lastNotify = now;
      _notifyTimer?.cancel();
      notifyListeners();
      _syncNotifications();
    } else {
      _notifyTimer ??= Timer(const Duration(milliseconds: 250), () {
        _notifyTimer = null;
        _lastNotify = DateTime.now();
        notifyListeners();
        _syncNotifications();
      });
    }
  }

  /// Last progress notification per task: (time, "percent|stage").
  final Map<String, (DateTime, String)> _lastNotified = {};

  String _fileName(DownloadTask t) => '${t.fileBaseName}.${t.option.extension}';

  /// Posts / updates the live notification of every active task.
  void _syncNotifications() {
    final now = DateTime.now();
    for (final t in _tasks.where((t) => t.isActive)) {
      final known = t.status == DownloadStatus.downloading && t.progress != null;
      final pct = known ? (t.progress! * 100).round().clamp(0, 100) : -1;
      final key = '$pct|${t.stage}';
      final last = _lastNotified[t.id];
      if (last != null) {
        if (last.$2 == key) continue;
        final sameStage = last.$2.substring(last.$2.indexOf('|') + 1) == '${t.stage}';
        if (sameStage && now.difference(last.$1) < const Duration(milliseconds: 700)) continue;
      }
      _lastNotified[t.id] = (now, key);
      final text = switch (t.status) {
        DownloadStatus.queued => 'Waiting in queue',
        DownloadStatus.downloading => [
            if (known) '$pct%',
            formatSpeed(t.speed),
            formatEta(t.eta),
          ].where((e) => e.isNotEmpty).join(' · '),
        _ => t.stage ?? 'Starting…',
      };
      unawaited(NativeBridge.downloadNotification(
        id: t.id,
        state: 'progress',
        fileName: _fileName(t),
        text: text.isEmpty ? 'Downloading…' : text,
        detail: [t.option.label, if (t.option.detail != null) t.option.detail!].join(' · '),
        progress: pct,
      ));
    }
  }

  /// Turns the task's live notification into its final state.
  void _finishNotification(DownloadTask t) {
    _lastNotified.remove(t.id);
    switch (t.status) {
      case DownloadStatus.completed:
        unawaited(NativeBridge.downloadNotification(
          id: t.id,
          state: 'complete',
          fileName: t.filePath == null ? _fileName(t) : p.basename(t.filePath!),
          path: t.filePath,
          size: () {
            try {
              return formatBytes(File(t.filePath!).lengthSync());
            } catch (_) {
              return '';
            }
          }(),
        ));
      case DownloadStatus.failed:
        unawaited(NativeBridge.downloadNotification(
          id: t.id,
          state: 'failed',
          fileName: _fileName(t),
          text: t.errorHint ?? t.error ?? 'Something went wrong.',
        ));
      default:
        unawaited(NativeBridge.downloadNotification(id: t.id, state: 'cancelled', fileName: _fileName(t)));
    }
  }

  /// Cancel requested from a notification.
  Future<void> cancelById(String id) async {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) {
      unawaited(NativeBridge.downloadNotification(id: id, state: 'cancelled', fileName: ''));
      return;
    }
    await cancel(task);
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }
}
