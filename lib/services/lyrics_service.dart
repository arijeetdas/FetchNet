import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/media_info.dart';
import 'lrc.dart';

/// What to look lyrics up by: the video's title (and channel / description,
/// which name the singers), with the artist and song when they're known.
class LyricsQuery {
  const LyricsQuery({this.artist, this.track, this.album, this.duration, this.title = '', this.context, this.confident = false});

  /// The artist and song: from the site, or guessed from the title.
  final String? artist;
  final String? track;
  final String? album;

  /// Seconds, to tell versions apart (radio edit, live…).
  final double? duration;

  /// The video's whole title ("Kesariya - Brahmāstra | Ranbir Kapoor | Pritam
  /// | Arijit Singh"): where the song's name and its singers are looked for.
  final String title;

  /// The channel and the start of the description, which often list the
  /// singers ("Singer: Arijit Singh").
  final String? context;

  /// [artist] and [track] come from the site (or an artist's channel), not a
  /// guess from the title.
  final bool confident;

  Map<String, dynamic> toJson() => {
        if (artist != null) 'artist': artist,
        if (track != null) 'track': track,
        if (album != null) 'album': album,
        if (duration != null) 'duration': duration,
        if (title.isNotEmpty) 'title': title,
        if (context != null) 'context': context,
        if (confident) 'confident': true,
      };

  static LyricsQuery? fromJson(Object? j) {
    if (j is! Map) return null;
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    final q = LyricsQuery(
      artist: s(j['artist']),
      track: s(j['track']),
      album: s(j['album']),
      duration: (j['duration'] as num?)?.toDouble(),
      title: s(j['title']) ?? '',
      context: s(j['context']),
      // Saved before titles were kept: those names came from the site.
      confident: j['confident'] == true || (j['title'] == null && s(j['artist']) != null),
    );
    return q.title.isEmpty && (q.artist == null || q.track == null) ? null : q;
  }

  /// The song in [info], or `null` when it doesn't look like music.
  ///
  /// Sites that know the song (YouTube Music, an artist's "Topic" channel,
  /// music services) say its artist and title. Otherwise the title is used:
  /// "Artist - Song", or a label's "Song - Movie | Cast | Singer" upload.
  /// A lookup that finds nothing means it wasn't a song after all.
  static LyricsQuery? fromInfo(MediaInfo info) {
    final raw = info.raw;
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final description = text(raw['description']);
    final context = <String>{
      ?info.uploader,
      ?text(raw['channel']),
      if (description != null) description.length > 400 ? description.substring(0, 400) : description,
    }.join('\n');
    final artists = raw['artists'];
    final artist = text(raw['artist']) ??
        (artists is List && artists.isNotEmpty ? text(artists.first) : null) ??
        text(raw['creator']);
    final track = text(raw['track']);
    final album = text(raw['album']);
    if (artist != null && track != null) {
      return LyricsQuery(
        artist: _firstArtist(artist),
        track: cleanTitle(track),
        album: album,
        duration: info.duration,
        title: info.title,
        context: context.isEmpty ? null : context,
        confident: true,
      );
    }
    final categories = raw['categories'];
    final music = info.isYouTubeMusic ||
        (categories is List && categories.contains('Music')) ||
        (info.uploader ?? '').endsWith(' - Topic');
    return fromTitle(info.title, uploader: info.uploader, duration: info.duration, music: music, context: context);
  }

  /// From a video's title and channel (a playlist's entries know no more).
  static LyricsQuery? fromTitle(String title, {String? uploader, double? duration, bool music = false, String? context}) {
    // Songs are a few minutes long, not an hour-long mix.
    if (duration != null && (duration < 45 || duration > 15 * 60)) return null;
    final topic = uploader != null && uploader.endsWith(' - Topic');
    final cleaned = cleanTitle(title);
    final hints = <String>{?uploader, if (context != null && context.isNotEmpty) context}.join('\n');
    LyricsQuery query({String? artist, String? track, bool confident = false}) => LyricsQuery(
          artist: artist == null ? null : _firstArtist(artist),
          track: track,
          duration: duration,
          title: title,
          context: hints.isEmpty ? null : hints,
          confident: confident,
        );
    if (topic && cleaned.isNotEmpty) {
      return query(artist: uploader.replaceFirst(RegExp(r'\s*-\s*Topic$'), '').trim(), track: cleaned, confident: true);
    }
    // "Artist - Song" (or "Song - Movie": the lookup checks either way).
    final dash = RegExp(r'\s+[-–—]\s+').firstMatch(cleaned);
    if (dash != null) {
      final artist = cleaned.substring(0, dash.start).trim();
      final track = cleaned.substring(dash.end).replaceFirst(RegExp(r'\s*[|:].*$'), '').trim();
      if (artist.isNotEmpty && track.isNotEmpty) return query(artist: artist, track: track);
    }
    if (music && uploader != null && cleaned.isNotEmpty) {
      final artist = uploader.replaceFirst(RegExp(r'VEVO$'), '').trim();
      if (artist.isNotEmpty) return query(artist: artist, track: _segments(title).firstOrNull ?? cleaned);
    }
    // "Song | Movie | Singer", "Movie: Song": a music label's upload.
    if (_segments(title).length > 1) return query();
    return null;
  }

