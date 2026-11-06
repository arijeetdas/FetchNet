import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/platform/pip.dart';
import '../../models/youtube_models.dart';
import '../../services/sites_service.dart';
import '../../services/youtube_client.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/app_navigation.dart';
import '../../widgets/brand.dart';
import '../../widgets/site_icon.dart';
import '../browser/browser_screen.dart';
import '../shell/home_shell.dart' show Breakpoints, FadeIndexedStack;
import 'player/yt_player_controller.dart';
import 'youtube_channel_screen.dart';
import 'youtube_hub.dart';
import 'youtube_settings_screen.dart';
import 'youtube_watch_screen.dart';
import 'youtube_widgets.dart';

/// FetchNet's own YouTube view: the signed-in account's feeds (Home,
/// Trending, Music, Channels), search and the player. Pops with a
/// [BrowserGrab] only when the user grabs a video from the YouTube website.
class YouTubeScreen extends StatefulWidget {
  const YouTubeScreen({super.key, this.initialQuery, this.initialVideoId});

  final String? initialQuery;
  final String? initialVideoId;

  @override
  State<YouTubeScreen> createState() => _YouTubeScreenState();
}

class _YouTubeScreenState extends State<YouTubeScreen> implements YouTubeHub {
  late final AppServices _services = AppScope.of(context);
  late final YouTubeClient _client = _services.youtube.client;
  late final YtPlayerController _player = YtPlayerController(_services.youtube, _services.youtubeStreams);
  final ValueNotifier<bool> _watchOpen = ValueNotifier(false);

