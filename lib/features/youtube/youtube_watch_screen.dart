import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/app_services.dart';
import '../../models/youtube_models.dart';
import '../../services/sites_service.dart';
import '../../services/web_session.dart';
import '../../services/youtube_client.dart';
import '../../widgets/brand.dart';
import '../../widgets/site_icon.dart';
import '../browser/browser_screen.dart';
import 'youtube_screen.dart';
import 'youtube_widgets.dart';

/// Plays a video with YouTube's embedded player and shows its details and
/// "Up next". Pops with a [BrowserGrab] when the user grabs the video.
class YouTubeWatchScreen extends StatefulWidget {
  const YouTubeWatchScreen({super.key, required this.videoId, this.preview});

  final String videoId;

  /// Card data shown while the full details load.
  final YtVideo? preview;

  @override
  State<YouTubeWatchScreen> createState() => _YouTubeWatchScreenState();
}

class _YouTubeWatchScreenState extends State<YouTubeWatchScreen> {
  late final YouTubeClient _client = AppScope.of(context).youtube.client;
  final _scroll = ScrollController();

  /// Videos opened from "Up next"; back steps through them.
  final List<({String id, YtVideo? preview})> _stack = [];
  InAppWebViewController? _player;

  YtWatchInfo? _info;
  List<YtVideo> _related = const [];
  String? _relatedToken;
  bool _loading = true;
  bool _loadingMore = false;
  bool _descriptionOpen = false;
  String? _error;
  int _loadId = 0;

  String get _id => _stack.last.id;
  YtVideo? get _preview => _stack.last.preview;

