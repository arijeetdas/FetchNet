import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/engine/engine.dart';
import 'package:fetchnet/engine/gallery_engine.dart';
import 'package:fetchnet/services/fetch_service.dart';
import 'package:fetchnet/services/gallery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers lookups with canned gallery-dl output: signed out, Instagram
/// redirects to its login page; with the browser's cookies, it lists the post.
class _FakeGalleryEngine extends GalleryDlEngine {
  _FakeGalleryEngine(super.prefs) {
    status.value = const EngineStatus(state: EngineState.ready, version: '1.32.20');
  }

  final runs = <List<String>>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<EngineResult> run(List<String> args, {String? id}) async {
    runs.add(args);
    // gallery-dl -j exits with 0 even when the lookup fails.
    if (!args.contains('--cookies')) {
      return const EngineResult(
        exitCode: 0,
        stdout: '[[-1, {"error": "AbortExtraction", "message": "HTTP redirect to login page '
            '(https://www.instagram.com/accounts/login/)"}]]',
        stderr: '',
      );
    }
    return const EngineResult(
      exitCode: 0,
      stdout: '''[
  [2, {"category": "instagram", "description": "Beach day", "username": "sam"}],
  [3, "https://scontent.cdninstagram.com/a.jpg", {"extension": "jpg", "num": 1}],
  [3, "https://scontent.cdninstagram.com/b.jpg", {"extension": "jpg", "num": 2}],
  [3, "ytdl:https://www.instagram.com/p/ABC/3.mp4", {"extension": "mp4", "num": 3,
     "display_url": "https://scontent.cdninstagram.com/c.jpg"}]
]''',
      stderr: '',
    );
  }

  @override
  EngineRun start(String id, List<String> args) => FailedEngineRun('not used');

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<String> update() async => 'up to date';
}

void main() {
  late AppPrefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AppPrefs.load();
  });

  const url = 'https://www.instagram.com/p/ABC/';

  test('an Instagram post that needs a sign-in is read with the browser\'s cookies', () async {
    final engine = _FakeGalleryEngine(prefs);
    final service = GalleryService(engine, prefs, cookieArgs: (_) async => ['--cookies', 'c.txt']);
    final post = await service.fetch(url);
    expect(engine.runs.length, 2, reason: 'signed out first, then with the sign-in');
    expect(engine.runs.last, containsAllInOrder(['--cookies', 'c.txt']));
    expect(post.items.length, 3);
    expect(post.requestArgs, contains('--cookies'), reason: 'the download needs the sign-in too');
  });

  test('without a sign-in, the error says so (not an exit code of 0 and a class name)', () async {
    final engine = _FakeGalleryEngine(prefs);
    final service = GalleryService(engine, prefs, cookieArgs: (_) async => const []);
    final error = await service.fetch(url).then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<GalleryFetchException>());
    final g = error! as GalleryFetchException;
    expect(g.needsSignIn, isTrue);
    expect(g.message, startsWith('HTTP redirect to login page'));
    expect(g.hint, contains('sign in'));
  });

  test('gallery-dl\'s reason is shown for a post yt-dlp has no video in', () {
    final signIn = GalleryFetchException('HTTP redirect to login page', exitCode: GalleryExit.auth);
    final other = GalleryFetchException('Requested post could not be found', exitCode: 0);
    final unknown = GalleryFetchException('Unsupported URL', exitCode: GalleryExit.unsupported);
    // yt-dlp on a pictures-only Instagram post.
    expect(galleryErrorExplainsBetter(FetchException('There is no video in this post'), signIn), isTrue);
    expect(galleryErrorExplainsBetter(FetchException('No video formats found!'), other), isTrue);
    expect(galleryErrorExplainsBetter(FetchException('Instagram sent an empty media response.'), other), isTrue);
    // A sign-in request beats anything yt-dlp says.
    expect(galleryErrorExplainsBetter(FetchException('Unable to download webpage: HTTP Error 403'), signIn), isTrue);
    // gallery-dl doesn't know the site: yt-dlp's error stays.
    expect(galleryErrorExplainsBetter(FetchException('Unsupported URL'), unknown), isFalse);
    expect(galleryErrorExplainsBetter(FetchException('Video unavailable'), other), isFalse);
  });

  test('sign-in errors are recognised in every form gallery-dl reports them', () {
    expect(GalleryService.needsSignIn('AbortExtraction: HTTP redirect to login page (https://www.instagram.com/accounts/login/)'), isTrue);
    expect(GalleryService.needsSignIn('AuthRequired: authenticated cookies needed to access this resource'), isTrue);
    expect(GalleryService.needsSignIn('AuthorizationError: Insufficient privileges'), isTrue);
    expect(GalleryService.needsSignIn('HttpError: \'404 Not Found\''), isFalse);
  });
}
