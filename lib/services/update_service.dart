import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform/device_environment.dart';
import '../models/changelog.dart';

/// A FetchNet version: `version: <versionName>+<buildNumber>` in pubspec.yaml.
@immutable
class AppRelease {
  const AppRelease({required this.versionName, required this.buildNumber});

  final String versionName;
  final int buildNumber;

  @override
  String toString() => '$versionName+$buildNumber';
}

/// `ahead`: the installed build is newer than the latest public one (an
/// unreleased or modified build).
enum UpdateState { idle, checking, upToDate, available, ahead, failed, offline }

/// The latest release of this platform, from the website's
/// `/update-manifest.json`: its version, notes and download links.
@immutable
class PlatformUpdate {
  const PlatformUpdate({required this.release, required this.downloads, this.notes});

  final AppRelease release;

  /// That version's release notes (`null` when the site has none).
  final ChangelogRelease? notes;

  /// Android: `universal`, `arm64-v8a`, `armeabi-v7a`, `x86_64`.
  /// Windows: `zip`, `installer`. Values are direct download links.
  final Map<String, String> downloads;

  static PlatformUpdate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['versionName'];
    final build = raw['buildNo'];
    if (name is! String || build is! num) return null;
    final downloads = <String, String>{};
    final d = raw['downloads'];
    if (d is Map) {
      for (final e in d.entries) {
        final url = e.value is Map ? (e.value as Map)['url'] : null;
        if (url is String && url.startsWith('https://')) downloads['${e.key}'] = url;
      }
    }
    return PlatformUpdate(
      release: AppRelease(versionName: name, buildNumber: build.toInt()),
      notes: ChangelogRelease.fromJson(raw['notes']),
      downloads: downloads,
    );
  }
}

/// Checks fetchnet.arijeet.in for a newer release of this platform, and
/// builds the "Check for Updates" link of the website.
class UpdateService extends ChangeNotifier {
  static const site = 'https://fetchnet.arijeet.in';

  /// Latest version, download links and notes per platform (built by the
  /// website from `releases.json`, `downloadLinks.ts` and `changelog.json`).
  static const updateManifestUrl = '$site/update-manifest.json';

  /// Every release's notes (`changelog.json`), for What's new.
  static const changelogUrl = '$site/changelog.json';

  /// Latest release per platform only. Older FetchNet versions read it; this
  /// one falls back to it when the update manifest can't be read.
  static const manifestUrl = '$site/releases.json';

  /// Android builds published on the website (universal + split per ABI).
  static const _publishedAbis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'};

  UpdateState _state = UpdateState.idle;
  AppRelease? _installed;
  AppRelease? _latest;
  PlatformUpdate? _update;
  Future<AppRelease?>? _installedLoad;
  Future<UpdateState>? _checking;

  UpdateState get state => _state;
  bool get updateAvailable => _state == UpdateState.available;

  /// The installed build is newer than the latest public one.
  bool get isUnreleasedBuild => _state == UpdateState.ahead;

  /// Newest public release for this platform, once checked.
  AppRelease? get latest => _latest;
  AppRelease? get installed => _installed;

  /// The latest release's notes and download links (`null` when only the
  /// old releases.json could be read).
  PlatformUpdate? get update => _update;

