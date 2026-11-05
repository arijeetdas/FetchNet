import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/device_environment.dart';
import '../../engine/engine.dart';
import '../../models/media_info.dart';
import '../../services/fetch_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../browser/browser_screen.dart';
import '../shell/home_shell.dart';
import 'engine_banner.dart';
import 'media_result_view.dart';

enum _Phase { idle, loading, error, result }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final AppServices _services;

  _Phase _phase = _Phase.idle;
  MediaInfo? _info;
  FetchException? _error;
  String? _lastUrl;
  List<String> _lastArgs = const [];
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    _services = AppScope.of(context);
    _services.incomingLink.addListener(_onIncomingLink);
    _controller.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _onIncomingLink());
  }

  @override
  void dispose() {
    _services.incomingLink.removeListener(_onIncomingLink);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onIncomingLink() {
    final text = _services.incomingLink.value;
    if (text == null) return;
    _services.incomingLink.value = null;
    final url = extractUrl(text);
    if (url == null) return;
    _controller.text = url;
    _fetch();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (mounted) showSnack(context, 'Your clipboard is empty');
      return;
    }
    _controller.text = extractUrl(text) ?? text;
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    _fetch();
  }

  String? _currentUrl() {
    final url = extractUrl(_controller.text);
    if (url == null) {
      showSnack(context, 'That doesn\'t look like a link', kind: ToastKind.error);
    }
    return url;
  }

  Future<void> _fetch({String? url, List<String> requestArgs = const []}) async {
    url ??= _currentUrl();
    if (url == null) return;
    _focus.unfocus();
    final token = ++_requestToken;
    setState(() {
      _phase = _Phase.loading;
      _error = null;
      _lastUrl = url;
      _lastArgs = requestArgs;
    });
    try {
      final info = await _services.fetcher.fetch(url, requestArgs: requestArgs);
      if (!mounted || token != _requestToken) return;
      setState(() {
        _info = info;
        _phase = _Phase.result;
      });
    } on FetchException catch (e) {
      if (!mounted || token != _requestToken) return;
      if (e.cancelled) {
        setState(() => _phase = _info == null ? _Phase.idle : _Phase.result);
        return;
      }
      setState(() {
        _error = e;
        _phase = _Phase.error;
      });
    }
  }

  void _cancelFetch() {
    _requestToken++;
    _services.fetcher.cancel();
    setState(() => _phase = _info == null ? _Phase.idle : _Phase.result);
  }

  void _clear() {
    _controller.clear();
    setState(() {
      _phase = _Phase.idle;
      _info = null;
      _error = null;
    });
  }

  Future<void> _openBrowserMode([String? url]) async {
    url ??= extractUrl(_controller.text);
    if (!BrowserScreen.isSupported) {
      await _useBrowserCookies(url);
      return;
    }
    final result = await Navigator.of(context)
        .push<BrowserGrab>(MaterialPageRoute(builder: (_) => BrowserScreen(initialUrl: url)));
    if (result == null || !mounted) return;
    _controller.text = result.pageUrl;
    await _fetch(url: result.mediaUrl, requestArgs: result.requestArgs);
    // Media URLs often have no title: use the page's. Audio picked in the
    // browser opens on the Audio tab.
    final info = _info;
    final usePageTitle = result.pageTitle != null && result.mediaUrl != result.pageUrl;
    if (info != null && _phase == _Phase.result && (usePageTitle || result.audio)) {
      setState(() {
        _info = MediaInfo(
          url: info.url,
          title: usePageTitle ? result.pageTitle! : info.title,
          raw: info.raw,
          thumbnail: info.thumbnail,
          uploader: info.uploader ?? Uri.tryParse(result.pageUrl)?.host,
          duration: info.duration,
          extractor: info.extractor,
          viewCount: info.viewCount,
          isLive: info.isLive,
          entries: info.entries,
          requestArgs: info.requestArgs,
          preferAudio: result.audio,
        );
      });
    }
  }

  /// Desktop fallback: let yt-dlp read cookies from an installed browser.
  Future<void> _useBrowserCookies(String? url) async {
    url ??= _lastUrl;
    if (url == null) return;
    const browsers = ['firefox', 'chrome', 'edge', 'brave', 'chromium', 'opera', 'vivaldi', 'safari'];
    final scheme = Theme.of(context).colorScheme;
    final picked = await showFetchNetDialog<String>(
      context: context,
      barrierDismissible: true,
      lockBack: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        icon: Icon(Icons.cookie_rounded, color: scheme.primary),
        title: const Text('Use your browser\'s sign-in'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                BrowserScreen.isSupported
                    ? 'FetchNet can reuse the cookies of a browser where you\'re already signed in to this site.'
                    : 'The built-in browser isn\'t available on ${DeviceEnvironment.platformDisplayName}. Instead, '
                          'FetchNet can reuse the cookies of a browser where you\'re signed in to this site.',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final b in browsers)
                    DialogButton(
                      label: b[0].toUpperCase() + b.substring(1),
                      icon: Icons.public_rounded,
                      onPressed: () => Navigator.pop(context, b),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          if (!BrowserScreen.isSupported && url != null)
            DialogButton(
              label: 'Open in browser',
              icon: Icons.open_in_new_rounded,
              onPressed: () => launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication),
            ),
          DialogButton(label: 'Cancel', icon: Icons.close_rounded, onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
    if (picked == null) return;
    await _fetch(url: url, requestArgs: ['--cookies-from-browser', picked]);
  }

  @override
  Widget build(BuildContext context) {
    final wide = Breakpoints.isWide(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final content = SafeArea(
      bottom: false,
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              wide ? 28 : 16,
              wide ? 28 : 12,
              wide ? 28 : 16,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            sliver: SliverConstrainedCrossAxis(
              maxExtent: 1080,
              sliver: SliverList.list(
                children: [
                  const _Hero(),
                  const SizedBox(height: 16),
                  const EngineBanner(),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: _LinkCard(
                        controller: _controller,
                        focusNode: _focus,
                        loading: _phase == _Phase.loading,
                        onFetch: () => _fetch(),
                        onPaste: _paste,
                        onClear: _clear,
                        onBrowser: () => _openBrowserMode(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: switch (_phase) {
                      _Phase.idle => const _IdleHints(key: ValueKey('idle')),
                      _Phase.loading => _LoadingCard(key: const ValueKey('loading'), onCancel: _cancelFetch),
                      _Phase.error => _ErrorCard(
                        key: const ValueKey('error'),
                        error: _error!,
                        onRetry: () => _fetch(url: _lastUrl, requestArgs: _lastArgs),
                        onBrowser: () => _openBrowserMode(_lastUrl),
                        onCookies: DeviceEnvironment.isDesktop ? () => _useBrowserCookies(_lastUrl) : null,
                      ),
                      _Phase.result =>
                        _info!.isPlaylist
                            ? _PlaylistView(
                                key: ValueKey('pl-${_info!.url}'),
                                info: _info!,
                                onPick: (entry) {
                                  _controller.text = entry.url;
                                  _fetch(url: entry.url, requestArgs: _info!.requestArgs);
                                },
                              )
                            : MediaResultView(key: ValueKey('res-${_info!.url}-${_info!.title}'), info: _info!),
                    },
                  ),
                  if (_phase == _Phase.result && !_info!.isPlaylist)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Center(
                        child: TextButton.icon(
                          onPressed: () => _openBrowserMode(_lastUrl),
                          icon: const Icon(Icons.travel_explore_rounded, size: 18),
                          label: const Text('Not the right media? Try Browser Mode'),
                          style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return wide ? content : AuroraBackground(intensity: 0.6, child: content);
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = Breakpoints.isWide(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Row(
        children: [
          if (!wide) ...[const FetchNetLogo(size: 72), const SizedBox(width: 16)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!wide)
                  GradientText(
                    'FetchNet',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.2,
                      height: 1.1,
                    ),
                  )
                else
                  Text('What do you want to save today?', style: theme.textTheme.headlineMedium),
                if (wide)
                  Text(
                    'Paste a link from YouTube or any of 1000+ supported sites.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  )
                else
                  // One line on every phone: shrinks only as much as a narrow
                  // screen needs instead of leaving "Done." on its own line.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Paste a link. Pick a quality. Done.',
                      maxLines: 1,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.controller,
    required this.focusNode,
    required this.loading,
    required this.onFetch,
    required this.onPaste,
    required this.onClear,
    required this.onBrowser,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool loading;
  final VoidCallback onFetch;
  final VoidCallback onPaste;
  final VoidCallback onClear;
  final VoidCallback onBrowser;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final services = AppScope.of(context);
    return ValueListenableBuilder<EngineStatus>(
      valueListenable: services.engine.status,
      builder: (context, status, _) {
        final canFetch = status.isReady && !loading && controller.text.trim().isNotEmpty;
        return Builder(
          builder: (context) {
            final field = TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => canFetch ? onFetch() : null,
              decoration: InputDecoration(
                hintText: 'Paste a video or audio link',
                prefixIcon: const Icon(Icons.link_rounded),
                suffixIcon: controller.text.isEmpty
                    ? IconButton(
                        tooltip: 'Paste',
                        icon: const Icon(Icons.content_paste_rounded),
                        onPressed: loading ? null : onPaste,
                      )
                    : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded), onPressed: onClear),
              ),
            );
            final fetch = GradientButton(
              label: 'Fetch',
              icon: Icons.bolt_rounded,
              loading: loading,
              expand: true,
              onPressed: canFetch ? onFetch : null,
            );
            final browser = OutlinedButton.icon(
              onPressed: loading ? null : onBrowser,
              icon: const Icon(Icons.travel_explore_rounded),
              label: const Text('Open in Browser Mode'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                side: BorderSide(color: scheme.primary.withValues(alpha: 0.35)),
              ),
            );
            return Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
                boxShadow: [
                  BoxShadow(color: scheme.primary.withValues(alpha: 0.06), blurRadius: 30, offset: const Offset(0, 12)),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [field, const SizedBox(height: 12), fetch, const SizedBox(height: 10), browser],
              ),
            );
          },
        );
      },
    );
  }
}

class _IdleHints extends StatelessWidget {
  const _IdleHints({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const tips = [
      (Icons.content_paste_go_rounded, 'Paste & fetch', 'Copy a link from any app and tap the paste icon.'),
      (Icons.tune_rounded, 'Choose a format', 'Video up to 4K, or MP3 / M4A audio.'),
      (Icons.travel_explore_rounded, 'Stuck?', 'Browser Mode finds media on pages that can\'t be read directly.'),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final columns = c.maxWidth >= 720 ? 3 : 1;
        final tiles = [
          for (final (icon, title, body) in tips)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(
                          body,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ];
        if (columns == 1) {
          return Column(
            children: [for (final t in tiles) Padding(padding: const EdgeInsets.only(bottom: 10), child: t)],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: tiles[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard({super.key, required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            const SizedBox(height: 6),
            const EnergyLoader(size: 64),
            const SizedBox(height: 18),
            Text('Reading the link…', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'yt-dlp is looking up the available formats. This can take a few seconds.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({super.key, required this.error, required this.onRetry, required this.onBrowser, this.onCookies});

  final FetchException error;
  final VoidCallback onRetry;
  final VoidCallback onBrowser;
  final VoidCallback? onCookies;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(14)),
                  child: Icon(Icons.search_off_rounded, color: scheme.onErrorContainer),
                ),
                const SizedBox(width: 14),
                Expanded(child: Text('Couldn\'t get this media', style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              error.hint ?? 'FetchNet couldn\'t read this link directly. Browser Mode lets you open the page, play the media, and grab it from there.',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
            const SizedBox(height: 10),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: Text('Details', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
                children: [
                  SelectableText(
                    error.message,
                    style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                GradientButton(label: 'Open in Browser Mode', icon: Icons.travel_explore_rounded, onPressed: onBrowser),
                if (onCookies != null)
                  OutlinedButton.icon(
                    onPressed: onCookies,
                    icon: const Icon(Icons.cookie_outlined),
                    label: const Text('Use browser sign-in'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 54)),
                  ),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 54)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistView extends StatelessWidget {
  const _PlaylistView({super.key, required this.info, required this.onPick});

  final MediaInfo info;
  final ValueChanged<PlaylistEntry> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(Icons.playlist_play_rounded, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.title,
                          style: theme.textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${info.entries.length} items · pick one to download',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (final (i, entry) in info.entries.take(200).indexed)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ),
                title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: entry.duration == null ? null : Text(formatDuration(entry.duration)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => onPick(entry),
              ),
          ],
        ),
      ),
    );
  }
}
