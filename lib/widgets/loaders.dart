import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// FetchNet's loading animation: a breathing comet arc chasing around a
/// counter-rotating inner arc, with a glowing spark at its head and a
/// pulsing core. Used everywhere instead of the stock spinner.
class EnergyLoader extends StatefulWidget {
  const EnergyLoader({super.key, this.size = 40, this.onColor = false});

  final double size;

  /// White variant for use on the violet gradient (buttons).
  final bool onColor;

  @override
  State<EnergyLoader> createState() => _EnergyLoaderState();
}

class _EnergyLoaderState extends State<EnergyLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final head = widget.onColor ? Colors.white : AppColors.orchid;
    final body = widget.onColor ? Colors.white : scheme.primary;
    return Semantics(
      label: 'Loading',
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(painter: _EnergyPainter(_c, head: head, body: body, onColor: widget.onColor)),
        ),
      ),
    );
  }
}

/// Geometry of the loader's comet arc at cycle position `t` (0..1).
///
/// The head surges ahead in the first part of the cycle while the tail
/// trails; then the tail catches up. Both always move forward (a steady base
/// rotation keeps going even while one end eases), and one cycle advances
/// both ends by exactly two full turns with the same speed at the start and
/// end, so the loop has no visible seam or "restart".
class EnergyArc {
  EnergyArc._();

  static const _tau = math.pi * 2;

  /// How far the head pulls ahead of the tail at most.
  static const _stretch = math.pi * 1.5;

  /// Shortest arc, so the comet never vanishes.
  static const _minSweep = math.pi * 0.14;

  /// Steady rotation per cycle; with [_stretch] it adds up to two turns.
  static const _base = _tau * 2 - _stretch;

  // Smootherstep has zero speed and acceleration at both ends, so the eased
  // surges blend into the steady rotation without any kink at the loop point
  // (the stock easeInOutCubic is a Bézier with a non-zero starting slope).
  static const _headCurve = Interval(0.0, 0.6, curve: _SmootherStep());
  static const _tailCurve = Interval(0.4, 1.0, curve: _SmootherStep());

  /// Start angle (tail) and sweep of the arc, in radians.
  static ({double start, double sweep}) at(double t) {
    final base = _base * t;
    final head = base + _stretch * _headCurve.transform(t);
    final tail = base + _stretch * _tailCurve.transform(t);
    return (start: tail % _tau, sweep: _minSweep + head - tail);
  }
}

/// 6t⁵ − 15t⁴ + 10t³.
class _SmootherStep extends Curve {
  const _SmootherStep();

  @override
  double transformInternal(double t) => t * t * t * (t * (t * 6 - 15) + 10);
}

class _EnergyPainter extends CustomPainter {
  _EnergyPainter(this.anim, {required this.head, required this.body, required this.onColor}) : super(repaint: anim);

  final Animation<double> anim;
  final Color head;
  final Color body;
  final bool onColor;

  @override
  void paint(Canvas canvas, Size size) {
    final t = anim.value;
    final r = size.shortestSide / 2;
    final c = size.center(Offset.zero);
    final stroke = math.max(1.6, r * 0.17);
    const tau = math.pi * 2;

    // Outer comet: head and tail chase each other (see [EnergyArc]).
    final arc = EnergyArc.at(t);
    final rot = arc.start;
    final sweep = arc.sweep;
    final outerRect = Rect.fromCircle(center: c, radius: r - stroke / 2);
    final cometShader = SweepGradient(
      startAngle: 0,
      endAngle: sweep,
      colors: [body.withValues(alpha: 0), body.withValues(alpha: 0.85), head],
      stops: const [0, 0.55, 1],
      transform: GradientRotation(rot),
    ).createShader(outerRect);
    canvas.drawArc(
      outerRect,
      rot,
      sweep,
      false,
      Paint()
        ..shader = cometShader
        ..style = PaintingStyle.stroke
        // Butt cap: a round tail cap would pick up the head colour (the
        // sweep gradient wraps around); the spark already rounds the head.
        ..strokeCap = StrokeCap.butt
        ..strokeWidth = stroke,
    );

    // Spark at the comet's head.
    final headAngle = rot + sweep;
    final spark = c + Offset(math.cos(headAngle), math.sin(headAngle)) * (r - stroke / 2);
    canvas.drawCircle(
      spark,
      stroke * 1.15,
      Paint()
        ..color = head.withValues(alpha: 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.9),
    );
    canvas.drawCircle(spark, stroke * 0.55, Paint()..color = onColor ? Colors.white : Colors.white.withValues(alpha: 0.95));

    // Inner arc turning the other way.
    final innerR = r * 0.56;
    final innerRot = -t * tau * 2;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: innerR),
      innerRot,
      math.pi * 0.7,
      false,
      Paint()
        ..color = body.withValues(alpha: onColor ? 0.55 : 0.4)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke * 0.7,
    );

    // Pulsing core.
    final pulse = 0.5 + 0.5 * math.sin(t * tau * 2);
    canvas.drawCircle(
      c,
      r * (0.16 + 0.07 * pulse),
      Paint()
        ..color = head.withValues(alpha: 0.35 + 0.35 * pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.12),
    );
    canvas.drawCircle(c, r * 0.09, Paint()..color = onColor ? Colors.white : head);
  }

  @override
  bool shouldRepaint(_EnergyPainter old) => old.head != head || old.body != body;
}

/// Progress bar in the brand gradient.
///
/// * `value == null`: an energized comet sweeping across the track.
/// * 1–99 %: a squiggly (travelling sine wave) bar.
/// * otherwise (0 % / 100 %): a plain bar. The wave smoothly flattens out
///   when a download reaches 100 %.
class GradientProgressBar extends StatefulWidget {
  const GradientProgressBar({super.key, required this.value, this.height = 8, this.wavy = true});

