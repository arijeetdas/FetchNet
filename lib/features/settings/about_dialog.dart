import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/platform/device_environment.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/platform_logo.dart';
import '../shell/update_banner.dart';

/// Recommended Android build for this device's preferred ABI, or `Universal`.
String recommendedAndroidBuild() {
  const known = {'arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'};
  final abis = DeviceEnvironment.supportedAbis;
  if (abis.isEmpty) return 'Universal';
  return known.contains(abis.first) ? abis.first : 'Universal';
}

String installedAndroidBuild() {
  final raw = DeviceEnvironment.installedApkType;
  return switch (raw) {
    'arm64-v8a' || 'arm-v8a' => 'arm64-v8a',
    'armeabi-v7a' || 'arm-v7a' => 'armeabi-v7a',
    'x86_64' => 'x86_64',
    'x86' => 'x86',
    _ => 'Universal',
  };
}

/// "FetchNet for [platform]" popup: version, Android build type advice,
/// and Check for Updates (opens the website in the system browser).
Future<void> showFetchNetAboutDialog(BuildContext context, {required String version}) {
  return showFetchNetDialog<void>(
    context: context,
    barrierDismissible: true,
    lockBack: false,
    builder: (context) => _AboutDialog(version: version),
  );
}

class _AboutDialog extends StatelessWidget {
  const _AboutDialog({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final installed = isAndroid ? installedAndroidBuild() : 'Universal';
    final recommended = isAndroid ? recommendedAndroidBuild() : 'Universal';
    final onRecommended = installed == recommended && installed != 'Universal';
    const headerHeight = 124.0;
    const logoSize = 84.0;

    return Dialog(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
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
                      child: DecoratedBox(
                        decoration: const BoxDecoration(gradient: AppColors.brandGradient),
                        child: Stack(
                          children: [
                            const Positioned(right: -30, top: -40, child: _Ring(size: 150, opacity: 0.16)),
                            const Positioned(left: -24, bottom: -50, child: _Ring(size: 120, opacity: 0.12)),
                          ],
                        ),
                      ),
                    ),
                    const Positioned(
                      top: headerHeight - logoSize / 2,
                      left: 0,
                      right: 0,
                      child: Center(child: FetchNetLogo(size: logoSize)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'FetchNet',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified_rounded, size: 15, color: scheme.onPrimaryContainer),
                            const SizedBox(width: 6),
                            Text(
                              isAndroid ? 'Version $version' : 'Installed version $version',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (isAndroid) ...[
                      const SizedBox(height: 18),
                      Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
                        ),
                        child: Column(
                          children: [
                            _BuildRow(icon: Icons.memory_rounded, label: 'Installed build', value: installed),
                            Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: scheme.outlineVariant.withValues(alpha: 0.4),
                            ),
                            _BuildRow(
                              icon: Icons.auto_awesome_rounded,
                              label: 'Best for this device',
                              value: recommended,
                              highlighted: true,
                              matched: onRecommended,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: onRecommended || recommended == 'Universal'
                              ? const Color(0xFF22C55E).withValues(alpha: 0.12)
                              : scheme.primaryContainer.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              onRecommended || recommended == 'Universal'
                                  ? Icons.check_circle_rounded
                                  : Icons.info_outline_rounded,
                              size: 17,
                              color: onRecommended || recommended == 'Universal' ? const Color(0xFF16A34A) : scheme.primary,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                onRecommended
                                    ? "You're on the best build for this device."
                                    : recommended == 'Universal'
                                        ? 'The universal build runs on every device.'
                                        : 'Switch to $recommended for a smaller, faster build.',
                                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
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
                                    const TextSpan(text: 'Thanks for using FetchNet on '),
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
                    const SizedBox(height: 20),
                    GradientButton(
                      label: 'Check for Updates',
                      icon: Icons.system_update_rounded,
                      expand: true,
                      // Opens /updates/<platform>/<version>+<build>[-<abi>] in the system browser.
                      onPressed: () => openUpdatePage(context),
                    ),
                    const SizedBox(height: 10),
                    DialogButton(
                      label: 'Close',
                      icon: Icons.close_rounded,
                      expand: true,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

class _BuildRow extends StatelessWidget {
  const _BuildRow({
    required this.icon,
    required this.label,
    required this.value,
    this.highlighted = false,
    this.matched = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool highlighted;
  final bool matched;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: highlighted ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              gradient: highlighted ? AppColors.brandGradient : null,
              color: highlighted ? null : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (matched) ...[
                  const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                  const SizedBox(width: 4),
                ],
                Text(
                  value,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: highlighted ? Colors.white : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
