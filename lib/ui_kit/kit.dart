import 'package:flutter/material.dart';

import 'glass_kit.dart';
import 'material_kit.dart';
import 'ui_look.dart';

export 'ui_look.dart';

// The pieces of FetchNet's chrome that look different with Liquid Glass on.
// Each is described here once and drawn by [MaterialKit] or [GlassKit],
// whichever look is on (see [UiLook]). Their parameters mirror the Material
// widgets they stand in for.

/// A dialog with its own content (a [Dialog]).
class KitDialog extends StatelessWidget {
  const KitDialog({
    super.key,
    required this.child,
    this.backgroundColor,
    this.surfaceTintColor,
    this.insetPadding,
    this.shape,
    this.clipBehavior,
  });

  final Widget child;
  final Color? backgroundColor;
  final Color? surfaceTintColor;
  final EdgeInsets? insetPadding;
  final ShapeBorder? shape;
  final Clip? clipBehavior;

  @override
  Widget build(BuildContext context) => context.liquidGlass ? GlassKit.dialog(context, this) : MaterialKit.dialog(context, this);
}

/// A question or a notice with buttons (an [AlertDialog]).
class KitAlertDialog extends StatelessWidget {
  const KitAlertDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
    this.shape,
    this.titlePadding,
    this.contentPadding,
    this.actionsPadding,
  });

  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final ShapeBorder? shape;
  final EdgeInsetsGeometry? titlePadding;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? actionsPadding;

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.alertDialog(context, this) : MaterialKit.alertDialog(context, this);
}

/// A sheet from the bottom of the screen (like [showModalBottomSheet]).
Future<T?> showKitSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool showDragHandle = false,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  BoxConstraints? constraints,
  Color? backgroundColor,
  Color? barrierColor,
  ShapeBorder? shape,
}) {
  final sheet = KitSheet(
    builder: builder,
    showDragHandle: showDragHandle,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    constraints: constraints,
    backgroundColor: backgroundColor,
    barrierColor: barrierColor,
    shape: shape,
  );
  return context.liquidGlass ? GlassKit.showSheet<T>(context, sheet) : MaterialKit.showSheet<T>(context, sheet);
}

/// What [showKitSheet] shows.
class KitSheet {
  const KitSheet({
    required this.builder,
    this.showDragHandle = false,
    this.isScrollControlled = false,
    this.useSafeArea = false,
    this.constraints,
    this.backgroundColor,
    this.barrierColor,
    this.shape,
  });

  final WidgetBuilder builder;
  final bool showDragHandle;
  final bool isScrollControlled;
  final bool useSafeArea;
  final BoxConstraints? constraints;
  final Color? backgroundColor;
  final Color? barrierColor;
  final ShapeBorder? shape;
}

/// A setting that's on or off, in a list (a [SwitchListTile]).
class KitSwitchListTile extends StatelessWidget {
  const KitSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.contentPadding,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? title;
  final Widget? subtitle;
  final Widget? secondary;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.switchTile(context, this) : MaterialKit.switchTile(context, this);
}

/// An on/off switch (a [Switch]).
class KitSwitch extends StatelessWidget {
  const KitSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.switchControl(context, this) : MaterialKit.switchControl(context, this);
}

/// A value picked on a track (a [Slider]).
class KitSlider extends StatelessWidget {
  const KitSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeStart,
    this.onChangeEnd,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) => context.liquidGlass ? GlassKit.slider(context, this) : MaterialKit.slider(context, this);
}

/// One choice out of a few, side by side (a single-choice [SegmentedButton]).
class KitSegmented<T> extends StatelessWidget {
  const KitSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.style,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool showSelectedIcon;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.segmented<T>(context, this) : MaterialKit.segmented<T>(context, this);
}

/// A choice in a [KitMenuButton].
class KitMenuEntry<T> {
  const KitMenuEntry({required this.value, required this.label, this.icon, this.checked});

  final T value;
  final String label;
  final IconData? icon;

  /// `true` / `false`: a choice that's on or off (a check mark); `null`:
  /// an action.
  final bool? checked;
}

/// A button that opens a menu of actions (a [PopupMenuButton]).
class KitMenuButton<T> extends StatelessWidget {
  const KitMenuButton({
    super.key,
    required this.entries,
    required this.onSelected,
    this.icon = Icons.more_vert_rounded,
    this.tooltip,
    this.backgroundColor,
    this.foregroundColor,
  });

  final List<KitMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final IconData icon;
  final String? tooltip;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.menuButton<T>(context, this) : MaterialKit.menuButton<T>(context, this);
}

/// A value picked from a short list (a [DropdownButton]).
class KitDropdown<T> extends StatelessWidget {
  const KitDropdown({super.key, required this.value, required this.items, required this.onChanged});

  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.dropdown<T>(context, this) : MaterialKit.dropdown<T>(context, this);
}

/// A page's back (or close) button: round and filled, never stretched; on
/// glass with Liquid Glass. With [halo], a soft blur around it keeps it
/// clear over content scrolling under the header.
class KitBackButton extends StatelessWidget {
  const KitBackButton({
    super.key,
    this.onPressed,
    this.close = false,
    this.icon = Icons.arrow_back_rounded,
    this.glassIcon,
    this.tooltip,
    this.halo = false,
    this.color,
    this.fill,
  });

  /// Default: back to the page before.
  final VoidCallback? onPressed;

  /// A close (×) button rather than a back arrow.
  final bool close;

  /// The Material look's icon (the glass look uses iOS's chevron, or
  /// [glassIcon]).
  final IconData icon;
  final IconData? glassIcon;
  final String? tooltip;
  final bool halo;

  /// The icon's colour (players: their own colours).
  final Color? color;

  /// The Material look's fill.
  final Color? fill;

  String get label => tooltip ?? (close ? 'Close' : 'Back');

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.backButton(context, this) : MaterialKit.backButton(context, this);
}

/// A button in a page's header (browser back / forward…).
class KitHeaderButton extends StatelessWidget {
  const KitHeaderButton({super.key, required this.icon, required this.onPressed, this.glassIcon, this.tooltip});

  final IconData icon;
  final IconData? glassIcon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.headerButton(context, this) : MaterialKit.headerButton(context, this);
}

/// A round button floating over content: a picture, a page, a video.
class KitFloatingButton extends StatelessWidget {
  const KitFloatingButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconSize = 24,
    this.color,
    this.backgroundColor,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double iconSize;

  /// The icon's colour (white over pictures).
  final Color? color;

  /// The Material look's fill.
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) =>
      context.liquidGlass ? GlassKit.floatingButton(context, this) : MaterialKit.floatingButton(context, this);
}