  final double? value;

  /// Thickness of the bar; the widget is taller to make room for the wave.
  final double height;

  /// Set false for non-download progress (e.g. page loading).
  final bool wavy;

  @override
  State<GradientProgressBar> createState() => _GradientProgressBarState();
}

class _GradientProgressBarState extends State<GradientProgressBar> with TickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  late final AnimationController _amp = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  late final AnimationController _value = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
  double _from = 0;
  double _to = 0;

  bool get _waving {
    final v = widget.value;
    return widget.wavy && v != null && v >= 0.01 && v < 0.995;
  }

  @override
  void initState() {
    super.initState();
    _to = _from = (widget.value ?? 0).clamp(0.0, 1.0);
    _amp.value = _waving ? 1 : 0;
    _value.value = 1;
    _amp.addStatusListener((_) => _syncTickers());
    _syncTickers();
  }

  @override
  void didUpdateWidget(GradientProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = (widget.value ?? 0).clamp(0.0, 1.0);
    if (next != _to) {
      _from = _current;
      _to = next;
      _value.forward(from: 0);
    }
    if (_waving) {
      _amp.forward();
    } else {
      _amp.reverse();
    }
    _syncTickers();
  }

  double get _current => _from + (_to - _from) * Curves.easeOut.transform(_value.value);

  void _syncTickers() {
    // Only tick while something moves: indeterminate, or a (fading) wave.
    final needsPhase = widget.value == null || _waving || _amp.value > 0;
    if (needsPhase && !_phase.isAnimating) {
      _phase.repeat();
    } else if (!needsPhase && _phase.isAnimating) {
      _phase.stop();
    }
  }

  @override
  void dispose() {
    _phase.dispose();
    _amp.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thickness = widget.height * 0.62;
    final ampMax = widget.wavy ? widget.height * 0.42 : 0.0;
    return RepaintBoundary(
      child: SizedBox(
        height: thickness + ampMax * 2 + 2,
        width: double.infinity,
        child: CustomPaint(
          painter: _BarPainter(
            repaint: Listenable.merge([_phase, _amp, _value]),
            phase: _phase,
            amp: _amp,
            value: () => widget.value == null ? null : _current,
            thickness: thickness,
            ampMax: ampMax,
            track: scheme.surfaceContainerHighest,
            dot: scheme.primary,
          ),
        ),
      ),
    );
  }
}

final _horizontalBrand = LinearGradient(
  colors: AppColors.brandGradient.colors,
  stops: AppColors.brandGradient.stops,
);

class _BarPainter extends CustomPainter {
  _BarPainter({
    required Listenable repaint,
    required this.phase,
    required this.amp,
    required this.value,
    required this.thickness,
    required this.ampMax,
    required this.track,
    required this.dot,
  }) : super(repaint: repaint);

  final Animation<double> phase;
  final Animation<double> amp;
  final double? Function() value;
  final double thickness;
  final double ampMax;
  final Color track;
  final Color dot;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final half = thickness / 2;
    final left = half;
    final right = size.width - half;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = thickness;
    // The brand gradient always spans just the coloured part (as the old flat
    // bar did), so its violet-to-orchid sweep is visible at any progress.
    Shader gradientOver(double from, double to) => _horizontalBrand.createShader(
          Rect.fromLTRB(from - half, 0, math.max(to + half, from + half + thickness * 6), size.height),
        );
    final v = value();

    if (v == null) {
      // Indeterminate: track + a glowing comet sweeping left to right.
      canvas.drawLine(Offset(left, cy), Offset(right, cy), line..color = track);
      final t = Curves.easeInOutCubic.transform(phase.value);
      final span = (right - left) * 0.38;
      final start = left - span + (right - left + span) * t;
      final a = start.clamp(left, right);
      final b = (start + span).clamp(left, right);
      if (b > a) {
        final shader = gradientOver(a, b);
        canvas.drawLine(
          Offset(a, cy),
          Offset(b, cy),
          Paint()
            ..shader = shader
            ..strokeWidth = thickness
            ..strokeCap = StrokeCap.round
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, thickness * 0.9),
        );
        canvas.drawLine(Offset(a, cy), Offset(b, cy), line..shader = shader);
      }
      return;
    }

    final end = left + (right - left) * v.clamp(0.0, 1.0);
    final gap = thickness * 1.3;
    final a = ampMax * Curves.easeInOut.transform(amp.value);

    // Remaining track, with a stop dot at the very end.
    if (end + gap < right) {
      canvas.drawLine(Offset(end + gap, cy), Offset(right, cy), Paint()
        ..color = track
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round);
    }
    if (v < 0.995) canvas.drawCircle(Offset(right, cy), half * 0.75, Paint()..color = dot);

    if (end <= left + 0.5) return;
    final active = Paint()
      ..shader = gradientOver(left, end)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = thickness;
    if (a < 0.05) {
      canvas.drawLine(Offset(left, cy), Offset(end, cy), active);
      return;
    }
    // Travelling sine wave whose amplitude tapers in at both ends.
    final wavelength = math.max(20.0, thickness * 6);
    final ph = phase.value * math.pi * 2;
    final ramp = wavelength * 0.6;
    final path = Path()..moveTo(left, cy);
    for (var x = left; x <= end; x += 1.5) {
      final taper = math.min(1.0, math.min((x - left) / ramp, (end - x) / ramp)).clamp(0.0, 1.0);
      path.lineTo(x, cy + math.sin((x / wavelength) * math.pi * 2 - ph) * a * taper);
    }
    path.lineTo(end, cy);
    canvas.drawPath(path, active);
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.track != track || old.dot != dot || old.thickness != thickness;
}
