import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_parsing/path_parsing.dart';

import 'motion_core.dart';

/// FetchNet's glyph split into its four parts, traced from the app icon
/// (same data as the website's LivingLogo, viewBox 709 × 791).
const _film = 'M50,552.41C28.11,547.72 8.82,529.52 2.32,507.41C0.75,502.09 0.54,494.32 0.23,429.5C-0.15,349.83 0.18,344.18 6.03,331.26C13.73,314.28 28.85,301.89 47.76,297.06C55.57,295.07 58.36,295 133.42,295L211,295L211,375.5L211,456L185.21,456C165.58,456 158.05,456.36 153.69,457.49C132.4,463.04 119,480.2 119,501.92C119,519.31 126.87,533.02 144.88,547C151.25,551.94 151.74,552.57 149.73,553.15C148.5,553.51 127.03,553.8 102,553.8C66.89,553.8 55.02,553.48 50,552.41ZM555,553.7C555,553.48 557.68,551.41 560.96,549.11C570.17,542.65 580.2,532.22 583.76,525.41C593.9,506.02 591.37,484.64 577.06,468.72C571.88,462.96 567.78,460.21 559.5,456.95C553.8,454.7 552.09,454.57 525.81,454.21L498.12,453.84L497.66,451.17C497.27,448.9 497.43,325.77 497.86,302.72L498,294.94L579.25,295.22L660.5,295.5L667.21,297.78C675.72,300.67 687.62,308.6 693.46,315.28C699.45,322.13 704.6,332.12 707.03,341.61C708.91,348.95 709,352.92 708.98,424.41C708.97,485.71 708.7,500.74 707.53,506.26C704.65,519.87 693.86,535.26 681.38,543.53C678.36,545.54 672.2,548.6 667.7,550.33L659.5,553.48L607.25,553.8C578.51,553.97 555,553.93 555,553.7Z';
const _tray = 'M103.46,789.93C79.47,785.89 58.71,769.57 49.84,747.77C44.6,734.89 44,729.2 44,692.25C44,665.03 44.3,657.27 45.54,652.52C49.97,635.51 64.47,622.61 82.26,619.84C101.76,616.81 121.82,628.31 129.12,646.69C131.27,652.11 131.46,654.33 131.96,680.08L132.5,707.66L135.54,712.58C139.34,718.74 147.06,723.63 154.36,724.49C157.19,724.82 249.27,724.96 359,724.8C581.72,724.47 561.73,725.17 569.2,717.37C576,710.26 576.35,708.56 577.04,679C577.64,653.24 577.74,652.32 580.34,645.97C589.67,623.27 617.42,612.92 639.87,623.78C648.14,627.78 658.15,638.13 660.96,645.58C664.69,655.49 665.18,662.28 664.75,697.77C664.29,735.87 664.1,737.16 656.51,752.63C646.46,773.12 626.62,786.98 603.13,789.92C592.97,791.2 111.03,791.2 103.46,789.93Z';
const _arrow = 'M340.26,702.91C334.76,701.17 332.66,699.65 322.71,690.22C293.37,662.41 148.55,517.04 146.16,513C143.96,509.28 143.5,507.28 143.5,501.5C143.5,495.45 143.91,493.86 146.49,489.78C148.46,486.66 151.17,484.12 154.49,482.28L159.5,479.5L195.63,479.2L231.75,478.91L232.37,475.2C232.7,473.17 232.99,432.58 233.01,385C233.04,290.03 232.99,290.92 239.06,278.88C243.17,270.73 255.17,258.62 264.03,253.7C277.15,246.41 276.04,246.5 355,246.5C433.82,246.5 431.14,246.29 445.23,253.69C458.31,260.56 467.37,271.29 473.38,286.98C475.46,292.42 475.5,293.86 475.99,386.5L476.5,480.5L513,481L549.5,481.5L554.22,484.28C563.82,489.92 567.44,502.78 561.92,511.67C560.59,513.81 547.8,527.02 533.5,541.03C519.2,555.04 477.65,595.98 441.17,632C404.68,668.02 373.08,698.55 370.95,699.83C362.19,705.1 350.77,706.24 340.26,702.91ZM324.57,479.11C326.81,478.09 341.21,469.26 356.57,459.5C371.93,449.73 392.25,436.81 401.72,430.79C413.5,423.3 419.58,418.81 420.97,416.55C423.39,412.64 423.71,404.26 421.6,400.2C419,395.21 420.67,396.29 366.5,364.46C358.25,359.61 346.05,352.38 339.39,348.4C325.18,339.9 320.84,338.43 314.79,340.06C309.45,341.49 303.57,347.28 302.12,352.52C300.37,358.81 300.67,464.33 302.45,469.32C304.23,474.3 306.6,476.87 311.5,479.12C316.55,481.44 319.45,481.43 324.57,479.11Z';
const _clapper = 'M3.27,245.8C3.73,190.54 3.72,190.64 10.26,173.2C15.25,159.94 22.15,149.11 32,139.1C51.08,119.7 64.71,113.8 115,103.15C122.97,101.46 138.95,98.01 150.5,95.49C162.05,92.98 176.9,89.83 183.5,88.51C190.1,87.18 207.2,83.57 221.5,80.49C235.8,77.4 251.55,74.05 256.5,73.05C261.45,72.04 298.35,64.19 338.5,55.61C378.65,47.02 416.9,38.84 423.5,37.44C430.1,36.04 442.7,33.31 451.5,31.37C460.3,29.44 474.93,26.33 484,24.47C493.07,22.62 510.85,18.82 523.5,16.03C536.15,13.25 552.8,9.64 560.5,8.02C568.2,6.4 580.12,3.89 587,2.43C597.45,0.22 601.14,-0.13 609.5,0.31C644.87,2.16 674.59,27.98 680.51,62C682.85,75.44 684.29,100.98 683.07,107.58C681.04,118.63 674.44,129.15 665.44,135.65C655.84,142.61 655.3,142.76 598,154.62C556.94,163.13 502.29,174.33 484,178C476.02,179.6 450.38,184.77 427,189.49C368.01,201.4 271.54,220.23 250,224.03C244.22,225.05 233.2,227.07 225.5,228.51C217.8,229.95 205.2,232.22 197.5,233.56C189.8,234.9 172.03,238.03 158,240.5C143.97,242.98 121.03,247 107,249.45C92.97,251.89 76.23,255 69.8,256.37C46.21,261.38 27.77,271.18 11.68,287.27L2.85,296.09L3.27,245.8ZM188,206.93C239.99,196.03 250.69,193.74 255,192.57L259.5,191.35L243.5,174.93C234.7,165.89 218.85,149.44 208.28,138.37L189.06,118.25L184.78,119.05C180.76,119.81 146.3,127.28 132,130.5C101.29,137.41 93.4,139.3 92.78,139.88C91.82,140.77 99.38,149.5 131,184.02C157.42,212.86 157.51,212.95 161,212.4C162.93,212.1 175.07,209.64 188,206.93ZM362.34,172.95C373.65,170.66 437.95,156.41 442.23,155.24C443.73,154.84 444.93,154.05 444.9,153.5C444.84,152.59 428.93,135.89 389.68,95.56L375.14,80.62L369.32,81.76C366.12,82.38 358.55,84 352.5,85.35C346.45,86.7 331.6,89.91 319.5,92.48C307.4,95.05 296.15,97.54 294.5,98.01C292.85,98.48 288.91,99.38 285.74,100.01L279.97,101.15L281.85,103.54C282.88,104.85 298.23,121.47 315.96,140.46C337.47,163.5 348.86,175 350.19,175C351.29,175 356.76,174.08 362.34,172.95ZM548.43,133.53C556.72,131.62 572.95,128.02 584.5,125.54C610.99,119.86 628,115.84 628,115.28C628,114.95 573.75,56.96 561.11,43.79L558.5,41.07L543,44.55C534.48,46.47 513.34,51.19 496.03,55.04C478.71,58.9 464.22,62.38 463.81,62.79C462.97,63.63 471.77,73.35 505.92,109.35C518.89,123.02 529.86,134.83 530.3,135.6C531.37,137.48 531.23,137.49 548.43,133.53Z';

