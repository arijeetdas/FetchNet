import 'dart:io';

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
import '../../widgets/motion/page_motions.dart';
import '../../widgets/page_parts.dart';
import '../shell/home_shell.dart';
import 'file_actions_sheet.dart';

/// Which saved files are shown.
enum _Kind {
  all('All', Icons.folder_rounded),
  videos('Videos', Icons.movie_rounded),
  music('Music', Icons.music_note_rounded),
  pictures('Pictures', Icons.image_rounded);

  const _Kind(this.label, this.icon);

  final String label;
  final IconData icon;

  /// What a saved file is, by its extension first (a song saved as .webm
  /// is still music), then by what was downloaded.
  static _Kind of(HistoryEntry e) {
    final path = e.filePath ?? '';
    if (e.kind == MediaKind.audio || isAudioPath(path)) return _Kind.music;
    if (isPicturePath(path)) return _Kind.pictures;
    if (isVideoPath(path)) return _Kind.videos;
    return switch (e.kind) {
      MediaKind.image || MediaKind.thumbnail || MediaKind.post => _Kind.pictures,
      _ => _Kind.videos,
    };
  }

  bool matches(HistoryEntry e) => this == _Kind.all || of(e) == this;
}

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  _Kind _kind = _Kind.all;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.downloads, services.history, services.storage]),
      builder: (context, _) {
        final downloads = services.downloads;
        final tasks = downloads.tasks;
        final allFiles = downloads.completedFiles;
        final files = allFiles.where(_kind.matches).toList();
        final dir = services.storage.downloadDir;
        final wide = Breakpoints.isWide(context);
        final textGrowth = MediaQuery.textScalerOf(context).scale(14) - 14;
        return PageFrame(
          title: 'Downloads',
          maxWidth: wide ? 1680 : 980,
          subtitle: dir == null ? null : services.storage.displayPath(),
          leading: const PageGlyph(PageGlyphKind.downloads),
          actions: [
            if (DeviceEnvironment.isDesktop && dir != null)
              PillButton(label: 'Open folder', icon: Icons.folder_open_rounded, onPressed: () => NativeBridge.openFolder(dir)),
          ],
          slivers: [
            // First, like History and Settings: downloads starting and
            // finishing below it never push it around.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: PageHero(
                  motion: (size) => DownloadsMotion(size: size),
                  tagline: 'What\'s downloading now and everything you\'ve saved, ready to play or share.',
                ),
              ),
            ),

            // ───── In progress ─────
            if (tasks.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: GroupLabel(
                  label: 'In progress',
                  count: tasks.length,
                  trailing: [
                    if (downloads.hasPaused)
                      PillButton(label: 'Resume all', icon: Icons.play_arrow_rounded, onPressed: downloads.resumeAll),
                    if (downloads.hasPausable)
                      PillButton(label: 'Pause all', icon: Icons.pause_rounded, onPressed: downloads.pauseAll),
                  ],
                ),
              ),
              // Large screens: two or three across (each as tall as it needs).
              SliverToBoxAdapter(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final cols = wide ? (c.maxWidth / 560).ceil().clamp(1, 3) : 1;
                    final width = (c.maxWidth - (cols - 1) * 10) / cols;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [for (final t in tasks) SizedBox(width: width, child: _TaskCard(task: t))],
                    );
                  },
                ),
              ),
            ],

            // ───── Saved ─────
            if (allFiles.isNotEmpty) ...[
              SliverToBoxAdapter(child: GroupLabel(label: 'Saved', count: allFiles.length)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: Row(
                        children: [
                          for (final (i, k) in _Kind.values.indexed) ...[
                            if (i > 0) const SizedBox(width: 8),
                            Expanded(
                              child: CountTile(
                                icon: k.icon,
                                label: k.label,
                                count: allFiles.where(k.matches).length,
                                selected: _kind == k,
                                onTap: () => setState(() => _kind = k),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (files.isEmpty)
                SliverToBoxAdapter(
                  child: EmptyHint(
                    icon: _kind.icon,
                    title: 'No ${_kind.label.toLowerCase()} yet',
                    text: 'Saved ${_kind.label.toLowerCase()} show up here.',
                    action: ('Show everything', () => setState(() => _kind = _Kind.all)),
                  ),
                )
              else
                SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 560,
                    mainAxisExtent: 92 + textGrowth * 3.2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _FileCard(entry: files[i]),
                    childCount: files.length,
                  ),
                ),
            ],

            if (tasks.isEmpty && allFiles.isEmpty)
              SliverToBoxAdapter(
                child: EmptyHint(
                  icon: Icons.download_rounded,
                  title: 'Nothing here yet',
                  text: 'Downloads in progress and the files saved in your FetchNet folder show up here.',
                  action: ('Find something to download', () => services.tabRequest.value = 0),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

/// A task's state, as a pill.
(String, IconData, ChipTone) _statusOf(DownloadTask task) => switch (task.status) {
      DownloadStatus.queued => ('Waiting', Icons.schedule_rounded, ChipTone.muted),
      DownloadStatus.starting => ('Starting', Icons.hourglass_top_rounded, ChipTone.accent),
      DownloadStatus.downloading => ('Downloading', Icons.downloading_rounded, ChipTone.accent),
      DownloadStatus.processing => ('Finishing', Icons.auto_fix_high_rounded, ChipTone.accent),
      DownloadStatus.paused => ('Paused', Icons.pause_circle_rounded, ChipTone.muted),
      DownloadStatus.failed => ('Failed', Icons.error_rounded, ChipTone.warn),
      DownloadStatus.cancelled => ('Cancelled', Icons.cancel_rounded, ChipTone.muted),
      DownloadStatus.completed => ('Saved', Icons.check_circle_rounded, ChipTone.good),
    };

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloads = services.downloads;
    final failed = task.status == DownloadStatus.failed;
    final paused = task.status == DownloadStatus.paused;
    final (label, icon, tone) = _statusOf(task);

    final stats = <String>[
      // "Waiting for Wi-Fi", "Waiting for yt-dlp…" or simply waiting.
      if (task.status == DownloadStatus.queued) task.stage ?? 'In the queue',
      if (paused && task.progress != null && task.progress! > 0) '${(task.progress! * 100).toStringAsFixed(0)}% done',
      if (task.stage != null && task.status != DownloadStatus.queued && !paused) task.stage!,
      if (task.status == DownloadStatus.downloading && task.totalBytes != null)
        '${formatBytes(task.downloadedBytes)} / ${task.totalIsEstimate ? '~' : ''}${formatBytes(task.totalBytes)}',
      if (task.status == DownloadStatus.downloading) formatSpeed(task.speed),
      if (task.status == DownloadStatus.downloading) formatEta(task.eta),
    ].where((s) => s.isNotEmpty).join('  ·  ');

    final pausing = task.stage == 'Pausing…' || task.stage == 'Cancelling…';
    return ListCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 88,
                height: 60,
                child: MediaThumb(kind: task.option.kind, url: task.thumbnail),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${task.fileBaseName}.${task.option.extension}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [task.option.label, if (task.option.detail != null) task.option.detail!].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    StatusPill(label: label, icon: icon, tone: tone),
                  ],
                ),
              ),
              if (!failed) ...[
                const SizedBox(width: 6),
                _RoundButton(
                  tooltip: paused ? 'Resume' : 'Pause',
                  icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  primary: paused,
                  onPressed: paused ? () => downloads.resume(task) : (pausing ? null : () => downloads.pause(task)),
                ),
                const SizedBox(width: 6),
                _RoundButton(
                  tooltip: 'Cancel',
                  icon: Icons.close_rounded,
                  onPressed: task.stage == 'Cancelling…' ? null : () => downloads.cancel(task),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (failed) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      task.errorHint ?? task.error ?? 'The download failed.',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DialogButton(
                    label: 'Try again',
                    icon: Icons.refresh_rounded,
                    primary: true,
                    expand: true,
                    onPressed: () => downloads.retry(task),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DialogButton(
                    label: 'Dismiss',
                    icon: Icons.close_rounded,
                    expand: true,
                    onPressed: () => downloads.dismiss(task),
                  ),
                ),
              ],
            ),
          ] else ...[
            GradientProgressBar(
              // Paused: where it stopped (no moving bar).
              value: paused
                  ? (task.progress ?? 0)
                  : task.status == DownloadStatus.queued || task.status == DownloadStatus.starting
                      ? null
                      : task.progress,
            ),
            const SizedBox(height: 6),
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
                if (task.progress != null && (task.status == DownloadStatus.downloading || paused))
                  Text(
                    '${(task.progress! * 100).toStringAsFixed(0)}%',
                    style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w900),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A round button on a download (pause, resume, cancel).
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.tooltip, required this.icon, required this.onPressed, this.primary = false});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: onPressed == null ? 0.45 : 1,
        child: Material(
          color: primary ? null : scheme.secondaryContainer.withValues(alpha: 0.8),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: primary ? const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle) : null,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(icon, size: 22, color: primary ? Colors.white : scheme.onSecondaryContainer),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({required this.entry});

  final HistoryEntry entry;

  Widget _thumb({double width = 96, double height = 66}) {
    final (file, url) = entryPicture(entry, fileThere: entry.filePath != null && File(entry.filePath!).existsSync());
    return SizedBox(width: width, height: height, child: MediaThumb(kind: entry.kind, file: file, url: url));
  }

  void _menu(BuildContext context) => showFileActions(context, entry, thumbnail: _thumb(width: 88, height: 60));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final details = [
      _Kind.of(entry).label.replaceFirst(RegExp(r's$'), ''),
      if (entry.quality.isNotEmpty) entry.quality,
      if (entry.sizeBytes != null && entry.sizeBytes! > 0) formatBytes(entry.sizeBytes),
    ].join(' · ');
    return ListCard(
      onTap: () => openDownloadedFile(context, entry),
      onLongPress: () => _menu(context),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
      child: Row(
        children: [
          _thumb(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(entry.filePath!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 13, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        formatDate(entry.completedAt ?? entry.createdAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: NativeBridge.canShareNatively ? 'Share' : 'Copy file to share',
            onPressed: () => shareDownloadedFile(context, entry),
            icon: Icon(NativeBridge.canShareNatively ? Icons.share_rounded : Icons.copy_rounded, size: 21),
            color: scheme.primary,
          ),
          IconButton(
            tooltip: 'More',
            onPressed: () => _menu(context),
            icon: const Icon(Icons.more_vert_rounded),
          ),
        ],
      ),
    );
  }
}
