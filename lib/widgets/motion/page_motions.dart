import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion_core.dart';

/// Which page a glyph belongs to.
enum PageGlyphKind { downloads, history, settings }

// ───── Animated page icons (same frame as the living logo) ─────

/// Downloads: an arrow drops into the tray, the tray squashes, the arrow
/// sinks in and the next one arrives (3 s).
class DownloadsMotion extends StatelessWidget {
  const DownloadsMotion({super.key, this.size = 136});

  final double size;

  @override
  Widget build(BuildContext context) => MotionCanvas(size: size, painter: paintDownloadsMotion, label: 'Downloads');
}

/// History: the clock's hands keep turning while the rewind arrow circles
/// back.
class HistoryMotion extends StatelessWidget {
  const HistoryMotion({super.key, this.size = 136});

  final double size;

  @override
  Widget build(BuildContext context) => MotionCanvas(size: size, painter: paintHistoryMotion, label: 'History');
}

/// Settings: two meshing gears turning.
class SettingsMotion extends StatelessWidget {
  const SettingsMotion({super.key, this.size = 136});

  final double size;

  @override
  Widget build(BuildContext context) => MotionCanvas(size: size, painter: paintSettingsMotion, label: 'Settings');
}

/// Paints the shared frame (glow, ring, floating tile) and hands the tile's
/// glyph box to [glyph]. [ringScale] pulses the ring.
void _framed(
  Canvas c,
  Size size,
  MotionState s,
  void Function(Canvas c, Rect box, RRect tile, double? t) glyph, {
  double ringScale = 1,
}) {
  final colors = MotionColors(s.dark);
  final k = size.width / 136;
  final t = s.still ? null : s.t;
  paintGlow(c, size, colors, t);
  paintRing(c, size, colors, t, scale: ringScale);
  c.save();
  final (dy, deg) = floatOffset(t);
  transformAround(c, size.center(Offset.zero), dy: dy * k, degrees: deg);
  final tile = paintTile(c, size, colors);
  final side = tile.width * 0.6;
  glyph(c, Rect.fromCenter(center: tile.center, width: side, height: side), tile, t);
  c.restore();
}

void paintDownloadsMotion(Canvas c, Size size, MotionState s) {
  final p = s.still ? null : loopPercent(s.t, 3);
  final ring = p == null
      ? 1.0
      : keyframes(const [Kf(0, 1), Kf(24, 1), Kf(28, 1.06), Kf(40, 1), Kf(100, 1)], p, curve: Curves.easeOut);
  _framed(c, size, s, ringScale: ring, (c, box, tile, t) {
    if (p == null) {
      drawDownloadGlyph(c, box);
      return;
    }
    drawDownloadGlyph(
      c,
      box,
      clip: tile,
      arrowDy: keyframes(const [
        Kf(0, -0.62, Cubic(0.3, 0, 0.2, 1)),
        Kf(24, 0.06),
        Kf(30, -0.03),
        Kf(36, 0),
        Kf(74, 0, Curves.easeIn),
        Kf(90, 0.08),
        Kf(100, 0.08),
      ], p),
      arrowOpacity: keyframes(const [Kf(0, 0), Kf(8, 1), Kf(74, 1), Kf(90, 0), Kf(100, 0)], p),
      arrowScale: keyframes(const [Kf(0, 1), Kf(74, 1, Curves.easeIn), Kf(90, 0.55), Kf(100, 0.55)], p),
      traySx: keyframes(const [Kf(0, 1), Kf(22, 1), Kf(26, 1.1), Kf(31, 0.97), Kf(36, 1), Kf(100, 1)], p),
      traySy: keyframes(const [Kf(0, 1), Kf(22, 1), Kf(26, 0.78), Kf(31, 1.06), Kf(36, 1), Kf(100, 1)], p),
    );
  });
}

void paintHistoryMotion(Canvas c, Size size, MotionState s) {
  _framed(c, size, s, (c, box, tile, t) {
    // Continuous turns: no loop seam. The arrow rewinds once every 16 s,
    // the minute hand turns every 6 s, the hour hand every 72 s.
    final seconds = t ?? 0;
    drawHistoryGlyph(
      c,
      box,
      arcTurns: -seconds / 16,
      minuteTurns: seconds / 6 + 1 / 6,
      hourTurns: seconds / 72 - 1 / 6,
    );
  });
}

