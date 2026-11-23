import 'package:flutter/material.dart';

import '../ui_kit/kit.dart';
import 'brand.dart';

/// A page opened from another (Creator Settings, Engines, YouTube
/// Settings): the content scrolls under a floating header, as in today's
/// design languages. The back button stays, in a soft blur; the title is
/// there at the top and gives way once the page scrolls.
///
/// [body] is laid out under the header: [MediaQuery.paddingOf]'s top is
/// where it should start (status bar + header), for its scroll view's
/// padding.
class SubPageScaffold extends StatefulWidget {
  const SubPageScaffold({super.key, required this.title, required this.body, this.background = true, this.actions = const []});

  final String title;
  final Widget body;

  /// FetchNet's aurora behind the page (phones).
  final bool background;

  /// Buttons at the header's end.
  final List<Widget> actions;

  /// The header's height (below the status bar).
  static const headerHeight = 64.0;

  @override
  State<SubPageScaffold> createState() => _SubPageScaffoldState();
}

class _SubPageScaffoldState extends State<SubPageScaffold> {
  bool _scrolled = false;

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      final scrolled = n.metrics.pixels > 8;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final content = MediaQuery(
      data: media.copyWith(padding: media.padding.copyWith(top: media.padding.top + SubPageScaffold.headerHeight)),
      child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.body),
    );
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: widget.background ? AuroraBackground(intensity: 0.5, child: content) : content),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: SubPageScaffold.headerHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      const KitBackButton(halo: true),
                      const SizedBox(width: 14),
                      Expanded(
                        child: IgnorePointer(
                          ignoring: _scrolled,
                          child: AnimatedOpacity(
                            opacity: _scrolled ? 0 : 1,
                            duration: const Duration(milliseconds: 180),
                            child: AnimatedSlide(
                              offset: _scrolled ? const Offset(0, -0.3) : Offset.zero,
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              child: Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                        ),
                      ),
                      for (final a in widget.actions) ...[const SizedBox(width: 8), a],
                    ],
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
