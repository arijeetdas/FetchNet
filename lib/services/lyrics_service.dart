import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/media_info.dart';

/// What to look lyrics up by: a song's artist, title, album and length.
class LyricsQuery {
  const LyricsQuery({required this.artist, required this.track, this.album, this.duration});

  final String artist;
  final String track;
  final String? album;

  /// Seconds, to tell versions apart (radio edit, live…).
  final double? duration;

  Map<String, dynamic> toJson() => {
        'artist': artist,
        'track': track,
        if (album != null) 'album': album,
        if (duration != null) 'duration': duration,
      };

  static LyricsQuery? fromJson(Object? j) {
    if (j is! Map) return null;
    final artist = j['artist'], track = j['track'];
    if (artist is! String || track is! String) return null;
    return LyricsQuery(
      artist: artist,
      track: track,
      album: j['album'] as String?,
      duration: (j['duration'] as num?)?.toDouble(),
    );
  }

  /// The song in [info], or `null` when it doesn't look like music.
  ///
  /// Sites that know the song (YouTube Music, an artist's "Topic" channel,
  /// music services) say its artist and title; otherwise a "Artist - Title"
  /// name on a music video is used. A lookup that finds nothing means it
  /// wasn't a song after all, and nothing is added.
  static LyricsQuery? fromInfo(MediaInfo info) {
    final raw = info.raw;
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final artists = raw['artists'];
    final artist = text(raw['artist']) ??
        (artists is List && artists.isNotEmpty ? text(artists.first) : null) ??
        text(raw['creator']);
    final track = text(raw['track']);
    final album = text(raw['album']);
    if (artist != null && track != null) {
      return LyricsQuery(artist: _firstArtist(artist), track: cleanTitle(track), album: album, duration: info.duration);
    }
    final categories = raw['categories'];
    final music = info.isYouTubeMusic ||
        (categories is List && categories.contains('Music')) ||
        (info.uploader ?? '').endsWith(' - Topic');
    return fromTitle(info.title, uploader: info.uploader, duration: info.duration, music: music);
  }

  /// From a video's title and channel (a playlist's entries know no more).
  static LyricsQuery? fromTitle(String title, {String? uploader, double? duration, bool music = false}) {
    // Songs are a few minutes long, not an hour-long mix.
    if (duration != null && (duration < 45 || duration > 15 * 60)) return null;
    final topic = uploader != null && uploader.endsWith(' - Topic');
    final cleaned = cleanTitle(title);
    final dash = RegExp(r'\s+[-–—]\s+').firstMatch(cleaned);
    if (dash != null) {
      final artist = cleaned.substring(0, dash.start).trim();
      final track = cleaned.substring(dash.end).trim();
      if (artist.isNotEmpty && track.isNotEmpty) {
        return LyricsQuery(artist: _firstArtist(artist), track: track, duration: duration);
      }
    }
    if ((music || topic) && uploader != null && cleaned.isNotEmpty) {
      final artist = uploader.replaceFirst(RegExp(r'\s*-\s*Topic$'), '').replaceFirst(RegExp(r'VEVO$'), '').trim();
      if (artist.isNotEmpty) return LyricsQuery(artist: _firstArtist(artist), track: cleaned, duration: duration);
    }
    return null;
  }

  static String _firstArtist(String artist) => artist.split(RegExp(r',|&| x | feat\.? | ft\.? ', caseSensitive: false)).first.trim();

  /// "Song (Official Video) [4K] ft. Someone" → "Song".
  static String cleanTitle(String title) {
    var t = title;
    t = t.replaceAll(
      RegExp(
        r'\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|mv|m/v|remaster|live|explicit|clean)[^\)\]]*[\)\]]',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceAll(RegExp(r'\s+(feat\.?|ft\.?)\s+.*$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\s*\|.*$'), '');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

/// Synced lyrics (LRC: `[mm:ss.xx] line`) from LRCLIB, a free and open
/// lyrics database.
class LyricsService {
  LyricsService({Future<String?> Function(Uri uri)? get}) : _get = get ?? _httpGet;

  final Future<String?> Function(Uri uri) _get;

  static const _host = 'lrclib.net';

  /// The best synced lyrics for [q], or `null` (not a song LRCLIB knows, or
  /// no synced version).
  Future<String?> synced(LyricsQuery q) async {
    final byName = await _search({'track_name': q.track, 'artist_name': q.artist});
    final pick = _best(byName, q) ?? _best(await _search({'q': '${q.artist} ${q.track}'}), q);
    return pick;
  }

  Future<List<Map<String, dynamic>>> _search(Map<String, String> params) async {
    try {
      final body = await _get(Uri.https(_host, '/api/search', params));
      if (body == null) return const [];
      final data = jsonDecode(body);
      if (data is! List) return const [];
      return [for (final e in data) if (e is Map) e.cast<String, dynamic>()];
    } catch (_) {
      return const [];
    }
  }

  /// A result with synced lyrics: the same artist and about the same
  /// length when it's known.
  static String? _best(List<Map<String, dynamic>> results, LyricsQuery q) {
    String norm(Object? s) => '$s'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final artist = norm(q.artist);
    final track = norm(q.track);
    Map<String, dynamic>? best;
    var bestScore = -1.0;
    for (final r in results) {
      final lrc = r['syncedLyrics'];
      if (lrc is! String || lrc.trim().isEmpty || r['instrumental'] == true) continue;
      final d = (r['duration'] as num?)?.toDouble();
      if (q.duration != null && d != null && (d - q.duration!).abs() > 4) continue;
      var score = 0.0;
      final ra = norm(r['artistName']);
      final rt = norm(r['trackName']);
      if (ra == artist) {
        score += 2;
      } else if (ra.contains(artist) || artist.contains(ra)) {
        score += 1;
      } else {
        continue;
      }
      if (rt == track) {
        score += 2;
      } else if (rt.contains(track) || track.contains(rt)) {
        score += 1;
      } else {
        continue;
      }
      if (q.duration != null && d != null) score += 1 - (d - q.duration!).abs() / 4;
      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }
    return best?['syncedLyrics'] as String?;
  }

  static Future<String?> _httpGet(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri);
      // LRCLIB asks apps to say who they are.
      req.headers.set(HttpHeaders.userAgentHeader, 'FetchNet (https://git-fetchnet.arijeet.in)');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// yt-dlp arguments that write [lrc] into the song's own lyrics tag (ID3
/// USLT for MP3, ©lyr for M4A, LYRICS for Opus / Vorbis), through the
/// FFmpeg metadata step.
List<String> lyricsEmbedArgs(String lrc, {required List<String> formatArgs}) {
  // yt-dlp splits these like a POSIX shell: single quotes keep everything
  // (new lines too); a quote inside becomes '"'"'.
  final quoted = "'${'lyrics=$lrc'.replaceAll("'", "'\"'\"'")}'";
  return [
    if (!formatArgs.contains('--embed-metadata')) '--embed-metadata',
    '--postprocessor-args',
    'Metadata+ffmpeg_o:-metadata $quoted',
  ];
}
