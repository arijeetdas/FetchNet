import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../services/download_manager.dart';
import '../services/fetch_service.dart';
import '../services/history_store.dart';
import '../services/sites_service.dart';
import '../services/storage_service.dart';
import '../services/update_service.dart';
import '../services/web_session.dart';
import '../services/youtube_client.dart';
import '../services/youtube_service.dart';
import 'app_prefs.dart';
import 'platform/native_bridge.dart';

/// Everything the UI needs, created once in `main`.
class AppServices {
  AppServices._({
    required this.prefs,
    required this.engine,
    required this.storage,
    required this.history,
    required this.downloads,
    required this.fetcher,
    required this.youtube,
    required this.sites,
  })  : themeMode = ValueNotifier(prefs.themeMode),
        showAnimations = ValueNotifier(prefs.showAnimations);

  factory AppServices.create(AppPrefs prefs) {
    final engine = YtDlpEngine.create(prefs);
    final storage = StorageService();
    final history = HistoryStore(prefs);
    final youtube = YouTubeService(prefs, YouTubeClient());

    // The browser's cookies for a link, offered to yt-dlp when an anonymous
    // fetch fails. YouTube only when the user signed in with Google.
    Future<List<String>> cookieArgs(String url) async {
      if (!WebSession.isSupported) return const [];
      if (isYouTubeUrl(url) && !youtube.signedIn) return const [];
      return WebSession.cookieArgs(url, await storage.workDir('cookies'));
    }

    return AppServices._(
      prefs: prefs,
      engine: engine,
      storage: storage,
      history: history,
      downloads: DownloadManager(engine: engine, storage: storage, history: history),
      fetcher: FetchService(engine, cookieArgs: cookieArgs),
      youtube: youtube,
      sites: SitesService(prefs, engine),
    );
  }

  final AppPrefs prefs;
  final YtDlpEngine engine;
  final StorageService storage;
  final HistoryStore history;
  final DownloadManager downloads;
  final FetchService fetcher;
  final YouTubeService youtube;
  final SitesService sites;
  final UpdateService updates = UpdateService();
  final ValueNotifier<ThemeMode> themeMode;

  /// Settings → Show animations: the animated page icons play, or stay still.
  final ValueNotifier<bool> showAnimations;

  /// Links shared into the app (Android share sheet). The home screen
  /// consumes them.
  final ValueNotifier<String?> incomingLink = ValueNotifier(null);

  /// Lets any screen switch the main tab (0 = Home, 1 = Downloads, ...).
  final ValueNotifier<int> tabRequest = ValueNotifier(0);

  bool _started = false;

  /// Starts background work once the user is past onboarding.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    unawaited(storage.ensureDownloadDir(requestPermission: true));
    unawaited(engine.initialize());
    unawaited(youtube.refresh());
    unawaited(updates.check());

    final initial = await NativeBridge.consumeSharedText();
    if (initial != null) incomingLink.value = initial;
    NativeBridge.sharedTextStream().listen((text) {
      incomingLink.value = text;
      tabRequest.value = 0;
    });

    // Download notifications: Cancel, or tap to open the Downloads tab.
    if (await NativeBridge.consumeLaunchAction() == 'open_downloads') tabRequest.value = 1;
    NativeBridge.notificationActions().listen((event) {
      switch (event['action']) {
        case 'cancel':
          final id = event['id'];
          if (id != null) downloads.cancelById(id);
        case 'open_downloads':
          tabRequest.value = 1;
      }
    });
  }

  Future<void> setShowAnimations(bool value) async {
    showAnimations.value = value;
    await prefs.setShowAnimations(value);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await prefs.setThemeMode(mode);
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
