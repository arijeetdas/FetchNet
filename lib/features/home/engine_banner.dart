import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../engine/engine.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';

/// Shows engine setup progress, problems, and optional add-ons on Home.
class EngineBanner extends StatelessWidget {
  const EngineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.engine.status, services.engine.componentInstall, services.storage]),
      builder: (context, _) {
        final status = services.engine.status.value;
        final install = services.engine.componentInstall.value;
        final children = <Widget>[];

        switch (status.state) {
          case EngineState.initializing:
            children.add(_Banner(
              icon: Icons.memory_rounded,
              title: 'Starting the engine',
              body: status.message ?? 'Preparing yt-dlp…',
              progress: null,
            ));
          case EngineState.installing:
            children.add(_Banner(
              icon: Icons.downloading_rounded,
              title: 'One-time setup',
              body: status.message ?? 'Downloading yt-dlp…',
              progress: status.progress,
            ));
          case EngineState.error:
            children.add(_Banner(
              icon: Icons.error_outline_rounded,
              title: 'The engine isn\'t ready',
              body: status.message ?? 'Something went wrong.',
              error: true,
              action: ('Retry', services.engine.initialize),
            ));
          case EngineState.unsupported:
            children.add(_Banner(
              icon: Icons.block_rounded,
              title: 'Downloading isn\'t available here',
              body: status.message ?? '',
              error: true,
            ));
          case EngineState.updating:
            children.add(_Banner(
              icon: Icons.system_update_alt_rounded,
              title: 'Updating yt-dlp',
              body: 'You can keep using FetchNet while this finishes.',
              progress: null,
            ));
          case EngineState.ready:
            break;
        }

        if (services.storage.error != null) {
          children.add(_Banner(
            icon: Icons.folder_off_rounded,
            title: 'Download folder unavailable',
            body: services.storage.error!,
            error: true,
            action: ('Allow', () => services.storage.ensureDownloadDir(requestPermission: true)),
          ));
        }

        if (install != null) {
          children.add(_Banner(
            icon: Icons.extension_rounded,
            title: 'Installing add-on',
            body: install.label,
            progress: install.progress,
          ));
        } else if (status.state == EngineState.ready && services.engine.canInstallComponents && !status.ffmpegAvailable) {
          children.add(_Banner(
            icon: Icons.auto_awesome_rounded,
            title: 'Unlock HD video and MP3',
            body: 'Install FFmpeg so FetchNet can merge high-quality video with audio and convert audio to MP3.',
            action: (
              'Install',
              () async {
                try {
                  await services.engine.installComponent(EngineComponent.ffmpeg);
                  if (context.mounted) showSnack(context, 'FFmpeg installed — HD and MP3 unlocked', kind: ToastKind.success);
                } catch (e) {
                  if (context.mounted) showSnack(context, 'FFmpeg install failed: $e', kind: ToastKind.error);
                }
              }
            ),
          ));
        }

        if (children.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            children: [
              for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 10), child: c),
            ],
          ),
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.title,
    required this.body,
    this.progress = -1,
    this.error = false,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;

  /// -1: no progress bar, null: indeterminate.
  final double? progress;
  final bool error;
  final (String, Future<void> Function())? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = error ? scheme.errorContainer.withValues(alpha: 0.55) : scheme.primaryContainer.withValues(alpha: 0.5);
    final fg = error ? scheme.onErrorContainer : scheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(22)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, color: fg)),
                    const SizedBox(height: 2),
                    Text(body, style: theme.textTheme.bodySmall?.copyWith(color: fg, height: 1.4)),
                  ],
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: action!.$2,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                  child: Text(action!.$1),
                ),
              ],
            ],
          ),
          if (progress != -1) ...[
            const SizedBox(height: 12),
            GradientProgressBar(value: progress, height: 6),
          ],
        ],
      ),
    );
  }
}
