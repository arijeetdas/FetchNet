import 'package:flutter/material.dart';

import '../../models/youtube_models.dart';
import '../../widgets/brand.dart';

/// Rounded 16:9 (or 9:16 for Shorts) thumbnail with duration / LIVE pill.
class YtThumbnail extends StatelessWidget {
  const YtThumbnail({super.key, required this.video, this.radius = 18, this.aspectRatio = 16 / 9});

  final YtVideo video;
  final double radius;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            Image.network(
              video.thumbnail,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const DecoratedBox(
                decoration: BoxDecoration(gradient: AppColors.brandGradient),
                child: Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 40),
              ),
              frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 250),
                child: child,
              ),
            ),
            if (video.isLive)
              const Positioned(right: 8, bottom: 8, child: YtPill(text: 'LIVE', color: Color(0xFFE11D48)))
            else if (video.duration != null)
              Positioned(right: 8, bottom: 8, child: YtPill(text: video.duration!)),
          ],
        ),
      ),
    );
  }
}

class YtPill extends StatelessWidget {
  const YtPill({super.key, required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color ?? Colors.black.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800)),
    );
  }
}

class YtChannelAvatar extends StatelessWidget {
  const YtChannelAvatar({super.key, required this.url, required this.name, this.size = 36});

  final String? url;
  final String? name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letter = (name == null || name!.isEmpty) ? '?' : name![0].toUpperCase();
    return SizedBox(
      width: size,
      height: size,
      child: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundImage: url == null ? null : NetworkImage(url!),
        onForegroundImageError: url == null ? null : (_, _) {},
        child: Text(
          letter,
          style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w800, fontSize: size * 0.42),
        ),
      ),
    );
  }
}

/// Feed card: big thumbnail, channel avatar, title and stats.
class YtVideoCard extends StatelessWidget {
  const YtVideoCard({super.key, required this.video, required this.onTap, required this.onDownload});

  final YtVideo video;
  final VoidCallback onTap;
  final VoidCallback onDownload;

  /// Height of the text block under the thumbnail.
  static const infoHeight = 92.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = [video.channel, video.stats].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              YtThumbnail(video: video),
              SizedBox(
                height: infoHeight - 8,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      YtChannelAvatar(url: video.channelAvatar, name: video.channel),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.25),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Download',
                        visualDensity: VisualDensity.compact,
                        onPressed: onDownload,
                        icon: Icon(Icons.download_for_offline_rounded, color: scheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Row card for "Up next": thumbnail on the left, text on the right.
class YtCompactCard extends StatelessWidget {
  const YtCompactCard({super.key, required this.video, required this.onTap, this.onDownload});

  final YtVideo video;
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 164, child: YtThumbnail(video: video, radius: 14)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.25),
                  ),
                  const SizedBox(height: 4),
                  if (video.channel != null)
                    Text(
                      video.channel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  if (video.stats.isNotEmpty)
                    Text(
                      video.stats,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (onDownload != null)
              IconButton(
                tooltip: 'Download',
                visualDensity: VisualDensity.compact,
                onPressed: onDownload,
                icon: Icon(Icons.download_for_offline_outlined, color: scheme.primary),
              ),
          ],
        ),
      ),
    );
  }
}

/// A horizontal shelf of Shorts.
class YtShortsShelf extends StatelessWidget {
  const YtShortsShelf({super.key, required this.shorts, required this.onTap});

