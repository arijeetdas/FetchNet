import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android picture-in-picture for the YouTube player.
class Pip {
  Pip._();

  static const MethodChannel _channel = MethodChannel('fetchnet/platform');
  static const EventChannel _events = EventChannel('fetchnet/pip');

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// The app is currently shown as a floating PiP window.
  static final ValueNotifier<bool> active = ValueNotifier(false);

  static StreamSubscription<dynamic>? _sub;
  static bool? _supported;

  static void _listen() {
    if (_sub != null || !_isAndroid) return;
    _sub = _events.receiveBroadcastStream().listen((e) => active.value = e == true, onError: (_) {});
  }

  static Future<bool> isSupported() async {
    if (!_isAndroid) return false;
    _listen();
    if (_supported != null) return _supported!;
    try {
      return _supported = await _channel.invokeMethod<bool>('pipSupported') ?? false;
    } catch (_) {
      return _supported = false;
    }
  }

  /// Shrinks the app into a floating window. Returns false when PiP isn't
  /// available (caller falls back to the in-app mini player).
  static Future<bool> enter({int? width, int? height}) async {
    if (!await isSupported()) return false;
    try {
      return await _channel.invokeMethod<bool>('enterPip', {'width': width, 'height': height}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Enter PiP by itself when the user leaves the app.
  static Future<void> setAutoEnter(bool enabled, {int? width, int? height}) async {
    if (!_isAndroid) return;
    _listen();
    try {
      await _channel.invokeMethod('setAutoPip', {'enabled': enabled, 'width': width, 'height': height});
    } catch (_) {}
  }
}
