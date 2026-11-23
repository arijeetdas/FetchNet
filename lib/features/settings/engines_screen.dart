import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_services.dart';
import '../../engine/engine.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../shell/home_shell.dart';
import '../../widgets/sub_page.dart';
import 'settings_widgets.dart';

const ytDlpRepo = 'https://github.com/yt-dlp/yt-dlp';
const ytDlpSites = 'https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md';
const ytDlpLicense = 'https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE';
const youtubedlAndroidRepo = 'https://github.com/JunkFood02/youtubedl-android';
const galleryDlRepo = 'https://codeberg.org/mikf/gallery-dl';
const galleryDlSites = 'https://github.com/mikf/gallery-dl/blob/master/docs/supportedsites.md';
const galleryDlLicense = 'https://codeberg.org/mikf/gallery-dl/src/branch/master/LICENSE';

/// Settings → Engines: yt-dlp and gallery-dl, each with its version, how it
/// runs here, its update button, links and credits. The switches (keep up
/// to date, Images & posts) stay on the main Settings page.
class EnginesScreen extends StatelessWidget {
  const EnginesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = Breakpoints.isWide(context);
    final android = !kIsWeb && Platform.isAndroid;
    final macos = !kIsWeb && Platform.isMacOS;

    final body = ListView(
      padding: EdgeInsets.fromLTRB(wide ? 28 : 16, MediaQuery.paddingOf(context).top, wide ? 28 : 16, 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'FetchNet doesn\'t download anything by itself. Two free, open-source engines do the work, and '
                        'they update on their own, without an app update.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
                      ),
                    ),
                  ],
                ),

                // ───── yt-dlp ─────
                const SectionLabel('Video & audio · yt-dlp'),
                _EngineCard(
                  name: 'yt-dlp',
                  role: 'Video and audio from YouTube and thousands of other sites',
                  icon: Icons.smart_display_rounded,
                  status: services.engine.status,
                  supported: services.engine.isSupported,
                  lastChecked: () => services.prefs.lastEngineUpdateCheck,
                  runsAs: android
                      ? 'Built into the app, with Python, FFmpeg and QuickJS'
                      : 'Official standalone build, in FetchNet\'s own folder',
                  maintainers: 'The yt-dlp contributors',
                  onUpdate: services.engine.update,
                  onRetry: services.engine.initialize,
                  links: [
                    const _EngineLink(Icons.code_rounded, 'Source code', 'github.com/yt-dlp/yt-dlp', ytDlpRepo),
                    const _EngineLink(Icons.public_rounded, 'Supported sites', 'The full list on GitHub', ytDlpSites),
                    const _EngineLink(Icons.balance_rounded, 'License', 'Unlicense', ytDlpLicense),
                    if (android)
                      const _EngineLink(
                        Icons.android_rounded,
                        'youtubedl-android',
                        'Runs yt-dlp on Android · GPL-3.0',
                        youtubedlAndroidRepo,
                      ),
                  ],
                  credits:
                      'yt-dlp is maintained by its own community of contributors, as a fork of youtube-dl.'
                      '${android ? ' On Android it runs through youtubedl-android by JunkFood02 (originally by yausername), '
                                'which bundles Python, FFmpeg and QuickJS.' : ''}'
                      ' FetchNet is not affiliated with yt-dlp.',
                ),

                // ───── gallery-dl ─────
                const SectionLabel('Images & posts · gallery-dl'),
                _EngineCard(
                  name: 'gallery-dl',
                  role: 'Every image, video and audio file of posts and galleries',
                  icon: Icons.collections_rounded,
                  status: services.gallery.engine.status,
                  supported: services.gallery.engine.isSupported,
                  enabled: () => services.prefs.galleryEnabled,
                  lastChecked: () => services.prefs.lastGalleryUpdateCheck,
                  runsAs: android
                      ? 'Official Python package from PyPI, run by the Python built in for yt-dlp'
                      : macos
                      ? 'gallery-dl\'s nightly standalone build, or one installed with Homebrew'
                      : 'Official standalone build from Codeberg, checked against its checksums',
                  maintainers: 'Mike Fährmann (mikf) and contributors',
                  onUpdate: services.gallery.engine.update,
                  onRetry: services.gallery.engine.initialize,
                  links: const [
                    _EngineLink(Icons.code_rounded, 'Source code', 'codeberg.org/mikf/gallery-dl', galleryDlRepo),
                    _EngineLink(Icons.public_rounded, 'Supported sites', 'The full list', galleryDlSites),
                    _EngineLink(Icons.balance_rounded, 'License', 'GPL-2.0', galleryDlLicense),
                  ],
                  credits:
                      'gallery-dl is written by Mike Fährmann (mikf) and its contributors.'
                      '${android ? ' On Android it uses requests, urllib3, idna, certifi and charset-normalizer from PyPI.' : ''}'
                      ' FetchNet downloads the official release at runtime and is not affiliated with gallery-dl.',
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.tune_rounded, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '"Keep engines up to date" and "Images & posts" are switched on or off on the main Settings page.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );

    return SubPageScaffold(title: 'Engines', background: !wide, body: body);
  }
}

