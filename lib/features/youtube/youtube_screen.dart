import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../models/youtube_models.dart';
import '../../services/sites_service.dart';
import '../../services/youtube_client.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/site_icon.dart';
import '../browser/browser_screen.dart';
import 'youtube_settings_screen.dart';
import 'youtube_watch_screen.dart';
import 'youtube_widgets.dart';

/// FetchNet's own YouTube view: the signed-in account's recommended feed and
/// search. Pops with a [BrowserGrab] when the user grabs a video.
class YouTubeScreen extends StatefulWidget {
  const YouTubeScreen({super.key, this.initialQuery, this.initialVideoId});

  final String? initialQuery;
  final String? initialVideoId;

  @override
  State<YouTubeScreen> createState() => _YouTubeScreenState();
}

class _Feed {
  List<YtVideo> items = const [];
  String? token;
  bool loading = false;
  bool loadingMore = false;
  String? error;
}

class _YouTubeScreenState extends State<YouTubeScreen> {
  late final YouTubeClient _client = AppScope.of(context).youtube.client;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();

  final _home = _Feed();
  final _results = _Feed();
  String? _query;
  int _searchToken = 0;

  _Feed get _feed => _query == null ? _home : _results;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _loadHome();
    final q = widget.initialQuery?.trim();
    if (q != null && q.isNotEmpty) {
      _search.text = q;
      _runSearch(q);
    }
    final id = widget.initialVideoId;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openVideo(id));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadHome() async {
    setState(() {
      _home.loading = true;
      _home.error = null;
    });
    try {
      final page = await _client.home();
      if (!mounted) return;
      setState(() {
        _home.items = page.items;
        _home.token = page.continuation;
      });
    } on YtException catch (e) {
      if (mounted) setState(() => _home.error = e.message);
    } finally {
      if (mounted) setState(() => _home.loading = false);
    }
  }

  Future<void> _runSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _searchFocus.unfocus();
    final token = ++_searchToken;
    setState(() {
      _query = q;
      _results
        ..items = const []
        ..token = null
        ..error = null
        ..loading = true;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    try {
      final page = await _client.search(q);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results.items = page.items;
        _results.token = page.continuation;
      });
    } on YtException catch (e) {
      if (mounted && token == _searchToken) setState(() => _results.error = e.message);
    } finally {
      if (mounted && token == _searchToken) setState(() => _results.loading = false);
    }
  }

  Future<void> _loadMore() async {
    final feed = _feed;
    final token = feed.token;
    if (token == null || feed.loading || feed.loadingMore) return;
    setState(() => feed.loadingMore = true);
    try {
      final page = await _client.more(feed == _home ? YtFeedKind.home : YtFeedKind.search, token);
      if (!mounted) return;
      final known = feed.items.map((v) => '${v.isShort}${v.id}').toSet();
      setState(() {
        feed.items = [...feed.items, ...page.items.where((v) => known.add('${v.isShort}${v.id}'))];
        feed.token = page.continuation;
      });
    } on YtException {
      if (mounted) setState(() => feed.token = null);
    } finally {
      if (mounted) setState(() => feed.loadingMore = false);
    }
  }

  void _clearSearch() {
    _searchToken++;
    _search.clear();
    setState(() => _query = null);
  }

  Future<void> _openVideo(String id, {YtVideo? preview}) async {
    final grab = await Navigator.of(context).push<BrowserGrab>(
      MaterialPageRoute(builder: (_) => YouTubeWatchScreen(videoId: id, preview: preview)),
    );
    if (grab != null && mounted) Navigator.of(context).pop(grab);
  }

  void _grab(YtVideo v) {
    Navigator.of(context).pop(BrowserGrab(pageUrl: v.watchUrl, mediaUrl: v.watchUrl, requestArgs: const [], pageTitle: v.title));
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 800) _loadMore();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final feed = _feed;
    final profile = AppScope.of(context).youtube.profile;

    final searchField = SizedBox(
      height: 46,
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        onSubmitted: _runSearch,
        style: theme.textTheme.bodyLarge,
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          hintText: 'Search YouTube',
          prefixIcon: const Padding(
            padding: EdgeInsets.all(11),
            child: BrandGlyph(brand: SiteBrand.youtube, size: 22),
          ),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded), onPressed: _clearSearch),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide(color: scheme.primary),
          ),
        ),
      ),
    );

    final slivers = <Widget>[
      SliverAppBar(
        floating: true,
        snap: true,
        backgroundColor: scheme.surface.withValues(alpha: 0.92),
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 66,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: IconButton.filledTonal(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        titleSpacing: 8,
        title: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: searchField),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const YouTubeSettingsScreen()),
              ),
              child: GoogleAvatar(profile: profile, size: 36),
            ),
          ),
        ],
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _query == null ? 'Recommended for you' : 'Results for “$_query”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (_query != null)
                TextButton.icon(
                  onPressed: _clearSearch,
                  icon: const Icon(Icons.home_rounded, size: 18),
                  label: const Text('Home'),
                ),
            ],
          ),
        ),
      ),
    ];

    if (feed.loading && feed.items.isEmpty) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: _CenteredState(loader: true, title: 'Loading YouTube…'),
      ));
    } else if (feed.error != null && feed.items.isEmpty) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: _CenteredState(
          icon: Icons.cloud_off_rounded,
          title: 'Couldn\'t load YouTube',
          message: feed.error,
          action: FilledButton.tonalIcon(
            onPressed: () => _query == null ? _loadHome() : _runSearch(_query!),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ),
      ));
    } else if (feed.items.isEmpty) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: _CenteredState(
          icon: _query == null ? Icons.explore_outlined : Icons.search_off_rounded,
          title: _query == null ? 'Nothing recommended yet' : 'No results',
          message: _query == null
              ? 'YouTube has no recommendations for this account yet (watch history may be off). Search for something to get started.'
              : 'Try different words.',
        ),
      ));
    } else {
      for (final segment in _segments(feed.items)) {
        slivers.add(SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverConstrainedCrossAxis(
            maxExtent: 1500,
            sliver: segment.shorts
                ? SliverToBoxAdapter(
                    child: YtShortsShelf(shorts: segment.items, onTap: (v) => _openVideo(v.id, preview: v)),
                  )
                : _VideoGrid(
                    videos: segment.items,
                    onTap: (v) => _openVideo(v.id, preview: v),
                    onGrab: _grab,
                  ),
          ),
        ));
      }
      if (feed.loadingMore) {
        slivers.add(const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(24), child: Center(child: EnergyLoader(size: 40))),
        ));
      }
    }
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: 24 + MediaQuery.paddingOf(context).bottom)));

    final scroll = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: CustomScrollView(
        controller: _scroll,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: slivers,
      ),
    );

    return PopScope(
      canPop: _query == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSearch();
      },
      child: Scaffold(
        body: AuroraBackground(
          intensity: 0.35,
          child: SafeArea(
            bottom: false,
            child: _query == null ? RefreshIndicator(onRefresh: _loadHome, child: scroll) : scroll,
          ),
        ),
      ),
    );
  }

  static List<({bool shorts, List<YtVideo> items})> _segments(List<YtVideo> items) {
    final out = <({bool shorts, List<YtVideo> items})>[];
    for (final v in items) {
      if (out.isNotEmpty && out.last.shorts == v.isShort) {
        out.last.items.add(v);
      } else {
        out.add((shorts: v.isShort, items: [v]));
      }
    }
    return out;
  }
}

