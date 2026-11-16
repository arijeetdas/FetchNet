// FetchNet changelog tool, run by .githooks/pre-commit.
//
//   dart run tool/changelog.dart release [--version 1.2.0+4]
//       pubspec.yaml's version was bumped: file the notes under
//       "## 🚧 Unreleased" in CHANGELOG.md as that version (the commit
//       subjects since the last bump when there are none), then sync.
//   dart run tool/changelog.dart sync [--version 1.2.0+4]
//       Regenerate from CHANGELOG.md:
//       - assets/whats_new.json: only the notes of the version in
//         pubspec.yaml (its own section, or the Unreleased notes before the
//         version-bump commit files them). The app's one-time "What's new"
//         popup reads it; nothing else of the changelog ships in the app.
//       - the website's src/config/changelog.json (every release).
//   dart run tool/changelog.dart check
//       Fail when the pubspec version has no changelog entry.
//
// The website folder defaults to ../../FetchNet (D:\FetchNet beside
// D:\flutter_projects\fetchnet); set FETCHNET_WEBSITE to point elsewhere.
import 'dart:convert';
import 'dart:io';

import 'package:fetchnet/models/changelog.dart';

import 'changelog_markdown.dart';

const _changelogFile = 'CHANGELOG.md';
const _websiteJson = 'src/config/changelog.json';
const _appNotes = 'assets/whats_new.json';

Future<void> main(List<String> args) async {
  final command = args.isEmpty ? 'sync' : args.first;
  final versionArg = _option(args, '--version');
  try {
    switch (command) {
      case 'release':
        await _release(versionArg);
        _sync(versionArg);
      case 'sync':
        _sync(versionArg);
      case 'check':
        _check(versionArg);
      default:
        stderr.writeln('Unknown command "$command". Use release, sync or check.');
        exitCode = 2;
    }
  } on FormatException catch (e) {
    stderr.writeln('changelog: ${e.message}');
    exitCode = 1;
  }
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

/// `1.2.0+4` from pubspec.yaml (or [override]).
({String version, int build}) _pubspecVersion([String? override]) {
  final raw = override ??
      RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())?.group(1);
  final m = RegExp(r'^(\d+(?:\.\d+){1,3})\+(\d+)$').firstMatch(raw?.trim() ?? '');
  if (m == null) throw FormatException('pubspec.yaml needs "version: 1.2.0+4", found "$raw".');
  return (version: m.group(1)!, build: int.parse(m.group(2)!));
}

String _markdown() {
  final file = File(_changelogFile);
  if (!file.existsSync()) throw const FormatException('CHANGELOG.md is missing.');
  return file.readAsStringSync();
}

Future<void> _release(String? override) async {
  final v = _pubspecVersion(override);
  final markdown = _markdown();
  if (ChangelogMarkdown.parse(markdown).any((r) => r.build == v.build)) {
    stdout.writeln('changelog: v${v.version} (build ${v.build}) already has notes.');
    return;
  }
  ChangelogRelease? pending;
  ChangelogMarkdown.parse(markdown, unreleased: (r) => pending = r);
  final empty = pending == null || pending!.isEmpty;
  final fallback = empty ? await _commitSubjects() : const <String>[];
  if (empty) {
    stdout.writeln(fallback.isEmpty
        ? 'changelog: nothing under "Unreleased"; v${v.version} gets a generic line.'
        : 'changelog: nothing under "Unreleased"; v${v.version} lists ${fallback.length} commit subject(s).');
  }
  final now = DateTime.now();
  final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final released = ChangelogMarkdown.release(markdown, version: v.version, build: v.build, date: date, fallback: fallback);
  File(_changelogFile).writeAsStringSync(released);
  stdout.writeln('changelog: notes filed under v${v.version} (build ${v.build}).');
}

/// Subjects of the commits since pubspec.yaml's version last changed.
Future<List<String>> _commitSubjects() async {
  try {
    final last = await Process.run('git', ['log', '-1', '--format=%H', '-G^version:', '--', 'pubspec.yaml']);
    final hash = '${last.stdout}'.trim();
    final log = await Process.run('git', ['log', '--no-merges', '--format=%s', if (hash.isNotEmpty) '$hash..HEAD']);
    final skip = RegExp(r'^(updated? to v?\d|bump|release|merge|wip\b|version\b)', caseSensitive: false);
    return '${log.stdout}'
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !skip.hasMatch(s))
        .toSet()
        .toList()
        .reversed
        .toList();
  } catch (_) {
    return const [];
  }
}

void _sync([String? override]) {
  ChangelogRelease? pending;
  final releases = ChangelogMarkdown.parse(_markdown(), unreleased: (r) => pending = r);
  const encoder = JsonEncoder.withIndent('  ');

  // The app: this version's notes only.
  final v = _pubspecVersion(override);
  final notes = Changelog(releases, pending: pending).notesFor(v.build, installedVersion: v.version);
  final empty = {'version': v.version, 'build': v.build, 'sections': <Object>[]};
  _write(_appNotes, '${encoder.convert(notes?.toJson() ?? empty)}\n');
  if (notes == null) stdout.writeln('changelog: no notes for v${v.version} (build ${v.build}) yet.');

  // The website: every release.
  final json = '${encoder.convert(Changelog(releases).toJson())}\n';
  final website = Platform.environment['FETCHNET_WEBSITE'] ?? '../../FetchNet';
  if (Directory('$website/src/config').existsSync()) {
    _write('$website/$_websiteJson', json);
  } else {
    stdout.writeln('changelog: website not found at "$website" (set FETCHNET_WEBSITE); skipped it.');
  }
}

void _write(String path, String content) {
  final file = File(path);
  if (file.existsSync() && file.readAsStringSync() == content) return;
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  stdout.writeln('changelog: wrote $path');
}

void _check(String? override) {
  final v = _pubspecVersion(override);
  if (!ChangelogMarkdown.parse(_markdown()).any((r) => r.build == v.build && r.version == v.version)) {
    throw FormatException('CHANGELOG.md has no v${v.version} (build ${v.build}) section.');
  }
  stdout.writeln('changelog: v${v.version} (build ${v.build}) has notes.');
}
