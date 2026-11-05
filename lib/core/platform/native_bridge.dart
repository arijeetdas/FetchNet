import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Small OS integrations: media scanning, opening files, the Android
/// download service and links shared into the app.
class NativeBridge {
  NativeBridge._();

  static const MethodChannel _channel = MethodChannel('fetchnet/platform');
  static const EventChannel _shareChannel = EventChannel('fetchnet/share');

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// `<Internal storage>/Download/FetchNet`, created if missing (Android only).
  static Future<({String path, bool exists})?> androidDownloadDirectory() async {
    if (!_isAndroid) return null;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getDownloadDirectory');
      if (result == null) return null;
      return (path: result['path'] as String, exists: result['exists'] == true);
    } catch (_) {
      return null;
    }
  }

  /// Android 10 and older need WRITE_EXTERNAL_STORAGE for the public Download folder.
  static Future<bool> needsLegacyStoragePermission() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('needsLegacyStoragePermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Requests `storage` (Android 10 and older) or `notifications` (Android
  /// 13+). Returns true when granted or not needed.
  static Future<bool> requestPermission(String name) async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestPermission', {'name': name}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Makes a finished (or deleted) file show up in / vanish from Gallery and
  /// music apps.
  static Future<void> scanFile(String path) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('scanFile', {'path': path});
    } catch (_) {}
  }

  /// Opens a downloaded file in the user's default app.
  static Future<bool> openFile(String path) async {
    if (kIsWeb) return false;
    if (_isAndroid) {
      try {
        return await _channel.invokeMethod<bool>('openFile', {'path': path}) ?? false;
      } catch (_) {
        return false;
      }
    }
    return launchUrl(Uri.file(path));
  }

  /// Opens the folder containing [path] with the file selected where possible.
  static Future<void> revealInFolder(String path) async {
    if (kIsWeb) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [File(path).parent.path]);
      }
    } catch (_) {}
  }

  static Future<void> openFolder(String dir) async {
    if (kIsWeb) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      }
    } catch (_) {}
  }

  /// Link the app was launched with through Android's share sheet.
  static Future<String?> consumeSharedText() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('consumeSharedText');
    } catch (_) {
      return null;
    }
  }

  /// Links shared into the app while it is running.
  static Stream<String> sharedTextStream() {
    if (!_isAndroid) return const Stream.empty();
    return _shareChannel.receiveBroadcastStream().map((e) => e.toString());
  }

  static const EventChannel _actionChannel = EventChannel('fetchnet/notification_actions');

  /// Chrome-style per-download notification. [state] is `progress`,
  /// `complete`, `failed` or `cancelled`.
  static Future<void> downloadNotification({
    required String id,
    required String state,
    required String fileName,
    String text = '',
    String detail = '',
    int progress = -1,
    String? path,
    String size = '',
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('downloadNotification', {
        'id': id,
        'state': state,
        'fileName': fileName,
        'text': text,
        'detail': detail,
        'progress': progress,
        'path': path,
        'size': size,
      });
    } catch (_) {}
  }

  /// Actions from notifications: `{action: cancel, id}` or `{action: open_downloads}`.
  static Stream<Map<String, String?>> notificationActions() {
    if (!_isAndroid) return const Stream.empty();
    return _actionChannel.receiveBroadcastStream().map((e) {
      final m = (e as Map).cast<Object?, Object?>();
      return {'action': m['action']?.toString(), 'id': m['id']?.toString()};
    });
  }

  /// `open_downloads` when the app was launched from a download notification.
  static Future<String?> consumeLaunchAction() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('consumeLaunchAction');
    } catch (_) {
      return null;
    }
  }
}