class _VideoGrid extends StatelessWidget {
  const _VideoGrid({required this.videos, required this.onTap, required this.onGrab});

  final List<YtVideo> videos;
  final ValueChanged<YtVideo> onTap;
  final ValueChanged<YtVideo> onGrab;

  static const _gap = 12.0;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.crossAxisExtent;
        final cols = w >= 1180 ? 4 : w >= 860 ? 3 : w >= 560 ? 2 : 1;
        final tile = (w - _gap * (cols - 1)) / cols;
        // Card padding (4 + 4) + 16:9 thumbnail + text block.
        final extent = 8 + (tile - 8) * 9 / 16 + YtVideoCard.infoHeight;
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: _gap,
            mainAxisSpacing: 8,
            mainAxisExtent: extent,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => YtVideoCard(video: videos[i], onTap: () => onTap(videos[i]), onGrab: () => onGrab(videos[i])),
            childCount: videos.length,
          ),
        );
      },
    );
  }
}

class _CenteredState extends StatelessWidget {
  const _CenteredState({required this.title, this.icon, this.message, this.action, this.loader = false});

  final String title;
  final IconData? icon;
  final String? message;
  final Widget? action;
  final bool loader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loader)
                const EnergyLoader(size: 56)
              else if (icon != null)
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
                  child: Icon(icon, color: scheme.onPrimaryContainer, size: 30),
                ),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the YouTube view, or YouTube Settings when nobody is signed in.
/// Completes with the grabbed video, if any.
Future<BrowserGrab?> openYouTube(BuildContext context, {String? query, String? videoId}) async {
  final services = AppScope.of(context);
  if (!services.youtube.signedIn) {
    showSnack(context, 'Sign in with Google to use YouTube in FetchNet');
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeSettingsScreen()));
    return null;
  }
  return Navigator.of(context).push<BrowserGrab>(
    MaterialPageRoute(builder: (_) => YouTubeScreen(initialQuery: query, initialVideoId: videoId)),
  );
}

/// What a youtube.com link points at, for [openYouTube].
({String? query, String? videoId}) parseYouTubeLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return (query: null, videoId: null);
  final host = uri.host.toLowerCase();
  String? id;
  if (host.endsWith('youtu.be')) {
    id = uri.pathSegments.firstOrNull;
  } else if (uri.path == '/watch') {
    id = uri.queryParameters['v'];
  } else if (uri.pathSegments.length >= 2 && const {'shorts', 'live', 'embed', 'v'}.contains(uri.pathSegments.first)) {
    id = uri.pathSegments[1];
  }
  if (id != null && !RegExp(r'^[\w-]{11}$').hasMatch(id)) id = null;
  final q = uri.path == '/results' ? (uri.queryParameters['search_query'] ?? uri.queryParameters['q']) : null;
  return (query: q, videoId: id);
}
