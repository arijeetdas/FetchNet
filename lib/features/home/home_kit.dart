import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../widgets/brand.dart';
import '../../widgets/motion/motion_core.dart';

/// Shared building blocks of the Home screen: entrance motion, press
/// feedback, the glass panel, an animated segmented control and pills.
///
/// Every animation here follows Settings → Show animations and the system's
/// "remove animations" switch: with either off, things simply appear.

/// Whether Home should animate right now.
bool homeMotion(BuildContext context) =>
    AppScope.of(context).showAnimations.value && !MediaQuery.disableAnimationsOf(context);

/// [d], or zero when animations are off.
Duration homeDuration(BuildContext context, Duration d) => homeMotion(context) ? d : Duration.zero;

/// Fades, lifts and slightly grows its child in once, after [delay]. Use
/// [index] for a stagger (each step adds [step]); only the first few steps
/// wait, so long grids don't take ages to fill.
class EntranceMotion extends StatefulWidget {
  const EntranceMotion({
    super.key,
    required this.child,
    this.index = 0,
    this.delay = Duration.zero,
    this.step = const Duration(milliseconds: 45),
    this.offset = 18,
    this.duration = const Duration(milliseconds: 520),
  });

  final Widget child;
  final int index;
  final Duration delay;
  final Duration step;

  /// Pixels the child rises from.
  final double offset;
  final Duration duration;

  @override
  State<EntranceMotion> createState() => _EntranceMotionState();
}

class _EntranceMotionState extends State<EntranceMotion> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: expoOutCurve);
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!homeMotion(context)) {
      _c.value = 1;
      return;
    }
    final wait = widget.delay + widget.step * widget.index.clamp(0, 10);
    if (wait == Duration.zero) {
      _c.forward();
    } else {
      _timer = Timer(wait, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) {
        final v = _t.value;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - v) * widget.offset),
            child: Transform.scale(scale: 0.97 + 0.03 * v, child: child),
          ),
        );
      },
    );
  }
}

/// Shrinks its child a touch while a pointer is down on it. It never takes
/// the tap itself, so an [InkWell] inside still works.
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.child, this.scale = 0.965, this.enabled = true});

  final Widget child;
  final double scale;
  final bool enabled;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: widget.enabled ? (_) => _set(true) : null,
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: homeDuration(context, Duration(milliseconds: _down ? 90 : 260)),
        curve: _down ? Curves.easeOut : springCurve,
        child: widget.child,
      ),
    );
  }
}

/// The frosted panel every Home section sits on.
class HomePanel extends StatelessWidget {
  const HomePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 28,
    this.highlight = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// A brighter violet edge and glow (results, the focused link dock).
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedContainer(
      duration: homeDuration(context, const Duration(milliseconds: 320)),
      curve: Curves.easeOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: dark ? 0.86 : 0.92),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: highlight ? scheme.primary.withValues(alpha: 0.45) : scheme.outlineVariant.withValues(alpha: 0.35),
          width: highlight ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: highlight ? 0.16 : 0.06),
            blurRadius: highlight ? 38 : 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// A small section heading: gradient icon tile, title, optional subtitle and
/// trailing widget.
class HomeSectionTitle extends StatelessWidget {
  const HomeSectionTitle({super.key, required this.icon, required this.title, this.subtitle, this.trailing});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(gradient: tileGradient, borderRadius: BorderRadius.circular(11)),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// One choice of a [SlidingSegments].
class Segment<T> {
  const Segment({required this.value, required this.label, this.icon, this.count, this.enabled = true});

  final T value;
  final String label;
  final IconData? icon;

  /// A small number next to the label (how many options / files).
  final int? count;
  final bool enabled;
}

/// A segmented control whose gradient pill slides between the choices.
class SlidingSegments<T> extends StatelessWidget {
  const SlidingSegments({super.key, required this.segments, required this.selected, required this.onChanged});

  final List<Segment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final index = segments.indexWhere((s) => s.value == selected).clamp(0, segments.length - 1);
    final n = segments.length;
    return Container(
      height: 50,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
            duration: homeDuration(context, const Duration(milliseconds: 420)),
            curve: springCurve,
            child: FractionallySizedBox(
              widthFactor: 1 / n,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppColors.brandGradient,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.violetBright.withValues(alpha: 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final (i, s) in segments.indexed)
                Expanded(
                  child: Semantics(
                    selected: i == index,
                    button: true,
                    enabled: s.enabled,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: s.enabled && i != index ? () => onChanged(s.value) : null,
                      child: _SegmentLabel(segment: s, active: i == index),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SegmentLabel<T> extends StatelessWidget {
  const _SegmentLabel({required this.segment, required this.active});

  final Segment<T> segment;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = !segment.enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
        : active
            ? Colors.white
            : scheme.onSurfaceVariant;
    final style = theme.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w800);
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (segment.icon != null) ...[
                Icon(segment.icon, size: 18, color: color),
                const SizedBox(width: 6),
              ],
              AnimatedDefaultTextStyle(
                duration: homeDuration(context, const Duration(milliseconds: 200)),
                style: style ?? TextStyle(color: color),
                child: Text(segment.label),
              ),
              if (segment.count != null) ...[
                const SizedBox(width: 6),
                AnimatedContainer(
                  duration: homeDuration(context, const Duration(milliseconds: 200)),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: active ? Colors.white.withValues(alpha: 0.22) : scheme.outlineVariant.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${segment.count}',
                    style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A dark, legible pill laid over pictures (duration, LIVE, counts).
class OverlayPill extends StatelessWidget {
  const OverlayPill({super.key, required this.text, this.icon, this.color});

  final String text;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color ?? Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800, height: 1.2),
          ),
        ],
      ),
    );
  }
}

/// Icon + text on a tonal background (site, uploader, views…).
class MetaChip extends StatelessWidget {
  const MetaChip({super.key, required this.icon, required this.text, this.strong = false, this.onTap});

  final IconData icon;
  final String text;

  /// The violet variant (the site the media is from).
  final bool strong;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = strong ? scheme.primaryContainer.withValues(alpha: 0.8) : scheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final fg = strong ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A gradient badge (4K, HD, Best, GIF…).
class GradientBadge extends StatelessWidget {
  const GradientBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(7)),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w900, letterSpacing: 0.3),
      ),
    );
  }
}

/// A dot that softly pulses while [active] (engine busy, live download).
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, required this.color, this.active = true, this.size = 9});

  final Color color;
  final bool active;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  void _sync() {
    final run = widget.active && homeMotion(context);
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run && _c.isAnimating) {
      _c
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 2,
      height: s * 2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_c.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              if (_c.isAnimating)
                Container(
                  width: s + s * t,
                  height: s + s * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.45 * (1 - t)),
                  ),
                ),
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                  boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.5), blurRadius: 6)],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A network picture that fades in, with [fallback] while it loads or when
/// it fails.
class FadeInNetworkImage extends StatelessWidget {
  const FadeInNetworkImage({
    super.key,
    required this.url,
    required this.fallback,
    this.headers,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });

  final String url;
  final Widget fallback;
  final Map<String, String>? headers;
  final BoxFit fit;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        fallback,
        Image.network(
          url,
          headers: headers,
          fit: fit,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
          frameBuilder: (context, child, frame, sync) {
            if (sync) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: homeDuration(context, const Duration(milliseconds: 320)),
              curve: Curves.easeOut,
              child: child,
            );
          },
        ),
      ],
    );
  }
}
