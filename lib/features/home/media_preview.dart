import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/brand.dart';
import '../downloads/file_actions_sheet.dart';
import '../../ui_kit/kit.dart';
import 'home_kit.dart';

/// One picture of a [showMediaPreview] viewer.
class PreviewItem {
  const PreviewItem({required this.url, this.filePath, this.caption, this.icon = Icons.image_rounded, this.heroTag});

  /// The picture shown from the web (a full image, a video's poster…).
  final String url;

  /// A downloaded picture on the device: shown from the file, and it can
  /// be shared.
  final String? filePath;

  /// Its name, shown at the top.
  final String? caption;

  /// Shown when the picture can't load.
  final IconData icon;
  final Object? heroTag;

  bool get isSaved => filePath != null;
}

/// Full-screen viewer: swipe (or use the arrows) between [items], pinch or
/// double-tap to zoom, tap to hide or show the controls. Saved pictures can
/// be shared. With [isSelected] and [onToggle] a select button sits at the
/// bottom, so files of a post can be picked while looking at them.
Future<void> showMediaPreview(
  BuildContext context, {
  required List<PreviewItem> items,
  int initial = 0,
  Map<String, String>? headers,
  bool Function(int index)? isSelected,
  void Function(int index)? onToggle,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      barrierDismissible: true,
      transitionDuration: homeDuration(context, const Duration(milliseconds: 280)),
      reverseTransitionDuration: homeDuration(context, const Duration(milliseconds: 220)),
      pageBuilder: (_, _, _) => _PreviewPage(
        items: items,
        initial: initial.clamp(0, items.length - 1),
        headers: headers,
        isSelected: isSelected,
        onToggle: onToggle,
      ),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    ),
  );
}

class _PreviewPage extends StatefulWidget {
  const _PreviewPage({required this.items, required this.initial, this.headers, this.isSelected, this.onToggle});

  final List<PreviewItem> items;
  final int initial;
  final Map<String, String>? headers;
  final bool Function(int index)? isSelected;
  final void Function(int index)? onToggle;

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  late final PageController _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  final _focus = FocusNode();

  /// The controls (header, arrows, thumbnails) are showing; a tap toggles.
  bool _chrome = true;

  /// Picture sizes once loaded, by index ("1920 × 1080").
  final Map<int, Size> _sizes = {};

  @override
  void dispose() {
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int delta) => _goTo(_index + delta);

