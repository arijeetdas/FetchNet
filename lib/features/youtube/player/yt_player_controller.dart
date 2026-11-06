import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show BoxFit;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/platform/media_notification.dart';
import '../../../models/youtube_models.dart';
import '../../../services/fetch_service.dart';
import '../../../services/youtube_client.dart';
import '../../../services/youtube_service.dart';
import '../../../services/youtube_streams.dart';

/// Playback speeds offered by the player.
const kPlaybackSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

/// The YouTube player: plays yt-dlp's streams (so no ads), and holds what the
/// watch page shows (details, "Up next", history for Previous).
///
/// One instance lives as long as FetchNet's YouTube view, so the mini player
/// and the watch page show the same playback.
class YtPlayerController extends ChangeNotifier {
  YtPlayerController(this._youtube, this._resolver);

  final YouTubeService _youtube;
  final YtStreamResolver _resolver;
  YouTubeClient get _client => _youtube.client;

  /// libmpv starts with the first video, not when the YouTube view opens.
  Player get player => _player ??= _createPlayer();
  Player? _player;
  late final VideoController video = VideoController(player);
  final List<StreamSubscription<dynamic>> _subs = [];

  Player _createPlayer() {
    final p = Player(
      configuration: const PlayerConfiguration(title: 'FetchNet', bufferSize: 64 * 1024 * 1024),
    );
    _subs.add(
      p.stream.completed.listen((done) {
        if (done) _onCompleted();
      }),
    );
    _subs.add(
      p.stream.error.listen((e) {
        // A stream URL that stopped working: look the video up again once.
        if (_id != null && !_retriedStreams && streams != null && e.toLowerCase().contains('http')) {
          _retriedStreams = true;
          unawaited(_loadStreams(_id!, _token, start: p.state.position, refresh: true));
        }
      }),
    );
    _subs.add(p.stream.position.listen(_maybePrefetch));
    if (MediaNotification.isSupported) {
      _subs.addAll([
        p.stream.playing.listen((_) => _syncMedia()),
        p.stream.duration.listen((_) => _syncMedia()),
        p.stream.rate.listen((_) => _syncMedia()),
        p.stream.position.listen(_onPositionForMedia),
        MediaNotification.actions().listen(_onMediaAction),
      ]);
    }
    return p;
  }

  // ───── Media notification (Android) ─────

  Timer? _mediaTimer;
  bool _mediaShown = false;
  String? _artFor;
  Uint8List? _art;
  bool _artSent = false;
  Duration _mediaPos = Duration.zero;
  DateTime _mediaAt = DateTime.now();
  bool _mediaPlaying = false;

  /// Coalesces changes into one notification update.
  void _syncMedia() {
    if (!MediaNotification.isSupported || _disposed) return;
    _mediaTimer?.cancel();
    _mediaTimer = Timer(const Duration(milliseconds: 80), _pushMedia);
  }

  Future<void> _pushMedia() async {
    final p = _player;
    final id = _id;
    if (id == null || p == null) {
      if (_mediaShown) {
        _mediaShown = false;
        await MediaNotification.stop();
      }
      return;
    }
    if (_artFor != id) {
      _artFor = id;
      _art = null;
      _artSent = false;
      unawaited(_loadArt(id));
    }
    final sendArt = _art != null && !_artSent;
    final s = p.state;
    _mediaPos = s.position;
    _mediaAt = DateTime.now();
    _mediaPlaying = s.playing;
    _mediaShown = true;
    await MediaNotification.update(
      title: title.isEmpty ? 'YouTube' : title,
      artist: channel ?? 'YouTube',
      duration: s.duration,
      position: s.position,
      playing: s.playing,
      speed: s.rate,
      // Previous always works: it restarts the video when there's no history.
      canPrevious: true,
      canNext: nextVideo != null,
      art: sendArt ? _art : null,
      keepArt: _artSent,
    );
    if (sendArt) _artSent = true;
  }