  static String _firstArtist(String artist) => artist.split(RegExp(r',|&| x | feat\.? | ft\.? ', caseSensitive: false)).first.trim();

  /// "Song (Official Video) [4K] ft. Someone" → "Song".
  static String cleanTitle(String title) {
    var t = title;
    t = t.replaceAll(
      RegExp(
        r'\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|8k|mv|m/v|remaster|live|explicit|clean|from)[^\)\]]*[\)\]]',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceAll(RegExp(r'\s+(feat\.?|ft\.?)\s+.*$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\s*\|.*$'), '');
    t = t.replaceAll(_noise, ' ');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Words that describe the upload, not the song.
  static final _noise = RegExp(
    r'\b(full\s+)?(video\s+|audio\s+)?song\b|\bfull\s+video\b|\bofficial(\s+music)?(\s+video|\s+audio)?\b|'
    r'\blyric(al)?(\s+video)?\b|\bwith\s+lyrics\b|\blyrics\b|\b[48]k\b|\bhd\b|\bhq\b|\bseason\s+\d+\b|\bep(isode)?\.?\s*\d+\b',
    caseSensitive: false,
  );

  /// The title's parts ("Aashiqui 2: Tum Hi Ho 8K Full Song | Arijit Singh"
  /// → "Aashiqui 2", "Tum Hi Ho", "Arijit Singh"), cleaned.
  static List<String> _segments(String title) {
    final out = <String>[];
    for (final part in title.split(RegExp(r'\s*(?:[|｜/•]|:\s|\s[-–—]\s)\s*'))) {
      final c = cleanTitle(part);
      if (c.isNotEmpty && !RegExp(r'^\d+$').hasMatch(c) && !out.contains(c)) out.add(c);
    }
    return out;
  }

  /// What to search LRCLIB for, most likely first.
  List<String> get searchPhrases {
    final out = <String>[
      if (artist != null && track != null) '$artist $track',
      ..._segments(title),
      ?track,
    ];
    final seen = <String>{};
    return [for (final s in out) if (seen.add(_words(s))) s];
  }
}

/// Lyrics for a song: found on LRCLIB, or imported from a file.
class LyricsMatch {
  const LyricsMatch({
    required this.lyrics,
    required this.artist,
    required this.track,
    this.album,
    this.duration,
    this.synced = true,
    this.score = 0,
    this.strong = false,
    this.fileName,
  });

  /// LRC text (`[mm:ss.xx] line`) when [synced], else plain lines.
  final String lyrics;
  final String artist;
  final String track;
  final String? album;
  final double? duration;

  /// Each line has its time, so players show it as it's sung.
  final bool synced;

  /// How well it fits the video (higher is better).
  final double score;

  /// The song's name and singer are in the title and its length matches.
  final bool strong;

  /// Imported from this file instead of LRCLIB.
  final String? fileName;

  bool get imported => fileName != null;

  /// From LRCLIB's search results: synced lyrics when it has them, else the
  /// plain ones; `null` without either (or for instrumentals).
  static LyricsMatch? fromResult(Map<String, dynamic> r, {double score = 0, bool strong = false}) {
    if (r['instrumental'] == true) return null;
    final synced = r['syncedLyrics'];
    final plain = r['plainLyrics'];
    final hasSynced = synced is String && synced.trim().isNotEmpty;
    if (!hasSynced && (plain is! String || plain.trim().isEmpty)) return null;
    return LyricsMatch(
      lyrics: hasSynced ? synced : plain as String,
      synced: hasSynced,
      artist: '${r['artistName'] ?? ''}',
      track: '${r['trackName'] ?? r['name'] ?? ''}',
      album: r['albumName'] is String && (r['albumName'] as String).isNotEmpty ? r['albumName'] as String : null,
      duration: (r['duration'] as num?)?.toDouble(),
      score: score,
      strong: strong,
    );
  }

  /// Lyrics from a `.lrc` or `.txt` file the user picked.
  static LyricsMatch? fromFile(String name, String text) {
    final clean = text.replaceFirst('﻿', '').replaceAll('\r\n', '\n').trim();
    if (clean.isEmpty) return null;
    final parsed = Lyrics.parse(clean);
    if (parsed.isEmpty) return null;
    String? tag(String key) => RegExp('^\\[$key:\\s*(.+?)\\s*\\]\$', multiLine: true, caseSensitive: false).firstMatch(clean)?.group(1);
    final base = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final last = parsed.synced.isEmpty ? null : parsed.synced.last.time;
    return LyricsMatch(
      lyrics: clean,
      synced: parsed.isSynced,
      track: tag('ti') ?? base,
      artist: tag('ar') ?? '',
      album: tag('al'),
      duration: last == null ? null : last.inMilliseconds / 1000,
      fileName: name,
    );
  }

  /// The same lyrics (the picker keeps its choice across searches).
  bool sameAs(LyricsMatch other) => lyrics == other.lyrics && track == other.track && artist == other.artist;
}

/// What a lookup found: the lyrics picked for the song (synced ones that fit
/// it, or `null`), and the other results to choose from instead.
class LyricsLookup {
  const LyricsLookup({this.best, this.matches = const []});

  final LyricsMatch? best;

  /// Every result with lyrics, best first.
  final List<LyricsMatch> matches;

  static const empty = LyricsLookup();
}

/// Lowercase words without accents or punctuation ("Brahmāstra!" →
/// "brahmastra"), in any script.
String _words(String s) {
  const fold = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a', //
    'ç': 'c', 'ć': 'c', 'č': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ė': 'e', 'ę': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'į': 'i', 'ñ': 'n', 'ń': 'n', //
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', //
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u', 'ý': 'y', 'ÿ': 'y', //
    'ś': 's', 'š': 's', 'ş': 's', 'ź': 'z', 'ż': 'z', 'ž': 'z', 'ł': 'l', 'ß': 'ss',
  };
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    b.write(fold[ch] ?? ch);
  }
  return b.toString().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
}

/// Synced lyrics (LRC: `[mm:ss.xx] line`) from LRCLIB, a free and open
/// lyrics database.
class LyricsService {
  LyricsService({Future<String?> Function(Uri uri)? get}) : _get = get ?? _httpGet;