class _PathBuilder extends PathProxy {
  final Path path = Path()..fillType = PathFillType.evenOdd;

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) =>
      path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void close() => path.close();
}

class _Part {
  _Part(String data) : path = _parse(data) {
    bounds = path.getBounds();
  }

  final Path path;
  late final Rect bounds;

  static Path _parse(String data) {
    final builder = _PathBuilder();
    writeSvgPathDataToPath(data, builder);
    return builder.path;
  }

  /// A point of the part's own box (CSS `transform-box: fill-box`).
  Offset at(double fx, double fy) => Offset(bounds.left + bounds.width * fx, bounds.top + bounds.height * fy);
}

final _parts = (
  film: _Part(_film),
  tray: _Part(_tray),
  arrow: _Part(_arrow),
  clapper: _Part(_clapper),
);

/// The moment the logo first animated this session: the parts assemble
/// once, then the 4.8 s scene loops on the shared clock.
double? _introAt;

const _loop = 4.8;
const _after = 1.3;

/// FetchNet's "living logo" from the website (phone view): the glyph
/// assembles, then the clapper snaps (spark + ring pulse), the arrow winds up
/// and drops into the tray, and the tray squashes on impact.
class LivingLogo extends StatelessWidget {
  const LivingLogo({super.key, this.size = 136});

