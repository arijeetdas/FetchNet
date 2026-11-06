import 'package:flutter/material.dart';

import 'liquid_nav_bar.dart';

export 'liquid_nav_bar.dart' show LiquidNavItem;

/// Floating glass bottom bar used on phones by the main screens and the
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
      LiquidNavBar.height + 12 + MediaQuery.paddingOf(context).bottom.clamp(10, double.infinity);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      minimum: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.4 : 0.12),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: LiquidNavBar(
                target: target,
                onTargetChanged: onTargetChanged,
                onSettled: onSettled,
                items: items,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded side rail used on wide screens by the main screens and the
/// YouTube view.
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget icon(LiquidNavItem item, bool selected) => Badge(
          isLabelVisible: item.badge > 0 || item.dot,
          label: item.badge > 0 ? Text('${item.badge}') : null,
          child: Icon(selected ? item.selectedIcon : item.icon),
        );
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        ),
        child: NavigationRail(
          extended: extended,
          minExtendedWidth: 220,
          selectedIndex: selectedIndex,
          onDestinationSelected: onSelected,
          labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
          leading: leading,
          trailing: trailing,
          destinations: [
            for (final item in items)
              NavigationRailDestination(
                icon: icon(item, false),
                selectedIcon: icon(item, true),
                label: Text(item.label),
                padding: const EdgeInsets.symmetric(vertical: 4),
              ),
          ],
        ),
      ),
    );
  }
}
