import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/app_services.dart';

/// One clock for every animated icon. Each animation's phase comes from this
/// clock, not from when its page opened, so switching tabs or scrolling never
/// restarts or jumps an animation: it just carries on.
class MotionClock {
  MotionClock._();

  static final Stopwatch _watch = Stopwatch()..start();

  static double get seconds => _watch.elapsedMicroseconds / 1e6;
}

/// What a motion painter draws for one frame.
@immutable
class MotionState {
  const MotionState({required this.t, required this.still, required this.dark});

  /// [MotionClock] seconds.
  final double t;

  /// Settings → Show animations is off: draw the resting pose.
  final bool still;
  final bool dark;
}

typedef MotionPaint = void Function(Canvas canvas, Size size, MotionState state);

/// A keyframe, like CSS `@keyframes`: [at] in percent, [curve] eases the
/// segment that starts here (CSS `animation-timing-function` in a keyframe).
class Kf {
  const Kf(this.at, this.v, [this.curve]);

  final double at;
  final double v;
  final Curve? curve;
}

/// Value of [frames] at [percent] (0..100).
double keyframes(List<Kf> frames, double percent, {Curve curve = Curves.ease}) {
  if (percent <= frames.first.at) return frames.first.v;
  for (var i = 0; i < frames.length - 1; i++) {
    final a = frames[i];
    final b = frames[i + 1];
    if (percent <= b.at) {
      final span = b.at - a.at;
      if (span <= 0) return b.v;
      return a.v + (b.v - a.v) * (a.curve ?? curve).transform(((percent - a.at) / span).clamp(0.0, 1.0));
    }
  }
  return frames.last.v;
}

/// Position in a repeating cycle of [period] seconds, in percent.
double loopPercent(double seconds, double period) => (seconds % period + period) % period / period * 100;

/// CSS `cubic-bezier(0.34, 1.56, 0.64, 1)` and `cubic-bezier(0.22, 1, 0.36, 1)`.
const springCurve = Cubic(0.34, 1.56, 0.64, 1);
const expoOutCurve = Cubic(0.22, 1, 0.36, 1);

/// Hosts a [MotionPaint]. Light by design: a single [RepaintBoundary] that
/// repaints from a ticker (no widget rebuilds), pauses when its page is hidden
/// or it's off screen, and draws one still frame when animations are off.
class MotionCanvas extends StatefulWidget {
  const MotionCanvas({super.key, required this.size, required this.painter, this.label});

  final double size;
  final MotionPaint painter;
  final String? label;

  @override
  State<MotionCanvas> createState() => _MotionCanvasState();
}

class _MotionCanvasState extends State<MotionCanvas> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double> _time = ValueNotifier(MotionClock.seconds);
  ValueNotifier<bool>? _enabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_enabled == null) {
      _enabled = AppScope.of(context).showAnimations..addListener(_sync);
      _sync();
    }
  }

  void _sync() {
    final on = _enabled!.value;
    if (on && !_ticker.isActive) {
      _ticker.start();
    } else if (!on && _ticker.isActive) {
      _ticker.stop();
    }
    if (mounted) setState(() {});
  }

  void _tick(Duration _) {
    if (_onScreen()) _time.value = MotionClock.seconds;
  }

  /// Skips painting while scrolled out of view.
  bool _onScreen() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    final height = MediaQuery.sizeOf(context).height;
    return top < height && top + box.size.height > 0;
  }

  @override
  void dispose() {
    _enabled?.removeListener(_sync);
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = !(_enabled?.value ?? true);
    return Semantics(
      label: widget.label,
      image: widget.label != null,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: _MotionPainter(
              widget.painter,
              _time,
              still: still,
              dark: Theme.of(context).brightness == Brightness.dark,
            ),
          ),
        ),
      ),
    );
  }
}

class _MotionPainter extends CustomPainter {
  _MotionPainter(this.fn, this.time, {required this.still, required this.dark}) : super(repaint: still ? null : time);

  final MotionPaint fn;
  final ValueNotifier<double> time;
  final bool still;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) => fn(canvas, size, MotionState(t: time.value, still: still, dark: dark));

  @override
  bool shouldRepaint(_MotionPainter old) => old.still != still || old.dark != dark || old.fn != fn;
}

// ───── The shared "living" frame (FetchNet website, phone view) ─────

