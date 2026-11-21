import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/media_notification.dart';
import '../../core/platform/native_bridge.dart';
import '../../services/audio_tags.dart';
import '../../services/lrc.dart';
import '../../services/lyrics_store.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import 'art_palette.dart';

/// Plays a downloaded song or other audio in FetchNet's own player.
Future<void> openAudioPlayer(BuildContext context, {required String path, String? title, String? artUrl}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, _, _) => AudioPlayerScreen(path: path, title: title, artUrl: artUrl),
      transitionsBuilder: (_, a, _, child) {
        final curve = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(curve),
            child: child,
          ),
        );
      },
    ),
  );
}

/// A light, modern audio player: the cover (its colours tint the whole
/// screen) or a music icon on FetchNet's background, synced lyrics that
/// follow the song (tap a line to jump there), a seek bar, buttons to go
/// back or forward a few seconds, speed, loop, a sleep timer and "Open
/// with". Lyrics come from the file itself or a `.lrc` next to it.
class AudioPlayerScreen extends StatefulWidget {
  const AudioPlayerScreen({super.key, required this.path, this.title, this.artUrl});

  final String path;
  final String? title;

  /// The download's thumbnail (a link or a saved picture): the cover when
  /// the file has none inside it.
  final String? artUrl;

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> {
  final Player _player = Player(configuration: const PlayerConfiguration(title: 'FetchNet'));
  final List<StreamSubscription<dynamic>> _subs = [];
  final _focus = FocusNode();
  late final SharedPreferences _store;

  AudioTags _tags = AudioTags.empty;

  /// The cover inside the file, else a picture next to it, else the
  /// download's thumbnail.
  Uint8List? _art;
  Lyrics _lyrics = const Lyrics();
  ArtPalette? _palette;

  /// The synced line playing now (only changes redraw the lyrics).
  final ValueNotifier<int> _line = ValueNotifier(-1);

  bool _showLyrics = false;
  double _rate = 1;
  bool _loop = false;
  int _skip = 10;

  // Sleep timer: a time, or the end of the song.
  Timer? _sleepTimer;
  DateTime? _sleepAt;
  bool _sleepAtEnd = false;

  bool _notified = false;

  String get _title => _tags.title ?? widget.title ?? p.basenameWithoutExtension(widget.path);
  String get _artist => _tags.artist ?? '';

  @override
  void initState() {
    super.initState();
    _store = AppScope.of(context).prefs.store;
    _subs
      ..add(_player.stream.position.listen(_onPosition))
      ..add(_player.stream.playing.listen((_) => _notify()))
      ..add(
        _player.stream.duration.listen((d) {
          _maybeResume(d);
          _notify();
        }),
      )
      ..add(
        _player.stream.completed.listen((done) {
          if (done && _sleepAtEnd) _sleepNow();
        }),
      );
    if (MediaNotification.isSupported) _subs.add(MediaNotification.actions().listen(_onMediaAction));
    // The tags don't wait for libmpv: title, cover and lyrics show at once.
    unawaited(_loadTags());
    unawaited(_start());
  }

  Future<void> _start() async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      // Sound only: libmpv doesn't decode the cover as a video.
      await platform.setProperty('vid', 'no');
      await platform.setProperty('audio-display', 'no');
    }
    unawaited(_player.open(Media(widget.path)));
  }

  Future<void> _loadTags() async {
    final tags = await AudioTags.read(widget.path);
    var lyrics = Lyrics.parse(tags.anyLyrics);
    // A .lrc saved next to the song (FetchNet's "Also keep a .lrc file").
    if (!lyrics.isSynced) {
      try {
        final lrc = File(p.setExtension(widget.path, '.lrc'));
        if (await lrc.exists()) {
          final fromFile = Lyrics.parse(await lrc.readAsString());
          if (!fromFile.isEmpty) lyrics = fromFile;
        }
      } catch (_) {}
    }
    // FetchNet's own copy, kept when the song was downloaded.
    if (!lyrics.isSynced) {
      final kept = Lyrics.parse(await LyricsStore.load(widget.path));
      if (kept.isSynced || lyrics.isEmpty) lyrics = kept.isEmpty ? lyrics : kept;
    }
    if (!mounted) return;
    // Title and lyrics now; the cover's colours fade in a moment later.
    setState(() {
      _tags = tags;
      _lyrics = lyrics;
    });
    _onPosition(_player.state.position);
    final cover = tags.cover ?? await findCover(widget.path, widget.artUrl);
    if (!mounted) return;
    if (cover != null) setState(() => _art = cover);
    _notified = false;
    _notify(force: true);
    final palette = cover == null ? null : await ArtPalette.fromBytes(cover);
    if (mounted && palette != null) setState(() => _palette = palette);
  }

  @override
  void dispose() {
    _savePosition();
    for (final s in _subs) {
      s.cancel();
    }
    _sleepTimer?.cancel();
    _focus.dispose();
    _line.dispose();
    if (MediaNotification.isSupported) unawaited(MediaNotification.stop());
    unawaited(_player.dispose());
    super.dispose();
  }

  // ───── Playback ─────

  void _onPosition(Duration position) {
    if (_lyrics.isSynced) _line.value = _lyrics.indexAt(position + const Duration(milliseconds: 150));
    if ((position - _lastSaved).abs() > const Duration(seconds: 5)) _savePosition();
  }

  Future<void> _seekBy(int seconds) async {
    final d = _player.state.duration;
    var target = _player.state.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (d > Duration.zero && target > d) target = d;
    await _player.seek(target);
    _notify(force: true);
  }

  Future<void> _seekTo(Duration to) async {
    await _player.seek(to);
    _notify(force: true);
  }

  Future<void> _setRate(double r) async {
    setState(() => _rate = r);
    await _player.setRate(r);
    _notify(force: true);
  }

  Future<void> _setLoop(bool v) async {
    setState(() => _loop = v);
    await _player.setPlaylistMode(v ? PlaylistMode.single : PlaylistMode.none);
  }

  Future<void> _openWith() async {
    await _player.pause();
    final ok = await NativeBridge.openWith(widget.path);
    if (!ok && mounted) showSnack(context, 'No app found to open this file.', kind: ToastKind.error);
  }

  // ───── Sleep timer ─────

  void _setSleep(Duration? after, {bool endOfSong = false}) {
    _sleepTimer?.cancel();
    setState(() {
      _sleepAtEnd = endOfSong;
      _sleepAt = after == null ? null : DateTime.now().add(after);
    });
    if (after != null) _sleepTimer = Timer(after, _sleepNow);
  }

  void _sleepNow() {
    _player.pause();
    if (!mounted) return;
    setState(() {
      _sleepAt = null;
      _sleepAtEnd = false;
    });
    showSnack(context, 'Sleep timer: paused');
  }

  String get _sleepLabel {
    if (_sleepAtEnd) return 'End of song';
    final at = _sleepAt;
    if (at == null) return 'Off';
    final left = at.difference(DateTime.now());
    return left.isNegative ? 'Off' : '${(left.inSeconds / 60).ceil()} min left';
  }

  // ───── Media notification (Android) ─────

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  void _notify({bool force = false}) {
    if (!MediaNotification.isSupported || !mounted) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastNotify) < const Duration(milliseconds: 300)) return;
    _lastNotify = now;
    final s = _player.state;
    unawaited(
      MediaNotification.update(
        title: _title,
        artist: _artist.isEmpty ? 'FetchNet' : _artist,
        duration: s.duration,
        position: s.position,
        playing: s.playing,
        speed: s.rate,
        canPrevious: false,
        canNext: false,
        art: _notified ? null : _art,
        keepArt: _notified,
      ),
    );
    _notified = true;
  }

  void _onMediaAction(MediaAction a) {
    switch (a.action) {
      case 'play':
        _player.play();
      case 'pause':
        _player.pause();
      case 'seek':
        if (a.positionMs != null) _seekTo(Duration(milliseconds: a.positionMs!));
      case 'next':
        _seekBy(_skip);
      case 'previous':
        _seekBy(-_skip);
      case 'stop':
        if (mounted) Navigator.of(context).maybePop();
    }
  }

  // ───── Resume long audio (podcasts, mixes) ─────

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
    if (_resumeChecked || duration < const Duration(minutes: 10) || !mounted) return;
    _resumeChecked = true;
    final ms = (_positions()[widget.path] as num?)?.toInt();
    if (ms == null) return;
    final at = Duration(milliseconds: ms);
    if (at < const Duration(seconds: 10) || at > duration - const Duration(seconds: 10)) return;
    _player.seek(at);
    showSnack(context, 'Resumed at ${formatDuration(at.inSeconds)}', actionLabel: 'Start over', onAction: () => _player.seek(Duration.zero));
  }

  void _savePosition() {
    final position = _player.state.position;
    final duration = _player.state.duration;
    _lastSaved = position;
    if (duration < const Duration(minutes: 10)) return;
    try {
      final map = _positions()..remove(widget.path);
      if (position < duration - const Duration(seconds: 10)) map[widget.path] = position.inMilliseconds;
      while (map.length > 100) {
        map.remove(map.keys.first);
      }
      unawaited(_store.setString(_kPositions, jsonEncode(map)));
    } catch (_) {}
  }

  // ───── Keyboard ─────

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      if (e is KeyDownEvent) _player.playOrPause();
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      _seekBy(-_skip);
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      _seekBy(_skip);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _player.setVolume((_player.state.volume + 5).clamp(0, 100));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _player.setVolume((_player.state.volume - 5).clamp(0, 100));
    } else if (key == LogicalKeyboardKey.keyY && e is KeyDownEvent) {
      setState(() => _showLyrics = !_showLyrics);
    } else if (key == LogicalKeyboardKey.escape && e is KeyDownEvent) {
      Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ───── Layout ─────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = _palette;
    final art = palette != null;
    final colors = _Colors(
      fg: art ? Colors.white : scheme.onSurface,
      muted: art ? Colors.white.withValues(alpha: 0.62) : scheme.onSurfaceVariant,
      accent: art ? palette.accent : scheme.primary,
      art: art,
    );
    final darkChrome = art || theme.brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkChrome ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // FetchNet's background, and the cover's colours over it once
              // known (a gentle fade, no jump).
              const AuroraBackground(intensity: 0.9, child: SizedBox.expand()),
              AnimatedOpacity(
                opacity: art ? 1 : 0,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [palette?.top ?? Colors.black, palette?.bottom ?? Colors.black],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, c) {
                    final wide = c.maxWidth >= 760 && c.maxWidth > c.maxHeight * 1.05;
                    return wide ? _wideLayout(colors, c) : _compactLayout(colors, c);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(_Colors colors, {bool lyricsButton = true}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.keyboard_arrow_down_rounded, color: colors.fg, size: 30),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  'NOW PLAYING',
                  style: TextStyle(color: colors.muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4),
                ),
                const SizedBox(height: 2),
                Text(
                  _tags.album ?? 'FetchNet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.fg, fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ],
            ),
          ),
          if (lyricsButton)
            IconButton(
              tooltip: _showLyrics ? 'Cover' : 'Lyrics',
              onPressed: () => setState(() => _showLyrics = !_showLyrics),
              icon: Icon(_showLyrics ? Icons.album_rounded : Icons.lyrics_outlined, color: colors.fg),
            )
          else
            const SizedBox(width: 48),
          IconButton(
            tooltip: 'More',
            onPressed: () => _openMenu(colors),
            icon: Icon(Icons.more_vert_rounded, color: colors.fg),
          ),
        ],
      ),
    );
  }

  Widget _compactLayout(_Colors colors, BoxConstraints c) {
    return Column(
      children: [
        _topBar(colors),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(a), child: child),
            ),
            child: _showLyrics
                ? _LyricsView(key: const ValueKey('lyrics'), lyrics: _lyrics, line: _line, colors: colors, onSeek: _seekTo)
                : Padding(
                    key: const ValueKey('art'),
                    padding: const EdgeInsets.fromLTRB(28, 12, 28, 8),
                    child: Column(
                      children: [
                        Expanded(child: Center(child: _cover(colors))),
                        if (_lyrics.isSynced) _CurrentLine(lyrics: _lyrics, line: _line, colors: colors, onTap: () => setState(() => _showLyrics = true)),
                      ],
                    ),
                  ),
          ),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(24, 4, 24, 12), child: _details(colors)),
      ],
    );
  }

  Widget _wideLayout(_Colors colors, BoxConstraints c) {
    return Column(
      children: [
        _topBar(colors, lyricsButton: false),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 8, 40, 24),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      Expanded(child: Center(child: _cover(colors))),
                      const SizedBox(height: 18),
                      _details(colors),
                    ],
                  ),
                ),
                const SizedBox(width: 40),
                Expanded(
                  flex: 6,
                  child: _LyricsView(lyrics: _lyrics, line: _line, colors: colors, onSeek: _seekTo),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The cover, a little smaller while paused; or a music note on
  /// FetchNet's gradient.
  Widget _cover(_Colors colors) {
    final cover = _art;
    return StreamBuilder<bool>(
      stream: _player.stream.playing,
      initialData: _player.state.playing,
      builder: (context, snap) => AnimatedScale(
        scale: snap.data == true ? 1 : 0.9,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 440),
          child: AspectRatio(
            aspectRatio: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: (colors.art ? Colors.black : colors.accent).withValues(alpha: colors.art ? 0.45 : 0.3),
                    blurRadius: 40,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: cover != null
                      ? Image.memory(cover, key: const ValueKey('cover'), fit: BoxFit.cover, gaplessPlayback: true)
                      : const DecoratedBox(
                          key: ValueKey('note'),
                          decoration: BoxDecoration(gradient: AppColors.brandGradient),
                          child: Center(
                            child: FractionallySizedBox(
                              widthFactor: 0.42,
                              heightFactor: 0.42,
                              child: FittedBox(child: Icon(Icons.music_note_rounded, color: Colors.white)),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Title, artist, the seek bar and the buttons.
  Widget _details(_Colors colors) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.fg, fontSize: 22, fontWeight: FontWeight.w900, height: 1.2, letterSpacing: -0.3),
          ),
          if (_artist.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.muted, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 14),
          _SeekBar(player: _player, colors: colors, onSeek: _seekTo),
          const SizedBox(height: 6),
          _ControlsRow(
            player: _player,
            colors: colors,
            skip: _skip,
            rate: _rate,
            loop: _loop,
            sleeping: _sleepAt != null || _sleepAtEnd,
            onSkip: (forward) => _seekBy(forward ? _skip : -_skip),
            onSpeed: () => _openMenu(colors),
            onLoop: () => _setLoop(!_loop),
            onSleep: () => _openMenu(colors, sleep: true),
          ),
        ],
      ),
    );
  }

  // ───── ⋮ menu ─────

  void _openMenu(_Colors colors, {bool sleep = false}) {
    final panel = colors.art ? Color.lerp(_palette!.bottom, Colors.black, 0.15)! : Theme.of(context).colorScheme.surfaceContainer;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, refresh) {
          void apply(VoidCallback change) {
            change();
            refresh(() {});
          }

          Widget label(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
            child: Text(
              t.toUpperCase(),
              style: TextStyle(color: colors.muted, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.1),
            ),
          );
          Widget chips<T>(List<(T, String)> items, T selected, ValueChanged<T> onPick) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final (v, text) in items) _Chip(text: text, selected: v == selected, colors: colors, onTap: () => apply(() => onPick(v)))],
          );
          return Padding(
            padding: EdgeInsets.fromLTRB(10, 0, 10, 10 + MediaQuery.paddingOf(sheet).bottom),
            child: Material(
              color: panel,
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(color: colors.muted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(99)),
                      ),
                    ),
                    if (!sleep) ...[
                      label('Speed'),
                      chips<double>(
                        [
                          for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]) (r, r == 1 ? '1×' : '${r.toString().replaceAll(RegExp(r'\.0$'), '')}×'),
                        ],
                        _rate,
                        _setRate,
                      ),
                      label('Skip with the arrows'),
                      chips<int>(
                        [
                          for (final s in const [5, 10, 15, 30]) (s, '$s s'),
                        ],
                        _skip,
                        (s) => setState(() => _skip = s),
                      ),
                    ],
                    label('Sleep timer · $_sleepLabel'),
                    chips<int>(
                      [(0, 'Off'), (15, '15 min'), (30, '30 min'), (45, '45 min'), (60, '1 hour'), (-1, 'End of song')],
                      _sleepAtEnd ? -1 : (_sleepAt == null ? 0 : -2),
                      (m) => m == 0 ? _setSleep(null) : (m < 0 ? _setSleep(null, endOfSong: true) : _setSleep(Duration(minutes: m))),
                    ),
                    if (!sleep) ...[
                      const SizedBox(height: 16),
                      _MenuRow(
                        icon: _loop ? Icons.repeat_one_on_rounded : Icons.repeat_one_rounded,
                        title: 'Loop',
                        value: _loop ? 'On' : 'Off',
                        colors: colors,
                        onTap: () => apply(() => _setLoop(!_loop)),
                      ),
                      _MenuRow(
                        icon: Icons.info_outline_rounded,
                        title: 'File',
                        value: p.basename(widget.path),
                        colors: colors,
                        onTap: () {
                          Navigator.pop(sheet);
                          _showInfo(colors, panel);
                        },
                      ),
                      _MenuRow(
                        icon: Icons.open_in_new_rounded,
                        title: 'Open with',
                        value: 'Play it in another app',
                        colors: colors,
                        onTap: () {
                          Navigator.pop(sheet);
                          _openWith();
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showInfo(_Colors colors, Color panel) {
    String size() {
      try {
        return formatBytes(File(widget.path).lengthSync());
      } catch (_) {
        return '—';
      }
    }

    final rows = <(String, String)>[
      ('Title', _title),
      if (_tags.artist != null) ('Artist', _tags.artist!),
      if (_tags.album != null) ('Album', _tags.album!),
      ('Length', formatDuration(_player.state.duration.inSeconds)),
      ('Size', size()),
      ('Lyrics', _lyrics.isSynced ? 'Synced' : (_lyrics.isEmpty ? 'None' : 'Plain text')),
      ('File', widget.path),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(10, 0, 10, 10 + MediaQuery.paddingOf(sheet).bottom),
        child: Material(
          color: panel,
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (k, v) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 80,
                          child: Text(k, style: TextStyle(color: colors.muted)),
                        ),
                        Expanded(
                          child: SelectableText(
                            v,
                            style: TextStyle(color: colors.fg, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A cover for a song without one inside: a picture saved next to it
/// ("Song.jpg", "cover.jpg", "folder.jpg"), else [artUrl] — the download's
/// thumbnail, fetched once and kept in the app's cache for offline plays.
Future<Uint8List?> findCover(String songPath, String? artUrl) async {
  Future<Uint8List?> read(File f) async {
    try {
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      return bytes.length > 32 ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  final dir = p.dirname(songPath);
  final base = p.basenameWithoutExtension(songPath);
  for (final name in [
    for (final ext in const ['.jpg', '.jpeg', '.png', '.webp']) '$base$ext',
    'cover.jpg',
    'cover.png',
    'folder.jpg',
  ]) {
    final bytes = await read(File(p.join(dir, name)));
    if (bytes != null) return bytes;
  }
  final url = artUrl?.trim();
  if (url == null || url.isEmpty) return null;
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return read(File(url.startsWith('file://') ? Uri.parse(url).toFilePath() : url));
  }
  File? cached;
  try {
    final cache = Directory(p.join((await getApplicationCacheDirectory()).path, 'covers'));
    cached = File(p.join(cache.path, md5.convert(url.codeUnits).toString()));
    final hit = await read(cached);
    if (hit != null) return hit;
  } catch (_) {}
  final client = HttpClient()
    ..userAgent = 'FetchNet'
    ..connectionTimeout = const Duration(seconds: 8);
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 12))) {
      builder.add(chunk);
      if (builder.length > 8 * 1024 * 1024) return null;
    }
    final bytes = builder.takeBytes();
    if (bytes.length < 64) return null;
    try {
      await cached?.parent.create(recursive: true);
      await cached?.writeAsBytes(bytes, flush: true);
    } catch (_) {}
    return bytes;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// The screen's colours: from the cover, or the app's theme without one.
class _Colors {
  const _Colors({required this.fg, required this.muted, required this.accent, required this.art});

  final Color fg;
  final Color muted;
  final Color accent;

  /// Coloured from a cover (dark background, white text).
  final bool art;

  /// Text / icons on [accent].
  Color get onAccent => art ? Colors.black.withValues(alpha: 0.85) : Colors.white;
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player, required this.colors, required this.onSeek});

  final Player player;
  final _Colors colors;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final player = widget.player;
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, _) {
        final total = player.state.duration.inMilliseconds.toDouble();
        final max = total <= 0 ? 1.0 : total;
        final pos = (_dragging ?? player.state.position.inMilliseconds.toDouble()).clamp(0.0, max);
        TextStyle time() => TextStyle(color: c.muted, fontSize: 12.5, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]);
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: _dragging == null ? 5 : 8,
                activeTrackColor: c.accent,
                inactiveTrackColor: c.fg.withValues(alpha: 0.16),
                thumbColor: c.art ? Colors.white : c.accent,
                overlayColor: c.accent.withValues(alpha: 0.18),
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: _dragging == null ? 6 : 9),
                trackShape: const RoundedRectSliderTrackShape(),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
              ),
              child: Slider(
                value: pos,
                max: max,
                onChangeStart: (v) => setState(() => _dragging = v),
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) {
                  widget.onSeek(Duration(milliseconds: v.round()));
                  setState(() => _dragging = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(
                children: [
                  Text(_clock(pos ~/ 1000), style: time()),
                  const Spacer(),
                  Text(total <= 0 ? '--:--' : '-${_clock(((max - pos) / 1000).round())}', style: time()),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "0:00", "3:07", "1:02:03".
String _clock(int seconds) => seconds <= 0 ? '0:00' : formatDuration(seconds);

/// Loop · back N seconds · play / pause · forward N seconds · speed /
/// sleep.
class _ControlsRow extends StatelessWidget {
  const _ControlsRow({
    required this.player,
    required this.colors,
    required this.skip,
    required this.rate,
    required this.loop,
    required this.sleeping,
    required this.onSkip,
    required this.onSpeed,
    required this.onLoop,
    required this.onSleep,
  });

  final Player player;
  final _Colors colors;
  final int skip;
  final double rate;
  final bool loop;
  final bool sleeping;
  final ValueChanged<bool> onSkip;
  final VoidCallback onSpeed;
  final VoidCallback onLoop;
  final VoidCallback onSleep;

  static IconData _skipIcon(bool forward, int s) => switch ((forward, s)) {
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
    final c = colors;
    Widget small(IconData icon, String tip, VoidCallback onTap, {bool on = false}) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, color: on ? c.accent : c.muted),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        small(loop ? Icons.repeat_one_on_rounded : Icons.repeat_one_rounded, loop ? 'Loop: on' : 'Loop', onLoop, on: loop),
        IconButton(
          tooltip: 'Back $skip seconds',
          iconSize: 34,
          onPressed: () => onSkip(false),
          icon: Icon(_skipIcon(false, skip), color: c.fg),
        ),
        StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, snap) {
            final playing = snap.data ?? false;
            return Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.art ? c.accent : null,
                  gradient: c.art ? null : AppColors.brandGradient,
                  boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.4), blurRadius: 26, offset: const Offset(0, 8))],
                ),
                child: InkWell(
                  onTap: player.playOrPause,
                  child: SizedBox(
                    width: 76,
                    height: 76,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                      child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(playing), color: c.onAccent, size: 42),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'Forward $skip seconds',
          iconSize: 34,
          onPressed: () => onSkip(true),
          icon: Icon(_skipIcon(true, skip), color: c.fg),
        ),
        rate != 1
            ? TextButton(
                onPressed: onSpeed,
                style: TextButton.styleFrom(foregroundColor: c.accent, minimumSize: const Size(48, 48)),
                child: Text('${rate.toString().replaceAll(RegExp(r'\.0$'), '')}×', style: const TextStyle(fontWeight: FontWeight.w900)),
              )
            : small(sleeping ? Icons.bedtime_rounded : Icons.bedtime_outlined, 'Sleep timer', onSleep, on: sleeping),
      ],
    );
  }
}

