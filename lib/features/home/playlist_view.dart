import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../models/download_models.dart';
import '../../models/media_info.dart';
import '../../services/extra_settings.dart';
import '../../services/fetch_service.dart';
import '../../services/storage_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/motion/motion_core.dart';
import '../youtube/youtube_download_sheet.dart';
import 'home_kit.dart';

/// A playlist or channel: its videos, [FetchService.playlistPageSize] at a
/// time ("Load more" reads the next page, so channels with thousands of
/// videos stay quick). Up to [maxPicked] videos are picked at once and
/// downloaded with the quick download presets; each video's own details
/// (formats, subtitles, tags) open in a popup. Entries that are lists of
/// their own (a channel's Videos / Shorts tabs) open with [onOpenList].
class PlaylistView extends StatefulWidget {
  const PlaylistView({super.key, required this.info, required this.onOpenList});

  final MediaInfo info;
  final ValueChanged<PlaylistEntry> onOpenList;

  /// Videos picked at once.
  static const maxPicked = 10;

  @override
  State<PlaylistView> createState() => _PlaylistViewState();
}

class _PlaylistViewState extends State<PlaylistView> {
  late final List<PlaylistEntry> _entries = [...widget.info.entries];

  /// Reads the next pages; made on the first "Load more".
  FetchService? _fetcher;

  /// Picked videos, by URL, in the order they were picked.
  final List<String> _picked = [];

  /// The last page was full: there may be more.
  late bool _lastPageFull = widget.info.entries.length >= FetchService.playlistPageSize;
  bool _loadingMore = false;
  String? _loadError;
  bool _queueing = false;

  /// What the picked videos download as; `null` = the preset's choice.
  MediaKind? _kind;

  bool get _hasMore {
    final total = widget.info.playlistCount;
    if (total != null) return _entries.length < total;
    return _lastPageFull;
  }

  @override
  void dispose() {
    _fetcher?.cancel();
    super.dispose();
  }

  Future<void> _loadMore() async {
    final fetcher = _fetcher ??= AppScope.of(context).newFetcher();
    setState(() {
      _loadingMore = true;
      _loadError = null;
    });
    try {
      final page = await fetcher.fetch(
        widget.info.url,
        requestArgs: widget.info.requestArgs,
        playlistStart: _entries.length + 1,
      );
      if (!mounted) return;
      final known = {for (final e in _entries) e.url};
      setState(() {
        _entries.addAll(page.entries.where((e) => known.add(e.url)));
        _lastPageFull = page.entries.length >= FetchService.playlistPageSize;
        _loadingMore = false;
      });
    } on FetchException catch (e) {
      if (!mounted || e.cancelled) return;
      setState(() {
        _loadingMore = false;
        _loadError = e.hint ?? e.message;
      });
    }
  }

  void _toggle(PlaylistEntry e) {
    setState(() {
      if (!_picked.remove(e.url) && _picked.length < PlaylistView.maxPicked) _picked.add(e.url);
    });
  }

  /// Picks the first videos not picked yet, up to [PlaylistView.maxPicked].
  void _pickNext() {
    setState(() {
      for (final e in _entries) {
        if (_picked.length >= PlaylistView.maxPicked) break;
        if (!e.isList && !_picked.contains(e.url)) _picked.add(e.url);
      }
    });
  }

  Future<void> _downloadPicked(MediaKind kind) async {
    final services = AppScope.of(context);
    if (services.storage.downloadDir == null) {
      await services.storage.ensureDownloadDir(requestPermission: true);
      if (!mounted) return;
      if (services.storage.downloadDir == null) {
        showSnack(context, services.storage.error ?? 'The download folder isn\'t available.', kind: ToastKind.error);
        return;
      }
    }
    setState(() => _queueing = true);
    final extras = services.extras;
    final ffmpeg = services.engine.status.value.ffmpegAvailable;
    final option = kind == MediaKind.audio
        ? presetAudioOption(extras.presetAudio, ffmpeg: ffmpeg)
        : presetVideoOption(extras.presetVideoHeight, ffmpeg: ffmpeg);
    final picked = [for (final e in _entries) if (_picked.contains(e.url)) e];
    for (final e in picked) {
      final title = StorageService.sanitizeFileName(e.title);
      final name = services.storage.uniqueBaseName(
        title.isEmpty ? StorageService.randomFileName(audio: kind == MediaKind.audio) : title,
        // Not a name in the folder, the queue or History (even a deleted file's).
        alsoTaken: services.downloads.takenNames(option.kind),
        kind: option.kind,
      );
      await services.downloads.enqueue(
        info: MediaInfo(
          url: e.url,
          title: e.title,
          raw: const {},
          thumbnail: e.thumbnail,
          uploader: e.channel ?? widget.info.uploader,
          duration: e.duration,
          extractor: widget.info.extractor,
          requestArgs: widget.info.requestArgs,
        ),
        option: option,
        fileBaseName: name,
        subtitleArgs: subtitleArgs(extras, option: option, ffmpeg: ffmpeg),
      );
    }
    if (!mounted) return;
    setState(() {
      _picked.clear();
      _queueing = false;
    });
    final navigator = Navigator.of(context, rootNavigator: true);
    showSnack(
      context,
      picked.length == 1 ? 'Downloading 1 video' : 'Downloading ${picked.length} videos',
      kind: ToastKind.success,
      actionLabel: 'View',
      onAction: () {
        navigator.popUntil((r) => r.isFirst);
        services.tabRequest.value = 1;
      },
    );
  }