  final List<YtVideo> shorts;
  final ValueChanged<YtVideo> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
          child: Row(
            children: [
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (b) => AppColors.brandGradient.createShader(Offset.zero & b.size),
                child: const Icon(Icons.bolt_rounded),
              ),
              const SizedBox(width: 6),
              Text('Shorts', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ],
          ),
        ),
        SizedBox(
          height: 270,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: shorts.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final s = shorts[i];
              return SizedBox(
                width: 152,
                child: InkWell(
                  onTap: () => onTap(s),
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      YtThumbnail(video: s, aspectRatio: 9 / 16),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.75)],
                              stops: const [0.55, 1],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 10,
                        right: 10,
                        bottom: 10,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
                            ),
                            if (s.views != null)
                              Text(s.views!, style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// A community post: author, text, images and an attached video.
class YtPostCard extends StatelessWidget {
  const YtPostCard({super.key, required this.post, this.onOpenVideo, this.onOpenChannel});

  final YtPost post;
  final ValueChanged<YtVideo>? onOpenVideo;
  final VoidCallback? onOpenChannel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onOpenChannel,
            borderRadius: BorderRadius.circular(12),
            child: Row(
              children: [
                YtChannelAvatar(url: post.authorAvatar, name: post.author, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(post.author, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                      if (post.published != null)
                        Text(post.published!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (post.text != null) ...[
            const SizedBox(height: 10),
            _ExpandableText(text: post.text!),
          ],
          if (post.images.isNotEmpty) ...[
            const SizedBox(height: 10),
            if (post.images.length == 1)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: Image.network(post.images.first, fit: BoxFit.cover, width: double.infinity,
                      errorBuilder: (_, _, _) => const SizedBox()),
                ),
              )
            else
              SizedBox(
                height: 220,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: post.images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Image.network(post.images[i], fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                    ),
                  ),
                ),
              ),
          ],
          if (post.video != null) ...[
            const SizedBox(height: 10),
            YtCompactCard(video: post.video!, onTap: () => onOpenVideo?.call(post.video!)),
          ],
          if (post.likes != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.thumb_up_alt_outlined, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(post.likes!, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text});

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final long = widget.text.length > 280 || '\n'.allMatches(widget.text).length > 5;
    return GestureDetector(
      onTap: long ? () => setState(() => _open = !_open) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.text,
            maxLines: _open || !long ? null : 5,
            overflow: _open || !long ? TextOverflow.visible : TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          if (long)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _open ? 'Show less' : 'Read more',
                style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w800),
              ),
            ),
        ],
      ),
    );
  }
}

/// Slivers for a feed: runs of Shorts become a shelf, videos a grid.
List<Widget> ytFeedSlivers(
  List<YtVideo> items, {
  required ValueChanged<YtVideo> onTap,
  required ValueChanged<YtVideo> onDownload,
  EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 12),
}) {
  final segments = <({bool shorts, List<YtVideo> items})>[];
  for (final v in items) {
    if (segments.isNotEmpty && segments.last.shorts == v.isShort) {
      segments.last.items.add(v);
    } else {
      segments.add((shorts: v.isShort, items: [v]));
    }
  }
  return [
    for (final s in segments)
      SliverPadding(
        padding: padding,
        sliver: SliverConstrainedCrossAxis(
          maxExtent: 1500,
          sliver: s.shorts
              ? SliverToBoxAdapter(child: YtShortsShelf(shorts: s.items, onTap: onTap))
              : YtVideoGrid(videos: s.items, onTap: onTap, onDownload: onDownload),
        ),
      ),
  ];
}

/// Responsive grid of [YtVideoCard]s.
class YtVideoGrid extends StatelessWidget {
  const YtVideoGrid({super.key, required this.videos, required this.onTap, required this.onDownload});

  final List<YtVideo> videos;
  final ValueChanged<YtVideo> onTap;
  final ValueChanged<YtVideo> onDownload;

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
            (context, i) => YtVideoCard(
              video: videos[i],
              onTap: () => onTap(videos[i]),
              onDownload: () => onDownload(videos[i]),
            ),
            childCount: videos.length,
          ),
        );
      },
    );
  }
}

/// Loader, empty or error state in the middle of a page.
class YtCenteredState extends StatelessWidget {
  const YtCenteredState({super.key, required this.title, this.icon, this.message, this.action, this.loader = false});

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
