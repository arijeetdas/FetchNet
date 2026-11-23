import 'package:flutter/material.dart';

import '../../widgets/brand.dart';
import '../../ui_kit/kit.dart';
import '../../widgets/page_parts.dart' show ChipTone;

export '../../widgets/page_parts.dart' show ChipTone;

/// Small uppercase heading above a settings card.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 22, 6, 10),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children, this.padding = const EdgeInsets.all(18)});

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }
}

/// Icon tile, title, subtitle and an optional trailing control.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
  }) : assert(icon != null || leading != null);

  final IconData? icon;

  /// Replaces the icon tile (e.g. an avatar).
  final Widget? leading;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        leading ??
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(13)),
              child: Icon(icon, color: scheme.onPrimaryContainer, size: 22),
            ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ],
    );
  }
}

/// The rounded icon tile at the start of a settings row.
class SettingsGlyph extends StatelessWidget {
  const SettingsGlyph(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(13)),
      child: Icon(icon, color: scheme.onPrimaryContainer, size: 22),
    );
  }
}

/// An icon on FetchNet's gradient (Engines, Creator Settings...).
class GradientGlyph extends StatelessWidget {
  const GradientGlyph(this.icon, {super.key, this.size = 44, this.dimmed = false});

  final IconData icon;
  final double size;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: dimmed ? 0.45 : 1,
      duration: const Duration(milliseconds: 200),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: AppColors.brandGradient,
          borderRadius: BorderRadius.circular(size * 0.3),
          boxShadow: [BoxShadow(color: AppColors.violetBright.withValues(alpha: 0.3), blurRadius: 14, offset: const Offset(0, 5))],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.52),
      ),
    );
  }
}

/// A row inside a settings card: small icon, title / subtitle and a switch, on a
/// tinted panel (rows are joined into one rounded group).
class ToggleRow extends StatelessWidget {
  const ToggleRow({super.key, required this.icon, required this.title, required this.subtitle, required this.value, required this.onChanged, this.last = false});

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onChanged != null;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 6),
      child: Material(
        color: value && enabled ? scheme.primaryContainer.withValues(alpha: 0.55) : scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? () => onChanged!(!value) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: enabled ? scheme.primary : scheme.outline),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800, color: enabled ? null : scheme.outline),
                      ),
                      Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                KitSwitch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A selectable picture tile (backgrounds, formats).
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({super.key, required this.selected, required this.onTap, required this.preview, required this.title, required this.subtitle});

  final bool selected;
  final VoidCallback? onTap;
  final Widget preview;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      inMutuallyExclusiveGroup: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : scheme.surfaceContainerHigh.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.5), width: selected ? 2 : 1),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      Center(child: SizedBox(height: 120, child: preview)),
                      if (selected)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
                            child: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w900, color: selected ? scheme.primary : null),
                  ),
                  Text(subtitle, maxLines: 2, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A short note on a tinted panel, with an optional button.
class TipBox extends StatelessWidget {
  const TipBox({super.key, required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(color: scheme.secondaryContainer.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(height: 1.4))),
          if (action != null) ...[const SizedBox(width: 8), FilledButton.tonal(onPressed: action!.$2, child: Text(action!.$1))],
        ],
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.icon, required this.tone});

  final String label;
  final IconData icon;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const green = Color(0xFF16A34A);
    final (bg, fg) = switch (tone) {
      ChipTone.good => (green.withValues(alpha: 0.14), green),
      ChipTone.warn => (scheme.errorContainer, scheme.onErrorContainer),
      ChipTone.accent => (scheme.primaryContainer, scheme.onPrimaryContainer),
      ChipTone.muted => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

/// A row that opens another page: an icon, a title, a short description and
/// a chevron (or [trailing]).
class NavTile extends StatelessWidget {
  const NavTile({super.key, required this.leading, required this.title, required this.subtitle, this.trailing, this.onTap});

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing ?? (onTap == null ? const SizedBox.shrink() : Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
