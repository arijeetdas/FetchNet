import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../engine/engine.dart';
import '../../models/gallery_models.dart';
import '../../models/media_info.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/motion/motion_core.dart';
import 'home_kit.dart';
import 'media_preview.dart';
import 'rename_dialog.dart';

/// Every file of a post (gallery-dl): filter by type, pick files, preview
/// them full screen, download them together. A profile / board link lists
/// its posts instead.
class PostResultView extends StatefulWidget {
  const PostResultView({super.key, required this.post, required this.onOpenChild, this.framed = true, this.onQueued});

  final GalleryPost post;

  /// A post of a profile was tapped.
  final void Function(String url) onOpenChild;
  final bool framed;
  final VoidCallback? onQueued;

  @override
  State<PostResultView> createState() => _PostResultViewState();
}

class _PostResultViewState extends State<PostResultView> {
  GalleryItemKind? _filter;
  late final Set<int> _selected = {for (final i in widget.post.items) i.index};

  /// Tiles built at first; big galleries show more on request.
  int _shown = 60;

  List<GalleryItem> get _visible => widget.post.items.where((i) => _filter == null || i.kind == _filter).toList();

  void _toggle(GalleryItem item) => setState(() {
        if (!_selected.remove(item.index)) _selected.add(item.index);
      });

  Future<void> _download() async {
    final services = AppScope.of(context);
    final post = widget.post;
    final items = post.items.where((i) => _selected.contains(i.index)).toList();
    if (items.isEmpty) return;
    if (services.storage.downloadDir == null) {
      await services.storage.ensureDownloadDir(requestPermission: true);
      if (!mounted) return;
      if (services.storage.downloadDir == null) {
        showSnack(context, services.storage.error ?? 'The download folder isn\'t available.', kind: ToastKind.error);
        return;
      }
    }
    final single = items.length == 1 ? items.first : null;
    final all = items.length == post.items.length && !post.truncated;
    final sizes = items.map((i) => i.sizeBytes).whereType<int>().toList();
    final option = DownloadOption(
      kind: single == null
          ? MediaKind.post
          : switch (single.kind) {
              GalleryItemKind.video => MediaKind.video,
              GalleryItemKind.audio => MediaKind.audio,
              _ => MediaKind.image,
            },
      label: single == null ? '${items.length} files' : _kindLabel(single.kind),
      detail: single == null ? _summary(items) : single.extension.toUpperCase(),
      extension: single?.extension ?? '',
      sizeBytes: sizes.length == items.length && sizes.isNotEmpty ? sizes.reduce((a, b) => a + b) : null,
      formatArgs: const [],
      gallery: GalleryDownload(count: items.length, range: all ? null : GalleryPost.rangeOf(items.map((i) => i.index))),
    );
    final info = post.toMediaInfo();
    final name = await showRenameDialog(context, info: info, option: option);
    if (name == null || !mounted) return;
    await services.downloads.enqueue(info: info, option: option, fileBaseName: name);
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    showSnack(
      context,
      single == null ? 'Downloading ${items.length} files as "$name 1" to "$name ${items.length}"' : 'Downloading $name.${single.extension}',
      kind: ToastKind.success,
      actionLabel: 'View',
      onAction: () {
        navigator.popUntil((r) => r.isFirst);
        services.tabRequest.value = 1;
      },
    );
    widget.onQueued?.call();
  }

