// Pure Dart (no Flutter imports): `tool/changelog.dart` uses it too.

/// A `#### 🤖 Android` style group inside a section.
class ChangelogGroup {
  const ChangelogGroup({required this.title, required this.items, this.platform});

  /// As written, emoji included (`🤖 Android`); empty for loose bullets.
  final String title;
  final List<String> items;

  /// `android`, `windows`, `macos` or `linux` when the group is about one
  /// platform only.
  final String? platform;

  Map<String, dynamic> toJson() => {
        'title': title,
        if (platform != null) 'platform': platform,
        'items': items,
      };

  static ChangelogGroup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final items = raw['items'];
    if (items is! List) return null;
    return ChangelogGroup(
      title: '${raw['title'] ?? ''}',
      platform: raw['platform'] as String?,
      items: [for (final i in items) if (i is String && i.trim().isNotEmpty) i],
    );
  }
}

/// A `### 🆕 New` style section.
class ChangelogSection {
  const ChangelogSection({required this.kind, required this.title, this.groups = const []});

  /// `highlights`, `new`, `improved`, `fixed`, `notes`, `internal` (under
  /// the hood) or `other`.
  final String kind;

  /// As written, emoji included (`🆕 New`).
  final String title;

  /// Bullets right under the section come first, in a group without a title.
  final List<ChangelogGroup> groups;

  /// The section is about one platform (e.g. `### 🤖 Android`).
  String? get platform => platformOf(title);

  Iterable<String> get items => groups.expand((g) => g.items);

  static String kindOf(String title) {
    final t = title.toLowerCase();
    if (t.contains('highlight')) return 'highlights';
    if (t.contains('under the hood') || t.contains('internal') || t.contains('developer')) return 'internal';
    if (t.contains('fix')) return 'fixed';
    if (t.contains('improv') || t.contains('changed')) return 'improved';
    if (t.contains('note') || t.contains('known')) return 'notes';
    if (t.contains('new') || t.contains('added') || t.contains('feature')) return 'new';
    return 'other';
  }

  static final _platform = RegExp(r'\b(android|windows|mac\s?os|linux)\b', caseSensitive: false);

  /// `android`, `windows`, `macos` or `linux` for a heading about that platform.
  static String? platformOf(String title) {
    final m = _platform.firstMatch(title);
    if (m == null) return null;
    final p = m.group(1)!.toLowerCase().replaceAll(' ', '');
    return p == 'macos' || p == 'mac os' ? 'macos' : p;
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'title': title,
        'groups': [for (final g in groups) g.toJson()],
      };

  static ChangelogSection? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final groups = raw['groups'];
    return ChangelogSection(
      kind: '${raw['kind'] ?? 'other'}',
      title: '${raw['title'] ?? ''}',
      groups: groups is List ? groups.map(ChangelogGroup.fromJson).whereType<ChangelogGroup>().toList() : const [],
    );
  }
}

/// One released version, from a `## 🎬 v1.1.1 — 2026-11-07` heading in
/// CHANGELOG.md. The app reads CHANGELOG.md itself; the website's
/// `src/config/changelog.json` is generated from it by
/// `tool/changelog.dart` (run by the pre-commit hook).
class ChangelogRelease {
  const ChangelogRelease({
    required this.version,
    required this.build,
    this.date,
    this.emoji,
    this.summary,
    this.sections = const [],
  });

  /// `1.2.0`
  final String version;

  /// The `+N` build number from pubspec.yaml (`> **Build N**` in the file).
  final int build;

  /// `2026-11-17`, when the heading has one.
  final String? date;

  /// The heading's emoji (`🎬`).
  final String? emoji;

  /// The quote line under the heading, without its `**Build N** ·` prefix.
  final String? summary;

  final List<ChangelogSection> sections;

  bool get isEmpty => (summary == null || summary!.isEmpty) && sections.every((s) => s.items.isEmpty);

  ChangelogSection? section(String kind) => sections.where((s) => s.kind == kind).firstOrNull;