class MotionColors {
  const MotionColors(this.dark);

  final bool dark;

  Color get brand => dark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED);
  Color get brand2 => dark ? const Color(0xFFD946EF) : const Color(0xFFC026D3);
}

/// Soft radial glow behind the tile (`mark-glow`, 3.2 s).
void paintGlow(Canvas c, Size size, MotionColors colors, double? seconds) {
  final k = size.width / 136;
  final p = seconds == null ? 0.0 : loopPercent(seconds, 3.2);
  final opacity = keyframes(const [Kf(0, 1), Kf(50, 0.45), Kf(100, 1)], p, curve: Curves.easeInOut);
  final scale = keyframes(const [Kf(0, 1), Kf(50, 0.88), Kf(100, 1)], p, curve: Curves.easeInOut);
  final center = size.center(Offset.zero);
  final r = 62 * k * scale;
  c.drawCircle(
    center,
    r,
    Paint()
      ..shader = RadialGradient(
        colors: [colors.brand.withValues(alpha: 0.7 * opacity), colors.brand.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: r)),
  );
}

/// The dashed ring: 18 dashes, turning once every 14 s.
void paintRing(Canvas c, Size size, MotionColors colors, double? seconds, {double scale = 1}) {
  final k = size.width / 136;
  final center = size.center(Offset.zero);
  final radius = 62.2 * k * scale;
  final rotation = seconds == null ? 0.0 : (seconds / 14) * 2 * math.pi;
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 7.5 * k * scale
    ..color = colors.brand.withValues(alpha: 0.62);
  final rect = Rect.fromCircle(center: center, radius: radius);
  const dash = 5 * math.pi / 180;
  for (var i = 0; i < 18; i++) {
    c.drawArc(rect, -math.pi / 2 + rotation + i * 2 * math.pi / 18, dash, false, paint);
  }
}

/// Gentle bob of the tile (`mark-float`, 4 s): (dy in px, degrees).
(double, double) floatOffset(double? seconds) {
  if (seconds == null) return (0, 0);
  final p = loopPercent(seconds, 4);
  return (
    keyframes(const [Kf(0, 0), Kf(50, -5), Kf(100, 0)], p, curve: Curves.easeInOut),
    keyframes(const [Kf(0, 0), Kf(50, -3), Kf(100, 0)], p, curve: Curves.easeInOut),
  );
}

/// The gradient tile (92 px of 136) with its soft shadow and inner light.
/// Returns the tile's rounded rect (in the current canvas space).
RRect paintTile(Canvas c, Size size, MotionColors colors) {
  final k = size.width / 136;
  final side = 92 * k;
  final rect = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
  final rr = RRect.fromRectAndRadius(rect, Radius.circular(side * 0.26));
  // Drop shadow: box-shadow 0 16px 30px -12px.
  c.drawRRect(
    rr.deflate(12 * k).shift(Offset(0, 16 * k)),
    Paint()
      ..color = colors.brand.withValues(alpha: 0.6)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 11 * k),
  );
  c.drawRRect(rr, Paint()..shader = tileGradient.createShader(rect));
  // Inner light: a highlight along the top, a violet depth at the bottom.
  c.save();
  c.clipRRect(rr);
  c.drawRect(
    rect,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x59FFFFFF), Color(0x00FFFFFF), Color(0x00000000), Color(0x594C1D95)],
        stops: [0, 0.03, 0.7, 1],
      ).createShader(rect),
  );
  c.restore();
  return rr;
}

/// `linear-gradient(140deg, #a78bfa, #7c3aed 42%, #9333ea 70%, #c026d3)`.
const tileGradient = LinearGradient(
  begin: Alignment(-0.64, -0.77),
  end: Alignment(0.64, 0.77),
  colors: [Color(0xFFA78BFA), Color(0xFF7C3AED), Color(0xFF9333EA), Color(0xFFC026D3)],
  stops: [0, 0.42, 0.7, 1],
);

/// Rotates / moves the canvas around [center] (tile float, intro).
void transformAround(Canvas c, Offset center, {double dy = 0, double degrees = 0, double scale = 1}) {
  c.translate(center.dx, center.dy + dy);
  if (degrees != 0) c.rotate(degrees * math.pi / 180);
  if (scale != 1) c.scale(scale);
  c.translate(-center.dx, -center.dy);
}
