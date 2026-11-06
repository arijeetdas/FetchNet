import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../models/youtube_models.dart';
import '../../services/sites_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/site_icon.dart';
import '../settings/settings_widgets.dart';
import '../shell/home_shell.dart';
import 'google_sign_in_screen.dart';

/// Settings → YouTube Settings: Google sign-in, thumbnail downloads, tags.
class YouTubeSettingsScreen extends StatefulWidget {
  const YouTubeSettingsScreen({super.key});

  @override
  State<YouTubeSettingsScreen> createState() => _YouTubeSettingsScreenState();
}

class _YouTubeSettingsScreenState extends State<YouTubeSettingsScreen> {
  @override
  void initState() {
    super.initState();
    // Keep the name and photo current.
    AppScope.of(context).youtube.refresh();
  }

  Future<void> _signIn() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const GoogleSignInScreen()));
    if (ok == true && mounted) showSnack(context, 'Sign in Successful', kind: ToastKind.success);
  }

  Future<void> _signOut() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Sign out of YouTube?',
      message: 'FetchNet will sign this Google account out of its built-in browser. You can sign in again any time.',
      confirmLabel: 'Sign out',
    );
    if (!confirmed || !mounted) return;
    final youtube = AppScope.of(context).youtube;
    await youtube.signOut();
    if (!mounted) return;
    showSnack(
      context,
      youtube.signedIn ? 'Couldn\'t sign out completely. Try again.' : 'Signed out of YouTube',
      kind: youtube.signedIn ? ToastKind.error : ToastKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final youtube = services.youtube;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = Breakpoints.isWide(context);

    final body = ListenableBuilder(
      listenable: youtube,
      builder: (context, _) => ListView(
        padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 0, wide ? 28 : 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionLabel('Account'),
                  SettingsCard(
                    children: [
                      if (!youtube.isSupported)
                        const SettingsRow(
                          leading: BrandGlyph(brand: SiteBrand.youtube, size: 42),
                          title: 'Sign in to YouTube',
                          subtitle: 'Needs the built-in browser, which isn\'t available on this device.',
                        )
                      else if (youtube.signedIn)
                        _AccountRow(
                          profile: youtube.profile,
                          busy: youtube.busy,
                          onSignOut: _signOut,
                        )
                      else
                        SettingsRow(
                          leading: const BrandGlyph(brand: SiteBrand.youtube, size: 42),
                          title: 'Sign in to YouTube with Google',
                          subtitle: 'For age-restricted videos, videos YouTube blocks for anonymous downloads, '
                              'and a personal YouTube feed in FetchNet.',
                          trailing: GradientButton(label: 'Sign in', icon: Icons.login_rounded, height: 42, onPressed: _signIn),
                        ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.shield_outlined, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'You sign in on Google\'s own page. The sign-in stays in FetchNet\'s built-in browser on '
                              'this device. FetchNet passes its cookies to yt-dlp only when a download can\'t work '
                              'without them.',
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SectionLabel('Download options'),
                  SettingsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        secondary: const _TileIcon(Icons.image_rounded),
                        value: youtube.thumbnailDownloads,
                        onChanged: youtube.setThumbnailDownloads,
                        title: const Text('Thumbnail downloads'),
                        subtitle: const Text('Adds a Thumbnail tab next to Video and Audio, with a choice of sizes. '
                            'YouTube videos only.'),
                      ),
                      const Divider(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        secondary: const _TileIcon(Icons.sell_rounded),
                        value: youtube.showTags,
                        onChanged: youtube.setShowTags,
                        title: const Text('Show video tags'),
                        subtitle: const Text('Lists a video\'s tags under the Download button, with a button to copy '
                            'them all. YouTube videos only.'),
                      ),
                      const Divider(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        secondary: const _TileIcon(Icons.image_aspect_ratio_rounded),
                        value: youtube.videoCoverArt,
                        onChanged: youtube.setVideoCoverArt,
                        title: const Text('Thumbnail as cover art'),
                        subtitle: const Text('Audio downloads of YouTube videos get the video\'s thumbnail as their '
                            'cover art. MP3 and M4A; needs FFmpeg.'),
                      ),
                    ],
                  ),
                  const SectionLabel('YouTube Music'),
                  SettingsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        secondary: const _TileIcon(Icons.album_rounded),
                        value: youtube.musicCoverArt,
                        onChanged: youtube.setMusicCoverArt,
                        title: const Text('Album cover art'),
                        subtitle: const Text('Audio downloads from music.youtube.com links get the song\'s square '
                            'album cover built into the file, so music players show it. MP3 and M4A; needs FFmpeg.'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('YouTube Settings'),
        backgroundColor: wide ? null : Colors.transparent,
      ),
      extendBodyBehindAppBar: !wide,
      body: wide
          ? body
          : AuroraBackground(
              intensity: 0.5,
              child: SafeArea(bottom: false, child: body),
            ),
    );
  }
}

class _TileIcon extends StatelessWidget {
  const _TileIcon(this.icon);

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

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.profile, required this.busy, required this.onSignOut});

  final GoogleProfile? profile;
  final bool busy;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = profile?.name ?? 'Signed in';
    return Row(
      children: [
        GoogleAvatar(profile: profile, size: 52),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                profile?.email ?? 'Google account',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        FilledButton.tonalIcon(
          onPressed: busy ? null : onSignOut,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: busy ? const EnergyLoader(size: 18) : const Icon(Icons.logout_rounded, size: 18),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}

/// The Google account photo, or the name's initial while it loads.
class GoogleAvatar extends StatelessWidget {
  const GoogleAvatar({super.key, required this.profile, this.size = 40});

  final GoogleProfile? profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = profile?.name ?? '';
    final url = profile?.avatarUrl;
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: AppColors.brandGradient),
      child: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundImage: url == null ? null : NetworkImage(url),
        onForegroundImageError: url == null ? null : (_, _) {},
        child: Text(
          name.isEmpty ? '?' : name[0].toUpperCase(),
          style: TextStyle(
            color: scheme.onPrimaryContainer,
            fontWeight: FontWeight.w900,
            fontSize: size * 0.4,
          ),
        ),
      ),
    );
  }
}