  static const _tabs = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.local_fire_department_outlined, Icons.local_fire_department_rounded, 'Trending'),
    (Icons.music_note_outlined, Icons.music_note_rounded, 'Music'),
    (Icons.subscriptions_outlined, Icons.subscriptions_rounded, 'Channels'),
  ];

  int _index = 0;
  int _navTarget = 0;
  final List<ScrollController> _scrolls = List.generate(_tabs.length, (_) => ScrollController());
  final ScrollController _searchScroll = ScrollController();

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String? _query;
  int _queryVersion = 0;
  List<String> _suggestions = const [];
  Timer? _suggestTimer;

  @override
  YtPlayerController get player => _player;

  @override
  ValueListenable<bool> get watchOpen => _watchOpen;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
    _searchFocus.addListener(() => setState(() {}));
    final q = widget.initialQuery?.trim();
    if (q != null && q.isNotEmpty) {
      _search.text = q;
      _query = q;
    }
    final id = widget.initialVideoId;
    if (id != null) WidgetsBinding.instance.addPostFrameCallback((_) => openVideo(id));
  }

  @override
  void dispose() {
    _suggestTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    for (final s in _scrolls) {
      s.dispose();
    }
    _searchScroll.dispose();
    Pip.setAutoEnter(false);
    _player.dispose();
    _watchOpen.dispose();
    super.dispose();
  }

  // ───── Hub ─────

  @override
  Future<void> openVideo(String id, {YtVideo? preview}) async {
    _searchFocus.unfocus();
    unawaited(_player.open(id, preview: preview));
    if (_watchOpen.value) return;
    _watchOpen.value = true;
    final grab = await Navigator.of(context).push<BrowserGrab>(YouTubeWatchScreen.route(this));
    _watchOpen.value = false;
    if (grab != null && mounted) {
      // Grabbed on the YouTube website: hand it to the Home tab.
      final self = ModalRoute.of(context);
      Navigator.of(context).popUntil((r) => r == self);
      Navigator.of(context).pop(grab);
    }
  }

  @override
  Future<void> openChannel(String channelId, {String? name, String? avatar}) async {
    // Like YouTube: the player shrinks to the mini player.
    if (_watchOpen.value) Navigator.of(context).pop();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => YouTubeChannelScreen(hub: this, channelId: channelId, name: name, avatar: avatar),
      ),
    );
  }

  void _download(YtVideo v) => downloadYouTubeVideo(context, id: v.id, title: v.title, thumbnail: v.thumbnail);

  // ───── Navigation ─────

  void _target(int i) {
    _leaveSearch();
    if (i != _navTarget) setState(() => _navTarget = i);
  }

  void _show(int i) {
    _leaveSearch();
    if (i == _index && i == _navTarget) {
      // Tapping the current tab again goes back to the top.
      final s = _scrolls[i];
      if (s.hasClients) s.animateTo(0, duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
      return;
    }
    setState(() => _index = _navTarget = i);
  }

  void _leaveSearch() {
    if (_query != null || _searchFocus.hasFocus) {
      _searchFocus.unfocus();
      _search.clear();
      setState(() => _query = null);
    }
  }

  /// Back: close suggestions, then the search, then the YouTube view.
  bool get _canPop => !_searchFocus.hasFocus && _query == null;

  void _back() {
    if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
      if (_query != null) _search.text = _query!;
    } else if (_query != null) {
      _leaveSearch();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  // ───── Search ─────

  void _onSearchChanged() {
    final text = _search.text.trim();
    _suggestTimer?.cancel();
    if (text.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    setState(() {});
    _suggestTimer = Timer(const Duration(milliseconds: 180), () async {
      final list = await _client.suggestions(text);
      if (!mounted || _search.text.trim() != text) return;
      setState(() => _suggestions = list);
    });
  }

  void _runSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    _search.value = TextEditingValue(
      text: q,
      selection: TextSelection.collapsed(offset: q.length),
    );
    _searchFocus.unfocus();
    _services.youtube.rememberSearch(q);
    setState(() {
      _query = q;
      _queryVersion++;
    });
    if (_searchScroll.hasClients) _searchScroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= Breakpoints.rail;
    final extended = width >= Breakpoints.wide;
    final typing = _searchFocus.hasFocus;
    final bottomInset = useRail ? 140.0 : FloatingNavBar.reservedHeight(context) + 110;

    final tabs = FadeIndexedStack(
      index: _index,
      children: [
        _FeedTab(
          hub: this,
          active: _index == 0,
          scroll: _scrolls[0],
          bottomInset: bottomInset,
          loader: _client.home,
          onDownload: _download,
          emptyIcon: Icons.explore_outlined,
          emptyTitle: 'Nothing recommended yet',
          emptyMessage:
              'YouTube has no recommendations for this account yet (watch history may be off). '
              'Search for something to get started.',
        ),
        _TrendingTab(
          hub: this,
          active: _index == 1,
          scroll: _scrolls[1],
          bottomInset: bottomInset,
          onDownload: _download,
        ),
        _FeedTab(
          hub: this,
          active: _index == 2,
          scroll: _scrolls[2],
          bottomInset: bottomInset,
          loader: _client.music,
          onDownload: _download,
          header: const _SectionTitle(icon: Icons.music_note_rounded, title: 'Music'),
          emptyIcon: Icons.music_off_rounded,
          emptyTitle: 'No music right now',
        ),
        _ChannelsTab(
          hub: this,
          active: _index == 3,
          scroll: _scrolls[3],
          bottomInset: bottomInset,
          onDownload: _download,
        ),
      ],
    );

    final content = Stack(
      children: [
        Positioned.fill(
          child: Offstage(offstage: _query != null, child: tabs),
        ),
        if (_query != null)
          Positioned.fill(
            child: _FeedTab(
              key: ValueKey('search-$_queryVersion'),
              hub: this,
              scroll: _searchScroll,
              bottomInset: bottomInset,
              loader: () => _client.search(_query!),
              moreKind: YtFeedKind.search,
              onDownload: _download,
              emptyIcon: Icons.search_off_rounded,
              emptyTitle: 'No results',
              emptyMessage: 'Try different words.',
              refreshable: false,
            ),
          ),
        if (typing)
          Positioned.fill(
            child: ListenableBuilder(
              listenable: _services.youtube,
              builder: (context, _) => _SuggestionsPanel(
                text: _search.text.trim(),
                history: _services.youtube.searchHistory,
                suggestions: _suggestions,
                onPick: _runSearch,
                onFill: (s) {
                  _search.value = TextEditingValue(
                    text: '$s ',
                    selection: TextSelection.collapsed(offset: s.length + 1),
                  );
                },
                onForget: _services.youtube.forgetSearch,
                onClearAll: _services.youtube.clearSearchHistory,
                onDismiss: _searchFocus.unfocus,
              ),
            ),
          ),
        if (useRail && !typing)
          Positioned(left: 0, right: 0, bottom: 0, child: YtMiniPlayer(hub: this, floating: true)),
      ],
    );

    final topBar = _TopBar(
      controller: _search,
      focusNode: _searchFocus,
      onBack: _back,
      onSubmit: _runSearch,
      onClear: () {
        _search.clear();
        _searchFocus.requestFocus();
      },
      profile: _services.youtube.profile,
      onProfile: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeSettingsScreen())),
      showBack: true,
    );

    final items = [for (final t in _tabs) LiquidNavItem(icon: t.$1, selectedIcon: t.$2, label: t.$3)];

    Widget page;
    if (!useRail) {
      page = Scaffold(
        extendBody: true,
        body: AuroraBackground(
          intensity: 0.5,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                topBar,
                Expanded(child: content),
              ],
            ),
          ),
        ),
        bottomNavigationBar: typing
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  YtMiniPlayer(hub: this),
                  FloatingNavBar(target: _navTarget, onTargetChanged: _target, onSettled: _show, items: items),
                ],
              ),
      );
    } else {
      page = Scaffold(
        body: AuroraBackground(
          intensity: 0.5,
          child: Row(
            children: [
              AppNavRail(
                extended: extended,
                selectedIndex: _index,
                onSelected: _show,
                items: items,
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
                  child: extended
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const BrandGlyph(brand: SiteBrand.youtube, size: 34),
                            const SizedBox(width: 12),
                            Text(
                              'YouTube',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                            ),
                          ],
                        )
                      : const BrandGlyph(brand: SiteBrand.youtube, size: 36),
                ),
              ),
              Expanded(
                child: SafeArea(
                  bottom: false,
                  left: false,
                  child: Column(
                    children: [
                      topBar,
                      Expanded(child: content),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: page,
    );
  }
}

// ───── Top bar ─────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.focusNode,
    required this.onBack,
    required this.onSubmit,
    required this.onClear,
    required this.profile,
    required this.onProfile,
    required this.showBack,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onBack;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;
  final GoogleProfile? profile;
  final VoidCallback onProfile;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none);
    final field = SizedBox(
      height: 46,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        textInputAction: TextInputAction.search,
        onSubmitted: onSubmit,
        style: theme.textTheme.bodyLarge,
        decoration: InputDecoration(
          filled: true,
          fillColor: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          hintText: 'Search YouTube',
          prefixIcon: const Padding(
            padding: EdgeInsets.all(11),
            child: BrandGlyph(brand: SiteBrand.youtube, size: 22),
          ),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded), onPressed: onClear),
          border: border,
          enabledBorder: border,
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide(color: scheme.primary),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        children: [
          if (showBack) ...[YtBackButton(onPressed: onBack), const SizedBox(width: 10)],
          Expanded(
            child: Center(
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: field),
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            customBorder: const CircleBorder(),
            onTap: onProfile,
            child: Tooltip(
              message: 'YouTube settings',
              child: GoogleAvatar(profile: profile, size: 40),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionsPanel extends StatelessWidget {
  const _SuggestionsPanel({
    required this.text,
    required this.history,
    required this.suggestions,
    required this.onPick,
    required this.onFill,
    required this.onForget,
    required this.onClearAll,
    required this.onDismiss,
  });

  final String text;
  final List<String> history;
  final List<String> suggestions;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onFill;
  final ValueChanged<String> onForget;
  final VoidCallback onClearAll;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lower = text.toLowerCase();
    final past = text.isEmpty ? history : history.where((h) => h.toLowerCase().contains(lower)).take(4).toList();
    final pastLower = past.map((e) => e.toLowerCase()).toSet();
    final live = text.isEmpty
        ? const <String>[]
        : suggestions.where((s) => !pastLower.contains(s.toLowerCase())).toList();

    Widget row(String s, {required bool fromHistory}) => ListTile(
      leading: Icon(fromHistory ? Icons.history_rounded : Icons.search_rounded, color: scheme.onSurfaceVariant),
      title: _Highlighted(text: s, query: text),
      onTap: () => onPick(s),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fromHistory)
            IconButton(
              tooltip: 'Remove from history',
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => onForget(s),
            ),
          IconButton(tooltip: 'Edit', icon: const Icon(Icons.north_west_rounded, size: 20), onPressed: () => onFill(s)),
        ],
      ),
    );

    final rows = <Widget>[
      if (text.isEmpty && history.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
          child: Row(
            children: [
              Text('Recent searches', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              const Spacer(),
              TextButton(onPressed: onClearAll, child: const Text('Clear all')),
            ],
          ),
        ),
      for (final h in past) row(h, fromHistory: true),
      for (final s in live) row(s, fromHistory: false),
      if (text.isEmpty && history.isEmpty)
        Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(Icons.manage_search_rounded, size: 44, color: scheme.primary),
              const SizedBox(height: 10),
              Text('Search YouTube', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Your recent searches show up here.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 760) {
          // Phones: a full page over the feed, like the YouTube app.
          return Material(
            color: scheme.surface,
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 24),
              children: rows,
            ),
          );
        }
        // Wide screens: a dropdown under the search field.
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: onDismiss,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
              ),
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 680, maxHeight: box.maxHeight * 0.75),
                  child: Material(
                    color: scheme.surfaceContainerLow,
                    elevation: 12,
                    shadowColor: Colors.black.withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 8), children: rows),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// [text] with the part matching [query] in normal weight and the rest bold,
