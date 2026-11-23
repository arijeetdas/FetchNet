import 'dart:async';

import 'dart:ui' show ImageFilter;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../widgets/app_dialog.dart' show DialogButton;
import '../widgets/app_navigation.dart';
import '../widgets/page_parts.dart' show PillButton;
import 'glass_tuning.dart';
import 'kit.dart';

/// The Liquid Glass look (Settings → Appearance → Liquid Glass), built on
/// `liquid_glass_widgets` the way Apple's iOS 26 design uses glass: for the
/// navigation and control layer floating above the content (the tab bar,
/// the sidebar, floating buttons, dialogs, sheets and menus) and for the
/// lenses of switches, sliders and segmented controls, never for the
/// content itself.
///
/// Everything the glass look draws for the shared chrome lives here; the
/// Material look is in `material_kit.dart`.
abstract final class GlassKit {
  static Future<void>? _ready;

  /// Loads the glass shaders (once), so the first glass frame doesn't flash.
  static Future<void> prepare() => _ready ??= LiquidGlassWidgets.initialize().catchError((Object _) {});

  /// Keeps the app (its pages, what's open) when Liquid Glass is switched.
  static final _app = GlobalKey(debugLabel: 'FetchNet app');

  /// The glass setup above the app: the device's accessibility settings
  /// (Reduce Transparency / Motion) are honoured and light and dark follow
  /// the app's theme. While glass is [on], its quality also adapts to how
  /// fast the device draws it (that watch isn't kept while it's off).
  static Widget wrap(Widget child, {required bool on, GlassTuning tuning = const GlassTuning()}) {
    final app = LiquidGlassWidgets.wrap(
      theme: themeFor(tuning),
      respectSystemAccessibility: true,
      brightnessResolver: Theme.maybeBrightnessOf,
      child: GlassTuningScope(tuning: tuning, child: KeyedSubtree(key: _app, child: child)),
    );
    // It may lower the quality on a slow device, but never below the
    // standard shader: the minimal tier is a plain blur, with no refraction
    // or reflection at all.
    return on ? GlassAdaptiveScope(minQuality: GlassQuality.standard, child: app) : app;
  }

  /// The package's iOS 27 glass with the user's opacity, reflection and
  /// refraction (see [GlassTuning]), for every glass widget it draws.
  static GlassThemeData themeFor(GlassTuning t) {
    GlassThemeVariant tune(GlassThemeVariant v, {required bool dark}) {
      final s = v.settings ?? const GlassThemeSettings();
      return v.copyWith(
        settings: s.copyWith(
          // iOS 27's own tint at the middle of the slider.
          glassColor: dark
              ? const Color(0xFFFFFFFF).withValues(alpha: 0.24 * t.opacity)
              : const Color(0xFFF8F8F8).withValues(alpha: 0.15 + 0.75 * t.opacity),
          refractiveIndex: _refractiveIndex(t),
          thickness: _bevel(t),
          lensModel: t.refraction > 0 ? GlassLensModel.spherical : GlassLensModel.paraxial,
          chromaticAberration: _dispersion(t),
          lightIntensity: 0.5 * t.reflection,
          fresnelStrength: 0.8 * t.reflection,
          ambientStrength: 0.12 * t.reflection,
        ),
      );
    }

    return GlassThemeData(light: tune(GlassThemeVariant.light, dark: false), dark: tune(GlassThemeVariant.dark, dark: true));
  }

  /// 1.0 bends nothing (refraction off); iOS's own lens is about 1.24.
  /// (The Premium shader's bending.)
  static double _refractiveIndex(GlassTuning t) => 1 + 0.45 * t.refraction;

  /// The depth of the glass's curved edge, where it bends the light: the
  /// Premium shader's lens, and all the bending the Standard shader does
  /// (it shifts the backdrop by half of it at the edge, whatever the
  /// refractive index).
  static double _bevel(GlassTuning t) => 6 + 54 * t.refraction;

  /// Glass that is handed a picture of what's behind it (the Standard
  /// shader, all Windows and Linux get); the Premium one reads it itself.
  static bool get _needsBackground => !ui.ImageFilter.isShaderFilterSupported;

