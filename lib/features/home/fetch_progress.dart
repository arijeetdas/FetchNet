import 'dart:async';

import 'package:flutter/material.dart';

import '../../widgets/brand.dart';
import '../../widgets/motion/living_logo.dart';
import 'home_kit.dart';

/// Where one engine is while a link is read.
enum LaneState { waiting, working, done, skipped, failed }

/// "Reading the link…" with a lane per engine: yt-dlp reading the formats and
/// gallery-dl looking for the images and other files of a post, plus how long
/// it has been going.
class FetchProgressCard extends StatefulWidget {
  const FetchProgressCard({
    super.key,
    required this.host,
    required this.ytdlp,
    required this.gallery,
    required this.onCancel,
  });

  final String? host;
  final LaneState ytdlp;
  final LaneState gallery;
  final VoidCallback onCancel;

  @override
  State<FetchProgressCard> createState() => _FetchProgressCardState();
}

class _FetchProgressCardState extends State<FetchProgressCard> {
  final _watch = Stopwatch()..start();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final seconds = _watch.elapsed.inSeconds;
    final slow = seconds >= 8;
    return HomePanel(
      highlight: true,
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
      child: Column(
        children: [
          const LivingLogo(size: 104),
          const SizedBox(height: 6),
          Text('Reading the link…', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: homeDuration(context, const Duration(milliseconds: 260)),
            child: Text(
              slow
                  ? 'Some sites take a little longer. Still working · ${seconds}s'
                  : widget.host == null
                      ? 'Looking up what can be saved · ${seconds}s'
                      : 'Asking ${widget.host} what can be saved · ${seconds}s',
              key: ValueKey(slow),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 16),
          _Lane(
            icon: Icons.smart_display_rounded,
            title: 'Video & audio',
            engine: 'yt-dlp',
            state: widget.ytdlp,
          ),
          const SizedBox(height: 8),
          _Lane(
            icon: Icons.collections_rounded,
            title: 'Images & posts',
            engine: 'gallery-dl',
            state: widget.gallery,
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: widget.onCancel,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('Cancel'),
            style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Lane extends StatelessWidget {
  const _Lane({required this.icon, required this.title, required this.engine, required this.state});

  final IconData icon;
  final String title;
  final String engine;
  final LaneState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = state == LaneState.skipped || state == LaneState.waiting;
    final (String note, Widget trailing) = switch (state) {
      LaneState.waiting => ('Waiting', Icon(Icons.more_horiz_rounded, color: scheme.outline)),
      LaneState.working => ('Working', const EnergyLoader(size: 22)),
      LaneState.done => ('Found', const Icon(Icons.check_circle_rounded, color: Color(0xFF22C55E))),
      LaneState.skipped => ('Not needed for this link', Icon(Icons.remove_circle_outline_rounded, color: scheme.outline)),
      LaneState.failed => ('Nothing here', Icon(Icons.do_not_disturb_on_outlined, color: scheme.outline)),
    };
    return AnimatedOpacity(
      duration: homeDuration(context, const Duration(milliseconds: 250)),
      opacity: muted ? 0.6 : 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: state == LaneState.working
                ? scheme.primary.withValues(alpha: 0.4)
                : scheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
                      Text(
                        '$engine · $note',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: homeDuration(context, const Duration(milliseconds: 260)),
                  transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                  child: KeyedSubtree(key: ValueKey(state), child: trailing),
                ),
              ],
            ),
            if (state == LaneState.working) ...[
              const SizedBox(height: 8),
              const GradientProgressBar(value: null, height: 4),
            ],
          ],
        ),
      ),
    );
  }
}