  void _details(PlaylistEntry e) => showLinkDownloadSheet(
        context,
        url: e.url,
        title: e.title,
        thumbnail: e.thumbnail,
        requestArgs: widget.info.requestArgs,
      );

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = widget.info;
    final total = info.playlistCount;
    final lists = _entries.where((e) => e.isList).length;
    final onlyLists = lists == _entries.length;
    return ListenableBuilder(
      listenable: Listenable.merge([services.history, services.extras]),
      builder: (context, _) {
        final saved = {
          for (final h in services.history.entries)
            if (h.status == DownloadStatus.completed) h.url,
        };
        final full = _picked.length >= PlaylistView.maxPicked;
        return HomePanel(
          highlight: true,
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HomeSectionTitle(
                icon: onlyLists ? Icons.video_library_rounded : Icons.playlist_play_rounded,
                title: info.title,
                subtitle: [
                  if (onlyLists)
                    'Pick what to open'
                  else if (total != null)
                    '$total ${total == 1 ? 'item' : 'items'}'
                  else
                    '${_entries.length}${_hasMore ? '+' : ''} items',
                  ?info.uploader,
                ].join(' · '),
              ),
              if (!onlyLists) ...[
                const SizedBox(height: 12),
                _PickBar(
                  picked: _picked.length,
                  onPickNext: _entries.any((e) => !e.isList && !_picked.contains(e.url)) && !full ? _pickNext : null,
                  onClear: _picked.isEmpty ? null : () => setState(_picked.clear),
                ),
              ],
              const SizedBox(height: 10),
              for (final (i, entry) in _entries.indexed)
                Padding(
                  key: ValueKey(entry.url),
                  padding: const EdgeInsets.only(bottom: 6),
                  child: EntranceMotion(
                    index: i % FetchService.playlistPageSize,
                    step: const Duration(milliseconds: 30),
                    offset: 10,
                    child: _EntryRow(
                      index: i + 1,
                      entry: entry,
                      picked: _picked.contains(entry.url),
                      canPick: !full,
                      saved: saved.contains(entry.url),
                      onTap: entry.isList ? () => widget.onOpenList(entry) : () => _toggle(entry),
                      onDetails: entry.isList ? null : () => _details(entry),
                    ),
                  ),
                ),
              if (_hasMore || _loadError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    children: [
                      if (_loadError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            _loadError!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: _loadingMore ? null : _loadMore,
                        icon: _loadingMore
                            ? const SizedBox(width: 18, height: 18, child: EnergyLoader(size: 18))
                            : Icon(_loadError != null ? Icons.refresh_rounded : Icons.expand_more_rounded),
                        label: Text(_loadingMore
                            ? 'Loading…'
                            : _loadError != null
                                ? 'Try again'
                                : 'Load ${FetchService.playlistPageSize} more'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                      ),
                    ],
                  ),
                ),
              AnimatedSize(
                duration: homeDuration(context, const Duration(milliseconds: 300)),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _picked.isEmpty
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _BatchBar(
                          count: _picked.length,
                          kind: _kind ?? services.extras.presetKind,
                          durations: [for (final e in _entries) if (_picked.contains(e.url)) e.duration],
                          extras: services.extras,
                          busy: _queueing,
                          onKind: (k) => setState(() => _kind = k),
                          onDownload: () => _downloadPicked(_kind ?? services.extras.presetKind),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// "3 of 10 picked" with Pick next / Clear.
class _PickBar extends StatelessWidget {
  const _PickBar({required this.picked, required this.onPickNext, required this.onClear});

  final int picked;
  final VoidCallback? onPickNext;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            picked == 0
                ? 'Tap videos to pick them, up to ${PlaylistView.maxPicked} at a time'
                : '$picked ${picked == 1 ? 'video' : 'videos'} picked',
            maxLines: picked == 0 ? 2 : 1,
            softWrap: picked == 0,
            overflow: TextOverflow.fade,
            style: theme.textTheme.labelLarge?.copyWith(
              color: picked == 0 ? scheme.onSurfaceVariant : scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (onClear != null)
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Clear'),
          ),
        // Narrow phones: once some are picked, just the icon (the count needs
        // the room).
        if (picked > 0 && MediaQuery.sizeOf(context).width < 430)
          IconButton(
            tooltip: 'Pick more',
            visualDensity: VisualDensity.compact,
            onPressed: onPickNext,
            icon: const Icon(Icons.checklist_rounded),
          )
        else
          TextButton.icon(
            onPressed: onPickNext,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.checklist_rounded, size: 18),
            label: Text(picked == 0 ? 'Pick ${PlaylistView.maxPicked}' : 'Pick more'),
          ),
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.index,
    required this.entry,
    required this.picked,
    required this.canPick,
    required this.saved,
    required this.onTap,
    required this.onDetails,
  });

  final int index;
  final PlaylistEntry entry;
  final bool picked;

  /// Fewer than the most picked at once: unpicked rows can be picked.
  final bool canPick;

  /// Already downloaded (in History).
  final bool saved;
  final VoidCallback onTap;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = entry.isList;
    final enabled = list || picked || canPick;
    // Narrow phones: a smaller picture leaves room for the title.
    final narrow = MediaQuery.sizeOf(context).width < 430;
    final thumbWidth = narrow ? 76.0 : 96.0;
    final meta = [
      if (list) 'Open this list',
      ?entry.channel,
      if (entry.viewCount != null) '${formatCount(entry.viewCount!)} views',
    ].join(' · ');
    return PressableScale(
      scale: 0.98,
      enabled: enabled,
      child: Material(
        color: picked ? scheme.primaryContainer.withValues(alpha: 0.55) : scheme.surfaceContainerLowest.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: picked ? scheme.primary.withValues(alpha: 0.5) : Colors.transparent),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.55,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Row(
                children: [
                  if (list)
                    const SizedBox(width: 8)
                  else
                    Checkbox(
                      value: picked,
                      visualDensity: narrow ? VisualDensity.compact : null,
                      onChanged: enabled ? (_) => onTap() : null,
                    ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: SizedBox(
                      width: thumbWidth,
                      height: thumbWidth * 9 / 16,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (entry.thumbnail != null)
                            FadeInNetworkImage(
                              url: entry.thumbnail!,
                              cacheWidth: 240,
                              fallback: ColoredBox(color: scheme.surfaceContainerHighest),
                            )
                          else
                            DecoratedBox(
                              decoration: const BoxDecoration(gradient: tileGradient),
                              child: Icon(list ? Icons.video_library_rounded : Icons.movie_rounded, color: Colors.white),
                            ),
                          if (!list) Positioned(left: 4, top: 4, child: OverlayPill(text: '$index')),
                          if (entry.duration != null)
                            Positioned(right: 4, bottom: 4, child: OverlayPill(text: formatDuration(entry.duration))),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: narrow ? 10 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
                        ),
                        if (meta.isNotEmpty || saved)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(
                              children: [
                                if (saved) ...[
                                  Icon(Icons.download_done_rounded, size: 14, color: scheme.primary),
                                  const SizedBox(width: 3),
                                  Text(
                                    'Saved',
                                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
                                  ),
                                  if (meta.isNotEmpty) const SizedBox(width: 6),
                                ],
                                Expanded(
                                  child: Text(
                                    meta,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (list)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                    )
                  else
                    IconButton(
                      tooltip: 'Details and formats',
                      onPressed: onDetails,
                      icon: const Icon(Icons.info_outline_rounded),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Download the picked videos: as video or audio, with the quick download
/// presets.
class _BatchBar extends StatelessWidget {
  const _BatchBar({
    required this.count,
    required this.kind,
    required this.durations,
    required this.extras,
    required this.busy,
    required this.onKind,
    required this.onDownload,
  });

  final int count;
  final MediaKind kind;

  /// The picked videos' lengths (seconds), `null` where unknown.
  final List<double?> durations;

  /// "About 1.2 GB in total": from the lengths and the preset's bitrate (a
  /// playlist's list doesn't say how big each file is).
  String? _sizeLine() {
    final known = durations.whereType<double>().toList();
    if (known.isEmpty) return null;
    final kbps = presetBitrateKbps(extras, kind);
    final bytes = known.fold<double>(0, (sum, s) => sum + s * kbps * 1000 / 8).round();
    final missing = durations.length - known.length;
    return missing == 0
        ? 'About ${formatBytes(bytes)} in total'
        : 'About ${formatBytes(bytes)} for ${known.length} of ${durations.length} videos';
  }
  final ExtraSettings extras;
  final bool busy;
  final ValueChanged<MediaKind> onKind;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final video = 'Video · ${ExtraSettings.videoPresetLabel(extras.presetVideoHeight)}';
    final audio = 'Audio · ${extras.presetAudio.label.split(' · ').first}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SlidingSegments<MediaKind>(
            segments: [
              Segment(value: MediaKind.video, icon: Icons.movie_rounded, label: video),
              Segment(value: MediaKind.audio, icon: Icons.music_note_rounded, label: audio),
            ],
            selected: kind,
            onChanged: onKind,
          ),
          const SizedBox(height: 10),
          GradientButton(
            label: busy ? 'Adding to the queue…' : 'Download $count ${count == 1 ? 'video' : 'videos'}',
            icon: Icons.download_rounded,
            expand: true,
            height: 52,
            onPressed: busy ? null : onDownload,
          ),
          if (_sizeLine() case final size?) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.data_usage_rounded, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    size,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            Text(
              'Estimated from the videos\' length',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Qualities come from your quick download presets (Settings → Extra Settings). '
            '${extras.maxConcurrent} download at a time; the rest wait in the queue.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
