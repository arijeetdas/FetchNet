import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/app_services.dart';
import '../../core/platform/pip.dart';
import '../../services/web_session.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../browser/browser_screen.dart';
import 'player/yt_player_controller.dart';
import 'player/yt_player_view.dart';
import 'youtube_hub.dart';
import 'youtube_widgets.dart';

bool get _isAndroid => !kIsWeb && Platform.isAndroid;
bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// The watch page: FetchNet's player, the video's details, actions and
/// "Up next". Back keeps the video playing in the mini player.
class YouTubeWatchScreen extends StatefulWidget {
  const YouTubeWatchScreen({super.key, required this.hub});

  final YouTubeHub hub;

  /// Slides up from the bottom, like a sheet.
  static Route<T> route<T>(YouTubeHub hub) => PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 360),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, _, _) => YouTubeWatchScreen(hub: hub),
    transitionsBuilder: (context, a, _, child) {
      final curve = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      return SlideTransition(
        position: Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(curve),
        child: FadeTransition(opacity: curve, child: child),
      );
    },
  );

  @override
  State<YouTubeWatchScreen> createState() => _YouTubeWatchScreenState();
}

class _YouTubeWatchScreenState extends State<YouTubeWatchScreen> {
  YtPlayerController get c => widget.hub.player;

  bool _fullscreen = false;

  /// Turned sideways (phones): full screen without the button.
  bool _autoFull = false;

  /// Left full screen while holding the phone sideways: stay upright.
  bool _portraitLocked = false;
  bool _descriptionOpen = false;
  bool _pipSupported = false;
  String? _shownId;
  StreamSubscription<bool>? _playingSub;

  @override
  void initState() {
    super.initState();
    Pip.isSupported().then((v) {
      if (mounted) setState(() => _pipSupported = v);
    });
    Pip.active.addListener(_onPip);
    _playingSub = c.player.stream.playing.listen((_) => _updateAutoPip());
    _updateAutoPip();
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    Pip.active.removeListener(_onPip);
    Pip.setAutoEnter(false);
    if (_fullscreen || _autoFull || _portraitLocked) _exitFullscreenSystem();
    super.dispose();
  }

  void _onPip() {
    if (mounted) setState(() {});
  }

  /// Leaving the app while a video plays opens PiP by itself.
  void _updateAutoPip() {
    if (!_isAndroid) return;
    final a = c.aspect;
    Pip.setAutoEnter(c.player.state.playing && !c.listenOnly, width: a.width, height: a.height);
  }

  bool get _portraitVideo {
    final a = c.aspect;
    return a.height > a.width;
  }

  Future<void> _enterFullscreenSystem() async {
    if (_isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(
        _portraitVideo
            ? const [DeviceOrientation.portraitUp]
            : const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      );
    } else if (_isDesktop) {
      await defaultEnterNativeFullscreen();
    }
  }

