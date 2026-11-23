import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_services.dart';
import '../../core/platform/device_environment.dart';
import '../../engine/engine.dart';
import '../../services/sites_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/platform_logo.dart';
import '../../widgets/motion/page_motions.dart';
import '../../widgets/page_parts.dart';
import '../../widgets/site_icon.dart';
import '../shell/home_shell.dart';
import '../shell/update_banner.dart';
import '../shell/whats_new_dialog.dart';
import '../youtube/youtube_settings_screen.dart';
import '../../ui_kit/glass_tuning.dart';
import '../../ui_kit/kit.dart';
import 'creator_settings_screen.dart';
import 'about_dialog.dart';
import 'engines_screen.dart';
import 'extra_settings_section.dart';
import 'info_dialogs.dart';
import 'save_location_card.dart';
import 'settings_widgets.dart';

const fetchNetRepo = 'https://git-fetchnet.arijeet.in';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _version = info.version);
    }).catchError((_) {});
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

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget section(String label, List<Widget> body) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [SectionLabel(label), ...body],
        );

    // ───── Appearance ─────
    final appearance = section('Appearance', [
      SettingsCard(
        children: [
          const _CardHeader(icon: Icons.palette_rounded, title: 'Theme', subtitle: 'Follow your device, or pick light or dark.'),
          const SizedBox(height: 14),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: services.themeMode,
            builder: (context, mode, _) => IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, (m, label, hint)) in const [
                    (ThemeMode.system, 'System', 'Like your device'),
                    (ThemeMode.light, 'Light', 'Bright and clear'),
                    (ThemeMode.dark, 'Dark', 'Easy on the eyes'),
                  ].indexed) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: ChoiceTile(
                        selected: mode == m,
                        onTap: () => services.setThemeMode(m),
                        preview: _ThemePreview(mode: m),
                        title: label,
                        subtitle: hint,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<bool>(
            valueListenable: services.showAnimations,
            builder: (context, on, _) => ToggleRow(
              icon: Icons.animation_rounded,
              title: 'Show animations',
              subtitle: 'Animated icons, the music player\'s moving background and the like.',
              value: on,
              onChanged: services.setShowAnimations,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: services.liquidGlass,
            builder: (context, on, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ToggleRow(
                  icon: Icons.blur_on_rounded,
                  title: 'Liquid Glass',
                  subtitle: 'Applies Glass Effect on UI elements',
                  value: on,
                  onChanged: services.setLiquidGlass,
                  last: !on,
                ),
                // Only with Liquid Glass on: how it looks.
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: on ? const _GlassTuningControls() : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ],
      ),
    ]);

    // ───── Downloads ─────
    final downloads = section('Downloads', const [
      SaveLocationCard(),
      SizedBox(height: 12),
      ExtraSettingsCards(only: [ExtraCard.presets, ExtraCard.downloads]),
    ]);

    // ───── YouTube and Creator Settings ─────
    final sitesAndTools = section('Sites & tools', [
      ListenableBuilder(
        listenable: services.youtube,
        builder: (context, _) {
          final yt = services.youtube;
          final profile = yt.profile;
          return SettingsCard(
            padding: EdgeInsets.zero,
            children: [
              NavTile(
                leading: yt.signedIn ? GoogleAvatar(profile: profile, size: 42) : const BrandGlyph(brand: SiteBrand.youtube, size: 42),
                title: 'YouTube Settings',
                subtitle: yt.signedIn
                    ? 'Signed in as ${profile?.email ?? profile?.name ?? 'your Google account'}'
                    : 'Sign in with Google, thumbnail downloads, tags and cover art',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeSettingsScreen())),
              ),
              Divider(height: 1, indent: 72, color: scheme.outlineVariant.withValues(alpha: 0.4)),
              const CreatorSettingsTile(),
            ],
          );
        },
      ),
    ]);

    // ───── Extras: subtitles, lyrics, Browser Mode and copied links ─────
    final extras = section('Extras', const [
      ExtraSettingsCards(only: [ExtraCard.subtitles, ExtraCard.lyrics, ExtraCard.browser]),
    ]);

    // ───── Engines ─────
    // Versions, updates, links and credits live on the Engines screen; the
    // switches and add-ons stay here.
    final engines = section('Engines', [
      ListenableBuilder(
        listenable: Listenable.merge([services.engine.status, services.engine.componentInstall]),
        builder: (context, _) {
          final status = services.engine.status.value;
          final install = services.engine.componentInstall.value;
          final supported = services.engine.isSupported;
          final gallery = services.gallery.engine;
          return SettingsCard(
            padding: EdgeInsets.zero,
            children: [
              const EnginesSummaryTile(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (supported)
                      ToggleRow(
                        icon: Icons.update_rounded,
                        title: 'Keep engines up to date',
                        subtitle: 'Sites change often: checks for a new yt-dlp and gallery-dl once a day.',
                        value: services.prefs.autoUpdateEngine,
                        onChanged: (v) async {
                          await services.prefs.setAutoUpdateEngine(v);
                          setState(() {});
                        },
                      ),
                    if (gallery.isSupported)
                      ToggleRow(
                        icon: Icons.photo_library_rounded,
                        title: 'Images & posts',
                        subtitle: 'Uses gallery-dl to list the images, videos and audio of posts and galleries.',
                        value: services.prefs.galleryEnabled,
                        onChanged: (v) async {
                          await services.prefs.setGalleryEnabled(v);
                          if (v) gallery.initialize();
                          setState(() {});
                        },
                      ),
                    if (services.engine.canInstallComponents) ...[
                      const SizedBox(height: 6),
                      _AddOnRow(
                        icon: Icons.movie_filter_rounded,
                        title: 'FFmpeg',
                        subtitle: status.ffmpegAvailable ? 'Installed: HD video, MP3, clips and Shorts' : 'Needed for HD video, MP3, clips and Shorts',
                        installed: status.ffmpegAvailable,
                        onInstall: install != null ? null : () => _install(EngineComponent.ffmpeg),
                      ),
                      const SizedBox(height: 6),
                      _AddOnRow(
                        icon: Icons.javascript_rounded,
                        title: 'JavaScript runtime',
                        subtitle: status.jsRuntime != null ? 'Using ${status.jsRuntime}' : 'YouTube needs one for every quality. Installs Deno.',
                        installed: status.jsRuntime != null,
                        onInstall: install != null ? null : () => _install(EngineComponent.jsRuntime),
                      ),
                      if (install != null) ...[
                        const SizedBox(height: 14),
                        Text(install.label, style: theme.textTheme.bodySmall),
                        const SizedBox(height: 6),
                        GradientProgressBar(value: install.progress, height: 6),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ]);

    // ───── About ─────
    final divider = Divider(height: 1, indent: 72, color: scheme.outlineVariant.withValues(alpha: 0.4));
    final about = section('About', [
      SettingsCard(
        padding: EdgeInsets.zero,
        children: [
          NavTile(
            leading: const SettingsGlyph(Icons.info_rounded),
            title: 'About FetchNet',
            subtitle: 'What this app does',
            onTap: () => showAboutFetchNetDialog(context),
          ),
          divider,
          NavTile(
            leading: const SettingsGlyph(Icons.new_releases_rounded),
            title: 'What\'s new',
            subtitle: 'Release notes for this version',
            onTap: () => showFullChangelog(context, services),
          ),
          divider,
          NavTile(
            leading: const SettingsGlyph(Icons.code_rounded),
            title: 'FetchNet on GitHub',
            subtitle: 'git-fetchnet.arijeet.in',
            trailing: Icon(Icons.open_in_new_rounded, size: 20, color: scheme.onSurfaceVariant),
            onTap: () => launchUrl(Uri.parse(fetchNetRepo), mode: LaunchMode.externalApplication),
          ),
          divider,
          NavTile(
            leading: const SettingsGlyph(Icons.gavel_rounded),
            title: 'Disclaimer',
            subtitle: 'Terms you agreed to',
            onTap: () => showDisclaimerDialog(context),
          ),
        ],
      ),
    ]);

    // ───── Footer ─────
    final footer = Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Center(
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
    );

    final top = [
      const UpdateBanner(padding: EdgeInsets.only(top: 8)),
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: PageHero(
          motion: (size) => SettingsMotion(size: size),
          tagline: 'Make it yours: looks, downloads, sites and engines.',
        ),
      ),
    ];

    final wide = Breakpoints.isWide(context);
    return PageFrame(
      title: 'Settings',
      leading: const PageGlyph(PageGlyphKind.settings),
      maxWidth: wide ? 1400 : 760,
      slivers: [
        SliverToBoxAdapter(
          child: LayoutBuilder(
            builder: (context, c) {
              // Phones: one list. Large screens: two columns of whole
              // sections (looks, downloads and engines | sites, extras and
              // about).
              if (!wide || c.maxWidth < 900) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [...top, appearance, downloads, sitesAndTools, extras, engines, about, footer],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...top,
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [appearance, downloads, engines]),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [sitesAndTools, extras, about]),
                      ),
                    ],
                  ),
                  footer,
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Liquid Glass's opacity, reflection and refraction (reflection and
/// refraction start off: plain frosted glass).
class _GlassTuningControls extends StatelessWidget {
  const _GlassTuningControls();

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<GlassTuning>(
      valueListenable: services.glassTuning,
      builder: (context, t, _) {
        Widget row(IconData icon, String title, String hint, double value, GlassTuning Function(double) change, {bool offAtZero = true}) {
          final pct = (value * 100).round();
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800))),
                    Text(
                      offAtZero && pct == 0 ? 'Off' : '$pct%',
                      style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
                const SizedBox(height: 4),
                KitSlider(
                  value: value,
                  divisions: 20,
                  onChanged: (v) => services.setGlassTuning(change(v), save: false),
                  onChangeEnd: (v) => services.setGlassTuning(change(v)),
                ),
              ],
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row(Icons.opacity_rounded, 'Opacity', 'How much the glass is tinted.', t.opacity, (v) => t.copyWith(opacity: v), offAtZero: false),
              row(Icons.flare_rounded, 'Reflection', 'Light catching on the glass: highlights and a glowing edge.', t.reflection,
                  (v) => t.copyWith(reflection: v)),
              row(Icons.lens_blur_rounded, 'Refraction', 'The glass bending what\'s behind it, like a lens, with colour at its edges.',
                  t.refraction, (v) => t.copyWith(refraction: v)),
            ],
          ),
        );
      },
    );
  }
}