  /// The width the glass sidebar takes, margin included.
  static double railWidth({required bool extended}) => (extended ? 240 : 96) + 12;

  /// Colour fringes at the glass's edges, with refraction.
  static double _dispersion(GlassTuning t) => 1.5 * t.refraction;

  /// FetchNet's own glass surfaces, tuned like the package's.
  static LiquidGlassSettings _tuned(BuildContext context, {required double tint, required double blur, required double thickness, double saturation = 1.5}) {
    final t = GlassTuningScope.of(context);
    return LiquidGlassSettings(
      glassColor: Theme.of(context).colorScheme.surface.withValues(alpha: tint.clamp(0.0, 1.0)),
      blur: blur,
      thickness: thickness + 54 * t.refraction,
      saturation: saturation,
      refractiveIndex: _refractiveIndex(t),
      lensModel: t.refraction > 0 ? GlassLensModel.spherical : GlassLensModel.paraxial,
      chromaticAberration: _dispersion(t),
      lightIntensity: 0.5 * t.reflection,
      fresnelStrength: 0.8 * t.reflection,
      ambientStrength: 0.12 * t.reflection,
    );
  }

  /// Glass for dialogs and sheets: frosted and tinted enough for their
  /// text to read on anything.
  static LiquidGlassSettings platter(BuildContext context) {
    final o = GlassTuningScope.of(context).opacity;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _tuned(context, tint: dark ? 0.35 + 0.54 * o : 0.3 + 0.5 * o, blur: 18, thickness: 8, saturation: 1.6);
  }

  /// Glass for the sidebar: clearer, like the tab bar.
  static LiquidGlassSettings chrome(BuildContext context) =>
      _tuned(context, tint: 0.44 * GlassTuningScope.of(context).opacity, blur: 8, thickness: 6);

  // ───── Navigation ─────

  /// The iOS 26 tab bar: a glass pill with a jelly lens that lifts and
  /// follows the finger. The page changes once the lens has landed.
  static Widget navBar(BuildContext context, FloatingNavBar bar) => _GlassNavBar(bar: bar);

  /// Space [navBar] takes at the bottom of the screen.
  static double navBarHeight(BuildContext context) => 64 + 20 + MediaQuery.paddingOf(context).bottom;

  static Widget _navIcon(LiquidNavItem item, bool selected) => Badge(
        isLabelVisible: item.badge > 0 || item.dot,
        label: item.badge > 0 ? Text('${item.badge}') : null,
        child: Icon(selected ? (item.glassSelectedIcon ?? item.selectedIcon) : (item.glassIcon ?? item.icon)),
      );

