import '../services/lyrics_service.dart';
import 'creator_job.dart';
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
    this.lyricsText,
    this.creator,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// The song to add synced lyrics for (Settings → Extra Settings), and
  /// how: `embed`, `file` or `both`.
  final LyricsQuery? lyrics;
  final String? lyricsMode;

  /// Lyrics picked (or imported) before downloading: used instead of
  /// looking them up.
  final String? lyricsText;

  /// A clip (maybe made 9:16 for Shorts / Reels) or a snapshot, instead of
  /// the whole video or song.
  final CreatorJob? creator;

  /// Lyrics to save as a `.lrc` next to the finished file.
  String? lyricsFile;

  // A creator's part: FFmpeg first cuts it straight from the streams
  // ([directTried] once it has had its go). Next, yt-dlp hands the download
  // of just that part to FFmpeg, which reports its own progress
  // ([sectionPart]: video, then audio). When that fails or stalls too, the
  // whole video is downloaded and cut on the device ([cutLocally]).
  bool directTried = false;
  bool cutLocally = false;
  bool sectionStalled = false;
  int sectionPart = 0;
  DateTime? sectionActivity;

  /// Lyrics FFmpeg was asked to put inside the song (checked once it's done).
  String? lyricsInside;

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

  /// Bytes of the parts already downloaded (the video, while the audio
  /// downloads).
  int finishedPartBytes = 0;

  /// [totalBytes] is an estimate (a stream in fragments: yt-dlp only knows
  /// the size at the end), shown as "~".
  bool totalIsEstimate = false;

  // The part downloading now: its size (exact, or the estimate shown) and
  // how much of it is done (never goes back).
  int? _partTotal;
  bool _partEstimated = false;
  double _partFraction = 0;

  int get expectedParts => option.needsMerge ? 2 : 1;

  /// Forgets the progress (a retry starts over).
  void resetProgress() {
    partIndex = 0;
    lastPartBytes = 0;
    finishedPartBytes = 0;
    totalIsEstimate = false;
    _partTotal = null;
    _partEstimated = false;
    _partFraction = 0;
    progress = null;
    downloadedBytes = null;
    totalBytes = null;
    speed = null;
    eta = null;
  }

  /// One progress line from yt-dlp: [downloaded] bytes of the current part,
  /// its [exactTotal] when known, else yt-dlp's [estimatedTotal] (which
  /// moves with every fragment of a stream). Sets [progress] (it never goes
  /// back), [downloadedBytes] and [totalBytes] for the whole download (video
  /// and audio together when the sizes are known), and returns this part's
  /// share done, 0..1.
  double? reportProgress({
    int? downloaded,
    int? exactTotal,
    int? estimatedTotal,
    double? fragmentIndex,
    double? fragmentCount,
  }) {
    final parts = expectedParts;
    if (downloaded != null) {
      // A new part started (video finished, audio begins): bytes count from
      // zero again. Not a part that's only half done (a fragment retried).
      final partDone = _partTotal == null || lastPartBytes >= _partTotal! * 0.9;
      if (lastPartBytes > 0 && downloaded < lastPartBytes * 0.5 && partIndex < parts - 1 && partDone) {
        finishedPartBytes += lastPartBytes;
        partIndex++;
        _partTotal = null;
        _partEstimated = false;
        _partFraction = 0;
      }
      if (downloaded > lastPartBytes || downloaded < lastPartBytes * 0.5) lastPartBytes = downloaded;
    }

    final exact = exactTotal != null && exactTotal > 0 ? exactTotal : null;
    final estimate = estimatedTotal != null && estimatedTotal > 0 ? estimatedTotal : null;
    if (exact != null) {
      _partTotal = exact;
      _partEstimated = false;
    } else if (estimate != null) {
      // The estimate shown moves only for a real change, or once the
      // download passes it.
      final shown = _partTotal;
      if (shown == null || !_partEstimated || (estimate - shown).abs() > shown * 0.08 || (downloaded ?? 0) > shown) {
        _partTotal = estimate;
      }
      _partEstimated = true;
    }

    // This part's share done, from the latest size (exact or estimated), else
    // from the fragments.
    final sizeNow = exact ?? estimate;
    double? f;
    if (downloaded != null && sizeNow != null) {
      f = downloaded / sizeNow;
    } else if (fragmentIndex != null && fragmentCount != null && fragmentCount > 0) {
      f = fragmentIndex / fragmentCount;
    }
    if (f != null) {
      // An estimate isn't done until yt-dlp says so.
      f = f.clamp(0.0, exact != null ? 1.0 : 0.99).toDouble();
      if (f > _partFraction) _partFraction = f;
    }

    // The whole download: one file, or video + audio whose sizes the format
    // list gave (the video's real size replaces its share once known).
    final partTotal = _partTotal;
    final byBytes = parts == 1 || option.sizeBytes != null;
    int? overall;
    if (partTotal != null) {
      if (parts == 1) {
        overall = partTotal;
      } else if (partIndex >= parts - 1) {
        overall = finishedPartBytes + partTotal;
      } else if (option.sizeBytes != null) {
        overall = option.sizeBytes! > partTotal ? option.sizeBytes! : partTotal;
      }
    }
    if (overall != null) {
      downloadedBytes = finishedPartBytes + (downloaded ?? (_partFraction * partTotal!).round());
      totalBytes = overall;
      totalIsEstimate = _partEstimated || (parts > 1 && partIndex < parts - 1);
    } else {
      // Only this part's size is known: its own numbers ("Downloading video").
      downloadedBytes = downloaded;
      totalBytes = partTotal;
      totalIsEstimate = _partEstimated;
    }

    double? p;
    if (byBytes && overall != null && overall > 0 && partTotal != null) {
      p = (finishedPartBytes + _partFraction * partTotal) / overall;
    } else if (f != null || _partFraction > 0) {
      p = (partIndex + _partFraction) / parts;
    }
    if (p != null) {
      p = p.clamp(0.0, 1.0).toDouble();
      // The bar never goes back.
      if (progress == null || p > progress!) progress = p;
    }
    return f == null ? null : _partFraction;
  }

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
        if (lyricsText != null) 'lyricsText': lyricsText,
        if (creator != null) 'creator': creator!.toJson(),
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
        lyricsText: j['lyricsText'] as String?,
        creator: CreatorJob.fromJson(j['creator']),
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
