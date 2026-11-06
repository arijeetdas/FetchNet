import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../models/youtube_models.dart';
import '../../services/youtube_client.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import 'youtube_hub.dart';
import 'youtube_widgets.dart';

/// A channel: header with Subscribe, its videos and its posts.
class YouTubeChannelScreen extends StatefulWidget {
  const YouTubeChannelScreen({super.key, required this.hub, required this.channelId, this.name, this.avatar});

  final YouTubeHub hub;
  final String channelId;
  final String? name;
  final String? avatar;

  @override
  State<YouTubeChannelScreen> createState() => _YouTubeChannelScreenState();
}

class _YouTubeChannelScreenState extends State<YouTubeChannelScreen> {
  late final YouTubeClient _client = AppScope.of(context).youtube.client;

  YtChannelPage? _page;
  YtChannel? _channel;
  List<YtVideo> _videos = const [];
  String? _token;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  bool _showPosts = false;
  List<YtPost>? _posts;
  bool _postsLoading = false;
  String? _postsError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _client.channel(widget.channelId);
      if (!mounted) return;
      setState(() {
        _page = page;
        _channel = page.channel;
        _videos = page.videos.items;
        _token = page.videos.continuation;
      });
    } on YtException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final t = _token;
    if (t == null || _loading || _loadingMore || _showPosts) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _client.more(YtFeedKind.home, t);
      if (!mounted) return;
      final known = _videos.map((v) => '${v.isShort}${v.id}').toSet();
      setState(() {
        _videos = [..._videos, ...page.items.where((v) => known.add('${v.isShort}${v.id}'))];
        _token = page.continuation;
      });
    } on YtException {
      if (mounted) setState(() => _token = null);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadPosts() async {
    if (_posts != null || _postsLoading) return;
    setState(() {
      _postsLoading = true;
      _postsError = null;
    });
    try {
      final posts = await _client.channelPosts(widget.channelId, params: _page?.postsParams);
      if (mounted) setState(() => _posts = posts);
    } on YtException catch (e) {
      if (mounted) setState(() => _postsError = e.message);
    } finally {
      if (mounted) setState(() => _postsLoading = false);
    }
  }

  Future<void> _toggleSubscribe() async {
    final ch = _channel;
    if (ch == null) return;
    final now = !(ch.subscribed ?? false);
    if (!now &&
        !await confirmDialog(
          context,
          title: 'Unsubscribe?',
          message: 'Stop following ${ch.name}?',
          confirmLabel: 'Unsubscribe',
          destructive: true,
        )) {
      return;
    }
    setState(() => _channel = _copy(ch, now));
    try {
      await _client.setSubscribed(ch.id, now);
      if (mounted) showSnack(context, now ? 'Subscribed to ${ch.name}' : 'Unsubscribed', kind: ToastKind.success);
    } on YtException catch (e) {
      if (!mounted) return;
      setState(() => _channel = ch);
      showSnack(context, e.message, kind: ToastKind.error);
    }
  }

  static YtChannel _copy(YtChannel c, bool subscribed) => YtChannel(
    id: c.id,
    name: c.name,
    avatar: c.avatar,
    subscribers: c.subscribers,
    handle: c.handle,
    banner: c.banner,
    subscribed: subscribed,
  );

  void _openVideo(YtVideo v) => widget.hub.openVideo(v.id, preview: v);

  void _download(YtVideo v) => downloadYouTubeVideo(context, id: v.id, title: v.title, thumbnail: v.thumbnail);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ch = _channel;
    final name = ch?.name ?? widget.name ?? 'Channel';
    final wide = MediaQuery.sizeOf(context).width >= 840;

    final header = SliverToBoxAdapter(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1500),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ch?.banner != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: AspectRatio(
                      aspectRatio: wide ? 6.2 : 4,
                      child: Image.network(ch!.banner!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                    ),
                  ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    YtChannelAvatar(url: ch?.avatar ?? widget.avatar, name: name, size: wide ? 80 : 64),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
                          Text(
                            [ch?.handle, ch?.subscribers].whereType<String>().join(' · '),
                            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    if (ch != null) YtSubscribeButton(subscribed: ch.subscribed, onPressed: _toggleSubscribe),
                  ],
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, icon: Icon(Icons.video_library_outlined), label: Text('Videos')),
                      ButtonSegment(value: true, icon: Icon(Icons.forum_outlined), label: Text('Posts')),
                    ],
                    selected: {_showPosts},
                    onSelectionChanged: (s) {
                      setState(() => _showPosts = s.first);
                      if (_showPosts) _loadPosts();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final slivers = <Widget>[header];
    if (_showPosts) {
      if (_postsLoading) {
        slivers.add(const SliverToBoxAdapter(child: YtCenteredState(loader: true, title: 'Loading posts…')));
      } else if (_postsError != null) {
        slivers.add(
          SliverToBoxAdapter(
            child: YtCenteredState(icon: Icons.cloud_off_rounded, title: 'Couldn\'t load posts', message: _postsError),
          ),
        );
      } else if ((_posts ?? const []).isEmpty) {
        slivers.add(
          const SliverToBoxAdapter(
            child: YtCenteredState(
              icon: Icons.forum_outlined,
              title: 'No posts',
              message: 'This channel hasn\'t posted anything yet.',
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
                itemBuilder: (context, i) => YtPostCard(post: _posts![i], onOpenVideo: _openVideo),
              ),
            ),
          ),
        );
      }
    } else if (_loading && _videos.isEmpty) {
      slivers.add(const SliverToBoxAdapter(child: YtCenteredState(loader: true, title: 'Loading channel…')));
    } else if (_error != null && _videos.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: YtCenteredState(
            icon: Icons.cloud_off_rounded,
            title: 'Couldn\'t load this channel',
            message: _error,
            action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ),
        ),
      );
    } else if (_videos.isEmpty) {
      slivers.add(
        const SliverToBoxAdapter(
          child: YtCenteredState(icon: Icons.videocam_off_outlined, title: 'No videos yet'),
        ),
      );
    } else {
      slivers.addAll(ytFeedSlivers(_videos, onTap: _openVideo, onDownload: _download));
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
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: 120 + MediaQuery.paddingOf(context).bottom)));

    return Scaffold(
      body: AuroraBackground(
        intensity: 0.35,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                child: Row(
                  children: [
                    const YtBackButton(),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 800) _loadMore();
                        return false;
                      },
                      child: RefreshIndicator(
                        onRefresh: () async {
                          _posts = null;
                          await _load();
                          if (_showPosts) await _loadPosts();
                        },
                        child: CustomScrollView(slivers: slivers),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: MediaQuery.paddingOf(context).bottom,
                      child: YtMiniPlayer(hub: widget.hub, floating: wide),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
