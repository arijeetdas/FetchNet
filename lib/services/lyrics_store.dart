import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// FetchNet's own copy of each downloaded song's lyrics, in its private
/// folder: the music player shows them even when the song's file or the
/// `.lrc` next to it couldn't take them (a format without a lyrics tag, a
/// folder that refuses other apps' files).
class LyricsStore {
  LyricsStore._();

  static Directory? _dir;

  static Future<Directory> _folder() async {
    final dir = _dir ??= Directory(p.join((await getApplicationSupportDirectory()).path, 'lyrics'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _name(String songPath) => '${md5.convert(utf8.encode(p.normalize(songPath).toLowerCase()))}.lrc';

  /// Keeps [lyrics] for the song at [songPath].
  static Future<void> save(String songPath, String lyrics) async {
    try {
      await File(p.join((await _folder()).path, _name(songPath))).writeAsString(lyrics, flush: true);
    } catch (_) {}
  }

  /// The lyrics kept for [songPath], or `null`.
  static Future<String?> load(String songPath) async {
    try {
      final f = File(p.join((await _folder()).path, _name(songPath)));
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// Forgets the lyrics of a deleted song.
  static Future<void> remove(String songPath) async {
    try {
      final f = File(p.join((await _folder()).path, _name(songPath)));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