  /// The iPadOS / macOS 26 sidebar: a floating glass platter; the page
  /// you're on is a tinted capsule in it (no glass inside glass).
  static Widget navRail(BuildContext context, AppNavRail rail) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 0, 12),
        child: Builder(
          builder: (context) {
            const shape = LiquidRoundedSuperellipse(borderRadius: 30);
            final content = SizedBox(
              width: rail.extended ? 240 : 96,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?rail.leading,
                  for (final (i, item) in rail.items.indexed)
                    _RailItem(item: item, selected: i == rail.selectedIndex, extended: rail.extended, onTap: () => rail.onSelected(i)),
                  if (rail.trailing != null) ...[const Spacer(), rail.trailing!],
                ],
              ),
            );
            // Windows / Linux: the Standard shader, handed the pages to
            // refract. Elsewhere the Premium shader reads them itself.
            final background = _needsBackground ? LiquidGlassScope.of(context) : null;
            if (background != null) {
              return LightweightLiquidGlass(shape: shape, settings: chrome(context), backgroundKey: background, child: content);
            }
            return GlassContainer(
              shape: shape,
              settings: chrome(context),
              quality: GlassQuality.premium,
              useOwnLayer: true,
              clipBehavior: Clip.antiAlias,
              child: content,
            );
          },
        ),
      ),
    );
  }

  // ───── Header buttons ─────

  /// A page's back (or close) button: a round glass button with the iOS
  /// chevron, in a soft blur so it stays clear over what scrolls under it.
  static Widget backButton(BuildContext context, KitBackButton b) {
    final button = GlassIconButton(
      icon: Icon(
        b.glassIcon ?? (b.close ? CupertinoIcons.xmark : CupertinoIcons.chevron_back),
        size: 22,
        color: b.color ?? Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: b.onPressed ?? () => Navigator.of(context).maybePop(),
      size: 44,
      semanticLabel: b.label,
      useOwnLayer: true,
    );
    return Tooltip(message: b.label, child: b.halo ? _Halo(child: button) : button);
  }

  /// A button in a page's header.
  static Widget headerButton(BuildContext context, KitHeaderButton h) => Tooltip(
        message: h.tooltip ?? '',
        child: GlassIconButton(
          icon: Icon(h.glassIcon ?? h.icon, size: 22, color: Theme.of(context).colorScheme.onSurface),
          onPressed: h.onPressed,
          size: 44,
          semanticLabel: h.tooltip,
          useOwnLayer: true,
        ),
      );

  /// A page header's capsule button ("Clear", "Open folder").
  static Widget pillButton(BuildContext context, PillButton b) {
    final theme = Theme.of(context);
    final fg = b.danger ? theme.colorScheme.error : theme.colorScheme.onSurface;
    return GlassButton.custom(
      onTap: b.onPressed ?? () {},
      label: b.label,
      height: 40,
      shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      useOwnLayer: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(b.icon, size: 18, color: fg),
            const SizedBox(width: 6),
            Text(b.label, style: theme.textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  // ───── Dialogs & sheets ─────

  static double _radiusOf(ShapeBorder? shape, double fallback) =>
      shape is RoundedRectangleBorder ? shape.borderRadius.resolve(TextDirection.ltr).topLeft.x : fallback;

  /// A dialog's own content on a glass platter.
  static Widget dialog(BuildContext context, KitDialog d) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        insetPadding: d.insetPadding,
        shape: d.shape,
        clipBehavior: Clip.none,
        child: GlassContainer(
          shape: LiquidRoundedSuperellipse(borderRadius: _radiusOf(d.shape, 28)),
          settings: platter(context),
          quality: GlassQuality.premium,
          useOwnLayer: true,
          clipBehavior: Clip.antiAlias,
          child: d.child,
        ),
      );

  /// An iOS 26 alert: a glass platter with capsule buttons, when its
  /// buttons are FetchNet's dialog buttons (one to three); otherwise the
  /// dialog's own layout on a glass platter.
  static Widget alertDialog(BuildContext context, KitAlertDialog a) {
    final actions = a.actions ?? const <Widget>[];
    final buttons = actions.whereType<DialogButton>().toList();
    final title = _textOf(a.title);
    final native = buttons.isNotEmpty && buttons.length <= 3 && buttons.length == actions.length && (a.title == null || title != null);
    if (!native) return dialog(context, KitDialog(shape: a.shape, child: _AlertLayout(alert: a)));
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: MediaQuery.viewInsetsOf(context) + const EdgeInsets.all(24),
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: GlassDialog(
            title: title,
            maxWidth: 380,
            content: a.icon == null && a.content == null
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (a.icon != null) ...[
                        IconTheme(data: IconThemeData(color: scheme.primary, size: 32), child: a.icon!),
                        const SizedBox(height: 10),
                      ],
                      ?a.content,
                    ],
                  ),
            actions: [
              for (final b in buttons)
                GlassDialogAction(label: b.label, onPressed: b.onPressed, isPrimary: b.primary && !b.destructive, isDestructive: b.destructive),
            ],
          ),
        ),
      ),
    );
  }

  /// A sheet floating above the bottom edge, on glass (iOS 26 sheets sit
  /// inset from the screen's edges).
  static Future<T?> showSheet<T>(BuildContext context, KitSheet sheet) => showModalBottomSheet<T>(
        context: context,
        isScrollControlled: sheet.isScrollControlled,
        useSafeArea: sheet.useSafeArea,
        constraints: sheet.constraints,
        barrierColor: sheet.barrierColor,
        backgroundColor: Colors.transparent,
        elevation: 0,
        showDragHandle: false,
        builder: (context) => _SheetFrame(handle: sheet.showDragHandle, child: sheet.builder(context)),
      );

  // ───── Controls: the lenses ─────

  static Widget switchTile(BuildContext context, KitSwitchListTile t) => ListTile(
        contentPadding: t.contentPadding,
        leading: t.secondary,
        title: t.title,
        subtitle: t.subtitle,
        trailing: switchControl(context, KitSwitch(value: t.value, onChanged: t.onChanged)),
        onTap: t.onChanged == null ? null : () => t.onChanged!(!t.value),
      );

  static Widget switchControl(BuildContext context, KitSwitch s) => GlassSwitch(
        value: s.value,
        onChanged: s.onChanged,
        activeColor: Theme.of(context).colorScheme.primary,
        useOwnLayer: true,
      );

  static Widget slider(BuildContext context, KitSlider s) => GlassSlider(
        value: s.value.clamp(s.min, s.max),
        onChanged: s.onChanged,
        min: s.min,
        max: s.max,
        divisions: s.divisions,
        label: s.label,
        onChangeStart: s.onChangeStart,
        onChangeEnd: s.onChangeEnd,
        activeColor: Theme.of(context).colorScheme.primary,
        useOwnLayer: true,
      );

  static Widget segmented<T>(BuildContext context, KitSegmented<T> s) {
    final index = s.segments.indexWhere((e) => s.selected.contains(e.value));
    final control = GlassSegmentedControl(
      segments: [
        // Text, as iOS segmented controls have it (an icon only when there's
        // no label: icon above label doesn't fit the control's height).
        for (final e in s.segments)
          if (_textOf(e.label) case final label?)
            GlassSegment(label: label, enabled: e.enabled)
          else
            GlassSegment(icon: e.icon, enabled: e.enabled),
      ],
      selectedIndex: index < 0 ? 0 : index,
      onSegmentSelected: (i) => s.onSelectionChanged?.call({s.segments[i].value}),
      useOwnLayer: true,
    );
    // In a row (a list tile's end), it gets a width of its own.
    return LayoutBuilder(
      builder: (context, c) => c.hasBoundedWidth ? control : SizedBox(width: 84.0 * s.segments.length, child: control),
    );
  }

  // ───── Menus & floating buttons ─────

  static Widget menuButton<T>(BuildContext context, KitMenuButton<T> m) => GlassPullDownButton(
        icon: Icon(m.icon, color: m.foregroundColor),
        semanticLabel: m.tooltip,
        menuWidth: 250,
        items: [
          for (final e in m.entries)
            GlassMenuItem(
              title: e.label,
              icon: e.icon == null ? null : Icon(e.icon),
              trailing: e.checked == true ? const Icon(Icons.check_rounded, size: 18) : null,
              semanticsSelected: e.checked,
              onTap: () => m.onSelected(e.value),
            ),
        ],
      );

  static Widget dropdown<T>(BuildContext context, KitDropdown<T> d) {
    final current = d.items.where((e) => e.$1 == d.value).firstOrNull?.$2 ?? '';
    return GlassPullDownButton(
      label: current,
      icon: const Icon(Icons.unfold_more_rounded, size: 18),
      buttonHeight: 40,
      menuWidth: 220,
      items: [
        for (final (v, text) in d.items)
          GlassMenuItem(
            title: text,
            trailing: v == d.value ? const Icon(Icons.check_rounded, size: 18) : null,
            semanticsSelected: v == d.value,
            onTap: () => d.onChanged(v),
          ),
      ],
    );
  }

  static Widget floatingButton(BuildContext context, KitFloatingButton b) {
    final button = GlassIconButton(
      icon: Icon(b.icon, color: b.color, size: b.iconSize),
      onPressed: b.onPressed,
      size: b.iconSize + 22,
      semanticLabel: b.tooltip,
      useOwnLayer: true,
    );
    return b.tooltip == null ? button : Tooltip(message: b.tooltip, child: button);
  }

  /// The text of a [Text] (labels that the glass widgets take as strings).
  static String? _textOf(Widget? w) => w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
}

