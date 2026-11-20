import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Browser Mode's ad, tracker and pop-up blocker.
///
/// A built-in list of ad networks, trackers and the pop-up / redirect
/// networks streaming sites lean on. Requests to them are blocked
/// (content blockers on Android, iOS, macOS and Linux; request
/// interception on Windows), pages that try to navigate to them are
/// stopped, and a small stylesheet hides the empty ad boxes left behind.
class AdBlocker {
  AdBlocker._();

  /// Blocked hosts; their subdomains are blocked too.
  static const hosts = <String>{
    // Google ads & analytics (not Google sign-in, fonts or APIs).
    'doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'google-analytics.com',
    'googletagmanager.com', 'googletagservices.com', 'adservice.google.com', 'adtrafficquality.google',
    // Ad exchanges and networks.
    'adnxs.com', 'adsrvr.org', 'advertising.com', 'amazon-adsystem.com', 'criteo.com', 'criteo.net',
    'taboola.com', 'outbrain.com', 'revcontent.com', 'mgid.com', 'zergnet.com', 'rubiconproject.com',
    'pubmatic.com', 'openx.net', 'casalemedia.com', 'indexww.com', 'sharethrough.com', 'smartadserver.com',
    'adform.net', 'yieldmo.com', 'teads.tv', '33across.com', 'sovrn.com', 'lijit.com', 'contextweb.com',
    'gumgum.com', 'media.net', 'bidswitch.net', 'adsafeprotected.com', 'doubleverify.com', 'moatads.com',
    'serving-sys.com', 'flashtalking.com', 'innovid.com', 'spotxchange.com', 'springserve.com',
    'adcolony.com', 'applovin.com', 'inmobi.com', 'chartboost.com', 'vungle.com', 'adskeeper.com',
    'adskeeper.co.uk', 'adition.com', 'yieldlab.net', 'improvedigital.com', 'emxdgt.com',
    'districtm.io', 'undertone.com', 'triplelift.com', 'nativo.com', 'adroll.com', 'perfectaudience.com',
    'outbrainimg.com', 'adsco.re', 'carbonads.com', 'buysellads.com', 'admixer.net', 'adtelligent.com',
    'vidoomy.com', 'adpushup.com', 'ezoic.net', 'ezodn.com', 'mediavine.com', 'adthrive.com',
    // Pop-unders, redirects and push-ad networks (common on streaming sites).
    'propellerads.com', 'propellerclick.com', 'onclickads.net', 'onclkds.com', 'onclickalgo.com',
    'onclickperformance.com', 'onclickgenius.com', 'popads.net', 'popcash.net', 'popmyads.com', 'poptm.com',
    'popunder.net', 'adcash.com', 'acscdn.com', 'adsterra.com', 'adsterratools.com', 'highperformanceformat.com',
    'highcpmgate.com', 'profitablecpmgate.com', 'profitablegatecpm.com', 'effectiveratecpm.com',
    'hilltopads.net', 'hilltopads.com', 'exoclick.com', 'exosrv.com', 'exdynsrv.com', 'realsrv.com',
    'juicyads.com', 'trafficjunky.net', 'trafficjunky.com', 'trafficstars.com', 'tsyndicate.com',
    'clickadu.com', 'clickaine.com', 'galaksion.com', 'a-ads.com', 'admaven.com', 'ad-maven.com',
    'monetag.com', 'acint.net', 'dtscout.com', 'dtscdn.com', 'rtmark.net', 'bebi.com', 'notix.io',
    'pushame.com', 'wpadmngr.com', 'wpushsdk.com', 'adspyglass.com', 'zeropark.com', 'richads.com',
    'evadav.com', 'pushground.com', 'kadam.net', 'trafficforce.com',
    // Trackers and analytics.
    'scorecardresearch.com', 'quantserve.com', 'quantcount.com', 'demdex.net', 'everesttech.net',
    'krxd.net', 'bluekai.com', 'exelator.com', 'agkn.com', 'mathtag.com', 'rlcdn.com', 'hotjar.com',
    'hotjar.io', 'mouseflow.com', 'fullstory.com', 'crazyegg.com', 'clarity.ms', 'bat.bing.com',
    'statcounter.com', 'histats.com', 'mc.yandex.ru', 'an.yandex.ru', 'adfox.ru', 'hm.baidu.com',
    'cnzz.com', 'analytics.tiktok.com', 'ads-twitter.com', 'analytics.twitter.com', 'an.facebook.com',
    'chartbeat.com', 'chartbeat.net', 'newrelic.com', 'nr-data.net', 'mixpanel.com', 'segment.io',
    'kissmetrics.com', 'parsely.com', 'tealiumiq.com', 'omtrdc.net', '2o7.net', 'branch.io', 'adjust.com',
    'appsflyer.com', 'kochava.com', 'liadm.com', 'id5-sync.com', 'pippio.com', 'tapad.com', 'adsymptotic.com',
  };

  /// Whether [url] is an ad, tracker or pop-up network.
  static bool isBlocked(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return false;
    return isBlockedHost(host);
  }

  static bool isBlockedHost(String host) {
    var h = host.toLowerCase();
    while (true) {
      if (hosts.contains(h)) return true;
      final dot = h.indexOf('.');
      if (dot < 0) return false;
      h = h.substring(dot + 1);
    }
  }

  static String _escape(String host) => host.replaceAll('.', r'\.').replaceAll('-', r'\-');

  /// `(a\.com|b\.net|...)` for regular expressions.
  static String hostAlternation() => '(?:${hosts.map(_escape).join('|')})';

  /// Content blockers (Android, iOS, macOS, Linux): one per group of hosts,
  /// so the expressions stay small.
  static List<ContentBlocker> contentBlockers() {
    final list = hosts.toList();
    final blockers = <ContentBlocker>[];
    for (var i = 0; i < list.length; i += 40) {
      final group = list.sublist(i, i + 40 > list.length ? list.length : i + 40).map(_escape).join('|');
      blockers.add(ContentBlocker(
        trigger: ContentBlockerTrigger(urlFilter: '^https?://([^/?#]*\\.)?($group)([:/?#]|\$)'),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ));
    }
    return blockers;
  }

  /// The same site (example.com for www.example.com and cdn.example.com),
  /// to tell a site's own pop-ups from ads.
  static String siteOf(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final parts = host.split('.');
    if (parts.length <= 2) return host;
    // example.co.uk, example.com.au, ...
    const second = {'co', 'com', 'net', 'org', 'gov', 'ac', 'edu', 'ne', 'or', 'go'};
    final n = parts[parts.length - 1].length == 2 && second.contains(parts[parts.length - 2]) ? 3 : 2;
    return parts.sublist(parts.length - n).join('.');
  }

  /// Hides the boxes ads leave behind (only selectors that mean ads).
  static const cosmeticScript = r'''
(function(){
  if (window.__fnCosmetic) return; window.__fnCosmetic = 1;
  var css = 'ins.adsbygoogle,.adsbygoogle,[id^="google_ads_"],[id^="div-gpt-ad"],'
    + 'iframe[src*="doubleclick.net"],iframe[src*="googlesyndication"],iframe[id^="google_ads_iframe"],'
    + 'iframe[src*="adsterra"],iframe[src*="exoclick"],iframe[src*="popads"],a[href*="doubleclick.net"],'
    + '[data-ad-slot],[data-google-query-id],amp-ad,amp-embed[type="taboola"],.taboola,.OUTBRAIN'
    + '{display:none!important;visibility:hidden!important;}';
  function add(){
    try {
      var s = document.createElement('style');
      s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    } catch (e) {}
  }
  if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
})();
''';
}
