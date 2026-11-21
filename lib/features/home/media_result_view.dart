import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../engine/engine.dart';
import '../../models/media_info.dart';
import '../../services/extra_settings.dart';
import '../../services/lyrics_service.dart';
import 'lyrics_picker.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/motion/motion_core.dart';
import 'home_kit.dart';
import 'media_preview.dart';
import 'rename_dialog.dart';

/// One video or song: its preview, then the qualities (video), formats
/// (audio) and thumbnail sizes (YouTube) to pick from, and its tags.
class MediaResultView extends StatefulWidget {
  const MediaResultView({super.key, required this.info, this.framed = true, this.onQueued});

  final MediaInfo info;

  /// Draw the card around it (off inside sheets that have their own surface).
  final bool framed;

  /// Called once a download was queued (e.g. to close a popup).
  final VoidCallback? onQueued;

  @override
  State<MediaResultView> createState() => _MediaResultViewState();
}

class _MediaResultViewState extends State<MediaResultView> {
  late MediaKind _kind = widget.info.preferAudio ? MediaKind.audio : MediaKind.video;

  /// The option picked on the current tab; `null` until the user picks one
  /// (the quick download preset's choice is selected meanwhile).
  int? _selected;

  /// Subtitle tracks picked; `null` until the user changes them (the ones
  /// the settings ask for are picked meanwhile).
  Set<String>? _subtitles;

  /// YouTube thumbnail sizes that exist for this video, probed once.
  Future<List<DownloadOption>>? _thumbnails;
  List<DownloadOption>? _thumbnailOptions;

  // Lyrics for a song saved as audio: looked up as soon as the audio
  // formats show, so the card can say what will be added.
  Future<LyricsLookup>? _lyricsLookup;
  LyricsLookup? _lyricsResult;
  LyricsChoice? _lyricsChoice;
  LyricsService? _lyricsService;

  LyricsService _lyrics(AppServices services) => _lyricsService ??= services.downloads.lyricsService ?? LyricsService();

  void _loadLyrics(AppServices services, LyricsQuery? song) {
    if (_lyricsLookup != null) return;
    if (song == null) {
      _lyricsResult = LyricsLookup.empty;
      _lyricsLookup = Future.value(LyricsLookup.empty);
      return;
    }
    _lyricsLookup = _lyrics(services).lookup(song).timeout(const Duration(seconds: 45), onTimeout: () => LyricsLookup.empty).then((r) {
      if (mounted) setState(() => _lyricsResult = r);
      return r;
    });
  }

  Future<void> _openLyrics(AppServices services, LyricsQuery? song) async {
    _loadLyrics(services, song);
    final choice = await showLyricsPicker(
      context,
      service: _lyrics(services),
      videoTitle: widget.info.title,
      lookup: _lyricsLookup!,
      searchText: song?.searchPhrases.firstOrNull ?? LyricsQuery.cleanTitle(widget.info.title),
      duration: widget.info.duration,
      current: _lyricsChoice,
    );
    if (choice != null && mounted) setState(() => _lyricsChoice = choice);
  }

  void _loadThumbnails() {
    if (_thumbnails != null) return;
    _thumbnails = probeThumbnails(widget.info).then((list) {
      if (mounted) setState(() => _thumbnailOptions = list);
      return list;
    });
  }

  Future<void> _download(DownloadOption option, {List<String>? subtitleLanguages}) async {
    final services = AppScope.of(context);
    if (services.storage.downloadDir == null) {
      await services.storage.ensureDownloadDir(requestPermission: true);
      if (!mounted) return;
      if (services.storage.downloadDir == null) {
        showSnack(context, services.storage.error ?? 'The download folder isn\'t available.', kind: ToastKind.error);
        return;
      }
    }
    final name = await showRenameDialog(context, info: widget.info, option: option);
    if (name == null || !mounted) return;
    // The lyrics picked in the popup, else the ones the card found.
    final choice = _lyricsChoice;
    await services.downloads.enqueue(
      info: widget.info,
      option: option,
      fileBaseName: name,
      lyricsText: choice?.match?.lyrics ?? (choice == null ? _lyricsResult?.best?.lyrics : null),
      noLyrics: choice?.none ?? false,
      subtitleArgs: subtitleArgs(
        services.extras,
        option: option,
        ffmpeg: services.engine.status.value.ffmpegAvailable,
        languages: subtitleLanguages,
      ),
    );
    if (!mounted) return;
    // Works from screens pushed over the main tabs (YouTube) too.
    final navigator = Navigator.of(context, rootNavigator: true);
    showSnack(
      context,
      'Downloading $name.${option.extension}',
      kind: ToastKind.success,
      actionLabel: 'View',
      onAction: () {
        navigator.popUntil((r) => r.isFirst);
        services.tabRequest.value = 1;
      },
    );
    widget.onQueued?.call();
  }