class _EngineLink {
  const _EngineLink(this.icon, this.title, this.subtitle, this.url);

  final IconData icon;
  final String title;
  final String subtitle;
  final String url;
}

/// One engine: header with its status, the facts, Check for updates, links
/// and credits.
class _EngineCard extends StatefulWidget {
  const _EngineCard({
    required this.name,
    required this.role,
    required this.icon,
    required this.status,
    required this.supported,
    required this.lastChecked,
    required this.runsAs,
    required this.maintainers,
    required this.onUpdate,
    required this.onRetry,
    required this.links,
    required this.credits,
    this.enabled,
  });

  final String name;
  final String role;
  final IconData icon;
  final ValueNotifier<EngineStatus> status;
  final bool supported;

  /// Switched off in Settings (gallery-dl's "Images & posts").
  final bool Function()? enabled;
  final DateTime? Function() lastChecked;
  final String runsAs;
  final String maintainers;
  final Future<String> Function() onUpdate;
  final Future<void> Function() onRetry;
  final List<_EngineLink> links;
  final String credits;

  @override
  State<_EngineCard> createState() => _EngineCardState();
}

class _EngineCardState extends State<_EngineCard> {
  bool _busy = false;

  Future<void> _update() async {
    setState(() => _busy = true);
    final message = await widget.onUpdate();
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(context, message, kind: message.startsWith('Update failed') ? ToastKind.error : ToastKind.success);
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    await widget.onRetry();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<EngineStatus>(
      valueListenable: widget.status,
      builder: (context, status, _) {
        final enabled = widget.enabled?.call() ?? true;
        final (label, tone) = _statusOf(status, supported: widget.supported, enabled: enabled);
        final working =
            _busy ||
            status.state == EngineState.updating ||
            status.state == EngineState.installing ||
            status.state == EngineState.initializing;
        final failed = status.state == EngineState.error;
        return SettingsCard(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: AppColors.brandGradient,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(widget.icon, color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.name, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900)),
                        const SizedBox(height: 2),
                        Text(widget.role, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        const SizedBox(height: 8),
                        _StatusChip(label: label, tone: tone),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (status.state == EngineState.installing || status.state == EngineState.updating) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (status.message != null) Text(status.message!, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 6),
                    GradientProgressBar(value: status.progress, height: 6),
                  ],
                ),
              ),
            ],
            if (failed && status.message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(14)),
                  child: Text(
                    status.message!,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
                  ),
                ),
              ),
            // Version, then its update button, then when it last checked.
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
              child: _FactBox(
                children: [
                  _FactRow(
                    icon: Icons.verified_rounded,
                    label: 'Version',
                    value: status.version ?? (widget.supported ? '—' : 'Not available'),
                    highlighted: status.version != null,
                  ),
                ],
              ),
            ),
            if (widget.supported)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                child: failed
                    ? GradientButton(
                        label: 'Retry setup',
                        icon: Icons.refresh_rounded,
                        expand: true,
                        height: 50,
                        loading: _busy,
                        onPressed: enabled ? _retry : null,
                      )
                    : GradientButton(
                        label: status.state == EngineState.updating ? 'Updating…' : 'Check for updates',
                        icon: Icons.system_update_alt_rounded,
                        expand: true,
                        height: 50,
                        loading: working,
                        onPressed: enabled && status.isReady && !working ? _update : null,
                      ),
              ),
            if (!enabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                child: Text(
                  'Turn on "Images & posts" in Settings to set up and update ${widget.name}.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: _FactBox(
                children: [
                  _FactRow(icon: Icons.update_rounded, label: 'Last checked', value: _ago(widget.lastChecked())),
                  _FactDivider(),
                  _FactRow(icon: Icons.memory_rounded, label: 'Runs as', value: widget.runsAs, wrap: true),
                  _FactDivider(),
                  _FactRow(icon: Icons.groups_rounded, label: 'Maintained by', value: widget.maintainers, wrap: true),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < widget.links.length; i++) ...[
              if (i > 0) const Divider(indent: 16, endIndent: 16, height: 1),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 18),
                leading: Icon(widget.links[i].icon, color: scheme.primary),
                title: Text(widget.links[i].title, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(widget.links[i].subtitle),
                trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                onTap: () => launchUrl(Uri.parse(widget.links[i].url), mode: LaunchMode.externalApplication),
              ),
            ],
            // Credits.
            Container(
              margin: const EdgeInsets.fromLTRB(18, 6, 18, 18),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.favorite_rounded, color: Colors.redAccent, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.credits,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.45, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static (String, _Tone) _statusOf(EngineStatus s, {required bool supported, required bool enabled}) {
    if (!supported || s.state == EngineState.unsupported) return ('Not available', _Tone.muted);
    if (!enabled) return ('Off', _Tone.muted);
    return switch (s.state) {
      EngineState.ready => ('Ready', _Tone.good),
      EngineState.updating => ('Updating', _Tone.busy),
      EngineState.installing => ('Installing', _Tone.busy),
      EngineState.initializing => ('Starting', _Tone.busy),
      EngineState.error => ('Needs attention', _Tone.bad),
      EngineState.unsupported => ('Not available', _Tone.muted),
    };
  }

  /// `Just now`, `12 min ago`, `3 h ago`, `2 days ago`, `Never`.
  static String _ago(DateTime? time) {
    if (time == null) return 'Never';
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return d.inDays == 1 ? 'Yesterday' : '${d.inDays} days ago';
  }
}

enum _Tone { good, busy, bad, muted }

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.tone});

  final String label;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const green = Color(0xFF16A34A);
    final (bg, fg, icon) = switch (tone) {
      _Tone.good => (green.withValues(alpha: 0.14), green, Icons.check_circle_rounded),
      _Tone.busy => (scheme.primaryContainer, scheme.onPrimaryContainer, Icons.autorenew_rounded),
      _Tone.bad => (scheme.errorContainer, scheme.onErrorContainer, Icons.error_rounded),
      _Tone.muted => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, Icons.remove_circle_outline_rounded),
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

