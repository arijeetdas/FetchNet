import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' show Player;
import 'package:media_kit_video/media_kit_video.dart';

import '../../../widgets/brand.dart';
import 'yt_player_controller.dart';
import 'yt_player_settings.dart';

/// `1:05` / `1:02:03`.
String formatClock(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// FetchNet's video player surface with YouTube-style controls.
class YtPlayerView extends StatefulWidget {
  const YtPlayerView({
    super.key,
    required this.controller,
    required this.fullscreen,
    required this.onToggleFullscreen,
    this.onMinimize,
    this.onPip,
    this.onOpenInBrowser,
    this.bare = false,
  });

  final YtPlayerController controller;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  /// Chevron in the top-left (back to the feed, keeps playing).
  final VoidCallback? onMinimize;
  final VoidCallback? onPip;

  /// Shown on the error panel.
  final VoidCallback? onOpenInBrowser;

  /// Only the picture (Android PiP window).
  final bool bare;

  @override
  State<YtPlayerView> createState() => _YtPlayerViewState();
}

class _YtPlayerViewState extends State<YtPlayerView> {
  YtPlayerController get c => widget.controller;

  bool _visible = true;
  bool _locked = false;
  Timer? _hideTimer;

  // Double-tap seeking: which side and how far, shown as a ripple.
  int _seekSide = 0;
  int _seekSeconds = 0;
  Timer? _seekTimer;
  Offset? _doubleTapAt;

  // Long-press: temporary 2× speed.
  bool _boost = false;
  double _rateBeforeBoost = 1;

  final FocusNode _focus = FocusNode(debugLabel: 'player');

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      // Stay up while paused (except when locked) so the controls are at hand.
      if (c.player.state.playing || _locked) setState(() => _visible = false);
    });
  }

  void _show() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggleVisible() {
    setState(() => _visible = !_visible);
    if (_visible) _scheduleHide();
  }

  void _onTapUp(TapUpDetails d, double width) {
    if (_locked) {
      _toggleVisible();
      return;
    }
    // Keep seeking with single taps right after a double tap, like YouTube.
    if (_seekSide != 0) {
      final side = d.localPosition.dx < width / 2 ? -1 : 1;
      if (side == _seekSide) {
        _seek(side);
        return;
      }
    }
    _toggleVisible();
  }

  void _onDoubleTap(double width) {
    if (_locked) return;
    final x = _doubleTapAt?.dx ?? width / 2;
    if (x > width * 0.4 && x < width * 0.6) {
      c.playPause();
      _show();
      return;
    }
    _seek(x < width / 2 ? -1 : 1);
  }

  void _seek(int side) {
    HapticFeedback.lightImpact();
    c.seekBy(Duration(seconds: 10 * side));
    setState(() {
      if (_seekSide != side) _seekSeconds = 0;
      _seekSide = side;
      _seekSeconds += 10;
      _visible = false;
    });
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => _seekSide = 0);
    });
  }

  void _startBoost() {
    if (_locked || !c.player.state.playing) return;
    HapticFeedback.mediumImpact();
    _rateBeforeBoost = c.speed;
    c.player.setRate(2);
    setState(() {
      _boost = true;
      _visible = false;
    });
  }

  void _endBoost() {
    if (!_boost) return;
    c.player.setRate(_rateBeforeBoost);
    setState(() => _boost = false);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    void seek(int s) {
      c.seekBy(Duration(seconds: s));
      _show();
    }

    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK || key == LogicalKeyboardKey.mediaPlayPause) {
      if (e is KeyDownEvent) c.playPause();
      _show();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      seek(-5);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      seek(5);
    } else if (key == LogicalKeyboardKey.keyJ) {
      seek(-10);
    } else if (key == LogicalKeyboardKey.keyL) {
      seek(10);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      c.player.setVolume((c.player.state.volume + 5).clamp(0, 100));
      _show();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      c.player.setVolume((c.player.state.volume - 5).clamp(0, 100));
      _show();
    } else if (key == LogicalKeyboardKey.keyM) {
      c.player.setVolume(c.player.state.volume > 0 ? 0 : 100);
      _show();
    } else if (key == LogicalKeyboardKey.keyF && e is KeyDownEvent) {
      widget.onToggleFullscreen();
    } else if (key == LogicalKeyboardKey.escape && widget.fullscreen && e is KeyDownEvent) {
      widget.onToggleFullscreen();
    } else if ((key == LogicalKeyboardKey.keyN && shift) || key == LogicalKeyboardKey.mediaTrackNext) {
      if (e is KeyDownEvent) c.next();
    } else if ((key == LogicalKeyboardKey.keyP && shift) || key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (e is KeyDownEvent) c.previous();
    } else if (key.keyLabel.length == 1 && RegExp(r'[0-9]').hasMatch(key.keyLabel) && e is KeyDownEvent) {
      // 0–9 jumps to 0 %–90 %, like YouTube.
      final d = c.player.state.duration;
      if (d > Duration.zero) c.player.seek(d * (int.parse(key.keyLabel) / 10));
      _show();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final video = Video(
          controller: c.video,
          controls: NoVideoControls,
          fit: c.fit,
          fill: Colors.black,
          // Listen only keeps going when the app is in the background.
          pauseUponEnteringBackgroundMode: !c.listenOnly,
        );
        final layers = <Widget>[
          Positioned.fill(child: video),
          if (c.listenOnly)
            Positioned.fill(
              child: _ListenArtwork(thumbnail: c.thumbnail, title: c.title),
            ),
          if (c.streams == null && c.streamError == null)
            Positioned.fill(
              child: _Preparing(thumbnail: c.thumbnail, bare: widget.bare, startedAt: c.lookupStartedAt),
            ),
          if (c.streams != null) Positioned.fill(child: _BufferingSpinner(controller: c)),
        ];
        if (widget.bare) {
          return ColoredBox(
            color: Colors.black,
            child: Stack(children: layers),
          );
        }
        return Focus(
          focusNode: _focus,
          autofocus: _isDesktop,
          onKeyEvent: _onKey,
          child: MouseRegion(
            onHover: (_) => _show(),
            child: ColoredBox(
              color: Colors.black,
              child: LayoutBuilder(
                builder: (context, box) {
                  final w = box.maxWidth;
                  return Stack(
                    children: [
                      ...layers,
                      // Gestures under the controls; buttons on top win their taps.
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (d) => _onTapUp(d, w),
                          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
                          onDoubleTap: () => _onDoubleTap(w),
                          onLongPressStart: (_) => _startBoost(),
                          onLongPressEnd: (_) => _endBoost(),
                          onLongPressCancel: _endBoost,
                        ),
                      ),
                      if (_seekSide != 0) _SeekRipple(side: _seekSide, seconds: _seekSeconds),
                      if (_boost) const Positioned(top: 14, left: 0, right: 0, child: Center(child: _BoostPill())),
                      if (c.streamError != null)
                        Positioned.fill(
                          child: _ErrorPanel(
                            message: c.streamError!,
                            hint: c.streamHint,
                            onRetry: c.retry,
                            onOpenInBrowser: widget.onOpenInBrowser,
                            onMinimize: widget.onMinimize,
                          ),
                        )
                      else if (_locked)
                        _LockedLayer(
                          visible: _visible,
                          onUnlock: () {
                            setState(() => _locked = false);
                            _show();
                          },
                        )
                      else
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: !_visible,
                            child: AnimatedOpacity(
                              opacity: _visible ? 1 : 0,
                              duration: const Duration(milliseconds: 220),
                              child: _Controls(
                                controller: c,
                                fullscreen: widget.fullscreen,
                                compact: w < 420,
                                onToggleFullscreen: widget.onToggleFullscreen,
                                onMinimize: widget.onMinimize,
                                onPip: widget.onPip,
                                onLock: () {
                                  setState(() => _locked = true);
                                  _show();
                                },
                                onInteract: _show,
                              ),
                            ),
                          ),
                        ),
                      Positioned.fill(child: _UpNextCountdown(controller: c)),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

// ───── Controls ─────

class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.fullscreen,
    required this.compact,
    required this.onToggleFullscreen,
    required this.onLock,
    required this.onInteract,
    this.onMinimize,
    this.onPip,
  });

  final YtPlayerController controller;
  final bool fullscreen;
  final bool compact;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onLock;

  /// Any tap on a control keeps the controls up a little longer.
  final VoidCallback onInteract;
  final VoidCallback? onMinimize;
  final VoidCallback? onPip;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final player = c.player;
    VoidCallback tap(VoidCallback f) => () {
      onInteract();
      f();
    };
    final big = compact ? 56.0 : 68.0;
    final small = compact ? 42.0 : 48.0;

    // The scrim doesn't take taps: those reach the gesture layer below (hide
    // the controls, double-tap to seek). Only the buttons catch them.
    final scrim = IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.62),
              Colors.black.withValues(alpha: 0.18),
              Colors.black.withValues(alpha: 0.18),
              Colors.black.withValues(alpha: 0.72),
            ],
            stops: const [0, 0.3, 0.62, 1],
          ),
        ),
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: scrim),
        Positioned.fill(child: _bar(context, c, player, tap, big, small)),
      ],
    );
  }

  Widget _bar(
    BuildContext context,
    YtPlayerController c,
    Player player,
    VoidCallback Function(VoidCallback) tap,
    double big,
    double small,
  ) {
    return SafeArea(
      top: fullscreen,
      bottom: fullscreen,
      left: fullscreen,
      right: fullscreen,
      child: Stack(
        children: [
          // Top bar.
          Positioned(
            left: 4,
            right: 4,
            top: 4,
            child: Row(
              children: [
                if (onMinimize != null)
                  _IconAction(
                    icon: fullscreen ? Icons.fullscreen_exit_rounded : Icons.keyboard_arrow_down_rounded,
                    tooltip: fullscreen ? 'Exit full screen' : 'Minimize',
                    onTap: tap(fullscreen ? onToggleFullscreen : onMinimize!),
                  ),
                Expanded(
                  child: fullscreen
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                        )
                      : const SizedBox(),
                ),
                if (c.listenOnly) const _Chip(icon: Icons.headphones_rounded, label: 'Audio only'),
                if (c.loop) const _Chip(icon: Icons.repeat_one_rounded, label: 'Loop'),
                if (c.sleepTimerOn) const _Chip(icon: Icons.bedtime_rounded, label: 'Sleep'),
                if (onPip != null)
                  _IconAction(
                    icon: Icons.picture_in_picture_alt_rounded,
                    tooltip: 'Picture-in-picture',
                    onTap: tap(onPip!),
                  ),
                _IconAction(icon: Icons.lock_outline_rounded, tooltip: 'Lock controls', onTap: tap(onLock)),
                _IconAction(
                  icon: Icons.tune_rounded,
                  tooltip: 'Settings',
                  onTap: tap(() => showYtPlayerSettings(context, c)),
                ),
              ],
            ),
          ),
          // Transport.
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RoundButton(
                  icon: Icons.skip_previous_rounded,
                  size: small,
                  tooltip: 'Previous',
                  onTap: tap(c.previous),
                ),
                SizedBox(width: compact ? 6 : 14),
                _RoundButton(
                  icon: Icons.replay_10_rounded,
                  size: small,
                  tooltip: 'Back 10 seconds',
                  onTap: tap(() => c.seekBy(const Duration(seconds: -10))),
                ),
                SizedBox(width: compact ? 10 : 20),
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  initialData: player.state.playing,
                  builder: (context, snap) => StreamBuilder<bool>(
                    stream: player.stream.completed,
                    initialData: player.state.completed,
                    builder: (context, done) => _RoundButton(
                      icon: done.data == true
                          ? Icons.replay_rounded
                          : (snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      size: big,
                      primary: true,
                      tooltip: snap.data == true ? 'Pause (k)' : 'Play (k)',
                      onTap: tap(c.playPause),
                    ),
                  ),
                ),
                SizedBox(width: compact ? 10 : 20),
                _RoundButton(
                  icon: Icons.forward_10_rounded,
                  size: small,
                  tooltip: 'Forward 10 seconds',
                  onTap: tap(() => c.seekBy(const Duration(seconds: 10))),
                ),
                SizedBox(width: compact ? 6 : 14),
                _RoundButton(
                  icon: Icons.skip_next_rounded,
                  size: small,
                  tooltip: 'Next',
                  onTap: c.nextVideo == null ? null : tap(c.next),
                ),
              ],
            ),
          ),
          // Bottom bar.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
                  child: Row(
                    children: [
                      _TimeLabel(controller: c),
                      if (_isDesktop) _VolumeControl(controller: c, onInteract: onInteract),
                      const Spacer(),
                      if (c.speed != 1) _Chip(icon: Icons.speed_rounded, label: '${_speedLabel(c.speed)}×'),
                      _IconAction(
                        icon: c.fit == BoxFit.contain ? Icons.fit_screen_rounded : Icons.crop_free_rounded,
                        tooltip: c.fit == BoxFit.contain ? 'Fill screen' : 'Fit to screen',
                        onTap: tap(c.toggleFit),
                      ),
                      _IconAction(
                        icon: fullscreen
                            ? Icons.fullscreen_exit_rounded
                            : (_isDesktop ? Icons.fullscreen_rounded : Icons.screen_rotation_rounded),
                        tooltip: fullscreen ? 'Exit full screen (f)' : (_isDesktop ? 'Full screen (f)' : 'Landscape'),
                        onTap: tap(onToggleFullscreen),
                      ),
                    ],
                  ),
                ),
                _SeekBar(controller: c, onInteract: onInteract),
                SizedBox(height: fullscreen ? 8 : 2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _speedLabel(double s) => s == s.roundToDouble() ? s.toStringAsFixed(0) : '$s';

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.size, required this.onTap, this.tooltip, this.primary = false});

  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final button = Material(
      color: primary ? Colors.white.withValues(alpha: 0.18) : Colors.black.withValues(alpha: 0.28),
      shape: CircleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: primary ? 0.35 : 0.12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: size * 0.56,
            color: Colors.white.withValues(alpha: enabled ? 1 : 0.35),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    icon: Icon(icon, color: Colors.white, size: 24),
    style: IconButton.styleFrom(shape: const CircleBorder()),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.controller});

  final YtPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.player;
    return StreamBuilder<Duration>(
      stream: p.stream.position,
      initialData: p.state.position,
      builder: (context, pos) => StreamBuilder<Duration>(
        stream: p.stream.duration,
        initialData: p.state.duration,
        builder: (context, dur) => Text(
          '${formatClock(pos.data ?? Duration.zero)}  /  ${formatClock(dur.data ?? Duration.zero)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.controller, required this.onInteract});

  final YtPlayerController controller;
  final VoidCallback onInteract;

  @override
  Widget build(BuildContext context) {
    final p = controller.player;
    return StreamBuilder<double>(
      stream: p.stream.volume,
      initialData: p.state.volume,
      builder: (context, snap) {
        final v = snap.data ?? 100;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 6),
            _IconAction(
              icon: v == 0 ? Icons.volume_off_rounded : (v < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
              tooltip: v == 0 ? 'Unmute (m)' : 'Mute (m)',
              onTap: () {
                onInteract();
                p.setVolume(v == 0 ? 100 : 0);
              },
            ),
            SizedBox(
              width: 90,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: SliderComponentShape.noOverlay,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  value: v.clamp(0, 100),
                  max: 100,
                  onChanged: (x) {
                    onInteract();
                    p.setVolume(x);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.controller, required this.onInteract});

  final YtPlayerController controller;
  final VoidCallback onInteract;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = widget.controller.player;
    return StreamBuilder<Duration>(
      stream: p.stream.duration,
      initialData: p.state.duration,
      builder: (context, durSnap) {
        final total = (durSnap.data ?? Duration.zero).inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: p.stream.position,
          initialData: p.state.position,
          builder: (context, posSnap) {
            return StreamBuilder<Duration>(
              stream: p.stream.buffer,
              initialData: p.state.buffer,
              builder: (context, bufSnap) {
                final max = total <= 0 ? 1.0 : total;
                final pos = (_drag ?? (posSnap.data ?? Duration.zero).inMilliseconds.toDouble()).clamp(0.0, max);
                final buf = (bufSnap.data ?? Duration.zero).inMilliseconds.toDouble().clamp(0.0, max);
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: _drag == null ? 3 : 5,
                        thumbShape: RoundSliderThumbShape(enabledThumbRadius: _drag == null ? 7 : 9),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                        activeTrackColor: AppColors.lilac,
                        secondaryActiveTrackColor: Colors.white54,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                        overlayColor: AppColors.lilac.withValues(alpha: 0.25),
                        trackShape: const RoundedRectSliderTrackShape(),
                      ),
                      child: Slider(
                        value: pos,
                        secondaryTrackValue: buf,
                        max: max,
                        onChangeStart: total <= 0
                            ? null
                            : (v) {
                                widget.onInteract();
                                setState(() => _drag = v);
                              },
                        onChanged: total <= 0
                            ? null
                            : (v) {
                                widget.onInteract();
                                setState(() => _drag = v);
                              },
                        onChangeEnd: total <= 0
                            ? null
                            : (v) {
                                p.seek(Duration(milliseconds: v.round()));
                                setState(() => _drag = null);
                              },
                      ),
                    ),
                    if (_drag != null)
                      Positioned(
                        bottom: 40,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              formatClock(Duration(milliseconds: _drag!.round())),
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

// ───── Overlays ─────

class _SeekRipple extends StatelessWidget {
  const _SeekRipple({required this.side, required this.seconds});

  final int side;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    final left = side < 0;
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: left ? Alignment.centerLeft : Alignment.centerRight,
          child: FractionallySizedBox(
            widthFactor: 0.38,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: left
                    ? const BorderRadius.horizontal(right: Radius.circular(400))
                    : const BorderRadius.horizontal(left: Radius.circular(400)),
              ),
              child: Center(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(seconds),
                  tween: Tween(begin: 0.8, end: 1),
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutBack,
                  builder: (context, s, child) => Transform.scale(scale: s, child: child),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        left ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$seconds seconds',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BoostPill extends StatelessWidget {
  const _BoostPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(999)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '2×',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
          ),
          SizedBox(width: 4),
          Icon(Icons.fast_forward_rounded, color: Colors.white, size: 18),
        ],
      ),
    );
  }
}

class _LockedLayer extends StatelessWidget {
  const _LockedLayer({required this.visible, required this.onUnlock});

  final bool visible;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RoundButton(
                  icon: Icons.lock_open_rounded,
                  size: 56,
                  primary: true,
                  tooltip: 'Unlock',
                  onTap: onUnlock,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Controls locked · tap to unlock',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BufferingSpinner extends StatelessWidget {
  const _BufferingSpinner({required this.controller});

  final YtPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.player;
    return IgnorePointer(
      child: StreamBuilder<bool>(
        stream: p.stream.buffering,
        initialData: p.state.buffering,
        builder: (context, snap) => AnimatedOpacity(
          opacity: snap.data == true ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: const Center(child: EnergyLoader(size: 52, onColor: true)),
        ),
      ),
    );
  }
}

/// Thumbnail and a loader while yt-dlp finds the streams.
class _Preparing extends StatefulWidget {
  const _Preparing({required this.thumbnail, required this.bare, this.startedAt});

  final String thumbnail;
  final bool bare;

  /// When the stream lookup started: the overlay counts up from there.
  final DateTime? startedAt;

  @override
  State<_Preparing> createState() => _PreparingState();
}

class _PreparingState extends State<_Preparing> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final started = widget.startedAt;
    final seconds = started == null ? 0 : DateTime.now().difference(started).inSeconds;
    final text = seconds < 5
        ? 'Getting the video ready…'
        : seconds < 20
            ? 'Getting the video ready… ${seconds}s'
            : 'YouTube is slow to answer… ${seconds}s';
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(widget.thumbnail, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
          ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const EnergyLoader(size: 52, onColor: true),
                if (!widget.bare) ...[
                  const SizedBox(height: 12),
                  Text(
                    text,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ListenArtwork extends StatelessWidget {
  const _ListenArtwork({required this.thumbnail, required this.title});

  final String thumbnail;
  final String title;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Image.network(thumbnail, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
          LayoutBuilder(
            builder: (context, box) {
              final art = (box.maxHeight * 0.5).clamp(60.0, 220.0);
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: SizedBox(
                        height: art,
                        width: art * 16 / 9,
                        child: Image.network(thumbnail, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                      ),
                    ),
                    if (box.maxHeight > 180) ...[
                      const SizedBox(height: 10),
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.headphones_rounded, color: Colors.white, size: 18),
                          SizedBox(width: 6),
                          Text(
                            'Listening · audio only',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry, this.hint, this.onOpenInBrowser, this.onMinimize});

  final String message;
  final String? hint;
  final VoidCallback onRetry;
  final VoidCallback? onOpenInBrowser;
  final VoidCallback? onMinimize;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.82),
      child: Stack(
        children: [
          if (onMinimize != null)
            Positioned(
              left: 4,
              top: 4,
              child: _IconAction(icon: Icons.keyboard_arrow_down_rounded, tooltip: 'Minimize', onTap: onMinimize!),
            ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded, color: Colors.white, size: 36),
                  const SizedBox(height: 8),
                  Text(
                    hint ?? 'This video won\'t play right now.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                      ),
                      if (onOpenInBrowser != null)
                        OutlinedButton.icon(
                          onPressed: onOpenInBrowser,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white54),
                          ),
                          icon: const Icon(Icons.open_in_browser_rounded),
                          label: const Text('Open the YouTube page'),
                        ),
                    ],
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

class _UpNextCountdown extends StatelessWidget {
  const _UpNextCountdown({required this.controller});

  final YtPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: controller.countdown,
      builder: (context, left, _) {
        final next = controller.nextVideo;
        if (left == null || next == null) return const SizedBox.shrink();
        return ColoredBox(
          color: Colors.black.withValues(alpha: 0.78),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Up next in $left',
                      style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 112,
                            height: 63,
                            child: Image.network(
                              next.thumbnail,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const SizedBox(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            next.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: controller.cancelCountdown,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white38),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () {
                              controller.cancelCountdown();
                              controller.next();
                            },
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Play now'),
                          ),
                        ),
                      ],
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