/// [GlassKit.navBar]: the tab bar, and the page change once its lens has
/// moved to a new tab (tapped, or asked for elsewhere in the app).
class _GlassNavBar extends StatefulWidget {
  const _GlassNavBar({required this.bar});

  final FloatingNavBar bar;

  @override
  State<_GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends State<_GlassNavBar> {
  Timer? _settle;

  @override
  void didUpdateWidget(_GlassNavBar old) {
    super.didUpdateWidget(old);
    final target = widget.bar.target;
    if (target != old.bar.target) {
      _settle?.cancel();
      _settle = Timer(const Duration(milliseconds: 320), () {
        if (mounted && widget.bar.target == target) widget.bar.onSettled(target);
      });
    }
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bar = widget.bar;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: GlassTabBar.bottom(
          tabs: [
            for (final item in bar.items)
              GlassTab(icon: GlassKit._navIcon(item, false), activeIcon: GlassKit._navIcon(item, true), label: item.label),
          ],
          selectedIndex: bar.target,
          // Windows / Linux: the pages, to refract.
          backgroundKey: GlassKit._needsBackground ? LiquidGlassScope.of(context) : null,
          onTabSelected: (i) {
            if (i != bar.target) bar.onTargetChanged(i);
          },
          selectedIconColor: scheme.primary,
          selectedLabelColor: scheme.primary,
          unselectedIconColor: scheme.onSurfaceVariant,
          unselectedLabelColor: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A soft blur around a floating button, so it stays clear over content.
class _Halo extends StatelessWidget {
  const _Halo({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            left: -6,
            top: -6,
            right: -6,
            bottom: -6,
            child: ClipOval(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5), child: const SizedBox.expand())),
          ),
          child,
        ],
      );
}

/// A sidebar entry: icon and label; the selected one in a tinted capsule.
class _RailItem extends StatelessWidget {
  const _RailItem({required this.item, required this.selected, required this.extended, required this.onTap});

