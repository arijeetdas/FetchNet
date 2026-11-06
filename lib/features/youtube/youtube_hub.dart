import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/platform/native_bridge.dart';
import '../../models/youtube_models.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import 'player/yt_player_controller.dart';
import 'youtube_download_sheet.dart';
import 'youtube_widgets.dart';

/// What the screens of FetchNet's YouTube view share: the player and the
/// ways to open videos, channels and downloads. Implemented by the YouTube
/// home, handed to the pages it pushes (watch, channel).
abstract class YouTubeHub {
  YtPlayerController get player;

  /// The watch page is on screen (the mini player hides meanwhile).
  ValueListenable<bool> get watchOpen;

  /// Plays [id] and shows the watch page.
  Future<void> openVideo(String id, {YtVideo? preview});

  Future<void> openChannel(String channelId, {String? name, String? avatar});
}

/// The download popup for a video card or the current video.
Future<void> downloadYouTubeVideo(BuildContext context, {required String id, String? title, String? thumbnail}) =>
    showYtDownloadSheet(
      context,
      videoId: id,
      title: title,
      thumbnail: thumbnail ?? 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
    );

/// The system share sheet on Android; elsewhere the link goes on the clipboard.
Future<void> shareYouTubeLink(BuildContext context, String url, {String? title}) async {
  if (NativeBridge.canShareNatively && await NativeBridge.shareText(url, subject: title)) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) showSnack(context, 'Link copied to the clipboard', kind: ToastKind.success);
}

/// Small player docked above the navigation while browsing. Tap to go back
/// to the watch page.
class YtMiniPlayer extends StatelessWidget {
  const YtMiniPlayer({super.key, required this.hub, this.floating = false});

  final YouTubeHub hub;

  /// A card in the corner (wide screens) instead of a full-width bar.
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final c = hub.player;
    return ListenableBuilder(
      listenable: Listenable.merge([c, hub.watchOpen]),
      builder: (context, _) {
        final show = c.hasVideo && !hub.watchOpen.value;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          transitionBuilder: (child, a) => SizeTransition(
            sizeFactor: a,
            alignment: Alignment.bottomCenter,
            child: FadeTransition(opacity: a, child: child),
          ),
          child: show
              ? _MiniCard(key: ValueKey(c.videoId), hub: hub, floating: floating)
              : const SizedBox(width: double.infinity),
        );
      },
    );
  }
}

class _MiniCard extends StatelessWidget {
  const _MiniCard({super.key, required this.hub, required this.floating});

  final YouTubeHub hub;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = hub.player;
    final p = c.player;
    final ready = c.streams != null && !c.listenOnly;
    final picture = SizedBox(
      width: floating ? 150 : 120,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Colors.black,
            child: ready
                ? Video(controller: c.video, controls: NoVideoControls, fill: Colors.black)
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(c.thumbnail, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                      if (c.listenOnly)
                        const ColoredBox(
                          color: Color(0x66000000),
                          child: Icon(Icons.headphones_rounded, color: Colors.white),
                        )
                      else if (c.streamError == null)
                        const ColoredBox(
                          color: Color(0x66000000),
                          child: Center(child: EnergyLoader(size: 24, onColor: true)),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
    final card = Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => hub.openVideo(c.videoId!, preview: c.preview),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
              child: Row(
                children: [
                  picture,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
                        ),
                        if (c.channel != null)
                          Text(
                            c.channel!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  StreamBuilder<bool>(
                    stream: p.stream.playing,
                    initialData: p.state.playing,
                    builder: (context, snap) => IconButton(
                      tooltip: snap.data == true ? 'Pause' : 'Play',
                      onPressed: c.playPause,
                      icon: Icon(snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
                    ),
                  ),
                  IconButton(tooltip: 'Close player', onPressed: c.close, icon: const Icon(Icons.close_rounded)),
                ],
              ),
            ),
            _MiniProgress(controller: c),
          ],
        ),
      ),
    );
    return Padding(
      padding: floating ? const EdgeInsets.all(16) : const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: floating
          ? Align(
              alignment: Alignment.bottomRight,
              child: SizedBox(width: 420, child: card),
            )
          : Center(
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: card),
            ),
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.controller});

  final YtPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.player;
    return StreamBuilder<Duration>(
      stream: p.stream.position,
      initialData: p.state.position,
      builder: (context, pos) {
        final total = p.state.duration.inMilliseconds;
        final v = total <= 0 ? 0.0 : ((pos.data?.inMilliseconds ?? 0) / total).clamp(0.0, 1.0);
        return SizedBox(
          height: 3,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: v,
              heightFactor: 1,
              child: const DecoratedBox(decoration: BoxDecoration(gradient: AppColors.brandGradient)),
            ),
          ),
        );
      },
    );
  }
}

/// Circular back button that keeps its shape in any toolbar.
class YtBackButton extends StatelessWidget {
  const YtBackButton({super.key, this.onPressed, this.icon = Icons.arrow_back_rounded, this.tooltip = 'Back'});

  final VoidCallback? onPressed;
  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox.square(
        dimension: 44,
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
            shape: CircleBorder(side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35))),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed ?? () => Navigator.of(context).maybePop(),
              child: Icon(icon, size: 22, color: scheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

/// Subscribe / Subscribed button.
class YtSubscribeButton extends StatelessWidget {
  const YtSubscribeButton({super.key, required this.subscribed, required this.onPressed, this.dense = false});

  final bool? subscribed;
  final VoidCallback? onPressed;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final on = subscribed ?? false;
    final style = FilledButton.styleFrom(
      minimumSize: Size(0, dense ? 36 : 40),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      textStyle: const TextStyle(fontWeight: FontWeight.w800),
    );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: on
          ? FilledButton.tonalIcon(
              key: const ValueKey('on'),
              onPressed: onPressed,
              style: style,
              icon: const Icon(Icons.notifications_active_outlined, size: 18),
              label: const Text('Subscribed'),
            )
          : DecoratedBox(
              key: const ValueKey('off'),
              decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(999)),
              child: FilledButton(
                onPressed: onPressed,
                style: style.copyWith(
                  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
                  foregroundColor: const WidgetStatePropertyAll(Colors.white),
                ),
                child: const Text('Subscribe'),
              ),
            ),
    );
  }
}

/// Avatar + name, used in the Channels strip.
class YtChannelBubble extends StatelessWidget {
  const YtChannelBubble({super.key, required this.channel, required this.onTap});

  final YtChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 76,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              YtChannelAvatar(url: channel.avatar, name: channel.name, size: 56),
              const SizedBox(height: 6),
              Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
