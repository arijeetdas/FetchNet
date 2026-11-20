import '../services/lyrics_service.dart';
import 'media_info.dart';

enum DownloadStatus { queued, starting, downloading, processing, paused, completed, failed, cancelled }

/// A download in the queue. Unfinished ones are saved (see [toJson]) so the
/// queue survives closing the app.
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.title,
    required this.fileBaseName,
    required this.option,
    required this.requestArgs,
    this.extraArgs = const [],
    this.subtitleArgs = const [],
    this.thumbnail,
    this.extractor,
    this.lyrics,
    this.lyricsMode,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// The song to add synced lyrics for (Settings → Extra Settings), and
  /// how: `embed`, `file` or `both`.
  final LyricsQuery? lyrics;
  final String? lyricsMode;

  /// Lyrics to save as a `.lrc` next to the finished file.
  String? lyricsFile;

  final String id;
  final String url;
  final String title;
  final String fileBaseName;
  final DownloadOption option;

  /// Grows the browser's cookies when an automatic retry needs a sign-in.
  List<String> requestArgs;

  /// Post-processing picked from settings (e.g. embedded cover art).
  final List<String> extraArgs;

  /// Subtitles (Settings → Extra Settings). Dropped when the site refuses
  /// them, so the video itself still downloads.
  List<String> subtitleArgs;
  final String? thumbnail;
  final String? extractor;
  final DateTime createdAt;

  DownloadStatus status = DownloadStatus.queued;

  /// Overall progress 0..1, or null when unknown.
  double? progress;
  int? downloadedBytes;
  int? totalBytes;
  double? speed; // bytes / s
  int? eta; // seconds
  String? stage; // e.g. "Merging video and audio"
  String? filePath;

  /// Every saved file of a post (gallery-dl), first one = [filePath].
  List<String> files = const [];
  int filesDone = 0;
  String? error;
  String? errorHint;

  // Part tracking (video + audio downloaded separately).
  int partIndex = 0;
  int lastPartBytes = 0;

  int get expectedParts => option.needsMerge ? 2 : 1;

  /// Not finished yet: waiting, running or paused.
  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.starting ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.processing ||
      status == DownloadStatus.paused;

  /// Holding a slot: an engine is working on it.
  bool get isRunning =>
      status == DownloadStatus.starting || status == DownloadStatus.downloading || status == DownloadStatus.processing;

  /// Saved queue entry. A running download is saved as queued: it carries
  /// on (from its partial file) when the app opens again. Browser cookies
  /// (temporary files) aren't kept; a refused download asks for them again.
  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'fileBaseName': fileBaseName,
        'option': option.toJson(),
        'requestArgs': withoutCookies(requestArgs),
        if (extraArgs.isNotEmpty) 'extraArgs': extraArgs,
        if (subtitleArgs.isNotEmpty) 'subtitleArgs': subtitleArgs,
        if (thumbnail != null) 'thumbnail': thumbnail,
        if (extractor != null) 'extractor': extractor,
        if (lyrics != null) 'lyrics': lyrics!.toJson(),
        if (lyricsMode != null) 'lyricsMode': lyricsMode,
        'createdAt': createdAt.toIso8601String(),
        'status': switch (status) {
          DownloadStatus.paused => 'paused',
          DownloadStatus.failed => 'failed',
          _ => 'queued',
        },
        if (error != null) 'error': error,
        if (errorHint != null) 'errorHint': errorHint,
      };

  static DownloadTask? fromJson(Map<String, dynamic> j) {
    try {
      final option = DownloadOption.fromJson((j['option'] as Map).cast<String, dynamic>());
      if (option == null) return null;
      List<String> strings(Object? v) => [for (final s in (v as List?) ?? const []) if (s is String) s];
      return DownloadTask(
        id: j['id'] as String,
        url: j['url'] as String,
        title: j['title'] as String,
        fileBaseName: j['fileBaseName'] as String,
        option: option,
        requestArgs: strings(j['requestArgs']),
        extraArgs: strings(j['extraArgs']),
        subtitleArgs: strings(j['subtitleArgs']),
        thumbnail: j['thumbnail'] as String?,
        extractor: j['extractor'] as String?,
        lyrics: LyricsQuery.fromJson(j['lyrics']),
        lyricsMode: j['lyricsMode'] as String?,
        createdAt: DateTime.tryParse('${j['createdAt']}'),
      )
        ..status = switch (j['status']) {
          'paused' => DownloadStatus.paused,
          'failed' => DownloadStatus.failed,
          _ => DownloadStatus.queued,
        }
        ..error = j['error'] as String?
        ..errorHint = j['errorHint'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// [args] without `--cookies <file>` pairs.
  static List<String> withoutCookies(List<String> args) {
    final out = <String>[];
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--cookies') {
        i++;
        continue;
      }
      out.add(args[i]);
    }
    return out;
  }
}

/// A finished / failed download, persisted in SharedPreferences.
class HistoryEntry {
  HistoryEntry({
    required this.id,
    required this.url,
    required this.title,
    required this.fileName,
    required this.kind,
    required this.quality,
    required this.status,
    required this.createdAt,
    this.filePath,
    this.sizeBytes,
    this.thumbnail,
    this.extractor,
    this.error,
    this.completedAt,
    this.files = const [],
  });

  final String id;
  final String url;
  final String title;

  /// File name chosen in the rename dialog (without extension).
  final String fileName;
  final MediaKind kind;
  final String quality;
  final DownloadStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? filePath;
  final int? sizeBytes;
  final String? thumbnail;
  final String? extractor;
  final String? error;

  /// Every file of a post download ([filePath] is the first one). Empty for
  /// single-file downloads (and entries from older versions).
  final List<String> files;

  /// The files of this entry that are on disk.
  List<String> get allFiles => files.isNotEmpty ? files : [?filePath];

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'fileName': fileName,
        'kind': kind.name,
        'quality': quality,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
        if (filePath != null) 'filePath': filePath,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (thumbnail != null) 'thumbnail': thumbnail,
        if (extractor != null) 'extractor': extractor,
        if (error != null) 'error': error,
        if (files.isNotEmpty) 'files': files,
      };

  static HistoryEntry? fromJson(Map<String, dynamic> j) {
    try {
      return HistoryEntry(
        id: j['id'] as String,
        url: j['url'] as String,
        title: j['title'] as String,
        fileName: j['fileName'] as String,
        kind: MediaKind.values.byName(j['kind'] as String),
        quality: j['quality'] as String? ?? '',
        status: DownloadStatus.values.byName(j['status'] as String),
        createdAt: DateTime.parse(j['createdAt'] as String),
        completedAt: j['completedAt'] == null ? null : DateTime.parse(j['completedAt'] as String),
        filePath: j['filePath'] as String?,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt(),
        thumbnail: j['thumbnail'] as String?,
        extractor: j['extractor'] as String?,
        error: j['error'] as String?,
        files: [for (final f in (j['files'] as List?) ?? const []) if (f is String) f],
      );
    } catch (_) {
      return null;
    }
  }
}
