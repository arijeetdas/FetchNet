import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fetchnet/features/player/art_palette.dart';
import 'package:fetchnet/services/audio_tags.dart';
import 'package:fetchnet/services/lrc.dart';
import 'package:fetchnet/services/mp3_lyrics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _be32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];
List<int> _le32(int v) => [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255];
List<int> _syncsafe(int v) => [(v >> 21) & 127, (v >> 14) & 127, (v >> 7) & 127, v & 127];
List<int> _box(String type, List<int> body) => [..._be32(body.length + 8), ...latin1.encode(type), ...body];

List<int> _id3Frame(String id, List<int> data) => [...latin1.encode(id), ..._be32(data.length), 0, 0, ...data];

List<int> _utf16(String s) => [0xFF, 0xFE, for (final u in s.codeUnits) ...[u & 255, u >> 8], 0, 0];

const _cover = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('fetchnet_tags'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return f.path;
  }

  group('Reading a song\'s tags', () {
    test('MP3 (ID3v2.3): title, artist, album, UTF-16 lyrics and the front cover', () {
      final frames = [
        ..._id3Frame('TIT2', [3, ...utf8.encode('Café Song')]),
        ..._id3Frame('TPE1', [0, ...latin1.encode('The Band')]),
        ..._id3Frame('TALB', [3, ...utf8.encode('Debut')]),
        ..._id3Frame('USLT', [1, ...latin1.encode('eng'), 0xFF, 0xFE, 0, 0, ..._utf16('[00:01.00]Hello\r\n[00:02.50]World')]),
        // A back cover first: the front one (type 3) must win.
        ..._id3Frame('APIC', [0, ...latin1.encode('image/png'), 0, 4, 0, 9, 9, 9]),
        ..._id3Frame('APIC', [0, ...latin1.encode('image/jpeg'), 0, 3, ...latin1.encode('front'), 0, ..._cover]),
      ];
      final path = write('song.mp3', [...latin1.encode('ID3'), 3, 0, 0, ..._syncsafe(frames.length), ...frames, 0xFF, 0xFB, 0, 0]);
      final tags = AudioTags.readSync(path);
      expect(tags.title, 'Café Song');
      expect(tags.artist, 'The Band');
      expect(tags.album, 'Debut');
      expect(tags.lyrics, '[00:01.00]Hello\n[00:02.50]World');
      expect(tags.cover, _cover);
    });

    test('MP3 whose lyrics FFmpeg 7 left in a TXXX "USLT" field: still found (not as the real tag)', () {
      final frames = [
        ..._id3Frame('TXXX', [0, ...latin1.encode('USLT'), 0, ...utf8.encode('[00:15.82] The club')]),
        ..._id3Frame('TXXX', [0, ...latin1.encode('purl'), 0, ...latin1.encode('https://x')]),
      ];
      final path = write('phone.mp3', [...latin1.encode('ID3'), 3, 0, 0, ..._syncsafe(frames.length), ...frames, 0xFF, 0xFB, 0, 0]);
      final tags = AudioTags.readSync(path);
      expect(tags.lyrics, isNull);
      expect(tags.lyricsElsewhere, '[00:15.82] The club');
      expect(tags.anyLyrics, '[00:15.82] The club');
    });

    test('MP3: FetchNet puts the lyrics in a real USLT frame (keeping the other tags and the audio)', () {
      final frames = [
        ..._id3Frame('TIT2', [3, ...utf8.encode('Song')]),
        ..._id3Frame('TXXX', [0, ...latin1.encode('USLT'), 0, ...utf8.encode('[00:01.00] old')]),
        ..._id3Frame('APIC', [0, ...latin1.encode('image/jpeg'), 0, 3, 0, ..._cover]),
      ];
      const audio = [0xFF, 0xFB, 0x90, 0x00, 1, 2, 3, 4];
      final path = write('fix.mp3', [...latin1.encode('ID3'), 3, 0, 0, ..._syncsafe(frames.length), ...frames, ...audio]);
      expect(Mp3Lyrics.writeSync(path, '[00:01.00] Hello\n[00:02.00] नमस्ते'), isTrue);
      final tags = AudioTags.readSync(path);
      expect(tags.lyrics, '[00:01.00] Hello\n[00:02.00] नमस्ते');
      expect(tags.lyricsElsewhere, isNull);
      expect([tags.title, tags.cover], ['Song', _cover]);
      final bytes = File(path).readAsBytesSync();
      expect(bytes.sublist(bytes.length - audio.length), audio);
      // A song without a tag gets one.
      final bare = write('bare.mp3', audio);
      expect(Mp3Lyrics.writeSync(bare, 'x'), isTrue);
      expect(AudioTags.readSync(bare).lyrics, 'x');
    });

    test('M4A: the iTunes tags inside moov', () {
      List<int> item(String name, List<int> payload, {int type = 1}) =>
          _box(name, _box('data', [..._be32(type), 0, 0, 0, 0, ...payload]));
      final ilst = _box('ilst', [
        ...item('©nam', utf8.encode('Night Drive')),
        ...item('©ART', utf8.encode('Synth Duo')),
        ...item('©alb', utf8.encode('Neon')),
        ...item('©lyr', utf8.encode('[00:03.00]Go')),
        ...item('covr', _cover, type: 13),
      ]);
      final meta = _box('meta', [0, 0, 0, 0, ..._box('hdlr', List.filled(25, 0)), ...ilst]);
      final moov = _box('moov', [..._box('mvhd', List.filled(100, 0)), ..._box('udta', meta)]);
      final path = write('song.m4a', [..._box('ftyp', latin1.encode('M4A isom')), ...moov, ..._box('mdat', [1, 2, 3])]);
      final tags = AudioTags.readSync(path);
      expect(tags.title, 'Night Drive');
      expect(tags.artist, 'Synth Duo');
      expect(tags.album, 'Neon');
      expect(tags.lyrics, '[00:03.00]Go');
      expect(tags.cover, _cover);
    });

    test('FLAC: Vorbis comments and a PICTURE block', () {
      List<int> comment(String s) => [..._le32(utf8.encode(s).length), ...utf8.encode(s)];
      final vorbis = [
        ..._le32(6), ...latin1.encode('vendor'), ..._le32(3),
        ...comment('TITLE=Rain'), ...comment('artist=Cloud'), ...comment('LYRICS=Plain words'),
      ];
      final mime = latin1.encode('image/jpeg');
      final picture = [..._be32(3), ..._be32(mime.length), ...mime, ..._be32(0), ...List.filled(16, 0), ..._be32(_cover.length), ..._cover];
      List<int> block(int type, List<int> body, {bool last = false}) =>
          [(last ? 0x80 : 0) | type, (body.length >> 16) & 255, (body.length >> 8) & 255, body.length & 255, ...body];
      final path = write('song.flac', [
        ...latin1.encode('fLaC'),
        ...block(0, List.filled(34, 0)),
        ...block(4, vorbis),
        ...block(6, picture, last: true),
      ]);
      final tags = AudioTags.readSync(path);
      expect(tags.title, 'Rain');
      expect(tags.artist, 'Cloud');
      expect(tags.album, isNull);
      expect(tags.lyrics, 'Plain words');
      expect(tags.cover, _cover);
    });

    test('a file without tags, or not audio at all: nothing, no crash', () {
      expect(AudioTags.readSync(write('a.wav', latin1.encode('RIFF....WAVEfmt '))).title, isNull);
      expect(AudioTags.readSync(write('b.mp3', [...latin1.encode('ID3'), 3, 0, 0, 0, 0, 0x7F, 0x7F, 1])).title, isNull);
      expect(AudioTags.readSync('${dir.path}/missing.mp3').cover, isNull);
    });
  });

  group('Synced lyrics', () {
    test('lines in time order, repeated stamps, offset and word timing', () {
      final l = Lyrics.parse('[ar:Someone]\n[offset:+500]\n[00:10.00]Second\n[00:05.20][00:20.00]Chorus\n[00:12.345]<00:12.40>Word <00:13.00>by word\n[00:30.00]');
      expect(l.isSynced, isTrue);
      expect([for (final x in l.synced) x.text], ['Chorus', 'Second', 'Word by word', 'Chorus', '']);
      expect(l.synced.first.time, const Duration(milliseconds: 4700));
      expect(l.synced[2].time, const Duration(milliseconds: 11845));
    });

    test('the line playing at a moment', () {
      final l = Lyrics.parse('[00:01.00]A\n[00:03.00]B\n[00:06.00]C');
      expect(l.indexAt(Duration.zero), -1);
      expect(l.indexAt(const Duration(seconds: 1)), 0);
      expect(l.indexAt(const Duration(milliseconds: 5999)), 1);
      expect(l.indexAt(const Duration(minutes: 5)), 2);
    });

    test('text without timestamps is plain lyrics; nothing is empty', () {
      final plain = Lyrics.parse('Just words\nMore words');
      expect(plain.isSynced, isFalse);
      expect(plain.plain, 'Just words\nMore words');
      expect(Lyrics.parse('  ').isEmpty, isTrue);
      expect(Lyrics.parse(null).isEmpty, isTrue);
    });
  });

  group('Colours from the cover', () {
    Uint8List pixels(List<(Color, int)> parts) => Uint8List.fromList([
          for (final (c, n) in parts)
            for (var i = 0; i < n; i++) ...[(c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round(), 255],
        ]);

    test('a mostly blue cover with orange: deep blue background, orange accent', () {
      final p = ArtPalette.fromPixels(pixels([(const Color(0xFF1E3A8A), 1600), (const Color(0xFFF97316), 700)]))!;
      final top = HSLColor.fromColor(p.top), bottom = HSLColor.fromColor(p.bottom), accent = HSLColor.fromColor(p.accent);
      expect(top.hue, inInclusiveRange(215, 235));
      expect(top.lightness, lessThanOrEqualTo(0.265));
      expect(bottom.lightness, lessThan(top.lightness));
      expect(accent.hue, inInclusiveRange(15, 35));
      expect(accent.lightness, closeTo(0.66, 0.01));
    });

    test('white text stays readable on any cover (even an all-white one)', () {
      for (final c in const [Colors.white, Colors.yellow, Colors.black, Color(0xFF808080)]) {
        final p = ArtPalette.fromPixels(pixels([(c, 500)]))!;
        expect(p.top.computeLuminance(), lessThan(0.1), reason: '$c');
      }
    });

    test('a grey cover gets FetchNet\'s violet', () {
      final p = ArtPalette.fromPixels(pixels([(const Color(0xFF777777), 500)]))!;
      expect(HSLColor.fromColor(p.accent).hue, closeTo(265, 2));
    });

    test('a see-through picture has no colours', () {
      expect(ArtPalette.fromPixels(Uint8List(400)), isNull);
    });
  });
}
