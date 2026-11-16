import 'dart:convert';

import 'media_info.dart';

enum GalleryItemKind { image, video, audio, other }

/// One file of a post, from gallery-dl's `-j` output.
class GalleryItem {
  const GalleryItem({
    required this.index,
    required this.url,
    required this.kind,
    required this.extension,
    this.filename,
    this.width,
    this.height,
    this.duration,
    this.sizeBytes,
    this.preview,
  });

  /// 1-based position among the post's files: what `--range` selects.
  final int index;
  final String url;
  final GalleryItemKind kind;

  /// `jpg`, `mp4`, ... (lowercase, no dot).
  final String extension;
  final String? filename;
  final int? width;
  final int? height;

  /// Seconds.
  final double? duration;
  final int? sizeBytes;

  /// An image to show for the file: the image itself, or a video's poster.
  final String? preview;

  /// gallery-dl hands this one to yt-dlp (`ytdl:` URLs).
  bool get viaYtDlp => url.startsWith('ytdl:');

  static const imageExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'bmp', 'heic', 'heif', 'jxl', 'tif', 'tiff', 'jfif'};
  static const videoExt = {'mp4', 'm4v', 'webm', 'mov', 'mkv', 'avi', 'flv', 'm3u8', 'ts', 'wmv', '3gp'};
  static const audioExt = {'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wav', 'weba', 'wma'};

  static GalleryItemKind kindOf(String ext, {String? url, String? type}) {
    if (url != null && url.startsWith('ytdl:')) return GalleryItemKind.video;
    final t = type?.toLowerCase();
    if (t == 'video' || t == 'animated_gif') return GalleryItemKind.video;
    if (t == 'audio') return GalleryItemKind.audio;
    if (imageExt.contains(ext)) return GalleryItemKind.image;
    if (videoExt.contains(ext)) return GalleryItemKind.video;
    if (audioExt.contains(ext)) return GalleryItemKind.audio;
    if (t == 'photo' || t == 'image') return GalleryItemKind.image;
    return GalleryItemKind.other;
  }
}

/// A child of a profile / board / search URL: one post to open.
class GalleryChild {
  const GalleryChild({required this.url, required this.title});

  final String url;
  final String title;
}

/// What gallery-dl found at a link: the files of one post (or gallery), or
/// the posts of a profile.
class GalleryPost {
  GalleryPost({
    required this.url,
    required this.title,
    required this.items,
    this.children = const [],
    this.author,
    this.site,
    this.description,
    this.requestArgs = const [],
    this.truncated = false,
  });

  /// The link gallery-dl was given (downloads use it again).
  final String url;
  final String title;
  final String? author;

  /// gallery-dl's category, e.g. `instagram`.
  final String? site;
  final String? description;
  final List<GalleryItem> items;
  final List<GalleryChild> children;

  /// yt-dlp style arguments (cookies, user agent) that reached this post.
  final List<String> requestArgs;

  /// The lookup stopped at its file limit: there may be more files.
  final bool truncated;

  bool get isEmpty => items.isEmpty && children.isEmpty;

  int count(GalleryItemKind kind) => items.where((i) => i.kind == kind).length;

  GalleryPost withRequestArgs(List<String> args) => GalleryPost(
        url: url,
        title: title,
        items: items,
        children: children,
        author: author,
        site: site,
        description: description,
        requestArgs: args,
        truncated: truncated,
      );

  /// `1-3,5,9-12` for [indices] (1-based, any order).
  static String rangeOf(Iterable<int> indices) {
    final sorted = indices.toSet().toList()..sort();
    final parts = <String>[];
    for (var i = 0; i < sorted.length; i++) {
      final start = sorted[i];
      var end = start;
      while (i + 1 < sorted.length && sorted[i + 1] == end + 1) {
        end = sorted[++i];
      }
      parts.add(start == end ? '$start' : '$start-$end');
    }
    return parts.join(',');
  }

  /// Error reported inside gallery-dl's JSON (`[-1, {"error": ..., "message": ...}]`).
  static String? errorIn(String stdout) {
    final data = _decode(stdout);
    if (data == null) return null;
    for (final m in data) {
      if (m is List && m.isNotEmpty && m[0] == -1 && m.length > 1 && m[1] is Map) {
        final e = m[1] as Map;
        return [e['error'], e['message']].where((x) => x != null && '$x'.isNotEmpty).join(': ');
      }
    }
    return null;
  }