  Widget _lyricsCard(AppServices services, {required bool inside}) {
    final song = LyricsQuery.fromInfo(widget.info);
    _loadLyrics(services, song);
    return LyricsCard(
      looking: _lyricsResult == null,
      found: _lyricsResult?.best,
      choice: _lyricsChoice,
      isSong: song != null,
      inside: inside,
      onOpen: () => _openLyrics(services, song),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([services.engine.status, services.youtube, services.extras]),
      builder: (context, _) {
        final status = services.engine.status.value;
        final extras = services.extras;
        final youtube = widget.info.isYouTube;
        final showThumbnails = youtube && services.youtube.thumbnailDownloads;
        final showTags = youtube && services.youtube.showTags;
        if (showThumbnails) _loadThumbnails();

        final ffmpeg = status.ffmpegAvailable;
        final video = widget.info.videoOptions(ffmpeg: ffmpeg);
        final audio = widget.info.audioOptions(ffmpeg: ffmpeg);
        final thumbs = _thumbnailOptions ?? const <DownloadOption>[];
        var kind = _kind;
        if (kind == MediaKind.thumbnail && !showThumbnails) kind = MediaKind.video;
        if (kind == MediaKind.video && video.isEmpty && audio.isNotEmpty) kind = MediaKind.audio;
        if (kind == MediaKind.audio && audio.isEmpty && video.isNotEmpty) kind = MediaKind.video;
        final options = switch (kind) {
          MediaKind.video => video,
          MediaKind.audio => audio,
          MediaKind.thumbnail => thumbs,
          // Posts and images have their own view (PostResultView).
          MediaKind.image || MediaKind.post || MediaKind.subtitle => const <DownloadOption>[],
        };
        // Until the user picks, the quick download preset's choice.
        final index = _selected ??
            switch (kind) {
              MediaKind.video => presetVideoIndex(options, extras.presetVideoHeight),
              MediaKind.audio => presetAudioIndex(options, extras.presetAudio),
              _ => 0,
            };
        final selected = options.isEmpty ? null : options[index.clamp(0, options.length - 1)];
        // Thumbnails are plain image downloads: no need to wait for yt-dlp.
        final canDownload = selected != null && (kind == MediaKind.thumbnail || status.isReady);

        // Subtitles (Settings → Extra Settings), for videos that have any.
        final tracks = extras.subtitles && kind == MediaKind.video
            ? subtitleTracksOf(widget.info, wanted: extras.subtitleLanguageCodes)
            : const <SubtitleTrack>[];
        final picks = _subtitles ?? defaultSubtitlePicks(tracks, extras);

        final header = _MediaHeader(info: widget.info);
        final picker = _OptionPicker(
          kind: kind,
          videoCount: video.length,
          audioCount: audio.length,
          showThumbnails: showThumbnails,
          thumbnailsLoading: showThumbnails && _thumbnailOptions == null,
          thumbnailCount: _thumbnailOptions?.length,
          options: options,
          selected: selected,
          ffmpegMissing: !ffmpeg && kind != MediaKind.thumbnail,
          canInstallFfmpeg: services.engine.canInstallComponents && status.state == EngineState.ready,
          tags: showTags ? widget.info.tags : null,
          subtitles: tracks.isNotEmpty
              ? _SubtitlePicker(
                  tracks: tracks,
                  picked: picks,
                  note: _subtitleNote(extras, ffmpeg),
                  onChanged: (v) => setState(() => _subtitles = v),
                )
              // A song saved as audio: its lyrics, found (or picked) now.
              : kind == MediaKind.audio && extras.lyrics
                  ? _lyricsCard(services, inside: ffmpeg && extras.mergeLyrics)
                  : null,
          onKind: (k) => setState(() {
            _kind = k;
            _selected = null;
          }),
          onSelect: (o) => setState(() => _selected = options.indexOf(o)),
          onDownload: canDownload
              ? () => _download(
                    selected,
                    // A video without subtitles gets none; otherwise the picked tracks.
                    subtitleLanguages: kind == MediaKind.video && extras.subtitles ? picks.toList() : null,
                  )
              : null,
        );

        return LayoutBuilder(builder: (context, c) {
          final twoColumn = c.maxWidth >= 820;
          final body = twoColumn
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: header),
                    const SizedBox(width: 26),
                    Expanded(flex: 6, child: picker),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [header, const SizedBox(height: 20), picker],
                );
          if (!widget.framed) return body;
          return HomePanel(highlight: true, padding: EdgeInsets.all(twoColumn ? 22 : 14), child: body);
        });
      },
    );
  }
}

