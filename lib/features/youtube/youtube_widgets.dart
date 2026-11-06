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
  const YtVideoCard({super.key, required this.video, required this.onTap, required this.onGrab});

  final YtVideo video;
  final VoidCallback onTap;
  final VoidCallback onGrab;

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
                        tooltip: 'Grab this video',
                        visualDensity: VisualDensity.compact,
                        onPressed: onGrab,
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
  const YtCompactCard({super.key, required this.video, required this.onTap});

  final YtVideo video;
  final VoidCallback onTap;

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
