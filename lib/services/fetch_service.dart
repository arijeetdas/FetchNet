import '../engine/engine.dart';
import '../models/media_info.dart';

class FetchException implements Exception {
  FetchException(this.message, {this.hint, this.cancelled = false});

  final String message;
  final String? hint;
  final bool cancelled;

  @override
  String toString() => message;
}

/// Asks yt-dlp what a link contains (`yt-dlp -J`).
class FetchService {
  FetchService(this._engine);

  final YtDlpEngine _engine;
  String? _currentId;

  Future<MediaInfo> fetch(String url, {List<String> requestArgs = const []}) async {
    final id = 'info-${DateTime.now().microsecondsSinceEpoch}';
    _currentId = id;
    final result = await _engine.run([
      '-J',
      '--no-playlist',
      '--flat-playlist',
      '--no-warnings',
      ...requestArgs,
      '--',
      url,
    ], id: id);
    final wasCancelled = _currentId != id;
    if (_currentId == id) _currentId = null;

    if (wasCancelled || result.cancelled) throw FetchException('Cancelled', cancelled: true);
    if (!result.ok || result.stdout.trim().isEmpty) {
      final message = extractEngineError(result.stderr.isEmpty ? result.stdout : result.stderr);
      throw FetchException(message, hint: friendlyEngineHint(message));
    }
    try {
      return MediaInfo.parse(result.stdout, sourceUrl: url, requestArgs: requestArgs);
    } on FormatException catch (e) {
      throw FetchException('Couldn\'t read the media information (${e.message}).');
    }
  }

  Future<void> cancel() async {
    final id = _currentId;
    _currentId = null;
    if (id != null) await _engine.cancel(id);
  }
}
