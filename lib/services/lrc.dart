/// One line of synced lyrics.
class LyricLine {
  const LyricLine(this.time, this.text);

  final Duration time;
  final String text;
}

/// Lyrics from an LRC text: [synced] lines in time order, or [plain] text
/// when there are no timestamps.
class Lyrics {
  const Lyrics({this.synced = const [], this.plain});

  final List<LyricLine> synced;
  final String? plain;

  bool get isEmpty => synced.isEmpty && (plain == null || plain!.trim().isEmpty);
  bool get isSynced => synced.isNotEmpty;

  static final _stamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final _offset = RegExp(r'^\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);
  static final _metaTag = RegExp(r'^\[[a-z]+:.*\]$', caseSensitive: false);
  static final _wordStamp = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

  static Lyrics parse(String? text) {
    if (text == null || text.trim().isEmpty) return const Lyrics();
    var offsetMs = 0;
    final lines = <LyricLine>[];
    final plain = <String>[];
    for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      final offset = _offset.firstMatch(line);
      if (offset != null) {
        offsetMs = int.tryParse(offset.group(1)!) ?? 0;
        continue;
      }
      // Every timestamp at the start ("[00:12.00][01:30.00]Chorus").
      final stamps = <Duration>[];
      var rest = line;
      while (true) {
        final m = _stamp.matchAsPrefix(rest);
        if (m == null) break;
        final minutes = int.parse(m.group(1)!);
        final seconds = int.parse(m.group(2)!);
        final fraction = m.group(3);
        final ms = fraction == null ? 0 : int.parse(fraction.padRight(3, '0').substring(0, 3));
        stamps.add(Duration(minutes: minutes, seconds: seconds, milliseconds: ms));
        rest = rest.substring(m.end);
      }
      if (stamps.isEmpty) {
        if (line.isNotEmpty && !_metaTag.hasMatch(line)) plain.add(line);
        continue;
      }
      // Word-by-word timing ("<00:12.30>word") is shown as the plain line.
      final words = rest.replaceAll(_wordStamp, '').trim();
      for (final t in stamps) {
        lines.add(LyricLine(t - Duration(milliseconds: offsetMs), words));
      }
    }
    if (lines.isEmpty) return Lyrics(plain: plain.isEmpty ? null : plain.join('\n'));
    lines.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(synced: lines);
  }

  /// The line playing at [position] (-1 before the first).
  int indexAt(Duration position) {
    var lo = 0, hi = synced.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (synced[mid].time <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }
}
