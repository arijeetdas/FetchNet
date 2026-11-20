import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/media_info.dart';
import '../../widgets/app_dialog.dart';

/// What Browser Mode downloads: video, audio, pictures and subtitles (and
/// streams, which go to yt-dlp). Everything else is refused.
enum BrowserFileType {
  video,
  audio,
  image,
  subtitle,

  /// HLS / DASH playlists: read by yt-dlp.
  stream;

  MediaKind get kind => switch (this) {
        video || stream => MediaKind.video,
        audio => MediaKind.audio,
        image => MediaKind.image,
        subtitle => MediaKind.subtitle,
      };

  static const videoExt = {'mp4', 'm4v', 'webm', 'mov', 'mkv', 'flv', '3gp', 'avi', 'ogv', 'wmv', 'mpg', 'mpeg', 'ts'};
  static const audioExt = {'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wav', 'weba', 'wma', 'mka', 'amr'};
  static const imageExt = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'avif', 'bmp', 'heic', 'heif', 'jxl', 'tif', 'tiff'};
  static const subtitleExt = {'srt', 'vtt', 'ass', 'ssa', 'sub', 'ttml', 'dfxp', 'sbv'};
  static const streamExt = {'m3u8', 'm3u', 'mpd'};

  /// From a file name or URL's extension.
  static BrowserFileType? fromExtension(String? ext) {
    final e = ext?.toLowerCase().replaceFirst('.', '');
    if (e == null || e.isEmpty) return null;
    if (videoExt.contains(e)) return video;
    if (audioExt.contains(e)) return audio;
    if (imageExt.contains(e)) return image;
    if (subtitleExt.contains(e)) return subtitle;
    if (streamExt.contains(e)) return stream;
    return null;
  }

  /// From a Content-Type; `null` when it doesn't say (octet-stream).
  static BrowserFileType? fromMime(String? mime) {
    final m = mime?.toLowerCase().split(';').first.trim();
    if (m == null || m.isEmpty) return null;
    if (m.contains('mpegurl') || m == 'application/dash+xml') return stream;
    if (m.startsWith('video/')) return video;
    if (m.startsWith('audio/')) return audio;
    if (m.startsWith('image/') && m != 'image/svg+xml' && m != 'image/x-icon' && m != 'image/vnd.microsoft.icon') {
      return image;
    }
    if (m == 'text/vtt' || m == 'application/x-subrip' || m == 'text/x-ssa' || m == 'text/x-ass' ||
        m == 'application/ttml+xml') {
      return subtitle;
    }
    return null;
  }

  /// What a download is, from its Content-Type, its file name and its URL
  /// (in that order); `null` when it's none of the supported kinds.
  static BrowserFileType? detect({required String url, String? mime, String? fileName}) {
    final byMime = fromMime(mime);
    if (byMime != null) return byMime;
    return fromExtension(extensionOf(fileName)) ?? fromExtension(extensionOf(url));
  }

  /// `mp4` from `video.mp4` or `https://x/y/video.mp4?a=b`.
  static String? extensionOf(String? nameOrUrl) {
    if (nameOrUrl == null || nameOrUrl.isEmpty) return null;
    var last = nameOrUrl;
    final uri = Uri.tryParse(nameOrUrl);
    if (uri != null && uri.hasScheme) last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final dot = last.lastIndexOf('.');
    if (dot < 0 || dot == last.length - 1) return null;
    final ext = last.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : null;
  }

  /// The file name in a Content-Disposition header, if any.
  static String? fileNameFromDisposition(String? disposition) {
    if (disposition == null) return null;
    final star = RegExp(r'''filename\*\s*=\s*[^']*'[^']*'([^;]+)''', caseSensitive: false).firstMatch(disposition);
    if (star != null) {
      try {
        return Uri.decodeComponent(star.group(1)!.trim());
      } catch (_) {}
    }
    final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false).firstMatch(disposition);
    return plain?.group(1)?.trim();
  }
}

/// "File not supported": FetchNet only takes video, audio, pictures and
/// subtitles. The link can be opened in the device's default browser.
Future<void> showUnsupportedFileDialog(BuildContext context, {required String url, String? fileName}) {
  final name = (fileName != null && fileName.isNotEmpty)
      ? fileName
      : (Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'This file');
  return showFetchNetDialog<void>(
    context: context,
    barrierDismissible: true,
    lockBack: false,
    builder: (context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        icon: Icon(Icons.block_rounded, color: scheme.error, size: 32),
        title: const Text('File not supported'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'FetchNet downloads videos, audio, pictures and subtitles. "$name" is something else, so it '
                'wasn\'t opened or downloaded.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 10),
              Text(
                'You can open the link in your browser instead.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          DialogButton(label: 'Close', icon: Icons.close_rounded, onPressed: () => Navigator.pop(context)),
          DialogButton(
            label: 'Open in browser',
            icon: Icons.open_in_new_rounded,
            primary: true,
            onPressed: () {
              Navigator.pop(context);
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            },
          ),
        ],
      );
    },
  );
}
