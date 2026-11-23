import 'package:flutter/material.dart';

import '../ui_kit/glass_kit.dart';
import '../ui_kit/material_kit.dart';
import '../ui_kit/ui_look.dart';
import 'liquid_nav_bar.dart';

export 'liquid_nav_bar.dart' show LiquidNavItem;

/// The bottom bar used on phones (Material: FetchNet's liquid bar; Liquid
/// Glass: the iOS 26 tab bar) by the main screens and the
/// YouTube view. See [LiquidNavBar] for [target] / [onSettled].
class FloatingNavBar extends StatelessWidget {
  const FloatingNavBar({
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

  /// Space the bar takes at the bottom of the screen (bar + margins).
  static double reservedHeight(BuildContext context) =>
      context.liquidGlass ? GlassKit.navBarHeight(context) : MaterialKit.navBarHeight(context);

  @override
  Widget build(BuildContext context) => context.liquidGlass ? GlassKit.navBar(context, this) : MaterialKit.navBar(context, this);
}

/// The side rail used on wide screens by the main screens and the YouTube
/// view (Liquid Glass: a floating glass sidebar).
class AppNavRail extends StatelessWidget {
  const AppNavRail({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.extended,
    this.leading,
    this.trailing,
  });

  final List<LiquidNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool extended;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => context.liquidGlass ? GlassKit.navRail(context, this) : MaterialKit.navRail(context, this);
}