  final LiquidNavItem item;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    final icon = Badge(
      isLabelVisible: item.badge > 0 || item.dot,
      label: item.badge > 0 ? Text('${item.badge}') : null,
      child: Icon(selected ? (item.glassSelectedIcon ?? item.selectedIcon) : (item.glassIcon ?? item.icon), color: color),
    );
    final label = Text(
      item.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (extended ? theme.textTheme.titleSmall : theme.textTheme.labelMedium)?.copyWith(
        color: color,
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          padding: extended ? const EdgeInsets.symmetric(horizontal: 16, vertical: 13) : const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: extended
              ? Row(children: [icon, const SizedBox(width: 14), Expanded(child: label)])
              : Column(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(height: 5), label]),
        ),
      ),
    );
  }
}

/// [KitAlertDialog]'s layout (Material's spacing) for a glass platter.
class _AlertLayout extends StatelessWidget {
  const _AlertLayout({required this.alert});

  final KitAlertDialog alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = alert;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (a.icon != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: IconTheme(data: IconThemeData(color: theme.colorScheme.secondary, size: 24), child: a.icon!),
            ),
          if (a.title != null)
            Padding(
              padding: a.titlePadding ?? EdgeInsets.fromLTRB(24, a.icon == null ? 24 : 16, 24, 0),
              child: DefaultTextStyle(
                style: theme.textTheme.headlineSmall!,
                textAlign: a.icon == null ? TextAlign.start : TextAlign.center,
                child: a.title!,
              ),
            ),
          if (a.content != null)
            Flexible(
              child: Padding(
                padding: a.contentPadding ?? const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: DefaultTextStyle(
                  style: theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  child: a.content!,
                ),
              ),
            ),
          if (a.actions != null && a.actions!.isNotEmpty)
            Padding(
              padding: a.actionsPadding ?? const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, overflowSpacing: 8, children: a.actions!),
            )
          else
            const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// A sheet's glass: inset from the screen's edges, with a grabber when the
/// sheet has one.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.handle, required this.child});

  final bool handle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 34),
          settings: GlassKit.platter(context),
          quality: GlassQuality.premium,
          useOwnLayer: true,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (handle)
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 14),
                    width: 38,
                    height: 5,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
