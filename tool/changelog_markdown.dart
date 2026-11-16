import 'package:fetchnet/models/changelog.dart';

/// Reads CHANGELOG.md (FetchNet's own style) and files the Unreleased notes
/// under a version. The file stays hand-written: releasing only rewrites the
/// Unreleased heading and its build line, everything else is left as is.
///
/// ```md
/// ## 🚧 Unreleased
///
/// > One-line summary.
///
/// ### ✨ Highlights
/// - ...
///
/// ### 🆕 New
///
/// #### 🤖 Android
/// - ...
///
/// ---
///
/// ## 🎬 v1.1.1 — 2026-11-07
///
/// > **Build 3** · One-line summary.
/// ```
class ChangelogMarkdown {
  ChangelogMarkdown._();

  static final _release =
      RegExp(r'^##\s+(?:(\S+)\s+)?v(\d+(?:\.\d+){1,3})(?:\+(\d+))?\s*(?:[—–-]+\s*(.*))?$');
  static final _unreleased = RegExp(r'^##\s+(?:\S+\s+)?unreleased\b.*$', caseSensitive: false);
  static final _date = RegExp(r'\d{4}-\d{2}-\d{2}');
  static final _build = RegExp(r'\*\*\s*build\s+(\d+)\s*\*\*\s*[·•|-]?\s*', caseSensitive: false);
  static final _bullet = RegExp(r'^(\s*)[-*]\s+(.*)$');

  static bool isUnreleasedHeading(String line) => _unreleased.hasMatch(line.trim());

  /// Every released version, newest first. [unreleased] receives the
  /// Unreleased block when one exists (version `0.0.0`, build 0).
  static List<ChangelogRelease> parse(String markdown, {void Function(ChangelogRelease)? unreleased}) {
    final lines = _withoutComments(markdown.replaceAll('\r\n', '\n')).split('\n');
    final releases = <ChangelogRelease>[];

    String? version;
    int? build;
    String? date;
    String? emoji;
    var isUnreleased = false;
    var open = false;
    final summary = <String>[];
    final sections = <({String title, List<({String title, List<String> items})> groups})>[];

    List<String> target() {
      if (sections.isEmpty) sections.add((title: '✨ Highlights', groups: [(title: '', items: <String>[])]));
      final s = sections.last;
      if (s.groups.isEmpty) s.groups.add((title: '', items: <String>[]));
      return s.groups.last.items;
    }

    void close() {
      if (!open) return;
      final release = ChangelogRelease(
        version: version ?? '0.0.0',
        build: build ?? 0,
        date: date,
        emoji: emoji,
        summary: summary.isEmpty ? null : summary.join(' ').trim(),
        sections: [
          for (final s in sections)
            ChangelogSection(
              kind: ChangelogSection.kindOf(s.title),
              title: s.title,
              groups: [
                for (final g in s.groups)
                  if (g.items.isNotEmpty)
                    ChangelogGroup(
                      title: g.title,
                      items: List.of(g.items),
                      platform: ChangelogSection.platformOf(g.title) ?? ChangelogSection.platformOf(s.title),
                    ),
              ],
            ),
        ].where((s) => s.groups.isNotEmpty).toList(),
      );
      if (isUnreleased) {
        unreleased?.call(release);
      } else {
        if (release.build <= 0) {
          throw FormatException('v${release.version} has no build number: add "> **Build N**" under its heading.');
        }
        releases.add(release);
      }
      open = false;
      summary.clear();
      sections.clear();
    }

    for (final raw in lines) {
      final line = raw.trimRight();
      final t = line.trim();
      final r = _release.firstMatch(t);
      if (r != null || _unreleased.hasMatch(t)) {
        close();
        open = true;
        isUnreleased = r == null;
        emoji = r?.group(1);
        version = r?.group(2);
        build = r?.group(3) == null ? null : int.parse(r!.group(3)!);
        final tail = r?.group(4) ?? '';
        date = _date.firstMatch(tail)?.group(0);
        continue;
      }
      if (!open || t.isEmpty || t == '---') continue;
      if (t.startsWith('## ')) {
        close();
        continue;
      }
      if (t.startsWith('### ')) {
        sections.add((title: t.substring(4).trim(), groups: []));
        continue;
      }
      if (t.startsWith('#### ')) {
        if (sections.isEmpty) sections.add((title: '🆕 New', groups: []));
        sections.last.groups.add((title: t.substring(5).trim(), items: <String>[]));
        continue;
      }
      if (t.startsWith('>')) {
        var text = t.replaceFirst(RegExp(r'^>\s?'), '');
        final b = _build.firstMatch(text);
        if (b != null) {
          build ??= int.parse(b.group(1)!);
          text = text.replaceFirst(_build, '');
        }
        if (text.trim().isNotEmpty) summary.add(text.trim());
        continue;
      }
      final bullet = _bullet.firstMatch(line);
      if (bullet != null) {
        final items = target();
        if (bullet.group(1)!.length >= 2 && items.isNotEmpty) {
          // A nested bullet reads as part of its parent.
          items[items.length - 1] = '${items.last} ${bullet.group(2)!.trim()}';
        } else {
          items.add(bullet.group(2)!.trim());
        }
        continue;
      }
      // A wrapped line continues the last bullet; loose text before the
      // first section reads as summary.
      final items = sections.isEmpty ? null : target();
      if (items != null && items.isNotEmpty) {
        items[items.length - 1] = '${items.last} $t';
      } else if (sections.isEmpty) {
        summary.add(t);
      }
    }
    close();
    releases.sort((a, b) => b.build.compareTo(a.build));
    return releases;
  }

