import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/app_services.dart';
import '../../services/web_session.dart';
import '../../services/youtube_service.dart';
import '../../widgets/brand.dart';

/// Google's own sign-in page in the built-in browser. Closes by itself with
/// `true` once Google hands back to YouTube with a signed-in session.
class GoogleSignInScreen extends StatefulWidget {
  const GoogleSignInScreen({super.key});

  @override
  State<GoogleSignInScreen> createState() => _GoogleSignInScreenState();
}

class _GoogleSignInScreenState extends State<GoogleSignInScreen> {
  InAppWebViewController? _controller;
  double _progress = 0;
  String _host = 'accounts.google.com';
  bool _canGoBack = false;
  bool _done = false;

  Future<void> _check(WebUri? url) async {
    if (url == null || _done) return;
    if (mounted) setState(() => _host = url.host);
    final c = _controller;
    if (c != null) {
      final back = await c.canGoBack();
      if (mounted) setState(() => _canGoBack = back);
    }
    if (!isYouTubeHost(url.host)) return;
    if (!await YouTubeService.hasSession() || _done || !mounted) return;
    _done = true;
    unawaited(AppScope.of(context).youtube.completeSignIn());
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _controller?.goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: scheme.surfaceContainerLow,
          leading: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sign in with Google'),
              Row(
                children: [
                  Icon(Icons.lock_rounded, size: 13, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _host,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(5),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _progress < 1 ? 1 : 0,
              child: GradientProgressBar(value: _progress, height: 4, wavy: false),
            ),
          ),
        ),
        body: InAppWebView(
          webViewEnvironment: WebSession.environment,
          initialUrlRequest: URLRequest(url: WebUri(YouTubeService.signInUrl)),
          initialSettings: WebSession.baseSettings()..supportMultipleWindows = false,
          onWebViewCreated: (c) => _controller = c,
          onLoadStop: (c, url) => _check(url),
          onUpdateVisitedHistory: (c, url, _) => _check(url),
          onProgressChanged: (c, p) => setState(() => _progress = p / 100),
        ),
      ),
    );
  }
}
