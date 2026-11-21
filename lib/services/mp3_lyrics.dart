import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Writes lyrics into an MP3's ID3v2 tag as a real USLT frame, the one music
/// players read.
///
/// FFmpeg 7 (the one on Android) can't write USLT: it turns "lyrics" into a
/// plain TXXX text field named "USLT" that no player looks at. This puts a
/// proper frame in its place, keeping every other frame (title, artist,
/// cover...) as it is. The audio isn't touched.
class Mp3Lyrics {
  Mp3Lyrics._();

  /// `true` when the song now has [lyrics] in a USLT frame.
  static Future<bool> write(String path, String lyrics) => Isolate.run(() => writeSync(path, lyrics));

  static bool writeSync(String path, String lyrics) {
    try {
      final file = File(path);
      final bytes = file.readAsBytesSync();
      final updated = withLyrics(bytes, lyrics);
      if (updated == null) return false;
      // Written beside it first, so a failure never leaves half a song.
      final part = File('$path.lyrics.part');
      part.writeAsBytesSync(updated, flush: true);
      part.renameSync(path);
      return true;
    } catch (_) {
      try {
        final part = File('$path.lyrics.part');
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  static const _lyricsFields = {'USLT', 'LYRICS', 'UNSYNCEDLYRICS', 'SYNCEDLYRICS', 'UNSYNCED LYRICS'};

  /// [mp3] with [lyrics] as its USLT frame (old lyrics frames and TXXX
  /// lyrics fields dropped), or `null` for a tag this can't safely edit.
  static Uint8List? withLyrics(Uint8List mp3, String lyrics) {
    final text = lyrics.replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) return null;
    final hasTag = mp3.length >= 10 && mp3[0] == 0x49 && mp3[1] == 0x44 && mp3[2] == 0x33;
    var major = 3;
    var frames = <int>[];
    var audioStart = 0;
    if (hasTag) {
      major = mp3[3];
      final flags = mp3[5];
      // ID3v2.2, unsynchronised tags or extended headers: left alone.
      if ((major != 3 && major != 4) || flags & 0xC0 != 0) return null;
      final size = _syncsafe(mp3, 6);
      final end = 10 + size;
      if (end > mp3.length) return null;
      audioStart = end + (flags & 0x10 != 0 ? 10 : 0); // a v2.4 footer
      var pos = 10;
      while (pos + 10 <= end) {
        if (mp3[pos] == 0) break; // padding
        final id = latin1.decode(mp3.sublist(pos, pos + 4), allowInvalid: true);
        final frameSize = major == 4 ? _syncsafe(mp3, pos + 4) : _be32(mp3, pos + 4);
        final frameEnd = pos + 10 + frameSize;
        if (frameSize <= 0 || frameEnd > end) return null;
        final frameFlags = (mp3[pos + 8] << 8) | mp3[pos + 9];
        final keep = switch (id) {
          'USLT' => false,
          'TXXX' => !_isLyricsField(mp3.sublist(pos + 10, frameEnd), dataLengthIndicator: major == 4 && frameFlags & 0x0001 != 0),
          _ => true,
        };
        if (keep) frames.addAll(mp3.sublist(pos, frameEnd));
        pos = frameEnd;
      }
    }
    frames = [...frames, ..._uslt(text, major)];
    final padded = [...frames, ...List<int>.filled(1024, 0)];
    final header = [0x49, 0x44, 0x33, major, 0, 0, ..._toSyncsafe(padded.length)];
    return Uint8List.fromList([...header, ...padded, ...mp3.sublist(audioStart)]);
  }

  static bool _isLyricsField(List<int> d, {required bool dataLengthIndicator}) {
    final data = dataLengthIndicator && d.length > 4 ? d.sublist(4) : d;
    if (data.length < 2) return false;
    final enc = data[0];
    String name;
    if (enc == 1 || enc == 2) {
      final units = <int>[];
      var i = 1;
      var bigEndian = enc == 2;
      if (data.length >= 3 && data[1] == 0xFF && data[2] == 0xFE) {
        bigEndian = false;
        i = 3;
      } else if (data.length >= 3 && data[1] == 0xFE && data[2] == 0xFF) {
        bigEndian = true;
        i = 3;
      }
      for (; i + 1 < data.length; i += 2) {
        final u = bigEndian ? (data[i] << 8) | data[i + 1] : data[i] | (data[i + 1] << 8);
        if (u == 0) break;
        units.add(u);
      }
      name = String.fromCharCodes(units);
    } else {
      final zero = data.indexOf(0, 1);
      name = latin1.decode(data.sublist(1, zero < 0 ? data.length : zero), allowInvalid: true);
    }
    return _lyricsFields.contains(name.trim().toUpperCase());
  }

  /// A USLT frame: UTF-16 with a BOM in ID3v2.3, UTF-8 in ID3v2.4.
  static List<int> _uslt(String text, int major) {
    final List<int> data;
    if (major == 4) {
      data = [3, ...latin1.encode('eng'), 0, ...utf8.encode(text)];
    } else {
      final units = <int>[0xFF, 0xFE];
      for (final u in text.codeUnits) {
        units
          ..add(u & 0xFF)
          ..add(u >> 8);
      }
      data = [1, ...latin1.encode('eng'), 0xFF, 0xFE, 0, 0, ...units];
    }
    final size = major == 4 ? _toSyncsafe(data.length) : _toBe32(data.length);
    return [...latin1.encode('USLT'), ...size, 0, 0, ...data];
  }

  static int _syncsafe(List<int> b, int i) => (b[i] << 21) | (b[i + 1] << 14) | (b[i + 2] << 7) | b[i + 3];
  static int _be32(List<int> b, int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  static List<int> _toSyncsafe(int n) => [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];
  static List<int> _toBe32(int n) => [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];
}
