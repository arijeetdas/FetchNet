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

/// Returns yt-dlp arguments with the built-in browser's cookies for a URL
/// (empty when there are none worth sending).
typedef CookieArgsProvider = Future<List<String>> Function(String url);

/// Asks yt-dlp what a link contains (`yt-dlp -J`).
class FetchService {
  FetchService(this._engine, {this.cookieArgs});

  final YtDlpEngine _engine;
  final CookieArgsProvider? cookieArgs;
  String? _currentId;
  int _generation = 0;

  /// Fetches anonymously first. When that fails and the browser holds a
  /// sign-in for the site, tries once more with its cookies (age-restricted,
  /// private or bot-checked media).
  Future<MediaInfo> fetch(String url, {List<String> requestArgs = const []}) async {
    final generation = ++_generation;
    try {
      return await _fetchOnce(url, requestArgs);
    } on FetchException catch (e) {
      final provider = cookieArgs;
      if (e.cancelled || provider == null || requestArgs.contains('--cookies') || !_worthRetrying(e.message)) rethrow;
      final extra = await provider(url);
      if (generation != _generation) throw FetchException('Cancelled', cancelled: true);
      if (extra.isEmpty) rethrow;
      return _fetchOnce(url, [...requestArgs, ...extra]);
    }
  }

  static bool _worthRetrying(String message) {
    final m = message.toLowerCase();
    return !(m.contains('unsupported url') ||
        m.contains('getaddrinfo') ||
        m.contains('timed out') ||
        m.contains('network is unreachable') ||
        m.contains('is not a valid url'));
  }

  Future<MediaInfo> _fetchOnce(String url, List<String> requestArgs) async {
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
    _generation++;
    final id = _currentId;
    _currentId = null;
    if (id != null) await _engine.cancel(id);
  }
}
