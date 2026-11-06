import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A button pressed on the media notification, lock screen or a headset.
typedef MediaAction = ({String action, int? positionMs});

/// Android's media notification and media session for the YouTube player.
class MediaNotification {
  MediaNotification._();

  static const MethodChannel _channel = MethodChannel('fetchnet/media');
  static const EventChannel _events = EventChannel('fetchnet/media/events');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Stream<MediaAction>? _stream;

  /// play | pause | next | previous | seek | stop.
  static Stream<MediaAction> actions() {
    if (!isSupported) return const Stream.empty();
    return _stream ??= _events.receiveBroadcastStream().map((e) {
      final m = (e as Map).cast<Object?, Object?>();
      return (action: '${m['action']}', positionMs: (m['position'] as num?)?.toInt());
    }).asBroadcastStream();
  }

  /// Shows / updates the notification. [art] is sent only when it changed;
  /// otherwise [keepArt] keeps the one already shown.
  static Future<void> update({
    required String title,
    required String artist,
    required Duration duration,
    required Duration position,
    required bool playing,
    required double speed,
    required bool canPrevious,
    required bool canNext,
    Uint8List? art,
    bool keepArt = false,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'artist': artist,
        'durationMs': duration.inMilliseconds,
        'positionMs': position.inMilliseconds,
        'playing': playing,
        'speed': speed,
        'canPrevious': canPrevious,
        'canNext': canNext,
        'art': ?art,
        'keepArt': keepArt,
      });
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
