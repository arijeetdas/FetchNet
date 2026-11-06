import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_services.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';

/// Opens this build's update page on fetchnet.arijeet.in in the system browser.
Future<void> openUpdatePage(BuildContext context) async {
  final uri = await AppScope.of(context).updates.updateLink();
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showSnack(context, 'Couldn\'t open the browser', kind: ToastKind.error);
}

/// "Update available" card for Home and Settings. It can't be dismissed and
/// only disappears once the installed version is the latest.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, this.padding = const EdgeInsets.only(bottom: 12)});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final updates = AppScope.of(context).updates;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final latest = updates.latest;
        if (!updates.updateAvailable || latest == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final installed = updates.installed;
        return Padding(
          padding: padding,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
                  child: const Icon(Icons.system_update_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Update available · v${latest.versionName}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        installed == null
                            ? 'A newer FetchNet is ready to download.'
                            : 'You have v${installed.versionName}. Get the latest fixes and features.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer, height: 1.4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => openUpdatePage(context),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                  child: const Text('Update'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