  static List<dynamic>? _decode(String stdout) {
    final start = stdout.indexOf('[');
    final end = stdout.lastIndexOf(']');
    if (start < 0 || end <= start) return null;
    try {
      final data = jsonDecode(stdout.substring(start, end + 1));
      return data is List ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// Parses `gallery-dl -j` output: a list of messages, `[2, meta]` for a
  /// directory, `[3, url, meta]` for a file and `[6, url, meta]` for a child
  /// extractor (a post of a profile). [limit] is the lookup's file limit.
  static GalleryPost parse(String stdout, {required String sourceUrl, List<String> requestArgs = const [], int? limit}) {
    final data = _decode(stdout);
    if (data == null) throw const FormatException('gallery-dl returned no data.');
    Map<String, dynamic>? directory;
    final files = <(String, Map<String, dynamic>)>[];
    final children = <GalleryChild>[];
    for (final m in data) {
      if (m is! List || m.isEmpty) continue;
      switch (m[0]) {
        case 2 when m.length > 1 && m[1] is Map:
          directory ??= (m[1] as Map).cast<String, dynamic>();
        case 3 when m.length > 2 && m[1] is String:
          files.add((m[1] as String, m[2] is Map ? (m[2] as Map).cast<String, dynamic>() : const {}));
        case 6 when m.length > 1 && m[1] is String:
          final meta = m.length > 2 && m[2] is Map ? (m[2] as Map).cast<String, dynamic>() : const <String, dynamic>{};
          children.add(GalleryChild(url: m[1] as String, title: _firstText(meta, _titleKeys) ?? m[1] as String));
      }
    }

    final items = <GalleryItem>[];
    for (var i = 0; i < files.length; i++) {
      final (url, meta) = files[i];
      final ext = ('${meta['extension'] ?? ''}'.isNotEmpty ? '${meta['extension']}' : _extOf(url)).toLowerCase();
      final kind = GalleryItem.kindOf(ext, url: url, type: meta['type']?.toString());
      final previewKey = _firstUrl(meta, const ['thumbnail', 'display_url', 'preview', 'poster', 'cover', 'thumb', 'thumbnail_url']);
      items.add(GalleryItem(
        index: i + 1,
        url: url,
        kind: kind,
        extension: ext.isEmpty ? (kind == GalleryItemKind.video ? 'mp4' : 'jpg') : ext,
        filename: meta['filename']?.toString(),
        width: _int(meta['width'] ?? meta['image_width']),
        height: _int(meta['height'] ?? meta['image_height']),
        duration: (meta['duration'] is num) ? (meta['duration'] as num).toDouble() : null,
        sizeBytes: _int(meta['filesize'] ?? meta['size'] ?? meta['file_size']),
        preview: kind == GalleryItemKind.image && url.startsWith('http') ? url : previewKey,
      ));
    }

    final first = files.isEmpty ? null : files.first.$2;
    final meta = {...?first, ...?directory};
    final description = _firstText(meta, const ['description', 'content', 'caption', 'text', 'body', 'selftext']);
    var title = _firstText(meta, _titleKeys) ?? description;
    if (title != null) title = title.split('\n').first.trim();
    if (title != null && title.length > 140) title = '${title.substring(0, 140).trimRight()}…';
    return GalleryPost(
      url: sourceUrl,
      title: (title == null || title.isEmpty) ? (meta['category']?.toString() ?? 'Post') : title,
      author: _author(meta),
      site: meta['category']?.toString(),
      description: description,
      items: items,
      children: children,
      requestArgs: requestArgs,
      truncated: limit != null && items.length >= limit,
    );
  }

  static const _titleKeys = ['title', 'post_title', 'gallery_title', 'name', 'album'];

  static String? _firstText(Map<String, dynamic> meta, List<String> keys) {
    for (final k in keys) {
      final v = meta[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  static String? _firstUrl(Map<String, dynamic> meta, List<String> keys) {
    for (final k in keys) {
      final v = meta[k];
      if (v is String && v.startsWith('http')) return v;
      if (v is Map && v['url'] is String && (v['url'] as String).startsWith('http')) return v['url'] as String;
    }
    return null;
  }

  static String? _author(Map<String, dynamic> meta) {
    for (final k in const ['author', 'user', 'owner', 'artist', 'uploader', 'blog', 'channel']) {
      final v = meta[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (v is Map) {
        for (final n in const ['nick', 'name', 'username', 'screen_name', 'title']) {
          final x = v[n];
          if (x is String && x.trim().isNotEmpty) return x.trim();
        }
      }
    }
    for (final k in const ['username', 'fullname', 'screen_name', 'nick']) {
      final v = meta[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  static String _extOf(String url) {
    final uri = Uri.tryParse(url.replaceFirst('ytdl:', ''));
    final last = uri == null || uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final dot = last.lastIndexOf('.');
    if (dot >= 0 && dot < last.length - 1) return last.substring(dot + 1);
    return uri?.queryParameters['format'] ?? '';
  }

  /// A MediaInfo for the shared download / rename code.
  MediaInfo toMediaInfo() => MediaInfo(
        url: url,
        title: title,
        raw: const {},
        thumbnail: items.map((i) => i.preview).whereType<String>().firstOrNull,
        uploader: author,
        extractor: site,
        requestArgs: requestArgs,
      );
}
