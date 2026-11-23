import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/device_environment.dart';
import '../../core/platform/native_bridge.dart';
import '../../models/download_models.dart';
import '../../models/media_info.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../home/media_preview.dart';
import '../player/audio_player_screen.dart';
import '../player/video_player_screen.dart';
import '../../ui_kit/kit.dart';
import '../youtube/youtube_download_sheet.dart' show youTubeVideoId;

/// Tapping a saved file: songs and videos play in FetchNet's players, pictures open
/// in FetchNet's viewer (a post's pictures together, to swipe through);
/// anything else goes to [openWithApp].
Future<void> openDownloadedFile(BuildContext context, HistoryEntry entry) async {
  final path = entry.filePath;
  if (path == null || !File(path).existsSync()) {
    showSnack(context, 'This file is no longer on your device.', kind: ToastKind.error);
    return;
  }
  // An audio download saved as .webm / .mp4 is still a song.
  if (isAudioPath(path) || (entry.kind == MediaKind.audio && isVideoPath(path))) {
    // No picture inside the file: the video's thumbnail is the cover.
    final id = youTubeVideoId(entry.url);
    final art = entry.thumbnail ?? (id == null ? null : 'https://i.ytimg.com/vi/$id/hqdefault.jpg');
    await openAudioPlayer(context, path: path, title: entry.title, artUrl: art);
    return;
  }
  if (isVideoPath(path)) {
    await openVideoPlayer(context, path: path, title: entry.title);
    return;
  }
  final pictures = [
    for (final f in entry.allFiles)
      if (isPicturePath(f) && File(f).existsSync()) f,
  ];
  if (pictures.isNotEmpty) {
    await showMediaPreview(
      context,
      items: [
        for (final f in pictures) PreviewItem(url: '', filePath: f, caption: p.basename(f), icon: Icons.photo_rounded),
      ],
    );
    return;
  }
  await openWithApp(context, path);
}

/// "Open with": another app on the device, for any file (Android's app
/// chooser, Windows' "How do you want to open this file?").
Future<void> openWithApp(BuildContext context, String path) async {
  final ok = await NativeBridge.openWith(path);
  if (!ok && context.mounted) showSnack(context, 'No app found to open this file.', kind: ToastKind.error);
}

/// The saved picture (a path, when [fileThere]) and the download's
/// thumbnail (a link; YouTube's for its videos), for a [MediaThumb].
(String?, String?) entryPicture(HistoryEntry entry, {required bool fileThere}) {
  final path = entry.filePath;
  final id = youTubeVideoId(entry.url);
  return (
    fileThere && path != null && isPicturePath(path) ? path : null,
    entry.thumbnail ?? (id == null ? null : 'https://i.ytimg.com/vi/$id/mqdefault.jpg'),
  );
}

bool isPicturePath(String path) => const {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif'}
    .contains(p.extension(path).toLowerCase());

bool isAudioPath(String path) =>
    const {'.mp3', '.m4a', '.opus', '.ogg', '.oga', '.flac', '.wav', '.aac', '.weba', '.alac', '.wma', '.mka', '.aiff'}
        .contains(p.extension(path).toLowerCase());

bool isVideoPath(String path) => const {'.mp4', '.m4v', '.webm', '.mkv', '.mov', '.avi', '.flv', '.3gp', '.ts', '.wmv'}
    .contains(p.extension(path).toLowerCase());

Future<void> deleteDownloadedFile(BuildContext context, HistoryEntry entry) async {
  final services = AppScope.of(context);
  final ok = await confirmDialog(
    context,
    title: 'Delete file?',
    message: '"${p.basename(entry.filePath!)}" will be permanently deleted from your device.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (ok) await services.downloads.deleteFile(entry);
}

/// Android: the share sheet. Desktop: the file goes on the clipboard, ready
/// to paste into a chat, an email or a folder.
Future<void> shareDownloadedFile(BuildContext context, HistoryEntry entry) =>
    shareFilePath(context, entry.filePath!, title: entry.title);

/// Shares a saved file: Android's share sheet; on a computer, the file goes
/// on the clipboard.
Future<void> shareFilePath(BuildContext context, String path, {String? title}) async {
  if (NativeBridge.canShareNatively) {
    final error = await NativeBridge.shareFile(path, title: title);
    if (error != null && context.mounted) showSnack(context, 'Couldn\'t share this file. $error', kind: ToastKind.error);
    return;
  }
  final copied = await NativeBridge.copyFileToClipboard(path);
  if (!context.mounted) return;
  if (copied) {
    showSnack(context, 'File copied. Paste it into any app or folder.', kind: ToastKind.success);
  } else {
    await Clipboard.setData(ClipboardData(text: path));
    if (context.mounted) showSnack(context, 'Copied the file\'s location');
  }
}

/// Shares a download's link (Android), or copies it.
Future<void> shareEntryLink(BuildContext context, HistoryEntry entry) async {
  if (NativeBridge.canShareNatively && await NativeBridge.shareText(entry.url, subject: entry.title)) return;
  await Clipboard.setData(ClipboardData(text: entry.url));
  if (context.mounted) showSnack(context, 'Link copied', kind: ToastKind.success);
}

/// The ⋮ menu of a saved file: preview, quick actions and more options.
Future<void> showFileActions(BuildContext context, HistoryEntry entry, {required Widget thumbnail}) {
  return showKitSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheet) => _FileActionsSheet(entry: entry, thumbnail: thumbnail, outer: context),
  );
}

