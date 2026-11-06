import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Facts about the device the app runs on that Dart can't learn by itself.
///
/// Loaded once before the UI starts and immutable afterwards.
class DeviceEnvironment {
  DeviceEnvironment._();

  static const MethodChannel _channel = MethodChannel('fetchnet/platform');

  static bool _isChromeOS = false;
  static List<String> _abis = const [];
  static String _installedApkType = 'universal';
  static int _sdkInt = 0;
  static String? _pubspecVersionName;
  static int? _pubspecBuildNumber;
  static bool _initialized = false;

  /// Android: `version` / build number from pubspec.yaml, recorded at build
  /// time by Gradle. Unlike the APK version code, split-per-ABI builds don't
  /// inflate the build number. `null` elsewhere.
  static String? get pubspecVersionName => _pubspecVersionName;
  static int? get pubspecBuildNumber => _pubspecBuildNumber;

  /// True when this Android build runs on a Chromebook (ARC++ / ARCVM).
  static bool get isChromeOS => _isChromeOS;

  /// Android ABIs supported by the device, most preferred first.
  static List<String> get supportedAbis => _abis;

  /// `universal`, `arm64-v8a`, `armeabi-v7a`, `x86_64` or `x86`.
  static String get installedApkType => _installedApkType;

  /// Android API level (0 elsewhere).
  static int get androidSdkInt => _sdkInt;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isDesktop => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Display name of the OS the app is installed on.
  static String get platformDisplayName {
    if (kIsWeb) return 'Web';
    if (Platform.isAndroid) return _isChromeOS ? 'ChromeOS' : 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Web';
  }

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!isAndroid) return;
    await _load(const Duration(seconds: 2));
  }

  /// Asks again when the startup query didn't answer in time (the update
  /// link needs the device's ABIs).
  static Future<void> ensureLoaded() async {
    if (!isAndroid || _abis.isNotEmpty) return;
    await _load(const Duration(seconds: 5));
  }

  static Future<void> _load(Duration timeout) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getDeviceEnvironment').timeout(timeout);
      if (result == null) return;
      _isChromeOS = result['isChromeOS'] == true;
      _abis = (result['abis'] as List?)?.map((e) => e.toString()).toList() ?? const [];
      _installedApkType = (result['installedApkType']?.toString() ?? 'universal').trim();
      _sdkInt = (result['sdkInt'] as num?)?.toInt() ?? 0;
      final name = result['pubspecVersionName']?.toString().trim();
      _pubspecVersionName = (name == null || name.isEmpty || name == 'null') ? null : name;
      _pubspecBuildNumber = (result['pubspecBuildNumber'] as num?)?.toInt();
    } catch (_) {
      // Unknown: behave like a regular Android device.
    }
  }
}
