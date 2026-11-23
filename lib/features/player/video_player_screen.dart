import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/device_environment.dart';
import '../../core/platform/native_bridge.dart';
import '../../core/platform/pip.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../ui_kit/kit.dart';

/// Plays a downloaded video in FetchNet's own player.
Future<void> openVideoPlayer(BuildContext context, {required String path, String? title}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => VideoPlayerScreen(path: path, title: title),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ),
  );
}

/// A light player for videos on the device: play / pause, double-tap to
/// skip, a seek bar the picture follows while dragging, subtitles (inside
/// the video or in files next to it), speed, picture fit, loop, rotation /
/// full screen, picture-in-picture (Android), resume where it stopped, and
/// "Open with" another player.
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.path, this.title});

  final String path;
  final String? title;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  final Player _player = Player(configuration: const PlayerConfiguration(title: 'FetchNet'));

  /// Made before the video is opened, so libmpv starts straight on
  /// FetchNet's video output (no second start).
  late final VideoController _video;
  final _focus = FocusNode();
  final List<StreamSubscription<dynamic>> _subs = [];

  static bool get _desktop => DeviceEnvironment.isDesktop;
  static bool get _android => DeviceEnvironment.isAndroid;

  /// Where play positions are kept (taken at start: the widget tree can't
  /// be looked up while closing).
  late final SharedPreferences _store;

  /// The first picture is on screen.
  bool _ready = false;

  // ───── Controls ─────
  bool _controls = true;
  Timer? _hideTimer;

  /// Taps: the first shows / hides the controls at once; a second one on
  /// the same side soon after is a double-tap (skip), and the taps after
  /// it keep skipping.
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastTapZone = 0;
  bool _controlsBeforeTap = true;
  bool _skipping = false;

  /// A short "-10 s / +10 s" bubble on the side that was double-tapped.
  ({bool forward, int seconds, int key})? _ripple;
  Timer? _rippleTimer;

  /// Computers: the pointer must really move to bring the controls back
  /// (not the jitter of the click that hid them).
  Offset? _hoverAnchor;

  /// Held down: 2× until released.
  bool _boosting = false;
  double _rateBeforeBoost = 1;

  // ───── Options ─────
  double _rate = 1;
  BoxFit _fit = BoxFit.contain;
  bool _loop = false;
  int _skipSeconds = 10;
  double _subtitleScale = 1;
  bool _fullscreen = false;

  /// Phones: the screen is locked to this orientation (follows the video
  /// at first).
  bool? _landscape;

  /// Subtitle files next to the video (`Video.en.srt`), and the others in
  /// its folder.
  List<File> _sidecars = const [];
  List<File> _folderSubtitles = const [];
  String _subtitleLabel = 'Off';
  bool _subtitlesChosen = false;

  String get _title => widget.title ?? p.basenameWithoutExtension(widget.path);

  @override
  void initState() {
    super.initState();
    _store = AppScope.of(context).prefs.store;
    _video = VideoController(_player);
    _subs
      ..add(_player.stream.playing.listen((_) => _scheduleHide()))
      ..add(_player.stream.tracks.listen(_onTracks))
      ..add(_player.stream.width.listen((_) => _followVideoOrientation()))
      ..add(_player.stream.duration.listen(_maybeResume))
      ..add(_player.stream.position.listen(_rememberPosition));
    unawaited(_player.open(Media(widget.path)));
    unawaited(
      _video.waitUntilFirstFrameRendered.then((_) {
        if (mounted) setState(() => _ready = true);
      }),
    );
    unawaited(_findSubtitleFiles());
    if (!_desktop) unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _scheduleHide();
  }

  @override
  void dispose() {
    _savePosition(force: true);
    for (final s in _subs) {
      s.cancel();
    }
    _hideTimer?.cancel();
    _rippleTimer?.cancel();
    _scrubTimer?.cancel();
    _focus.dispose();
    unawaited(_player.dispose());
    if (_desktop) {
      if (_fullscreen) unawaited(defaultExitNativeFullscreen());
    } else {
      unawaited(SystemChrome.setPreferredOrientations(const []));
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  // ───── Controls showing / hiding ─────

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_player.state.playing) return;
    _hideTimer = Timer(const Duration(milliseconds: 3200), () {
      if (mounted && _player.state.playing) _setControls(false);
    });
  }

  void _setControls(bool show) {
    if (_controls == show) return;
    setState(() => _controls = show);
    if (!show) _hoverAnchor = null;
  }

  void _showControls() {
    _setControls(true);
    _scheduleHide();
  }

  void _onHover(PointerHoverEvent e) {
    if (_controls) {
      _scheduleHide();
      return;
    }
    final anchor = _hoverAnchor ??= e.position;
    if ((e.position - anchor).distance > 12) _showControls();
  }

  /// Splits the width into back (left), middle and forward (right).
  int _zone(double x, double width) => x < width * 0.35 ? -1 : (x > width * 0.65 ? 1 : 0);

  void _onTapUp(TapUpDetails d, double width) {
    final now = DateTime.now();
    final zone = _zone(d.localPosition.dx, width);
    final quick = now.difference(_lastTapAt) < const Duration(milliseconds: 320);
    _lastTapAt = now;
    if (zone != 0 && (_skipping || (quick && zone == _lastTapZone))) {
      // A double-tap on a side (and the taps after it): skip, and leave the
      // controls as they were before the first tap.
      _skipping = true;
      _lastTapZone = zone;
      if (_controls != _controlsBeforeTap) setState(() => _controls = _controlsBeforeTap);
      _skip(zone > 0);
      return;
    }
    if (zone == 0 && quick && _lastTapZone == 0 && _desktop) {
      // Double-click in the middle on a computer: full screen.
      _lastTapZone = 0;
      if (_controls != _controlsBeforeTap) setState(() => _controls = _controlsBeforeTap);
      _toggleFullscreen();
      return;
    }
    _lastTapZone = zone;
    _controlsBeforeTap = _controls;
    if (_controls) {
      _setControls(false);
    } else {
      _showControls();
    }
  }

  void _skip(bool forward) {
    final previous = _ripple;
    final seconds = previous != null && previous.forward == forward ? previous.seconds + _skipSeconds : _skipSeconds;
    _seekBy(forward ? _skipSeconds : -_skipSeconds);
    setState(() => _ripple = (forward: forward, seconds: seconds, key: (previous?.key ?? 0) + 1));
    _rippleTimer?.cancel();
    _rippleTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      _skipping = false;
      setState(() => _ripple = null);
    });
  }

  // ───── Playback ─────

  Future<void> _playPause() async {
    await _player.playOrPause();
    _showControls();
  }

  Future<void> _seekBy(int seconds) async {
    final d = _player.state.duration;
    var target = _player.state.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (d > Duration.zero && target > d) target = d;
    await _player.seek(target);
  }

  // Dragging the seek bar: quick keyframe seeks (a few a second) so the
  // picture follows the finger, then an exact one where it's let go.
  Duration? _scrubTo;
  Timer? _scrubTimer;
  bool _scrubbing = false;

  void _scrubStart() {
    _hideTimer?.cancel();
    _scrubbing = true;
  }

  void _scrub(Duration to) {
    _scrubTo = to;
    if (_scrubTimer?.isActive ?? false) return;
    _fastSeek(to);
    _scrubTimer = Timer(const Duration(milliseconds: 120), () {
      final last = _scrubTo;
      if (_scrubbing && last != null) _fastSeek(last);
    });
  }

  Future<void> _scrubEnd(Duration to) async {
    _scrubbing = false;
    _scrubTimer?.cancel();
    await _player.seek(to);
    _scheduleHide();
  }

  void _fastSeek(Duration to) {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      unawaited(platform.command(['seek', (to.inMilliseconds / 1000).toStringAsFixed(3), 'absolute+keyframes']));
    } else {
      unawaited(_player.seek(to));
    }
  }

  void _startBoost() {
    if (_boosting || !_player.state.playing) return;
    _rateBeforeBoost = _player.state.rate;
    _player.setRate(2);
    HapticFeedback.selectionClick();
    setState(() => _boosting = true);
  }

  void _endBoost() {
    if (!_boosting) return;
    _player.setRate(_rateBeforeBoost);
    setState(() => _boosting = false);
  }

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    await _player.setRate(rate);
  }

  Future<void> _setLoop(bool loop) async {
    setState(() => _loop = loop);
    await _player.setPlaylistMode(loop ? PlaylistMode.single : PlaylistMode.none);
  }

  // ───── Screen ─────

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    next ? await defaultEnterNativeFullscreen() : await defaultExitNativeFullscreen();
  }

  /// Phones: a landscape video turns the screen sideways (once, at start).
  void _followVideoOrientation() {
    if (_desktop || _landscape != null) return;
    final w = _player.state.width, h = _player.state.height;
    if (w == null || h == null || w == 0 || h == 0) return;
    _setLandscape(w > h);
  }

  Future<void> _setLandscape(bool landscape) async {
    setState(() => _landscape = landscape);
    await SystemChrome.setPreferredOrientations(
      landscape ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const [DeviceOrientation.portraitUp],
    );
  }

  Future<void> _enterPip() async {
    final ok = await Pip.enter(width: _player.state.width, height: _player.state.height);
    if (!ok && mounted) showSnack(context, 'Picture-in-picture isn\'t available on this device.');
  }

  Future<void> _openWith() async {
    await _player.pause();
    final ok = await NativeBridge.openWith(widget.path);
    if (!ok && mounted) showSnack(context, 'No app found to open this video.', kind: ToastKind.error);
  }

  // ───── Subtitles ─────

  static const _subtitleExt = {'.srt', '.vtt', '.ass', '.ssa'};

  /// In the background: big folders don't hold up the first picture.
  Future<void> _findSubtitleFiles() async {
    try {
      final dir = Directory(p.dirname(widget.path));
      final base = p.basenameWithoutExtension(widget.path).toLowerCase();
      final all = <File>[
        await for (final e in dir.list())
          if (e is File && _subtitleExt.contains(p.extension(e.path).toLowerCase())) e,
      ]..sort((a, b) => a.path.compareTo(b.path));
      if (!mounted) return;
      setState(() {
        _sidecars = [
          for (final f in all)
            if (p.basename(f.path).toLowerCase().startsWith('$base.')) f,
        ];
        _folderSubtitles = [
          for (final f in all)
            if (!_sidecars.contains(f)) f,
        ];
      });
      _onTracks(_player.state.tracks);
    } catch (_) {}
  }

  /// Subtitles show by themselves: the ones FetchNet put inside the video,
  /// or the files saved next to it.
  void _onTracks(Tracks tracks) {
    if (_subtitlesChosen) return;
    final inside = _embeddedSubtitles(tracks);
    if (inside.isNotEmpty) {
      _subtitlesChosen = true;
      _pickEmbedded(inside.first);
    } else if (_sidecars.isNotEmpty) {
      _subtitlesChosen = true;
      _pickFile(_sidecars.first);
    }
  }

  static List<SubtitleTrack> _embeddedSubtitles(Tracks t) => [
    for (final s in t.subtitle)
      if (s.id != 'auto' && s.id != 'no' && !s.uri && !s.data) s,
  ];

  static String _trackName(SubtitleTrack t, int i) {
    final name = [t.title, t.language].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return name.isEmpty ? 'Track ${i + 1}' : name;
  }

  /// "EN · SRT file" for "Video.en.srt".
  String _fileLabel(File f) {
    final name = p.basenameWithoutExtension(f.path);
    final base = p.basenameWithoutExtension(widget.path);
    if (name.toLowerCase().startsWith('${base.toLowerCase()}.')) {
      final lang = name.substring(base.length + 1);
      return '${lang.toUpperCase()} · ${p.extension(f.path).substring(1).toUpperCase()} file';
    }
    return p.basename(f.path);
  }

  Future<void> _pickEmbedded(SubtitleTrack t) async {
    await _player.setSubtitleTrack(t);
    if (mounted) setState(() => _subtitleLabel = _trackName(t, _embeddedSubtitles(_player.state.tracks).indexOf(t)));
  }

  Future<void> _pickFile(File f) async {
    await _player.setSubtitleTrack(SubtitleTrack.uri(Uri.file(f.path).toString(), title: _fileLabel(f)));
    if (mounted) setState(() => _subtitleLabel = _fileLabel(f));
  }

  Future<void> _subtitlesOff() async {
    _subtitlesChosen = true;
    await _player.setSubtitleTrack(SubtitleTrack.no());
    if (mounted) setState(() => _subtitleLabel = 'Off');
  }

  // ───── Resume where it stopped ─────

  static const _kPositions = 'player.positions';
  Duration _lastSaved = Duration.zero;
  bool _resumeChecked = false;

  Map<String, dynamic> _positions() {
    try {
      final raw = _store.getString(_kPositions);
      return raw == null ? {} : (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  void _maybeResume(Duration duration) {
    if (_resumeChecked || duration <= Duration.zero || !mounted) return;
    _resumeChecked = true;
    final ms = (_positions()[widget.path] as num?)?.toInt();
    if (ms == null) return;
    final at = Duration(milliseconds: ms);
    if (at < const Duration(seconds: 10) || at > duration - const Duration(seconds: 10)) return;
    _player.seek(at);
    showSnack(context, 'Resumed at ${formatDuration(at.inSeconds)}', actionLabel: 'Start over', onAction: () => _player.seek(Duration.zero));
  }

  void _rememberPosition(Duration position) {
    if ((position - _lastSaved).abs() > const Duration(seconds: 10)) _savePosition();
  }

  void _savePosition({bool force = false}) {
    if (!mounted && !force) return;
    final position = _player.state.position;
    final duration = _player.state.duration;
    _lastSaved = position;
    try {
      final map = _positions()..remove(widget.path);
      // Near the end counts as watched: next time starts from the top.
      if (duration > Duration.zero && position < duration - const Duration(seconds: 10)) {
        map[widget.path] = position.inMilliseconds;
      }
      while (map.length > 100) {
        map.remove(map.keys.first);
      }
      unawaited(_store.setString(_kPositions, jsonEncode(map)));
    } catch (_) {}
  }

  // ───── The ⋮ panel ─────

  void _openMenu([_MenuPage page = _MenuPage.main]) {
    _hideTimer?.cancel();
    showKitSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => _PlayerMenu(state: this, initial: page),
    ).whenComplete(_scheduleHide);
  }

  static String sizeLabel(double s) => s < 0.9 ? 'Small' : (s > 1.3 ? 'Extra large' : (s > 1.1 ? 'Large' : 'Normal'));
  static String fitLabel(BoxFit f) => switch (f) {
    BoxFit.cover => 'Fill',
    BoxFit.fill => 'Stretch',
    _ => 'Fit',
  };

  void _cycleFit() => setState(
    () => _fit = switch (_fit) {
      BoxFit.contain => BoxFit.cover,
      BoxFit.cover => BoxFit.fill,
      _ => BoxFit.contain,
    },
  );

  void _cycleSkip() => setState(
    () => _skipSeconds = switch (_skipSeconds) {
      5 => 10,
      10 => 15,
      15 => 30,
      _ => 5,
    },
  );

  // ───── Keyboard ─────

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    void volume(double delta) => _player.setVolume((_player.state.volume + delta).clamp(0, 100));
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      if (e is KeyDownEvent) _playPause();
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      _seekBy(key == LogicalKeyboardKey.keyJ ? -10 : -_skipSeconds);
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      _seekBy(key == LogicalKeyboardKey.keyL ? 10 : _skipSeconds);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      volume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      volume(-5);
    } else if (key == LogicalKeyboardKey.keyM) {
      _player.setVolume(_player.state.volume > 0 ? 0 : 100);
    } else if (key == LogicalKeyboardKey.keyF && e is KeyDownEvent && _desktop) {
      _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.escape && e is KeyDownEvent) {
      if (_fullscreen) {
        _toggleFullscreen();
      } else {
        Navigator.of(context).maybePop();
      }
    } else if (key == LogicalKeyboardKey.period && e.character == '>') {
      _setRate((_rate + 0.25).clamp(0.25, 3));
    } else if (key == LogicalKeyboardKey.comma && e.character == '<') {
      _setRate((_rate - 0.25).clamp(0.25, 3));
    } else {
      return KeyEventResult.ignored;
    }
    _showControls();
    return KeyEventResult.handled;
  }

  // ───── Layout ─────

  /// The video itself, rebuilt only when its picture fit or subtitle size
  /// changes (not on every tap), so the picture never stutters.
  Widget? _videoWidget;
  (BoxFit, double)? _videoKey;

  Widget _videoView() {
    final key = (_fit, _subtitleScale);
    if (_videoWidget != null && _videoKey == key) return _videoWidget!;
    _videoKey = key;
    return _videoWidget = RepaintBoundary(
      child: Video(
        controller: _video,
        controls: NoVideoControls,
        fit: _fit,
        fill: Colors.black,
        subtitleViewConfiguration: SubtitleViewConfiguration(
          style: TextStyle(
            height: 1.4,
            fontSize: 44 * _subtitleScale,
            color: Colors.white,
            fontWeight: FontWeight.w600,
            shadows: const [
              Shadow(blurRadius: 6, color: Colors.black),
              Shadow(blurRadius: 2, color: Colors.black),
            ],
            backgroundColor: const Color(0x66000000),
          ),
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 56),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: Pip.active,
      builder: (context, pip, _) {
        if (pip) return Scaffold(backgroundColor: Colors.black, body: _videoView());
        return Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: MouseRegion(
              onHover: _onHover,
              cursor: _controls ? MouseCursor.defer : SystemMouseCursors.none,
              child: LayoutBuilder(
                builder: (context, c) => Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => _onTapUp(d, c.maxWidth),
                      onLongPressStart: (_) => _startBoost(),
                      onLongPressEnd: (_) => _endBoost(),
                      child: _videoView(),
                    ),
                    if (!_ready) _Loading(title: _title),
                    _BufferingIndicator(player: _player, ready: _ready),
                    if (_ripple case final r?) _SkipRipple(forward: r.forward, seconds: r.seconds, key: ValueKey(r.key)),
                    if (_boosting)
                      const Positioned(
                        top: 24,
                        left: 0,
                        right: 0,
                        child: SafeArea(
                          child: Center(
                            child: _Pill(icon: Icons.fast_forward_rounded, text: '2× speed'),
                          ),
                        ),
                      ),
                    RepaintBoundary(
                      child: _Controls(
                        visible: _controls,
                        title: _title,
                        player: _player,
                        rate: _rate,
                        skipSeconds: _skipSeconds,
                        desktop: _desktop,
                        fullscreen: _fullscreen,
                        landscape: _landscape ?? false,
                        subtitlesOn: _subtitleLabel != 'Off',
                        onBack: () => Navigator.of(context).maybePop(),
                        onPlayPause: _playPause,
                        onSkip: (forward) {
                          _seekBy(forward ? _skipSeconds : -_skipSeconds);
                          _showControls();
                        },
                        onScrubStart: _scrubStart,
                        onScrub: _scrub,
                        onScrubEnd: _scrubEnd,
                        onSubtitles: () => _openMenu(_MenuPage.subtitles),
                        onSpeed: () => _openMenu(),
                        onOptions: () => _openMenu(),
                        onFullscreen: _toggleFullscreen,
                        onRotate: () => _setLandscape(!(_landscape ?? false)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ───────────── Controls ─────────────

/// Header (back, title, subtitles, ⋮), the middle buttons, and the seek bar
/// with its buttons. They slide and fade together.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.visible,
    required this.title,
    required this.player,
    required this.rate,
    required this.skipSeconds,
    required this.desktop,
    required this.fullscreen,
    required this.landscape,
    required this.subtitlesOn,
    required this.onBack,
    required this.onPlayPause,
    required this.onSkip,
    required this.onScrubStart,
    required this.onScrub,
    required this.onScrubEnd,
    required this.onSubtitles,
    required this.onSpeed,
    required this.onOptions,
    required this.onFullscreen,
    required this.onRotate,
  });

  final bool visible;
  final String title;
  final Player player;
  final double rate;
  final int skipSeconds;
  final bool desktop;
  final bool fullscreen;
  final bool landscape;
  final bool subtitlesOn;
  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final ValueChanged<bool> onSkip;
  final VoidCallback onScrubStart;
  final ValueChanged<Duration> onScrub;
  final ValueChanged<Duration> onScrubEnd;
  final VoidCallback onSubtitles;
  final VoidCallback onSpeed;
  final VoidCallback onOptions;
  final VoidCallback onFullscreen;
  final VoidCallback onRotate;

  static const _fade = Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget part({required Widget child, required Offset hidden}) => AnimatedSlide(
      offset: visible ? Offset.zero : hidden,
      duration: _fade,
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(opacity: visible ? 1 : 0, duration: _fade, child: child),
    );
    return IgnorePointer(
      ignoring: !visible,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Shade under the bars so they read on any picture (it doesn't
          // catch taps: those reach the video).
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: _fade,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB0000000), Color(0x00000000), Color(0x00000000), Color(0xD0000000)],
                    stops: [0, 0.22, 0.62, 1],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Column(
                children: [
                  part(
                    hidden: const Offset(0, -0.6),
                    child: Row(
                      children: [
                        _GlassIcon(icon: Icons.arrow_back_rounded, tooltip: 'Back', onTap: onBack),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                        ),
                        _GlassIcon(
                          icon: subtitlesOn ? Icons.closed_caption_rounded : Icons.closed_caption_off_rounded,
                          tooltip: 'Subtitles',
                          onTap: onSubtitles,
                        ),
                        const SizedBox(width: 6),
                        _GlassIcon(icon: Icons.more_vert_rounded, tooltip: 'More', onTap: onOptions),
                      ],
                    ),
                  ),
                  const Spacer(),
                  AnimatedScale(
                    scale: visible ? 1 : 0.9,
                    duration: _fade,
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: visible ? 1 : 0,
                      duration: _fade,
                      child: _MiddleButtons(player: player, skipSeconds: skipSeconds, onPlayPause: onPlayPause, onSkip: onSkip),
                    ),
                  ),
                  const Spacer(),
                  part(
                    hidden: const Offset(0, 0.4),
                    child: Column(
                      children: [
                        _SeekBar(player: player, active: visible, onStart: onScrubStart, onChanged: onScrub, onEnd: onScrubEnd),
                        Row(
                          children: [
                            _TimeText(player: player, active: visible),
                            const Spacer(),
                            _SpeedChip(rate: rate, onTap: onSpeed),
                            if (desktop) _Volume(player: player),
                            if (desktop)
                              _GlassIcon(
                                icon: fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                                tooltip: fullscreen ? 'Exit full screen (F)' : 'Full screen (F)',
                                onTap: onFullscreen,
                              )
                            else
                              _GlassIcon(icon: Icons.screen_rotation_rounded, tooltip: landscape ? 'Portrait' : 'Landscape', onTap: onRotate),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiddleButtons extends StatelessWidget {
  const _MiddleButtons({required this.player, required this.skipSeconds, required this.onPlayPause, required this.onSkip});

  final Player player;
  final int skipSeconds;
  final VoidCallback onPlayPause;
  final ValueChanged<bool> onSkip;

  static IconData _skipIcon(bool forward, int seconds) => switch ((forward, seconds)) {
    (true, 5) => Icons.forward_5_rounded,
    (true, 10) => Icons.forward_10_rounded,
    (true, 30) => Icons.forward_30_rounded,
    (true, _) => Icons.fast_forward_rounded,
    (false, 5) => Icons.replay_5_rounded,
    (false, 10) => Icons.replay_10_rounded,
    (false, 30) => Icons.replay_30_rounded,
    (false, _) => Icons.fast_rewind_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, snap) {
        final playing = snap.data ?? false;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _GlassIcon(icon: _skipIcon(false, skipSeconds), tooltip: 'Back $skipSeconds seconds', size: 30, onTap: () => onSkip(false)),
            const SizedBox(width: 30),
            Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.brandGradient,
                  boxShadow: [BoxShadow(color: AppColors.violetBright.withValues(alpha: 0.45), blurRadius: 24)],
                ),
                child: InkWell(
                  onTap: onPlayPause,
                  child: SizedBox(
                    width: 74,
                    height: 74,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                      child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(playing), color: Colors.white, size: 42),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 30),
            _GlassIcon(icon: _skipIcon(true, skipSeconds), tooltip: 'Forward $skipSeconds seconds', size: 30, onTap: () => onSkip(true)),
          ],
        );
      },
    );
  }
}

class _GlassIcon extends StatelessWidget {
  const _GlassIcon({required this.icon, required this.tooltip, required this.onTap, this.size = 24});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: size,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      icon: Icon(icon, color: Colors.white),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.rate, required this.onTap});

  final double rate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = rate == 1 ? '1×' : '${rate.toString().replaceAll(RegExp(r'\.0$'), '')}×';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: rate == 1 ? Colors.white.withValues(alpha: 0.12) : null,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: rate == 1 ? null : const BoxDecoration(gradient: AppColors.brandGradient),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The seek bar: dragging moves the picture with it (quick seeks) and shows
/// the time in big; what's loaded shows behind it.
class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player, required this.active, required this.onStart, required this.onChanged, required this.onEnd});

  final Player player;

  /// Follows the playing position only while the controls show: hidden
  /// ones don't redraw on every frame of the video.
  final bool active;
  final VoidCallback onStart;
  final ValueChanged<Duration> onChanged;
  final ValueChanged<Duration> onEnd;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = widget.player;
    return StreamBuilder<Duration>(
      stream: widget.active || _dragging != null ? player.stream.position : null,
      initialData: player.state.position,
      builder: (context, _) {
        final total = player.state.duration.inMilliseconds.toDouble();
        final max = total <= 0 ? 1.0 : total;
        final pos = (_dragging ?? player.state.position.inMilliseconds.toDouble()).clamp(0.0, max);
        final buffer = player.state.buffer.inMilliseconds.toDouble().clamp(0.0, max);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The time being dragged to, big.
            AnimatedOpacity(
              opacity: _dragging == null ? 0 : 1,
              duration: const Duration(milliseconds: 120),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(999)),
                child: Text(
                  '${formatDuration(pos ~/ 1000)} / ${formatDuration(max ~/ 1000)}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: _dragging == null ? 4 : 6,
                activeTrackColor: scheme.primary,
                inactiveTrackColor: Colors.white24,
                secondaryActiveTrackColor: Colors.white54,
                thumbColor: Colors.white,
                overlayColor: scheme.primary.withValues(alpha: 0.25),
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: _dragging == null ? 7 : 9),
              ),
              child: Slider(
                value: pos,
                secondaryTrackValue: buffer,
                max: max,
                onChangeStart: (v) {
                  widget.onStart();
                  setState(() => _dragging = v);
                },
                onChanged: (v) {
                  setState(() => _dragging = v);
                  widget.onChanged(Duration(milliseconds: v.round()));
                },
                onChangeEnd: (v) {
                  widget.onEnd(Duration(milliseconds: v.round()));
                  setState(() => _dragging = null);
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimeText extends StatefulWidget {
  const _TimeText({required this.player, required this.active});

  final Player player;
  final bool active;

  @override
  State<_TimeText> createState() => _TimeTextState();
}

class _TimeTextState extends State<_TimeText> {
  // Redraws once a second (when the shown time changes), not every frame.
  late final Stream<int> _seconds = widget.player.stream.position.map((d) => d.inSeconds).distinct();

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return StreamBuilder<int>(
      stream: widget.active ? _seconds : null,
      initialData: player.state.position.inSeconds,
      builder: (context, _) {
        final pos = player.state.position;
        return Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Text(
            '${formatDuration(pos.inSeconds)} / ${formatDuration(player.state.duration.inSeconds)}',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        );
      },
    );
  }
}

class _Volume extends StatelessWidget {
  const _Volume({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      initialData: player.state.volume,
      builder: (context, snap) {
        final v = snap.data ?? 100;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: v == 0 ? 'Unmute (M)' : 'Mute (M)',
              onPressed: () => player.setVolume(v == 0 ? 100 : 0),
              icon: Icon(v == 0 ? Icons.volume_off_rounded : (v < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded), color: Colors.white),
            ),
            SizedBox(
              width: 110,
              child: Slider(value: v.clamp(0, 100), max: 100, onChanged: player.setVolume),
            ),
          ],
        );
      },
    );
  }
}

/// Until the first picture: the name and a loader (no black screen).
class _Loading extends StatelessWidget {
  const _Loading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EnergyLoader(size: 56, onColor: true),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  title,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BufferingIndicator extends StatelessWidget {
  const _BufferingIndicator({required this.player, required this.ready});

  final Player player;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    if (!ready) return const SizedBox.shrink();
    return StreamBuilder<bool>(
      stream: player.stream.buffering,
      initialData: player.state.buffering,
      // Built only while buffering: a hidden, still-spinning loader would
      // make Flutter draw every frame next to the video and stutter it.
      builder: (context, snap) => IgnorePointer(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: snap.data == true
              ? const Center(key: ValueKey('buffering'), child: EnergyLoader(size: 56, onColor: true))
              : const SizedBox.shrink(key: ValueKey('playing')),
        ),
      ),
    );
  }
}

/// "-10 s" / "+10 s" on the double-tapped side.
class _SkipRipple extends StatelessWidget {
  const _SkipRipple({super.key, required this.forward, required this.seconds});

  final bool forward;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: 0.36,
          heightFactor: 1,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: forward ? const BorderRadius.horizontal(left: Radius.circular(400)) : const BorderRadius.horizontal(right: Radius.circular(400)),
              ),
              child: Center(
                child: _Pill(icon: forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded, text: '${forward ? '+' : '−'}$seconds s'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

// ───────────── The ⋮ panel ─────────────

enum _MenuPage { main, subtitles, audio, info }

/// A dark panel: speed chips, a grid of quick settings, and "Open with".
/// Subtitles, audio tracks and file info open as pages inside it.
class _PlayerMenu extends StatefulWidget {
  const _PlayerMenu({required this.state, required this.initial});

  final _VideoPlayerScreenState state;
  final _MenuPage initial;

  @override
  State<_PlayerMenu> createState() => _PlayerMenuState();
}

class _PlayerMenuState extends State<_PlayerMenu> {
  late _MenuPage _page = widget.initial;

  _VideoPlayerScreenState get s => widget.state;

  /// Changes a setting of the player, and redraws this panel too.
  void _apply(VoidCallback change) {
    change();
    setState(() {});
  }

  void _go(_MenuPage page) => setState(() => _page = page);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 0, 10, 10 + media.padding.bottom),
      child: Material(
        color: const Color(0xF2161320),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(seedColor: AppColors.violetBright, brightness: Brightness.dark),
            textTheme: Theme.of(context).textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: media.size.height * 0.8),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                child: SingleChildScrollView(
                  key: ValueKey(_page),
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                  child: switch (_page) {
                    _MenuPage.main => _main(context),
                    _MenuPage.subtitles => _subtitles(context),
                    _MenuPage.audio => _audio(context),
                    _MenuPage.info => _info(context),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _grabber() => Center(
    child: Container(
      width: 38,
      height: 4,
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(99)),
    ),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(color: Colors.white54, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.1),
    ),
  );

  Widget _pageHeader(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Back',
          onPressed: () => _go(_MenuPage.main),
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
        ),
        const SizedBox(width: 4),
        Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget _main(BuildContext context) {
    final audio = [
      for (final a in s._player.state.tracks.audio)
        if (a.id != 'auto' && a.id != 'no') a,
    ];
    final tiles = <Widget>[
      _Tile(
        icon: Icons.closed_caption_rounded,
        label: 'Subtitles',
        value: s._subtitleLabel,
        active: s._subtitleLabel != 'Off',
        onTap: () => _go(_MenuPage.subtitles),
      ),
      _Tile(
        icon: Icons.format_size_rounded,
        label: 'Subtitle size',
        value: _VideoPlayerScreenState.sizeLabel(s._subtitleScale),
        onTap: () => _apply(
          () => s.setState(
            () => s._subtitleScale = switch (s._subtitleScale) {
              0.8 => 1.0,
              1.0 => 1.2,
              1.2 => 1.5,
              _ => 0.8,
            },
          ),
        ),
      ),
      _Tile(icon: Icons.aspect_ratio_rounded, label: 'Picture', value: _VideoPlayerScreenState.fitLabel(s._fit), onTap: () => _apply(s._cycleFit)),
      _Tile(icon: Icons.fast_forward_rounded, label: 'Double-tap', value: '${s._skipSeconds} s', onTap: () => _apply(s._cycleSkip)),
      _Tile(icon: Icons.repeat_one_rounded, label: 'Loop', value: s._loop ? 'On' : 'Off', active: s._loop, onTap: () => _apply(() => s._setLoop(!s._loop))),
      if (audio.length > 1) _Tile(icon: Icons.audiotrack_rounded, label: 'Audio', value: '${audio.length} tracks', onTap: () => _go(_MenuPage.audio)),
      if (_VideoPlayerScreenState._android)
        _Tile(
          icon: Icons.picture_in_picture_alt_rounded,
          label: 'Mini player',
          value: 'Picture-in-picture',
          onTap: () {
            Navigator.pop(context);
            s._enterPip();
          },
        ),
      _Tile(icon: Icons.info_outline_rounded, label: 'File info', value: 'Size, length…', onTap: () => _go(_MenuPage.info)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _grabber(),
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(13)),
              child: const Icon(Icons.tune_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Playback',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    s._title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _label('Speed'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final r in const [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _SpeedOption(
                    label: r == 1 ? '1×' : '${r.toString().replaceAll(RegExp(r'\.0$'), '')}×',
                    selected: s._rate == r,
                    onTap: () => _apply(() => s._setRate(r)),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, c) {
            final columns = c.maxWidth >= 420 ? 3 : 2;
            const gap = 10.0;
            final width = (c.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final t in tiles) SizedBox(width: width, child: t)],
            );
          },
        ),
        const SizedBox(height: 16),
        Material(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              Navigator.pop(context);
              s._openWith();
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.open_in_new_rounded, color: Colors.white),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Open with',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                        ),
                        Text('Play it in another app', style: TextStyle(color: Colors.white60, fontSize: 12.5)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: Colors.white54),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _choice(String label, bool selected, VoidCallback onTap, {String? detail}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? AppColors.violetBright.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: selected ? AppColors.violetBright.withValues(alpha: 0.6) : Colors.transparent),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                      if (detail != null) Text(detail, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
                if (selected) const Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _subtitles(BuildContext context) {
    final inside = _VideoPlayerScreenState._embeddedSubtitles(s._player.state.tracks);
    final current = s._subtitleLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _grabber(),
        _pageHeader('Subtitles'),
        _choice('Off', current == 'Off', () => _apply(s._subtitlesOff)),
        if (inside.isNotEmpty) ...[
          const SizedBox(height: 8),
          _label('In the video'),
          for (final (i, t) in inside.indexed)
            _choice(_VideoPlayerScreenState._trackName(t, i), current == _VideoPlayerScreenState._trackName(t, i), () => _apply(() => s._pickEmbedded(t))),
        ],
        if (s._sidecars.isNotEmpty) ...[
          const SizedBox(height: 8),
          _label('Saved with this video'),
          for (final f in s._sidecars) _choice(s._fileLabel(f), current == s._fileLabel(f), () => _apply(() => s._pickFile(f))),
        ],
        if (s._folderSubtitles.isNotEmpty) ...[
          const SizedBox(height: 8),
          _label('Other files in this folder'),
          for (final f in s._folderSubtitles) _choice(s._fileLabel(f), current == s._fileLabel(f), () => _apply(() => s._pickFile(f))),
        ],
        if (inside.isEmpty && s._sidecars.isEmpty && s._folderSubtitles.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'This video has no subtitles. Turn on Download subtitles in Settings → Extra Settings to save them with '
              'your next videos.',
              style: TextStyle(color: Colors.white60),
            ),
          ),
        const SizedBox(height: 10),
        _label('Size'),
        KitSegmented<double>(
          segments: const [
            ButtonSegment(value: 0.8, label: Text('S')),
            ButtonSegment(value: 1.0, label: Text('M')),
            ButtonSegment(value: 1.2, label: Text('L')),
            ButtonSegment(value: 1.5, label: Text('XL')),
          ],
          selected: {s._subtitleScale},
          showSelectedIcon: false,
          onSelectionChanged: (v) => _apply(() => s.setState(() => s._subtitleScale = v.first)),
        ),
      ],
    );
  }

  Widget _audio(BuildContext context) {
    final tracks = [
      for (final a in s._player.state.tracks.audio)
        if (a.id != 'auto' && a.id != 'no') a,
    ];
    final current = s._player.state.track.audio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _grabber(),
        _pageHeader('Audio track'),
        for (final (i, t) in tracks.indexed)
          _choice(
            [t.title, t.language].whereType<String>().where((x) => x.isNotEmpty).join(' · ').ifEmpty('Track ${i + 1}'),
            current.id == t.id,
            () => _apply(() => s._player.setAudioTrack(t)),
          ),
      ],
    );
  }

  Widget _info(BuildContext context) {
    final path = s.widget.path;
    final w = s._player.state.width, h = s._player.state.height;
    String size() {
      try {
        return formatBytes(File(path).lengthSync());
      } catch (_) {
        return '—';
      }
    }

    final rows = <(IconData, String, String)>[
      (Icons.movie_rounded, 'Name', p.basename(path)),
      if (w != null && h != null && w > 0) (Icons.high_quality_rounded, 'Resolution', '$w × $h'),
      (Icons.schedule_rounded, 'Length', formatDuration(s._player.state.duration.inSeconds)),
      (Icons.sd_storage_rounded, 'Size', size()),
      (Icons.folder_rounded, 'Folder', p.dirname(path)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _grabber(),
        _pageHeader('File info'),
        for (final (icon, k, v) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(14)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: Colors.white70, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(k, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        SelectableText(
                          v,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _SpeedOption extends StatelessWidget {
  const _SpeedOption({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? null : Colors.white.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: selected ? const BoxDecoration(gradient: AppColors.brandGradient) : null,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ),
    );
  }
}

/// A quick setting: icon, name and its value; highlighted when on.
class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label, required this.value, required this.onTap, this.active = false});

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.violetBright.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: active ? AppColors.violetBright.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: active ? Colors.white : Colors.white70, size: 22),
              const SizedBox(height: 10),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: active ? Colors.white : Colors.white60, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
