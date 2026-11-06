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

Future<void> openDownloadedFile(BuildContext context, HistoryEntry entry) async {
  final ok = await NativeBridge.openFile(entry.filePath!);
  if (!ok && context.mounted) showSnack(context, 'No app found to open this file.', kind: ToastKind.error);
}

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
Future<void> shareDownloadedFile(BuildContext context, HistoryEntry entry) async {
  final path = entry.filePath!;
  if (NativeBridge.canShareNatively) {
    final error = await NativeBridge.shareFile(path, title: entry.title);
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

Future<void> _shareLink(BuildContext context, HistoryEntry entry) async {
  if (NativeBridge.canShareNatively && await NativeBridge.shareText(entry.url, subject: entry.title)) return;
  await Clipboard.setData(ClipboardData(text: entry.url));
  if (context.mounted) showSnack(context, 'Link copied', kind: ToastKind.success);
}

/// The ⋮ menu of a saved file: preview, quick actions and more options.
Future<void> showFileActions(BuildContext context, HistoryEntry entry, {required Widget thumbnail}) {
  return showModalBottomSheet<void>(
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
    };
    final link = Uri.tryParse(entry.url);
    final hasLink = link != null && link.hasScheme && link.host.isNotEmpty;

    final quick = <_QuickAction>[
      _QuickAction(
        icon: Icons.play_arrow_rounded,
        label: 'Open',
        primary: true,
        onTap: () => _run(context, (c) => openDownloadedFile(c, entry)),
      ),
      _QuickAction(
        icon: android ? Icons.share_rounded : Icons.copy_rounded,
        label: android ? 'Share' : 'Copy file',
        onTap: () => _run(context, (c) => shareDownloadedFile(c, entry)),
      ),
      if (desktop)
        _QuickAction(
          icon: Icons.folder_open_rounded,
          label: 'Show in folder',
          onTap: () => _run(context, (_) => NativeBridge.revealInFolder(entry.filePath!)),
        )
      else if (hasLink)
        _QuickAction(
          icon: Icons.link_rounded,
          label: 'Share link',
          onTap: () => _run(context, (c) => _shareLink(c, entry)),
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
                        _Chip(text: kindLabel, highlighted: true),
                        if (entry.quality.isNotEmpty) _Chip(text: entry.quality),
                        _Chip(text: formatBytes(entry.sizeBytes)),
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
                    _MenuRow(
                      icon: Icons.content_copy_rounded,
                      title: 'Copy link',
                      subtitle: link.host,
                      onTap: () => _run(context, (c) async {
                        await Clipboard.setData(ClipboardData(text: entry.url));
                        if (c.mounted) showSnack(c, 'Link copied', kind: ToastKind.success);
                      }),
                    ),
                    _divider(scheme),
                    _MenuRow(
                      icon: Icons.open_in_new_rounded,
                      title: 'Open source page',
                      subtitle: link.host,
                      onTap: () => _run(context, (_) => launchUrl(link, mode: LaunchMode.externalApplication)),
                    ),
                    _divider(scheme),
                    _MenuRow(
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

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap, this.primary = false});

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

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.title, required this.onTap, this.subtitle});

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

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.highlighted = false});

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
