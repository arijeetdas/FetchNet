import 'dart:io';

import 'package:flutter/material.dart';

import '../models/media_info.dart';
import 'brand.dart';
import 'kind_icon.dart';

/// The colour of a status chip or pill.
enum ChipTone { good, warn, accent, muted }

/// (background, text) for [tone].
(Color, Color) chipColors(BuildContext context, ChipTone tone) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final green = theme.brightness == Brightness.dark ? const Color(0xFF6EE7A0) : const Color(0xFF15803D);
  return switch (tone) {
    ChipTone.good => (green.withValues(alpha: 0.14), green),
    ChipTone.warn => (scheme.errorContainer, scheme.onErrorContainer),
    ChipTone.accent => (scheme.primaryContainer, scheme.onPrimaryContainer),
    ChipTone.muted => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
  };
}

/// The card at the top of Downloads, History and Settings: the page's
/// animated icon and a tagline (side by side on large screens).
class PageHero extends StatelessWidget {
  const PageHero({super.key, required this.motion, required this.tagline});

  /// Builds the animated icon at the given size.
  final Widget Function(double size) motion;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 520;
    final text = Text(
      tagline,
      textAlign: narrow ? TextAlign.center : TextAlign.start,
      style: theme.textTheme.titleMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        height: 1.35,
      ),
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Center(child: motion(112)), const SizedBox(height: 10), text],
              )
            : Row(children: [motion(104), const SizedBox(width: 20), Expanded(child: text)]),
      ),
    );
  }
}

/// "TODAY  3  ─────": a list's group heading, with how many and optional
/// buttons at the end.
class GroupLabel extends StatelessWidget {
  const GroupLabel({super.key, required this.label, required this.count, this.trailing = const []});

  final String label;
  final int count;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 22, 2, 10),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w900, letterSpacing: 1.2),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(999)),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 10),
          // Buttons take the line's place (and wrap on a narrow phone).
          Expanded(
            child: trailing.isEmpty
                ? Divider(color: scheme.outlineVariant.withValues(alpha: 0.5))
                : Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: trailing),
          ),
        ],
      ),
    );
  }
}

/// A small rounded button for a group heading or a page's top bar ("Pause
/// all", "Open folder", "Clear").
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.icon, required this.onPressed, this.danger = false});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = danger ? scheme.errorContainer.withValues(alpha: 0.75) : scheme.secondaryContainer.withValues(alpha: 0.8);
    final fg = danger ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 15, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tile with an icon, a number and a label; tap to pick it (History's
/// filters, Downloads' kinds).
class CountTile extends StatelessWidget {
  const CountTile({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? Colors.white : scheme.onSurface;
    final sub = selected ? Colors.white.withValues(alpha: 0.9) : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            decoration: BoxDecoration(
              gradient: selected ? AppColors.brandGradient : null,
              color: selected ? null : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: selected ? Colors.transparent : scheme.outlineVariant.withValues(alpha: 0.4)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: selected ? Colors.white : scheme.primary),
                const SizedBox(height: 4),
                Text('$count', style: theme.textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w900, height: 1.1)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: sub, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "✓ Saved", "! Failed": a download's state.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.icon, required this.tone, this.onPicture = false});

  final String label;
  final IconData icon;
  final ChipTone tone;

  /// On top of a picture: an opaque background so it stays readable.
  final bool onPicture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (bg, fg) = chipColors(context, tone);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: onPicture ? 9 : 7, vertical: onPicture ? 4 : 2),
      decoration: BoxDecoration(
        color: onPicture ? Color.alphaBlend(bg, scheme.surface) : bg,
        borderRadius: BorderRadius.circular(999),
        boxShadow: onPicture ? [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 8)] : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

/// A download's picture: a saved picture ([file]), its thumbnail ([url]),
/// or its kind on FetchNet's gradient.
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.kind,
    this.file,
    this.url,
    this.radius = 14,
    this.iconSize = 24,
    this.showIcon = true,
  });

  final MediaKind kind;
  final String? file;
  final String? url;
  final double radius;
  final double iconSize;

  /// The kind's icon on the gradient when there's no picture.
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final fallback = DecoratedBox(
      decoration: const BoxDecoration(gradient: AppColors.brandGradient),
      child: showIcon ? Center(child: Icon(kindIcon(kind), color: Colors.white, size: iconSize)) : null,
    );
    final Widget image = file != null
        ? Image.file(File(file!), fit: BoxFit.cover, cacheWidth: 480, errorBuilder: (_, _, _) => fallback)
        : url == null
            ? fallback
            : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (file != null || url != null)
            Positioned(
              left: 5,
              bottom: 5,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(6)),
                child: Icon(kindIcon(kind), size: 12, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

/// A rounded, outlined surface for a row of a list (a download, a file).
class ListCard extends StatelessWidget {
  const ListCard({super.key, required this.child, this.onTap, this.onLongPress, this.padding = const EdgeInsets.all(10)});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Nothing to list: an icon, why, and what to do.
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.title, required this.text, this.action});

  final IconData icon;
  final String title;
  final String text;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 64),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(18)),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.4),
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 14),
            FilledButton.tonal(onPressed: action!.$2, child: Text(action!.$1)),
          ],
        ],
      ),
    );
  }
}