/// like YouTube's suggestions.
class _Highlighted extends StatelessWidget {
  const _Highlighted({required this.text, required this.query});

  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge;
    final i = query.isEmpty ? -1 : text.toLowerCase().indexOf(query.toLowerCase());
    if (i < 0) return Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    final bold = style?.copyWith(fontWeight: FontWeight.w800);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, i), style: bold),
          TextSpan(text: text.substring(i, i + query.length), style: style),
          TextSpan(text: text.substring(i + query.length), style: bold),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        children: [
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (b) => AppColors.brandGradient.createShader(Offset.zero & b.size),
            child: Icon(icon, size: 26),
          ),
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

// ───── Feeds ─────

/// A feed that loads when its tab is first shown, pages on scroll and
/// pulls to refresh.
class _FeedTab extends StatefulWidget {
  const _FeedTab({
    super.key,
    required this.hub,
    required this.loader,
    required this.onDownload,
    required this.scroll,
    required this.bottomInset,
    this.active = true,
    this.reloadKey,
    this.moreKind = YtFeedKind.home,
    this.header,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage,
    this.refreshable = true,
  });

  final YouTubeHub hub;
  final Future<YtPage> Function() loader;
  final ValueChanged<YtVideo> onDownload;
  final ScrollController scroll;
  final double bottomInset;
  final bool active;

