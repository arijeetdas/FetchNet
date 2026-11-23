import 'dart:math' as math;

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
import 'playlist_view.dart';
import 'post_result_view.dart';
import 'sites_panel.dart';
import 'status_deck.dart';
import '../../ui_kit/kit.dart';

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

  /// A link found on the clipboard, offered under the link box.
  String? _clipboardOffer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _services = AppScope.of(context);
    _services.incomingLink.addListener(_onIncomingLink);
    _services.tabRequest.addListener(_onTab);
    _controller.addListener(() => setState(() {}));
    // Back in the app (or its window focused again): maybe a link was copied.
    _lifecycle = AppLifecycleListener(onResume: _checkClipboard);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onIncomingLink();
      _checkClipboard();
    });
  }

  @override
  void dispose() {
    _services.incomingLink.removeListener(_onIncomingLink);
    _services.tabRequest.removeListener(_onTab);
    _lifecycle.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTab() {
    if (_services.tabRequest.value == 0) _checkClipboard();
  }

  /// Offers a copied link once (Settings → Extra Settings → Detect copied
  /// links). Skipped while a link is being read, and for the link already
  /// in the box.
  Future<void> _checkClipboard() async {
    final extras = _services.extras;
    if (!extras.detectClipboard || _phase == _Phase.loading || !mounted) return;
    try {
      // Cheap check first: no reading (and no "pasted" notice) without text.
      if (!await Clipboard.hasStrings()) return;
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
      final url = text == null ? null : extractUrl(text);
      if (!mounted || url == null) return;
      if (url == extras.lastOfferedLink || url == extractUrl(_controller.text) || url == _lastUrl) return;
      await extras.setLastOfferedLink(url);
      if (mounted) setState(() => _clipboardOffer = url);
    } catch (_) {}
  }

  void _takeClipboardOffer() {
    final url = _clipboardOffer;
    if (url == null) return;
    setState(() => _clipboardOffer = null);
    _controller.text = url;
    _fetch(url: url);
  }

  /// The copied-link card under the link box (it slides away when gone).
  Widget _clipboardCard() => AnimatedSize(
        duration: homeDuration(context, const Duration(milliseconds: 300)),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _clipboardOffer == null || _phase == _Phase.loading
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _ClipboardOffer(
                  url: _clipboardOffer!,
                  onFetch: _takeClipboardOffer,
                  onDismiss: () => setState(() => _clipboardOffer = null),
                ),
              ),
      );

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
            ? PlaylistView(
                key: ValueKey('pl-${info.url}'),
                info: info,
                // A channel's Videos / Shorts tab, or a playlist of it.
                onOpenList: (entry) {
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
      builder: (context) => KitAlertDialog(
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

  /// [fill]: the desktop's main column, where the cards take its full width.
  Widget _phaseView({bool fill = false, double cardsExtra = 0}) {
    return switch (_phase) {
      _Phase.idle => fill
          ? _Capabilities(key: const ValueKey('idle'), wide: true, extra: cardsExtra)
          : Center(
              key: const ValueKey('idle'),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: const _Capabilities(),
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

  Widget _linkDock() => LinkDock(
        controller: _controller,
        focusNode: _focus,
        loading: _phase == _Phase.loading,
        onFetch: () => _fetch(),
        onPaste: _paste,
        onClear: _clear,
      );

  Widget _phaseSwitcher({bool fill = false, double cardsExtra = 0}) => AnimatedSize(
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
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
          child: _phaseView(fill: fill, cardsExtra: cardsExtra),
        ),
      );

  Widget _hero({bool row = false, double extra = 0}) => AnimatedSize(
        duration: homeDuration(context, const Duration(milliseconds: 420)),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _phase == _Phase.idle ? _Hero(row: row, extra: extra) : const SizedBox(width: double.infinity),
      );

  Widget _sites() => SitesPanel(onOpen: _openSite, onBrowser: () => _openBrowserMode());

  // ── Large screens: filling the window ──
  //
  // The two columns reach down to the bottom of the window (and to each
  // other's bottom when the page scrolls). After each layout, the natural
  // height of each column is measured; what's left of the window goes to
  // the panels that can use it: the "What FetchNet saves" cards and How it
  // works in the main column (while idle), Recent downloads in the side
  // column (more rows fit).
  final _contentKey = GlobalKey();
  final _rowKey = GlobalKey();
  final _mainKey = GlobalKey();
  final _sideKey = GlobalKey();
  double _mainFill = 0;
  double _sideFill = 0;

  /// Height of the window available to the content (padding taken off).
  double _viewport = 0;
  bool _measureQueued = false;

  void _queueMeasure() {
    if (_measureQueued) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      _measure();
    });
  }

  void _measure() {
    if (!mounted) return;
    RenderBox? box(GlobalKey k) {
      final r = k.currentContext?.findRenderObject();
      return r is RenderBox && r.hasSize ? r : null;
    }

    final content = box(_contentKey), row = box(_rowKey), main = box(_mainKey), side = box(_sideKey);
    if (content == null || row == null || main == null || side == null) return;
    final rowTop = row.localToGlobal(Offset.zero, ancestor: content).dy;
    final mainNatural = main.size.height - _mainFill;
    final sideNatural = side.size.height - _sideFill;
    final idle = _phase == _Phase.idle;
    final window = _viewport - rowTop;
    // How far the idle main column may grow; past that (very tall
    // windows), the page is centered vertically instead.
    final reach = idle ? math.min(window, mainNatural + _mainFillCap) : window;
    final target = math.max(reach, math.max(mainNatural, sideNatural));
    final mainFill = idle ? math.max(0.0, target - mainNatural) : 0.0;
    final sideFill = math.max(0.0, target - sideNatural);
    final slack = math.max(0.0, window - target);
    if ((mainFill - _mainFill).abs() > 0.5 || (sideFill - _sideFill).abs() > 0.5 || (slack - _slack).abs() > 0.5) {
      setState(() {
        _mainFill = mainFill;
        _sideFill = sideFill;
        _slack = slack;
      });
    }
  }

  /// The most the idle main column grows (cards, How it works).
  static const _mainFillCap = 260.0;

  /// Window height left over on very tall screens: split above and below
  /// the page.
  double _slack = 0;

  /// Desktop and other large screens (side rail). With room for it, a main
  /// column (the hero, the link, results) sits next to a side column
  /// (downloads in progress, sites, recent downloads), both filling the
  /// window; otherwise it is one centered column, like on a phone.
  Widget _buildWide(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, c) {
          const pad = 32.0;
          const columnGap = 28.0;
          const top = 28.0;
          final bottom = 32 + MediaQuery.paddingOf(context).bottom;
          final room = c.maxWidth - pad * 2;
          final twoColumns = room >= 1000;
          final width = twoColumns ? room.clamp(0.0, 1840.0) : room.clamp(0.0, 760.0);
          final sideWidth = (width * 0.3).clamp(340.0, 460.0);
          final side = (c.maxWidth - width) / 2;
          _viewport = c.maxHeight - top - bottom;
          final List<Widget> children;
          if (twoColumns) {
            _queueMeasure();
            final idle = _phase == _Phase.idle;
            // The main column's share: the cards grow a little, How it
            // works takes the rest (its pictures grow).
            final cardsExtra = idle ? math.min(_mainFill * 0.15, 36.0) : 0.0;
            final howExtra = idle ? _mainFill - cardsExtra : 0.0;
            children = [
              const EntranceMotion(child: _Header()),
              const SizedBox(height: 18),
              const StatusDeck(),
              const SizedBox(height: 4),
              NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  _queueMeasure();
                  return true;
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Above both columns, so the side column starts level
                    // with the link box. (It collapses once a link is read;
                    // the columns move up together.)
                    SizeChangedLayoutNotifier(child: _hero(row: true)),
                    Row(
                      key: _rowKey,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SizeChangedLayoutNotifier(
                            child: Column(
                              key: _mainKey,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                EntranceMotion(index: 2, child: _linkDock()),
                                _clipboardCard(),
                                const SizedBox(height: 20),
                                _phaseSwitcher(fill: true, cardsExtra: cardsExtra),
                                AnimatedSize(
                                  duration: homeDuration(context, const Duration(milliseconds: 380)),
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.topCenter,
                                  child: idle
                                      ? Padding(
                                          padding: const EdgeInsets.only(top: 20),
                                          child: EntranceMotion(index: 5, child: _HowItWorks(extra: howExtra)),
                                        )
                                      : const SizedBox(width: double.infinity),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: columnGap),
                        SizedBox(
                          width: sideWidth,
                          child: SizeChangedLayoutNotifier(
                            child: Column(
                              key: _sideKey,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const _ActiveDownloads(sidebar: true),
                                EntranceMotion(index: 4, child: _sites()),
                                const SizedBox(height: 20),
                                EntranceMotion(index: 6, child: _RecentDownloads(extra: _sideFill)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ];
          } else {
            children = [
              const EntranceMotion(child: _Header()),
              const SizedBox(height: 16),
              const StatusDeck(),
              _hero(),
              EntranceMotion(index: 2, child: _linkDock()),
              _clipboardCard(),
              const SizedBox(height: 20),
              _phaseSwitcher(fill: true),
              const _ActiveDownloads(),
              const SizedBox(height: 20),
              EntranceMotion(index: 4, child: _sites()),
            ];
          }
          return CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: twoColumns
                    ? EdgeInsets.fromLTRB(side, top + _slack / 2, side, bottom + _slack / 2)
                    : EdgeInsets.fromLTRB(side, top, side, bottom),
                sliver: SliverToBoxAdapter(
                  child: Column(key: _contentKey, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Phones and other small screens from here on.
    if (Breakpoints.isWide(context)) return _buildWide(context);
    final idle = _phase == _Phase.idle;

    final content = SafeArea(
      bottom: false,
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 32 + MediaQuery.paddingOf(context).bottom),
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
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: _clipboardCard(),
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
    return AuroraBackground(intensity: 0.6, child: content);
  }
}

// ───────────── A copied link ─────────────

/// "Link copied" under the link box, with Fetch and dismiss.
class _ClipboardOffer extends StatelessWidget {
  const _ClipboardOffer({required this.url, required this.onFetch, required this.onDismiss});

  final String url;
  final VoidCallback onFetch;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final uri = Uri.tryParse(url);
    final host = (uri?.host ?? '').replaceFirst(RegExp(r'^www\.'), '');
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onFetch,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(Icons.content_paste_go_rounded, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Link copied',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      host.isEmpty ? url : host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                onPressed: onFetch,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                child: const Text('Fetch'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
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
  const _Hero({this.row = false, this.extra = 0});

  /// Desktop main column: the logo next to the words, left-aligned with the
  /// link box below.
  final bool row;

  /// Height added in the [row] layout (to fill the window): a larger logo
  /// and more room below it.
  final double extra;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = Breakpoints.isWide(context);
    if (row) {
      return Padding(
        padding: EdgeInsets.only(top: 6, bottom: 18 + extra * 0.4),
        child: Row(
          children: [
            EntranceMotion(child: LivingLogo(size: 104 + extra * 0.6)),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EntranceMotion(
                    index: 1,
                    child: Text(
                      'Paste a link. Pick a quality. Done.',
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
                    ),
                  ),
                  const SizedBox(height: 6),
                  EntranceMotion(
                    index: 2,
                    child: Text(
                      'Video up to 4K, MP3 and M4A, and every image of a post.',
                      style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
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

/// Four cards telling what FetchNet saves. They only inform (no taps), and
/// every card has the same width and height, whatever its text: the height
/// comes from the text styles (one title line, two body lines), not from
/// the words in a card.
class _Capabilities extends StatelessWidget {
  const _Capabilities({super.key, this.wide = false, this.extra = 0});

  /// Desktop layout: four across from a narrower width.
  final bool wide;

  /// Height added to every card (desktop, to fill the window): the space
  /// goes between the icon and the words.
  final double extra;

  static const _gap = 10.0;
  static const _padding = 14.0;
  static const _iconSize = 38.0;

  static TextStyle? _titleStyle(ThemeData theme) => theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800);
  static TextStyle? _bodyStyle(ThemeData theme) =>
      theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.35);

  /// The height of every card, measured once from the styles.
  static double _cardHeight(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double linesHeight(TextStyle? style, int lines) {
      final painter = TextPainter(
        text: TextSpan(text: List.filled(lines, 'Ag').join('\n'), style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: lines,
      )..layout();
      final h = painter.height;
      painter.dispose();
      return h;
    }

    return _padding * 2 + _iconSize + 10 + linesHeight(_titleStyle(theme), 1) + 2 + linesHeight(_bodyStyle(theme), 2);
  }

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
    final height = _cardHeight(context) + extra;
    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= (wide ? 600 : 720) ? 4 : 2;
        final width = (c.maxWidth - _gap * (columns - 1)) / columns;
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final (i, (icon, title, body, on)) in items.indexed)
              SizedBox(
                width: width,
                height: height,
                child: EntranceMotion(
                  index: i,
                  delay: const Duration(milliseconds: 120),
                  child: _CapabilityCard(icon: icon, title: title, body: body, enabled: on, grow: extra * 0.6),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.icon, required this.title, required this.body, required this.enabled, this.grow = 0});

  final IconData icon;
  final String title;
  final String body;
  final bool enabled;

  /// How much larger the icon tile is (part of a taller desktop card).
  final double grow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final iconSize = _Capabilities._iconSize + grow;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Opacity(
        opacity: enabled ? 1 : 0.6,
        child: Padding(
          padding: const EdgeInsets.all(_Capabilities._padding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: iconSize,
                height: iconSize,
                decoration: BoxDecoration(
                  gradient: enabled ? tileGradient : null,
                  color: enabled ? null : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: enabled
                      ? [BoxShadow(color: AppColors.violetBright.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 5))]
                      : null,
                ),
                child: Icon(icon, color: enabled ? Colors.white : scheme.onSurfaceVariant, size: 20 + grow * 0.5),
              ),
              const SizedBox(height: 10),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _Capabilities._titleStyle(theme)),
              const SizedBox(height: 2),
              Text(body, maxLines: 2, overflow: TextOverflow.ellipsis, style: _Capabilities._bodyStyle(theme)),
              // Titles line up across the cards; a one-line description
              // leaves its spare line (and a taller desktop card its extra)
              // at the bottom.
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────── Desktop: How it works, Recent downloads ─────────────

/// Three steps under the "What FetchNet saves" cards on large screens.
/// Information only. [extra] (to fill the window) makes every step taller,
/// its contents centered.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks({required this.extra});

  final double extra;

  static const _steps = [
    (Icons.content_paste_rounded, 'Paste a link', 'From YouTube, Instagram, X, Facebook or 1000+ other sites.'),
    (Icons.tune_rounded, 'Pick what you want', 'A video quality, MP3 or M4A, a thumbnail, or the files of a post.'),
    (Icons.folder_special_rounded, 'Find it sorted', 'Saved in the FetchNet folder, in Images, Audio and Video.'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return HomePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HomeSectionTitle(
            icon: Icons.auto_awesome_rounded,
            title: 'How it works',
            subtitle: 'Three steps, on any site FetchNet can read.',
          ),
          const SizedBox(height: 14),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, (icon, title, body)) in _steps.indexed) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // The extra height: a picture of the step.
                          if (extra > 0)
                            SizedBox(
                              height: extra,
                              child: Center(child: _StepPicture(icon: icon, size: math.min(extra * 0.75, 132))),
                            ),
                          Row(
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
                                child: Text(
                                  '${i + 1}',
                                  style: theme.textTheme.labelLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w900),
                                ),
                              ),
                              const Spacer(),
                              if (extra < 40) Icon(icon, color: scheme.primary.withValues(alpha: 0.8), size: 22),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 3),
                          Text(
                            body,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A step's icon on a soft glowing disc, sized to the room it has.
class _StepPicture extends StatelessWidget {
  const _StepPicture({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (size < 24) return const SizedBox.shrink();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [scheme.primary.withValues(alpha: 0.2), scheme.primary.withValues(alpha: 0.04)],
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Center(
        child: Container(
          width: size * 0.52,
          height: size * 0.52,
          decoration: BoxDecoration(
            gradient: tileGradient,
            borderRadius: BorderRadius.circular(size * 0.16),
            boxShadow: [BoxShadow(color: AppColors.violetBright.withValues(alpha: 0.3), blurRadius: size * 0.16, offset: Offset(0, size * 0.05))],
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.28),
        ),
      ),
    );
  }
}

/// The latest downloads, in the side column on large screens. It shows as
/// many as fit: [extra] (to fill the window) makes room for more. A tap
/// opens History, where every action on them is.
class _RecentDownloads extends StatelessWidget {
  const _RecentDownloads({required this.extra});

  final double extra;

  /// Height of the panel's contents without [extra].
  static const _base = 250.0;
  static const _rowHeight = 52.0;
  static const _rowGap = 6.0;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: services.history,
      builder: (context, _) {
        final entries = services.history.entries;
        return HomePanel(
          padding: const EdgeInsets.all(14),
          child: SizedBox(
            height: _base + extra,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HomeSectionTitle(
                  icon: Icons.history_rounded,
                  title: 'Recent downloads',
                  subtitle: entries.isEmpty
                      ? 'What you save shows up here.'
                      : '${entries.length} in History',
                  trailing: entries.isEmpty
                      ? null
                      : TextButton(
                          onPressed: () => services.tabRequest.value = 2,
                          child: const Text('See all'),
                        ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: entries.isEmpty
                      ? _empty(theme, scheme)
                      : LayoutBuilder(
                          builder: (context, c) {
                            final fit = ((c.maxHeight + _rowGap) / (_rowHeight + _rowGap)).floor();
                            final shown = entries.take(fit.clamp(0, entries.length)).toList();
                            return Column(
                              children: [
                                for (final (i, e) in shown.indexed) ...[
                                  if (i > 0) const SizedBox(height: _rowGap),
                                  SizedBox(
                                    height: _rowHeight,
                                    child: _RecentRow(entry: e, onTap: () => services.tabRequest.value = 2),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _empty(ThemeData theme, ColorScheme scheme) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(Icons.download_done_rounded, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 10),
            Text('Nothing saved yet', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(
              'Paste a link to get started.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.entry, required this.onTap});

  final HistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color) = switch (entry.status) {
      DownloadStatus.completed => (Icons.check_circle_rounded, Colors.green),
      DownloadStatus.failed => (Icons.error_rounded, scheme.error),
      DownloadStatus.cancelled => (Icons.cancel_rounded, scheme.outline),
      _ => (Icons.schedule_rounded, scheme.outline),
    };
    final fallback = DecoratedBox(
      decoration: const BoxDecoration(gradient: tileGradient),
      child: Icon(kindIcon(entry.kind), color: Colors.white, size: 18),
    );
    return Material(
      color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                  width: 56,
                  height: 36,
                  child: entry.thumbnail == null
                      ? fallback
                      : FadeInNetworkImage(url: entry.thumbnail!, cacheWidth: 160, fallback: fallback),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      [entry.quality, formatDate(entry.createdAt)].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(icon, color: color, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────── Downloads in progress ─────────────

/// The downloads running right now, live, with a shortcut to Downloads.
class _ActiveDownloads extends StatelessWidget {
  const _ActiveDownloads({this.sidebar = false});

  /// Desktop side column: on top of the sites, with the gap below it.
  final bool sidebar;

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
                  padding: sidebar ? const EdgeInsets.only(bottom: 20) : const EdgeInsets.only(top: 20),
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
      DownloadStatus.queued => task.stage ?? 'Waiting in line',
      DownloadStatus.paused => 'Paused',
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
              GradientProgressBar(
                value: switch (task.status) {
                  DownloadStatus.downloading => p,
                  DownloadStatus.paused => p ?? 0,
                  _ => null,
                },
                height: 5,
              ),
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
