import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/device_environment.dart';
import '../../core/platform/native_bridge.dart';
import '../../models/download_models.dart';
import '../../models/media_info.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/motion/page_motions.dart';
import '../../widgets/page_parts.dart';
import '../downloads/file_actions_sheet.dart';
import '../settings/settings_widgets.dart';
import '../shell/home_shell.dart';
import 'clear_history_dialog.dart';
import '../../ui_kit/kit.dart';

/// Which downloads the History page lists.
enum _Filter {
  all('All', Icons.history_rounded),
  saved('Saved', Icons.check_circle_rounded),
  failed('Failed', Icons.error_rounded),
  cancelled('Cancelled', Icons.cancel_rounded);

  const _Filter(this.label, this.icon);

  final String label;
  final IconData icon;

  bool matches(HistoryEntry e) => switch (this) {
        _Filter.all => true,
        _Filter.saved => e.status == DownloadStatus.completed,
        _Filter.failed => e.status == DownloadStatus.failed,
        _Filter.cancelled => e.status == DownloadStatus.cancelled,
      };
}

/// The heading a download is listed under: "Today", "Yesterday", "Last 7
/// days", "Earlier this month", then the month ("October 2026").
@visibleForTesting
String historyGroupOf(DateTime when, DateTime now) {
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June', //
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(when.year, when.month, when.day)).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return 'Last 7 days';
  if (when.year == now.year && when.month == now.month) return 'Earlier this month';
  return '${months[when.month - 1]} ${when.year}';
}

/// "Video", "Audio", "Post · 12 files".
String _kindLabel(HistoryEntry entry) => switch (entry.kind) {
      MediaKind.video => 'Video',
      MediaKind.audio => 'Audio',
      MediaKind.thumbnail => 'Thumbnail',
      MediaKind.image => 'Image',
      MediaKind.post => entry.files.length > 1 ? 'Post · ${entry.files.length} files' : 'Post',
      MediaKind.subtitle => 'Subtitles',
    };

bool _fileThere(HistoryEntry e) => e.filePath != null && File(e.filePath!).existsSync();

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _search = TextEditingController();
  String _query = '';
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reset() {
    _search.clear();
    setState(() {
      _query = '';
      _filter = _Filter.all;
    });
  }

  Future<void> _clear(AppServices services) async {
    final history = services.history;
    final scope = await showClearHistoryDialog(context, history.entries);
    if (scope == null || !mounted) return;
    final now = DateTime.now();
    final removed = await history.removeWhere((e) => scope.picks(e, now));
    if (!mounted || removed.isEmpty) return;
    showSnack(
      context,
      'Cleared ${removed.length} download${removed.length == 1 ? '' : 's'} from history',
      kind: ToastKind.success,
      actionLabel: 'Undo',
      onAction: () => history.restore(removed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: services.history,
      builder: (context, _) {
        final all = services.history.entries;
        final q = _query.trim().toLowerCase();
        final entries = all.where((e) {
          if (!_filter.matches(e)) return false;
          if (q.isEmpty) return true;
          return e.title.toLowerCase().contains(q) || e.fileName.toLowerCase().contains(q) || e.url.toLowerCase().contains(q);
        }).toList();

        // Newest first, under "Today", "Yesterday"…
        final now = DateTime.now();
        final groups = <String, List<HistoryEntry>>{};
        for (final e in entries) {
          groups.putIfAbsent(historyGroupOf(e.completedAt ?? e.createdAt, now), () => []).add(e);
        }

        final wide = Breakpoints.isWide(context);
        final textGrowth = MediaQuery.textScalerOf(context).scale(14) - 14;
        return PageFrame(
          title: 'History',
          maxWidth: wide ? 1680 : 980,
          subtitle: all.isEmpty ? null : '${all.length} download${all.length == 1 ? '' : 's'}',
          leading: const PageGlyph(PageGlyphKind.history),
          actions: [
            if (all.isNotEmpty)
              Tooltip(
                message: 'Clear history',
                child: PillButton(label: 'Clear', icon: Icons.delete_sweep_rounded, danger: true, onPressed: () => _clear(services)),
              ),
          ],
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: PageHero(
                  motion: (size) => HistoryMotion(size: size),
                  tagline: 'Everything you\'ve downloaded: play it, share it or fetch it again.',
                ),
              ),
            ),
            if (all.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 14, bottom: 4),
                  child: _Controls(
                    all: all,
                    filter: _filter,
                    onFilter: (f) => setState(() => _filter = f),
                    search: _search,
                    onSearch: (v) => setState(() => _query = v),
                    wide: wide,
                  ),
                ),
              ),
            if (entries.isEmpty)
              SliverToBoxAdapter(
                child: all.isEmpty
                    ? EmptyHint(
                        icon: Icons.download_rounded,
                        title: 'No downloads yet',
                        text: 'What you download, and anything that fails or is cancelled, shows up here.',
                        action: ('Find something to download', () => services.tabRequest.value = 0),
                      )
                    : EmptyHint(
                        icon: Icons.search_off_rounded,
                        title: 'No matches',
                        text: q.isEmpty ? 'Nothing here is ${_filter.label.toLowerCase()}.' : 'Nothing matches "$_query".',
                        action: ('Show everything', _reset),
                      ),
              )
            else
              for (final MapEntry(key: label, value: items) in groups.entries) ...[
                SliverToBoxAdapter(child: GroupLabel(label: label, count: items.length)),
                if (wide)
                  // Large screens: two or three across. Every tile has the
                  // same lines, so one height fits.
                  SliverGrid(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 560,
                      mainAxisExtent: 92 + textGrowth * 3.2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _HistoryTile(entry: items[i]),
                      childCount: items.length,
                    ),
                  )
                else
                  SliverList.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _HistoryTile(entry: items[i]),
                  ),
              ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

