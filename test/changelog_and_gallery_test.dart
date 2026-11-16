import 'dart:convert';
import 'dart:io';

import 'package:fetchnet/core/app_prefs.dart';
import 'package:fetchnet/engine/gallery_android_engine.dart';
import 'package:fetchnet/engine/gallery_engine.dart';
import 'package:fetchnet/models/changelog.dart';
import 'package:fetchnet/models/gallery_models.dart';
import 'package:fetchnet/models/media_info.dart';
import 'package:fetchnet/services/gallery_service.dart';
import 'package:fetchnet/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tool/changelog_markdown.dart';

const _sample = '''# 📜 Changelog

Intro.

---

## 🚧 Unreleased

<!-- how-to -->

> Posts and images.

### ✨ Highlights

- 🖼️ **Images**: new

### 🆕 New

#### 🤖 Android

- Only on Android

---

## 🎬 v1.1.1 — 2026-11-07

> **Build 3** · YouTube, rebuilt.

### ✨ Highlights

- ▶️ A player

### 🧰 Under the hood

- Tests

---

## 🎬 v1.0.0 — First release

> **Build 1** · The first release.

- 🔗 Paste a link
''';

void main() {
  group('Changelog markdown', () {
    test('reads releases in FetchNet\'s style', () {
      ChangelogRelease? pending;
      final releases = ChangelogMarkdown.parse(_sample, unreleased: (r) => pending = r);
      expect(releases.map((r) => '${r.version}+${r.build}'), ['1.1.1+3', '1.0.0+1']);
      expect(releases.first.summary, 'YouTube, rebuilt.');
      expect(releases.first.date, '2026-11-07');
      expect(releases.first.emoji, '🎬');
      // Bullets without a section read as highlights.
      expect(releases.last.section('highlights')!.items, ['🔗 Paste a link']);
      expect(pending!.summary, 'Posts and images.');
      final android = pending!.section('new')!.groups.single;
      expect(android.platform, 'android');
    });

    test('a version bump files Unreleased under the version, leaving the rest as is', () {
      final out = ChangelogMarkdown.release(_sample, version: '1.2.0', build: 4, date: '2026-11-17');
      expect(out, contains('## 🚀 v1.2.0 — 2026-11-17\n\n> **Build 4** · Posts and images.'));
      expect(out, contains('## 🚧 Unreleased'));
      // The old releases are untouched.
      expect(out, contains(_sample.substring(_sample.indexOf('## 🎬 v1.1.1'))));
      final releases = ChangelogMarkdown.parse(out);
      expect(releases.first.build, 4);
      expect(releases.first.section('highlights')!.items, ['🖼️ **Images**: new']);
      expect(releases.first.section('new')!.groups.single.items, ['Only on Android']);
    });

    test('with no notes written, commit subjects become the release', () {
      final empty = ChangelogMarkdown.release(_sample, version: '1.2.0', build: 4, date: '2026-11-17');
      final again = ChangelogMarkdown.release(empty, version: '1.2.1', build: 5, date: '2026-11-18', fallback: ['Fix a crash']);
      final releases = ChangelogMarkdown.parse(again);
      expect(releases.first.version, '1.2.1');
      expect(releases.first.section('improved')!.items, ['Fix a crash']);
      expect(releases[1].version, '1.2.0');
    });

    test('the repository changelog parses and covers the pubspec version', () {
      ChangelogRelease? pending;
      final releases = ChangelogMarkdown.parse(File('CHANGELOG.md').readAsStringSync(), unreleased: (r) => pending = r);
      final version = RegExp(r'^version:\s*(\d[\d.]*)\+(\d+)', multiLine: true)
          .firstMatch(File('pubspec.yaml').readAsStringSync())!;
      final released = releases.any((r) => r.version == version.group(1) && r.build == int.parse(version.group(2)!));
      // A bump not committed yet: the pre-commit hook files Unreleased.
      expect(
        released || (pending != null && !pending!.isEmpty),
        isTrue,
        reason: 'CHANGELOG.md needs notes for the version in pubspec.yaml (or under Unreleased)',
      );
      // The app ships this version's notes only, in assets/whats_new.json:
      // it must be generated from the current CHANGELOG.md for this build.
      final expected = Changelog(releases, pending: pending)
          .notesFor(int.parse(version.group(2)!), installedVersion: version.group(1));
      expect(expected, isNotNull, reason: 'the What\'s new popup would have nothing to show for this build');
      final shipped = ChangelogRelease.fromJson(jsonDecode(File('assets/whats_new.json').readAsStringSync()));
      expect(
        jsonEncode(shipped?.toJson()),
        jsonEncode(expected!.toJson()),
        reason: 'assets/whats_new.json is out of date: run "dart run tool/changelog.dart sync"',
      );
    });

    test('only this version\'s notes ship in the app, not CHANGELOG.md', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/whats_new.json'));
      expect(pubspec, isNot(contains('- CHANGELOG.md')));
    });
  });

  group('What\'s new', () {
    final changelog = Changelog(ChangelogMarkdown.parse(_sample));

    test('shows once per build: a flag for each, checked at startup', () {
      // 1.1.1 (build 3, flagged) → 1.2.0 (build 4, no flag yet): show.
      expect(Changelog.isDue(installedBuild: 4, shownBuilds: {3}), isTrue);
      // 1.2.0 → 1.2.0 again (reinstall over itself), or after it showed: don't.
      expect(Changelog.isDue(installedBuild: 4, shownBuilds: {4}), isFalse);
      // Back to an older version (a newer build's flag exists): don't.
      expect(Changelog.isDue(installedBuild: 3, shownBuilds: {4}), isFalse);
      // No flag at all (updated from a version before the popup existed): show.
      expect(Changelog.isDue(installedBuild: 4, shownBuilds: {}), isTrue);
    });

    test('a build\'s flag replaces the previous ones', () async {
      SharedPreferences.setMockInitialValues({
        'whatsnew.shown.3': true,
        'app.changelog_seen_build': 2, // saved by an earlier version of the popup
      });
      final prefs = await AppPrefs.load();
      expect(prefs.whatsNewShownBuilds, {3, 2});
      expect(prefs.whatsNewShown(4), isFalse);
      await prefs.markWhatsNewShown(4);
      expect(prefs.whatsNewShown(4), isTrue);
      expect(prefs.whatsNewShownBuilds, {4}, reason: 'the previous flags are deleted');
    });

    test('lists the installed version only, even after skipping versions', () {
      expect(changelog.notesFor(3)!.version, '1.1.1');
      expect(changelog.notesFor(1)!.version, '1.0.0');
      expect(changelog.notesFor(2), isNull, reason: 'no notes for that build: nothing to show');
    });

    test('a version bump not committed yet shows the Unreleased notes', () {
      ChangelogRelease? pending;
      final releases = ChangelogMarkdown.parse(_sample, unreleased: (r) => pending = r);
      final withPending = Changelog(releases, pending: pending);
      // pubspec says 1.2.0+4; CHANGELOG.md still has its notes under Unreleased.
      final notes = withPending.notesFor(4, installedVersion: '1.2.0')!;
      expect(notes.version, '1.2.0');
      expect(notes.build, 4);
      expect(notes.summary, 'Posts and images.');
      expect(notes.section('highlights')!.items, ['🖼️ **Images**: new']);
      // A released build keeps its own notes, and an older build never gets
      // the Unreleased ones.
      expect(withPending.notesFor(3)!.version, '1.1.1');
      expect(withPending.notesFor(2), isNull);
      // Nothing written under Unreleased: nothing to show.
      expect(Changelog(releases).notesFor(4, installedVersion: '1.2.0'), isNull);
    });

    test('other platforms\' groups and under-the-hood notes stay out', () {
      final r = ChangelogRelease.fromJson(changelog.toJson()['releases'][0])!;
      expect(r.sectionsFor('windows').map((s) => s.kind), ['highlights']);
    });
  });

  group('Download folders', () {
    test('every kind of download has its type folder', () {
      expect(MediaFolder.forKind(MediaKind.video).folderName, 'Video');
      expect(MediaFolder.forKind(MediaKind.audio).folderName, 'Audio');
      expect(MediaFolder.forKind(MediaKind.image).folderName, 'Images');
      expect(MediaFolder.forKind(MediaKind.thumbnail).folderName, 'Images');
    });

    test('a post\'s files are sorted by their extension', () {
      expect(MediaFolder.forExtension('.JPG'), MediaFolder.images);
      expect(MediaFolder.forExtension('webp'), MediaFolder.images);
      expect(MediaFolder.forExtension('.mp3'), MediaFolder.audio);
      expect(MediaFolder.forExtension('opus'), MediaFolder.audio);
      expect(MediaFolder.forExtension('.mp4'), MediaFolder.video);
      expect(MediaFolder.forExtension('.zip'), MediaFolder.video);
    });
  });

  group('gallery-dl', () {
    const output = '''[
  [2, {"category": "twitter", "content": "A day at the beach\\nmore", "author": {"name": "sam", "nick": "Sam"}}],
  [3, "https://pbs.twimg.com/media/a.jpg", {"extension": "jpg", "width": 1200, "height": 900, "num": 1}],
  [3, "https://video.twimg.com/v.mp4", {"extension": "mp4", "type": "video", "duration": 12.5, "display_url": "https://pbs.twimg.com/thumb.jpg"}],
  [3, "ytdl:https://v.redd.it/x", {"extension": ""}]
]''';

    test('parses files, kinds, previews, title and author', () {
      final post = GalleryPost.parse(output, sourceUrl: 'https://x.com/sam/status/1');
      expect(post.items.map((i) => i.kind), [GalleryItemKind.image, GalleryItemKind.video, GalleryItemKind.video]);
      expect(post.items.map((i) => i.index), [1, 2, 3]);
      expect(post.items[1].preview, 'https://pbs.twimg.com/thumb.jpg');
      expect(post.items[2].viaYtDlp, isTrue);
      expect(post.title, 'A day at the beach');
      expect(post.author, 'Sam');
      expect(post.site, 'twitter');
    });

    test('a profile lists its posts', () {
      final post = GalleryPost.parse('[[6, "https://x.com/sam/status/2", {"title": "Two"}]]', sourceUrl: 'https://x.com/sam');
      expect(post.items, isEmpty);
      expect(post.children.single.title, 'Two');
    });

    test('reads errors reported inside the JSON', () {
      expect(GalleryPost.errorIn('[[-1, {"error": "AuthorizationError", "message": "Login required"}]]'),
          'AuthorizationError: Login required');
    });

    test('ranges collapse runs', () {
      expect(GalleryPost.rangeOf([5, 1, 2, 3, 9, 10]), '1-3,5,9-10');
    });

    test('Browser Mode sign-in reaches gallery-dl in its own spelling', () {
      expect(
        galleryRequestArgs(['--cookies', 'c.txt', '--user-agent', 'UA', '--referer', 'https://a', '--no-playlist']),
        ['--cookies', 'c.txt', '--user-agent', 'UA'],
      );
    });

    test('hints point to signing in, unless the run already had the sign-in', () {
      expect(friendlyGalleryHint('Login required', exitCode: 16), contains('Browser Mode and sign in'));
      expect(friendlyGalleryHint('Login required', exitCode: 16, signedIn: true), contains('even with your sign-in'));
      expect(friendlyGalleryHint('Unsupported URL', exitCode: 64), contains('doesn\'t know this site'));
    });

    test('supported sites come from the example URLs', () {
      const list = '''InstagramPostExtractor
Category: instagram - Subcategory: post
Example : https://www.instagram.com/p/abcdefg/

TumblrUserExtractor
Example : https://BLOG.tumblr.com/

YoutubeExtractor
Example : https://www.youtube.com/watch?v=x
''';
      expect(GalleryService.hostsFromExtractorList(list), {'instagram.com', 'tumblr.com'});
    });

    test('PyPI: the newest pure wheel that runs on the bundled Python', () {
      final json = {
        'info': {'version': '3.0'},
        'urls': [
          {'filename': 'pkg-3.0-py3-none-any.whl', 'packagetype': 'bdist_wheel', 'requires_python': '>=3.13', 'url': 'u3', 'digests': {'sha256': 'A'}},
        ],
        'releases': {
          '2.0': [
            {'filename': 'pkg-2.0-cp312-cp312-android.whl', 'packagetype': 'bdist_wheel', 'url': 'x', 'digests': {'sha256': 'X'}},
            {'filename': 'pkg-2.0-py3-none-any.whl', 'packagetype': 'bdist_wheel', 'requires_python': '>=3.8', 'url': 'u2', 'digests': {'sha256': 'B'}},
          ],
          '3.0': [],
        },
      };
      final w = PyWheel.pick(json, python: (3, 12))!;
      expect(w.version, '2.0');
      expect(w.url, 'u2');
      expect(w.sha256, 'b');
    });
  });
}