  @override
  void initState() {
    super.initState();
    _stack.add((id: widget.videoId, preview: widget.preview));
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    if (!kIsWeb && Platform.isAndroid) {
      SystemChrome.setPreferredOrientations(const []);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  static URLRequest _embed(String id) => URLRequest(
        url: WebUri('https://www.youtube.com/embed/$id?autoplay=1&playsinline=1&rel=0&modestbranding=1'
            '&origin=https%3A%2F%2Fwww.youtube.com'),
        headers: const {'Referer': 'https://www.youtube.com/'},
      );

  Future<void> _load() async {
    final id = _id;
    final token = ++_loadId;
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
      _related = const [];
      _relatedToken = null;
      _descriptionOpen = false;
    });
    try {
      final info = await _client.watch(id);
      if (!mounted || token != _loadId) return;
      setState(() {
        _info = info;
        _related = info.related;
        _relatedToken = info.relatedContinuation;
      });
    } on YtException catch (e) {
      if (mounted && token == _loadId) setState(() => _error = e.message);
    } finally {
      if (mounted && token == _loadId) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final token = _relatedToken;
    if (token == null || _loading || _loadingMore) return;
    final loadId = _loadId;
    setState(() => _loadingMore = true);
    try {
      final page = await _client.more(YtFeedKind.related, token);
      if (!mounted || loadId != _loadId) return;
      final known = _related.map((v) => v.id).toSet()..add(_id);
      setState(() {
        _related = [..._related, ...page.items.where((v) => !v.isShort && known.add(v.id))];
        _relatedToken = page.continuation;
      });
    } on YtException {
      if (mounted) setState(() => _relatedToken = null);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openVideo(String id, {YtVideo? preview}) {
    if (id == _id) return;
    _stack.add((id: id, preview: preview));
    _player?.loadUrl(urlRequest: _embed(id));
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  void _stepBack() {
    if (_stack.length <= 1) return;
    _stack.removeLast();
    _player?.loadUrl(urlRequest: _embed(_id));
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  String get _watchUrl => 'https://www.youtube.com/watch?v=$_id';
  String? get _title => _info?.title ?? _preview?.title;

  void _grab() {
    Navigator.of(context).pop(BrowserGrab(
      pageUrl: _watchUrl,
      mediaUrl: _watchUrl,
      requestArgs: const [],
      pageTitle: _title,
    ));
  }

  /// The real YouTube page in the built-in browser (videos that refuse to
  /// play in the embedded player).
  Future<void> _openPage() async {
    try {
      await _player?.pauseAllMediaPlayback();
    } catch (_) {}
    if (!mounted) return;
    final url = WebSession.isMobile ? 'https://m.youtube.com/watch?v=$_id' : _watchUrl;
    final grab = await Navigator.of(context).push<BrowserGrab>(
      MaterialPageRoute(builder: (_) => BrowserScreen(initialUrl: url, youtubeHandoff: false)),
    );
    if (grab != null && mounted) Navigator.of(context).pop(grab);
  }

  Future<NavigationActionPolicy> _onNavigate(InAppWebViewController c, NavigationAction action) async {
    final url = action.request.url?.toString() ?? '';
    if (url.contains('youtube.com/embed/') || !action.isForMainFrame) return NavigationActionPolicy.ALLOW;
    // Taps on the player's title / logo: stay in FetchNet.
    final link = parseYouTubeLink(url);
    if (link.videoId != null) _openVideo(link.videoId!);
    return NavigationActionPolicy.CANCEL;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final player = AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(
        color: Colors.black,
        child: InAppWebView(
          webViewEnvironment: WebSession.environment,
          initialUrlRequest: _embed(widget.videoId),
          initialSettings: WebSession.baseSettings()
            ..mediaPlaybackRequiresUserGesture = false
            ..supportZoom = false
            ..transparentBackground = true
            ..supportMultipleWindows = false
            ..useShouldOverrideUrlLoading = true
            ..regexToAllowSyncUrlLoading = r'^https://www\.youtube\.com/embed/.*',
          onWebViewCreated: (c) => _player = c,
          shouldOverrideUrlLoading: _onNavigate,
          onEnterFullscreen: (_) {
            if (kIsWeb || !Platform.isAndroid) return;
            SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
          },
          onExitFullscreen: (_) {
            if (kIsWeb || !Platform.isAndroid) return;
            SystemChrome.setPreferredOrientations(const []);
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
          },
        ),
      ),
    );

    final details = _Details(
      info: _info,
      preview: _preview,
      loading: _loading,
      error: _error,
      descriptionOpen: _descriptionOpen,
      onToggleDescription: () => setState(() => _descriptionOpen = !_descriptionOpen),
      onRetry: _load,
      onOpenPage: _openPage,
    );

    final upNextTitle = Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text('Up next', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
    );

    List<Widget> related() => [
          for (final v in _related.where((v) => !v.isShort))
            YtCompactCard(video: v, onTap: () => _openVideo(v.id, preview: v)),
          if (_loadingMore) const Padding(padding: EdgeInsets.all(20), child: Center(child: EnergyLoader(size: 36))),
          if (_loading && _related.isEmpty)
            const Padding(padding: EdgeInsets.all(28), child: Center(child: EnergyLoader(size: 40))),
        ];

    bool onScroll(ScrollNotification n) {
      if (n.metrics.extentAfter < 600) _loadMore();
      return false;
    }

    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stepBack();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: scheme.surfaceContainerLow,
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          titleSpacing: 0,
          title: const Row(
            children: [
              BrandGlyph(brand: SiteBrand.youtube, size: 26),
              SizedBox(width: 10),
              Text('YouTube'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Open the YouTube page',
              icon: const Icon(Icons.open_in_browser_rounded),
              onPressed: _openPage,
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth >= 1000) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 20, 12, 24),
                      children: [
                        ClipRRect(borderRadius: BorderRadius.circular(20), child: player),
                        const SizedBox(height: 16),
                        details,
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 440,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: onScroll,
                      child: ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 2, 20, 24),
                        children: [upNextTitle, ...related()],
                      ),
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: player)),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: onScroll,
                    child: ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [details, upNextTitle, ...related()],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        bottomNavigationBar: _GrabBar(onGrab: _grab),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.info,
    required this.preview,
    required this.loading,
    required this.error,
    required this.descriptionOpen,
    required this.onToggleDescription,
    required this.onRetry,
    required this.onOpenPage,
  });

  final YtWatchInfo? info;
  final YtVideo? preview;
  final bool loading;
  final String? error;
  final bool descriptionOpen;
  final VoidCallback onToggleDescription;
  final VoidCallback onRetry;
  final VoidCallback onOpenPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = info?.title ?? preview?.title;
    final stats = info?.stats ?? preview?.stats ?? '';
    final channel = info?.channel ?? preview?.channel;
    final avatar = info?.channelAvatar ?? preview?.channelAvatar;
    final description = info?.description;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Text(title, style: theme.textTheme.titleLarge?.copyWith(height: 1.25))
        else if (loading)
          Container(
            height: 24,
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
          ),
        if (stats.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(stats, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        if (channel != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              YtChannelAvatar(url: avatar, name: channel, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    if (info?.subscribers != null)
                      Text(
                        info!.subscribers!,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(child: Text(error!, style: theme.textTheme.bodyMedium)),
                  TextButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        ],
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: 14),
          Material(
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onToggleDescription,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      description,
                      maxLines: descriptionOpen ? null : 3,
                      overflow: descriptionOpen ? TextOverflow.visible : TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      descriptionOpen ? 'Show less' : 'Show more',
                      style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onOpenPage,
            icon: const Icon(Icons.play_disabled_rounded, size: 18),
            label: const Text('Won\'t play here? Open the YouTube page'),
            style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _GrabBar extends StatelessWidget {
  const _GrabBar({required this.onGrab});

  final VoidCallback onGrab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: GradientButton(
                label: 'Grab this video',
                icon: Icons.download_for_offline_rounded,
                expand: true,
                height: 50,
                onPressed: onGrab,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
