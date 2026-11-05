import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../engine/engine.dart';
import '../../models/media_info.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import 'rename_dialog.dart';

class MediaResultView extends StatefulWidget {
  const MediaResultView({super.key, required this.info});

  final MediaInfo info;

  @override
  State<MediaResultView> createState() => _MediaResultViewState();
}

class _MediaResultViewState extends State<MediaResultView> {
  late MediaKind _kind = widget.info.preferAudio ? MediaKind.audio : MediaKind.video;
  int _selected = 0;

  Future<void> _download(DownloadOption option) async {
    final services = AppScope.of(context);
    if (services.storage.downloadDir == null) {
      await services.storage.ensureDownloadDir(requestPermission: true);
      if (!mounted) return;
      if (services.storage.downloadDir == null) {
        showSnack(context, services.storage.error ?? 'The download folder isn\'t available.', kind: ToastKind.error);
        return;
      }
    }
    final name = await showRenameDialog(context, info: widget.info, option: option);
    if (name == null || !mounted) return;
    await services.downloads.enqueue(info: widget.info, option: option, fileBaseName: name);
    if (!mounted) return;
    showSnack(
      context,
      'Downloading $name.${option.extension}',
      kind: ToastKind.success,
      actionLabel: 'View',
      onAction: () => services.tabRequest.value = 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ValueListenableBuilder<EngineStatus>(
      valueListenable: services.engine.status,
      builder: (context, status, _) {
        final ffmpeg = status.ffmpegAvailable;
        final video = widget.info.videoOptions(ffmpeg: ffmpeg);
        final audio = widget.info.audioOptions(ffmpeg: ffmpeg);
        var kind = _kind;
        if (kind == MediaKind.video && video.isEmpty && audio.isNotEmpty) kind = MediaKind.audio;
        if (kind == MediaKind.audio && audio.isEmpty && video.isNotEmpty) kind = MediaKind.video;
        final options = kind == MediaKind.video ? video : audio;
        final selected = options.isEmpty ? null : options[_selected.clamp(0, options.length - 1)];

        final header = _MediaHeader(info: widget.info);
        final picker = _OptionPicker(
          kind: kind,
          hasVideo: video.isNotEmpty,
          hasAudio: audio.isNotEmpty,
          options: options,
          selected: selected,
          ffmpegMissing: !ffmpeg,
          onKind: (k) => setState(() {
            _kind = k;
            _selected = 0;
          }),
          onSelect: (o) => setState(() => _selected = options.indexOf(o)),
          onDownload: selected == null || !status.isReady ? null : () => _download(selected),
        );

        return LayoutBuilder(builder: (context, c) {
          final twoColumn = c.maxWidth >= 820;
          return Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: EdgeInsets.all(twoColumn ? 22 : 16),
              child: twoColumn
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: header),
                        const SizedBox(width: 24),
                        Expanded(flex: 6, child: picker),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [header, const SizedBox(height: 18), picker],
                    ),
            ),
          );
        });
      },
    );
  }
}

class _MediaHeader extends StatelessWidget {
  const _MediaHeader({required this.info});

  final MediaInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [
      if (info.uploader != null) info.uploader!,
      if (info.viewCount != null) '${formatCount(info.viewCount)} views',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  decoration: const BoxDecoration(gradient: AppColors.brandGradient),
                  child: const Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 56),
                ),
                if (info.thumbnail != null)
                  Image.network(
                    info.thumbnail!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      child: child,
                    ),
                  ),
                if (info.duration != null)
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: _Pill(text: formatDuration(info.duration), dark: true),
                  ),
                if (info.isLive)
                  const Positioned(left: 10, top: 10, child: _Pill(text: 'LIVE', color: Colors.red)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(info.title, style: theme.textTheme.titleLarge, maxLines: 3, overflow: TextOverflow.ellipsis),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(meta, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        if (info.extractor != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.public_rounded, size: 14, color: scheme.onSecondaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    info.extractor!,
                    style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.dark = false, this.color});

  final String text;
  final bool dark;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color ?? Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
    );
  }
}

class _OptionPicker extends StatelessWidget {
  const _OptionPicker({
    required this.kind,
    required this.hasVideo,
    required this.hasAudio,
    required this.options,
    required this.selected,
    required this.ffmpegMissing,
    required this.onKind,
    required this.onSelect,
    required this.onDownload,
  });

  final MediaKind kind;
  final bool hasVideo;
  final bool hasAudio;
  final List<DownloadOption> options;
  final DownloadOption? selected;
  final bool ffmpegMissing;
  final ValueChanged<MediaKind> onKind;
  final ValueChanged<DownloadOption> onSelect;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<MediaKind>(
          segments: [
            ButtonSegment(
              value: MediaKind.video,
              icon: const Icon(Icons.movie_rounded),
              label: const Text('Video'),
              enabled: hasVideo,
            ),
            ButtonSegment(
              value: MediaKind.audio,
              icon: const Icon(Icons.music_note_rounded),
              label: const Text('Audio'),
              enabled: hasAudio,
            ),
          ],
          selected: {kind},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onKind(s.first),
        ),
        const SizedBox(height: 14),
        Text(
          kind == MediaKind.video ? 'Choose a quality' : 'Choose a format',
          style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (options.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No ${kind.name} formats are available for this link.',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: options.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _OptionTile(
                option: options[i],
                selected: identical(options[i], selected),
                onTap: () => onSelect(options[i]),
              ),
            ),
          ),
        if (ffmpegMissing) ...[
          const SizedBox(height: 10),
          Text(
            'Install FFmpeg (Home banner or Settings) for HD qualities and MP3.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 16),
        GradientButton(
          label: selected == null
              ? 'Download'
              : 'Download ${selected!.label}${selected!.sizeBytes != null ? '  ·  ~${formatBytes(selected!.sizeBytes)}' : ''}',
          icon: Icons.download_rounded,
          expand: true,
          onPressed: onDownload,
        ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.option, required this.selected, required this.onTap});

  final DownloadOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.65) : scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.5),
          width: selected ? 1.6 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? scheme.primary : scheme.outline,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(option.label, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                          if (option.badge != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                gradient: AppColors.brandGradient,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                option.badge!,
                                style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w900),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (option.detail != null)
                        Text(option.detail!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (option.sizeBytes != null)
                  Text(
                    '~${formatBytes(option.sizeBytes)}',
                    style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