/// "Saved as SRT · separate files" for the subtitle picker.
String _subtitleNote(ExtraSettings s, bool ffmpeg) {
  final mode = ffmpeg ? s.subtitleMode : SubtitleMode.file;
  final how = switch (mode) {
    SubtitleMode.file => 'separate files',
    SubtitleMode.embed => 'inside the video',
    SubtitleMode.both => 'inside the video and as files',
  };
  final format = s.subtitleFormat == SubtitleFormat.best ? 'the site\'s format' : s.subtitleFormat.label;
  return 'Saved as $format, $how · change in Settings → Extra Settings';
}

/// Subtitle tracks of a video to save with it.
class _SubtitlePicker extends StatelessWidget {
  const _SubtitlePicker({required this.tracks, required this.picked, required this.note, required this.onChanged});

  final List<SubtitleTrack> tracks;
  final Set<String> picked;
  final String note;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.closed_caption_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Subtitles', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              ),
              Text(
                picked.isEmpty ? 'None' : '${picked.length} picked',
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in tracks)
                FilterChip(
                  label: Text(t.automatic ? '${t.name} · auto' : t.name),
                  selected: picked.contains(t.code),
                  onSelected: (on) => onChanged(on ? {...picked, t.code} : ({...picked}..remove(t.code))),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(note, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ───────────── Preview & details ─────────────

class _MediaHeader extends StatelessWidget {
  const _MediaHeader({required this.info});

  final MediaInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = info.thumbnail;
    final heroTag = 'media-cover-${info.url}';
    final chips = <Widget>[
      if (info.extractor != null) MetaChip(icon: Icons.public_rounded, text: info.extractor!, strong: true),
      if (info.uploader != null) MetaChip(icon: Icons.person_rounded, text: info.uploader!),
      if (info.viewCount != null) MetaChip(icon: Icons.visibility_rounded, text: '${formatCount(info.viewCount)} views'),
      if (info.duration != null && !info.isLive) MetaChip(icon: Icons.schedule_rounded, text: formatDuration(info.duration)),
    ];

    final preview = AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // A soft glow of the picture itself behind the frame.
          if (cover != null && homeMotion(context))
            Positioned(
              left: 18,
              right: 18,
              top: 22,
              bottom: -16,
              child: IgnorePointer(
                child: Opacity(
                  opacity: Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.4,
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22, tileMode: TileMode.decal),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(30),
                      child: Image.network(cover, fit: BoxFit.cover, cacheWidth: 240, errorBuilder: (_, _, _) => const SizedBox()),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: cover == null
                      ? null
                      : () => showMediaPreview(
                            context,
                            items: [PreviewItem(url: cover, caption: info.title, heroTag: heroTag)],
                          ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Hero(
                        tag: heroTag,
                        child: cover == null
                            ? const _CoverFallback()
                            : FadeInNetworkImage(url: cover, fallback: const _CoverFallback()),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x40000000), Color(0x00000000), Color(0x00000000), Color(0x8A000000)],
                            stops: [0, 0.28, 0.6, 1],
                          ),
                        ),
                      ),
                      if (info.isLive)
                        const Positioned(
                          left: 12,
                          top: 12,
                          child: OverlayPill(text: 'LIVE', icon: Icons.sensors_rounded, color: Color(0xE6E11D48)),
                        ),
                      if (cover != null)
                        const Positioned(right: 12, top: 12, child: OverlayPill(text: 'View', icon: Icons.zoom_out_map_rounded)),
                      if (info.duration != null && !info.isLive)
                        Positioned(right: 12, bottom: 12, child: OverlayPill(text: formatDuration(info.duration))),
                      if (info.isYouTubeMusic)
                        const Positioned(left: 12, bottom: 12, child: OverlayPill(text: 'Music', icon: Icons.music_note_rounded)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntranceMotion(child: preview),
        const SizedBox(height: 16),
        EntranceMotion(
          index: 1,
          child: Text(
            info.title,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.25),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 10),
          EntranceMotion(index: 2, child: Wrap(spacing: 6, runSpacing: 6, children: chips)),
        ],
      ],
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(gradient: tileGradient),
      child: Center(child: Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 56)),
    );
  }
}

