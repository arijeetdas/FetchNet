import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../engine/engine.dart';
import '../../models/gallery_models.dart';
import '../../models/media_info.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import 'rename_dialog.dart';

/// Every file of a post (gallery-dl): filter by type, pick files, download
/// them together. A profile / board link lists its posts instead.
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

  List<GalleryItem> get _visible =>
      widget.post.items.where((i) => _filter == null || i.kind == _filter).toList();

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
      single == null ? 'Downloading ${items.length} files into "$name"' : 'Downloading $name.${single.extension}',
      kind: ToastKind.success,
      actionLabel: 'View',
      onAction: () {
        navigator.popUntil((r) => r.isFirst);
        services.tabRequest.value = 1;
      },
    );
    widget.onQueued?.call();
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final body = post.items.isEmpty ? _ChildrenList(post: post, onOpen: widget.onOpenChild) : _buildFiles(context);
    if (!widget.framed) return body;
    return Card(clipBehavior: Clip.antiAlias, child: Padding(padding: const EdgeInsets.all(16), child: body));
  }

  Widget _buildFiles(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final services = AppScope.of(context);
    final post = widget.post;
    final visible = _visible;
    final allVisibleSelected = visible.isNotEmpty && visible.every((i) => _selected.contains(i.index));
    final kinds = [for (final k in GalleryItemKind.values) if (post.count(k) > 0) k];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PostHeader(post: post),
        const SizedBox(height: 14),
        if (kinds.length > 1 || post.truncated)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (kinds.length > 1)
                ChoiceChip(
                  label: Text('All ${post.items.length}${post.truncated ? '+' : ''}'),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
              if (kinds.length > 1)
                for (final k in kinds)
                  ChoiceChip(
                    avatar: Icon(_kindIcon(k), size: 18),
                    label: Text('${_kindLabel(k, plural: post.count(k) != 1)} ${post.count(k)}'),
                    selected: _filter == k,
                    onSelected: (_) => setState(() => _filter = _filter == k ? null : k),
                  ),
              if (post.truncated)
                Chip(
                  avatar: Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
                  label: Text('Showing the first ${post.items.length} files'),
                ),
            ],
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                '${_selected.length} of ${post.items.length} selected',
                style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
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
              label: Text(allVisibleSelected ? 'Select none' : 'Select all'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, c) {
          final columns = (c.maxWidth / 150).floor().clamp(2, 6);
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
              return _FileTile(
                item: item,
                referer: post.url,
                selected: _selected.contains(item.index),
                onTap: () => setState(() {
                  if (!_selected.remove(item.index)) _selected.add(item.index);
                }),
              );
            },
          );
        }),
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
                      : _selected.length == 1
                          ? 'Download 1 file'
                          : 'Download ${_selected.length} files',
                  icon: Icons.download_rounded,
                  expand: true,
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
    final meta = [?post.author, if (post.items.isNotEmpty) _summary(post.items)].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(15)),
          child: const Icon(Icons.photo_library_rounded, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(post.title, style: theme.textTheme.titleLarge, maxLines: 3, overflow: TextOverflow.ellipsis),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(meta, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ],
              if (post.site != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(999)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.public_rounded, size: 14, color: scheme.onSecondaryContainer),
                      const SizedBox(width: 6),
                      Text(
                        post.site!,
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.item, required this.referer, required this.selected, required this.onTap});

  final GalleryItem item;
  final String referer;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dims = item.width != null && item.height != null ? '${item.width}×${item.height}' : null;
    final badge = [
      switch (item.kind) {
        GalleryItemKind.image => item.extension == 'gif' ? 'GIF' : 'IMAGE',
        GalleryItemKind.video => 'VIDEO',
        GalleryItemKind.audio => 'AUDIO',
        GalleryItemKind.other => item.extension.toUpperCase(),
      },
      if (item.duration != null && item.duration! > 0) formatDuration(item.duration),
    ].join(' · ');
    final footer = [?dims, if (item.sizeBytes != null) formatBytes(item.sizeBytes)].join(' · ');
    final preview = item.preview;
    return Semantics(
      selected: selected,
      button: true,
      label: '${_kindLabel(item.kind)} ${item.index}',
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (preview != null)
                Image.network(
                  preview,
                  headers: {'Referer': referer},
                  fit: BoxFit.cover,
                  cacheWidth: 360,
                  errorBuilder: (_, _, _) => Icon(_kindIcon(item.kind), size: 36, color: scheme.onSurfaceVariant),
                )
              else
                Icon(_kindIcon(item.kind), size: 36, color: scheme.onSurfaceVariant),
              // Legible labels over any picture.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x66000000), Color(0x00000000), Color(0x00000000), Color(0x8C000000)],
                    stops: [0, 0.3, 0.6, 1],
                  ),
                ),
              ),
              Positioned(
                left: 8,
                top: 8,
                right: 36,
                child: Row(
                  children: [
                    Icon(_kindIcon(item.kind), size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        badge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 6,
                top: 6,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? scheme.primary : Colors.black26,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: selected ? Icon(Icons.check_rounded, size: 16, color: scheme.onPrimary) : null,
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
                    style: theme.textTheme.labelSmall?.copyWith(color: Colors.white),
                  ),
                ),
              if (selected)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.primary, width: 3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
            ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PostHeader(post: post),
        const SizedBox(height: 12),
        Text(
          '${post.children.length}${post.children.length >= 200 ? '+' : ''} posts. Open one to pick its files.',
          style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        for (final child in post.children.take(200))
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(child.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: child.title == child.url
                ? null
                : Text(child.url, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => onOpen(child.url),
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
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: true,
                icon: const Icon(Icons.photo_library_rounded),
                label: Text(n == 0 ? 'Post' : 'Post · $n ${n == 1 ? 'file' : 'files'}'),
              ),
              const ButtonSegment(value: false, icon: Icon(Icons.movie_rounded), label: Text('Video')),
            ],
            selected: {_post},
            onSelectionChanged: (s) => setState(() => _post = s.first),
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(key: ValueKey(_post), child: _post ? widget.postView : widget.mediaView),
        ),
      ],
    );
  }
}