/// The line being sung, under the cover (tap: all lyrics).
class _CurrentLine extends StatelessWidget {
  const _CurrentLine({required this.lyrics, required this.line, required this.colors, required this.onTap});

  final Lyrics lyrics;
  final ValueNotifier<int> line;
  final _Colors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: line,
      builder: (context, i, _) {
        final text = i >= 0 && i < lyrics.synced.length ? lyrics.synced[i].text : '';
        return GestureDetector(
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                child: text.isEmpty
                    ? Icon(Icons.graphic_eq_rounded, key: ValueKey(i), color: colors.muted, size: 22)
                    : Text(
                        text,
                        key: ValueKey(i),
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.fg, fontSize: 16, fontWeight: FontWeight.w800, height: 1.3),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// All the lyrics: synced ones follow the song (the current line big and
/// bright, kept near the middle; tap a line to jump there). Scrolling by
/// hand pauses the following for a few seconds.
class _LyricsView extends StatefulWidget {
  const _LyricsView({super.key, required this.lyrics, required this.line, required this.colors, required this.onSeek});

  final Lyrics lyrics;
  final ValueNotifier<int> line;
  final _Colors colors;
  final ValueChanged<Duration> onSeek;

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  final _scroll = ScrollController();
  List<GlobalKey> _keys = const [];
  DateTime _userScrolledAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _keys = [for (var i = 0; i < widget.lyrics.synced.length; i++) GlobalKey()];
    widget.line.addListener(_follow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow(jump: true));
  }

  @override
  void didUpdateWidget(_LyricsView old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _keys = [for (var i = 0; i < widget.lyrics.synced.length; i++) GlobalKey()];
    }
    if (old.line != widget.line) {
      old.line.removeListener(_follow);
      widget.line.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.line.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  void _follow({bool jump = false}) {
    if (DateTime.now().difference(_userScrolledAt) < const Duration(seconds: 4)) return;
    final i = widget.line.value;
    if (i < 0 || i >= _keys.length) return;
    final ctx = _keys[i].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, alignment: 0.4, duration: jump ? Duration.zero : const Duration(milliseconds: 520), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final lyrics = widget.lyrics;
    if (lyrics.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lyrics_outlined, size: 48, color: c.muted),
              const SizedBox(height: 12),
              Text(
                'No lyrics for this song',
                style: TextStyle(color: c.fg, fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'Turn on "Add lyrics to music" in Settings › Extra Settings, and songs you download get synced lyrics.',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted, height: 1.4),
              ),
            ],
          ),
        ),
      );
    }
    if (!lyrics.isSynced) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
        child: Text(
          lyrics.plain!,
          style: TextStyle(color: c.fg, fontSize: 18, fontWeight: FontWeight.w700, height: 1.6),
        ),
      );
    }
    return NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        _userScrolledAt = DateTime.now();
        return false;
      },
      child: ShaderMask(
        // The lines fade out at the top and bottom edges.
        shaderCallback: (r) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
          stops: [0, 0.1, 0.88, 1],
        ).createShader(r),
        blendMode: BlendMode.dstIn,
        child: ValueListenableBuilder<int>(
          valueListenable: widget.line,
          builder: (context, current, _) => SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(28, 140, 28, 220),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, l) in lyrics.synced.indexed)
                  KeyedSubtree(
                    key: _keys[i],
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _userScrolledAt = DateTime.fromMillisecondsSinceEpoch(0);
                        widget.onSeek(l.time);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOut,
                          style: DefaultTextStyle.of(context).style.merge(
                            TextStyle(
                              color: i == current ? c.fg : c.fg.withValues(alpha: i < current ? 0.32 : 0.45),
                              fontSize: i == current ? 26 : 22,
                              fontWeight: FontWeight.w800,
                              height: 1.3,
                              letterSpacing: -0.3,
                            ),
                          ),
                          child: l.text.isEmpty
                              ? Align(
                                  alignment: Alignment.centerLeft,
                                  child: Icon(Icons.more_horiz_rounded, color: c.fg.withValues(alpha: i == current ? 1 : 0.45), size: 30),
                                )
                              : Text(l.text),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.selected, required this.colors, required this.onTap});

  final String text;
  final bool selected;
  final _Colors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Material(
      color: selected ? c.accent : c.fg.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          child: Text(
            text,
            style: TextStyle(color: selected ? c.onAccent : c.fg, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.title, required this.value, required this.colors, required this.onTap});

  final IconData icon;
  final String title;
  final String value;
  final _Colors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: c.fg.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Icon(icon, color: c.fg),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(color: c.fg, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.muted, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: c.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
