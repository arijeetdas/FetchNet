import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../services/web_session.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../home/sites_panel.dart';
import '../youtube/youtube_screen.dart';
import 'media_sniffer.dart';

/// What Browser Mode hands back to Home.
class BrowserGrab {
  const BrowserGrab({
    required this.pageUrl,
    required this.mediaUrl,
    required this.requestArgs,
    this.pageTitle,
    this.audio = false,
  });

  final String pageUrl;

  /// The URL to give yt-dlp: the page itself or a media stream found on it.
  final String mediaUrl;
  final String? pageTitle;

  /// Cookies / user agent / referer so yt-dlp sees what the browser sees.
  final List<String> requestArgs;

  /// The picked media was detected as audio-only.
  final bool audio;
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, this.initialUrl, this.youtubeHandoff = true});

  final String? initialUrl;

  /// Opening a youtube.com page switches to FetchNet's YouTube view.
  final bool youtubeHandoff;

  /// The in-app browser exists on Android, iOS, macOS, Windows and Linux (WPE WebKit).
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  static const _scanScript = '''
(function(){
  var out=[];
  try{if(!window.__fnBuf){performance.setResourceTimingBufferSize(3000);window.__fnBuf=1;}}catch(e){}
  try{document.querySelectorAll('video,audio,source').forEach(function(e){
    var s=e.currentSrc||e.src; if(!s||s.indexOf('blob:')===0||s.indexOf('data:')===0) return;
    var t=e.tagName.toLowerCase(); if(t==='source'&&e.parentElement) t=e.parentElement.tagName.toLowerCase();
    var ty=(e.getAttribute('type')||'').toLowerCase();
    if(ty.indexOf('video')===0) t='video'; if(ty.indexOf('audio')===0) t='audio';
    var m=t==='video'?(e.tagName.toLowerCase()==='video'?e:e.parentElement):null;
    if(m&&m.readyState>=1&&m.videoWidth===0) t='audio';
    out.push({u:s,h:t});
  });}catch(e){}
  try{performance.getEntriesByType('resource').forEach(function(r){out.push({u:r.name,h:r.initiatorType});});}catch(e){}
  return JSON.stringify(out);
})()
''';

  InAppWebViewController? _controller;
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  late final MediaSniffer _sniffer = MediaSniffer(onChanged: () {
    if (mounted) setState(() {});
  });
  Timer? _scanTimer;
  double _progress = 0;
  String _pageUrl = '';
  String? _pageTitle;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _grabbing = false;
  bool _desktop = false;
  bool _handingOff = false;

  /// Opened straight on a YouTube link: hand off without loading anything.
  late final bool _redirectOnly = widget.youtubeHandoff && isYouTubeUrl(widget.initialUrl);

  String get _startUrl => widget.initialUrl ?? 'https://www.google.com';

  /// Lets Android load everything except YouTube pages without a round trip
  /// to Dart (which would turn form posts into GETs).
  static const _notYouTube = r'(?i)^(?!https?://(www\.|m\.)?(youtube\.com|youtu\.be)([/?#:]|$)).*$';

  bool get _interceptsNavigation => widget.youtubeHandoff && !kIsWeb && Platform.isAndroid;

  InAppWebViewSettings _settings() => WebSession.baseSettings(desktop: _desktop)
    ..useOnLoadResource = true
    ..mediaPlaybackRequiresUserGesture = true
    ..supportMultipleWindows = false
    ..useShouldOverrideUrlLoading = _interceptsNavigation
    ..regexToAllowSyncUrlLoading = _interceptsNavigation ? _notYouTube : null;

  @override
  void initState() {
    super.initState();
    _pageUrl = _startUrl;
    _address.text = _startUrl;
    if (_redirectOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handOff(_startUrl));
      return;
    }
    _scanTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) => _scan());
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _address.dispose();
    _addressFocus.dispose();
    WebSession.flush();
    super.dispose();
  }

  /// Switches to FetchNet's YouTube view for [url]. A grabbed video is
  /// handed back to Home; otherwise the browser returns to where it was.
  Future<void> _handOff(String url) async {
    if (_handingOff) return;
    _handingOff = true;
    final link = parseYouTubeLink(url);
    final grab = await openYouTube(context, query: link.query, videoId: link.videoId);
    _handingOff = false;
    if (!mounted) return;
    if (grab != null || _redirectOnly) {
      Navigator.of(context).pop(grab);
      return;
    }
    final c = _controller;
    final current = (await c?.getUrl())?.toString();
    if (!mounted || c == null || !isYouTubeUrl(current)) return;
    if (await c.canGoBack()) {
      await c.goBack();
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _toggleDesktop() async {
    setState(() => _desktop = !_desktop);
    final c = _controller;
    if (c == null) return;
    await c.setSettings(settings: _settings());
    await c.reload();
  }

  Future<void> _pinSite() async {
    final host = Uri.tryParse(_pageUrl)?.host ?? '';
    showSnack(context, 'Checking ${host.isEmpty ? 'this site' : host} with yt-dlp…');
    final result = await AppScope.of(context).sites.pin(_pageUrl);
    if (mounted) showPinResult(context, result);
  }

  void _consider(String url, {String? hint}) {
    _sniffer.referer = _pageUrl;
    _sniffer.consider(url, hint: hint);
  }

  Future<void> _scan() async {
    final c = _controller;
    if (c == null || !mounted) return;
    try {
      final result = await c.evaluateJavascript(source: _scanScript);
      if (result is! String) return;
      if (_sniffer.userAgent == null) {
        final ua = await c.evaluateJavascript(source: 'navigator.userAgent');
        if (ua is String) _sniffer.userAgent = ua;
      }
      for (final e in (jsonDecode(result) as List)) {
        if (e is Map) {
          _consider('${e['u']}', hint: e['h']?.toString());
        } else {
          _consider(e.toString());
        }
      }
    } catch (_) {}
  }

  Future<void> _refreshNav() async {
    final c = _controller;
    if (c == null) return;
    final back = await c.canGoBack();
    final fwd = await c.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = fwd;
    });
  }

  void _go(String text) {
    final url = extractUrl(text) ??
        'https://www.google.com/search?q=${Uri.encodeQueryComponent(text.trim())}';
    _addressFocus.unfocus();
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _grab(String mediaUrl, {bool audio = false}) async {
    if (_grabbing) return;
    setState(() => _grabbing = true);
    final services = AppScope.of(context);
    try {
      final c = _controller;
      String? ua;
      if (c != null) {
        try {
          ua = (await c.evaluateJavascript(source: 'navigator.userAgent'))?.toString();
        } catch (_) {}
      }
      final cookies = await WebSession.exportCookies(
        {_pageUrl, mediaUrl}.toList(),
        await services.storage.workDir('cookies'),
      );
      final args = <String>[
        if (cookies != null) ...['--cookies', cookies],
        if (ua != null && ua.isNotEmpty) ...['--user-agent', ua],
        if (mediaUrl != _pageUrl) ...['--referer', _pageUrl],
      ];
      if (!mounted) return;
      Navigator.of(context).pop(BrowserGrab(
        pageUrl: _pageUrl,
        mediaUrl: mediaUrl,
        pageTitle: _pageTitle,
        requestArgs: args,
        audio: audio,
      ));
    } finally {
      if (mounted) setState(() => _grabbing = false);
    }
  }

  void _showMedia() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Media found on this page', style: theme.textTheme.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'Tap one to get its download options. Videos usually appear after you press play.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final (title, items) in [
                      ('Videos', _sniffer.found.values.where((m) => !m.isAudio).toList().reversed.toList()),
                      ('Audio', _sniffer.found.values.where((m) => m.isAudio).toList().reversed.toList()),
                    ])
                      if (items.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                          child: Text(
                            '$title · ${items.length}',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        for (final m in items)
                          ListTile(
                            leading: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                gradient: m.isAudio ? null : AppColors.brandGradient,
                                color: m.isAudio ? scheme.secondaryContainer : null,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                switch (m.kind) {
                                  SniffedKind.audio => Icons.music_note_rounded,
                                  SniffedKind.video => Icons.movie_rounded,
                                  _ => Icons.stream_rounded,
                                },
                                color: m.isAudio ? scheme.onSecondaryContainer : Colors.white,
                              ),
                            ),
                            title: Text(
                              [m.label, m.format, if (m.sizeBytes != null) formatBytes(m.sizeBytes)].join(' · '),
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text(_shortUrl(m.url), maxLines: 2, overflow: TextOverflow.ellipsis),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () {
                              Navigator.pop(context);
                              _grab(m.url, audio: m.isAudio);
                            },
                          ),
                      ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  String _shortUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final path = uri.path.length > 60 ? '…${uri.path.substring(uri.path.length - 60)}' : uri.path;
    return '${uri.host}$path';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_redirectOnly) {
      return const Scaffold(body: Center(child: EnergyLoader(size: 56)));
    }
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _controller?.goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: scheme.surfaceContainerLow,
          titleSpacing: 0,
          leading: IconButton.filledTonal(
            tooltip: 'Close Browser Mode',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: SizedBox(
              height: 44,
              child: TextField(
                controller: _address,
                focusNode: _addressFocus,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                autocorrect: false,
                onSubmitted: _go,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  prefixIcon: Icon(
                    _pageUrl.startsWith('https') ? Icons.lock_rounded : Icons.public_rounded,
                    size: 18,
                  ),
                  hintText: 'Search or enter address',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide(color: scheme.primary),
                  ),
                ),
              ),
            ),
          ),
          actions: [
            IconButton.filledTonal(
              tooltip: 'Back',
              onPressed: _canGoBack ? () => _controller?.goBack() : null,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            IconButton.filledTonal(
              tooltip: 'Forward',
              onPressed: _canGoForward ? () => _controller?.goForward() : null,
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert_rounded),
              style: IconButton.styleFrom(
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              onSelected: (v) {
                switch (v) {
                  case 'reload':
                    _controller?.reload();
                  case 'desktop':
                    _toggleDesktop();
                  case 'pin':
                    _pinSite();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'reload',
                  child: ListTile(
                    leading: Icon(Icons.refresh_rounded),
                    title: Text('Reload'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (WebSession.isMobile)
                  CheckedPopupMenuItem(value: 'desktop', checked: _desktop, child: const Text('Desktop view')),
                const PopupMenuItem(
                  value: 'pin',
                  child: ListTile(
                    leading: Icon(Icons.push_pin_outlined),
                    title: Text('Pin this site'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(5),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _progress < 1 ? 1 : 0,
              child: GradientProgressBar(value: _progress, height: 4, wavy: false),
            ),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: InAppWebView(
                webViewEnvironment: WebSession.environment,
                initialUrlRequest: URLRequest(url: WebUri(_startUrl)),
                initialSettings: _settings(),
                onWebViewCreated: (c) => _controller = c,
                shouldOverrideUrlLoading: (c, action) async {
                  final url = action.request.url?.toString();
                  if (action.isForMainFrame && widget.youtubeHandoff && isYouTubeUrl(url)) {
                    _handOff(url!);
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },
                onLoadStart: (c, url) {
                  if (url == null) return;
                  if (widget.youtubeHandoff && isYouTubeUrl(url.toString())) {
                    c.stopLoading();
                    _handOff(url.toString());
                    return;
                  }
                  // A new page: forget media found on the previous one.
                  if (url.toString() != _pageUrl) _sniffer.reset();
                  setState(() {
                    _pageUrl = url.toString();
                    if (!_addressFocus.hasFocus) _address.text = _pageUrl;
                  });
                },
                onLoadStop: (c, url) async {
                  final title = await c.getTitle();
                  if (!mounted) return;
                  setState(() => _pageTitle = (title?.trim().isEmpty ?? true) ? null : title!.trim());
                  _refreshNav();
                  _scan();
                },
                onUpdateVisitedHistory: (c, url, _) {
                  if (url == null) return;
                  setState(() {
                    _pageUrl = url.toString();
                    if (!_addressFocus.hasFocus) _address.text = _pageUrl;
                  });
                  _refreshNav();
                },
                onTitleChanged: (c, title) => setState(() => _pageTitle = title),
                onProgressChanged: (c, progress) => setState(() => _progress = progress / 100),
                onLoadResource: (c, resource) {
                  final u = resource.url?.toString();
                  if (u != null) _consider(u);
                },
              ),
            ),
            _GrabBar(
              mediaCount: _sniffer.found.length,
              grabbing: _grabbing,
              onGrabPage: () => _grab(_pageUrl),
              onShowMedia: _sniffer.found.isEmpty ? null : _showMedia,
            ),
          ],
        ),
      ),
    );
  }
}

class _GrabBar extends StatelessWidget {
  const _GrabBar({required this.mediaCount, required this.grabbing, required this.onGrabPage, this.onShowMedia});

  final int mediaCount;
  final bool grabbing;
  final VoidCallback onGrabPage;
  final VoidCallback? onShowMedia;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Row(
                children: [
                  Expanded(
                    child: GradientButton(
                      label: 'Grab this page',
                      icon: Icons.download_for_offline_rounded,
                      loading: grabbing,
                      expand: true,
                      height: 50,
                      onPressed: onGrabPage,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Badge(
                    isLabelVisible: mediaCount > 0,
                    label: Text('$mediaCount'),
                    child: OutlinedButton.icon(
                      onPressed: grabbing ? null : onShowMedia,
                      icon: const Icon(Icons.video_library_rounded),
                      label: const Text('Media found'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
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
