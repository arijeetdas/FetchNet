import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../services/lrc.dart';
import '../../services/lyrics_service.dart';
import '../../widgets/app_dialog.dart';

/// What the user chose for a song's lyrics on Home: these lyrics, or none.
class LyricsChoice {
  const LyricsChoice.use(LyricsMatch this.match) : none = false;
  const LyricsChoice.none() : match = null, none = true;

  final LyricsMatch? match;
  final bool none;
}

/// The lyrics popup: the lyrics picked for the song (with all their lines),
/// the other matches, a search of LRCLIB, and importing a `.lrc` / `.txt`
/// file. Returns the choice, or `null` when closed without one.
Future<LyricsChoice?> showLyricsPicker(
  BuildContext context, {
  required LyricsService service,
  required String videoTitle,
  required Future<LyricsLookup> lookup,
  String? searchText,
  double? duration,
  LyricsChoice? current,
}) {
  return showFetchNetDialog<LyricsChoice>(
    context: context,
    barrierDismissible: true,
    lockBack: false,
    builder: (_) => _LyricsPicker(service: service, videoTitle: videoTitle, lookup: lookup, searchText: searchText ?? '', duration: duration, current: current),
  );
}

class _LyricsPicker extends StatefulWidget {
  const _LyricsPicker({
    required this.service,
    required this.videoTitle,
    required this.lookup,
    required this.searchText,
    required this.duration,
    required this.current,
  });

  final LyricsService service;
  final String videoTitle;
  final Future<LyricsLookup> lookup;
  final String searchText;
  final double? duration;
  final LyricsChoice? current;

  @override
  State<_LyricsPicker> createState() => _LyricsPickerState();
}

class _LyricsPickerState extends State<_LyricsPicker> {
  late final TextEditingController _search = TextEditingController(text: widget.searchText);
  LyricsMatch? _best;
  List<LyricsMatch> _matches = const [];
  final List<LyricsMatch> _imported = [];
  LyricsMatch? _selected;
  bool _loading = true;

  /// What the list shows: `null` for the matches found for the video.
  String? _resultsFor;
  int _searchId = 0;