/// A card's title row: a gradient icon, a title and what it's about.
class _CardHeader extends StatelessWidget {
  const _CardHeader({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        GradientGlyph(icon),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 2),
              Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

/// An add-on (FFmpeg, a JavaScript runtime): installed, or a button.
class _AddOnRow extends StatelessWidget {
  const _AddOnRow({required this.icon, required this.title, required this.subtitle, required this.installed, required this.onInstall});

  final IconData icon;
  final String title;
  final String subtitle;
  final bool installed;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: installed ? scheme.primaryContainer.withValues(alpha: 0.45) : scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800)),
                Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          installed
              ? const StatusChip(label: 'Installed', icon: Icons.check_circle_rounded, tone: ChipTone.good)
              : FilledButton.tonal(onPressed: onInstall, child: const Text('Install')),
        ],
      ),
    );
  }
}

/// A tiny FetchNet window in the light or dark theme (System: both, split).
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.mode});

  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    Widget screen(bool dark) {
      final bg = dark ? const Color(0xFF1A1230) : const Color(0xFFF5F0FF);
      final card = dark ? const Color(0xFF2A1F45) : Colors.white;
      final line = dark ? const Color(0xFF4A3D6B) : const Color(0xFFE2D8F7);
      return ColoredBox(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(5)),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(6)),
                  padding: const EdgeInsets.all(5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final w in const [0.9, 0.6, 0.75]) ...[
                        FractionallySizedBox(
                          widthFactor: w,
                          child: Container(height: 4, decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(2))),
                        ),
                        const SizedBox(height: 4),
                      ],
                      const Spacer(),
                      Container(
                        height: 8,
                        decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(4)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AspectRatio(
      aspectRatio: 3 / 4,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: switch (mode) {
            ThemeMode.light => screen(false),
            ThemeMode.dark => screen(true),
            ThemeMode.system => Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: ClipRect(child: OverflowBox(alignment: Alignment.centerLeft, maxWidth: double.infinity, child: _Half(child: screen(false))))),
                  Expanded(child: ClipRect(child: OverflowBox(alignment: Alignment.centerRight, maxWidth: double.infinity, child: _Half(child: screen(true))))),
                ],
              ),
          },
        ),
      ),
    );
  }
}

/// Lays a full-width screen out inside half of the preview (each half shows
/// its side of the same picture).
class _Half extends StatelessWidget {
  const _Half({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => SizedBox(width: c.maxHeight * 3 / 4, child: child),
      );
}
