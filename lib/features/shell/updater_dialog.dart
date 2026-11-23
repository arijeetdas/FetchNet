import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/device_environment.dart';
import '../../services/app_updater.dart';
import '../../services/update_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import 'update_banner.dart';
import 'whats_new_dialog.dart';
import '../../ui_kit/kit.dart';

/// The updater: what's new in the latest version, then download and install
/// it in the app. "Open the update page" (the website, as before) is always
/// there, and becomes the main button when anything fails.
Future<void> showUpdaterDialog(BuildContext context) {
  return showFetchNetDialog<void>(
    context: context,
    barrierDismissible: true,
    lockBack: false,
    builder: (context) => const _UpdaterDialog(),
  );
}

class _UpdaterDialog extends StatelessWidget {
  const _UpdaterDialog();

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final updates = services.updates;
    final updater = services.updater;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    const inset = EdgeInsets.symmetric(horizontal: 20, vertical: 24);
    final maxHeight = media.size.height - media.padding.vertical - inset.vertical;
    final compact = maxHeight < 560;
    final headerHeight = compact ? 72.0 : 112.0;
    final logoSize = compact ? 56.0 : 76.0;

    return ListenableBuilder(
      listenable: Listenable.merge([updates, updater]),
      builder: (context, _) {
        final latest = updates.latest;
        final installed = updates.installed;
        final notes = updates.update?.notes;
        final header = SizedBox(
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
        );
        final title = Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Update available',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
              ),
              const SizedBox(height: 8),
              Center(
                child: PopupChip(
                  icon: Icons.system_update_rounded,
                  text: [
                    if (installed != null) 'v${installed.versionName}',
                    if (latest != null) 'v${latest.versionName}',
                  ].join('  →  '),
                ),
              ),
            ],
          ),
        );
        final notesView = notes != null
            ? ReleaseNotesCard(release: notes, platform: UpdateService.platformSlug)
            : Text(
                'A newer FetchNet is ready with the latest fixes and features.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              );
        final actions = Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 20),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _Actions(updater: updater, inApp: AppUpdater.supported && updates.update != null),
          ),
        );
        return KitDialog(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          insetPadding: inset,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 440, maxHeight: maxHeight),
            // Short screens (landscape phones): everything scrolls together.
            // Otherwise the notes scroll between the header and the buttons.
            child: compact
                ? Scrollbar(
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          header,
                          title,
                          Padding(padding: const EdgeInsets.symmetric(horizontal: 22), child: notesView),
                          actions,
                        ],
                      ),
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      title,
                      Flexible(
                        child: Scrollbar(
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                            child: notesView,
                          ),
                        ),
                      ),
                      actions,
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// The bottom of the updater: what to do next, by the updater's phase.
class _Actions extends StatelessWidget {
  const _Actions({required this.updater, required this.inApp});

  final AppUpdater updater;

  /// The update can be installed in the app (otherwise: the website).
  final bool inApp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final website = DialogButton(
      label: 'Open the update page',
      icon: Icons.open_in_new_rounded,
      expand: true,
      onPressed: () => openUpdatePage(context),
    );
    Widget note(String text, {bool error = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: error ? scheme.errorContainer : scheme.primaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: error ? scheme.onErrorContainer : scheme.onSurface,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        );
    const gap = SizedBox(height: 10);

    if (!inApp) {
      // The website is the only way (no in-app install here, or the site's
      // update manifest couldn't be read).
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GradientButton(
            label: 'Open the update page',
            icon: Icons.open_in_new_rounded,
            expand: true,
            onPressed: () => openUpdatePage(context),
          ),
          gap,
          DialogButton(label: 'Later', icon: Icons.schedule_rounded, expand: true, onPressed: () => Navigator.pop(context)),
        ],
      );
    }

    final children = switch (updater.phase) {
      UpdaterPhase.idle => [
          if (updater.message != null) ...[note(updater.message!), gap],
          GradientButton(
            label: 'Download update',
            icon: Icons.download_rounded,
            expand: true,
            onPressed: updater.start,
          ),
          gap,
          DialogButton(label: 'Later', icon: Icons.schedule_rounded, expand: true, onPressed: () => Navigator.pop(context)),
        ],
      UpdaterPhase.downloading => [
          GradientProgressBar(value: updater.progress, height: 8),
          const SizedBox(height: 8),
          Text(
            [
              if (updater.progress != null) '${(updater.progress! * 100).round()}%',
              if (updater.receivedBytes != null)
                updater.totalBytes != null
                    ? '${formatBytes(updater.receivedBytes)} of ${formatBytes(updater.totalBytes)}'
                    : formatBytes(updater.receivedBytes),
              if (updater.speed != null) formatSpeed(updater.speed),
            ].where((s) => s.isNotEmpty).join(' · ').ifEmpty('Starting the download…'),
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
          ),
          gap,
          DialogButton(label: 'Cancel', icon: Icons.close_rounded, expand: true, onPressed: updater.cancel),
        ],
      UpdaterPhase.installing => [
          const Center(child: EnergyLoader(size: 40)),
          const SizedBox(height: 8),
          Text(
            updater.message ?? 'Installing…',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
          ),
        ],
      UpdaterPhase.needsPermission => [
          note('To install the update, allow FetchNet to install apps. Android asks once.'),
          gap,
          GradientButton(
            label: 'Allow & install',
            icon: Icons.verified_user_rounded,
            expand: true,
            onPressed: updater.allowInstalls,
          ),
          gap,
          website,
        ],
      UpdaterPhase.waitingForUser => [
          note('Confirm the update in Android\'s installer. FetchNet restarts as the new version.'),
          gap,
          website,
        ],
      UpdaterPhase.readyToRelaunch => [
          note(updater.relaunchRunsInstaller
              ? 'The update is downloaded. FetchNet closes while it installs, then starts again.'
              : 'The new version is ready. Relaunch FetchNet to start using it.'),
          gap,
          GradientButton(
            label: updater.relaunchRunsInstaller ? 'Restart to update' : 'Relaunch',
            icon: Icons.restart_alt_rounded,
            expand: true,
            onPressed: updater.relaunch,
          ),
          gap,
          DialogButton(label: 'Later', icon: Icons.schedule_rounded, expand: true, onPressed: () => Navigator.pop(context)),
        ],
      UpdaterPhase.failed => [
          note(updater.message ?? 'The update couldn\'t be installed.', error: true),
          gap,
          GradientButton(
            label: 'Open the update page',
            icon: Icons.open_in_new_rounded,
            expand: true,
            onPressed: () => openUpdatePage(context),
          ),
          gap,
          DialogButton(
            label: 'Try again',
            icon: Icons.refresh_rounded,
            expand: true,
            onPressed: () {
              updater.reset();
              updater.start();
            },
          ),
        ],
    };
    return Column(
      key: ValueKey(updater.phase),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...children,
        if (DeviceEnvironment.isAndroid && updater.phase == UpdaterPhase.idle) ...[
          const SizedBox(height: 8),
          Text(
            'Android shows its installer to confirm the update.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