  /// `android`, `windows`, `macos`, `linux`, `ios`, or `null` (web).
  static String? get platformSlug {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isIOS) return 'ios';
    return null;
  }

  /// Android build that suits this device best, as named on the website:
  /// the device's preferred ABI when FetchNet publishes a build for it,
  /// otherwise `universal` (same rule as DropNet).
  static String recommendedAndroidInstallType() => recommendedInstallTypeFor(DeviceEnvironment.supportedAbis);

  /// Also used by the "FetchNet for Android" popup, so both always agree.
  static String recommendedInstallTypeFor(List<String> abis) {
    final preferred = abis.map((e) => e.trim()).where((e) => e.isNotEmpty).firstOrNull;
    return preferred != null && _publishedAbis.contains(preferred) ? preferred : 'universal';
  }

  /// Which APK the in-app updater downloads.
  ///
  /// Android only installs an APK whose version code is higher than the
  /// installed one, and split-per-ABI builds have inflated codes (ABI × 1000
  /// + build: armeabi-v7a 1, arm64-v8a 2, x86_64 4) while universal is just
  /// the build. So the update is the same kind of APK as the installed one;
  /// only a universal install may move up to the device's recommended split
  /// (always a higher code). The website link keeps the recommended ABI.
  static String androidDownloadKey({
    required String installedType,
    required List<String> abis,
    required Iterable<String> available,
  }) {
    final type = installedType.trim().toLowerCase();
    if (_publishedAbis.contains(type)) return type;
    final recommended = recommendedInstallTypeFor(abis);
    return available.contains(recommended) ? recommended : 'universal';
  }

  /// The installed version, straight from pubspec.yaml: Gradle records it on
  /// Android, the desktop runners embed it in the executable.
  Future<AppRelease?> installedRelease() => _installedLoad ??= _loadInstalled();

  Future<AppRelease?> _loadInstalled() async {
    await DeviceEnvironment.ensureLoaded();
    PackageInfo? info;
    try {
      info = await PackageInfo.fromPlatform();
    } catch (_) {}
    final name = DeviceEnvironment.pubspecVersionName ?? info?.version;
    var build = DeviceEnvironment.pubspecBuildNumber;
    if (build == null) {
      final raw = int.tryParse(info?.buildNumber ?? '');
      // Older Android builds without the Gradle record: undo the split-per-ABI
      // version code (abiCode * 1000 + build).
      build = raw == null ? null : (DeviceEnvironment.isAndroid && raw >= 1000 ? raw % 1000 : raw);
    }
    if (name == null || name.isEmpty || build == null) return null;
    return _installed = AppRelease(versionName: name, buildNumber: build);
  }

  /// `https://fetchnet.arijeet.in/updates/android/1.0.0+1-arm64-v8a`
  /// or `.../updates/windows/1.0.0+1`; the site root when unknown. Android
  /// links always carry the recommended ABI (the website requires it).
  Future<Uri> updateLink() async {
    final platform = platformSlug;
    final installed = await installedRelease();
    if (platform == null || installed == null) return Uri.parse(site);
    if (platform == 'android') await DeviceEnvironment.ensureLoaded();
    return Uri.parse(buildUpdateLink(platform, installed, androidInstallType: recommendedAndroidInstallType()));
  }

  @visibleForTesting
  static String buildUpdateLink(String platform, AppRelease installed, {String androidInstallType = 'universal'}) {
    final suffix = platform == 'android' ? '-$androidInstallType' : '';
    return '$site/updates/$platform/${Uri.encodeComponent(installed.versionName)}+${installed.buildNumber}$suffix';
  }

  /// Sets what a check would have found (tests).
  @visibleForTesting
  void debugSetResult({required UpdateState state, AppRelease? installed, PlatformUpdate? update}) {
    _state = state;
    _installed = installed;
    _installedLoad = Future.value(installed);
    _update = update;
    _latest = update?.release;
    notifyListeners();
  }

  /// Checks the website for the latest release of this platform. Runs once
  /// at startup and again on demand; overlapping calls share one check.
  Future<UpdateState> check() => _checking ??= _check().whenComplete(() => _checking = null);

  Future<UpdateState> _check() async {
    _state = UpdateState.checking;
    notifyListeners();
    final installed = await installedRelease();
    final platform = platformSlug;
    try {
      PlatformUpdate? update;
      AppRelease? latest;
      try {
        final body = await _get(updateManifestUrl, installed, platform);
        update = parseUpdateManifest(body, platform);
        latest = update?.release;
      } on SocketException {
        rethrow;
      } on TimeoutException {
        rethrow;
      } catch (_) {
        // No manifest yet (or a broken one): the old file still tells the
        // version, and updates go through the website.
        latest = parseManifest(await _get(manifestUrl, installed, platform), platform);
      }
      _update = update;
      _latest = latest;
      _state = compare(installed: installed, latest: latest);
    } on FormatException {
      _state = UpdateState.failed;
    } catch (_) {
      _state = await hasInternet() ? UpdateState.failed : UpdateState.offline;
    }
    notifyListeners();
    return _state;
  }

  /// Up to date, an update, or an unreleased build (by build number, which
  /// never carries the split-per-ABI inflation).
  @visibleForTesting
  static UpdateState compare({required AppRelease? installed, required AppRelease? latest}) {
    if (latest == null || installed == null) return UpdateState.upToDate;
    if (latest.buildNumber > installed.buildNumber) return UpdateState.available;
    if (installed.buildNumber > latest.buildNumber) return UpdateState.ahead;
    return UpdateState.upToDate;
  }

  Future<String> _get(String url, AppRelease? installed, String? platform) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await http.getUrl(Uri.parse('$url?t=${DateTime.now().millisecondsSinceEpoch}'));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache')
        ..set(HttpHeaders.userAgentHeader, 'FetchNet/${installed ?? 'unknown'} ($platform)');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      return body;
    } finally {
      http.close(force: true);
    }
  }

  /// This platform's entry of `/update-manifest.json`, or `null` when the
  /// platform has no public release.
  @visibleForTesting
  static PlatformUpdate? parseUpdateManifest(String body, String? platform) {
    final json = jsonDecode(body);
    if (json is! Map || json['platforms'] is! Map) throw const FormatException('update-manifest.json is not a manifest');
    if (platform == null) return null;
    final entry = (json['platforms'] as Map)[platform];
    if (entry == null) return null;
    return PlatformUpdate.fromJson(entry) ?? (throw const FormatException('Bad platform entry'));
  }

  /// Latest release for [platform] in the website's `releases.json`, or
  /// `null` when that platform has no public release:
  /// `{"android": {"latest": {"versionName": "1.0.0", "buildNo": 1}, "older": [...]}, ...}`
  @visibleForTesting
  static AppRelease? parseManifest(String body, String? platform) {
    final json = jsonDecode(body);
    if (json is! Map) throw const FormatException('releases.json is not an object');
    final entry = platform == null ? null : json[platform];
    if (entry == null) return null;
    if (entry is! Map) throw const FormatException('Bad platform entry');
    final latest = entry['latest'];
    if (latest == null) return null;
    if (latest is! Map) throw const FormatException('Bad latest release');
    final name = latest['versionName'];
    final build = latest['buildNo'];
    if (name is! String || build is! num) throw const FormatException('Bad release entry');
    return AppRelease(versionName: name, buildNumber: build.toInt());
  }

  /// The notes of [build] from the website: the update manifest's when it
  /// is that build, otherwise `/changelog.json`. `null` when they can't be
  /// loaded (offline, or the site has none for it).
  Future<ChangelogRelease?> notesFor(int build) async {
    final fromManifest = _update?.notes;
    if (fromManifest != null && _update!.release.buildNumber == build && !fromManifest.isEmpty) return fromManifest;
    try {
      final body = await _get(changelogUrl, await installedRelease(), platformSlug);
      final notes = Changelog.fromJson(jsonDecode(body)).forBuild(build);
      return notes == null || notes.isEmpty ? null : notes;
    } catch (_) {
      return null;
    }
  }

  /// Whether the device can reach the internet at all (no DNS needed).
  static Future<bool> hasInternet() async {
    Future<bool> reach(String host, int port) async {
      try {
        final s = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
        s.destroy();
        return true;
      } catch (_) {
        return false;
      }
    }

    final results = await Future.wait([
      reach('1.1.1.1', 443),
      reach('8.8.8.8', 443),
      reach('fetchnet.arijeet.in', 443),
    ]);
    return results.any((ok) => ok);
  }
}