/// The rounded box the fact rows sit in.
class _FactBox extends StatelessWidget {
  const _FactBox({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(children: children),
    );
  }
}

class _FactDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    indent: 16,
    endIndent: 16,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
  );
}

/// A label and its value, like the build rows of "FetchNet for (platform)".
class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.icon,
    required this.label,
    required this.value,
    this.highlighted = false,
    this.wrap = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool highlighted;

  /// Long values go under the label instead of beside it.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelText = Text(
      label,
      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
    );
    final valueStyle = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w800,
      color: highlighted ? Colors.white : scheme.onSurface,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: wrap ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: highlighted ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          if (wrap)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  labelText,
                  const SizedBox(height: 3),
                  Text(value, style: valueStyle),
                ],
              ),
            )
          else ...[
            Expanded(child: labelText),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  gradient: highlighted ? AppColors.brandGradient : null,
                  color: highlighted ? null : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: valueStyle),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The Engines row on the main Settings page: both versions at a glance.
class EnginesSummaryTile extends StatelessWidget {
  const EnginesSummaryTile({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final yt = services.engine;
    final gdl = services.gallery.engine;
    return ListenableBuilder(
      listenable: Listenable.merge([yt.status, gdl.status]),
      builder: (context, _) {
        String part(String name, EngineStatus s, bool supported, {bool enabled = true}) {
          if (!supported) return '$name not available';
          if (!enabled) return '$name off';
          if (s.state == EngineState.error) return '$name needs attention';
          if (s.state == EngineState.installing) return '$name installing…';
          if (s.state == EngineState.updating) return '$name updating…';
          return s.version == null ? '$name starting…' : '$name ${s.version}';
        }

        final attention =
            yt.status.value.state == EngineState.error ||
            (services.prefs.galleryEnabled && gdl.status.value.state == EngineState.error);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(13)),
            child: const Icon(Icons.memory_rounded, color: Colors.white, size: 22),
          ),
          title: const Text('Engines', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(
            [
              part('yt-dlp', yt.status.value, yt.isSupported),
              part('gallery-dl', gdl.status.value, gdl.isSupported, enabled: services.prefs.galleryEnabled),
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (attention) Icon(Icons.error_rounded, color: Theme.of(context).colorScheme.error, size: 20),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EnginesScreen())),
        );
      },
    );
  }
}