  Future<void> _exitFullscreenSystem() async {
    if (_isAndroid) {
      await SystemChrome.setPreferredOrientations(const []);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else if (_isDesktop) {
      await defaultExitNativeFullscreen();
    }
  }

  Future<void> _toggleFullscreen() async {
    if (_autoFull && !_fullscreen) return _leaveSideways();
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    if (next) {
      _portraitLocked = false;
      await _enterFullscreenSystem();
    } else if (_isAndroid) {
      // Upright again even if the phone is still held sideways.
      _portraitLocked = true;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    } else {
      await _exitFullscreenSystem();
    }
  }

  Future<void> _leaveSideways() async {
    _portraitLocked = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  }

  /// Hides the system bars while the phone is held sideways.
  void _syncAutoFull(bool sideways) {
    if (sideways == _autoFull) return;
    _autoFull = sideways;
    if (_fullscreen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(sideways ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    });
  }

  void _minimize() => Navigator.of(context).maybePop();

  /// System PiP on Android; the in-app mini player elsewhere.
  Future<void> _pip() async {
    if (_pipSupported) {
      final a = c.aspect;
      if (await Pip.enter(width: a.width, height: a.height)) return;
    }
    if (!mounted) return;
    if (_fullscreen) await _toggleFullscreen();
    _minimize();
  }

  Future<void> _download() => downloadYouTubeVideo(context, id: c.videoId!, title: c.title, thumbnail: c.thumbnail);

  Future<void> _share() => shareYouTubeLink(context, c.watchUrl, title: c.title);

  Future<void> _subscribe() async {
    final info = c.info;
    if (info == null) return;
    if (info.subscribed == true) {
      final ok = await confirmDialog(
        context,
        title: 'Unsubscribe?',
        message: 'Stop following ${info.channel ?? 'this channel'}?',
        confirmLabel: 'Unsubscribe',
        destructive: true,
      );
      if (!ok) return;
    }
    final error = await c.toggleSubscribe();
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, kind: ToastKind.error);
    } else {
      showSnack(
        context,
        c.info?.subscribed == true ? 'Subscribed to ${info.channel ?? 'the channel'}' : 'Unsubscribed',
        kind: ToastKind.success,
      );
    }
  }

  void _openChannel() {
    final info = c.info;
    final id = info?.channelId;
    if (id == null) return;
    widget.hub.openChannel(id, name: info!.channel, avatar: info.channelAvatar);
  }

  /// The real YouTube page in the built-in browser (videos that won't play).
  Future<void> _openPage() async {
    await c.player.pause();
    if (!mounted) return;
    final url = WebSession.isMobile ? 'https://m.youtube.com/watch?v=${c.videoId}' : c.watchUrl;
    final grab = await Navigator.of(context)
        .push<BrowserGrab>(MaterialPageRoute(builder: (_) => BrowserScreen(initialUrl: url, youtubeHandoff: false)));
    if (grab != null && mounted) Navigator.of(context).pop(grab);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 600) c.loadMoreRelated();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (Pip.active.value) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: YtPlayerView(controller: c, fullscreen: true, onToggleFullscreen: () {}, bare: true),
      );
    }

    final size = MediaQuery.sizeOf(context);
    // Turning a phone sideways goes full screen, like YouTube.
    final sideways = _isAndroid && size.width > size.height && size.shortestSide < 600;
    _syncAutoFull(sideways);
    final full = _fullscreen || sideways;

    final player = YtPlayerView(
      controller: c,
      fullscreen: full,
      onToggleFullscreen: _toggleFullscreen,
      onMinimize: _minimize,
      onPip: _pip,
      onOpenInBrowser: BrowserScreen.isSupported ? _openPage : null,
    );

    if (full) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _toggleFullscreen();
        },
        child: Scaffold(backgroundColor: Colors.black, body: player),
      );
    }

    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (_shownId != c.videoId) {
          _shownId = c.videoId;
          _descriptionOpen = false;
        }
        final details = _Details(
          controller: c,
          descriptionOpen: _descriptionOpen,
          signedIn: AppScope.of(context).youtube.signedIn,
          onToggleDescription: () => setState(() => _descriptionOpen = !_descriptionOpen),
          onSubscribe: _subscribe,
          onOpenChannel: _openChannel,
          onDownload: _download,
          onShare: _share,
          onPip: _pip,
          pipLabel: _pipSupported ? 'PiP' : 'Mini player',
        );
        final upNext = _UpNext(controller: c, hub: widget.hub);

        return Scaffold(
          body: AuroraBackground(
            intensity: 0.35,
            child: LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth >= 1000) {
                  return SafeArea(
                    bottom: false,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(24, 16, 12, 32),
                            children: [
                              Row(
                                children: [
                                  YtBackButton(
                                    onPressed: _minimize,
                                    icon: Icons.keyboard_arrow_down_rounded,
                                    tooltip: 'Minimize',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(22),
                                child: AspectRatio(aspectRatio: 16 / 9, child: player),
                              ),
                              const SizedBox(height: 16),
                              details,
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 430,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _onScroll,
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(12, 64, 20, 32),
                              children: upNext.children(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return Column(
                  children: [
                    // The status bar sits on black above the video.
                    AnnotatedRegion<SystemUiOverlayStyle>(
                      value: SystemUiOverlayStyle.light,
                      child: ColoredBox(
                        color: Colors.black,
                        child: SafeArea(
                          bottom: false,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 900),
                              child: AspectRatio(aspectRatio: 16 / 9, child: player),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child: ListView(
                          padding: EdgeInsets.fromLTRB(16, 14, 16, 24 + MediaQuery.paddingOf(context).bottom),
                          children: [details, ...upNext.children(context)],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.controller,
    required this.descriptionOpen,
    required this.signedIn,
    required this.onToggleDescription,
    required this.onSubscribe,
    required this.onOpenChannel,
    required this.onDownload,
    required this.onShare,
    required this.onPip,
    required this.pipLabel,
  });

  final YtPlayerController controller;
  final bool descriptionOpen;
  final bool signedIn;
  final VoidCallback onToggleDescription;
  final VoidCallback onSubscribe;
  final VoidCallback onOpenChannel;
  final VoidCallback onDownload;
  final VoidCallback onShare;
  final VoidCallback onPip;
  final String pipLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = controller;
    final info = c.info;
    final preview = c.preview;
    final title = c.title;
    final channel = info?.channel ?? preview?.channel;
    final avatar = info?.channelAvatar ?? preview?.channelAvatar;
    final stats = [
      info?.views ?? preview?.views,
      info?.published ?? preview?.published,
      if (info?.likes != null) '${info!.likes} likes',
    ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
    final description = info?.description;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty)
          InkWell(
            onTap: description == null ? null : onToggleDescription,
            borderRadius: BorderRadius.circular(8),
            child: Text(
              title,
              maxLines: descriptionOpen ? null : 3,
              overflow: descriptionOpen ? null : TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.25),
            ),
          )
        else
          Container(
            height: 24,
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
          ),
        if (stats.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(stats, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 14),
        // Channel.
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: info?.channelId == null ? null : onOpenChannel,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      YtChannelAvatar(url: avatar, name: channel, size: 42),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              channel ?? (c.infoLoading ? 'Loading…' : 'YouTube'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            if (info?.subscribers != null)
                              Text(
                                info!.subscribers!,
                                maxLines: 1,
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (signedIn && info?.channelId != null) ...[
              const SizedBox(width: 8),
              YtSubscribeButton(subscribed: info!.subscribed, onPressed: onSubscribe),
            ],
          ],
        ),
        const SizedBox(height: 14),
        // Actions.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              _ActionPill(icon: Icons.download_rounded, label: 'Download', primary: true, onTap: onDownload),
              _ActionPill(
                icon: c.listenOnly ? Icons.headphones_rounded : Icons.headphones_outlined,
                label: 'Listen only',
                selected: c.listenOnly,
                onTap: c.streams?.audio == null && c.streams != null ? null : () => c.setListenOnly(!c.listenOnly),
              ),
              _ActionPill(icon: Icons.picture_in_picture_alt_rounded, label: pipLabel, onTap: onPip),
              _ActionPill(icon: Icons.share_rounded, label: 'Share', onTap: onShare),
            ],
          ),
        ),
        if (c.infoError != null && info == null) ...[
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(child: Text(c.infoError!, style: theme.textTheme.bodyMedium)),
                  TextButton(onPressed: c.retry, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ],
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: 14),
          _DescriptionBox(
            description: description,
            header: [info?.views, info?.published].whereType<String>().join('  ·  '),
            open: descriptionOpen,
            onToggle: onToggleDescription,
          ),
        ],
      ],
    );
  }
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = primary ? Colors.white : (selected ? scheme.onPrimaryContainer : scheme.onSurface);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: primary ? AppColors.brandGradient : null,
            color: primary
                ? null
                : (selected ? scheme.primaryContainer : scheme.surfaceContainerHigh.withValues(alpha: 0.9)),
            borderRadius: BorderRadius.circular(999),
            border: primary ? null : Border.all(color: scheme.outlineVariant.withValues(alpha: selected ? 0 : 0.35)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 20, color: fg),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: theme.textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DescriptionBox extends StatelessWidget {
  const _DescriptionBox({required this.description, required this.header, required this.open, required this.onToggle});

  final String description;
  final String header;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open ? null : onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (header.isNotEmpty) ...[
                  Text(header, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                ],
                if (open)
                  SelectableText(description, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45))
                else
                  Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                const SizedBox(height: 4),
                InkWell(
                  onTap: onToggle,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      open ? 'Show less' : '…more',
                      style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Up next" header with the autoplay switch, and the related videos.
class _UpNext {
  const _UpNext({required this.controller, required this.hub});

  final YtPlayerController controller;
  final YouTubeHub hub;

  List<Widget> children(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = controller;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 0, 6),
        child: Row(
          children: [
            Text('Up next', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const Spacer(),
            Text('Autoplay', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(width: 6),
            Switch(value: c.autoplay, onChanged: c.setAutoplay),
          ],
        ),
      ),
      for (final (i, v) in c.related.indexed)
        Container(
          decoration: i == 0 && c.autoplay
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
                )
              : null,
          margin: EdgeInsets.only(bottom: i == 0 && c.autoplay ? 6 : 0),
          child: YtCompactCard(
            video: v,
            onTap: () => hub.openVideo(v.id, preview: v),
            onDownload: () => downloadYouTubeVideo(context, id: v.id, title: v.title, thumbnail: v.thumbnail),
          ),
        ),
      if (c.loadingMore)
        const Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: EnergyLoader(size: 36)),
        ),
      if (c.infoLoading && c.related.isEmpty)
        const Padding(
          padding: EdgeInsets.all(28),
          child: Center(child: EnergyLoader(size: 40)),
        ),
    ];
  }
}
