import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LiquidNavItem {
  const LiquidNavItem({required this.icon, required this.selectedIcon, required this.label, this.badge = 0});

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Shown as a small count bubble when > 0.
  final int badge;
}

/// Floating glass navigation bar with a liquid selector.
///
/// Tapping an item calls [onTargetChanged]; the parent passes the new
/// [target] back, the selector flows over to it, and only once it has fully
/// settled is [onSettled] called (that's when the page should change).
class LiquidNavBar extends StatefulWidget {
  const LiquidNavBar({
    super.key,
    required this.items,
    required this.target,
    required this.onTargetChanged,
    required this.onSettled,
  });

  final List<LiquidNavItem> items;
  final int target;
  final ValueChanged<int> onTargetChanged;
  final ValueChanged<int> onSettled;

  static const height = 70.0;

  @override
  State<LiquidNavBar> createState() => _LiquidNavBarState();
}

class _LiquidNavBarState extends State<LiquidNavBar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 560))
    ..addStatusListener(_onStatus);

  // Selector edges in "slot" units: slot i spans [i, i + 1].
  late double _fromL = widget.target.toDouble();
  late double _fromR = widget.target + 1.0;
  late int _to = widget.target;

  @override
  void didUpdateWidget(LiquidNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.target != _to) _moveTo(widget.target);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) widget.onSettled(_to);
  }

  void _moveTo(int index) {
    final (l, r) = _edges();
    _fromL = l;
    _fromR = r;
    _to = index;
    _c.forward(from: 0);
  }

  /// Current selector edges. The leading edge rushes ahead, the trailing edge
  /// follows later with a slight overshoot, so the blob stretches and then
  /// squishes into place like a drop of liquid.
  (double, double) _edges() {
    final t = _c.value;
    final toL = _to.toDouble();
    final toR = _to + 1.0;
    if (_c.isCompleted) return (toL, toR);
    if (_c.isDismissed) return (_fromL, _fromR);
    final movingRight = toL > _fromL;
    const lead = Interval(0.0, 0.62, curve: Curves.easeOutCubic);
    const trail = Interval(0.16, 1.0, curve: Curves.easeOutBack);
    final leadT = lead.transform(t);
    final trailT = trail.transform(t);
    if (movingRight) {
      return (lerpDouble(_fromL, toL, trailT)!, lerpDouble(_fromR, toR, leadT)!);
    }
    return (lerpDouble(_fromL, toL, leadT)!, lerpDouble(_fromR, toR, trailT)!);
  }

  void _tap(int i) {
    if (i == _to && !_c.isAnimating) {
      widget.onSettled(i);
      return;
    }
    HapticFeedback.selectionClick();
    widget.onTargetChanged(i);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final n = widget.items.length;
    const pad = 6.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: LiquidNavBar.height,
          decoration: BoxDecoration(
            color: (dark ? const Color(0xFF1A1229) : Colors.white).withValues(alpha: dark ? 0.62 : 0.68),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.10 : 0.65)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slot = (constraints.maxWidth - pad * 2) / n;
              return AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final (l, r) = _edges();
                  final t = _c.isAnimating ? _c.value : 0.0;
                  // Squash vertically while stretched, like a moving droplet.
                  final squash = math.sin(t * math.pi) * 0.10;
                  final selectorH = (LiquidNavBar.height - pad * 2) * (1 - squash);
                  return Stack(
                    children: [
                      Positioned(
                        left: pad + l * slot + 2,
                        width: math.max(0, (r - l) * slot - 4),
                        top: (LiquidNavBar.height - selectorH) / 2,
                        height: selectorH,
                        child: _GlassSelector(dark: dark, scheme: scheme, stretch: t),
                      ),
                      Positioned.fill(
                        left: pad,
                        right: pad,
                        child: Row(
                          children: [
                            for (var i = 0; i < n; i++)
                              Expanded(
                                child: _NavItem(
                                  item: widget.items[i],
                                  highlight: (math.min(r, i + 1.0) - math.max(l, i.toDouble())).clamp(0.0, 1.0),
                                  onTap: () => _tap(i),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GlassSelector extends StatelessWidget {
  const _GlassSelector({required this.dark, required this.scheme, required this.stretch});

  final bool dark;
  final ColorScheme scheme;
  final double stretch;

  @override
  Widget build(BuildContext context) {
    final glow = 0.22 + 0.18 * math.sin(stretch * math.pi);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.primary.withValues(alpha: dark ? 0.30 : 0.18),
            scheme.primary.withValues(alpha: dark ? 0.16 : 0.08),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.22 : 0.85), width: 1.1),
        boxShadow: [
          BoxShadow(color: scheme.primary.withValues(alpha: glow), blurRadius: 18, spreadRadius: -2),
        ],
      ),
      child: Align(
        alignment: Alignment.topCenter,
        // Specular highlight along the top edge.
        child: FractionallySizedBox(
          widthFactor: 0.82,
          heightFactor: 0.42,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20), bottom: Radius.circular(40)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white.withValues(alpha: dark ? 0.16 : 0.55), Colors.white.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.item, required this.highlight, required this.onTap});

  final LiquidNavItem item;
  final double highlight;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final h = widget.highlight;
    final color = Color.lerp(scheme.onSurfaceVariant, scheme.primary, h)!;
    final icon = Icon(h > 0.5 ? widget.item.selectedIcon : widget.item.icon, color: color, size: 24);

    return Semantics(
      button: true,
      selected: h > 0.5,
      label: widget.item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.88 : 1 + 0.06 * h,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Badge(
                isLabelVisible: widget.item.badge > 0,
                label: Text('${widget.item.badge}'),
                child: icon,
              ),
              const SizedBox(height: 3),
              Text(
                widget.item.label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontSize: 11.5,
                  fontWeight: FontWeight.lerp(FontWeight.w600, FontWeight.w800, h),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