  /// A small 16:9 thumbnail for the notification and lock screen.
  Future<void> _loadArt(String id) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await http.getUrl(Uri.parse('https://i.ytimg.com/vi/$id/mqdefault.jpg'));
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return;
      final bytes = await consolidateHttpClientResponseBytes(res);
      if (_artFor != id || _disposed) return;
      _art = bytes;
      _syncMedia();
    } catch (_) {
    } finally {
      http.close(force: true);
    }
  }

  /// Seeks show up on the lock screen bar; normal playback the system
  /// extrapolates by itself.
  void _onPositionForMedia(Duration pos) {
    if (!_mediaShown) return;
    final expected = _mediaPlaying
        ? _mediaPos + DateTime.now().difference(_mediaAt) * (_player?.state.rate ?? 1)
        : _mediaPos;
    if ((pos - expected).inMilliseconds.abs() > 2000) _syncMedia();
  }

  void _onMediaAction(MediaAction a) {
    final p = _player;
    if (p == null || _id == null) return;
    switch (a.action) {
      case 'play':
        if (!p.state.playing) playPause();
      case 'pause':
        p.pause();
      case 'next':
        next();
      case 'previous':
        previous();
      case 'seek':
        p.seek(Duration(milliseconds: a.positionMs ?? 0));
      case 'stop':
        close();
    }
  }

  String? _id;
  YtVideo? _preview;
  int _token = 0;
  bool _retriedStreams = false;
  bool _disposed = false;

  // ───── Details ─────
  YtWatchInfo? info;
  bool infoLoading = false;
  String? infoError;
  List<YtVideo> related = const [];
  String? _relatedToken;
  bool loadingMore = false;

  // ───── Streams ─────
  YtStreams? streams;
  YtStream? currentVideo;
  bool resolving = false;

  /// When the current stream lookup started (the player shows how long it's taking).
  DateTime? lookupStartedAt;

  /// The video whose lookup this controller waits for, and the "Up next"
  /// video looked up ahead of time. Both are released when no longer needed,
  /// which stops their yt-dlp runs.
  String? _awaiting;
  String? _prefetchId;

  void _releaseAwaited() {
    final id = _awaiting;
    _awaiting = null;
    if (id != null) _resolver.release(id);
  }

  void _releasePrefetch() {
    final id = _prefetchId;
    _prefetchId = null;
    if (id != null) _resolver.release(id);
  }

  /// With autoplay on, the next video's streams are looked up while this one
  /// plays, so it starts right away.
  void _maybePrefetch(Duration position) {
    if (position < const Duration(seconds: 15) || !autoplay || streams == null || _disposed) return;
    final next = nextVideo;
    if (next == null || next.id == _prefetchId || _resolver.cached(next.id) != null) return;
    _releasePrefetch();
    _prefetchId = next.id;
    _resolver.resolve(next.id).then<void>((_) {}, onError: (Object _) {});
  }
  String? streamError;
  String? streamHint;

  // ───── Options ─────
  bool listenOnly = false;
  bool loop = false;
  double speed = 1;
  BoxFit fit = BoxFit.contain;

  /// Videos played before the current one (Previous steps back).
  final List<YtVideo> _history = [];

  /// Seconds left before "Up next" plays, while counting down.
  final ValueNotifier<int?> countdown = ValueNotifier(null);
  Timer? _countdownTimer;

  DateTime? sleepAt;
  bool sleepAtEnd = false;
  Timer? _sleepTimer;

  String? get videoId => _id;
  bool get hasVideo => _id != null;
  bool get hasPrevious => _history.isNotEmpty;
  bool get autoplay => _youtube.autoplay;
  bool get qualityAuto => _youtube.quality <= 0;

  YtVideo? get nextVideo => related.isEmpty ? null : related.first;

  String get title => info?.title ?? _preview?.title ?? '';
  String? get channel => info?.channel ?? _preview?.channel;
  String get thumbnail => _preview?.thumbnail ?? 'https://i.ytimg.com/vi/$_id/hqdefault.jpg';
  YtVideo? get preview => _preview;
  String get watchUrl => 'https://www.youtube.com/watch?v=$_id';

  /// Video size for the PiP window.
  ({int width, int height}) get aspect {
    final w = player.state.width ?? currentVideo?.width ?? 16;
    final h = player.state.height ?? currentVideo?.height ?? 9;
    return (width: w > 0 ? w : 16, height: h > 0 ? h : 9);
  }

  /// Automatic quality: sharp enough without wasting data.
  static int get _autoHeight => (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ? 720 : 1080;

  YtVideo get _asCard => YtVideo(
    id: _id!,
    title: title,
    thumbnail: thumbnail,
    channel: channel,
    channelAvatar: info?.channelAvatar ?? _preview?.channelAvatar,
    views: info?.views ?? _preview?.views,
    published: info?.published ?? _preview?.published,
  );

  void _notify() {
    if (_disposed) return;
    notifyListeners();
    _syncMedia();
  }

  // ───── Opening videos ─────

  /// Plays [id]. Does nothing when it's already the current video.
  Future<void> open(String id, {YtVideo? preview, bool recordHistory = true}) async {
    if (id == _id) {
      if (!player.state.playing && streams != null && player.state.completed) await player.seek(Duration.zero);
      return;
    }
    if (recordHistory && _id != null) {
      _history.remove(_history.where((v) => v.id == id).firstOrNull);
      _history.add(_asCard);
      if (_history.length > 50) _history.removeAt(0);
    }
    cancelCountdown();
    // Stop looking up a video the user has moved on from.
    _releaseAwaited();
    if (_prefetchId != id) _releasePrefetch();
    final token = ++_token;
    _id = id;
    _preview = preview;
    _retriedStreams = false;
    info = null;
    infoError = null;
    infoLoading = true;
    related = const [];
    _relatedToken = null;
    streams = null;
    currentVideo = null;
    streamError = null;
    streamHint = null;
    _notify();
    unawaited(player.stop());
    unawaited(_loadInfo(id, token));
    await _loadStreams(id, token);
  }

  /// Loads the details and streams of the current video again.
  Future<void> retry() async {
    final id = _id;
    if (id == null) return;
    final token = ++_token;
    if (info == null) {
      infoLoading = true;
      infoError = null;
      unawaited(_loadInfo(id, token));
    }
    await _loadStreams(id, token, refresh: true);
  }

  Future<void> _loadInfo(String id, int token) async {
    try {
      final i = await _client.watch(id);
      if (token != _token) return;
      info = i;
      related = i.related.where((v) => !v.isShort).toList();
      _relatedToken = i.relatedContinuation;
      _preview ??= YtVideo(
        id: id,
        title: i.title,
        thumbnail: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
        channel: i.channel,
      );
    } on YtException catch (e) {
      if (token == _token) infoError = e.message;
    } finally {
      if (token == _token) {
        infoLoading = false;
        _notify();
      }
    }
  }

  Future<void> loadMoreRelated() async {
    final t = _relatedToken;
    if (t == null || loadingMore || infoLoading) return;
    final token = _token;
    loadingMore = true;
    _notify();
    try {
      final page = await _client.more(YtFeedKind.related, t);
      if (token != _token) return;
      final known = {...related.map((v) => v.id), ?_id};
      related = [...related, ...page.items.where((v) => !v.isShort && known.add(v.id))];
      _relatedToken = page.continuation;
    } on YtException {
      if (token == _token) _relatedToken = null;
    } finally {
      if (token == _token) {
        loadingMore = false;
        _notify();
      }
    }
  }

  bool get canLoadMoreRelated => _relatedToken != null;

  Future<void> _loadStreams(String id, int token, {Duration start = Duration.zero, bool refresh = false}) async {
    resolving = true;
    streamError = null;
    streamHint = null;
    lookupStartedAt = DateTime.now();
    _notify();
    _releaseAwaited();
    final lookup = _resolver.resolve(id, refresh: refresh);
    _awaiting = id;
    if (_prefetchId == id) {
      // Adopt the look-ahead lookup: one waiter is enough.
      _prefetchId = null;
      _resolver.release(id);
    }
    try {
      final s = await lookup;
      if (token != _token) return;
      streams = s;
      currentVideo = s.videoFor(_youtube.quality, auto: _autoHeight);
      await _play(start: start);
    } on FetchException catch (e) {
      if (token != _token || e.cancelled) return;
      streamError = e.message;
      streamHint = e.hint;
    } catch (e) {
      if (token != _token) return;
      streamError = '$e';
    } finally {
      if (token == _token) {
        if (_awaiting == id) _awaiting = null;
        resolving = false;
        _notify();
      }
    }
  }

  /// Opens the right streams: video + the separate audio track, the audio
  /// alone (Listen only) or a combined stream as a fallback.
  Future<void> _play({Duration start = Duration.zero, bool autoPlay = true}) async {
    final s = streams;
    if (s == null) return;
    final audio = s.audio;
    YtStream? main;
    YtStream? extraAudio;
    if (listenOnly && audio != null) {
      main = audio;
    } else {
      main = currentVideo ?? s.muxed ?? audio;
      if (main != null && !main.hasAudio && audio != null) extraAudio = audio;
    }
    if (main == null) return;
    final native = player.platform is NativePlayer ? player.platform as NativePlayer : null;
    try {
      // Loaded with the file, so audio starts in sync with the picture.
      await native?.command(['change-list', 'audio-files', 'clr', '']);
      if (extraAudio != null) await native?.command(['change-list', 'audio-files', 'append', extraAudio.url]);
    } catch (_) {}
    await player.open(
      Media(main.url, httpHeaders: main.headers, start: start > Duration.zero ? start : null),
      play: autoPlay,
    );
    await player.setRate(speed);
    await player.setPlaylistMode(loop ? PlaylistMode.single : PlaylistMode.none);
  }

  /// Reopens the streams at the current position (quality / listen only).
  Future<void> _reopen() async {
    final pos = player.state.position;
    final playing = player.state.playing || player.state.buffering;
    await _play(start: pos, autoPlay: playing);
    _notify();
  }

  // ───── Options ─────

  /// [stream] `null` = automatic.
  Future<void> setQuality(YtStream? stream) async {
    await _youtube.setQuality(stream?.resolution ?? 0);
    currentVideo = stream ?? streams?.videoFor(0, auto: _autoHeight);
    _notify();
    if (!listenOnly) await _reopen();
  }

  /// Resolution [qualityAuto] would pick, for the menu.
  YtStream? get autoStream => streams?.videoFor(0, auto: _autoHeight);

  Future<void> setListenOnly(bool value) async {
    if (value == listenOnly) return;
    listenOnly = value;
    _notify();
    if (streams != null) await _reopen();
  }

  Future<void> setSpeed(double value) async {
    speed = value;
    _notify();
    await player.setRate(value);
  }

  Future<void> setLoop(bool value) async {
    loop = value;
    _notify();
    await player.setPlaylistMode(value ? PlaylistMode.single : PlaylistMode.none);
  }

  void setFit(BoxFit value) {
    fit = value;
    _notify();
  }

  void toggleFit() => setFit(fit == BoxFit.contain ? BoxFit.cover : BoxFit.contain);

  Future<void> setAutoplay(bool value) async {
    await _youtube.setAutoplay(value);
    if (!value) cancelCountdown();
    _notify();
  }

  /// Pauses after [duration], or when the video ends with [endOfVideo].
  void setSleepTimer(Duration? duration, {bool endOfVideo = false}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepAt = null;
    sleepAtEnd = endOfVideo;
    if (duration != null) {
      sleepAt = DateTime.now().add(duration);
      _sleepTimer = Timer(duration, () {
        player.pause();
        sleepAt = null;
        _notify();
      });
    }
    _notify();
  }

  bool get sleepTimerOn => sleepAt != null || sleepAtEnd;

  // ───── Transport ─────

  Future<void> playPause() async {
    if (player.state.completed) {
      await player.seek(Duration.zero);
      await player.play();
      return;
    }
    await player.playOrPause();
  }

  Future<void> seekBy(Duration delta) async {
    final dur = player.state.duration;
    var target = player.state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    await player.seek(target);
  }

  Future<void> next() async {
    final n = nextVideo;
    if (n == null) return;
    await open(n.id, preview: n);
  }

  /// Back to the start, or to the previous video when near the start.
  Future<void> previous() async {
    if (_history.isEmpty || player.state.position > const Duration(seconds: 5)) {
      await player.seek(Duration.zero);
      return;
    }
    final p = _history.removeLast();
    await open(p.id, preview: p, recordHistory: false);
  }

  void _onCompleted() {
    if (loop) return;
    if (sleepAtEnd) {
      sleepAtEnd = false;
      _notify();
      return;
    }
    if (!autoplay || nextVideo == null) return;
    countdown.value = 5;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = (countdown.value ?? 0) - 1;
      if (left <= 0) {
        t.cancel();
        countdown.value = null;
        next();
      } else {
        countdown.value = left;
      }
    });
  }

  void cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    countdown.value = null;
  }

  /// Stops playback and hides the mini player.
  Future<void> close() async {
    _token++;
    _releaseAwaited();
    _releasePrefetch();
    cancelCountdown();
    _id = null;
    _preview = null;
    info = null;
    streams = null;
    currentVideo = null;
    related = const [];
    _history.clear();
    listenOnly = false;
    _notify();
    await _player?.stop();
  }

  // ───── Channel ─────

  /// Follows / unfollows the current video's channel. Returns an error
  /// message, or `null` on success.
  Future<String?> toggleSubscribe() async {
    final i = info;
    final channelId = i?.channelId;
    if (i == null || channelId == null) return 'This channel can\'t be followed from here.';
    final now = !(i.subscribed ?? false);
    info = i.copyWith(subscribed: now);
    _notify();
    try {
      await _client.setSubscribed(channelId, now);
      return null;
    } on YtException catch (e) {
      if (info?.id == i.id) {
        info = i;
        _notify();
      }
      return e.message;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    _releaseAwaited();
    _releasePrefetch();
    _countdownTimer?.cancel();
    _sleepTimer?.cancel();
    _mediaTimer?.cancel();
    if (_mediaShown) unawaited(MediaNotification.stop());
    countdown.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }
}