void paintSettingsMotion(Canvas c, Size size, MotionState s) {
  _framed(c, size, s, (c, box, tile, t) => drawGearsGlyph(c, box, turns: (t ?? 0) / 10));
}

// ───── Static header icon ─────

/// The big icon next to a page heading: the page's glyph on the brand tile.
class PageGlyph extends StatelessWidget {
  const PageGlyph(this.kind, {super.key, this.size = 48});

  final PageGlyphKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: tileGradient,
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: MotionColors(dark).brand.withValues(alpha: dark ? 0.45 : 0.3),
            blurRadius: size * 0.36,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      child: CustomPaint(painter: _GlyphPainter(kind)),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.kind);

  final PageGlyphKind kind;

  @override
  void paint(Canvas c, Size size) {
    final side = size.width * 0.6;
    final box = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    switch (kind) {
      case PageGlyphKind.downloads:
        drawDownloadGlyph(c, box);
      case PageGlyphKind.history:
        drawHistoryGlyph(c, box, arcTurns: 0, minuteTurns: 1 / 6, hourTurns: -1 / 6);
      case PageGlyphKind.settings:
        drawGearsGlyph(c, box, turns: 0);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.kind != kind;
}

// ───── Glyphs (white, drawn in a square box) ─────

Paint _stroke(double width) => Paint()
  ..color = Colors.white
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

/// Download arrow over a tray. Offsets are fractions of the box.
void drawDownloadGlyph(
  Canvas c,
  Rect box, {
  RRect? clip,
  double arrowDy = 0,
  double arrowOpacity = 1,
  double arrowScale = 1,
  double traySx = 1,
  double traySy = 1,
}) {
  final w = box.width;
  Offset pt(double x, double y) => Offset(box.left + w * x, box.top + w * y);
  final stroke = w * 0.13;

  // Tray, squashing from its base.
  c.save();
  final base = pt(0.5, 0.86);
  c.translate(base.dx, base.dy);
  c.scale(traySx, traySy);
  c.translate(-base.dx, -base.dy);
  c.drawPath(
    Path()
      ..moveTo(pt(0.12, 0.6).dx, pt(0.12, 0.6).dy)
      ..lineTo(pt(0.12, 0.86).dx, pt(0.12, 0.86).dy)
      ..lineTo(pt(0.88, 0.86).dx, pt(0.88, 0.86).dy)
      ..lineTo(pt(0.88, 0.6).dx, pt(0.88, 0.6).dy),
    _stroke(stroke),
  );
  c.restore();

  if (arrowOpacity <= 0) return;
  c.save();
  if (clip != null) c.clipRRect(clip);
  final pivot = pt(0.5, 0.62);
  c.translate(0, arrowDy * w);
  c.translate(pivot.dx, pivot.dy);
  c.scale(arrowScale);
  c.translate(-pivot.dx, -pivot.dy);
  final arrow = _stroke(stroke)..color = Colors.white.withValues(alpha: arrowOpacity);
  c.drawLine(pt(0.5, 0.08), pt(0.5, 0.6), arrow);
  c.drawPath(
    Path()
      ..moveTo(pt(0.27, 0.38).dx, pt(0.27, 0.38).dy)
      ..lineTo(pt(0.5, 0.62).dx, pt(0.5, 0.62).dy)
      ..lineTo(pt(0.73, 0.38).dx, pt(0.73, 0.38).dy),
    arrow,
  );
  c.restore();
}

/// A clock inside a rewind arrow ("history"). Angles are in turns.
void drawHistoryGlyph(
  Canvas c,
  Rect box, {
  required double arcTurns,
  required double minuteTurns,
  required double hourTurns,
}) {
  final w = box.width;
  final center = box.center;
  final r = w * 0.4;
  final stroke = w * 0.11;

  // Rewind arrow: a 300° arc with its head pointing counter-clockwise.
  c.save();
  c.translate(center.dx, center.dy);
  c.rotate(arcTurns * 2 * math.pi);
  final start = math.pi * 0.82; // gap on the left, like a history icon
  const sweep = math.pi * 2 * 300 / 360;
  c.drawArc(Rect.fromCircle(center: Offset.zero, radius: r), start, sweep, false, _stroke(stroke));
  final tip = Offset(math.cos(start), math.sin(start)) * r;
  final tangent = Offset(math.sin(start), -math.cos(start)); // counter-clockwise direction
  final normal = Offset(math.cos(start), math.sin(start));
  final head = Path()
    ..moveTo(tip.dx + tangent.dx * w * 0.16, tip.dy + tangent.dy * w * 0.16)
    ..lineTo(tip.dx + normal.dx * w * 0.14, tip.dy + normal.dy * w * 0.14)
    ..lineTo(tip.dx - normal.dx * w * 0.14, tip.dy - normal.dy * w * 0.14)
    ..close();
  c.drawPath(head, Paint()..color = Colors.white);
  c.restore();

  // Hands.
  void hand(double turns, double length, double width) {
    final a = turns * 2 * math.pi - math.pi / 2;
    c.drawLine(center, center + Offset(math.cos(a), math.sin(a)) * length, _stroke(width));
  }

  hand(hourTurns, r * 0.42, stroke * 0.95);
  hand(minuteTurns, r * 0.66, stroke * 0.8);
  c.drawCircle(center, stroke * 0.62, Paint()..color = Colors.white);
}

// Tooth counts match the gears' sizes (10 : 6 ≈ 0.338 : 0.209 pitch radius),
// so the teeth keep the same spacing and mesh without slipping.
const _bigTeeth = 10;
const _smallTeeth = 6;
final Path _bigGear = _gear(teeth: _bigTeeth, outer: 1, inner: 0.78, hole: 0.34);
final Path _smallGear = _gear(teeth: _smallTeeth, outer: 1, inner: 0.74, hole: 0.34);

/// A gear of radius 1 around the origin, with a hole.
Path _gear({required int teeth, required double outer, required double inner, required double hole}) {
  final path = Path()..fillType = PathFillType.evenOdd;
  final step = 2 * math.pi / teeth;
  Offset polar(double r, double a) => Offset(math.cos(a) * r, math.sin(a) * r);
  for (var i = 0; i < teeth; i++) {
    final a = i * step;
    final points = [
      polar(inner, a - step * 0.5),
      polar(inner, a - step * 0.24),
      polar(outer, a - step * 0.15),
      polar(outer, a + step * 0.15),
      polar(inner, a + step * 0.24),
    ];
    for (final (j, p) in points.indexed) {
      if (i == 0 && j == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
  }
  path.close();
  path.addOval(Rect.fromCircle(center: Offset.zero, radius: hole));
  return path;
}

/// A big gear meshing with a small one. [turns] of the big gear.
void drawGearsGlyph(Canvas c, Rect box, {required double turns}) {
  final w = box.width;
  final fill = Paint()..color = Colors.white;
  void gear(Path path, Offset center, double radius, double angle) {
    c.save();
    c.translate(center.dx, center.dy);
    c.rotate(angle);
    c.scale(radius);
    c.drawPath(path, fill);
    c.restore();
  }

  final angle = turns * 2 * math.pi;
  final bigCenter = box.topLeft + Offset(w * 0.4, w * 0.42);
  // Centres 0.566 w apart: teeth reach into each other's gaps without
  // touching the other gear's root (big tip 0.38 + small root 0.178 ≤ 0.566).
  final smallCenter = box.topLeft + Offset(w * 0.8, w * 0.82);
  gear(_bigGear, bigCenter, w * 0.38, angle);
  // The small gear turns the other way, faster by the tooth ratio. Its phase
  // puts a gap between two teeth wherever a big-gear tooth points at it.
  const ratio = _bigTeeth / _smallTeeth;
  const smallStep = 2 * math.pi / _smallTeeth;
  final contact = (smallCenter - bigCenter).direction;
  final phase = contact + math.pi + contact * ratio - smallStep / 2;
  gear(_smallGear, smallCenter, w * 0.24, -angle * ratio + phase);
}