class _FileActionsSheet extends StatelessWidget {
  const _FileActionsSheet({required this.entry, required this.thumbnail, required this.outer});

  final HistoryEntry entry;
  final Widget thumbnail;

  /// The Downloads page: actions run there once the sheet has closed.
  final BuildContext outer;

  void _run(BuildContext sheet, Future<void> Function(BuildContext) action) {
    Navigator.of(sheet).pop();
    action(outer);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final services = AppScope.of(context);
    final android = NativeBridge.canShareNatively;
    final desktop = DeviceEnvironment.isDesktop;
    final kindLabel = switch (entry.kind) {
      MediaKind.video => 'Video',
      MediaKind.audio => 'Audio',
      MediaKind.thumbnail => 'Thumbnail',
      MediaKind.image => 'Image',
      MediaKind.post => entry.files.length > 1 ? 'Post · ${entry.files.length} files' : 'Post',
      MediaKind.subtitle => 'Subtitles',
    };
    final link = Uri.tryParse(entry.url);
    final hasLink = link != null && link.hasScheme && link.host.isNotEmpty;

    final quick = <SheetQuickAction>[
      // Another app, for every kind of file (a tap on the file opens it in
      // FetchNet).
      SheetQuickAction(
        icon: Icons.open_in_new_rounded,
        label: 'Open with',
        primary: true,
        onTap: () => _run(context, (c) => openWithApp(c, entry.filePath!)),
      ),
      SheetQuickAction(
        icon: android ? Icons.share_rounded : Icons.copy_rounded,
        label: android ? 'Share' : 'Copy file',
        onTap: () => _run(context, (c) => shareDownloadedFile(c, entry)),
      ),
      if (desktop)
        SheetQuickAction(
          icon: Icons.folder_open_rounded,
          label: 'Show in folder',
          onTap: () => _run(context, (_) => NativeBridge.revealInFolder(entry.filePath!)),
        )
      else if (hasLink)
        SheetQuickAction(
          icon: Icons.link_rounded,
          label: 'Share link',
          onTap: () => _run(context, (c) => shareEntryLink(c, entry)),
        ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ───── Preview ─────
          Row(
            children: [
              thumbnail,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.basename(entry.filePath!),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, height: 1.25),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        SheetChip(text: kindLabel, highlighted: true),
                        if (entry.quality.isNotEmpty) SheetChip(text: entry.quality),
                        SheetChip(text: formatBytes(entry.sizeBytes)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              'Saved ${formatDate(entry.completedAt ?? entry.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 18),

          // ───── Quick actions ─────
          Row(
            children: [
              for (var i = 0; i < quick.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: quick[i]),
              ],
            ],
          ),
          const SizedBox(height: 14),

          // ───── More ─────
          if (hasLink)
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    SheetMenuRow(
                      icon: Icons.content_copy_rounded,
                      title: 'Copy link',
                      subtitle: link.host,
                      onTap: () => _run(context, (c) async {
                        await Clipboard.setData(ClipboardData(text: entry.url));
                        if (c.mounted) showSnack(c, 'Link copied', kind: ToastKind.success);
                      }),
                    ),
                    _divider(scheme),
                    SheetMenuRow(
                      icon: Icons.open_in_new_rounded,
                      title: 'Open source page',
                      subtitle: link.host,
                      onTap: () => _run(context, (_) => launchUrl(link, mode: LaunchMode.externalApplication)),
                    ),
                    _divider(scheme),
                    SheetMenuRow(
                      icon: Icons.bolt_rounded,
                      title: 'Fetch again',
                      subtitle: 'Pick another quality or format',
                      onTap: () => _run(context, (_) async {
                        services.incomingLink.value = entry.url;
                        services.tabRequest.value = 0;
                      }),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 14),
          DialogButton(
            label: 'Delete file',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            expand: true,
            onPressed: () => _run(context, (c) => deleteDownloadedFile(c, entry)),
          ),
        ],
      ),
    );
  }

  static Widget _divider(ColorScheme scheme) =>
      Divider(height: 1, indent: 56, endIndent: 16, color: scheme.outlineVariant.withValues(alpha: 0.4));
}

/// A big button in a row of quick actions (the first one on the gradient).
class SheetQuickAction extends StatelessWidget {
  const SheetQuickAction({super.key, required this.icon, required this.label, required this.onTap, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: primary ? null : scheme.secondaryContainer.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: primary ? const BoxDecoration(gradient: AppColors.brandGradient) : null,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: primary ? Colors.white : scheme.onSecondaryContainer, size: 26),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: primary ? Colors.white : scheme.onSecondaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of an action list: an icon tile, a title, a detail and a chevron.
class SheetMenuRow extends StatelessWidget {
  const SheetMenuRow({super.key, required this.icon, required this.title, required this.onTap, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(11)),
        child: Icon(icon, size: 19, color: scheme.onPrimaryContainer),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
    );
  }
}

/// A small label: a file's kind (on the gradient), quality or size.
class SheetChip extends StatelessWidget {
  const SheetChip({super.key, required this.text, this.highlighted = false});

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        gradient: highlighted ? AppColors.brandGradient : null,
        color: highlighted ? null : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w800,
          color: highlighted ? Colors.white : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
