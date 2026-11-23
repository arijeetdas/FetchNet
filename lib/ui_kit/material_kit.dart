import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../widgets/app_navigation.dart';
import '../widgets/liquid_nav_bar.dart';
import '../widgets/page_parts.dart' show PillButton;
import 'kit.dart';

/// FetchNet's own look (Liquid Glass off): Material 3 with the app theme.
///
/// Everything the Material look draws for the shared chrome lives here;
/// the glass look is in `glass_kit.dart`.
abstract final class MaterialKit {
  // ───── Navigation ─────

  /// The floating bar on phones, with its liquid selector.
  static Widget navBar(BuildContext context, FloatingNavBar bar) {
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
                target: bar.target,
                onTargetChanged: bar.onTargetChanged,
                onSettled: bar.onSettled,
                items: bar.items,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Space [navBar] takes at the bottom of the screen.
  static double navBarHeight(BuildContext context) =>
      LiquidNavBar.height + 12 + MediaQuery.paddingOf(context).bottom.clamp(10, double.infinity);

  /// The rounded side rail on large screens.
  static Widget navRail(BuildContext context, AppNavRail rail) {
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
          extended: rail.extended,
          minExtendedWidth: 220,
          selectedIndex: rail.selectedIndex,
          onDestinationSelected: rail.onSelected,
          labelType: rail.extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
          leading: rail.leading,
          trailing: rail.trailing,
          destinations: [
            for (final item in rail.items)
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

  // ───── Header buttons ─────

  /// A page's back (or close) button: a filled circle (never stretched), in
  /// a soft blur when it floats over content.
  static Widget backButton(BuildContext context, KitBackButton b) {
    final scheme = Theme.of(context).colorScheme;
    final button = SizedBox.square(
      dimension: 44,
      child: Tooltip(
        message: b.label,
        child: Material(
          color: b.fill ?? scheme.surfaceContainerHigh.withValues(alpha: 0.92),
          shape: CircleBorder(side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35))),
          elevation: b.halo ? 2 : 0,
          shadowColor: Colors.black.withValues(alpha: 0.3),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: b.onPressed ?? () => Navigator.of(context).maybePop(),
            child: Icon(b.close ? Icons.close_rounded : b.icon, size: 22, color: b.color ?? scheme.onSurface),
          ),
        ),
      ),
    );
    return Center(widthFactor: 1, heightFactor: 1, child: b.halo ? _Halo(child: button) : button);
  }

  static Widget headerButton(BuildContext context, KitHeaderButton h) =>
      IconButton.filledTonal(tooltip: h.tooltip, onPressed: h.onPressed, icon: Icon(h.icon));

  /// A page header's capsule button ("Clear", "Open folder").
  static Widget pillButton(BuildContext context, PillButton b) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = b.danger ? scheme.errorContainer.withValues(alpha: 0.75) : scheme.secondaryContainer.withValues(alpha: 0.8);
    final fg = b.danger ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: b.onPressed,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 15, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(b.icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(b.label, style: theme.textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }

  // ───── Dialogs & sheets ─────

  static Widget dialog(BuildContext context, KitDialog d) => Dialog(
        backgroundColor: d.backgroundColor,
        surfaceTintColor: d.surfaceTintColor,
        insetPadding: d.insetPadding,
        shape: d.shape,
        clipBehavior: d.clipBehavior,
        child: d.child,
      );

  static Widget alertDialog(BuildContext context, KitAlertDialog a) => AlertDialog(
        icon: a.icon,
        title: a.title,
        content: a.content,
        actions: a.actions,
        shape: a.shape,
        titlePadding: a.titlePadding,
        contentPadding: a.contentPadding,
        actionsPadding: a.actionsPadding,
      );

  static Future<T?> showSheet<T>(BuildContext context, KitSheet sheet) => showModalBottomSheet<T>(
        context: context,
        builder: sheet.builder,
        showDragHandle: sheet.showDragHandle,
        isScrollControlled: sheet.isScrollControlled,
        useSafeArea: sheet.useSafeArea,
        constraints: sheet.constraints,
        backgroundColor: sheet.backgroundColor,
        barrierColor: sheet.barrierColor,
        shape: sheet.shape,
      );

  // ───── Controls ─────

  static Widget switchTile(BuildContext context, KitSwitchListTile t) => SwitchListTile(
        value: t.value,
        onChanged: t.onChanged,
        title: t.title,
        subtitle: t.subtitle,
        secondary: t.secondary,
        contentPadding: t.contentPadding,
      );

  static Widget switchControl(BuildContext context, KitSwitch s) => Switch(value: s.value, onChanged: s.onChanged);

  static Widget slider(BuildContext context, KitSlider s) => Slider(
        value: s.value,
        onChanged: s.onChanged,
        min: s.min,
        max: s.max,
        divisions: s.divisions,
        label: s.label,
        onChangeStart: s.onChangeStart,
        onChangeEnd: s.onChangeEnd,
      );

  static Widget segmented<T>(BuildContext context, KitSegmented<T> s) => SegmentedButton<T>(
        segments: s.segments,
        selected: s.selected,
        onSelectionChanged: s.onSelectionChanged,
        showSelectedIcon: s.showSelectedIcon,
        style: s.style,
      );

  // ───── Menus ─────

  static Widget menuButton<T>(BuildContext context, KitMenuButton<T> m) => PopupMenuButton<T>(
        tooltip: m.tooltip,
        icon: Icon(m.icon),
        style: m.backgroundColor == null && m.foregroundColor == null
            ? null
            : IconButton.styleFrom(backgroundColor: m.backgroundColor, foregroundColor: m.foregroundColor),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        onSelected: m.onSelected,
        itemBuilder: (context) => [
          for (final e in m.entries)
            if (e.checked != null)
              CheckedPopupMenuItem<T>(value: e.value, checked: e.checked!, child: Text(e.label))
            else
              PopupMenuItem<T>(
                value: e.value,
                child: e.icon == null
                    ? Text(e.label)
                    : ListTile(leading: Icon(e.icon), title: Text(e.label), contentPadding: EdgeInsets.zero),
              ),
        ],
      );

  static Widget dropdown<T>(BuildContext context, KitDropdown<T> d) => DropdownButton<T>(
        value: d.value,
        underline: const SizedBox(),
        borderRadius: BorderRadius.circular(14),
        items: [for (final (v, text) in d.items) DropdownMenuItem(value: v, child: Text(text))],
        onChanged: (v) {
          if (v != null) d.onChanged(v);
        },
      );

  static Widget floatingButton(BuildContext context, KitFloatingButton b) {
    final button = IconButton.filledTonal(
      iconSize: b.iconSize,
      tooltip: b.tooltip,
      style: b.backgroundColor == null ? null : IconButton.styleFrom(backgroundColor: b.backgroundColor),
      onPressed: b.onPressed,
      icon: Icon(b.icon, color: b.color),
    );
    return button;
  }
}

/// A soft blur (and a little of the page colour) around a floating
/// button, so it stays clear over content.
class _Halo extends StatelessWidget {
  const _Halo({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned(
          left: -8,
          top: -8,
          right: -8,
          bottom: -8,
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(colors: [surface.withValues(alpha: 0.35), surface.withValues(alpha: 0)]),
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