  final double size;

  @override
  Widget build(BuildContext context) => MotionCanvas(size: size, painter: paintLivingLogo, label: 'FetchNet');
}

void paintLivingLogo(Canvas c, Size size, MotionState s) {
  final colors = MotionColors(s.dark);
  final k = size.width / 136;
  final center = size.center(Offset.zero);

  // Seconds since the logo first appeared; null = resting pose.
  double? life;
  if (!s.still) {
    _introAt ??= s.t;
    life = s.t - _introAt!;
  } else {
    _introAt ??= -100; // animations off at first sight: no assembly later
  }
  final loopP = (life != null && life >= _after) ? loopPercent(life - _after, _loop) : null;

  paintGlow(c, size, colors, life);
  paintRing(
    c,
    size,
    colors,
    life,
    scale: loopP == null
        ? 1
        : keyframes(const [Kf(0, 1), Kf(21, 1), Kf(24, 1.07), Kf(34, 1), Kf(100, 1)], loopP, curve: Curves.easeOut),
  );
  if (loopP != null) _paintSparks(c, k, colors, loopP);

  // ───── Tile: pops in, then floats ─────
  c.save();
  var tileOpacity = 1.0;
  if (life != null && life < 1.2) {
    final e = springCurve.transform((life / 0.7).clamp(0.0, 1.0));
    tileOpacity = (life / 0.7).clamp(0.0, 1.0);
    transformAround(c, center, scale: 0.4 + 0.6 * e, degrees: -18 * (1 - e));
  } else {
    final (dy, deg) = floatOffset(life == null ? null : life - 1.2);
    transformAround(c, center, dy: dy * k, degrees: deg);
  }
  if (tileOpacity < 1) {
    c.saveLayer(Rect.fromCircle(center: center, radius: 70 * k), Paint()..color = Color.fromRGBO(0, 0, 0, tileOpacity));
  }
  paintTile(c, size, colors);

  // ───── Glyph: 62% of the tile ─────
  final glyphW = 92 * k * 0.62;
  final scale = glyphW / 709;
  final glyphH = 791 * scale;
  c.translate(center.dx - glyphW / 2, center.dy - glyphH / 2);
  c.scale(scale);

  // Intro progress of a part: 0 before its delay, eased 0..1 after.
  double intro(double delay, double duration, Curve curve) {
    if (life == null) return 1;
    return curve.transform(((life - delay) / duration).clamp(0.0, 1.0));
  }

  double opacityAfter(double delay, double duration) {
    if (life == null) return 1;
    return ((life - delay) / duration).clamp(0.0, 1.0);
  }

  // Film: scaleX 0.3 → 1, then a small squash when the clapper snaps.
  {
    final part = _parts.film;
    double sx = 1, sy = 1;
    if (loopP != null) {
      sx = keyframes(const [Kf(0, 1), Kf(21.5, 1), Kf(23, 1.035), Kf(27, 1), Kf(100, 1)], loopP);
      sy = keyframes(const [Kf(0, 1), Kf(21.5, 1), Kf(23, 0.97), Kf(27, 1), Kf(100, 1)], loopP);
    } else {
      sx = 0.3 + 0.7 * intro(0.25, 0.6, expoOutCurve);
    }
    _drawPart(c, part, opacityAfter(0.25, 0.6), origin: part.at(0.5, 0.5), sx: sx, sy: sy, k: k / scale);
  }

  // Tray: rises in, then squashes when the arrow lands.
  {
    final part = _parts.tray;
    double sx = 1, sy = 1, dy = 0;
    if (loopP != null) {
      sx = keyframes(const [Kf(0, 1), Kf(45, 1), Kf(47, 1.1), Kf(51, 0.97), Kf(55, 1), Kf(100, 1)], loopP);
      sy = keyframes(const [Kf(0, 1), Kf(45, 1), Kf(47, 0.74), Kf(51, 1.08), Kf(55, 1), Kf(100, 1)], loopP);
    } else {
      dy = 0.6 * part.bounds.height * (1 - intro(0.4, 0.6, springCurve));
    }
    _drawPart(c, part, opacityAfter(0.4, 0.6), origin: part.at(0.5, 1), sx: sx, sy: sy, dy: dy, k: k / scale);
  }

  // Arrow: drops in, then winds up and drops into the tray.
  {
    final part = _parts.arrow;
    double dy;
    if (loopP != null) {
      dy = part.bounds.height *
          keyframes(const [
            Kf(0, 0),
            Kf(32, 0, Cubic(0.3, 0, 0.2, 1)),
            Kf(40, -0.13, Cubic(0.6, 0, 1, 0.5)),
            Kf(46, 0.09),
            Kf(50, -0.03),
            Kf(54, 0),
            Kf(100, 0),
          ], loopP);
    } else {
      dy = -0.8 * part.bounds.height * (1 - intro(0.55, 0.65, springCurve));
    }
    _drawPart(c, part, opacityAfter(0.55, 0.65), origin: part.at(0.5, 0.5), dy: dy, k: k / scale);
  }

  // Clapper: swings shut, then lifts and SNAPS on its hinge every loop.
  {
    final part = _parts.clapper;
    double deg;
    if (loopP != null) {
      deg = keyframes(const [
        Kf(0, 0),
        Kf(6, 0, Cubic(0.3, 0, 0.2, 1)),
        Kf(15, -20),
        Kf(19, -20, Cubic(0.7, 0, 1, 0.6)),
        Kf(22, 3),
        Kf(24.5, -1.5),
        Kf(27, 0),
        Kf(100, 0),
      ], loopP);
    } else {
      deg = -75 * (1 - intro(0.7, 0.7, springCurve));
    }
    _drawPart(c, part, opacityAfter(0.7, 0.7), origin: part.at(0, 1), degrees: deg, k: k / scale);
  }

  if (tileOpacity < 1) c.restore();
  c.restore();
}

