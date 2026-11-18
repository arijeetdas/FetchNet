import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/device_environment.dart';
import '../../engine/engine.dart';
import '../../models/download_models.dart';
import '../../models/gallery_models.dart';
import '../../models/media_info.dart';
import '../../services/fetch_service.dart';
import '../../services/gallery_service.dart';
import '../../services/sites_service.dart';
import '../../services/web_session.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/kind_icon.dart';
import '../../widgets/motion/living_logo.dart';
import '../../widgets/motion/motion_core.dart';
import '../browser/browser_screen.dart';
import '../shell/home_shell.dart';
import '../youtube/youtube_screen.dart';
import '../youtube/youtube_settings_screen.dart';
import 'fetch_progress.dart';
import 'home_kit.dart';
import 'link_dock.dart';
import 'media_result_view.dart';
import 'post_result_view.dart';
import 'sites_panel.dart';
import 'status_deck.dart';

enum _Phase { idle, loading, error, result }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final AppServices _services;

  _Phase _phase = _Phase.idle;
  MediaInfo? _info;

  /// What gallery-dl found at the link (files of a post), next to or
  /// instead of yt-dlp's [_info].
  GalleryPost? _post;

  /// gallery-dl is still looking while yt-dlp's result is shown.
  bool _postLoading = false;
  FetchException? _error;
  String? _lastUrl;
  List<String> _lastArgs = const [];
  int _requestToken = 0;

  /// What each engine is doing while a link is read (the progress card).
  LaneState _ytLane = LaneState.waiting;
  LaneState _galleryLane = LaneState.waiting;

  @override
  void initState() {
    super.initState();
    _services = AppScope.of(context);
    _services.incomingLink.addListener(_onIncomingLink);
    _controller.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _onIncomingLink());
  }

  @override
  void dispose() {
    _services.incomingLink.removeListener(_onIncomingLink);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onIncomingLink() {
    final text = _services.incomingLink.value;
    if (text == null) return;
    _services.incomingLink.value = null;
    final url = extractUrl(text);
    if (url == null) return;
    _controller.text = url;
    _fetch();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (mounted) showSnack(context, 'Your clipboard is empty');
      return;
    }
    _controller.text = extractUrl(text) ?? text;
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    _fetch();
  }

  String? _currentUrl() {
    final url = extractUrl(_controller.text);
    if (url == null) {
      showSnack(context, 'That doesn\'t look like a link', kind: ToastKind.error);
    }
    return url;
  }

  Future<void> _fetch({String? url, List<String> requestArgs = const []}) async {
    url ??= _currentUrl();
    if (url == null) return;
    _focus.unfocus();
    final token = ++_requestToken;
    final gallery = _services.gallery;
    final galleryAllowed = gallery.enabled && !isYouTubeLink(url);
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _lastUrl = url;
      _lastArgs = requestArgs;
      _ytLane = LaneState.waiting;
      _galleryLane = galleryAllowed ? LaneState.working : LaneState.skipped;
    });
    // Sites gallery-dl knows (posts, galleries) are looked up by both engines
    // at once; yt-dlp's answer shows first and the post joins it.
    Future<GalleryPost>? post =
        galleryAllowed && await gallery.supports(url) == true ? gallery.fetch(url, requestArgs: requestArgs) : null;
    post?.ignore(); // Errors are read below; never unhandled.
    if (!mounted || token != _requestToken) return;
    setState(() {
      _ytLane = LaneState.working;
      if (post == null && galleryAllowed) _galleryLane = LaneState.waiting;
    });

    MediaInfo info;
    try {
      info = await _services.fetcher.fetch(url, requestArgs: requestArgs);
    } on FetchException catch (e) {
      if (!mounted || token != _requestToken) return;
      if (e.cancelled) {
        setState(() => _phase = _hasResult ? _Phase.result : _Phase.idle);
        return;
      }
      // yt-dlp couldn't read it: gallery-dl may (image posts, galleries).
      if (post == null && galleryAllowed && _worthTryingGallery(e)) {
        post = gallery.fetch(url, requestArgs: requestArgs);
      }
      if (post == null) {
        setState(() {
          _error = e;
          _phase = _Phase.error;
        });
        return;
      }
      setState(() {
        _ytLane = LaneState.failed;
        _galleryLane = LaneState.working;
      });
      try {
        final found = await post;
        if (!mounted || token != _requestToken) return;
        setState(() {
          _info = null;
          _post = found;
          _postLoading = false;
          _phase = _Phase.result;
        });
      } on FetchException catch (g) {
        if (!mounted || token != _requestToken) return;
        if (g.cancelled) {
          setState(() => _phase = _hasResult ? _Phase.result : _Phase.idle);
          return;
        }
        setState(() {
          _error = galleryErrorExplainsBetter(e, g) ? g : e;
          _phase = _Phase.error;
        });
      }
      return;
    }
    if (!mounted || token != _requestToken) return;
    setState(() {
      _info = info;
      _post = null;
      _postLoading = post != null;
      _phase = _Phase.result;
    });
    if (post == null) return;
    try {
      final found = await post;
      if (!mounted || token != _requestToken) return;
      // A profile's list of posts adds nothing to yt-dlp's own result.
      setState(() {
        _post = found.items.isEmpty ? null : found;
        _postLoading = false;
      });
    } catch (_) {
      if (mounted && token == _requestToken) setState(() => _postLoading = false);
    }
  }

  bool get _hasResult => _info != null || _post != null;

  /// Network trouble won't be different for gallery-dl.
  static bool _worthTryingGallery(FetchException e) {
    final m = e.message.toLowerCase();
    return !(m.contains('getaddrinfo') || m.contains('timed out') || m.contains('network is unreachable') ||
        m.contains('is not a valid url') || m.contains('private video'));
  }

  void _cancelFetch() {
    _requestToken++;
    _services.fetcher.cancel();
    _services.gallery.cancel();
    setState(() {
      _postLoading = false;
      _phase = _hasResult ? _Phase.result : _Phase.idle;
    });
  }

  void _clear() {
    _controller.clear();
    _services.gallery.cancel();
    setState(() {
      _phase = _Phase.idle;
      _info = null;
      _post = null;
      _postLoading = false;
      _error = null;
    });
  }

  /// yt-dlp's result, gallery-dl's post, or both behind a switch.
  Widget _buildResult() {
    final info = _info;
    final post = _post;
    final Widget? media = info == null
        ? null
        : info.isPlaylist
            ? _PlaylistView(
                key: ValueKey('pl-${info.url}'),
                info: info,
                onPick: (entry) {
                  _controller.text = entry.url;
                  _fetch(url: entry.url, requestArgs: info.requestArgs);
                },
              )
            : MediaResultView(key: ValueKey('res-${info.url}-${info.title}'), info: info);
    final Widget? postView = post == null
        ? null
        : PostResultView(
            key: ValueKey('post-${post.url}'),
            post: post,
            onOpenChild: (url) {
              _controller.text = url;
              _fetch(url: url, requestArgs: post.requestArgs);
            },
          );
    final Widget body;
    if (media != null && postView != null) {
      body = PostOrMediaSwitch(key: ValueKey('both-${post!.url}'), post: post, postView: postView, mediaView: media);
    } else {
      body = media ?? postView!;
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      key: ValueKey('result-${info?.url ?? post?.url}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        body,
        AnimatedSize(
          duration: homeDuration(context, const Duration(milliseconds: 300)),
          curve: Curves.easeOutCubic,
          child: !_postLoading
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        const EnergyLoader(size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'gallery-dl is looking for images and other files in this post…',
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        if (!(info?.isPlaylist ?? false) && post?.items.isEmpty != true)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Center(
              child: TextButton.icon(
                onPressed: () => _openBrowserMode(_lastUrl),
                icon: const Icon(Icons.travel_explore_rounded, size: 18),
                label: const Text('Not the right media? Try Browser Mode'),
                style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _openBrowserMode([String? url]) async {
    url ??= extractUrl(_controller.text);
    if (!BrowserScreen.isSupported) {
      await _useBrowserCookies(url);
      return;
    }
    final result = await Navigator.of(context)
        .push<BrowserGrab>(MaterialPageRoute(builder: (_) => BrowserScreen(initialUrl: url)));
    await _handleGrab(result);
  }

  /// A site tile on the Sites panel.
  Future<void> _openSite(Site site) async {
    if (site.brand == SiteBrand.youtube) {
      if (!BrowserScreen.isSupported) {
        await _openBrowserMode(site.url);
        return;
      }
      await _handleGrab(await openYouTube(context));
      return;
    }
    await _openBrowserMode(site.url);
  }

  Future<void> _openYouTubeSettings() =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeSettingsScreen()));

  Future<void> _handleGrab(BrowserGrab? result) async {
    if (result == null || !mounted) return;
    _controller.text = result.pageUrl;
    await _fetch(url: result.mediaUrl, requestArgs: result.requestArgs);
    // Media URLs often have no title: use the page's. Audio picked in the
    // browser opens on the Audio tab.
    final info = _info;
    final usePageTitle = result.pageTitle != null && result.mediaUrl != result.pageUrl;
    if (info != null && _phase == _Phase.result && (usePageTitle || result.audio)) {
      setState(() {
        _info = MediaInfo(
          url: info.url,
          title: usePageTitle ? result.pageTitle! : info.title,
          raw: info.raw,
          thumbnail: info.thumbnail,
          uploader: info.uploader ?? Uri.tryParse(result.pageUrl)?.host,
          duration: info.duration,
          extractor: info.extractor,
          viewCount: info.viewCount,
          isLive: info.isLive,
          entries: info.entries,
          requestArgs: info.requestArgs,
          preferAudio: result.audio,
        );
      });
    }
  }

  /// Desktop fallback: let yt-dlp read cookies from an installed browser.
  Future<void> _useBrowserCookies(String? url) async {
    url ??= _lastUrl;
    if (url == null) return;
    const browsers = ['firefox', 'chrome', 'edge', 'brave', 'chromium', 'opera', 'vivaldi', 'safari'];
    final scheme = Theme.of(context).colorScheme;
    final picked = await showFetchNetDialog<String>(
      context: context,
      barrierDismissible: true,
      lockBack: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        icon: Icon(Icons.cookie_rounded, color: scheme.primary),
        title: const Text('Use your browser\'s sign-in'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                BrowserScreen.isSupported
                    ? 'FetchNet can reuse the cookies of a browser where you\'re already signed in to this site.'
                    : 'The built-in browser isn\'t available on ${DeviceEnvironment.platformDisplayName}. Instead, '
                          'FetchNet can reuse the cookies of a browser where you\'re signed in to this site.',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final b in browsers)
                    DialogButton(
                      label: b[0].toUpperCase() + b.substring(1),
                      icon: Icons.public_rounded,
                      onPressed: () => Navigator.pop(context, b),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          if (!BrowserScreen.isSupported && url != null)
            DialogButton(
              label: 'Open in browser',
              icon: Icons.open_in_new_rounded,
              onPressed: () => launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication),
            ),
          DialogButton(label: 'Cancel', icon: Icons.close_rounded, onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
    if (picked == null) return;
    await _fetch(url: url, requestArgs: ['--cookies-from-browser', picked]);
  }

  Widget _phaseView() {
    return switch (_phase) {
      _Phase.idle => Center(
        key: const ValueKey('idle'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _Capabilities(onTap: () => _focus.requestFocus()),
        ),
      ),
      _Phase.loading => FetchProgressCard(
        key: ValueKey('loading-$_requestToken'),
        host: _hostOf(_lastUrl),
        ytdlp: _ytLane,
        gallery: _galleryLane,
        onCancel: _cancelFetch,
      ),
      _Phase.error => _ErrorCard(
        key: ValueKey('error-$_requestToken'),
        error: _error!,
        onRetry: () => _fetch(url: _lastUrl, requestArgs: _lastArgs),
        onBrowser: () => _openBrowserMode(_lastUrl),
        onCookies: DeviceEnvironment.isDesktop ? () => _useBrowserCookies(_lastUrl) : null,
        onYouTubeSignIn: isYouTubeUrl(_lastUrl) && !_services.youtube.signedIn && BrowserScreen.isSupported
            ? _openYouTubeSettings
            : null,
      ),
      _Phase.result => _buildResult(),
    };
  }

  static String? _hostOf(String? url) {
    final host = Uri.tryParse(url ?? '')?.host.toLowerCase();
    if (host == null || host.isEmpty) return null;
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  @override
  Widget build(BuildContext context) {
    final wide = Breakpoints.isWide(context);
    final idle = _phase == _Phase.idle;

    final content = SafeArea(
      bottom: false,
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              wide ? 28 : 16,
              wide ? 24 : 10,
              wide ? 28 : 16,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            sliver: SliverConstrainedCrossAxis(
              maxExtent: 1080,
              sliver: SliverList.list(
                children: [
                  const EntranceMotion(child: _Header()),
                  const SizedBox(height: 16),
                  // App update, then yt-dlp / gallery-dl / add-on setup and updates.
                  const StatusDeck(),
                  // The living logo and the promise, while nothing is fetched.
                  AnimatedSize(
                    duration: homeDuration(context, const Duration(milliseconds: 420)),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: idle ? const _Hero() : const SizedBox(width: double.infinity),
                  ),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: EntranceMotion(
                        index: 2,
                        child: LinkDock(
                          controller: _controller,
                          focusNode: _focus,
                          loading: _phase == _Phase.loading,
                          onFetch: () => _fetch(),
                          onPaste: _paste,
                          onClear: _clear,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  AnimatedSize(
                    duration: homeDuration(context, const Duration(milliseconds: 380)),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: homeDuration(context, const Duration(milliseconds: 360)),
                      switchInCurve: expoOutCurve,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a),
                          child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(a), child: child),
                        ),
                      ),
                      layoutBuilder: (current, previous) =>
                          Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                      child: _phaseView(),
                    ),
                  ),
                  const _ActiveDownloads(),
                  const SizedBox(height: 20),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: EntranceMotion(
                        index: 4,
                        child: SitesPanel(onOpen: _openSite, onBrowser: () => _openBrowserMode()),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return wide ? content : AuroraBackground(intensity: 0.6, child: content);
  }
}

// ───────────── Header & hero ─────────────

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = Breakpoints.isWide(context);
    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What do you want to save today?', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 2),
          Text(
            'Videos, music, images and whole posts from YouTube and 1000+ other sites.',
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    return Row(
      children: [
        const FetchNetLogo(size: 46),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GradientText(
                'FetchNet',
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.8, height: 1.1),
              ),
              Text(
                'Paste. Pick. Done.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = Breakpoints.isWide(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          EntranceMotion(child: LivingLogo(size: wide ? 132 : 116)),
          const SizedBox(height: 4),
          EntranceMotion(
            index: 1,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'Paste a link. Pick a quality. Done.',
                maxLines: 1,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.4),
              ),
            ),
          ),
          const SizedBox(height: 4),
          EntranceMotion(
            index: 2,
            child: Text(
              'Video up to 4K, MP3 and M4A, and every image of a post.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────── Idle: what FetchNet can save ─────────────

class _Capabilities extends StatelessWidget {
  const _Capabilities({required this.onTap});

  /// Tapping a card puts the cursor in the link field.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final galleryOn = services.gallery.enabled;
    final items = [
      (Icons.movie_rounded, 'Video', 'Up to 4K, with its sound', true),
      (Icons.music_note_rounded, 'Audio', 'MP3 and M4A, with cover art', true),
      (Icons.collections_rounded, 'Images & posts', galleryOn ? 'Every file of a post or gallery' : 'Turn on in Settings → Engines', galleryOn),
      (Icons.sell_rounded, 'Thumbnails & tags', 'YouTube covers in every size', true),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 10.0;
        final columns = c.maxWidth >= 720 ? 4 : 2;
        final width = (c.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (i, (icon, title, body, on)) in items.indexed)
              SizedBox(
                width: width,
                child: EntranceMotion(
                  index: i,
                  delay: const Duration(milliseconds: 120),
                  child: _CapabilityCard(icon: icon, title: title, body: body, enabled: on, onTap: onTap),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.icon, required this.title, required this.body, required this.enabled, required this.onTap});

  final IconData icon;
  final String title;
  final String body;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PressableScale(
      child: Material(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Opacity(
            opacity: enabled ? 1 : 0.6,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      gradient: enabled ? tileGradient : null,
                      color: enabled ? null : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: enabled
                          ? [BoxShadow(color: AppColors.violetBright.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 5))]
                          : null,
                    ),
                    child: Icon(icon, color: enabled ? Colors.white : scheme.onSurfaceVariant, size: 20),
                  ),
                  const SizedBox(height: 10),
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────── Downloads in progress ─────────────

/// The downloads running right now, live, with a shortcut to Downloads.
class _ActiveDownloads extends StatelessWidget {
  const _ActiveDownloads();

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: services.downloads,
      builder: (context, _) {
        final active = services.downloads.tasks.where((t) => t.isActive).toList();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return AnimatedSize(
          duration: homeDuration(context, const Duration(milliseconds: 340)),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: active.isEmpty
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: EntranceMotion(
                        child: HomePanel(
                          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  PulseDot(color: scheme.primary, size: 9),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      active.length == 1 ? 'Downloading now' : 'Downloading now · ${active.length}',
                                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => services.tabRequest.value = 1,
                                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                                    label: const Text('Downloads'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              for (final t in active.take(3))
                                Padding(
                                  key: ValueKey(t.id),
                                  padding: const EdgeInsets.only(top: 6, right: 6),
                                  child: _TaskRow(task: t),
                                ),
                              if (active.length > 3)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    '+${active.length - 3} more in Downloads',
                                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = task.progress;
    final files = task.option.gallery?.count;
    final line = switch (task.status) {
      DownloadStatus.queued => 'Waiting in line',
      DownloadStatus.starting => 'Starting…',
      DownloadStatus.processing => task.stage ?? 'Finishing up…',
      _ => [
          if (p != null) '${(p * 100).round()}%',
          if (files != null && files > 1) '${task.filesDone} of $files files',
          formatSpeed(task.speed),
          formatEta(task.eta),
        ].where((s) => s.isNotEmpty).join(' · '),
    };
    final thumb = task.thumbnail;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 56,
            height: 36,
            child: thumb == null
                ? DecoratedBox(
                    decoration: const BoxDecoration(gradient: tileGradient),
                    child: Icon(kindIcon(task.option.kind), color: Colors.white, size: 18),
                  )
                : FadeInNetworkImage(
                    url: thumb,
                    cacheWidth: 160,
                    fallback: DecoratedBox(
                      decoration: const BoxDecoration(gradient: tileGradient),
                      child: Icon(kindIcon(task.option.kind), color: Colors.white, size: 18),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              GradientProgressBar(value: task.status == DownloadStatus.downloading ? p : null, height: 5),
              const SizedBox(height: 3),
              Text(
                line.isEmpty ? 'Downloading…' : line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────── Errors ─────────────

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    super.key,
    required this.error,
    required this.onRetry,
    required this.onBrowser,
    this.onCookies,
    this.onYouTubeSignIn,
  });

  final FetchException error;
  final VoidCallback onRetry;
  final VoidCallback onBrowser;
  final VoidCallback? onCookies;

  /// Set for YouTube links while nobody is signed in.
  final VoidCallback? onYouTubeSignIn;

  static bool _needsSignIn(String message) {
    final m = message.toLowerCase();
    return m.contains('sign in') || m.contains('login') || m.contains('log in') || m.contains('cookies') ||
        m.contains('not a bot') || m.contains('age-restricted') || m.contains('age restricted') ||
        m.contains('confirm your age') || m.contains('inappropriate') || m.contains('private') || m.contains('members');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final signIn = onYouTubeSignIn != null && _needsSignIn(error.message);
    return HomePanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [BoxShadow(color: scheme.error.withValues(alpha: 0.2), blurRadius: 14, offset: const Offset(0, 6))],
                ),
                child: Icon(Icons.search_off_rounded, color: scheme.onErrorContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Couldn\'t get this media', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    Text(
                      'Neither engine could read the link directly.',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            signIn
                ? 'YouTube wants a signed-in account for this video. Sign in with Google in YouTube Settings, '
                    'then try again.'
                : error.hint ??
                    'FetchNet couldn\'t read this link directly. Browser Mode lets you open the page, play the media, and grab it from there.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 6),
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text('Details', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    error.message,
                    style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (signIn)
                GradientButton(label: 'Sign in to YouTube', icon: Icons.login_rounded, onPressed: onYouTubeSignIn)
              else
                GradientButton(label: 'Open in Browser Mode', icon: Icons.travel_explore_rounded, onPressed: onBrowser),
              if (onCookies != null)
                OutlinedButton.icon(
                  onPressed: onCookies,
                  icon: const Icon(Icons.cookie_outlined),
                  label: const Text('Use browser sign-in'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 54)),
                ),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 54)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────── Playlists ─────────────

class _PlaylistView extends StatelessWidget {
  const _PlaylistView({super.key, required this.info, required this.onPick});

  final MediaInfo info;
  final ValueChanged<PlaylistEntry> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = info.entries.take(200).toList();
    return HomePanel(
      highlight: true,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSectionTitle(
            icon: Icons.playlist_play_rounded,
            title: info.title,
            subtitle: [
              '${info.entries.length} items',
              ?info.uploader,
              'pick one to download',
            ].join(' · '),
          ),
          const SizedBox(height: 12),
          for (final (i, entry) in entries.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: EntranceMotion(
                index: i,
                step: const Duration(milliseconds: 30),
                offset: 10,
                child: PressableScale(
                  scale: 0.98,
                  child: Material(
                    color: scheme.surfaceContainerLowest.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => onPick(entry),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(11),
                              child: SizedBox(
                                width: 96,
                                height: 54,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (entry.thumbnail != null)
                                      FadeInNetworkImage(
                                        url: entry.thumbnail!,
                                        cacheWidth: 240,
                                        fallback: ColoredBox(color: scheme.surfaceContainerHighest),
                                      )
                                    else
                                      const DecoratedBox(decoration: BoxDecoration(gradient: tileGradient)),
                                    Positioned(left: 4, top: 4, child: OverlayPill(text: '${i + 1}')),
                                    if (entry.duration != null)
                                      Positioned(right: 4, bottom: 4, child: OverlayPill(text: formatDuration(entry.duration))),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                entry.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
                              ),
                            ),
                            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (info.entries.length > entries.length)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'Showing the first ${entries.length}.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