  final Future<String?> Function(Uri uri) _get;

  static const _host = 'lrclib.net';

  /// The best synced lyrics for [q], or `null` (not a song LRCLIB knows, or
  /// no synced version).
  Future<String?> synced(LyricsQuery q) async => (await find(q))?.lyrics;

  Future<LyricsMatch?> find(LyricsQuery q) async => (await lookup(q)).best;

  /// Searches by artist and song when they're known, then by each part of
  /// the title, and stops at the first sure match. Everything found is
  /// listed too, for picking another.
  Future<LyricsLookup> lookup(LyricsQuery q) async {
    final pool = <Map<String, dynamic>>[];
    final seen = <String>{};
    LyricsMatch? best;
    Future<bool> searchFor(Map<String, String> params) async {
      for (final r in await _search(params)) {
        if (seen.add(_key(r))) pool.add(r);
      }
      best = pick(pool, q);
      return best?.strong ?? false;
    }

    Future<void> run() async {
      if (q.artist != null && q.track != null) {
        if (await searchFor({'track_name': q.track!, 'artist_name': q.artist!})) return;
      }
      for (final phrase in q.searchPhrases.take(4)) {
        if (await searchFor({'q': phrase})) return;
      }
    }

    await run();
    return LyricsLookup(best: best, matches: rank(pool, q));
  }

  /// LRCLIB's results for what the user typed: synced lyrics first, then
  /// the ones closest to [duration] (the video's length).
  Future<List<LyricsMatch>> search(String text, {double? duration}) async {
    final query = text.trim();
    if (query.isEmpty) return const [];
    final found = [for (final r in await _search({'q': query})) ?LyricsMatch.fromResult(r)];
    double gap(LyricsMatch m) => duration == null || m.duration == null ? 0 : (m.duration! - duration).abs();
    found.sort((a, b) {
      if (a.synced != b.synced) return a.synced ? -1 : 1;
      return gap(a).compareTo(gap(b));
    });
    return found;
  }

  static String _key(Map<String, dynamic> r) => '${r['id'] ?? '${r['artistName']}|${r['trackName']}|${r['duration']}'}';

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

  /// Name parts too common to tell singers apart.
  static const _common = {'music', 'sound', 'songs', 'studio', 'records', 'official', 'band', 'group', 'orchestra', 'singh', 'kumar', 'khan'};

  static final _versionWord = RegExp(r'\b(live|remix|acoustic|unplugged|reprise|version|cover|lofi|slowed|reverb)\b');