/// The filter tiles (with how many each has) and the search box.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.all,
    required this.filter,
    required this.onFilter,
    required this.search,
    required this.onSearch,
    required this.wide,
  });

  final List<HistoryEntry> all;
  final _Filter filter;
  final ValueChanged<_Filter> onFilter;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final filters = Row(
      children: [
        for (final (i, f) in _Filter.values.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: CountTile(
              icon: f.icon,
              label: f.label,
              count: all.where(f.matches).length,
              selected: filter == f,
              onTap: () => onFilter(f),
            ),
          ),
        ],
      ],
    );
    final box = ValueListenableBuilder<TextEditingValue>(
      valueListenable: search,
      builder: (context, value, _) => TextField(
        controller: search,
        onChanged: onSearch,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search by title, file name or link',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    search.clear();
                    onSearch('');
                  },
                ),
          isDense: true,
        ),
      ),
    );
    if (wide) {
      return Row(
        children: [
          Expanded(flex: 3, child: filters),
          const SizedBox(width: 16),
          Expanded(flex: 2, child: box),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [filters, const SizedBox(height: 12), box],
    );
  }
}

/// Saved, the file moved, failed or cancelled.
(String, IconData, ChipTone) _statusOf(HistoryEntry e, bool fileThere) => switch (e.status) {
      DownloadStatus.completed when fileThere => ('Saved', Icons.check_circle_rounded, ChipTone.good),
      DownloadStatus.completed => ('File moved', Icons.folder_off_rounded, ChipTone.muted),
      DownloadStatus.failed => ('Failed', Icons.error_rounded, ChipTone.warn),
      DownloadStatus.cancelled => ('Cancelled', Icons.cancel_rounded, ChipTone.muted),
      _ => ('Unfinished', Icons.schedule_rounded, ChipTone.muted),
    };