  @override
  void initState() {
    super.initState();
    _selected = widget.current?.match;
    widget.lookup.then(
      (r) {
        if (!mounted || _resultsFor != null) return;
        setState(() {
          _best = r.best;
          _matches = r.matches;
          _loading = false;
          if (widget.current == null) _selected = r.best ?? r.matches.firstOrNull;
        });
      },
      onError: (_) {
        if (mounted) setState(() => _loading = false);
      },
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final text = _search.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    final id = ++_searchId;
    setState(() {
      _loading = true;
      _resultsFor = text;
    });
    final found = await widget.service.search(text, duration: widget.duration);
    if (!mounted || id != _searchId) return;
    setState(() {
      _matches = found;
      _loading = false;
    });
  }

  Future<void> _import() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Choose a lyrics file',
        // Phones don't know .lrc as a type: any file, checked below.
        type: Theme.of(context).platform == TargetPlatform.android ? FileType.any : FileType.custom,
        allowedExtensions: Theme.of(context).platform == TargetPlatform.android ? null : const ['lrc', 'txt'],
      );
      if (files.isEmpty || !mounted) return;
      final file = files.first;
      final ext = (file.extension ?? '').toLowerCase().replaceFirst('.', '');
      if (ext != 'lrc' && ext != 'txt') {
        showSnack(context, 'Pick a .lrc or .txt lyrics file.', kind: ToastKind.error);
        return;
      }
      final bytes = await file.xFile.readAsBytes();
      if (bytes.length > 512 * 1024) {
        if (mounted) showSnack(context, 'That file is too big to be lyrics.', kind: ToastKind.error);
        return;
      }
      final match = LyricsMatch.fromFile(file.name, utf8.decode(bytes, allowMalformed: true));
      if (!mounted) return;
      if (match == null) {
        showSnack(context, 'No lyrics in that file.', kind: ToastKind.error);
        return;
      }
      setState(() {
        _imported.insert(0, match);
        _selected = match;
      });
    } on PlatformException catch (e) {
      if (mounted) showSnack(context, e.message ?? 'Couldn\'t open the file.', kind: ToastKind.error);
    } catch (_) {
      if (mounted) showSnack(context, 'Couldn\'t open the file.', kind: ToastKind.error);
    }
  }

  void _backToMatches() => setState(() {
    _searchId++;
    _resultsFor = null;
    _loading = true;
    widget.lookup.then((r) {
      if (!mounted || _resultsFor != null) return;
      setState(() {
        _matches = r.matches;
        _loading = false;
      });
    });
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final selected = _selected;
    // The pick stays at the top while other results are listed.
    final pinned = selected != null && !_imported.any((m) => m.sameAs(selected)) && !_matches.any((m) => m.sameAs(selected));
    final items = [..._imported, if (pinned) selected, ..._matches];

    final list = _MatchList(
      items: items,
      best: _resultsFor == null ? _best : null,
      selected: selected,
      loading: _loading,
      label: _resultsFor == null ? 'Matches for this song' : 'Results for “$_resultsFor”',
      onBack: _resultsFor == null ? null : _backToMatches,
      onSelect: (m) => setState(() => _selected = m),
    );
    final preview = _Preview(match: selected);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 820, maxHeight: size.height * 0.9),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
                    child: Icon(Icons.lyrics_rounded, color: scheme.onPrimaryContainer, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Lyrics', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                        Text(
                          widget.videoTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _runSearch(),
                decoration: InputDecoration(
                  hintText: 'Search LRCLIB: song and artist',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(tooltip: 'Search', onPressed: _runSearch, icon: const Icon(Icons.arrow_forward_rounded)),
                  filled: true,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: LayoutBuilder(
                  builder: (context, c) {
                    if (c.maxWidth >= 620) {
                      return SizedBox(
                        height: (size.height * 0.9 - 220).clamp(260.0, 560.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 5, child: list),
                            const SizedBox(width: 14),
                            Expanded(flex: 6, child: preview),
                          ],
                        ),
                      );
                    }
                    return SizedBox(
                      height: (size.height * 0.9 - 250).clamp(300.0, 700.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 5, child: list),
                          const SizedBox(height: 10),
                          Expanded(flex: 5, child: preview),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, c) {
                  final import = TextButton.icon(
                    onPressed: _import,
                    icon: const Icon(Icons.file_open_rounded),
                    label: const Text('Import file', maxLines: 1, overflow: TextOverflow.ellipsis),
                  );
                  final none = TextButton.icon(
                    onPressed: () => Navigator.pop(context, const LyricsChoice.none()),
                    icon: const Icon(Icons.block_rounded),
                    label: const Text('No lyrics', maxLines: 1, overflow: TextOverflow.ellipsis),
                  );
                  final use = DialogButton(
                    label: 'Use these lyrics',
                    icon: Icons.check_rounded,
                    primary: true,
                    expand: c.maxWidth < 520,
                    onPressed: selected == null ? null : () => Navigator.pop(context, LyricsChoice.use(selected)),
                  );
                  if (c.maxWidth < 520) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(child: import),
                            Flexible(child: none),
                          ],
                        ),
                        const SizedBox(height: 6),
                        use,
                      ],
                    );
                  }
                  return Row(children: [import, const SizedBox(width: 4), none, const Spacer(), use]);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MatchList extends StatelessWidget {
  const _MatchList({
    required this.items,
    required this.best,
    required this.selected,
    required this.loading,
    required this.label,
    required this.onBack,
    required this.onSelect,
  });

  final List<LyricsMatch> items;
  final LyricsMatch? best;
  final LyricsMatch? selected;
  final bool loading;
  final String label;
  final VoidCallback? onBack;
  final ValueChanged<LyricsMatch> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(onBack == null ? 14 : 4, 6, 10, 4),
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    tooltip: 'Back to the matches',
                    visualDensity: VisualDensity.compact,
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded, size: 20),
                  ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurfaceVariant),
                  ),
                ),
                if (!loading) Text('${items.length}', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        loading ? 'Looking up lyrics…' : 'No lyrics found. Try other words, or import a .lrc file.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final m = items[i];
                      final current = selected;
                      return _MatchTile(
                        match: m,
                        best: best != null && m.sameAs(best!),
                        selected: current != null && m.sameAs(current),
                        onTap: () => onSelect(m),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  const _MatchTile({required this.match, required this.best, required this.selected, required this.onTap});

  final LyricsMatch match;
  final bool best;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = match;
    final details = [
      if (m.imported) m.fileName! else if (m.artist.isNotEmpty) m.artist,
      if (m.album != null && !m.imported) m.album!,
      if (m.duration != null) formatDuration(m.duration),
    ].join(' · ');
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Material(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
              child: Row(
                children: [
                  Icon(
                    selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    size: 20,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.track.isEmpty ? 'Untitled' : m.track,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800, color: selected ? scheme.onPrimaryContainer : null),
                        ),
                        if (details.isNotEmpty)
                          Text(
                            details,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: selected ? scheme.onPrimaryContainer.withValues(alpha: 0.8) : scheme.onSurfaceVariant,
                            ),
                          ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (best) _Badge(text: 'Best match', icon: Icons.auto_awesome_rounded, strong: true),
                            if (m.imported) const _Badge(text: 'From file', icon: Icons.folder_rounded),
                            _Badge(text: m.synced ? 'Synced' : 'Plain text', icon: m.synced ? Icons.timer_outlined : Icons.notes_rounded),
                          ],
                        ),
                      ],
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

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.icon, this.strong = false});

  final String text;
  final IconData icon;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = strong ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: strong ? scheme.tertiaryContainer : scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
          ),
        ],
      ),
    );
  }
}

