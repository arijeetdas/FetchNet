import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../services/fetch_service.dart';
import '../../services/youtube_streams.dart';
import '../../widgets/brand.dart';
import '../home/media_result_view.dart';

/// Download options for a YouTube video in a popup, without leaving the
/// YouTube view. Uses the same formats, settings (thumbnails, tags) and
/// rename step as the Home tab. When the video is already playing, its
/// yt-dlp lookup is reused, so the options appear instantly.
Future<void> showYtDownloadSheet(BuildContext context, {required String videoId, String? title, String? thumbnail}) {
  final size = MediaQuery.sizeOf(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxWidth: 980, maxHeight: size.height * 0.92),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => _DownloadSheet(videoId: videoId, title: title, thumbnail: thumbnail),
  );
}

class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({required this.videoId, this.title, this.thumbnail});

  final String videoId;
  final String? title;
  final String? thumbnail;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  late final YtStreamResolver _resolver = AppScope.of(context).youtubeStreams;
  late Future<YtStreams> _future = _lookup();

  /// Still waiting: closing the popup releases the lookup (stopping it when
  /// the player isn't waiting for the same video).
  bool _waiting = false;
  int _gen = 0;

  Future<YtStreams> _lookup({bool refresh = false}) {
    if (_waiting) _resolver.release(widget.videoId);
    _waiting = true;
    final gen = ++_gen;
    final f = _resolver.resolve(widget.videoId, refresh: refresh);
    f.whenComplete(() {
      if (gen == _gen) _waiting = false;
    }).ignore();
    return f;
  }

  void _retry() => setState(() => _future = _lookup(refresh: true));

  @override
  void dispose() {
    if (_waiting) _resolver.release(widget.videoId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(13)),
                child: const Icon(Icons.download_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('Download', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Flexible(
          child: FutureBuilder<YtStreams>(
            future: _future,
            builder: (context, snap) {
              Widget child;
              if (snap.hasData) {
                child = MediaResultView(
                  key: const ValueKey('options'),
                  info: snap.data!.info,
                  framed: false,
                  onQueued: () {
                    if (mounted) Navigator.of(context).pop();
                  },
                );
              } else if (snap.hasError) {
                final e = snap.error;
                child = _Message(
                  key: const ValueKey('error'),
                  icon: Icons.search_off_rounded,
                  title: 'Couldn\'t read the formats',
                  message: e is FetchException ? (e.hint ?? e.message) : '$e',
                  action: FilledButton.tonalIcon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                );
              } else {
                child = _Message(
                  key: const ValueKey('loading'),
                  loader: true,
                  title: widget.title ?? 'Reading the video…',
                  message: 'yt-dlp is looking up the available qualities.',
                  thumbnail: widget.thumbnail,
                );
              }
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: child,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.title,
    this.message,
    this.icon,
    this.action,
    this.loader = false,
    this.thumbnail,
  });

  final String title;
  final String? message;
  final IconData? icon;
  final Widget? action;
  final bool loader;
  final String? thumbnail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          if (thumbnail != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(thumbnail!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                      ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
                      const Center(child: EnergyLoader(size: 52, onColor: true)),
                    ],
                  ),
                ),
              ),
            )
          else if (loader)
            const EnergyLoader(size: 56)
          else if (icon != null)
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(20)),
              child: Icon(icon, color: scheme.onErrorContainer, size: 28),
            ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
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
    );
  }
}
