import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// What a song file says about itself: title, artist, album, its cover
/// picture and its lyrics (synced LRC or plain).
class AudioTags {
  const AudioTags({this.title, this.artist, this.album, this.lyrics, this.cover});

  final String? title;
  final String? artist;
  final String? album;
  final String? lyrics;

  /// The picture's bytes (JPEG / PNG).
  final Uint8List? cover;

  static const empty = AudioTags();

  /// Reads [path] off the UI thread. Only the parts of the file that hold
  /// tags are read (not the audio). Unknown formats give [empty].
  static Future<AudioTags> read(String path) => Isolate.run(() => readSync(path));

  static AudioTags readSync(String path) {
    RandomAccessFile? file;
    try {
      file = File(path).openSync();
      final head = file.readSync(12);
      if (head.length < 4) return empty;
      final magic = latin1.decode(head.sublist(0, 4), allowInvalid: true);
      if (magic.startsWith('ID3')) return _id3(file);
      if (magic == 'fLaC') return _flac(file);
      if (magic == 'OggS') return _ogg(file);
      if (head.length >= 8 && latin1.decode(head.sublist(4, 8), allowInvalid: true) == 'ftyp') return _mp4(file);
      return empty;
    } catch (_) {
      return empty;
    } finally {
      file?.closeSync();
    }
  }

  // ───── MP3: ID3v2 ─────

  static AudioTags _id3(RandomAccessFile f) {
    f.setPositionSync(0);
    final header = f.readSync(10);
    final major = header[3];
    final size = _syncsafe(header, 6);
    if (size <= 0 || size > 64 * 1024 * 1024) return empty;
    final tag = f.readSync(size);
    var pos = 0;
    // Extended header.
    if (header[5] & 0x40 != 0 && tag.length > 4) {
      pos += major == 4 ? _syncsafe(tag, 0) : _be32(tag, 0) + 4;
    }
    String? title, artist, album, lyrics;
    Uint8List? cover;
    var coverType = -1;
    final v22 = major == 2;
    final idLen = v22 ? 3 : 4;
    final headLen = v22 ? 6 : 10;
    while (pos + headLen <= tag.length) {
      final id = latin1.decode(tag.sublist(pos, pos + idLen), allowInvalid: true);
      if (id.codeUnits.every((c) => c == 0)) break;
      final frameSize = v22
          ? (tag[pos + 3] << 16) | (tag[pos + 4] << 8) | tag[pos + 5]
          : (major == 4 ? _syncsafe(tag, pos + 4) : _be32(tag, pos + 4));
      final flags = v22 ? 0 : (tag[pos + 8] << 8) | tag[pos + 9];
      var start = pos + headLen;
      final end = start + frameSize;
      if (frameSize <= 0 || end > tag.length) break;
      // ID3v2.4 "data length indicator": four bytes before the frame data.
      if (major == 4 && flags & 0x0001 != 0) start += 4;
      final data = tag.sublist(start, end);
      switch (id) {
        case 'TIT2' || 'TT2':
          title ??= _id3Text(data);
        case 'TPE1' || 'TP1':
          artist ??= _id3Text(data);
        case 'TALB' || 'TAL':
          album ??= _id3Text(data);
        case 'USLT' || 'ULT':
          lyrics ??= _id3Lyrics(data);
        case 'APIC' || 'PIC':
          final pic = _id3Picture(data, v22: v22);
          // The front cover (type 3) wins over other pictures.
          if (pic != null && (cover == null || (pic.$1 == 3 && coverType != 3))) {
            cover = pic.$2;
            coverType = pic.$1;
          }
      }
      pos = end;
    }
    return AudioTags(title: title, artist: artist, album: album, lyrics: lyrics, cover: cover);
  }

  static int _syncsafe(List<int> b, int i) => (b[i] << 21) | (b[i + 1] << 14) | (b[i + 2] << 7) | b[i + 3];
  static int _be32(List<int> b, int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  static int _le32(List<int> b, int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

  /// Decodes ID3 text in [encoding] (0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16
  /// BE, 3 UTF-8).
  static String _decode(List<int> b, int encoding) {
    if (encoding == 1 || encoding == 2) {
      var bigEndian = encoding == 2;
      var i = 0;
      if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        bigEndian = false;
        i = 2;
      } else if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
        bigEndian = true;
        i = 2;
      }
      final units = <int>[];
      for (; i + 1 < b.length; i += 2) {
        final u = bigEndian ? (b[i] << 8) | b[i + 1] : b[i] | (b[i + 1] << 8);
        if (u == 0) break;
        units.add(u);
      }
      return String.fromCharCodes(units);
    }
    final zero = b.indexOf(0);
    final bytes = zero >= 0 ? b.sublist(0, zero) : b;
    return encoding == 3 ? utf8.decode(bytes, allowMalformed: true) : latin1.decode(bytes, allowInvalid: true);
  }