/// Every line of the picked lyrics, with its time when synced.
class _Preview extends StatelessWidget {
  const _Preview({required this.match});

  final LyricsMatch? match;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = match;
    final Widget body;
    if (m == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Pick lyrics to see them here.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    } else {
      final parsed = Lyrics.parse(m.lyrics);
      final lines = parsed.isSynced ? [for (final l in parsed.synced) (l.time, l.text)] : [for (final l in (parsed.plain ?? '').split('\n')) (null, l)];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.track.isEmpty ? 'Untitled' : m.track,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (m.artist.isNotEmpty || m.imported)
                  Text(
                    m.imported ? 'Imported from ${m.fileName}' : m.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              itemCount: lines.length,
              itemBuilder: (context, i) {
                final (time, text) = lines[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (time != null)
                        SizedBox(
                          width: 46,
                          child: Text(
                            _clock(time),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              height: 1.6,
                            ),
                          ),
                        ),
                      Expanded(
                        child: Text(text.isEmpty ? '♪' : text, style: theme.textTheme.bodyMedium?.copyWith(height: 1.45, fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(20)),
      child: body,
    );
  }

  static String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// The lyrics line on Home under the audio formats: what will be added
/// (looked up as soon as the song shows), with a button to see the lyrics,
/// pick others, search or import.
class LyricsCard extends StatelessWidget {
  const LyricsCard({
    super.key,
    required this.looking,
    required this.found,
    required this.choice,
    required this.isSong,
    required this.inside,
    required this.onOpen,
  });

  /// Still looking the lyrics up.
  final bool looking;

  /// What the lookup picked (when the user didn't choose).
  final LyricsMatch? found;
  final LyricsChoice? choice;

  /// The video looked like a song (so lyrics are looked up by themselves).
  final bool isSong;

  /// They go inside the song (else as a .lrc file).
  final bool inside;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final where = inside ? 'added inside the song' : 'saved as a .lrc file';
    final picked = choice?.match;
    final (String title, String detail, IconData icon) = switch (choice) {
      LyricsChoice(none: true) => ('No lyrics', 'You chose to download this song without lyrics.', Icons.block_rounded),
      _ when picked != null && picked.imported => ('Lyrics from ${picked.fileName}', 'Will be $where.', Icons.folder_rounded),
      _ when picked != null => (
        '“${picked.track}”${picked.artist.isEmpty ? '' : ' · ${picked.artist}'}',
        '${picked.synced ? 'Synced lyrics' : 'Plain lyrics'} you picked, $where.',
        Icons.lyrics_rounded,
      ),
      _ when looking => ('Looking up lyrics…', 'Searching LRCLIB for this song.', Icons.lyrics_outlined),
      _ when found != null => ('“${found!.track}”${found!.artist.isEmpty ? '' : ' · ${found!.artist}'}', 'Synced lyrics found, $where.', Icons.lyrics_rounded),
      _ when isSong => ('No synced lyrics found', 'Search LRCLIB yourself, or import a .lrc file.', Icons.search_off_rounded),
      _ => ('Add lyrics?', 'Search LRCLIB, or import a .lrc file for this song.', Icons.lyrics_outlined),
    };
    return Material(
      color: scheme.surfaceContainerLowest.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              if (looking && choice == null)
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.primary))
              else
                Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: onOpen,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: Icon(picked != null || found != null ? Icons.visibility_rounded : Icons.search_rounded, size: 18),
                label: Text(picked != null || (found != null && choice == null) ? 'View' : 'Find'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