  /// Opens the full-screen viewer on [item], swiping through [visible].
  void _preview(List<GalleryItem> visible, GalleryItem item) {
    showMediaPreview(
      context,
      initial: visible.indexOf(item),
      headers: {'Referer': widget.post.url},
      items: [
        for (final i in visible)
          PreviewItem(
            url: _fullPicture(i) ?? '',
            caption: [
              '${_kindLabel(i.kind)} ${i.index}',
              if (i.width != null && i.height != null) '${i.width}×${i.height}',
              if (i.sizeBytes != null) formatBytes(i.sizeBytes),
            ].join(' · '),
            icon: _kindIcon(i.kind),
          ),
      ],
      isSelected: (n) => _selected.contains(visible[n].index),
      onToggle: (n) => _toggle(visible[n]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final body = post.items.isEmpty ? _ChildrenList(post: post, onOpen: widget.onOpenChild) : _buildFiles(context);
    if (!widget.framed) return body;
    return HomePanel(highlight: true, padding: const EdgeInsets.all(16), child: body);
  }

  Widget _buildFiles(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final services = AppScope.of(context);
    final post = widget.post;
    final visible = _visible;
    final allVisibleSelected = visible.isNotEmpty && visible.every((i) => _selected.contains(i.index));
    final kinds = [for (final k in GalleryItemKind.values) if (post.count(k) > 0) k];
    final picked = post.items.where((i) => _selected.contains(i.index)).toList();
    final sizes = picked.map((i) => i.sizeBytes).whereType<int>().toList();
    final total = sizes.isEmpty ? null : sizes.reduce((a, b) => a + b);
    final sizeKnown = sizes.length == picked.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntranceMotion(child: _PostHeader(post: post)),
        const SizedBox(height: 16),
        if (kinds.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SlidingSegments<GalleryItemKind?>(
              segments: [
                Segment(value: null, label: 'All', count: post.items.length),
                for (final k in kinds)
                  Segment(value: k, icon: _kindIcon(k), label: _kindLabel(k, plural: post.count(k) != 1), count: post.count(k)),
              ],
              selected: _filter,
              onChanged: (k) => setState(() => _filter = k),
            ),
          ),
        if (post.truncated)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'A big post: showing its first ${post.items.length} files.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        // Selection bar.
        Container(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedSwitcher(
                      duration: homeDuration(context, const Duration(milliseconds: 180)),
                      layoutBuilder: (current, previous) =>
                          Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                      child: Text(
                        '${_selected.length} of ${post.items.length} selected',
                        key: ValueKey(_selected.length),
                        style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text(
                      total == null ? 'Tap to pick · hold to preview' : '${sizeKnown ? '' : 'at least '}${formatBytes(total)} · hold to preview',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Invert selection',
                onPressed: visible.isEmpty
                    ? null
                    : () => setState(() {
                          for (final i in visible) {
                            if (!_selected.remove(i.index)) _selected.add(i.index);
                          }
                        }),
                icon: const Icon(Icons.flip_rounded),
              ),
              TextButton.icon(
                onPressed: visible.isEmpty
                    ? null
                    : () => setState(() {
                          if (allVisibleSelected) {
                            _selected.removeAll(visible.map((i) => i.index));
                          } else {
                            _selected.addAll(visible.map((i) => i.index));
                          }
                        }),
                icon: Icon(allVisibleSelected ? Icons.deselect_rounded : Icons.select_all_rounded),
                label: Text(allVisibleSelected ? 'None' : 'All'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: homeDuration(context, const Duration(milliseconds: 260)),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
          child: LayoutBuilder(
            key: ValueKey(_filter),
            builder: (context, c) {
              final columns = (c.maxWidth / 140).floor().clamp(2, 6);
              final shown = visible.take(_shown).toList();
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: shown.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemBuilder: (context, i) {
                  final item = shown[i];
                  return EntranceMotion(
                    index: i,
                    step: const Duration(milliseconds: 30),
                    offset: 10,
                    child: _FileTile(
                      item: item,
                      referer: post.url,
                      selected: _selected.contains(item.index),
                      onTap: () => _toggle(item),
                      onPreview: () => _preview(visible, item),
                    ),
                  );
                },
              );
            },
          ),
        ),
        if (visible.length > _shown)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(
              child: TextButton.icon(
                onPressed: () => setState(() => _shown += 120),
                icon: const Icon(Icons.expand_more_rounded),
                label: Text('Show ${(visible.length - _shown).clamp(0, 120)} more'),
              ),
            ),
          ),
        const SizedBox(height: 16),
        ValueListenableBuilder<EngineStatus>(
          valueListenable: services.gallery.engine.status,
          builder: (context, status, _) {
            final ready = status.isReady;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GradientButton(
                  label: _selected.isEmpty
                      ? 'Pick files to download'
                      : [
                          _selected.length == 1 ? 'Download 1 file' : 'Download ${_selected.length} files',
                          if (total != null && sizeKnown) '~${formatBytes(total)}',
                        ].join('  ·  '),
                  icon: Icons.download_rounded,
                  expand: true,
                  height: 56,
                  loading: !ready && status.state != EngineState.error,
                  onPressed: _selected.isEmpty || !ready ? null : _download,
                ),
                if (!ready && status.message != null) ...[
                  const SizedBox(height: 8),
                  Text(status.message!, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

/// The best picture of [item] for the full-screen viewer: the image itself,
/// or a video's poster.
String? _fullPicture(GalleryItem item) {
  if (item.kind == GalleryItemKind.image && !item.viaYtDlp && item.url.startsWith('http')) return item.url;
  return item.preview;
}

String _kindLabel(GalleryItemKind kind, {bool plural = false}) => switch (kind) {
      GalleryItemKind.image => plural ? 'Images' : 'Image',
      GalleryItemKind.video => plural ? 'Videos' : 'Video',
      GalleryItemKind.audio => 'Audio',
      GalleryItemKind.other => plural ? 'Files' : 'File',
    };

IconData _kindIcon(GalleryItemKind kind) => switch (kind) {
      GalleryItemKind.image => Icons.photo_rounded,
      GalleryItemKind.video => Icons.movie_rounded,
      GalleryItemKind.audio => Icons.music_note_rounded,
      GalleryItemKind.other => Icons.insert_drive_file_rounded,
    };

/// `8 images · 3 videos`
String _summary(List<GalleryItem> items) {
  final parts = <String>[];
  for (final k in GalleryItemKind.values) {
    final n = items.where((i) => i.kind == k).length;
    if (n > 0) parts.add('$n ${_kindLabel(k, plural: n != 1).toLowerCase()}');
  }
  return parts.join(' · ');
}

class _PostHeader extends StatelessWidget {
  const _PostHeader({required this.post});

  final GalleryPost post;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final covers = [for (final i in post.items) ?i.preview].take(3).toList();
    final chips = <Widget>[
      if (post.site != null) MetaChip(icon: Icons.public_rounded, text: post.site!, strong: true),
      if (post.author != null) MetaChip(icon: Icons.person_rounded, text: post.author!),
      for (final k in GalleryItemKind.values)
        if (post.count(k) > 0) MetaChip(icon: _kindIcon(k), text: '${post.count(k)}${post.truncated ? '+' : ''} ${_kindLabel(k, plural: post.count(k) != 1).toLowerCase()}'),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CoverStack(covers: covers, referer: post.url, isPost: post.items.isNotEmpty),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                post.title,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.25),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (post.description != null && post.description!.trim().isNotEmpty && post.description!.trim() != post.title.trim()) ...[
                const SizedBox(height: 4),
                Text(
                  post.description!.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
                ),
              ],
              if (chips.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: chips),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Up to three of the post's pictures, fanned like a little stack of prints.
class _CoverStack extends StatelessWidget {
  const _CoverStack({required this.covers, required this.referer, required this.isPost});

  final List<String> covers;
  final String referer;
  final bool isPost;

  @override
  Widget build(BuildContext context) {
    const size = 72.0;
    final scheme = Theme.of(context).colorScheme;
    Widget tile(Widget child) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.surfaceContainerLowest, width: 2.5),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(15.5), child: child),
        );
    final fallback = DecoratedBox(
      decoration: const BoxDecoration(gradient: tileGradient),
      child: Icon(isPost ? Icons.photo_library_rounded : Icons.collections_bookmark_rounded, color: Colors.white),
    );
    if (covers.isEmpty) return tile(fallback);
    // (angle, dx) per print: the first lies straight on top of the others.
    const fan = [(0.0, 0.0), (0.13, 7.0), (-0.13, -7.0)];
    final n = covers.length;
    return SizedBox(
      width: size + 14,
      height: size + 10,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = n - 1; i >= 0; i--)
            Positioned(
              left: 7 + fan[i].$2,
              top: 5,
              child: Transform.rotate(
                angle: fan[i].$1,
                child: tile(
                  FadeInNetworkImage(url: covers[i], headers: {'Referer': referer}, cacheWidth: 200, fallback: fallback),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.item,
    required this.referer,
    required this.selected,
    required this.onTap,
    required this.onPreview,
  });

  final GalleryItem item;
  final String referer;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dims = item.width != null && item.height != null ? '${item.width}×${item.height}' : null;
    final badge = switch (item.kind) {
      GalleryItemKind.image => item.extension == 'gif' ? 'GIF' : item.extension.toUpperCase(),
      GalleryItemKind.video => item.duration != null && item.duration! > 0 ? formatDuration(item.duration) : 'VIDEO',
      GalleryItemKind.audio => 'AUDIO',
      GalleryItemKind.other => item.extension.toUpperCase(),
    };
    final footer = [?dims, if (item.sizeBytes != null) formatBytes(item.sizeBytes)].join(' · ');
    final preview = item.preview;
    final d = homeDuration(context, const Duration(milliseconds: 240));
    final fallback = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(_kindIcon(item.kind), size: 34, color: scheme.onSurfaceVariant),
    );

    return Semantics(
      selected: selected,
      button: true,
      label: '${_kindLabel(item.kind)} ${item.index}${footer.isEmpty ? '' : ', $footer'}',
      onLongPressHint: 'Preview',
      child: PressableScale(
        scale: 0.95,
        child: AnimatedContainer(
          duration: d,
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.all(selected ? 2.5 : 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: selected ? AppColors.brandGradient : null,
          ),
          child: Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(selected ? 15.5 : 18),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onPreview,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedScale(
                    scale: selected ? 1.0 : 1.04,
                    duration: d,
                    child: preview != null
                        ? FadeInNetworkImage(url: preview, headers: {'Referer': referer}, cacheWidth: 360, fallback: fallback)
                        : fallback,
                  ),
                  // Legible labels over any picture; unselected files dim a little.
                  AnimatedContainer(
                    duration: d,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          const Color(0x66000000),
                          Colors.black.withValues(alpha: selected ? 0 : 0.18),
                          Colors.black.withValues(alpha: selected ? 0 : 0.18),
                          const Color(0x99000000),
                        ],
                        stops: const [0, 0.32, 0.6, 1],
                      ),
                    ),
                  ),
                  if (item.kind == GalleryItemKind.video || item.kind == GalleryItemKind.audio)
                    Center(
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.4),
                        ),
                        child: Icon(
                          item.kind == GalleryItemKind.video ? Icons.play_arrow_rounded : Icons.graphic_eq_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  Positioned(left: 6, top: 6, right: 34, child: Align(alignment: Alignment.centerLeft, child: OverlayPill(text: badge, icon: _kindIcon(item.kind)))),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: AnimatedContainer(
                      duration: d,
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: selected ? AppColors.brandGradient : null,
                        color: selected ? null : Colors.black26,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: AnimatedScale(
                        scale: selected ? 1 : 0,
                        duration: d,
                        curve: springCurve,
                        child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
                      ),
                    ),
                  ),
                  if (footer.isNotEmpty)
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 6,
                      child: Text(
                        footer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
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

class _ChildrenList extends StatelessWidget {
  const _ChildrenList({required this.post, required this.onOpen});

  final GalleryPost post;
  final void Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final children = post.children.take(200).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PostHeader(post: post),
        const SizedBox(height: 14),
        Text(
          '${post.children.length}${post.children.length >= 200 ? '+' : ''} posts · open one to pick its files',
          style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (final (i, child) in children.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: EntranceMotion(
              index: i,
              step: const Duration(milliseconds: 30),
              offset: 10,
              child: PressableScale(
                scale: 0.98,
                child: Material(
                  color: scheme.surfaceContainerLowest.withValues(alpha: 0.75),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onOpen(child.url),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
                            child: Icon(Icons.photo_library_outlined, color: scheme.onPrimaryContainer, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  child.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                if (child.title != child.url)
                                  Text(
                                    child.url,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                              ],
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
      ],
    );
  }
}

/// A link both engines understood: the post's files, or yt-dlp's qualities.
class PostOrMediaSwitch extends StatefulWidget {
  const PostOrMediaSwitch({super.key, required this.post, required this.postView, required this.mediaView});

  final GalleryPost post;
  final Widget postView;
  final Widget mediaView;

  @override
  State<PostOrMediaSwitch> createState() => _PostOrMediaSwitchState();
}

class _PostOrMediaSwitchState extends State<PostOrMediaSwitch> {
  /// A single video opens on yt-dlp's qualities; anything else on the post.
  late bool _post = !(widget.post.items.length == 1 && widget.post.items.first.kind == GalleryItemKind.video);

  @override
  Widget build(BuildContext context) {
    final n = widget.post.items.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SlidingSegments<bool>(
              segments: [
                Segment(value: true, icon: Icons.photo_library_rounded, label: n == 1 ? 'Post · 1 file' : 'Post', count: n > 1 ? n : null),
                const Segment(value: false, icon: Icons.movie_rounded, label: 'Video'),
              ],
              selected: _post,
              onChanged: (v) => setState(() => _post = v),
            ),
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: homeDuration(context, const Duration(milliseconds: 280)),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(a), child: child),
          ),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
          child: KeyedSubtree(key: ValueKey(_post), child: _post ? widget.postView : widget.mediaView),
        ),
      ],
    );
  }
}