  /// Where the null-terminated string starting at [from] ends (after its
  /// terminator) in [encoding].
  static int _skipString(List<int> b, int from, int encoding) {
    if (encoding == 1 || encoding == 2) {
      for (var i = from; i + 1 < b.length; i += 2) {
        if (b[i] == 0 && b[i + 1] == 0) return i + 2;
      }
      return b.length;
    }
    final zero = b.indexOf(0, from);
    return zero < 0 ? b.length : zero + 1;
  }

  static String? _id3Text(List<int> d) {
    if (d.isEmpty) return null;
    return _clean(_decode(d.sublist(1), d[0]));
  }

  static String? _id3Lyrics(List<int> d) {
    if (d.length < 5) return null;
    final enc = d[0];
    final textStart = _skipString(d, 4, enc); // language (3), then the description
    if (textStart >= d.length) return null;
    return _clean(_decode(d.sublist(textStart), enc).replaceAll('\r\n', '\n'));
  }

  static (int, Uint8List)? _id3Picture(List<int> d, {required bool v22}) {
    if (d.length < 6) return null;
    final enc = d[0];
    var i = 1;
    i = v22 ? 4 : _skipString(d, 1, 0); // image format (3) / MIME type
    if (i >= d.length) return null;
    final type = d[i];
    i = _skipString(d, i + 1, enc); // description
    if (i >= d.length) return null;
    return (type, Uint8List.fromList(d.sublist(i)));
  }

  static String? _clean(String? s) {
    final t = s?.replaceAll('\u0000', '').trim();
    return t == null || t.isEmpty ? null : t;
  }

  // ───── M4A / MP4: the ilst atom ─────

  static AudioTags _mp4(RandomAccessFile f) {
    final length = f.lengthSync();
    var pos = 0;
    while (pos + 8 <= length) {
      f.setPositionSync(pos);
      final h = f.readSync(16);
      if (h.length < 8) break;
      var size = _be32(h, 0);
      final type = latin1.decode(h.sublist(4, 8), allowInvalid: true);
      var headerLen = 8;
      if (size == 1 && h.length >= 16) {
        size = (_be32(h, 8) << 32) | _be32(h, 12);
        headerLen = 16;
      } else if (size == 0) {
        size = length - pos;
      }
      if (size < headerLen) break;
      if (type == 'moov') {
        if (size > 64 * 1024 * 1024) return empty;
        f.setPositionSync(pos + headerLen);
        return _ilst(f.readSync(size - headerLen));
      }
      pos += size;
    }
    return empty;
  }

  /// Finds moov › udta › meta › ilst in [moov] (the moov box's contents).
  static AudioTags _ilst(List<int> moov) {
    List<int>? child(List<int> box, String name, {int skip = 0}) {
      var i = skip;
      while (i + 8 <= box.length) {
        final size = _be32(box, i);
        if (size < 8 || i + size > box.length) return null;
        if (latin1.decode(box.sublist(i + 4, i + 8), allowInvalid: true) == name) return box.sublist(i + 8, i + size);
        i += size;
      }
      return null;
    }

    final udta = child(moov, 'udta');
    // "meta" is a full box: 4 bytes of version and flags before its children.
    final meta = udta == null ? null : child(udta, 'meta');
    final ilst = meta == null ? null : (child(meta, 'ilst', skip: 4) ?? child(meta, 'ilst'));
    if (ilst == null) return empty;
    String? title, artist, album, lyrics;
    Uint8List? cover;
    var i = 0;
    while (i + 8 <= ilst.length) {
      final size = _be32(ilst, i);
      if (size < 8 || i + size > ilst.length) break;
      final name = latin1.decode(ilst.sublist(i + 4, i + 8), allowInvalid: true);
      final data = child(ilst.sublist(i + 8, i + size), 'data');
      if (data != null && data.length >= 8) {
        final payload = data.sublist(8); // type (4) and locale (4)
        String text() => utf8.decode(payload, allowMalformed: true);
        switch (name) {
          case '©nam':
            title = _clean(text());
          case '©ART':
            artist = _clean(text());
          case 'aART':
            artist ??= _clean(text());
          case '©alb':
            album = _clean(text());
          case '©lyr':
            lyrics = _clean(text().replaceAll('\r\n', '\n'));
          case 'covr':
            cover ??= Uint8List.fromList(payload);
        }
      }
      i += size;
    }
    return AudioTags(title: title, artist: artist, album: album, lyrics: lyrics, cover: cover);
  }