  /// What applies on [platform] (`android`, ...; `null` keeps everything):
  /// groups and sections about other platforms are left out.
  List<ChangelogSection> sectionsFor(String? platform, {bool includeInternal = false}) => [
        for (final s in sections)
          if ((includeInternal || s.kind != 'internal') && (platform == null || s.platform == null || s.platform == platform))
            ChangelogSection(
              kind: s.kind,
              title: s.title,
              groups: [
                for (final g in s.groups)
                  if (g.items.isNotEmpty && (platform == null || g.platform == null || g.platform == platform)) g,
              ],
            ),
      ].where((s) => s.groups.isNotEmpty).toList();

  Map<String, dynamic> toJson() => {
        'version': version,
        'build': build,
        if (date != null) 'date': date,
        if (emoji != null) 'emoji': emoji,
        if (summary != null && summary!.isNotEmpty) 'summary': summary,
        'sections': [for (final s in sections) s.toJson()],
      };

  static ChangelogRelease? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = raw['version'];
    final build = raw['build'];
    if (version is! String || build is! num) return null;
    final sections = raw['sections'];
    return ChangelogRelease(
      version: version,
      build: build.toInt(),
      date: raw['date'] as String?,
      emoji: raw['emoji'] as String?,
      summary: raw['summary'] as String?,
      sections: sections is List ? sections.map(ChangelogSection.fromJson).whereType<ChangelogSection>().toList() : const [],
    );
  }
}

/// The whole changelog, newest release first.
class Changelog {
  const Changelog(this.releases, {this.pending});

  final List<ChangelogRelease> releases;

  /// The notes under "Unreleased" in CHANGELOG.md: the version being built.
  /// They belong to the version in pubspec.yaml until the commit that bumps
  /// it files them under that version.
  final ChangelogRelease? pending;

  static const empty = Changelog([]);

  ChangelogRelease? forBuild(int build) => releases.where((r) => r.build == build).firstOrNull;

  /// The notes of the installed version only (never earlier builds), or
  /// `null` when the changelog has none for it.
  ///
  /// A build newer than every released one without a section of its own (a
  /// version bump not committed yet) gets the Unreleased notes, labelled
  /// with [installedVersion] and [installedBuild].
  ChangelogRelease? notesFor(int installedBuild, {String? installedVersion}) {
    final r = forBuild(installedBuild);
    if (r != null) return r.isEmpty ? null : r;
    final p = pending;
    final newest = releases.isEmpty ? 0 : releases.map((r) => r.build).reduce((a, b) => a > b ? a : b);
    if (p == null || p.isEmpty || installedBuild <= newest) return null;
    return ChangelogRelease(
      version: installedVersion ?? p.version,
      build: installedBuild,
      date: p.date,
      emoji: p.emoji == null || p.emoji == '🚧' ? '🚀' : p.emoji,
      summary: p.summary,
      sections: p.sections,
    );
  }

  /// Whether the one-time popup is due for [installedBuild], given the
  /// builds that have a "shown" flag ([shownBuilds], normally the previous
  /// version's only).
  ///
  /// - Its own flag exists: already shown (1.2.0 → 1.2.0 again): no.
  /// - A newer build's flag exists: an older version was installed: no.
  /// - Otherwise (an update, or no flag at all): yes.
  ///
  /// A fresh install gets its flag during onboarding, so it shows nothing.
  static bool isDue({required int installedBuild, required Set<int> shownBuilds}) =>
      !shownBuilds.contains(installedBuild) && !shownBuilds.any((b) => b > installedBuild);

  Map<String, dynamic> toJson() => {
        'releases': [for (final r in releases) r.toJson()],
      };

  static Changelog fromJson(Object? raw) {
    final list = raw is Map ? raw['releases'] : null;
    if (list is! List) return empty;
    final releases = list.map(ChangelogRelease.fromJson).whereType<ChangelogRelease>().toList()
      ..sort((a, b) => b.build.compareTo(a.build));
    return Changelog(releases);
  }
}
