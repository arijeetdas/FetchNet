import 'package:flutter/widgets.dart';

/// How the Liquid Glass looks (Settings → Appearance, under Liquid Glass):
/// its tint's opacity, and how much it reflects light and bends what's
/// behind it. Reflection and refraction start off: plain frosted glass.
@immutable
class GlassTuning {
  const GlassTuning({this.opacity = 0.5, this.reflection = 0, this.refraction = 0});

  /// 0–1: how much the glass is tinted (0 clear, 1 nearly opaque).
  final double opacity;

  /// 0–1: light on the glass (specular highlights and the Fresnel edge
  /// glow); 0 is off.
  final double reflection;

  /// 0–1: how much the glass bends and splits the light behind it (lens
  /// refraction and a little dispersion at the edges); 0 is off.
  final double refraction;

  GlassTuning copyWith({double? opacity, double? reflection, double? refraction}) => GlassTuning(
        opacity: opacity ?? this.opacity,
        reflection: reflection ?? this.reflection,
        refraction: refraction ?? this.refraction,
      );

  @override
  bool operator ==(Object other) =>
      other is GlassTuning && other.opacity == opacity && other.reflection == reflection && other.refraction == refraction;

  @override
  int get hashCode => Object.hash(opacity, reflection, refraction);
}

/// The [GlassTuning] for everything below it (above the whole app).
class GlassTuningScope extends InheritedWidget {
  const GlassTuningScope({super.key, required this.tuning, required super.child});

  final GlassTuning tuning;

  static GlassTuning of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassTuningScope>()?.tuning ?? const GlassTuning();

  @override
  bool updateShouldNotify(GlassTuningScope oldWidget) => oldWidget.tuning != tuning;
}