  /// The synced lyrics that fit the video best (see [_score]), or `null`.
  static LyricsMatch? pick(List<Map<String, dynamic>> results, LyricsQuery q) {
    final fit = _Fit(q);
    LyricsMatch? best;
    for (final r in results) {
      final lrc = r['syncedLyrics'];
      if (lrc is! String || lrc.trim().isEmpty) continue;
      final s = fit.score(r);
      if (s == null) continue;
      if (best == null || s.$1 > best.score) best = LyricsMatch.fromResult(r, score: s.$1, strong: s.$2);
    }
    return best;
  }

  /// Every result with lyrics: the ones that fit the video first (synced
  /// before plain, then by score), then the rest, synced and closest in
  /// length first.
  static List<LyricsMatch> rank(List<Map<String, dynamic>> results, LyricsQuery q) {
    final fit = _Fit(q);
    final fitting = <LyricsMatch>[];
    final others = <LyricsMatch>[];
    for (final r in results) {
      final s = fit.score(r);
      final m = LyricsMatch.fromResult(r, score: s?.$1 ?? -100, strong: s?.$2 ?? false);
      if (m == null) continue;
      (s == null ? others : fitting).add(m);
    }
    double gap(LyricsMatch m) => q.duration == null || m.duration == null ? 0 : (m.duration! - q.duration!).abs();
    fitting.sort((a, b) => a.synced != b.synced ? (a.synced ? -1 : 1) : b.score.compareTo(a.score));
    others.sort((a, b) => a.synced != b.synced ? (a.synced ? -1 : 1) : gap(a).compareTo(gap(b)));
    return [...fitting, ...others];
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

/// How well an LRCLIB result fits a video: its song name is in the title (or
/// is the known song), one of its singers is named in the title, channel or
/// description, and its length is close.
class _Fit {
  _Fit(this.q)
      : titleWords = ' ${_words('${q.title} ${q.track ?? ''} ${q.artist ?? ''}')} ',
        singerWords = ' ${_words('${q.title}\n${q.context ?? ''}\n${q.artist ?? ''}')} ',
        segments = [for (final s in LyricsQuery._segments(q.title)) _words(s)],
        knownArtist = q.artist == null ? null : _words(q.artist!);

  final LyricsQuery q;
  final String titleWords;
  final String singerWords;
  final List<String> segments;
  final String? knownArtist;

  /// (score, strong), or `null` when it isn't this song.
  (double, bool)? score(Map<String, dynamic> r) {
    final rawTrack = '${r['trackName'] ?? r['name'] ?? ''}';
    final rawArtist = '${r['artistName'] ?? ''}';
    // "Kesariya (From "Brahmastra")" → "kesariya".
    var song = _words(rawTrack.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), ''));
    if (song.isEmpty) song = _words(rawTrack);
    if (song.isEmpty) return null;
    final parts = {...segments, if (q.track != null) _words(q.track!)};
    final exact = parts.contains(song);
    if (!exact && (song.length < 4 || !titleWords.contains(' $song '))) return null;
    final singers = [
      for (final a in rawArtist.split(RegExp(r',|&|/|;|\bx\b|\bfeat\.?|\bft\.?|\band\b|\bwith\b', caseSensitive: false)))
        if (_words(a).length >= 3) _words(a),
    ];
    // The whole name, or a distinctive part of it ("Arijit" for Arijit
    // Singh, as titles often shorten it).
    bool named(String a) => singerWords.contains(' $a ') ||
        a.split(' ').any((w) => w.length >= 5 && !LyricsService._common.contains(w) && singerWords.contains(' $w '));
    if (!singers.any(named)) return null;
    final d = (r['duration'] as num?)?.toDouble();
    final gap = d == null || q.duration == null ? null : (d - q.duration!).abs();
    // The song's name usually comes first in a title ("Song | Movie |
    // Cast"); the movie's name can be another song's.
    final position = segments.indexOf(song);
    final titled = (q.track != null && _words(q.track!) == song) || position == 0;
    // A music video runs a little longer than the song (an intro, an outro;
    // a lyric video a bit more), not minutes: that's another version.
    if (gap != null && gap > (titled ? 90 : 45)) return null;
    var score = exact ? 2.0 : 1.0;
    if (position == 0) score += 2;
    if (position == 1) score += 1;
    if (knownArtist != null && singers.contains(knownArtist)) score += 1;
    if (gap != null) score += gap <= 3 ? 3 : (gap <= 8 ? 2 : (gap <= 20 ? 1 : 0));
    // A live version or remix only when the title says so.
    final version = LyricsService._versionWord.firstMatch(_words(rawTrack));
    if (version != null && !titleWords.contains(' ${version.group(1)} ')) score -= 2;
    return (score, gap == null || gap <= 8);
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
