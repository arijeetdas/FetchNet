import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../engine/engine.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/motion/motion_core.dart';
import '../settings/engines_screen.dart';
import '../shell/updater_dialog.dart';
import 'home_kit.dart';

void _openEngines(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EnginesScreen()));

enum _Tone { info, busy, error, update }

class _Card {
  const _Card({
    required this.id,
    required this.tone,
    required this.icon,
    required this.title,
    required this.body,
    this.progress = -1,
    this.action,
    this.onTap,
  });

  /// Stable per kind of card, so a card that changes (25 % → 60 %) updates in
  /// place and only new cards animate in.
  final String id;
  final _Tone tone;
  final IconData icon;
  final String title;
  final String body;

  /// -1: no bar, null: indeterminate, 0..1: progress.
  final double? progress;
  final (String, IconData, Future<void> Function())? action;
  final VoidCallback? onTap;
}

/// Everything Home needs to tell you before a download: a new FetchNet
/// version, yt-dlp and gallery-dl starting, installing, updating or failing,
/// the download folder, and add-ons (FFmpeg) to install.
class StatusDeck extends StatelessWidget {
  const StatusDeck({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final gallery = services.gallery;
    return ListenableBuilder(
      listenable: Listenable.merge([
        services.updates,
        services.engine.status,
        services.engine.componentInstall,
        gallery.engine.status,
        services.storage,
      ]),
      builder: (context, _) {
        final cards = <_Card>[];
        void engines() => _openEngines(context);

        // ── FetchNet itself ──
        final latest = services.updates.latest;
        if (services.updates.updateAvailable && latest != null) {
          final installed = services.updates.installed;
          cards.add(_Card(
            id: 'app-update',
            tone: _Tone.update,
            icon: Icons.system_update_rounded,
            title: 'FetchNet v${latest.versionName} is here',
            body: installed == null
                ? 'A newer FetchNet is ready to download.'
                : 'You have v${installed.versionName}. Update for the latest fixes and features.',
            action: ('Update', Icons.arrow_upward_rounded, () => showUpdaterDialog(context)),
          ));
        }

        // ── yt-dlp ──
        final status = services.engine.status.value;
        switch (status.state) {
          case EngineState.initializing:
            cards.add(_Card(
              id: 'ytdlp',
              tone: _Tone.busy,
              icon: Icons.memory_rounded,
              title: 'Starting yt-dlp',
              body: status.message ?? 'Warming up the video & audio engine…',
              progress: null,
              onTap: engines,
            ));
          case EngineState.installing:
            final p = status.progress;
            cards.add(_Card(
              id: 'ytdlp',
              tone: _Tone.busy,
              icon: Icons.downloading_rounded,
              title: p == null ? 'Downloading yt-dlp' : 'Downloading yt-dlp · ${(p * 100).round()}%',
              body: status.message ?? 'A one-time setup. FetchNet is ready as soon as it finishes.',
              progress: p,
              onTap: engines,
            ));
          case EngineState.updating:
            cards.add(_Card(
              id: 'ytdlp',
              tone: _Tone.busy,
              icon: Icons.update_rounded,
              title: 'Updating yt-dlp',
              body: 'Keep fetching: the update finishes in the background.',
              progress: null,
              onTap: engines,
            ));
          case EngineState.error:
            cards.add(_Card(
              id: 'ytdlp',
              tone: _Tone.error,
              icon: Icons.error_outline_rounded,
              title: 'yt-dlp isn\'t ready',
              body: status.message ?? 'Something went wrong while starting the engine.',
              action: ('Retry', Icons.refresh_rounded, services.engine.initialize),
              onTap: engines,
            ));
          case EngineState.unsupported:
            cards.add(_Card(
              id: 'ytdlp',
              tone: _Tone.error,
              icon: Icons.block_rounded,
              title: 'Downloading isn\'t available here',
              body: status.message ?? '',
            ));
          case EngineState.ready:
            break;
        }

        // ── gallery-dl (images & posts) ──
        if (gallery.enabled) {
          final g = gallery.engine.status.value;
          switch (g.state) {
            case EngineState.installing:
              final p = g.progress;
              cards.add(_Card(
                id: 'gallery',
                tone: _Tone.busy,
                icon: Icons.collections_rounded,
                title: p == null ? 'Setting up images & posts' : 'Setting up images & posts · ${(p * 100).round()}%',
                body: g.message ?? 'Downloading gallery-dl in the background. Videos and audio already work.',
                progress: p,
                onTap: engines,
              ));
            case EngineState.updating:
              cards.add(_Card(
                id: 'gallery',
                tone: _Tone.busy,
                icon: Icons.update_rounded,
                title: 'Updating gallery-dl',
                body: 'Images and posts keep working while it updates.',
                progress: null,
                onTap: engines,
              ));
            case EngineState.error:
              cards.add(_Card(
                id: 'gallery',
                tone: _Tone.error,
                icon: Icons.hide_image_outlined,
                title: 'Images & posts aren\'t ready',
                body: g.message ?? 'gallery-dl couldn\'t start. Videos and audio still work.',
                action: ('Retry', Icons.refresh_rounded, gallery.engine.initialize),
                onTap: engines,
              ));
            case EngineState.initializing || EngineState.ready || EngineState.unsupported:
              break;
          }
        }

        // ── Download folder ──
        if (services.storage.error != null) {
          cards.add(_Card(
            id: 'storage',
            tone: _Tone.error,
            icon: Icons.folder_off_rounded,
            title: 'Download folder unavailable',
            body: services.storage.error!,
            action: ('Allow', Icons.folder_open_rounded, () => services.storage.ensureDownloadDir(requestPermission: true)),
          ));
        }

        // ── Add-ons ──
        final install = services.engine.componentInstall.value;
        if (install != null) {
          final p = install.progress;
          cards.add(_Card(
            id: 'addon',
            tone: _Tone.busy,
            icon: Icons.extension_rounded,
            title: p == null ? 'Installing add-on' : 'Installing add-on · ${(p * 100).round()}%',
            body: install.label,
            progress: p,
          ));
        } else if (status.state == EngineState.ready && services.engine.canInstallComponents && !status.ffmpegAvailable) {
          cards.add(_Card(
            id: 'ffmpeg',
            tone: _Tone.info,
            icon: Icons.auto_awesome_rounded,
            title: 'Unlock HD video and MP3',
            body: 'Install FFmpeg so FetchNet can merge HD video with its audio and convert audio to MP3.',
            action: (
              'Install',
              Icons.download_rounded,
              () async {
                try {
                  await services.engine.installComponent(EngineComponent.ffmpeg);
                  if (context.mounted) showSnack(context, 'FFmpeg installed: HD and MP3 unlocked', kind: ToastKind.success);
                } catch (e) {
                  if (context.mounted) showSnack(context, 'FFmpeg install failed: $e', kind: ToastKind.error);
                }
              },
            ),
          ));
        }

        return AnimatedSize(
          duration: homeDuration(context, const Duration(milliseconds: 380)),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: cards.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    children: [
                      for (final (i, c) in cards.indexed)
                        Padding(
                          key: ValueKey(c.id),
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                          child: EntranceMotion(index: i, child: _StatusCard(card: c)),
                        ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _StatusCard extends StatefulWidget {
  const _StatusCard({required this.card});

  final _Card card;

  @override
  State<_StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<_StatusCard> {
  bool _running = false;

  Future<void> _run() async {
    final action = widget.card.action;
    if (action == null || _running) return;
    setState(() => _running = true);
    try {
      await action.$3();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = widget.card;
    final error = c.tone == _Tone.error;
    final update = c.tone == _Tone.update;
    final busy = c.tone == _Tone.busy;
    final fg = error ? scheme.onErrorContainer : scheme.onSurface;
    final sub = error ? scheme.onErrorContainer.withValues(alpha: 0.85) : scheme.onSurfaceVariant;

    final iconTile = AnimatedContainer(
      duration: homeDuration(context, const Duration(milliseconds: 300)),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: error ? null : tileGradient,
        color: error ? scheme.error : null,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: (error ? scheme.error : AppColors.violetBright).withValues(alpha: 0.3),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: busy && c.progress == null
          ? const Padding(padding: EdgeInsets.all(9), child: EnergyLoader(size: 26, onColor: true))
          : Icon(c.icon, color: error ? scheme.onError : Colors.white, size: 22),
    );

    final action = c.action;
    final button = action == null
        ? null
        : update
            ? GradientButton(label: action.$1, icon: action.$2, height: 42, loading: _running, onPressed: _run)
            : FilledButton.tonalIcon(
                onPressed: _running ? null : _run,
                icon: _running ? const EnergyLoader(size: 18) : Icon(action.$2, size: 18),
                label: Text(action.$1),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  backgroundColor: error ? scheme.error : null,
                  foregroundColor: error ? scheme.onError : null,
                ),
              );

    final narrow = MediaQuery.sizeOf(context).width < 420;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSwitcher(
          duration: homeDuration(context, const Duration(milliseconds: 200)),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
          child: Text(
            c.title,
            key: ValueKey(c.title),
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, color: fg),
          ),
        ),
        if (c.body.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(c.body, style: theme.textTheme.bodySmall?.copyWith(color: sub, height: 1.4)),
        ],
      ],
    );

    return PressableScale(
      enabled: c.onTap != null,
      scale: 0.985,
      child: Material(
        color: error
            ? scheme.errorContainer.withValues(alpha: 0.7)
            : scheme.surfaceContainerLow.withValues(alpha: 0.92),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color: error
                ? scheme.error.withValues(alpha: 0.35)
                : update
                    ? scheme.primary.withValues(alpha: 0.5)
                    : scheme.outlineVariant.withValues(alpha: 0.35),
            width: update ? 1.4 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: c.onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    iconTile,
                    const SizedBox(width: 12),
                    Expanded(child: text),
                    if (button != null && !narrow) ...[const SizedBox(width: 10), button],
                    if (button == null && c.onTap != null)
                      Icon(Icons.chevron_right_rounded, color: sub),
                  ],
                ),
                if (button != null && narrow) ...[
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerRight, child: button),
                ],
                if (c.progress != -1) ...[
                  const SizedBox(height: 12),
                  GradientProgressBar(value: c.progress, height: 6),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
