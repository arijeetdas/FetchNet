import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_services.dart';
import '../../core/platform/device_environment.dart';
import '../../core/platform/native_bridge.dart';
import '../../engine/engine.dart';
import '../../services/sites_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/platform_logo.dart';
import '../../widgets/motion/page_motions.dart';
import '../../widgets/site_icon.dart';
import '../onboarding/disclaimer_content.dart';
import '../shell/home_shell.dart';
import '../shell/update_banner.dart';
import '../youtube/youtube_settings_screen.dart';
import 'about_dialog.dart';
import 'settings_widgets.dart';

const ytDlpRepo = 'https://github.com/yt-dlp/yt-dlp';
const fetchNetRepo = 'https://git-fetchnet.arijeet.in';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    }).catchError((_) {});
  }

  Future<void> _updateEngine() async {
    final services = AppScope.of(context);
    setState(() => _updating = true);
    final message = await services.engine.update();
    if (!mounted) return;
    setState(() => _updating = false);
    showSnack(context, message, kind: message.startsWith('Update failed') ? ToastKind.error : ToastKind.success);
  }

  Future<void> _install(EngineComponent component) async {
    final services = AppScope.of(context);
    try {
      await services.engine.installComponent(component);
      if (mounted) {
        showSnack(context, component == EngineComponent.ffmpeg ? 'FFmpeg installed' : 'Deno installed', kind: ToastKind.success);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Install failed: $e', kind: ToastKind.error);
    }
  }

  void _showDisclaimer() {
    showFetchNetDialog<void>(
      context: context,
      barrierDismissible: true,
      lockBack: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Disclaimer'),
        content: const SizedBox(width: 520, child: SingleChildScrollView(child: DisclaimerBody())),
        actions: [
          DialogButton(
            label: 'Close',
            icon: Icons.check_circle_rounded,
            primary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  void _showAboutApp() {
    final theme = Theme.of(context);
    showFetchNetDialog<void>(
      context: context,
      barrierDismissible: true,
      lockBack: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        icon: const FetchNetLogo(size: 56),
        title: const Text('About FetchNet'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(
            'FetchNet is a lightweight, cross-platform interface for yt-dlp. Paste a link, choose video or audio in the '
            'quality you want, and FetchNet saves it to Download/FetchNet.\n\n'
            'All the heavy lifting is done by yt-dlp, a free and open-source project maintained by its own community. '
            'FetchNet is not affiliated with yt-dlp.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ),
        actions: [
          DialogButton(
            label: 'Close',
            icon: Icons.check_circle_rounded,
            primary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return PageFrame(
      title: 'Settings',
      leading: const PageGlyph(PageGlyphKind.settings),
      maxWidth: 760,
      slivers: [
        SliverList.list(
          children: [
            const UpdateBanner(padding: EdgeInsets.only(top: 8)),
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Center(child: SettingsMotion()),
            ),

            // ───── Appearance ─────
            const SectionLabel('Appearance'),
            SettingsCard(
              children: [
                SettingsRow(
                  icon: Icons.palette_rounded,
                  title: 'Theme',
                  subtitle: 'Follow the system, or pick light or dark.',
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<ThemeMode>(
                  valueListenable: services.themeMode,
                  builder: (context, mode, _) => SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_rounded), label: Text('System')),
                        ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_rounded), label: Text('Light')),
                        ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_rounded), label: Text('Dark')),
                      ],
                      selected: {mode},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => services.setThemeMode(s.first),
                    ),
                  ),
                ),
                const Divider(height: 28),
                ValueListenableBuilder<bool>(
                  valueListenable: services.showAnimations,
                  builder: (context, on, _) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: on,
                    onChanged: services.setShowAnimations,
                    title: const Text('Show animations'),
                    subtitle: const Text(
                      'Play the animated icons on Home, Downloads, History and Settings. When off, they stay still.',
                    ),
                  ),
                ),
              ],
            ),

            // ───── Downloads ─────
            const SectionLabel('Downloads'),
            ListenableBuilder(
              listenable: services.storage,
              builder: (context, _) {
                final dir = services.storage.downloadDir;
                return SettingsCard(
                  children: [
                    SettingsRow(
                      icon: Icons.folder_rounded,
                      title: 'Save location',
                      subtitle: dir ?? (services.storage.error ?? 'Preparing…'),
                      trailing: DeviceEnvironment.isDesktop && dir != null
                          ? IconButton(
                              tooltip: 'Open folder',
                              onPressed: () => NativeBridge.openFolder(dir),
                              icon: const Icon(Icons.open_in_new_rounded),
                            )
                          : null,
                    ),
                    if (DeviceEnvironment.isAndroid) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Videos appear in your Gallery / Photos app and audio in your music & file manager apps.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                );
              },
            ),

            // ───── YouTube ─────
            const SectionLabel('YouTube Settings'),
            ListenableBuilder(
              listenable: services.youtube,
              builder: (context, _) {
                final yt = services.youtube;
                final profile = yt.profile;
                final subtitle = yt.signedIn
                    ? 'Signed in as ${profile?.email ?? profile?.name ?? 'your Google account'}'
                    : 'Sign in with Google, thumbnail downloads and video tags';
                return SettingsCard(
                  padding: EdgeInsets.zero,
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      leading: yt.signedIn
                          ? GoogleAvatar(profile: profile, size: 42)
                          : const BrandGlyph(brand: SiteBrand.youtube, size: 40),
                      title: const Text('YouTube', style: TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const YouTubeSettingsScreen()),
                      ),
                    ),
                  ],
                );
              },
            ),

            // ───── Engine ─────
            const SectionLabel('Engine'),
            ListenableBuilder(
              listenable: Listenable.merge([services.engine.status, services.engine.componentInstall]),
              builder: (context, _) {
                final status = services.engine.status.value;
                final install = services.engine.componentInstall.value;
                final supported = services.engine.isSupported;
                return SettingsCard(
                  children: [
                    SettingsRow(
                      icon: Icons.memory_rounded,
                      title: 'yt-dlp',
                      subtitle: !supported
                          ? 'Not available on ${DeviceEnvironment.platformDisplayName}'
                          : status.version != null
                              ? 'Version ${status.version}'
                              : (status.message ?? 'Starting…'),
                      trailing: supported
                          ? FilledButton.tonal(
                              onPressed: _updating || !status.isReady ? null : _updateEngine,
                              child: _updating || status.state == EngineState.updating
                                  ? const EnergyLoader(size: 22)
                                  : const Text('Update'),
                            )
                          : null,
                    ),
                    if (supported) ...[
                      const Divider(height: 24),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: services.prefs.autoUpdateEngine,
                        onChanged: (v) async {
                          await services.prefs.setAutoUpdateEngine(v);
                          setState(() {});
                        },
                        title: const Text('Keep yt-dlp up to date'),
                        subtitle: const Text('Sites change often. Checks for a new yt-dlp once a day.'),
                      ),
                    ],
                    if (services.engine.canInstallComponents) ...[
                      const Divider(height: 24),
                      SettingsRow(
                        icon: Icons.movie_filter_rounded,
                        title: 'FFmpeg',
                        subtitle: status.ffmpegAvailable
                            ? 'Installed — HD video and MP3 available'
                            : 'Needed for HD video (merging) and MP3 conversion',
                        trailing: status.ffmpegAvailable
                            ? Icon(Icons.check_circle_rounded, color: scheme.primary)
                            : FilledButton.tonal(
                                onPressed: install != null ? null : () => _install(EngineComponent.ffmpeg),
                                child: const Text('Install'),
                              ),
                      ),
                      const Divider(height: 24),
                      SettingsRow(
                        icon: Icons.javascript_rounded,
                        title: 'JavaScript runtime',
                        subtitle: status.jsRuntime != null
                            ? 'Using ${status.jsRuntime}'
                            : 'YouTube needs one for full quality options. Installs Deno.',
                        trailing: status.jsRuntime != null
                            ? Icon(Icons.check_circle_rounded, color: scheme.primary)
                            : FilledButton.tonal(
                                onPressed: install != null ? null : () => _install(EngineComponent.jsRuntime),
                                child: const Text('Install'),
                              ),
                      ),
                      if (install != null) ...[
                        const SizedBox(height: 14),
                        Text(install.label, style: theme.textTheme.bodySmall),
                        const SizedBox(height: 6),
                        GradientProgressBar(value: install.progress, height: 6),
                      ],
                    ],
                  ],
                );
              },
            ),

            // ───── About ─────
            const SectionLabel('About'),
            SettingsCard(
              padding: EdgeInsets.zero,
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About FetchNet'),
                  subtitle: const Text('What this app does'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _showAboutApp,
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const FetchNetLogo(size: 26, glow: false),
                  title: const Text('FetchNet on GitHub'),
                  subtitle: const Text('git-fetchnet.arijeet.in'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                  onTap: () => launchUrl(Uri.parse(fetchNetRepo), mode: LaunchMode.externalApplication),
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('yt-dlp on GitHub'),
                  subtitle: const Text('github.com/yt-dlp/yt-dlp'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                  onTap: () => launchUrl(Uri.parse(ytDlpRepo), mode: LaunchMode.externalApplication),
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.gavel_rounded),
                  title: const Text('Disclaimer'),
                  subtitle: const Text('Terms you agreed to'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _showDisclaimer,
                ),
              ],
            ),
            const SizedBox(height: 32),

            // ───── Footer ─────
            Center(
              child: Column(
                children: [
                  InkWell(
                    onTap: _version.isEmpty ? null : () => showFetchNetAboutDialog(context, version: _version),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const PlatformLogo(size: 15),
                          const SizedBox(width: 7),
                          Text(
                            'FetchNet for ${DeviceEnvironment.platformDisplayName}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Developed by Arijeet Das',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
