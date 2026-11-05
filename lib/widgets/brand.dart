import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';
import 'loaders.dart';

export '../core/theme.dart' show AppColors;
export 'loaders.dart';

/// The in-app FetchNet icon: a rounded-square "app tile" with the glyph from
/// `assets/app_icon/foreground.png` (traced to `glyph.svg`). Launcher icons are
/// generated separately and are not affected by this widget.
class FetchNetLogo extends StatelessWidget {
  const FetchNetLogo({super.key, this.size = 48, this.glow = true});

  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = size * 0.27;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(
        color: dark ? Colors.white.withValues(alpha: 0.18) : AppColors.violet.withValues(alpha: 0.10),
        width: math.max(0.6, size / 96),
      ),
    );
    // Center(widthFactor/heightFactor: 1) keeps the tile square even when a
    // parent forces tight constraints (e.g. AlertDialog's icon slot).
    return Center(
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shape,
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Color(0xFFF3EEFF)],
            ),
            shadows: glow
                ? [
                    BoxShadow(
                      color: AppColors.violetBright.withValues(alpha: dark ? 0.45 : 0.28),
                      blurRadius: size * 0.42,
                      offset: Offset(0, size * 0.12),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: size * 0.08,
                      offset: Offset(0, size * 0.03),
                    ),
                  ]
                : null,
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Soft glass sheen across the top half.
                Align(
                  alignment: Alignment.topCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.5,
                    widthFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.white.withValues(alpha: 0.9), Colors.white.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(size * 0.19),
                  child: ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF6A1BFF), Color(0xFF4E01FA), Color(0xFF7A1FE8)],
                    ).createShader(Offset.zero & bounds.size),
                    child: SvgPicture.asset('assets/app_icon/glyph.svg', fit: BoxFit.contain),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Text painted with the brand gradient.
class GradientText extends StatelessWidget {
  const GradientText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => AppColors.brandGradient.createShader(Offset.zero & bounds.size),
      // Padding keeps glyph overhang (tight letter-spacing) inside the shader.
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Text(text, style: style, textAlign: textAlign),
      ),
    );
  }
}

/// Big primary action with the violet gradient.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = false,
    this.height = 54,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final child = AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled || loading ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppColors.brandGradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: AppColors.violetBright.withValues(alpha: 0.32),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Row(
                  mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (loading)
                      const EnergyLoader(size: 24, onColor: true)
                    else if (icon != null)
                      Icon(icon, color: Colors.white, size: 22),
                    if (loading || icon != null) const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}

/// Soft violet background with glowing colour blobs. With [animate] the
/// blobs drift slowly (used on onboarding).
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child, this.intensity = 1, this.animate = false});

  final Widget child;
  final double intensity;
  final bool animate;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  AnimationController? _drift;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(AuroraBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.animate && _drift == null) {
      _drift = AnimationController(vsync: this, duration: const Duration(seconds: 14))..repeat();
    } else if (!widget.animate && _drift != null) {
      _drift!.dispose();
      _drift = null;
    }
  }

  @override
  void dispose() {
    _drift?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final i = widget.intensity;
    Widget blobs(double t) {
      final a = t * 2 * math.pi;
      return Stack(
        children: [
          Positioned(
            top: -140 + math.sin(a) * 30,
            right: -110 + math.cos(a) * 40,
            child: _Blob(color: AppColors.purple.withValues(alpha: (dark ? 0.42 : 0.26) * i), size: 420),
          ),
          Positioned(
            bottom: -170 + math.cos(a) * 36,
            left: -130 + math.sin(a) * 44,
            child: _Blob(color: AppColors.violetBright.withValues(alpha: (dark ? 0.38 : 0.22) * i), size: 460),
          ),
          if (widget.animate)
            Positioned(
              top: 180 + math.sin(a + 1.4) * 60,
              left: -60 + math.cos(a + 0.8) * 70,
              child: _Blob(color: AppColors.orchid.withValues(alpha: (dark ? 0.20 : 0.12) * i), size: 300),
            ),
        ],
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(gradient: AppColors.softGradient(brightness)),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: _drift == null
                    ? blobs(0)
                    : AnimatedBuilder(animation: _drift!, builder: (context, _) => blobs(_drift!.value)),
              ),
            ),
          ),
          Positioned.fill(child: widget.child),
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)], stops: const [0, 1]),
      ),
    );
  }
}