  // ───── FLAC ─────

  static AudioTags _flac(RandomAccessFile f) {
    f.setPositionSync(4);
    var tags = empty;
    Uint8List? cover;
    for (var guard = 0; guard < 64; guard++) {
      final h = f.readSync(4);
      if (h.length < 4) break;
      final last = h[0] & 0x80 != 0;
      final type = h[0] & 0x7F;
      final size = (h[1] << 16) | (h[2] << 8) | h[3];
      if (type == 4 || type == 6) {
        final block = f.readSync(size);
        if (type == 4) tags = _vorbisComments(block, 0);
        if (type == 6) cover ??= _flacPicture(block);
      } else {
        f.setPositionSync(f.positionSync() + size);
      }
      if (last) break;
    }
    return AudioTags(title: tags.title, artist: tags.artist, album: tags.album, lyrics: tags.lyrics, cover: cover ?? tags.cover);
  }

  /// A FLAC PICTURE block (also inside Ogg as METADATA_BLOCK_PICTURE).
  static Uint8List? _flacPicture(List<int> b) {
    try {
      var i = 4; // picture type
      final mimeLen = _be32(b, i);
      i += 4 + mimeLen;
      final descLen = _be32(b, i);
      i += 4 + descLen + 16; // width, height, depth, colours
      final dataLen = _be32(b, i);
      i += 4;
      if (i + dataLen > b.length) return null;
      return Uint8List.fromList(b.sublist(i, i + dataLen));
    } catch (_) {
      return null;
    }
  }

  /// Vorbis comments ("KEY=value", little-endian lengths) from [start].
  static AudioTags _vorbisComments(List<int> b, int start) {
    try {
      var i = start;
      final vendorLen = _le32(b, i);
      i += 4 + vendorLen;
      final count = _le32(b, i);
      i += 4;
      String? title, artist, album, lyrics;
      Uint8List? cover;
      for (var n = 0; n < count && i + 4 <= b.length; n++) {
        final len = _le32(b, i);
        i += 4;
        if (i + len > b.length) break;
        final entry = utf8.decode(b.sublist(i, i + len), allowMalformed: true);
        i += len;
        final eq = entry.indexOf('=');
        if (eq <= 0) continue;
        final key = entry.substring(0, eq).toUpperCase();
        final value = entry.substring(eq + 1);
        switch (key) {
          case 'TITLE':
            title ??= _clean(value);
          case 'ARTIST':
            artist ??= _clean(value);
          case 'ALBUM':
            album ??= _clean(value);
          case 'LYRICS' || 'UNSYNCEDLYRICS':
            lyrics ??= _clean(value.replaceAll('\r\n', '\n'));
          case 'METADATA_BLOCK_PICTURE':
            try {
              cover ??= _flacPicture(base64.decode(value));
            } catch (_) {}
        }
      }
      return AudioTags(title: title, artist: artist, album: album, lyrics: lyrics, cover: cover);
    } catch (_) {
      return empty;
    }
  }

  // ───── Opus / Vorbis in Ogg ─────

  static AudioTags _ogg(RandomAccessFile f) {
    // The comment packet is the second one; it may span several pages
    // (a cover inside it), so pages are read until it's complete.
    f.setPositionSync(0);
    final packets = <List<int>>[];
    var current = <int>[];
    var read = 0;
    while (packets.length < 2 && read < 16 * 1024 * 1024) {
      final h = f.readSync(27);
      if (h.length < 27 || latin1.decode(h.sublist(0, 4), allowInvalid: true) != 'OggS') break;
      final segments = h[26];
      final table = f.readSync(segments);
      final body = f.readSync(table.fold<int>(0, (s, x) => s + x));
      read += 27 + segments + body.length;
      var offset = 0;
      for (final lace in table) {
        current.addAll(body.sublist(offset, offset + lace));
        offset += lace;
        if (lace < 255) {
          packets.add(current);
          current = <int>[];
          if (packets.length == 2) break;
        }
      }
    }
    if (packets.length < 2) return empty;
    final comments = packets[1];
    final head = latin1.decode(comments.take(8).toList(), allowInvalid: true);
    if (head == 'OpusTags') return _vorbisComments(comments, 8);
    if (comments.length > 7 && comments[0] == 3 && head.substring(1, 7) == 'vorbis') return _vorbisComments(comments, 7);
    return empty;
  }
}