  static String _withoutComments(String text) => text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  static const unreleasedBlock = '''## 🚧 Unreleased

<!-- Notes for the next version go here, in the same style as the releases
     below (### ✨ Highlights, ### 🆕 New with #### groups, ### 🛠️ Improved,
     ### 🐞 Fixed, ### ⚠️ Notes, ### 🧰 Under the hood; a "#### 🤖 Android"
     group is shown on Android only). A "> One-line summary." under this
     heading becomes the summary. When a commit bumps `version:` in
     pubspec.yaml, the pre-commit hook turns this heading into
     "## 🚀 vX.Y.Z — date" with "> **Build N**"; with no notes written, it
     uses the commit subjects since the last version bump. -->

---''';

  /// [markdown] with the Unreleased notes filed under `v[version]` (build
  /// [build], dated [date]) and a fresh, empty Unreleased block on top. When
  /// Unreleased is missing or empty, the release lists [fallback] (commit
  /// subjects) under Improved.
  static String release(
    String markdown, {
    required String version,
    required int build,
    required String date,
    List<String> fallback = const [],
  }) {
    final crlf = markdown.contains('\r\n');
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    final heading = lines.indexWhere(isUnreleasedHeading);

    ChangelogRelease? pending;
    parse(markdown, unreleased: (r) => pending = r);
    final hasNotes = heading >= 0 && pending != null && !pending!.isEmpty;

    List<String> out;
    if (hasNotes) {
      var end = lines.indexWhere((l) => l.trim().startsWith('## '), heading + 1);
      if (end < 0) end = lines.length;
      final block = lines.sublist(heading, end);
      final emoji = RegExp(r'^##\s+(\S+)\s+unreleased', caseSensitive: false).firstMatch(block.first.trim())?.group(1);
      block[0] = '## ${emoji == null || emoji == '🚧' ? '🚀' : emoji} v$version — $date';
      _dropComments(block);
      // The build goes into the quote line right under the heading.
      final first = block.indexWhere((l) => l.trim().isNotEmpty, 1);
      if (first > 0 && block[first].trim().startsWith('>')) {
        final text = block[first].trim().replaceFirst(RegExp(r'^>\s?'), '').replaceFirst(_build, '').trim();
        block[first] = '> **Build $build**${text.isEmpty ? '' : ' · $text'}';
      } else {
        block.insertAll(1, ['', '> **Build $build**']);
      }
      out = [...lines.sublist(0, heading), ...unreleasedBlock.split('\n'), '', ...block, ...lines.sublist(end)];
    } else {
      final notes = fallback.isEmpty ? const ['🔧 Fixes and improvements.'] : fallback;
      final release = [
        '## 🚀 v$version — $date',
        '',
        '> **Build $build**',
        '',
        '### 🛠️ Improved',
        '',
        for (final n in notes) '- $n',
        '',
        '---',
        '',
      ];
      // An empty Unreleased block is replaced; otherwise the new release
      // goes above the newest one.
      var at = heading;
      var removeTo = heading;
      if (heading >= 0) {
        removeTo = lines.indexWhere((l) => l.trim().startsWith('## '), heading + 1);
        if (removeTo < 0) removeTo = lines.length;
      } else {
        at = lines.indexWhere((l) => _release.hasMatch(l.trim()));
        if (at < 0) at = lines.length;
        removeTo = at;
      }
      out = [...lines.sublist(0, at), ...unreleasedBlock.split('\n'), '', ...release, ...lines.sublist(removeTo)];
    }
    final text = out.join('\n');
    return crlf ? text.replaceAll('\n', '\r\n') : text;
  }

  /// Removes the how-to comment from a block that became a release.
  static void _dropComments(List<String> block) {
    final joined = _withoutComments(block.join('\n')).split('\n');
    block
      ..clear()
      ..addAll(joined);
    // Collapse the blank lines the comment leaves behind.
    for (var i = block.length - 1; i > 0; i--) {
      if (block[i].trim().isEmpty && block[i - 1].trim().isEmpty) block.removeAt(i);
    }
  }
}
