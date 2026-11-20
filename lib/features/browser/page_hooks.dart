/// Scripts Browser Mode adds to every page and every frame inside it
/// (embedded players included), before the page's own scripts run.
class PageHooks {
  PageHooks._();

  /// Reports media the page loads (`fnMedia`: url, hint, frame address)
  /// and long-presses / right-clicks on pictures, video, audio and links
  /// (`fnPress`: {kind, src, href, page, title}).
  ///
  /// It watches the requests the page makes (fetch, XMLHttpRequest, the
  /// resources it loads), `<video>` / `<audio>` / `<source>` / `<track>`
  /// elements (also when a script sets their source), and the playlists of
  /// common players (JW Player, Video.js). A frame from another site that
  /// can't reach the app hands its findings to the page around it.
  static const script = r'''
(function(){
  if (window.__fnHook) return; window.__fnHook = 1;
  var RX = /\.(m3u8|m3u|mpd|mp4|m4v|webm|mov|mkv|flv|ogv|mp3|m4a|aac|oga|ogg|opus|flac|wav|vtt|srt|ass|ssa|ttml|dfxp)(?:[?#]|$)/i;
  var HINT = /m3u8|\.mpd|manifest|master\.|playlist\.|\/hls\/|\/dash\/|mime=video|mime=audio|videoplayback|subtitle|caption|format=m3u8/i;
  var top = window === window.top;
  function bridge(name, args) {
    try {
      var b = window.flutter_inappwebview;
      if (b && b.callHandler) { b.callHandler.apply(b, [name].concat(args)); return true; }
      if (!top) { window.top.postMessage({ __fnHook: name, a: args }, '*'); return true; }
    } catch (e) {}
    return false;
  }
  var waiting = [];
  setInterval(function () {
    if (!waiting.length) return;
    var q = waiting; waiting = [];
    q.forEach(function (x) { if (!bridge(x[0], x[1])) waiting.push(x); });
  }, 1000);
  function call(name, args) { if (!bridge(name, args)) waiting.push([name, args]); }
  if (top) {
    window.addEventListener('message', function (e) {
      var d = e.data;
      if (d && (d.__fnHook === 'fnMedia' || d.__fnHook === 'fnPress') && d.a && d.a.length) call(d.__fnHook, d.a);
    });
  }
  var sent = {};
  function send(u, h) {
    try {
      if (!u) return;
      u = String(u);
      if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      u = new URL(u, location.href).href;
      if (u.indexOf('http') !== 0) return;
      var media = h === 'video' || h === 'audio' || h === 'track';
      if (!media && !RX.test(u) && !HINT.test(u)) return;
      var key = u + '|' + (h || '');
      if (sent[key]) return;
      sent[key] = 1;
      call('fnMedia', [u, h || '', location.href]);
    } catch (e) {}
  }
  try {
    var f = window.fetch;
    if (f) window.fetch = function (i) {
      try { send(typeof i === 'string' ? i : (i && i.url), 'fetch'); } catch (e) {}
      return f.apply(this, arguments);
    };
  } catch (e) {}
  try {
    var open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, u) {
      try { send(u, 'xhr'); } catch (e) {}
      return open.apply(this, arguments);
    };
  } catch (e) {}
  try {
    var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (d && d.set) Object.defineProperty(HTMLMediaElement.prototype, 'src', {
      configurable: true, enumerable: d.enumerable, get: d.get,
      set: function (v) { try { send(v, this.tagName.toLowerCase()); } catch (e) {} return d.set.call(this, v); }
    });
  } catch (e) {}
  function scan() {
    try {
      document.querySelectorAll('video,audio,source,track').forEach(function (e) {
        var t = e.tagName.toLowerCase();
        if (t === 'track') { if (e.kind !== 'metadata' && e.kind !== 'chapters') send(e.src, 'track'); return; }
        if (t === 'source' && e.parentElement) t = e.parentElement.tagName.toLowerCase();
        send(e.currentSrc || e.src, t);
      });
    } catch (e) {}
    try {
      if (window.jwplayer) {
        var p = window.jwplayer(), list = p && p.getPlaylist && p.getPlaylist();
        (list || []).forEach(function (it) {
          if (it.file) send(it.file, 'video');
          (it.sources || []).forEach(function (s) { send(s.file, String(s.type || '').indexOf('audio') === 0 ? 'audio' : 'video'); });
          (it.tracks || []).forEach(function (t) { if (t.kind === 'captions' || t.kind === 'subtitles') send(t.file, 'track'); });
        });
      }
    } catch (e) {}
    try {
      if (window.videojs && window.videojs.getPlayers) {
        var players = window.videojs.getPlayers();
        for (var k in players) {
          var v = players[k];
          if (v && v.currentSources) v.currentSources().forEach(function (s) { send(s.src, 'video'); });
          if (v && v.remoteTextTracks) { var tt = v.remoteTextTracks(); for (var i = 0; i < tt.length; i++) if (tt[i].src) send(tt[i].src, 'track'); }
        }
      }
    } catch (e) {}
  }
  setInterval(scan, 2000);
  document.addEventListener('DOMContentLoaded', scan);
  try {
    new PerformanceObserver(function (l) { l.getEntries().forEach(function (e) { send(e.name, e.initiatorType); }); })
      .observe({ type: 'resource', buffered: true });
  } catch (e) {}
  document.addEventListener('contextmenu', function (ev) {
    try {
      var media = null, link = null;
      for (var n = ev.target; n && n.tagName; n = n.parentElement) {
        var t = n.tagName.toLowerCase();
        if (!media && (t === 'img' || t === 'video' || t === 'audio' || t === 'picture')) media = n;
        if (!link && t === 'a' && n.href) link = n;
      }
      if (media && media.tagName.toLowerCase() === 'picture') media = media.querySelector('img');
      var kind = media ? media.tagName.toLowerCase() : 'link';
      var src = '';
      if (media) {
        src = media.currentSrc || media.src || '';
        if (kind !== 'img' && (!src || src.indexOf('blob:') === 0)) {
          var s = media.querySelector('source[src]');
          if (s) src = s.src;
        }
      }
      var href = link ? link.href : '';
      if (href.indexOf('javascript:') === 0) href = '';
      if (!src && !href) return;
      ev.preventDefault();
      var title = (media && (media.alt || media.title)) || (link && (link.textContent || '').trim()) || document.title || '';
      call('fnPress', [{ kind: kind, src: src, href: href, page: location.href, title: title.slice(0, 120) }]);
    } catch (e) {}
  }, true);
})();
''';
}
