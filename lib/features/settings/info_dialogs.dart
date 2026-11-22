import 'package:flutter/material.dart';

import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../onboarding/disclaimer_content.dart';

/// Settings → About FetchNet: what the app does, how a download goes, and
/// the open-source tools behind it.
Future<void> showAboutFetchNetDialog(BuildContext context) => showFetchNetDialog<void>(
      context: context,
      barrierDismissible: true,
      lockBack: false,
      builder: (context) => const _InfoDialog(
        leading: FetchNetLogo(size: 56),
        title: 'About FetchNet',
        subtitle: 'Save videos, music and images from the web',
        body: _AboutBody(),
      ),
    );

/// Settings → Disclaimer: the terms agreed to when FetchNet was first set up.
Future<void> showDisclaimerDialog(BuildContext context) => showFetchNetDialog<void>(
      context: context,
      barrierDismissible: true,
      lockBack: false,
      builder: (context) => const _InfoDialog(
        leading: _HeaderIcon(Icons.gavel_rounded),
        title: 'Disclaimer',
        subtitle: 'The terms you agreed to when you set up FetchNet',
        body: _DisclaimerBody(),
      ),
    );

/// A popup with a gradient header, a body that scrolls and a Close button.
class _InfoDialog extends StatelessWidget {
  const _InfoDialog({required this.leading, required this.title, required this.subtitle, required this.body});

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Dialog(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(gradient: AppColors.brandGradient),
              child: Stack(
                children: [
                  const Positioned(right: -36, top: -44, child: _Ring(size: 140, opacity: 0.16)),
                  const Positioned(left: -30, bottom: -60, child: _Ring(size: 110, opacity: 0.12)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                    child: Row(
                      children: [
                        leading,
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                subtitle,
                                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.88), height: 1.3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: body,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: DialogButton(
                label: 'Close',
                icon: Icons.check_circle_rounded,
                primary: true,
                expand: true,
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
        ),
        child: Icon(icon, color: Colors.white, size: 28),
      );
}

class _Ring extends StatelessWidget {
  const _Ring({required this.size, required this.opacity});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: opacity), width: 18),
        ),
      );
}

/// A small heading inside a popup.
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// An icon on a soft tile, a title and a line or two about it.
class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 19, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(text, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutBody extends StatelessWidget {
  const _AboutBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const steps = [
      (Icons.link_rounded, 'Paste a link', 'From YouTube and the many other sites yt-dlp and gallery-dl support.'),
      (Icons.tune_rounded, 'Pick what you want', 'Video or audio in the quality you like, or the images and files of a post.'),
      (
        Icons.folder_rounded,
        'Find it in your folder',
        'Saved to Download/FetchNet (or the folder you chose in Settings), sorted into Images, Audio and Video.'
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'FetchNet is a lightweight, cross-platform app for yt-dlp and gallery-dl: everything they can do, without the command line.',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
        const SizedBox(height: 18),
        const _Heading('How it works'),
        for (final (i, (icon, title, text)) in steps.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          _InfoTile(icon: icon, title: '${i + 1}. $title', text: text),
        ],
        const SizedBox(height: 18),
        const _Heading('Powered by'),
        const IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _EngineCard(name: 'yt-dlp', role: 'Video and audio', icon: Icons.smart_display_rounded)),
              SizedBox(width: 8),
              Expanded(child: _EngineCard(name: 'gallery-dl', role: 'Images, galleries and posts', icon: Icons.photo_library_rounded)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Both are free, open-source projects maintained by their own communities. FetchNet is not affiliated with either of them.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
        ),
      ],
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.name, required this.role, required this.icon});

  final String name;
  final String role;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, size: 18, color: Colors.white),
          ),
          const SizedBox(height: 10),
          Text(name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900)),
          const SizedBox(height: 2),
          Text(role, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _DisclaimerBody extends StatelessWidget {
  const _DisclaimerBody();

  static const _icons = [
    Icons.layers_rounded,
    Icons.block_rounded,
    Icons.person_rounded,
    Icons.shield_outlined,
    Icons.copyright_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    const sections = DisclaimerText.sections;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (title, text)) in sections.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          _InfoTile(icon: _icons[i % _icons.length], title: title, text: text),
        ],
      ],
    );
  }
}
