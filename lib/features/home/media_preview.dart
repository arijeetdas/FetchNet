import 'package:flutter/material.dart';

import '../../widgets/brand.dart';
import 'home_kit.dart';

/// One picture of a [showMediaPreview] viewer.
class PreviewItem {
  const PreviewItem({required this.url, this.caption, this.icon = Icons.image_rounded, this.heroTag});

  /// The picture shown (a full image, a video's poster…).
  final String url;
  final String? caption;

  /// Shown when the picture can't load.
  final IconData icon;
  final Object? heroTag;
}

/// Full-screen viewer: swipe between [items], pinch or double-tap to zoom.
/// With [isSelected] and [onToggle] a select button sits at the bottom, so
/// files of a post can be picked while looking at them.
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
      barrierColor: Colors.black.withValues(alpha: 0.92),
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

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.items.length - 1);
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

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _ZoomablePicture(item: widget.items[i], headers: widget.headers),
          ),
          // Top bar: counter, caption, close.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    if (many) OverlayPill(text: '${_index + 1} / ${widget.items.length}'),
                    if (item.caption != null) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.caption!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    IconButton.filledTonal(
                      tooltip: 'Close',
                      style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.14)),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Arrows on wide screens, where swiping isn't natural.
          if (many && wide) ...[
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
          if (selectable)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: AnimatedSwitcher(
                        duration: homeDuration(context, const Duration(milliseconds: 220)),
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
                ),
              ),
            ),
        ],
      ),
    );
  }
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
      child: IconButton.filledTonal(
        iconSize: 30,
        style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.14)),
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }
}

/// One page: pinch to zoom, double-tap to zoom in / reset.
class _ZoomablePicture extends StatefulWidget {
  const _ZoomablePicture({required this.item, this.headers});

  final PreviewItem item;
  final Map<String, String>? headers;

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

  @override
  void dispose() {
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
    if (item.url.isEmpty) return Center(child: Icon(item.icon, size: 64, color: Colors.white54));
    Widget picture = Image.network(
      item.url,
      headers: widget.headers,
      fit: BoxFit.contain,
      loadingBuilder: (context, child, progress) => progress == null ? child : const Center(child: EnergyLoader(size: 44, onColor: true)),
      errorBuilder: (_, _, _) => Center(child: Icon(item.icon, size: 64, color: Colors.white54)),
    );
    if (item.heroTag != null) picture = Hero(tag: item.heroTag!, child: picture);
    return GestureDetector(
      onDoubleTapDown: (d) => _tap = d,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 5,
        child: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(vertical: 56), child: Center(child: picture))),
      ),
    );
  }
}
