import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/platform/device_environment.dart';
import '../../models/changelog.dart';
import '../../services/update_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/platform_logo.dart';
import 'updater_dialog.dart';

/// The one-time "What's new" popup, for the installed version only.
///
/// One flag per build (`whatsnew.shown.<build>`), read at startup:
/// - this build's flag exists: shown already (1.2.0 → 1.2.0 again), skip;
/// - it doesn't: create it, delete the previous build's, and show;
/// - a newer build's flag exists (an older version was installed): create
///   this build's flag without showing anything.
///
/// The notes come from the website (the app ships no changelog). The flag
/// is created before the popup opens, so it never shows twice even if the
/// app closes meanwhile. Notes that can't be loaded (offline) create no
/// flag: the popup tries again on the next launch.
Future<void> maybeShowWhatsNew(BuildContext context, AppServices services) async {
  final installed = await services.updates.installedRelease();
  if (installed == null || !context.mounted) return;
  final build = installed.buildNumber;
  final prefs = services.prefs;
  if (prefs.whatsNewShown(build)) return;
  final shown = prefs.whatsNewShownBuilds;
  if (!Changelog.isDue(installedBuild: build, shownBuilds: shown)) {
    await prefs.markWhatsNewShown(build);
    return;
  }
  final notes = await services.updates.notesFor(build);
  if (notes == null || !context.mounted) return;
  await prefs.markWhatsNewShown(build);
  if (!context.mounted) return;
  await showWhatsNew(context, notes);
}

/// Settings → About → What's new: the latest release's notes, from the
/// website. It checks first (silently):
/// - on the latest version: its notes;
/// - behind: the updater opens, with "Update to the latest version";
/// - newer than the latest public build: "This is an unreleased/modified build";
/// - offline or any failure: "Unable to load changelogs".
Future<void> showFullChangelog(BuildContext context, AppServices services) async {
  final updates = services.updates;
  final state = await updates.check();
  if (!context.mounted) return;
  switch (state) {
    case UpdateState.available:
      showSnack(context, 'Update to the latest version');
      await showUpdaterDialog(context);
      return;
    case UpdateState.ahead:
      showSnack(context, unreleasedBuildMessage);
      return;
    case UpdateState.upToDate:
      final installed = await updates.installedRelease();
      final notes = installed == null ? null : await updates.notesFor(installed.buildNumber);
      if (!context.mounted) return;
      if (notes == null) {
        showSnack(context, 'Unable to load changelogs', kind: ToastKind.error);
        return;
      }
      await showWhatsNew(context, notes);
    default:
      showSnack(context, 'Unable to load changelogs', kind: ToastKind.error);
  }
}

/// The toast for a build newer than the latest public one.
const unreleasedBuildMessage = 'This is an unreleased/modified build';

Future<void> showWhatsNew(BuildContext context, ChangelogRelease release) {
  return showFetchNetDialog<void>(
    context: context,
    barrierDismissible: true,
    lockBack: false,
    builder: (context) => _WhatsNewDialog(release: release),
  );
}

/// Styled like the "FetchNet for (platform)" popup: a gradient header with
/// the app tile, the version, then the changelog list. The list takes the
/// height the screen leaves and scrolls; the header and OK always show.
class _WhatsNewDialog extends StatelessWidget {
  const _WhatsNewDialog({required this.release});

  final ChangelogRelease release;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    const inset = EdgeInsets.symmetric(horizontal: 20, vertical: 24);
    final maxHeight = media.size.height - media.padding.vertical - inset.vertical;
    // Short screens (landscape phones) get a slimmer header.
    final compact = maxHeight < 560;
    final headerHeight = compact ? 72.0 : 112.0;
    final logoSize = compact ? 56.0 : 76.0;
    final platform = UpdateService.platformSlug;

    return Dialog(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: inset,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 440, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: gradient band with the app tile overlapping it.
            SizedBox(
              height: headerHeight + logoSize / 2,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: headerHeight,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(gradient: AppColors.brandGradient),
                      child: Stack(
                        children: [
                          Positioned(right: -30, top: -40, child: PopupHeaderRing(size: 150, opacity: 0.16)),
                          Positioned(left: -24, bottom: -50, child: PopupHeaderRing(size: 120, opacity: 0.12)),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    top: headerHeight - logoSize / 2,
                    left: 0,
                    right: 0,
                    child: Center(child: FetchNetLogo(size: logoSize)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'What\'s new',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: PopupChip(
                      icon: Icons.new_releases_rounded,
                      text: 'Version ${release.version} · Build ${release.build}',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // The changelog list: as tall as the screen allows, then scrolls.
            Flexible(
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                  child: ReleaseNotesCard(release: release, platform: platform),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!compact) ...[
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.favorite_rounded, color: Colors.redAccent, size: 15),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    const TextSpan(text: 'Thanks for updating FetchNet on '),
                                    const WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: Padding(
                                        padding: EdgeInsets.only(right: 4),
                                        child: PlatformLogo(size: 14),
                                      ),
                                    ),
                                    TextSpan(text: DeviceEnvironment.platformDisplayName),
                                  ],
                                ),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  GradientButton(
                    label: 'OK',
                    icon: Icons.check_rounded,
                    expand: true,
                    height: compact ? 46 : 52,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One release: its date and summary, then every section that applies on
/// this platform (other platforms' groups and "Under the hood" left out).
class ReleaseNotesCard extends StatelessWidget {
  const ReleaseNotesCard({super.key, required this.release, required this.platform});

  final ChangelogRelease release;
  final String? platform;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = release;
    final sections = r.sectionsFor(platform);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(r.emoji ?? '✨', style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This update',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (r.date != null)
                Text(
                  r.date!,
                  style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                ),
            ],
          ),
          if (r.summary != null) ...[
            const SizedBox(height: 8),
            Text.rich(
              richNoteSpan(r.summary!, theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
            ),
          ],
          for (final s in sections) ...[
            Divider(height: 24, color: scheme.outlineVariant.withValues(alpha: 0.4)),
            _SectionView(section: s),
          ],
        ],
      ),
    );
  }
}

class _SectionView extends StatelessWidget {
  const _SectionView({required this.section});

  final ChangelogSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(section.title, style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800)),
        for (final g in section.groups) ...[
          if (g.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Text(g.title, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
            ),
          for (final item in g.items)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text.rich(richNoteSpan(item, body)),
            ),
        ],
      ],
    );
  }
}

class PopupChip extends StatelessWidget {
  const PopupChip({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: scheme.onPrimaryContainer),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.labelMedium?.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class PopupHeaderRing extends StatelessWidget {
  const PopupHeaderRing({super.key, required this.size, required this.opacity});

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

/// `**bold**`, `*italic*` and `` `code` `` in a changelog line.
TextSpan richNoteSpan(String text, TextStyle? base) {
  final spans = <InlineSpan>[];
  final pattern = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\*([^*\s][^*]*?)\*');
  var last = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    if (m.group(1) != null) {
      spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w800)));
    } else if (m.group(2) != null) {
      spans.add(TextSpan(
        text: m.group(2),
        style: TextStyle(fontFamily: 'monospace', fontSize: (base?.fontSize ?? 14) * 0.92),
      ));
    } else {
      spans.add(TextSpan(text: m.group(3), style: const TextStyle(fontStyle: FontStyle.italic)));
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return TextSpan(style: base, children: spans);
}
