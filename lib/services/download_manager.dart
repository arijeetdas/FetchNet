import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/format.dart';
import '../core/platform/native_bridge.dart';
import '../engine/engine.dart';
import '../engine/gallery_engine.dart';
import '../models/download_models.dart';
import '../models/media_info.dart';
import 'extra_settings.dart';
import 'fetch_service.dart';
import 'history_store.dart';
import 'lyrics_service.dart';
import 'storage_service.dart';

/// Extra yt-dlp arguments a download gets from the user's settings.
typedef DownloadArgsProvider = List<String> Function(MediaInfo info, DownloadOption option);

/// Where the queue is kept between runs (one JSON string per task).
class QueueStore {
  const QueueStore({required this.load, required this.save});

  final List<String> Function() load;
  final Future<void> Function(List<String> tasks) save;
}

/// Queues and runs downloads, tracks their progress and records history.
///
/// The queue survives closing the app ([queueStore]): downloads that were
/// running carry on from their partial files, paused ones stay paused.
/// How many run at once, a speed limit and "Wi-Fi only" come from
/// [settings].
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.engine,
    required this.storage,
    required this.history,
    this.extraArgs,
    this.cookieArgs,
    this.gallery,
    this.settings,
    this.queueStore,
    this.onWifi,
    this.lyricsService,
  }) {
    settings?.addListener(_onSettings);
    engine.status.addListener(_pump);
    gallery?.status.addListener(_pump);
  }

  final YtDlpEngine engine;

  /// Downloads the files of posts (options with [DownloadOption.gallery]).
  final GalleryDlEngine? gallery;
  final StorageService storage;
  final HistoryStore history;
  final DownloadArgsProvider? extraArgs;

  /// The browser's sign-in for a link, tried when a download is refused.
  final CookieArgsProvider? cookieArgs;

  /// Settings → Extra Settings (downloads at once, speed limit, Wi-Fi only).
  final ExtraSettings? settings;
  final QueueStore? queueStore;

  /// Whether the device is on Wi-Fi (or another unmetered network); `null`
  /// on platforms where it doesn't matter.
  final Future<bool> Function()? onWifi;

  /// Synced lyrics for songs (Settings → Extra Settings → Lyrics).
  final LyricsService? lyricsService;

  int get _maxConcurrent => settings?.maxConcurrent ?? 3;

  /// Tasks being paused (their engine is stopping), and whether each goes
  /// back to the queue (Wi-Fi lost) instead of staying paused.
  final Map<String, bool> _pausing = {};

  /// Last known network state, for "Wi-Fi only".
  bool _wifiOk = true;
  Timer? _networkTimer;

  /// yt-dlp extracts the page again for every download, and YouTube now and
  /// then refuses one run (403, bot check, a format briefly missing) that
  /// works seconds later. Such failures are retried before giving up.
  static const _autoRetries = 2;

  final List<DownloadTask> _tasks = [];
  final Map<String, EngineRun> _runs = {};

  /// Plain HTTP downloads (thumbnails), closed to cancel.
  final Map<String, HttpClient> _direct = {};
  bool _askedNotificationPermission = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _notifyTimer;

  /// Active and failed tasks (completed / cancelled ones leave the list).
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  int get activeCount => _tasks.where((t) => t.isActive).length;

  /// Base names reserved by queued / running downloads.
  Set<String> get reservedNames =>
      _tasks.where((t) => t.isActive).map((t) => t.fileBaseName.toLowerCase()).toSet();

  /// Whether downloads of kinds [a] and [b] land in the same folder (a
  /// post's files go to all of them).
  static bool _sameFolder(MediaKind a, MediaKind b) =>
      a == MediaKind.post || b == MediaKind.post || MediaFolder.forKind(a) == MediaFolder.forKind(b);

  /// The History download that already used [name] for the folder [kind]
  /// saves to, even if its file was deleted since (from a gallery or file
  /// manager): reusing the name would mix the two up.
  HistoryEntry? historyEntryNamed(String name, MediaKind kind) {
    final wanted = name.toLowerCase();
    for (final e in history.entries) {
      if (e.status != DownloadStatus.completed) continue;
      if (e.fileName.toLowerCase() == wanted && _sameFolder(e.kind, kind)) return e;
    }
    return null;
  }

  /// Names (lower-case) a new download of [kind] shouldn't take: queued or
  /// running downloads, and History's downloads to the same folder.
  Set<String> takenNames(MediaKind kind) => {
        ...reservedNames,
        for (final e in history.entries)
          if (e.status == DownloadStatus.completed && _sameFolder(e.kind, kind)) e.fileName.toLowerCase(),
      };

  /// Finished downloads of [url] whose files are still on disk (the same
  /// video saved before, maybe under another name).
  List<HistoryEntry> savedCopiesOf(String url) => [
        for (final e in history.entries)
          if (e.status == DownloadStatus.completed && e.url == url && e.allFiles.any((f) => File(f).existsSync())) e,
      ];

  /// History entries whose file still exists in the download folder under the
  /// name it was saved with.
  List<HistoryEntry> get completedFiles {
    final seen = <String>{};
    return history.entries
        .where((e) => e.status == DownloadStatus.completed && e.filePath != null && storage.isInDownloadDir(e.filePath!))
        .where((e) => seen.add(HistoryStore.fileKey(e)!))
        .toList();
  }

  int _idSeq = 0;
  String _newId() => 'dl-${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

  /// [subtitleArgs]: yt-dlp arguments for subtitles (see `subtitleArgs`).
  /// [lyricsText]: lyrics the user picked or imported for a song (instead of
  /// looking them up); [noLyrics]: the user chose none.
  Future<void> enqueue({
    required MediaInfo info,
    required DownloadOption option,
    required String fileBaseName,
    List<String> subtitleArgs = const [],
    String? lyricsText,
    bool noLyrics = false,
  }) async {
    await _askNotificationPermissionOnce();
    // A song saved as audio gets its synced lyrics, when they're turned on.
    final song = option.kind == MediaKind.audio && option.directUrl == null && option.gallery == null;
    final picked = song && !noLyrics && lyricsText != null && lyricsText.trim().isNotEmpty ? lyricsText : null;
    final lyrics = song && !noLyrics && picked == null && settings?.lyrics == true ? LyricsQuery.fromInfo(info) : null;
    final task = DownloadTask(
      id: _newId(),
      url: info.url,
      title: info.title,
      fileBaseName: fileBaseName,
      option: option,
      requestArgs: info.requestArgs,
      extraArgs: option.directUrl != null || option.gallery != null
          ? const []
          : (extraArgs?.call(info, option) ?? const []),
      subtitleArgs: subtitleArgs,
      thumbnail: info.thumbnail,
      extractor: info.extractor,
      lyrics: lyrics,
      lyricsText: picked,
      lyricsMode: lyrics == null && picked == null ? null : (settings?.lyricsMode ?? SubtitleMode.embed).name,
    );
    _tasks.insert(0, task);
    notifyListeners();
    _pump();
  }

  // ───── Pause & resume ─────

  /// Stops [task] and keeps what it downloaded so far; [resume] carries on
  /// from there.
  Future<void> pause(DownloadTask task) => _pause(task, requeue: false);

  Future<void> _pause(DownloadTask task, {required bool requeue}) async {
    if (task.status == DownloadStatus.queued) {
      if (requeue) return;
      task
        ..status = DownloadStatus.paused
        ..stage = null;
      notifyListeners();
      _syncNotifications();
      return;
    }
    if (!task.isRunning || _pausing.containsKey(task.id)) return;
    _pausing[task.id] = requeue;
    task.stage = 'Pausing…';
    notifyListeners();
    _direct[task.id]?.close(force: true);
    await _runs[task.id]?.cancel();
  }

  /// Puts a paused download back in the queue.
  void resume(DownloadTask task) {
    if (task.status != DownloadStatus.paused) return;
    task
      ..status = DownloadStatus.queued
      ..stage = null
      ..speed = null
      ..eta = null;
    notifyListeners();
    _pump();
  }

  bool get hasPausable => _tasks.any((t) => t.status == DownloadStatus.queued || t.isRunning);
  bool get hasPaused => _tasks.any((t) => t.status == DownloadStatus.paused);

  Future<void> pauseAll() async {
    // Waiting ones first, so a freed slot doesn't start them.
    for (final t in _tasks.where((t) => t.status == DownloadStatus.queued).toList()) {
      await pause(t);
    }
    await Future.wait([for (final t in _tasks.where((t) => t.isRunning).toList()) pause(t)]);
  }

  void resumeAll() {
    for (final t in _tasks.reversed.where((t) => t.status == DownloadStatus.paused).toList()) {
      t
        ..status = DownloadStatus.queued
        ..stage = null;
    }
    notifyListeners();
    _pump();
  }

  /// A paused task whose engine has stopped: kept with its partial files.
  void _settlePause(DownloadTask task) {
    final requeue = _pausing.remove(task.id) ?? false;
    task
      ..status = requeue ? DownloadStatus.queued : DownloadStatus.paused
      ..stage = null
      ..speed = null
      ..eta = null;
    _syncNotifications();
  }

  // ───── The saved queue ─────

  /// Loads the queue saved by the last run. Running downloads restart from
  /// their partial files (yt-dlp continues `.part` files); work folders of
  /// downloads no longer in the queue are deleted.
  Future<void> restore() async {
    final store = queueStore;
    if (store == null) return;
    final restored = <DownloadTask>[];
    for (final s in store.load()) {
      try {
        final t = DownloadTask.fromJson((jsonDecode(s) as Map).cast<String, dynamic>());
        if (t != null && !_tasks.any((x) => x.id == t.id)) restored.add(t);
      } catch (_) {}
    }
    _tasks.addAll(restored);
    try {
      final parts = await storage.workDir('parts');
      final keep = {for (final t in _tasks) t.id};
      for (final d in parts.listSync().whereType<Directory>()) {
        if (!keep.contains(p.basename(d.path))) unawaited(_cleanup(d));
      }
    } catch (_) {}
    if (settings?.wifiOnly == true) await _checkNetwork();
    notifyListeners();
    _pump();
  }

  String _savedSignature = '';

  /// Saves the queue when a task was added, removed or changed state
  /// (progress alone doesn't count).
  void _saveQueue() {
    final store = queueStore;
    if (store == null) return;
    final unfinished = _tasks.where((t) => t.isActive || t.status == DownloadStatus.failed).toList();
    final signature = [
      for (final t in unfinished) '${t.id}:${t.isRunning ? 'run' : t.status.name}:${t.subtitleArgs.length}',
    ].join(',');
    if (signature == _savedSignature) return;
    _savedSignature = signature;
    unawaited(store.save([for (final t in unfinished) jsonEncode(t.toJson())]));
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _saveQueue();
  }

  // ───── Settings & network ─────

  void _onSettings() {
    if (settings?.wifiOnly == true) unawaited(_checkNetwork());
    _pump();
    notifyListeners();
  }

  Future<void> _checkNetwork() async {
    final check = onWifi;
    final ok = check == null ? true : await check().catchError((_) => true);
    if (ok == _wifiOk) return;
    _wifiOk = ok;
    _pump();
    notifyListeners();
  }

  bool get _waitingForWifi => settings?.wifiOnly == true && !_wifiOk;

  /// Keeps an eye on the network while downloads wait for Wi-Fi, or run
  /// with "Wi-Fi only" on (to pause them when Wi-Fi is lost).
  void _watchNetwork() {
    final watch = settings?.wifiOnly == true && onWifi != null && _tasks.any((t) => t.status == DownloadStatus.queued || t.isRunning);
    if (watch) {
      _networkTimer ??= Timer.periodic(const Duration(seconds: 8), (_) => _checkNetwork());
    } else {
      _networkTimer?.cancel();
      _networkTimer = null;
    }
  }

  Future<void> retry(DownloadTask failed) async {
    _tasks.remove(failed);
    final task = DownloadTask(
      id: _newId(),
      url: failed.url,
      title: failed.title,
      fileBaseName: storage.uniqueBaseName(
        failed.fileBaseName,
        alsoTaken: takenNames(failed.option.kind),
        kind: failed.option.kind,
        folders: failed.option.kind == MediaKind.post,
      ),
      option: failed.option,
      requestArgs: failed.requestArgs,
      extraArgs: failed.extraArgs,
      subtitleArgs: failed.subtitleArgs,
      thumbnail: failed.thumbnail,
      extractor: failed.extractor,
      lyrics: failed.lyrics,
      lyricsMode: failed.lyricsMode,
      lyricsText: failed.lyricsText,
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
    if (task.status == DownloadStatus.queued || task.status == DownloadStatus.paused) {
      task.status = DownloadStatus.cancelled;
      _tasks.remove(task);
      await _record(task);
      _finishNotification(task);
      unawaited(storage.workDir('parts/${task.id}').then(_cleanup));
      notifyListeners();
      return;
    }
    if (_pausing.containsKey(task.id)) {
      // Pausing and now cancelled: it ends as cancelled.
      _pausing.remove(task.id);
    }
    task.stage = 'Cancelling…';
    notifyListeners();
    _direct[task.id]?.close(force: true);
    await _runs[task.id]?.cancel();
  }

  /// Deletes a downloaded file from disk (history keeps the record). A post
  /// loses all its files, and its folder once empty.
  Future<void> deleteFile(HistoryEntry entry) async {
    final paths = entry.allFiles;
    if (paths.isEmpty) return;
    for (final path in paths) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      await NativeBridge.scanFile(path);
    }
    // Posts saved by v1.2.0 had a folder of their own: it goes once empty.
    // The FetchNet folder and its type folders always stay.
    final root = storage.downloadDir;
    if (entry.files.length > 1 && root != null) {
      final keep = {root, for (final f in MediaFolder.values) p.join(root, f.folderName)};
      for (final folder in {for (final path in paths) p.dirname(path)}) {
        try {
          final d = Directory(folder);
          if (!keep.any((k) => p.equals(k, folder)) && p.isWithin(root, folder) && d.listSync().isEmpty) d.deleteSync();
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  Future<void> _askNotificationPermissionOnce() async {
    if (_askedNotificationPermission || kIsWeb || !Platform.isAndroid) return;
    _askedNotificationPermission = true;
    await NativeBridge.requestPermission('notifications');
  }

  /// Why a queued task isn't starting yet, or `null` when it can.
  String? _holdReason(DownloadTask task) {
    if (_waitingForWifi) return 'Waiting for Wi-Fi';
    if (task.option.directUrl != null) return null;
    if (task.option.gallery != null) {
      final g = gallery;
      if (g != null && g.isSupported && !g.status.value.isReady) return 'Waiting for gallery-dl…';
      return null;
    }
    if (engine.isSupported && !engine.status.value.isReady) return 'Waiting for yt-dlp…';
    return null;
  }

  void _pump() {
    // "Wi-Fi only" and Wi-Fi was lost: running downloads go back to the
    // queue (keeping their partial files) until it's back.
    if (_waitingForWifi) {
      for (final t in _tasks.where((t) => t.isRunning).toList()) {
        unawaited(_pause(t, requeue: true));
      }
    }
    final running = _tasks.where((t) => t.isRunning).length;
    var slots = _maxConcurrent - running;
    var changed = false;
    // Oldest first.
    for (final task in _tasks.reversed.toList()) {
      if (task.status != DownloadStatus.queued) continue;
      final hold = _holdReason(task);
      if (task.stage != hold) {
        task.stage = hold;
        changed = true;
      }
      if (hold != null || slots <= 0) continue;
      slots--;
      unawaited(_run(task));
    }
    _watchNetwork();
    if (changed) notifyListeners();
    _syncNotifications();
  }

  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.starting;
    task.stage = 'Starting…';
    notifyListeners();

    // "Wi-Fi only": check the network now rather than trusting the last look.
    if (settings?.wifiOnly == true && onWifi != null) {
      await _checkNetwork();
      if (_waitingForWifi) {
        task
          ..status = DownloadStatus.queued
          ..stage = 'Waiting for Wi-Fi';
        notifyListeners();
        _watchNetwork();
        return;
      }
    }

    final root = storage.downloadDir ?? await storage.ensureDownloadDir(requestPermission: true);
    if (root == null) {
      _fail(task, storage.error ?? 'The download folder isn\'t available.');
      return;
    }
    if (task.option.gallery != null) {
      // A post's files are sorted into the type folders one by one.
      await _runGallery(task, root);
      notifyListeners();
      _pump();
      return;
    }
    // Everything else goes into its type folder: FetchNet/Images, Audio or Video.
    final dir = storage.dirForKind(task.option.kind) ?? root;
    if (task.option.directUrl != null) {
      await _runDirect(task, dir);
      notifyListeners();
      _pump();
      return;
    }
    final temp = await storage.workDir('parts/${task.id}');
    var extra = task.extraArgs;
    var retriesLeft = _autoRetries;

    // A song: its synced lyrics, looked up before downloading so FFmpeg can
    // write them into the file while it adds the other tags.
    // Lyrics picked on Home are used as they are.
    String? lrc = task.lyricsText;
    var lyricsArgs = const <String>[];
    final lyrics = task.lyrics;
    if (lrc == null && lyrics != null && lyricsService != null) {
      task.stage = 'Looking up lyrics…';
      notifyListeners();
      try {
        // Up to five LRCLIB searches (by name, then each part of the title).
        lrc = await lyricsService!.synced(lyrics).timeout(const Duration(seconds: 45));
      } catch (_) {}
      if (_pausing.containsKey(task.id)) {
        _settlePause(task);
        notifyListeners();
        _pump();
        return;
      }
      if (task.stage == 'Cancelling…') {
        task.status = DownloadStatus.cancelled;
        _tasks.remove(task);
        await _record(task);
        _finishNotification(task);
        notifyListeners();
        _pump();
        return;
      }
      task.stage = 'Starting…';
    }
    if (lrc != null && task.lyricsMode != SubtitleMode.file.name && engine.status.value.ffmpegAvailable) {
      lyricsArgs = lyricsEmbedArgs(lrc, formatArgs: task.option.formatArgs);
    }

    void resetProgress(String stage) {
      task
        ..resetProgress()
        ..status = DownloadStatus.starting
        ..stage = stage;
      notifyListeners();
      _syncNotifications();
    }

    while (true) {
      final result = await _runYtDlp(task, dir, temp, [...extra, ...lyricsArgs]);
      // Paused: the partial files stay in the work folder for later.
      if (_pausing.containsKey(task.id)) {
        _settlePause(task);
        notifyListeners();
        _pump();
        return;
      }
      if (!result.ok && !result.cancelled && task.stage != 'Cancelling…') {
        final raw = result.stderr.isEmpty ? result.stdout : result.stderr;
        final lower = raw.toLowerCase();
        // Subtitles are extra: when the site refuses them (often a 429 on
        // automatic captions), the video downloads without them.
        if (task.subtitleArgs.isNotEmpty && lower.contains('subtitle')) {
          task.subtitleArgs = const [];
          resetProgress('Retrying without subtitles…');
          continue;
        }
        // Lyrics inside the song are extra too: when writing the tags fails,
        // they're saved as a .lrc file next to it instead.
        if (lyricsArgs.isNotEmpty && (lower.contains('metadata') || lower.contains('postprocess'))) {
          lyricsArgs = const [];
          resetProgress('Retrying without lyrics inside…');
          continue;
        }
        // Cover art is a nice-to-have: when embedding it fails (a format or
        // platform without support), the download runs once more without it.
        if (extra.isNotEmpty && lower.contains('thumbnail')) {
          extra = const [];
          resetProgress('Retrying without cover art…');
          continue;
        }
        final message = extractEngineError(raw);
        if (retriesLeft > 0 && !isPermanentEngineError(message)) {
          retriesLeft--;
          resetProgress('Retrying…');
          await _addCookiesIfRefused(task, message);
          await Future<void>.delayed(Duration(seconds: 2 * (_autoRetries - retriesLeft)));
          if (_pausing.containsKey(task.id)) {
            _settlePause(task);
            notifyListeners();
            _pump();
            return;
          }
          if (task.stage != 'Cancelling…') continue;
        }
      }
      unawaited(_cleanup(temp));
      if (result.cancelled || task.stage == 'Cancelling…') {
        task.status = DownloadStatus.cancelled;
        _tasks.remove(task);
        await _record(task);
        _finishNotification(task);
      } else if (result.ok) {
        // The .lrc file goes next to the song before it's reported done.
        final keepFile = task.lyricsMode != SubtitleMode.embed.name || lyricsArgs.isEmpty;
        if (lrc != null && keepFile) task.lyricsFile = lrc;
        await _complete(task, dir);
      } else {
        final message = extractEngineError(result.stderr.isEmpty ? result.stdout : result.stderr);
        _fail(task, message);
      }
      break;
    }
    notifyListeners();
    _pump();
  }

  /// Saves synced lyrics next to [audioPath] (`Song.mp3` → `Song.lrc`), where
  /// music players look for them.
  Future<void> _writeLyricsFile(String audioPath, String lrc) async {
    try {
      final path = p.setExtension(audioPath, '.lrc');
      await File(path).writeAsString(lrc);
      await NativeBridge.scanFile(path);
    } catch (_) {}
  }

  /// A sign-in / bot check or a refused request: retry with the browser's
  /// cookies for the site, when the user signed in there (the same fallback
  /// the format lookup uses).
  /// [refused]: the engine already said it needs a sign-in (gallery-dl's
  /// authorization exit status).
  Future<void> _addCookiesIfRefused(DownloadTask task, String message, {bool refused = false}) async {
    final provider = cookieArgs;
    if (provider == null || task.requestArgs.contains('--cookies')) return;
    final m = message.toLowerCase();
    if (!refused && !isSignInError(m) && !m.contains('403') && !m.contains('forbidden') && !m.contains('401')) return;
    try {
      final extra = await provider(task.url);
      if (extra.isNotEmpty) task.requestArgs = [...task.requestArgs, ...extra];
    } catch (_) {}
  }

  Future<EngineResult> _runYtDlp(DownloadTask task, String dir, Directory temp, List<String> extra) async {
    final rate = settings?.rateArg;
    final args = <String>[
      ...task.option.formatArgs,
      ...extra,
      ...task.subtitleArgs,
      ...task.requestArgs,
      if (rate != null) ...['--limit-rate', rate],
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
    return result;
  }

  /// Saves [DownloadOption.directUrl] straight into the download folder.
  Future<void> _runDirect(DownloadTask task, String dir) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    _direct[task.id] = http;
    var path = p.join(dir, '${task.fileBaseName}.${task.option.extension}');
    var part = File('$path.part');
    try {
      final req = await http.getUrl(Uri.parse(task.option.directUrl!));
      // Images from Browser Mode: the page's cookies, referer and user agent.
      task.option.directHeaders.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('The server answered with error ${res.statusCode}.');
      if (task.option.kind == MediaKind.image) {
        // Image URLs often lack an extension: trust the server's type.
        final ext = imageExtensionFor(res.headers.contentType?.mimeType);
        if (ext != null && ext != task.option.extension) {
          path = p.join(dir, '${storage.uniqueBaseName(task.fileBaseName, kind: task.option.kind)}.$ext');
          part = File('$path.part');
        }
      }
      final total = res.contentLength > 0 ? res.contentLength : null;
      task
        ..status = DownloadStatus.downloading
        ..stage = 'Downloading'
        ..totalBytes = total;
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          task.downloadedBytes = received;
          task.progress = total == null ? null : (received / total).clamp(0, 1).toDouble();
          _throttledNotify();
        }
      } finally {
        await sink.close();
      }
      if (task.stage == 'Cancelling…' || _pausing.containsKey(task.id)) throw const HttpException('Cancelled');
      final target = File(path);
      if (target.existsSync()) target.deleteSync();
      part.renameSync(path);
      task.filePath = path;
      await _complete(task, dir);
    } catch (e) {
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      if (_pausing.containsKey(task.id)) {
        // A single picture: resuming simply downloads it again.
        _settlePause(task);
        task
          ..progress = null
          ..downloadedBytes = null;
      } else if (task.stage == 'Cancelling…') {
        task.status = DownloadStatus.cancelled;
        _tasks.remove(task);
        await _record(task);
        _finishNotification(task);
      } else {
        _fail(task, e is HttpException ? e.message : 'Couldn\'t download the image ($e).');
      }
    } finally {
      _direct.remove(task.id);
      http.close(force: true);
    }
  }

  /// Downloads the picked files of a post with gallery-dl into a work
  /// folder, then moves them into place: one file as `<name>.<ext>`, several
  /// into a `<name>` folder. Refusals are retried like yt-dlp downloads,
  /// with the browser's sign-in once the site asks for one.
  Future<void> _runGallery(DownloadTask task, String dir) async {
    final engine = gallery;
    final g = task.option.gallery!;
    if (engine == null || !engine.isSupported) {
      _fail(task, 'gallery-dl isn\'t available on this device.');
      return;
    }
    final temp = await storage.workDir('parts/${task.id}');
    var retriesLeft = _autoRetries;

    void showProgress() {
      final done = task.filesDone.clamp(0, g.count);
      task
        ..status = DownloadStatus.downloading
        ..progress = g.count > 1 ? (done / g.count).clamp(0, 1).toDouble() : null
        ..stage = g.count > 1 ? 'Downloading $done of ${g.count} files' : 'Downloading';
    }

    showProgress();
    notifyListeners();
    while (true) {
      final rate = settings?.rateArg;
      final args = <String>[
        '-D', temp.path,
        if (g.range != null) ...['--range', g.range!],
        if (rate != null) ...['--limit-rate', rate],
        // One line per saved (or already saved) file drives the progress.
        '--Print', 'after:FNFILE|{filename}.{extension}',
        '--Print', 'skip:FNFILE|{filename}.{extension}',
        ...galleryRequestArgs(task.requestArgs),
        '--',
        task.url,
      ];
      task.filesDone = 0;
      final run = engine.start(task.id, args);
      _runs[task.id] = run;
      final sub = run.lines.listen((line) {
        if (!line.startsWith('FNFILE|')) return;
        task.filesDone++;
        showProgress();
        _throttledNotify();
      });
      final result = await run.done;
      await sub.cancel();
      _runs.remove(task.id);

      // Paused: gallery-dl skips the files it already saved when resumed.
      if (_pausing.containsKey(task.id)) {
        _settlePause(task);
        return;
      }
      final saved = _savedFiles(temp);
      if (result.cancelled || task.stage == 'Cancelling…') {
        task.status = DownloadStatus.cancelled;
        _tasks.remove(task);
        await _record(task);
        _finishNotification(task);
        break;
      }
      if (saved.isNotEmpty && (result.ok || saved.length >= g.count)) {
        await _completeGallery(task, dir, saved);
        break;
      }
      final raw = result.stderr.isEmpty ? result.stdout : result.stderr;
      final message = result.ok ? 'No files were downloaded.' : extractGalleryError(raw);
      final unsupported = GalleryExit.has(result.exitCode, GalleryExit.unsupported);
      if (retriesLeft > 0 && !unsupported && !isPermanentEngineError(message)) {
        retriesLeft--;
        task
          ..status = DownloadStatus.starting
          ..progress = null
          ..stage = 'Retrying…';
        notifyListeners();
        _syncNotifications();
        await _addCookiesIfRefused(task, message, refused: GalleryExit.has(result.exitCode, GalleryExit.auth));
        await Future<void>.delayed(Duration(seconds: 2 * (_autoRetries - retriesLeft)));
        if (_pausing.containsKey(task.id)) {
          _settlePause(task);
          return;
        }
        if (task.stage != 'Cancelling…') {
          showProgress();
          continue;
        }
        task.status = DownloadStatus.cancelled;
        _tasks.remove(task);
        await _record(task);
        _finishNotification(task);
        break;
      }
      // Some files made it: keep them rather than losing everything.
      if (saved.isNotEmpty) {
        await _completeGallery(task, dir, saved);
        break;
      }
      _fail(
        task,
        message,
        hint: friendlyGalleryHint(message, exitCode: result.exitCode, signedIn: task.requestArgs.contains('--cookies')),
      );
      break;
    }
    unawaited(_cleanup(temp));
  }

  /// Files gallery-dl finished in [dir] (unfinished `.part` files left out),
  /// in name order (gallery-dl names files after their position).
  List<File> _savedFiles(Directory dir) {
    try {
      final files = dir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) => !RegExp(r'\.(part|ytdl|tmp|temp)$', caseSensitive: false).hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return files;
    } catch (_) {
      return const [];
    }
  }

  /// Files a post's downloads straight into the type folders (no folder per
  /// post): every image into `Images`, audio into `Audio`, the rest into
  /// `Video`. One file is `<name>.<ext>`; several are numbered in the post's
  /// order: `<name> 1.jpg`, `<name> 2.mp4`, ...
  Future<void> _completeGallery(DownloadTask task, String root, List<File> saved) async {
    final moved = <String>[];
    try {
      for (final (i, f) in saved.indexed) {
        moved.add(await _move(f, postFilePath(
          dir: storage.dirFor(MediaFolder.forExtension(p.extension(f.path))) ?? root,
          baseName: task.fileBaseName,
          extension: p.extension(f.path),
          number: saved.length > 1 ? i + 1 : null,
        )));
      }
    } catch (e) {
      if (moved.isEmpty) {
        _fail(task, 'The files were downloaded but couldn\'t be saved ($e).');
        return;
      }
    }
    for (final path in moved) {
      await NativeBridge.scanFile(path);
    }
    task
      ..filePath = moved.first
      ..files = moved.length > 1 ? moved : const []
      ..filesDone = moved.length
      ..status = DownloadStatus.completed
      ..progress = 1;
    _tasks.remove(task);
    await _record(task);
    _finishNotification(task);
  }

  /// Moves [file] to [target] (a copy when they're on different storage).
  Future<String> _move(File file, String target) async {
    try {
      return file.renameSync(target).path;
    } on FileSystemException {
      await file.copy(target);
      try {
        file.deleteSync();
      } catch (_) {}
      return target;
    }
  }

  void _onLine(DownloadTask task, String line) {
    if (line.startsWith('FNPROG|')) {
      final parts = line.split('|');
      double? num(int i) => i < parts.length ? double.tryParse(parts[i]) : null;
      // Sizes, the share done and the parts (video, then audio) are worked
      // out by the task: estimates that move with every fragment don't
      // make the size or the percentage jump around.
      final fraction = task.reportProgress(
        downloaded: num(1)?.toInt(),
        exactTotal: num(2)?.toInt(),
        estimatedTotal: num(3)?.toInt(),
        fragmentIndex: num(6),
        fragmentCount: num(7),
      );
      task.status = DownloadStatus.downloading;
      task.speed = num(4);
      task.eta = num(5)?.round();
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
        'EmbedThumbnail' || 'ThumbnailsConvertor' || 'FFmpegThumbnailsConvertor' => 'Adding cover art…',
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
    final lrc = task.lyricsFile;
    if (lrc != null) {
      task.lyricsFile = null;
      await _writeLyricsFile(path, lrc);
    }
    _tasks.remove(task);
    await _record(task);
    _finishNotification(task);
  }

  void _fail(DownloadTask task, String message, {String? hint}) {
    task.status = DownloadStatus.failed;
    task.error = message;
    task.errorHint = hint ?? friendlyEngineHint(message, url: task.url, signedIn: task.requestArgs.contains('--cookies'));
    task.stage = null;
    unawaited(_record(task));
    _finishNotification(task);
    notifyListeners();
  }

  Future<void> _record(DownloadTask task) async {
    int? size;
    final path = task.filePath;
    for (final f in task.files.isNotEmpty ? task.files : [?path]) {
      try {
        size = (size ?? 0) + File(f).lengthSync();
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
      files: task.files,
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
      // Cleared, or `??=` below would never schedule another update.
      _notifyTimer = null;
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

  String _fileName(DownloadTask t) =>
      t.option.extension.isEmpty ? t.fileBaseName : '${t.fileBaseName}.${t.option.extension}';

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
        DownloadStatus.queued => t.stage ?? 'Waiting in queue',
        DownloadStatus.paused => 'Paused',
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
          fileName: t.files.length > 1
              ? '${t.fileBaseName} · ${t.files.length} files'
              : t.filePath == null
                  ? _fileName(t)
                  : p.basename(t.filePath!),
          path: t.filePath,
          size: () {
            try {
              var bytes = 0;
              for (final f in t.files.isNotEmpty ? t.files : [t.filePath!]) {
                bytes += File(f).lengthSync();
              }
              return formatBytes(bytes);
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
    _networkTimer?.cancel();
    settings?.removeListener(_onSettings);
    engine.status.removeListener(_pump);
    gallery?.status.removeListener(_pump);
    super.dispose();
  }
}

/// File extension for an image MIME type (`image/webp` → `webp`), or `null`.
String? imageExtensionFor(String? mime) => switch (mime?.toLowerCase()) {
      'image/jpeg' || 'image/jpg' || 'image/pjpeg' => 'jpg',
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'image/avif' => 'avif',
      'image/heic' => 'heic',
      'image/heif' => 'heif',
      'image/bmp' => 'bmp',
      'image/tiff' => 'tiff',
      'image/jxl' => 'jxl',
      _ => null,
    };

/// Where a file of a post is saved: `<dir>/<baseName>[ <number>]<extension>`,
/// with " (2)", " (3)", ... added when that name is taken.
@visibleForTesting
String postFilePath({required String dir, required String baseName, required String extension, int? number}) {
  final base = number == null ? baseName : '$baseName $number';
  var name = base;
  for (var i = 2; File(p.join(dir, '$name$extension')).existsSync(); i++) {
    name = '$base ($i)';
  }
  return p.join(dir, '$name$extension');
}
