import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../engine/engine.dart';
import '../../models/creator_job.dart';
import '../../services/creator_settings.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../home/home_kit.dart';
import '../shell/home_shell.dart';
import 'settings_widgets.dart';
import '../../ui_kit/kit.dart';
import '../../widgets/sub_page.dart';

/// Settings → Creator Settings: clips of videos and songs, Shorts / Reels
/// (9:16) and snapshots, for YouTube and most other sites.
class CreatorSettingsScreen extends StatelessWidget {
  const CreatorSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final creator = services.creator;
    final wide = Breakpoints.isWide(context);

    final body = ListenableBuilder(
      listenable: Listenable.merge([creator, services.engine.status, services.engine.componentInstall]),
      builder: (context, _) {
        final ffmpeg = services.engine.status.value.ffmpegAvailable;
        final clips = _ClipsCard(creator: creator, ffmpeg: ffmpeg);
        final shorts = _ShortsCard(creator: creator, ffmpeg: ffmpeg);
        final snapshots = _SnapshotsCard(creator: creator, ffmpeg: ffmpeg);
        return LayoutBuilder(
          builder: (context, c) {
            final columns = c.maxWidth >= 1150 ? 3 : (c.maxWidth >= 900 ? 2 : 1);
            Widget column(List<Widget> children) =>
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children));
            final cards = switch (columns) {
              3 => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    column([EntranceMotion(index: 1, child: clips)]),
                    const SizedBox(width: 20),
                    column([EntranceMotion(index: 2, child: shorts)]),
                    const SizedBox(width: 20),
                    column([EntranceMotion(index: 3, child: snapshots)]),
                  ],
                ),
              2 => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    column([EntranceMotion(index: 1, child: clips), EntranceMotion(index: 3, child: snapshots)]),
                    const SizedBox(width: 20),
                    column([EntranceMotion(index: 2, child: shorts)]),
                  ],
                ),
              _ => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EntranceMotion(index: 1, child: clips),
                    EntranceMotion(index: 2, child: shorts),
                    EntranceMotion(index: 3, child: snapshots),
                  ],
                ),
            };
            return ListView(
              padding: EdgeInsets.fromLTRB(wide ? 28 : 16, MediaQuery.paddingOf(context).top + 4, wide ? 28 : 16, 32 + MediaQuery.paddingOf(context).bottom),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: columns == 3 ? 1320 : (columns == 2 ? 1100 : 760)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        EntranceMotion(
                          child: _Hero(creator: creator, ffmpeg: ffmpeg),
                        ),
                        cards,
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    return SubPageScaffold(title: 'Creator Settings', background: !wide, body: body);
  }
}

/// What's on, as short names: "Video clips", "9:16"...
List<String> _onNames(CreatorSettings c) => [
  if (c.videoClips) 'Video clips',
  if (c.audioClips) 'Audio clips',
  if (c.videoClips && c.shorts) 'Shorts & Reels',
  if (c.snapshots) 'Snapshots',
];

/// The page's top: what the tools are for, FFmpeg's state and what's on.
class _Hero extends StatelessWidget {
  const _Hero({required this.creator, required this.ffmpeg});

