import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/theme.dart';
import 'art_palette.dart';

/// Whether the player may move things by itself: Settings → Show
/// animations, and the system's "remove animations" switch.
bool playerMotion(BuildContext context) =>
    AppScope.of(context).showAnimations.value && !MediaQuery.disableAnimationsOf(context);

/// The music player's background: a gradient in the cover's colours (or
/// FetchNet's, light or dark) with soft glows that drift slowly while
/// animations are on. Colours change with a gentle fade.
class PlayerBackground extends StatefulWidget {
  const PlayerBackground({super.key, required this.palette});

  final ArtPalette? palette;

  @override
  State<PlayerBackground> createState() => _PlayerBackgroundState();
}

class _PlayerBackgroundState extends State<PlayerBackground> with SingleTickerProviderStateMixin {
  // One slow loop; the glows follow curves of it that never quite repeat
  // within it, so the motion doesn't look mechanical.
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 40));
  ValueNotifier<bool>? _setting;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final setting = AppScope.of(context).showAnimations;
    if (setting != _setting) {
      _setting?.removeListener(_sync);
      _setting = setting..addListener(_sync);
    }
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    if (playerMotion(context)) {
      if (!_drift.isAnimating) _drift.repeat();
    } else {
      _drift.stop();
    }
  }

  @override
  void dispose() {
    _setting?.removeListener(_sync);
    _drift.dispose();
    super.dispose();
  }

  _BgColors _colorsFor(BuildContext context) {
    final p = widget.palette;
    if (p != null) {
      return _BgColors(
        top: p.top,
        bottom: p.bottom,
        glowA: Color.lerp(p.accent, p.top, 0.35)!.withValues(alpha: 0.55),
        glowB: Color.lerp(p.top, Colors.white, 0.12)!.withValues(alpha: 0.5),
        glowC: Color.lerp(p.accent, p.bottom, 0.55)!.withValues(alpha: 0.45),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final soft = AppColors.softGradient(dark ? Brightness.dark : Brightness.light).colors;
    return _BgColors(
      top: soft.first,
      bottom: soft.last,
      glowA: AppColors.purple.withValues(alpha: dark ? 0.42 : 0.24),
      glowB: AppColors.violetBright.withValues(alpha: dark ? 0.38 : 0.2),
      glowC: AppColors.orchid.withValues(alpha: dark ? 0.24 : 0.14),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: TweenAnimationBuilder<_BgColors>(
        tween: _BgColorsTween(end: _colorsFor(context)),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOut,
        builder: (context, colors, _) => CustomPaint(
          painter: _BackgroundPainter(colors: colors, drift: _drift),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _BgColors {
  const _BgColors({required this.top, required this.bottom, required this.glowA, required this.glowB, required this.glowC});

  final Color top;
  final Color bottom;
  final Color glowA;
  final Color glowB;
  final Color glowC;

  static _BgColors lerp(_BgColors a, _BgColors b, double t) => _BgColors(
        top: Color.lerp(a.top, b.top, t)!,
        bottom: Color.lerp(a.bottom, b.bottom, t)!,
        glowA: Color.lerp(a.glowA, b.glowA, t)!,
        glowB: Color.lerp(a.glowB, b.glowB, t)!,
        glowC: Color.lerp(a.glowC, b.glowC, t)!,
      );
}

class _BgColorsTween extends Tween<_BgColors> {
  _BgColorsTween({super.end});

  @override
  _BgColors lerp(double t) => _BgColors.lerp(begin ?? end!, end!, t);
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter({required this.colors, required this.drift}) : super(repaint: drift);

  final _BgColors colors;
  final Animation<double> drift;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final a = drift.value * 2 * math.pi;
    // The base: a gradient whose direction sways a little.
    final sway = math.sin(a) * 0.35;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-0.4 + sway, -1),
          end: Alignment(0.4 - sway, 1),
          colors: [colors.top, colors.bottom],
        ).createShader(rect),
    );
    final r = math.max(size.width, size.height);
    void glow(Color color, Offset center, double radius) {
      final c = Offset(center.dx * size.width, center.dy * size.height);
      canvas.drawCircle(
        c,
        radius * r,
        Paint()
          ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(
            Rect.fromCircle(center: c, radius: radius * r),
          ),
      );
    }

    glow(colors.glowA, Offset(0.15 + 0.18 * math.sin(a), 0.12 + 0.10 * math.cos(2 * a)), 0.62);
    glow(colors.glowB, Offset(0.92 + 0.12 * math.cos(a + 1.3), 0.45 + 0.14 * math.sin(a + 0.6)), 0.55);
    glow(colors.glowC, Offset(0.3 + 0.2 * math.sin(2 * a + 2.1), 0.95 + 0.06 * math.cos(a)), 0.6);
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => old.colors != colors;
}

/// A Material 3 Expressive seek bar: the played part is a wave (it flows
/// while playing and flattens out when paused), the rest a flat track
/// ending in a stop dot, and the thumb a tall pill. Drag or tap to seek.
class WavySeekBar extends StatefulWidget {
  const WavySeekBar({
    super.key,
    required this.value,
    required this.playing,
    required this.active,
    required this.inactive,
    required this.thumb,
    required this.onChangeStart,
    required this.onChanged,
    required this.onChangeEnd,
    this.label,
  });

  /// 0..1.
  final double value;
  final bool playing;
  final Color active;
  final Color inactive;
  final Color thumb;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  /// What a screen reader says ("1:02 of 3:45").
  final String? label;

  @override
  State<WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<WavySeekBar> with TickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  late final AnimationController _amplitude = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  late final AnimationController _press = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  bool _motion = true;

  static const _pad = 10.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = playerMotion(context);
    _sync();
  }

  @override
  void didUpdateWidget(WavySeekBar old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) _sync();
  }

  void _sync() {
    if (widget.playing) {
      _amplitude.forward();
      if (_motion && !_phase.isAnimating) _phase.repeat();
      if (!_motion) _phase.stop();
    } else {
      _amplitude.reverse();
      _phase.stop();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    _amplitude.dispose();
    _press.dispose();
    super.dispose();
  }

  double _fraction(Offset local, double width) => ((local.dx - _pad) / (width - 2 * _pad)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      slider: true,
      label: 'Seek',
      value: widget.label ?? '${(widget.value * 100).round()}%',
      increasedValue: '${((widget.value + 0.05).clamp(0, 1) * 100).round()}%',
      decreasedValue: '${((widget.value - 0.05).clamp(0, 1) * 100).round()}%',
      onIncrease: () => widget.onChangeEnd((widget.value + 0.05).clamp(0.0, 1.0)),
      onDecrease: () => widget.onChangeEnd((widget.value - 0.05).clamp(0.0, 1.0)),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) {
              _press.forward();
              widget.onChangeStart(_fraction(d.localPosition, w));
            },
            onHorizontalDragUpdate: (d) => widget.onChanged(_fraction(d.localPosition, w)),
            onHorizontalDragEnd: (_) {
              _press.reverse();
              widget.onChangeEnd(widget.value);
            },
            onHorizontalDragCancel: () => _press.reverse(),
            onTapDown: (d) => _press.forward(),
            onTapUp: (d) {
              _press.reverse();
              final f = _fraction(d.localPosition, w);
              widget.onChangeStart(f);
              widget.onChangeEnd(f);
            },
            onTapCancel: () => _press.reverse(),
            child: SizedBox(
              height: 40,
              width: double.infinity,
              child: CustomPaint(
                painter: _WavePainter(
                  value: widget.value,
                  phase: _phase,
                  amplitude: _amplitude,
                  press: _press,
                  active: widget.active,
                  inactive: widget.inactive,
                  thumb: widget.thumb,
                  pad: _pad,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.value,
    required this.phase,
    required this.amplitude,
    required this.press,
    required this.active,
    required this.inactive,
    required this.thumb,
    required this.pad,
  }) : super(repaint: Listenable.merge([phase, amplitude, press]));

  final double value;
  final Animation<double> phase;
  final Animation<double> amplitude;
  final Animation<double> press;
  final Color active;
  final Color inactive;
  final Color thumb;
  final double pad;

  static const _stroke = 4.0;
  static const _wavelength = 30.0;
  static const _height = 3.4;
  static const _gap = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final left = pad;
    final right = size.width - pad;
    final x = left + (right - left) * value.clamp(0.0, 1.0);
    final pressed = Curves.easeOut.transform(press.value);
    final thumbW = 4.0 + 2 * pressed;
    final gap = _gap + thumbW / 2;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;

    // Played: a wave that eases in from the start and flows to the right.
    final end = x - gap;
    if (end > left) {
      final amp = _height * Curves.easeInOut.transform(amplitude.value);
      final shift = phase.value * 2 * math.pi;
      final path = Path()..moveTo(left, cy);
      for (var px = left; px <= end; px += 1.5) {
        // Flat at the very start, so the wave grows out of the track.
        final ease = ((px - left) / 18).clamp(0.0, 1.0);
        path.lineTo(px, cy + amp * ease * math.sin((px - left) / _wavelength * 2 * math.pi - shift));
      }
      canvas.drawPath(path, line..color = active);
    }

    // Still to play: a flat track and a stop dot at the end.
    final start = x + gap;
    if (start < right - 6) {
      canvas.drawLine(Offset(start, cy), Offset(right - 6, cy), line..color = inactive);
    }
    canvas.drawCircle(Offset(right - 1, cy), 2, Paint()..color = active);

    // The thumb: a tall pill.
    final thumbH = 22.0 + 8 * pressed;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, cy), width: thumbW, height: thumbH), Radius.circular(thumbW)),
      Paint()..color = thumb,
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.value != value || old.active != active || old.inactive != inactive || old.thumb != thumb;
}
