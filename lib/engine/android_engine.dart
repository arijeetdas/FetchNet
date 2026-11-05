import 'dart:async';

import 'package:flutter/services.dart';

import 'engine.dart';

/// yt-dlp on Android through youtubedl-android (bundled Python, FFmpeg and
/// QuickJS), driven over a method channel.
class AndroidEngine extends YtDlpEngine {
  AndroidEngine(super.prefs);

  static const _channel = MethodChannel('fetchnet/engine');
  static const _events = EventChannel('fetchnet/engine/events');

  final Map<String, _AndroidRun> _runs = {};
  StreamSubscription<dynamic>? _eventSub;
  Future<void>? _initFuture;

  @override
  Future<void> initialize() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    _eventSub ??= _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    status.value = const EngineStatus(state: EngineState.initializing, message: 'Preparing the download engine…');
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('init');
      status.value = EngineStatus(
        state: EngineState.ready,
        version: result?['version']?.toString(),
        ffmpegAvailable: true,
        jsRuntime: 'QuickJS',
      );
      unawaited(maybeAutoUpdate());
    } on PlatformException catch (e) {
      _initFuture = null;
      status.value = EngineStatus(
        state: EngineState.error,
        message: 'The download engine failed to start: ${e.message ?? e.code}',
      );
    }
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final id = raw['id']?.toString();
    final run = id == null ? null : _runs[id];
    if (run == null) return;
    switch (raw['type']) {
      case 'line':
        run._lines.add(raw['line']?.toString() ?? '');
      case 'exit':
        _runs.remove(id);
        run._finish(EngineResult(
          exitCode: (raw['exitCode'] as num?)?.toInt() ?? -1,
          stdout: raw['out']?.toString() ?? '',
          stderr: raw['err']?.toString() ?? '',
        ));
    }
  }

  @override
  Future<EngineResult> run(List<String> args, {String? id}) async {
    await initialize();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('run', {'id': id ?? '', 'args': args});
      return EngineResult(
        exitCode: (result?['exitCode'] as num?)?.toInt() ?? -1,
        stdout: result?['out']?.toString() ?? '',
        stderr: result?['err']?.toString() ?? '',
      );
    } on PlatformException catch (e) {
      return EngineResult(exitCode: -1, stdout: '', stderr: e.message ?? e.code);
    }
  }

  @override
  EngineRun start(String id, List<String> args) {
    final run = _AndroidRun(() => cancel(id));
    _runs[id] = run;
    () async {
      await initialize();
      try {
        await _channel.invokeMethod('start', {'id': id, 'args': args});
      } on PlatformException catch (e) {
        _runs.remove(id);
        run._finish(EngineResult(exitCode: -1, stdout: '', stderr: e.message ?? e.code));
      }
    }();
    return run;
  }

  @override
  Future<void> cancel(String id) async {
    try {
      await _channel.invokeMethod('cancel', {'id': id});
    } catch (_) {}
  }

  @override
  Future<String> update() async {
    await initialize();
    final previous = status.value;
    if (previous.state == EngineState.updating) return 'An update is already running.';
    status.value = previous.copyWith(state: EngineState.updating, message: 'Updating yt-dlp…');
    // Updates go through GitHub's API, which can hit rate limits or network
    // blips: retry with backoff, then fall back to the nightly build channel
    // (a separate release repository).
    const plan = [('stable', 0), ('stable', 2), ('stable', 5), ('nightly', 3), ('nightly', 8)];
    String? lastError;
    for (final (channel, delay) in plan) {
      if (delay > 0) await Future<void>.delayed(Duration(seconds: delay));
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>('update', {'channel': channel});
        await prefs.markEngineUpdateChecked();
        final version = result?['version']?.toString();
        status.value = previous.copyWith(state: EngineState.ready, version: version, clearMessage: true);
        return result?['status'] == 'ALREADY_UP_TO_DATE'
            ? 'yt-dlp is already up to date (${version ?? 'latest'}).'
            : 'yt-dlp updated to ${version ?? 'the latest version'}.';
      } on PlatformException catch (e) {
        lastError = e.message ?? e.code;
      }
    }
    status.value = previous.copyWith(state: EngineState.ready, clearMessage: true);
    return 'Update failed after several tries. Check your connection and try again. ($lastError)';
  }
}

class _AndroidRun extends EngineRun {
  _AndroidRun(this._cancel);

  final Future<void> Function() _cancel;
  final StreamController<String> _lines = StreamController.broadcast();
  final Completer<EngineResult> _done = Completer();

  void _finish(EngineResult result) {
    if (_done.isCompleted) return;
    _done.complete(result);
    _lines.close();
  }

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<EngineResult> get done => _done.future;

  @override
  Future<void> cancel() => _cancel();
}