  /// When it changes, the feed reloads (e.g. a Trending chip).
  final Object? reloadKey;
  final YtFeedKind moreKind;
  final Widget? header;
  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptyMessage;
  final bool refreshable;

  @override
  State<_FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<_FeedTab> {
  late final YouTubeClient _client = AppScope.of(context).youtube.client;
  List<YtVideo> _items = const [];
  String? _token;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loaded = false;
  String? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(_FeedTab old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) {
      _items = const [];
      _load();
    } else if (widget.active && !_loaded && !_loading) {
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_gen;
    _loaded = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.loader();
      if (!mounted || gen != _gen) return;
      setState(() {
        _items = page.items;
        _token = page.continuation;
      });
    } on YtException catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e.message);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    final t = _token;
    if (t == null || _loading || _loadingMore) return;
    final gen = _gen;
    setState(() => _loadingMore = true);
    try {
      final page = await _client.more(widget.moreKind, t);
      if (!mounted || gen != _gen) return;
      final known = _items.map((v) => '${v.isShort}${v.id}').toSet();
      setState(() {
        _items = [..._items, ...page.items.where((v) => known.add('${v.isShort}${v.id}'))];
        _token = page.continuation;
      });
    } on YtException {
      if (mounted && gen == _gen) setState(() => _token = null);
    } finally {
      if (mounted && gen == _gen) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slivers = <Widget>[if (widget.header != null) SliverToBoxAdapter(child: widget.header)];
    if (_loading && _items.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: YtCenteredState(loader: true, title: 'Loading YouTube…'),
        ),
      );
    } else if (_error != null && _items.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: YtCenteredState(
            icon: Icons.cloud_off_rounded,
            title: 'Couldn\'t load YouTube',
            message: _error,
            action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ),
        ),
      );
    } else if (_items.isEmpty && _loaded) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: YtCenteredState(icon: widget.emptyIcon, title: widget.emptyTitle, message: widget.emptyMessage),
        ),
      );
    } else {
      slivers.addAll(
        ytFeedSlivers(
          _items,
          onTap: (v) => widget.hub.openVideo(v.id, preview: v),
          onDownload: widget.onDownload,
        ),
      );
      if (_loadingMore) {
        slivers.add(
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: EnergyLoader(size: 40)),
            ),
          ),
        );
      }
    }
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: widget.bottomInset)));

    final scroll = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 900) _more();
        return false;
      },
      child: CustomScrollView(
        controller: widget.scroll,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );
    return widget.refreshable ? RefreshIndicator(onRefresh: _load, child: scroll) : scroll;
  }
}

