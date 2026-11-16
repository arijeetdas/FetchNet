import 'media_info.dart';

enum DownloadStatus { queued, starting, downloading, processing, completed, failed, cancelled }

/// A download in progress (lives only in memory).
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.title,
    required this.fileBaseName,
    required this.option,
    required this.requestArgs,
    this.extraArgs = const [],
    this.thumbnail,
    this.extractor,
  }) : createdAt = DateTime.now();

  final String id;
  final String url;
  final String title;
  final String fileBaseName;
  final DownloadOption option;

  /// Grows the browser's cookies when an automatic retry needs a sign-in.
  List<String> requestArgs;

  /// Post-processing picked from settings (e.g. embedded cover art).
  final List<String> extraArgs;
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

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.starting ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.processing;
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
