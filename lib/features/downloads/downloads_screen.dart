import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/device_environment.dart';
import '../../core/platform/native_bridge.dart';
import '../../models/download_models.dart';
import '../../models/media_info.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../shell/home_shell.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.downloads, services.history, services.storage]),
      builder: (context, _) {
        final tasks = services.downloads.tasks;
        final files = services.downloads.completedFiles;
        final dir = services.storage.downloadDir;
        return PageFrame(
          title: 'Downloads',
          subtitle: dir == null ? null : _friendlyDir(dir),
          actions: [
            if (DeviceEnvironment.isDesktop && dir != null)
              IconButton.filledTonal(
                tooltip: 'Open folder',
                onPressed: () => NativeBridge.openFolder(dir),
                icon: const Icon(Icons.folder_open_rounded),
              ),
          ],
          slivers: [
            if (tasks.isEmpty && files.isEmpty)
              const SliverToBoxAdapter(child: _EmptyState()),
            if (tasks.isNotEmpty) ...[
              _SectionHeader(title: 'In progress', count: tasks.where((t) => t.isActive).length),
              SliverList.separated(
                itemCount: tasks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _TaskCard(task: tasks[i]),
              ),
            ],
            if (files.isNotEmpty) ...[
              _SectionHeader(title: 'Saved', count: files.length),
              SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 560,
                  mainAxisExtent: 92,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _FileCard(entry: files[i]),
                  childCount: files.length,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  static String _friendlyDir(String dir) {
    final i = dir.indexOf('/Download/');
    if (DeviceEnvironment.isAndroid && i >= 0) return 'Internal storage${dir.substring(i)}';
    return dir;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
        child: Row(
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(width: 8),
            if (count > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url, required this.kind, this.size = 64});

  final String? url;
  final MediaKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      decoration: const BoxDecoration(gradient: AppColors.brandGradient),
      child: Icon(kind == MediaKind.audio ? Icons.music_note_rounded : Icons.movie_rounded, color: Colors.white),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: size * 16 / 11,
        height: size,
        child: url == null
            ? fallback
            : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = task.status == DownloadStatus.failed;

    final stats = <String>[
      if (task.status == DownloadStatus.queued) 'Waiting in queue',
      if (task.stage != null && task.status != DownloadStatus.queued) task.stage!,
      if (task.status == DownloadStatus.downloading && task.totalBytes != null)
        '${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}',
      if (task.status == DownloadStatus.downloading) formatSpeed(task.speed),
      if (task.status == DownloadStatus.downloading) formatEta(task.eta),
    ].where((s) => s.isNotEmpty).join('  ·  ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Thumb(url: task.thumbnail, kind: task.option.kind, size: 56),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${task.fileBaseName}.${task.option.extension}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [task.option.label, if (task.option.detail != null) task.option.detail!].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (failed) ...[
                  IconButton(
                    tooltip: 'Retry',
                    onPressed: () => services.downloads.retry(task),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: () => services.downloads.dismiss(task),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ] else
                  IconButton(
                    tooltip: 'Cancel',
                    onPressed: task.stage == 'Cancelling…' ? null : () => services.downloads.cancel(task),
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (failed)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  task.errorHint ?? task.error ?? 'The download failed.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
                ),
              )
            else ...[
              GradientProgressBar(
                value: task.status == DownloadStatus.queued || task.status == DownloadStatus.starting
                    ? null
                    : task.progress,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      stats,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  if (task.progress != null && task.status == DownloadStatus.downloading)
                    Text(
                      '${(task.progress! * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({required this.entry});

  final HistoryEntry entry;

  Future<void> _open(BuildContext context) async {
    final ok = await NativeBridge.openFile(entry.filePath!);
    if (!ok && context.mounted) showSnack(context, 'No app found to open this file.', kind: ToastKind.error);
  }

  Future<void> _delete(BuildContext context) async {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _Thumb(url: entry.thumbnail, kind: entry.kind, size: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.basename(entry.filePath!),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [formatBytes(entry.sizeBytes), formatDate(entry.completedAt ?? entry.createdAt)].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) {
                  switch (v) {
                    case 'open':
                      _open(context);
                    case 'reveal':
                      NativeBridge.revealInFolder(entry.filePath!);
                    case 'delete':
                      _delete(context);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.play_arrow_rounded), title: Text('Open'))),
                  if (DeviceEnvironment.isDesktop)
                    const PopupMenuItem(
                      value: 'reveal',
                      child: ListTile(leading: Icon(Icons.folder_open_rounded), title: Text('Show in folder')),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(leading: Icon(Icons.delete_outline_rounded), title: Text('Delete file')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, shape: BoxShape.circle),
            child: Icon(Icons.download_rounded, size: 40, color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 18),
          Text('Nothing here yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Downloads in progress and files saved in the FetchNet folder appear here.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