  final CreatorSettings creator;
  final bool ffmpeg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final services = AppScope.of(context);
    final install = services.engine.componentInstall.value;
    final installing = install?.component == EngineComponent.ffmpeg;
    final on = _onNames(creator);
    return SettingsCard(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const GradientGlyph(Icons.movie_edit, size: 56),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('For creators', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Text(
                    'Cut the part you need from a video or song, turn landscape clips into Shorts and Reels, '
                    'and save any moment as a picture. Works with YouTube and most other sites.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusChip(
              label: ffmpeg ? 'FFmpeg ready' : 'Needs FFmpeg',
              icon: ffmpeg ? Icons.check_circle_rounded : Icons.error_rounded,
              tone: ffmpeg ? ChipTone.good : ChipTone.warn,
            ),
            StatusChip(
              label: on.isEmpty ? 'All tools off' : '${on.length} of 4 on',
              icon: on.isEmpty ? Icons.toggle_off_rounded : Icons.toggle_on_rounded,
              tone: on.isEmpty ? ChipTone.muted : ChipTone.accent,
            ),
          ],
        ),
        if (!ffmpeg) ...[
          const SizedBox(height: 14),
          TipBox(
            icon: Icons.info_outline_rounded,
            text:
                'Clips, Shorts and snapshots are made with FFmpeg, a free video tool. '
                '${services.engine.canInstallComponents ? 'Install it once and the tools below switch on.' : 'It isn\'t available on this device yet.'}',
          ),
          if (services.engine.canInstallComponents) ...[
            const SizedBox(height: 12),
            GradientButton(
              label: installing ? install!.label : 'Install FFmpeg',
              icon: Icons.download_rounded,
              expand: true,
              height: 48,
              loading: installing,
              onPressed: installing
                  ? null
                  : () async {
                      await services.engine.installComponent(EngineComponent.ffmpeg);
                      if (context.mounted && services.engine.status.value.ffmpegAvailable) {
                        showSnack(context, 'FFmpeg is installed', kind: ToastKind.success);
                      }
                    },
            ),
          ],
        ],
      ],
    );
  }
}

/// Clips: video and audio, and how exactly they're cut.
class _ClipsCard extends StatelessWidget {
  const _ClipsCard({required this.creator, required this.ffmpeg});

  final CreatorSettings creator;
  final bool ffmpeg;

  @override
  Widget build(BuildContext context) {
    final any = creator.videoClips || creator.audioClips;
    return _ToolCard(
      label: 'Clips',
      icon: Icons.content_cut_rounded,
      title: 'Download just a part',
      subtitle: 'Pick where a clip starts and ends, to the second, instead of saving the whole thing.',
      children: [
        ToggleRow(
          icon: Icons.movie_rounded,
          title: 'Video clips',
          subtitle: 'Under the video qualities',
          value: creator.videoClips,
          onChanged: ffmpeg ? creator.setVideoClips : null,
        ),
        ToggleRow(
          icon: Icons.graphic_eq_rounded,
          title: 'Audio clips',
          subtitle: 'Under the audio formats',
          value: creator.audioClips,
          onChanged: ffmpeg ? creator.setAudioClips : null,
        ),
        ToggleRow(
          icon: Icons.straighten_rounded,
          title: 'Exact cut points',
          subtitle: creator.exactCuts ? 'Starts and ends right where you set them' : 'Faster; may be off by a few seconds',
          value: creator.exactCuts,
          onChanged: ffmpeg && any ? creator.setExactCuts : null,
          last: true,
        ),
        const SizedBox(height: 12),
        const TipBox(
          icon: Icons.touch_app_rounded,
          text: 'On Home, choose Clip under the formats, then drag the ends, type the times or pick 15 s, 30 s, 1 min or 3 min.',
        ),
      ],
    );
  }
}

/// Shorts & Reels: landscape clips made 9:16, on black or blurred video.
class _ShortsCard extends StatelessWidget {
  const _ShortsCard({required this.creator, required this.ffmpeg});

