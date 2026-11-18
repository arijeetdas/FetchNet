import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../engine/engine.dart';
import '../../services/sites_service.dart';
import '../../widgets/brand.dart';
import '../../widgets/site_icon.dart';
import 'home_kit.dart';

/// The link field: paste and fetch.
///
/// While empty it cycles through examples of what FetchNet can read; once a
/// link is in, it shows which site it's from. The edge lights up while it has
/// focus and a gradient runs around it while a link is being read.
class LinkDock extends StatefulWidget {
  const LinkDock({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.loading,
    required this.onFetch,
    required this.onPaste,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool loading;
  final VoidCallback onFetch;
  final VoidCallback onPaste;
  final VoidCallback onClear;

  @override
  State<LinkDock> createState() => _LinkDockState();
}

class _LinkDockState extends State<LinkDock> with SingleTickerProviderStateMixin {
  static const _hints = [
    'Paste a YouTube video or Shorts link',
    'Paste an Instagram post or reel',
    'Paste a Reddit or X gallery',
    'Paste a SoundCloud or Bandcamp track',
    'Paste a Pinterest pin or Tumblr post',
    'Paste a link from 1000+ sites',
  ];

  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
  Timer? _hintTimer;
  int _hint = 0;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    _hintTimer = Timer.periodic(const Duration(milliseconds: 3200), (_) {
      if (!mounted || widget.controller.text.isNotEmpty || widget.focusNode.hasFocus) return;
      if (!homeMotion(context)) return;
      setState(() => _hint = (_hint + 1) % _hints.length);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSpin();
  }

  @override
  void didUpdateWidget(LinkDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
    _syncSpin();
  }

  void _syncSpin() {
    final run = widget.loading && homeMotion(context);
    if (run && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!run && _spin.isAnimating) {
      _spin.stop();
    }
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    widget.focusNode.removeListener(_onFocus);
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final services = AppScope.of(context);
    final focused = widget.focusNode.hasFocus;
    final text = widget.controller.text;
    final url = extractUrl(text);

    return ValueListenableBuilder<EngineStatus>(
      valueListenable: services.engine.status,
      builder: (context, status, _) {
        final canFetch = status.isReady && !widget.loading && text.trim().isNotEmpty;
        final waiting = !status.isReady && status.state != EngineState.error && status.state != EngineState.unsupported;

        final field = TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          enableSuggestions: false,
          style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          onSubmitted: (_) => canFetch ? widget.onFetch() : null,
          decoration: InputDecoration(
            hint: AnimatedSwitcher(
              duration: homeDuration(context, const Duration(milliseconds: 380)),
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.45), end: Offset.zero)
                      .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
              child: Text(
                _hints[_hint],
                key: ValueKey(_hint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.75)),
              ),
            ),
            prefixIcon: Icon(Icons.link_rounded, color: focused || text.isNotEmpty ? scheme.primary : null),
            suffixIcon: AnimatedSwitcher(
              duration: homeDuration(context, const Duration(milliseconds: 200)),
              transitionBuilder: (child, a) => RotationTransition(
                turns: Tween(begin: 0.75, end: 1.0).animate(a),
                child: FadeTransition(opacity: a, child: child),
              ),
              child: text.isEmpty
                  ? IconButton(
                      key: const ValueKey('paste'),
                      tooltip: 'Paste',
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: widget.loading ? null : widget.onPaste,
                    )
                  : IconButton(
                      key: const ValueKey('clear'),
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: widget.onClear,
                    ),
            ),
          ),
        );

        final detected = AnimatedSize(
          duration: homeDuration(context, const Duration(milliseconds: 300)),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: url == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: EntranceMotion(key: ValueKey(_hostOf(url)), offset: 8, child: _DetectedLink(url: url)),
                ),
        );

        final fetchLabel = widget.loading
            ? 'Reading the link…'
            : waiting
                ? 'Waiting for yt-dlp…'
                : 'Fetch';

        final actions = GradientButton(
          label: fetchLabel,
          icon: Icons.bolt_rounded,
          loading: widget.loading || (waiting && text.isNotEmpty),
          expand: true,
          onPressed: canFetch ? widget.onFetch : null,
        );

        final card = Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [field, detected, const SizedBox(height: 12), actions],
          ),
        );

        // The edge: a gradient ring that runs around while loading, glows
        // while focused, and stays a quiet outline otherwise.
        return AnimatedBuilder(
          animation: _spin,
          child: card,
          builder: (context, child) {
            final lit = widget.loading || focused;
            return AnimatedContainer(
              duration: homeDuration(context, const Duration(milliseconds: 300)),
              padding: EdgeInsets.all(lit ? 1.8 : 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                gradient: lit
                    ? SweepGradient(
                        transform: GradientRotation(_spin.value * 2 * math.pi),
                        colors: const [
                          AppColors.violet,
                          AppColors.orchid,
                          AppColors.lilac,
                          AppColors.violetBright,
                          AppColors.violet,
                        ],
                      )
                    : null,
                color: lit ? null : scheme.outlineVariant.withValues(alpha: 0.4),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: lit ? 0.22 : 0.07),
                    blurRadius: lit ? 36 : 28,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: child,
            );
          },
        );
      },
    );
  }
}

String _hostOf(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// The site a link points to, shown under the field.
class _DetectedLink extends StatelessWidget {
  const _DetectedLink({required this.url});

  final String url;

  static const _aliases = {
    'youtu.be': 'youtube.com',
    'music.youtube.com': 'youtube.com',
    'm.youtube.com': 'youtube.com',
    'twitter.com': 'x.com',
    'mobile.twitter.com': 'x.com',
    'fb.watch': 'facebook.com',
    'm.facebook.com': 'facebook.com',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final services = AppScope.of(context);
    var host = _hostOf(url);
    host = _aliases[host] ?? host;
    Site? site;
    for (final s in services.sites.all) {
      if (host == s.key || host.endsWith('.${s.key}')) {
        site = s;
        break;
      }
    }
    final youtube = site?.brand == SiteBrand.youtube;
    final path = Uri.tryParse(url)?.path ?? '';
    final what = youtube
        ? (path.contains('/playlist') ? 'Playlist' : path.contains('/shorts') ? 'Short' : 'Video')
        : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          if (site != null)
            SiteIcon(site: site, size: 28)
          else
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.public_rounded, size: 17, color: Colors.white),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              site?.name ?? host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurface),
            ),
          ),
          if (what != null) ...[const SizedBox(width: 8), GradientBadge(what)],
          const SizedBox(width: 8),
          Icon(Icons.check_circle_rounded, size: 18, color: scheme.primary),
        ],
      ),
    );
  }
}