final _white = Paint()..color = Colors.white;
final _shade = Paint()..color = const Color(0x402E1065);

void _drawPart(
  Canvas c,
  _Part part,
  double opacity, {
  required Offset origin,
  required double k,
  double sx = 1,
  double sy = 1,
  double dy = 0,
  double degrees = 0,
}) {
  if (opacity <= 0) return;
  c.save();
  c.translate(origin.dx, origin.dy + dy);
  if (degrees != 0) c.rotate(degrees * math.pi / 180);
  if (sx != 1 || sy != 1) c.scale(sx, sy);
  c.translate(-origin.dx, -origin.dy);
  // drop-shadow(0 2px 3px rgb(46 16 101 / .35)), approximated without blur.
  _shade.color = Color.fromRGBO(46, 16, 101, 0.25 * opacity);
  c.drawPath(part.path.shift(Offset(0, 1.6 * k)), _shade);
  _white.color = Color.fromRGBO(255, 255, 255, opacity);
  c.drawPath(part.path, _white);
  c.restore();
}

/// Three sparks flying off the clapper's tip when it snaps.
void _paintSparks(Canvas c, double k, MotionColors colors, double p) {
  final opacity = keyframes(const [Kf(0, 0), Kf(21, 0), Kf(23.5, 1), Kf(31, 0), Kf(100, 0)], p, curve: Curves.easeOut);
  if (opacity <= 0) return;
  final ty = keyframes(const [Kf(0, 0), Kf(21, 0), Kf(23.5, -6), Kf(31, -14), Kf(100, -14)], p, curve: Curves.easeOut);
  final sy = keyframes(const [Kf(0, 0.2), Kf(21, 0.2), Kf(23.5, 1), Kf(31, 0.4), Kf(100, 0.4)], p, curve: Curves.easeOut);
  final anchor = Offset((136 - 17) * k, 17 * k);
  final bar = RRect.fromRectAndRadius(Rect.fromLTWH(-1.5 * k, -11 * k, 3 * k, 11 * k), Radius.circular(1.5 * k));
  final paint = Paint()
    ..shader = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [colors.brand2.withValues(alpha: opacity), Colors.white.withValues(alpha: opacity)],
    ).createShader(bar.outerRect);
  for (final deg in const [-10.0, 35.0, 80.0]) {
    c.save();
    c.translate(anchor.dx, anchor.dy);
    c.rotate(deg * math.pi / 180);
    c.translate(0, ty * k);
    c.scale(1, sy);
    c.drawRRect(bar, paint);
    c.restore();
  }
}