// ───────────── Picker ─────────────

class _OptionPicker extends StatelessWidget {
  const _OptionPicker({
    required this.kind,
    required this.videoCount,
    required this.audioCount,
    required this.showThumbnails,
    required this.thumbnailsLoading,
    required this.thumbnailCount,
    required this.options,
    required this.selected,
    required this.ffmpegMissing,
    required this.canInstallFfmpeg,
    required this.tags,
    required this.onKind,
    required this.onSelect,
    required this.onDownload,
    this.subtitles,
  });

  /// The subtitle picker (videos with subtitles, when they're turned on).
  final Widget? subtitles;

  final MediaKind kind;
  final int videoCount;
  final int audioCount;
  final bool showThumbnails;
  final bool thumbnailsLoading;
  final int? thumbnailCount;

  /// YouTube tags to list under the Download button, or `null` to hide them.
  final List<String>? tags;
  final List<DownloadOption> options;
  final DownloadOption? selected;
  final bool ffmpegMissing;
  final bool canInstallFfmpeg;
  final ValueChanged<MediaKind> onKind;
  final ValueChanged<DownloadOption> onSelect;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sel = selected;

    final Widget grid;
    if (options.isEmpty && kind == MediaKind.thumbnail && thumbnailsLoading) {
      grid = const Padding(
        key: ValueKey('thumbs-loading'),
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(child: EnergyLoader(size: 40)),
      );
    } else if (options.isEmpty) {
      grid = Padding(
        key: ValueKey('empty-$kind'),
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          kind == MediaKind.thumbnail
              ? 'No thumbnails are available for this video.'
              : 'No ${kind.name} formats are available for this link.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    } else {
      grid = _OptionGrid(
        key: ValueKey('grid-$kind'),
        kind: kind,
        options: options,
        selected: sel,
        onSelect: onSelect,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SlidingSegments<MediaKind>(
          segments: [
            Segment(value: MediaKind.video, icon: Icons.movie_rounded, label: 'Video', count: videoCount, enabled: videoCount > 0),
            Segment(value: MediaKind.audio, icon: Icons.music_note_rounded, label: 'Audio', count: audioCount, enabled: audioCount > 0),
            if (showThumbnails)
              Segment(value: MediaKind.thumbnail, icon: Icons.image_rounded, label: 'Thumbnail', count: thumbnailCount),
          ],
          selected: kind,
          onChanged: onKind,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: homeDuration(context, const Duration(milliseconds: 220)),
                layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                child: Text(
                  switch (kind) {
                    MediaKind.video => 'Pick a quality',
                    MediaKind.audio => 'Pick a format',
                    MediaKind.thumbnail => 'Pick a size',
                    MediaKind.image || MediaKind.post || MediaKind.subtitle => 'Pick files',
                  },
                  key: ValueKey(kind),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            if (options.length > 1)
              Text(
                '${options.length} options',
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        const SizedBox(height: 10),
        AnimatedSize(
          duration: homeDuration(context, const Duration(milliseconds: 320)),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: homeDuration(context, const Duration(milliseconds: 260)),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(a),
                child: child,
              ),
            ),
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: grid,
          ),
        ),
        if (ffmpegMissing) ...[
          const SizedBox(height: 12),
          _FfmpegHint(canInstall: canInstallFfmpeg),
        ],
        if (subtitles != null) ...[
          const SizedBox(height: 14),
          subtitles!,
        ],
        const SizedBox(height: 16),
        GradientButton(
          label: sel == null
              ? 'Download'
              : 'Download ${sel.label}${sel.sizeBytes != null ? '  ·  ~${formatBytes(sel.sizeBytes)}' : ''}',
          icon: Icons.download_rounded,
          expand: true,
          height: 56,
          onPressed: onDownload,
        ),
        if (tags != null) ...[
          const SizedBox(height: 16),
          _TagsCard(tags: tags!),
        ],
      ],
    );
  }
}

/// The choices as cards, two or three across.
class _OptionGrid extends StatelessWidget {
  const _OptionGrid({super.key, required this.kind, required this.options, required this.selected, required this.onSelect});

