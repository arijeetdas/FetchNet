import 'package:flutter/widgets.dart';

/// How FetchNet's chrome looks: its own Material design, or Apple's Liquid
/// Glass (Settings → Appearance → Liquid Glass).
///
/// The two looks live apart, so either can change without touching the
/// other: `material_kit.dart` builds the Material look and `glass_kit.dart`
/// the glass one. The widgets in `kit.dart` (and the app's nav bar and rail)
/// pick one of them by the [UiLook] in [UiLookScope].
enum UiLook { material, liquidGlass }

/// The [UiLook] for everything below it (above the whole app).
class UiLookScope extends InheritedWidget {
  const UiLookScope({super.key, required this.look, required super.child});

  final UiLook look;

  static UiLook of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiLookScope>()?.look ?? UiLook.material;

  @override
  bool updateShouldNotify(UiLookScope oldWidget) => oldWidget.look != look;
}

extension UiLookContext on BuildContext {
  /// Whether Liquid Glass is on.
  bool get liquidGlass => UiLookScope.of(this) == UiLook.liquidGlass;
}