class _TrendingTab extends StatefulWidget {
  const _TrendingTab({
    required this.hub,
    required this.active,
    required this.scroll,
    required this.bottomInset,
    required this.onDownload,
  });

  final YouTubeHub hub;
  final bool active;
  final ScrollController scroll;
  final double bottomInset;
  final ValueChanged<YtVideo> onDownload;

  @override
  State<_TrendingTab> createState() => _TrendingTabState();
}

class _TrendingTabState extends State<_TrendingTab> {
  YtTrendingTopic _topic = YtTrendingTopic.now;

  @override
  Widget build(BuildContext context) {
    final client = AppScope.of(context).youtube.client;
    final topic = _topic;
    return _FeedTab(
      hub: widget.hub,
      active: widget.active,
      scroll: widget.scroll,
      bottomInset: widget.bottomInset,
      reloadKey: topic,
      loader: () => client.trending(topic),
      onDownload: widget.onDownload,
      emptyIcon: Icons.local_fire_department_outlined,
      emptyTitle: 'Nothing trending here right now',
      header: SizedBox(
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          children: [
            for (final t in YtTrendingTopic.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(t.label),
                  selected: t == _topic,
                  showCheckmark: false,
                  onSelected: (_) {
                    if (t == _topic) return;
                    setState(() => _topic = t);
                    if (widget.scroll.hasClients) widget.scroll.jumpTo(0);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Videos and posts from the channels the account follows.
class _ChannelsTab extends StatefulWidget {
  const _ChannelsTab({
    required this.hub,
    required this.active,
    required this.scroll,
    required this.bottomInset,
    required this.onDownload,
  });

  final YouTubeHub hub;
  final bool active;
  final ScrollController scroll;
  final double bottomInset;
  final ValueChanged<YtVideo> onDownload;

  @override
  State<_ChannelsTab> createState() => _ChannelsTabState();
}

class _ChannelsTabState extends State<_ChannelsTab> {
  late final YouTubeClient _client = AppScope.of(context).youtube.client;
  List<YtChannel>? _channels;
  bool _channelsLoading = false;

  bool _postsMode = false;
  List<YtPost>? _posts;
  bool _postsLoading = false;
  String? _postsError;

  @override
  void initState() {
    super.initState();
    if (widget.active) _loadChannels();
  }

  @override
  void didUpdateWidget(_ChannelsTab old) {
    super.didUpdateWidget(old);
    if (widget.active && _channels == null && !_channelsLoading) _loadChannels();
  }

  Future<void> _loadChannels() async {
    setState(() => _channelsLoading = true);
    try {
      final list = await _client.subscribedChannels();
      if (mounted) setState(() => _channels = list);
    } on YtException {
      if (mounted) setState(() => _channels = const []);
    } finally {
      if (mounted) setState(() => _channelsLoading = false);
    }
  }

  Future<void> _loadPosts() async {
    setState(() {
      _postsLoading = true;
      _postsError = null;
    });
    try {
      if (_channels == null) await _loadChannels();
      final posts = await _client.subscriptionPosts(_channels ?? const []);
      if (mounted) setState(() => _posts = posts);
    } on YtException catch (e) {
      if (mounted) setState(() => _postsError = e.message);
    } finally {
      if (mounted) setState(() => _postsLoading = false);
    }
  }

  Widget _header(BuildContext context) {
    final channels = _channels ?? const <YtChannel>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (channels.isNotEmpty)
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: channels.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, i) => YtChannelBubble(
                channel: channels[i],
                onTap: () => widget.hub.openChannel(channels[i].id, name: channels[i].name, avatar: channels[i].avatar),
              ),
            ),
          )
        else if (_channelsLoading)
          const SizedBox(height: 100, child: Center(child: EnergyLoader(size: 32))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.video_library_outlined), label: Text('Videos')),
                ButtonSegment(value: true, icon: Icon(Icons.forum_outlined), label: Text('Posts')),
              ],
              selected: {_postsMode},
              onSelectionChanged: (s) {
                setState(() => _postsMode = s.first);
                if (_postsMode && _posts == null && !_postsLoading) _loadPosts();
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final header = _header(context);
    if (!_postsMode) {
      return _FeedTab(
        hub: widget.hub,
        active: widget.active,
        scroll: widget.scroll,
        bottomInset: widget.bottomInset,
        loader: _client.subscriptions,
        onDownload: widget.onDownload,
        header: header,
        emptyIcon: Icons.subscriptions_outlined,
        emptyTitle: 'No videos from your channels',
        emptyMessage: 'Subscribe to channels and their new videos show up here.',
      );
    }

    final slivers = <Widget>[SliverToBoxAdapter(child: header)];
    if (_postsLoading && _posts == null) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: YtCenteredState(
            loader: true,
            title: 'Collecting posts…',
            message: 'Checking the channels you follow.',
          ),
        ),
      );
    } else if (_postsError != null && _posts == null) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: YtCenteredState(
            icon: Icons.cloud_off_rounded,
            title: 'Couldn\'t load posts',
            message: _postsError,
            action: FilledButton.tonalIcon(
              onPressed: _loadPosts,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ),
        ),
      );
    } else if ((_posts ?? const []).isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: YtCenteredState(
            icon: Icons.forum_outlined,
            title: 'No posts yet',
            message: 'Posts from the channels you follow show up here.',
          ),
        ),
      );
    } else {
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverConstrainedCrossAxis(
            maxExtent: 760,
            sliver: SliverList.separated(
              itemCount: _posts!.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final p = _posts![i];
                return YtPostCard(
                  post: p,
                  onOpenVideo: (v) => widget.hub.openVideo(v.id, preview: v),
                  onOpenChannel: p.channelId == null
                      ? null
                      : () => widget.hub.openChannel(p.channelId!, name: p.author, avatar: p.authorAvatar),
                );
              },
            ),
          ),
        ),
      );
    }
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: widget.bottomInset)));
    return RefreshIndicator(
      onRefresh: _loadPosts,
      child: CustomScrollView(
        controller: widget.scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );
  }
}

/// Opens the YouTube view, or YouTube Settings when nobody is signed in.
/// Completes with a video grabbed on the YouTube website, if any.
Future<BrowserGrab?> openYouTube(BuildContext context, {String? query, String? videoId}) async {
  final services = AppScope.of(context);
  if (!services.youtube.signedIn) {
    showSnack(context, 'Sign in with Google to use YouTube in FetchNet');
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const YouTubeSettingsScreen()));
    return null;
  }
  return Navigator.of(context).push<BrowserGrab>(
    MaterialPageRoute(
      builder: (_) => YouTubeScreen(initialQuery: query, initialVideoId: videoId),
    ),
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