  final MediaKind kind;
  final List<DownloadOption> options;
  final DownloadOption? selected;
  final ValueChanged<DownloadOption> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 10.0;
      final columns = kind == MediaKind.thumbnail
          ? (c.maxWidth >= 560 ? 3 : 2)
          : (c.maxWidth >= 600 ? 4 : c.maxWidth >= 380 ? 3 : 2);
      final width = (c.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final (i, o) in options.indexed)
            SizedBox(
              width: width,
              child: EntranceMotion(
                index: i,
                step: const Duration(milliseconds: 35),
                offset: 12,
                child: kind == MediaKind.thumbnail
                    ? _ThumbnailCard(option: o, selected: identical(o, selected), onTap: () => onSelect(o))
                    : _FormatCard(option: o, kind: kind, selected: identical(o, selected), onTap: () => onSelect(o)),
              ),
            ),
        ],
      );
    });
  }
}

/// The frame shared by option cards: a gradient edge and a check when
/// selected.
class _SelectableFrame extends StatelessWidget {
  const _SelectableFrame({required this.selected, required this.onTap, required this.child, this.onLongPress, this.label});

  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = homeDuration(context, const Duration(milliseconds: 240));
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: PressableScale(
        child: AnimatedContainer(
          duration: d,
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.all(selected ? 2 : 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: selected ? AppColors.brandGradient : null,
            color: selected ? null : scheme.outlineVariant.withValues(alpha: 0.45),
            boxShadow: selected
                ? [BoxShadow(color: AppColors.violetBright.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 7))]
                : null,
          ),
          child: Material(
            color: selected
                ? Color.alphaBlend(scheme.primaryContainer.withValues(alpha: 0.5), scheme.surfaceContainerLowest)
                : scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(selected ? 18 : 19),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: Stack(
                children: [
                  child,
                  Positioned(
                    right: 8,
                    top: 8,
                    child: AnimatedScale(
                      scale: selected ? 1 : 0,
                      duration: d,
                      curve: springCurve,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: const BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
                        child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
                      ),
                    ),
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

/// A video quality or an audio format.
class _FormatCard extends StatelessWidget {
  const _FormatCard({required this.option, required this.kind, required this.selected, required this.onTap});

  final DownloadOption option;
  final MediaKind kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final audio = kind == MediaKind.audio;
    return _SelectableFrame(
      selected: selected,
      onTap: onTap,
      label: [option.label, ?option.detail, if (option.sizeBytes != null) formatBytes(option.sizeBytes)].join(', '),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  audio ? Icons.graphic_eq_rounded : Icons.hd_rounded,
                  size: 18,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                if (option.badge != null) ...[const SizedBox(width: 6), GradientBadge(option.badge!)],
                const SizedBox(width: 26),
              ],
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                option.label,
                maxLines: 1,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
            ),
            if (option.detail != null)
              Text(
                option.detail!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.3),
              ),
            const SizedBox(height: 6),
            Text(
              option.sizeBytes == null ? 'Size unknown' : '~${formatBytes(option.sizeBytes)}',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: option.sizeBytes == null ? scheme.outline : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A YouTube thumbnail size, with the picture itself.
class _ThumbnailCard extends StatelessWidget {
  const _ThumbnailCard({required this.option, required this.selected, required this.onTap});

  final DownloadOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final url = option.directUrl;
    void preview() {
      if (url != null) showMediaPreview(context, items: [PreviewItem(url: url, caption: '${option.label} · ${option.detail ?? ''}')]);
    }

    return _SelectableFrame(
      selected: selected,
      onTap: onTap,
      onLongPress: preview,
      label: [option.label, ?option.detail].join(', '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (url != null)
                  FadeInNetworkImage(
                    url: url,
                    cacheWidth: 360,
                    fallback: ColoredBox(color: scheme.surfaceContainerHighest, child: Icon(Icons.image_rounded, color: scheme.outline)),
                  )
                else
                  ColoredBox(color: scheme.surfaceContainerHighest),
                if (url != null)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: preview,
                        child: const Padding(
                          padding: EdgeInsets.all(5),
                          child: Icon(Icons.zoom_in_rounded, size: 16, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: selected ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                    ),
                    if (option.badge != null) ...[const SizedBox(width: 6), GradientBadge(option.badge!)],
                  ],
                ),
                Text(
                  [?option.detail, if (option.sizeBytes != null) formatBytes(option.sizeBytes)].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "HD and MP3 need FFmpeg", with a one-tap install where FetchNet can.
class _FfmpegHint extends StatefulWidget {
  const _FfmpegHint({required this.canInstall});

  final bool canInstall;

  @override
  State<_FfmpegHint> createState() => _FfmpegHintState();
}

class _FfmpegHintState extends State<_FfmpegHint> {
  bool _busy = false;

  Future<void> _install() async {
    final services = AppScope.of(context);
    setState(() => _busy = true);
    try {
      await services.engine.installComponent(EngineComponent.ffmpeg);
      if (mounted) showSnack(context, 'FFmpeg installed: HD and MP3 unlocked', kind: ToastKind.success);
    } catch (e) {
      if (mounted) showSnack(context, 'FFmpeg install failed: $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_rounded, size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.canInstall
                  ? 'HD qualities and MP3 need FFmpeg.'
                  : 'Install FFmpeg (Settings → Engines) for HD qualities and MP3.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onTertiaryContainer, height: 1.35),
            ),
          ),
          if (widget.canInstall)
            TextButton.icon(
              onPressed: _busy ? null : _install,
              icon: _busy ? const EnergyLoader(size: 16) : const Icon(Icons.download_rounded, size: 18),
              label: const Text('Install'),
            ),
        ],
      ),
    );
  }
}

// ───────────── Tags ─────────────

class _TagsCard extends StatefulWidget {
  const _TagsCard({required this.tags});

  final List<String> tags;

  @override
  State<_TagsCard> createState() => _TagsCardState();
}

class _TagsCardState extends State<_TagsCard> {
  static const _preview = 14;
  bool _all = false;

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showSnack(context, message, kind: ToastKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tags = widget.tags;
    final shown = _all ? tags : tags.take(_preview).toList();
    final hidden = tags.length - shown.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.sell_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tags.isEmpty ? 'Tags' : 'Tags · ${tags.length}',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (tags.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _copy(tags.join(', '), '${tags.length} tags copied'),
                  icon: const Icon(Icons.copy_all_rounded, size: 18),
                  label: const Text('Copy all'),
                ),
            ],
          ),
          if (tags.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'This video has no tags.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8, right: 4),
              child: Text(
                'Tap a tag to copy it.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            AnimatedSize(
              duration: homeDuration(context, const Duration(milliseconds: 320)),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (i, t) in shown.indexed)
                    EntranceMotion(
                      key: ValueKey('tag-$t'),
                      index: i >= _preview ? i - _preview : i,
                      step: const Duration(milliseconds: 20),
                      offset: 6,
                      child: _TagChip(tag: t, onTap: () => _copy(t, 'Copied “$t”')),
                    ),
                  if (hidden > 0 || _all && tags.length > _preview)
                    ActionChip(
                      avatar: Icon(_all ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                      label: Text(_all ? 'Show less' : '+$hidden more'),
                      onPressed: () => setState(() => _all = !_all),
                      shape: const StadiumBorder(),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, required this.onTap});

  final String tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PressableScale(
      child: Material(
        color: scheme.secondaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            child: Text(
              '#$tag',
              style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

/// Checks which YouTube thumbnail sizes exist for [info] (missing sizes
/// answer 404) and turns them into download options, largest first.
Future<List<DownloadOption>> probeThumbnails(MediaInfo info) async {
  final candidates = info.youtubeThumbnailCandidates;
  if (candidates.isEmpty) return const [];
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final sizes = await Future.wait(candidates.map((c) async {
      try {
        final req = await http.headUrl(Uri.parse(c.url));
        final res = await req.close().timeout(const Duration(seconds: 10));
        await res.drain<void>();
        if (res.statusCode != 200) return null;
        return res.contentLength > 0 ? res.contentLength : 0;
      } catch (_) {
        return -1; // unknown (network): keep only the sizes every video has
      }
    }));
    final options = <DownloadOption>[];
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      final size = sizes[i];
      if (size == null) continue;
      if (size < 0 && !c.url.contains('hqdefault') && !c.url.contains('mqdefault')) continue;
      final ext = c.extension;
      options.add(DownloadOption(
        kind: MediaKind.thumbnail,
        label: c.label,
        detail: '${c.width}×${c.height} · ${ext.toUpperCase()}',
        badge: c.width >= 1280 || c.height >= 1280 ? 'HD' : null,
        sizeBytes: size > 0 ? size : null,
        extension: ext,
        formatArgs: const [],
        directUrl: c.url,
      ));
    }
    return options;
  } finally {
    http.close(force: true);
  }
}