  final CreatorSettings creator;
  final bool ffmpeg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ready = ffmpeg && creator.videoClips;
    final on = ready && creator.shorts;
    return _ToolCard(
      label: 'Shorts & Reels',
      icon: Icons.stay_current_portrait_rounded,
      title: 'Make clips 9:16',
      subtitle:
          'A landscape clip becomes portrait for YouTube Shorts and Instagram Reels, without cutting anything '
          'off. Portrait clips stay as they are.',
      value: creator.shorts && creator.videoClips,
      onChanged: ready ? creator.setShorts : null,
      children: [
        if (!creator.videoClips)
          TipBox(
            icon: Icons.lock_outline_rounded,
            text: 'Works on video clips: turn on Video clips first.',
            action: ffmpeg ? ('Turn on', () => creator.setVideoClips(true)) : null,
          )
        else ...[
          Text(
            'Background',
            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: on ? null : scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          AnimatedOpacity(
            opacity: on ? 1 : 0.5,
            duration: const Duration(milliseconds: 200),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, bg) in ShortsBackground.values.indexed) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(
                      child: ChoiceTile(
                        selected: creator.shortsBackground == bg,
                        onTap: on ? () => creator.setShortsBackground(bg) : null,
                        preview: _PortraitPreview(blurred: bg == ShortsBackground.blur),
                        title: bg.label,
                        subtitle: bg == ShortsBackground.blur ? 'Like YouTube does' : 'Clean and simple',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Snapshots: one frame of a video, as a JPG or a PNG.
class _SnapshotsCard extends StatelessWidget {
  const _SnapshotsCard({required this.creator, required this.ffmpeg});

  final CreatorSettings creator;
  final bool ffmpeg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = ffmpeg && creator.snapshots;
    return _ToolCard(
      label: 'Snapshots',
      icon: Icons.camera_rounded,
      title: 'Save a moment',
      subtitle: 'Any frame of a video as a picture, at the video\'s best quality.',
      value: creator.snapshots,
      onChanged: ffmpeg ? creator.setSnapshots : null,
      children: [
        Text(
          'Format',
          style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: on ? null : scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        AnimatedOpacity(
          opacity: on ? 1 : 0.5,
          duration: const Duration(milliseconds: 200),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, f) in SnapshotFormat.values.indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: ChoiceTile(
                      selected: creator.snapshotFormat == f,
                      onTap: on ? () => creator.setSnapshotFormat(f) : null,
                      preview: _FormatBadge(label: f.label, lossless: f == SnapshotFormat.png),
                      title: f.label,
                      subtitle: f == SnapshotFormat.jpg ? 'Smaller · shares anywhere' : 'Lossless · bigger files',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const TipBox(
          icon: Icons.touch_app_rounded,
          text: 'On Home, the Thumbnail tab gets a Snapshot card: pick the moment to the second, or step frame by frame.',
        ),
      ],
    );
  }
}

// ───────────── Building blocks ─────────────

/// One tool: a label above, then a card with the tool's gradient icon, what
/// it does, an optional switch, and its options.
class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.label, required this.icon, required this.title, required this.subtitle, required this.children, this.value, this.onChanged});

  final String label;
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool? value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(label),
        SettingsCard(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GradientGlyph(icon, dimmed: onChanged == null && value != null),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                      const SizedBox(height: 3),
                      Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
                    ],
                  ),
                ),
                if (value != null) ...[const SizedBox(width: 8), KitSwitch(value: value!, onChanged: onChanged)],
              ],
            ),
            const SizedBox(height: 16),
            AnimatedSize(
              duration: homeDuration(context, const Duration(milliseconds: 240)),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ],
        ),
      ],
    );
  }
}

/// A 9:16 phone screen with a landscape video in the middle, on black or on
/// a blurred, enlarged copy of the video.
class _PortraitPreview extends StatelessWidget {
  const _PortraitPreview({required this.blurred});

  final bool blurred;

  static const _scene = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0EA5E9), Color(0xFF7C3AED), Color(0xFFF97316)]);

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 9 / 16,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black.withValues(alpha: 0.75), width: 3),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (blurred)
                // The video, enlarged, soft and a little darker.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [for (final c in _scene.colors) Color.lerp(c, Colors.black, 0.35)!],
                    ),
                  ),
                )
              else
                const ColoredBox(color: Colors.black),
              const Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: _scene),
                    child: Center(child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A picture file's badge: "JPG" / "PNG".
class _FormatBadge extends StatelessWidget {
  const _FormatBadge({required this.label, required this.lossless});

  final String label;
  final bool lossless;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 4 / 5,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(lossless ? Icons.high_quality_rounded : Icons.photo_rounded, size: 34, color: scheme.primary),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(6)),
              child: Text(
                '.${label.toLowerCase()}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Creator Settings button on the main Settings page.
class CreatorSettingsTile extends StatelessWidget {
  const CreatorSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    return NavTile(
      leading: const GradientGlyph(Icons.movie_edit, size: 42),
      title: 'Creator Settings',
      subtitle: 'Cut clips, make Shorts & Reels and save snapshots, on YouTube and more',
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreatorSettingsScreen())),
    );
  }
}