/// A download's picture: the saved picture itself, the video's thumbnail,
/// or its kind on FetchNet's gradient.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.entry, required this.fileThere, this.radius = 14, this.iconSize = 24, this.showIcon = true});

  final HistoryEntry entry;
  final bool fileThere;
  final double radius;
  final double iconSize;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final (file, url) = entryPicture(entry, fileThere: fileThere);
    return MediaThumb(kind: entry.kind, file: file, url: url, radius: radius, iconSize: iconSize, showIcon: showIcon);
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final there = _fileThere(entry);
    final (label, icon, tone) = _statusOf(entry, there);
    final details = [
      _kindLabel(entry),
      if (entry.quality.isNotEmpty) entry.quality,
      if (entry.sizeBytes != null && entry.sizeBytes! > 0) formatBytes(entry.sizeBytes),
    ].join(' · ');
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showHistoryDetails(context, entry),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
          child: Row(
            children: [
              SizedBox(width: 96, height: 66, child: _Thumb(entry: entry, fileThere: there)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        StatusPill(label: label, icon: icon, tone: tone),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            formatDate(entry.completedAt ?? entry.createdAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// A download's details: its picture, what and when, why it failed, and
/// what can be done with it.
Future<void> showHistoryDetails(BuildContext context, HistoryEntry entry) => showKitSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheet) => _DetailsSheet(entry: entry, outer: context),
    );

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.entry, required this.outer});

  final HistoryEntry entry;

  /// The History page: actions run there once the sheet has closed.
  final BuildContext outer;

  void _run(BuildContext sheet, Future<void> Function(BuildContext) action) {
    Navigator.of(sheet).pop();
    action(outer);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final services = AppScope.of(context);
    final there = _fileThere(entry);
    final (label, icon, tone) = _statusOf(entry, there);
    final link = Uri.tryParse(entry.url);
    final hasLink = link != null && link.hasScheme && link.host.isNotEmpty;
    final android = NativeBridge.canShareNatively;
    final playable = there && (entry.kind == MediaKind.audio || entry.kind == MediaKind.video);
    final (pictureFile, pictureUrl) = entryPicture(entry, fileThere: there);
    final hasPicture = pictureFile != null || pictureUrl != null;
    final when = entry.completedAt ?? entry.createdAt;
    final whenLabel = switch (entry.status) {
      DownloadStatus.completed => 'Downloaded ${formatDate(when)}',
      DownloadStatus.failed => 'Failed ${formatDate(when)}',
      DownloadStatus.cancelled => 'Cancelled ${formatDate(when)}',
      _ => formatDate(when),
    };

    Future<void> fetchAgain(BuildContext _) async {
      services.incomingLink.value = entry.url;
      services.tabRequest.value = 0;
    }

    final quick = <SheetQuickAction>[
      if (there) ...[
        SheetQuickAction(
          icon: entry.kind == MediaKind.audio || entry.kind == MediaKind.video ? Icons.play_arrow_rounded : Icons.visibility_rounded,
          label: entry.kind == MediaKind.audio || entry.kind == MediaKind.video ? 'Play' : 'Open',
          primary: true,
          onTap: () => _run(context, (c) => openDownloadedFile(c, entry)),
        ),
        SheetQuickAction(
          icon: Icons.open_in_new_rounded,
          label: 'Open with',
          onTap: () => _run(context, (c) => openWithApp(c, entry.filePath!)),
        ),
        if (DeviceEnvironment.isDesktop)
          SheetQuickAction(
            icon: Icons.folder_open_rounded,
            label: 'Show in folder',
            onTap: () => _run(context, (_) => NativeBridge.revealInFolder(entry.filePath!)),
          )
        else
          SheetQuickAction(
            icon: android ? Icons.share_rounded : Icons.copy_rounded,
            label: android ? 'Share' : 'Copy file',
            onTap: () => _run(context, (c) => shareDownloadedFile(c, entry)),
          ),
      ] else if (hasLink) ...[
        SheetQuickAction(
          icon: Icons.replay_rounded,
          label: entry.status == DownloadStatus.completed ? 'Download again' : 'Try again',
          primary: true,
          onTap: () => _run(context, fetchAgain),
        ),
        SheetQuickAction(
          icon: android ? Icons.share_rounded : Icons.link_rounded,
          label: android ? 'Share link' : 'Copy link',
          onTap: () => _run(context, (c) => shareEntryLink(c, entry)),
        ),
        SheetQuickAction(
          icon: Icons.public_rounded,
          label: 'Open page',
          onTap: () => _run(context, (_) => launchUrl(link, mode: LaunchMode.externalApplication)),
        ),
      ],
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ───── Picture, title and details ─────
          GestureDetector(
            onTap: there ? () => _run(context, (c) => openDownloadedFile(c, entry)) : null,
            // No picture: a shorter banner.
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: hasPicture ? 200 : 120),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Thumb(entry: entry, fileThere: there, radius: 22, iconSize: 44, showIcon: !playable),
                    Positioned(top: 10, left: 10, child: StatusPill(label: label, icon: icon, tone: tone, onPicture: true)),
                    if (playable)
                      Center(
                        child: Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.7), width: 1.5),
                          ),
                          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            entry.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, height: 1.25),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              SheetChip(text: _kindLabel(entry), highlighted: true),
              if (entry.quality.isNotEmpty) SheetChip(text: entry.quality),
              if (entry.sizeBytes != null && entry.sizeBytes! > 0) SheetChip(text: formatBytes(entry.sizeBytes)),
              if (hasLink) SheetChip(text: link.host.replaceFirst(RegExp(r'^www\.'), '')),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(whenLabel, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ],
          ),
          if (there) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.folder_rounded, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    services.storage.displayPath(p.dirname(entry.filePath!)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],

          // ───── Why it failed, or where the file went ─────
          if (entry.status == DownloadStatus.failed && (entry.error ?? '').isNotEmpty) ...[
            const SizedBox(height: 14),
            _ErrorBox(error: entry.error!),
          ] else if (entry.status == DownloadStatus.completed && !there) ...[
            const SizedBox(height: 14),
            const TipBox(
              icon: Icons.folder_off_rounded,
              text: 'This file was moved, renamed or deleted. Download it again to get it back.',
            ),
          ],

          // ───── Quick actions ─────
          if (quick.isNotEmpty) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                for (var i = 0; i < quick.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: quick[i]),
                ],
              ],
            ),
          ],

          // ───── More (for a saved file; the rest have them above) ─────
          if (hasLink && there) ...[
            const SizedBox(height: 14),
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    SheetMenuRow(
                      icon: Icons.bolt_rounded,
                      title: 'Fetch again',
                      subtitle: 'Pick another quality or format',
                      onTap: () => _run(context, fetchAgain),
                    ),
                    _divider(scheme),
                    SheetMenuRow(
                      icon: Icons.content_copy_rounded,
                      title: 'Copy link',
                      subtitle: link.host,
                      onTap: () => _run(context, (c) async {
                        await Clipboard.setData(ClipboardData(text: entry.url));
                        if (c.mounted) showSnack(c, 'Link copied', kind: ToastKind.success);
                      }),
                    ),
                    _divider(scheme),
                    SheetMenuRow(
                      icon: Icons.public_rounded,
                      title: 'Open source page',
                      subtitle: link.host,
                      onTap: () => _run(context, (_) => launchUrl(link, mode: LaunchMode.externalApplication)),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // ───── Remove ─────
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: DialogButton(
                  label: 'Remove',
                  icon: Icons.playlist_remove_rounded,
                  expand: true,
                  onPressed: () => _run(context, (c) async {
                    await services.history.remove(entry.id);
                    if (c.mounted) showSnack(c, 'Removed from history');
                  }),
                ),
              ),
              if (there) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: DialogButton(
                    label: 'Delete file',
                    icon: Icons.delete_outline_rounded,
                    destructive: true,
                    expand: true,
                    onPressed: () => _run(context, (c) => deleteDownloadedFile(c, entry)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static Widget _divider(ColorScheme scheme) =>
      Divider(height: 1, indent: 56, endIndent: 16, color: scheme.outlineVariant.withValues(alpha: 0.4));
}

/// Why a download failed, with a button to copy it (to search or report).
class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.error_outline_rounded, size: 20, color: scheme.onErrorContainer),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Why it failed', style: theme.textTheme.titleSmall?.copyWith(color: scheme.onErrorContainer, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      error,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer, height: 1.45),
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: Icon(Icons.copy_rounded, size: 18, color: scheme.onErrorContainer),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: error));
              if (context.mounted) showSnack(context, 'Copied', kind: ToastKind.success);
            },
          ),
        ],
      ),
    );
  }
}