  void _goTo(int index) {
    final next = index.clamp(0, widget.items.length - 1);
    if (next == _index) return;
    _pages.animateToPage(next, duration: homeDuration(context, const Duration(milliseconds: 320)), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.items[_index];
    final selectable = widget.isSelected != null && widget.onToggle != null;
    final selected = selectable && widget.isSelected!(_index);
    final many = widget.items.length > 1;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final size = _sizes[_index];
    final details = [
      if (many) '${_index + 1} of ${widget.items.length}',
      if (size != null) '${size.width.round()} × ${size.height.round()}',
      if (item.isSaved) 'Saved',
    ].join(' · ');
    final fade = homeDuration(context, const Duration(milliseconds: 200));

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pages,
                itemCount: widget.items.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _ZoomablePicture(
                  item: widget.items[i],
                  headers: widget.headers,
                  onTap: () => setState(() => _chrome = !_chrome),
                  onSize: (s) {
                    if (mounted && _sizes[i] != s) setState(() => _sizes[i] = s);
                  },
                ),
              ),
              // Header: name, details, share (saved pictures) and close.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: IgnorePointer(
                  ignoring: !_chrome,
                  child: AnimatedOpacity(
                    opacity: _chrome ? 1 : 0,
                    duration: fade,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
                        ),
                      ),
                      child: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 10, 10, 26),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Icon(item.icon, color: Colors.white, size: 22),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      item.caption ?? (item.isSaved ? 'Picture' : 'Preview'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                                    ),
                                    if (details.isNotEmpty)
                                      Text(
                                        details,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelMedium?.copyWith(color: Colors.white70),
                                      ),
                                  ],
                                ),
                              ),
                              if (item.isSaved) ...[
                                _BarButton(
                                  tooltip: 'Open with',
                                  icon: Icons.open_in_new_rounded,
                                  onPressed: () => openWithApp(context, item.filePath!),
                                ),
                                const SizedBox(width: 6),
                                _BarButton(
                                  tooltip: 'Share',
                                  icon: Icons.share_rounded,
                                  onPressed: () => shareFilePath(context, item.filePath!, title: item.caption),
                                ),
                              ],
                              const SizedBox(width: 6),
                              _BarButton(
                                tooltip: 'Close',
                                icon: Icons.close_rounded,
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Arrows on wide screens, where swiping isn't natural.
              if (many && wide && _chrome) ...[
                Positioned(
                  left: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(child: _NavButton(icon: Icons.chevron_left_rounded, onTap: _index > 0 ? () => _go(-1) : null)),
                ),
                Positioned(
                  right: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _NavButton(
                      icon: Icons.chevron_right_rounded,
                      onTap: _index < widget.items.length - 1 ? () => _go(1) : null,
                    ),
                  ),
                ),
              ],
              // Bottom: thumbnails of every picture, and the select button.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: !_chrome,
                  child: AnimatedOpacity(
                    opacity: _chrome ? 1 : 0,
                    duration: fade,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (many)
                              _ThumbStrip(
                                items: widget.items,
                                index: _index,
                                headers: widget.headers,
                                onTap: _goTo,
                              ),
                            if (selectable)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 360),
                                  child: AnimatedSwitcher(
                                    duration: fade,
                                    transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                                    child: selected
                                        ? GradientButton(
                                            key: const ValueKey('on'),
                                            label: 'Selected',
                                            icon: Icons.check_circle_rounded,
                                            expand: true,
                                            onPressed: () => setState(() => widget.onToggle!(_index)),
                                          )
                                        : OutlinedButton.icon(
                                            key: const ValueKey('off'),
                                            onPressed: () => setState(() => widget.onToggle!(_index)),
                                            icon: const Icon(Icons.radio_button_unchecked_rounded, color: Colors.white),
                                            label: const Text('Select this file', style: TextStyle(color: Colors.white)),
                                            style: OutlinedButton.styleFrom(
                                              minimumSize: const Size(double.infinity, 54),
                                              side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
                                              backgroundColor: Colors.black.withValues(alpha: 0.35),
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
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

class _BarButton extends StatelessWidget {
  const _BarButton({required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return KitFloatingButton(
      tooltip: tooltip,
      backgroundColor: Colors.white.withValues(alpha: 0.14),
      color: Colors.white,
      onPressed: onPressed,
      icon: icon,
    );
  }
}

/// Small pictures of every item; the current one is outlined.
class _ThumbStrip extends StatefulWidget {
  const _ThumbStrip({required this.items, required this.index, required this.headers, required this.onTap});

  final List<PreviewItem> items;
  final int index;
  final Map<String, String>? headers;
  final ValueChanged<int> onTap;

  @override
  State<_ThumbStrip> createState() => _ThumbStripState();
}

class _ThumbStripState extends State<_ThumbStrip> {
  final _scroll = ScrollController();
  static const _size = 54.0;
  static const _gap = 8.0;

  @override
  void didUpdateWidget(_ThumbStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index && _scroll.hasClients) {
      // Keeps the current picture in view.
      final target = (widget.index * (_size + _gap)) - (_scroll.position.viewportDimension - _size) / 2;
      _scroll.animateTo(
        target.clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _size + 6,
      child: Center(
        child: ListView.separated(
          controller: _scroll,
          shrinkWrap: true,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: widget.items.length,
          separatorBuilder: (_, _) => const SizedBox(width: _gap),
          itemBuilder: (context, i) {
            final item = widget.items[i];
            final current = i == widget.index;
            return GestureDetector(
              onTap: () => widget.onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: _size,
                height: _size,
                margin: const EdgeInsets.symmetric(vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: current ? Colors.white : Colors.white24, width: current ? 2.5 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: Opacity(
                  opacity: current ? 1 : 0.6,
                  child: _picture(item, headers: widget.headers, cacheWidth: 160, fit: BoxFit.cover),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The picture of [item]: from its file when saved, otherwise from the web.
Widget _picture(PreviewItem item, {Map<String, String>? headers, int? cacheWidth, BoxFit fit = BoxFit.contain}) {
  Widget fallback(BuildContext _, Object _, StackTrace? _) => Center(child: Icon(item.icon, size: 28, color: Colors.white54));
  if (item.filePath != null) {
    return Image.file(File(item.filePath!), fit: fit, cacheWidth: cacheWidth, errorBuilder: fallback);
  }
  if (item.url.isEmpty) return Center(child: Icon(item.icon, size: 28, color: Colors.white54));
  return Image.network(item.url, headers: headers, fit: fit, cacheWidth: cacheWidth, errorBuilder: fallback);
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: onTap == null ? 0.25 : 1,
      duration: const Duration(milliseconds: 160),
      child: KitFloatingButton(
        iconSize: 30,
        backgroundColor: Colors.white.withValues(alpha: 0.14),
        color: Colors.white,
        onPressed: onTap,
        icon: icon,
      ),
    );
  }
}

/// One page: pinch to zoom, double-tap to zoom in / reset, tap for the
/// controls.
class _ZoomablePicture extends StatefulWidget {
  const _ZoomablePicture({required this.item, this.headers, required this.onTap, required this.onSize});

  final PreviewItem item;
  final Map<String, String>? headers;
  final VoidCallback onTap;

  /// The picture's size, once known.
  final ValueChanged<Size> onSize;

  @override
  State<_ZoomablePicture> createState() => _ZoomablePictureState();
}

class _ZoomablePictureState extends State<_ZoomablePicture> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoom = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))
    ..addListener(() {
      final a = _zoomAnim;
      if (a != null) _transform.value = a.value;
    });
  Animation<Matrix4>? _zoomAnim;
  TapDownDetails? _tap;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  ImageProvider? get _provider {
    final item = widget.item;
    if (item.filePath != null) return FileImage(File(item.filePath!));
    if (item.url.isEmpty) return null;
    return NetworkImage(item.url, headers: widget.headers);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reads the picture's size for the header.
    final provider = _provider;
    if (provider == null || _stream != null) return;
    _stream = provider.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener((info, _) {
      widget.onSize(Size(info.image.width.toDouble(), info.image.height.toDouble()));
    }, onError: (_, _) {});
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _zoom.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.05;
    final Matrix4 end;
    if (zoomed) {
      end = Matrix4.identity();
    } else {
      final p = _tap?.localPosition ?? Offset.zero;
      const s = 2.5;
      end = Matrix4.identity()
        ..translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
    _zoomAnim = Matrix4Tween(begin: _transform.value, end: end)
        .animate(CurvedAnimation(parent: _zoom, curve: Curves.easeOutCubic));
    _zoom
      ..duration = homeDuration(context, const Duration(milliseconds: 260))
      ..forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (item.url.isEmpty && item.filePath == null) {
      return GestureDetector(
        onTap: widget.onTap,
        child: Center(child: Icon(item.icon, size: 64, color: Colors.white54)),
      );
    }
    Widget picture = item.filePath != null
        ? Image.file(
            File(item.filePath!),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Center(child: Icon(item.icon, size: 64, color: Colors.white54)),
          )
        : Image.network(
            item.url,
            headers: widget.headers,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const Center(child: EnergyLoader(size: 44, onColor: true)),
            errorBuilder: (_, _, _) => Center(child: Icon(item.icon, size: 64, color: Colors.white54)),
          );
    if (item.heroTag != null) picture = Hero(tag: item.heroTag!, child: picture);
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tap = d,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 5,
        child: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(vertical: 72), child: Center(child: picture))),
      ),
    );
  }
}
