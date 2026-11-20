import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/app_services.dart';
import '../../models/download_models.dart';
import '../../models/media_info.dart';
import '../../services/storage_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';

/// Asks for the file name before a download starts. Returns the final base
/// name (without extension), or `null` when cancelled. An empty field gets a
/// random name.
Future<String?> showRenameDialog(
  BuildContext context, {
  required MediaInfo info,
  required DownloadOption option,
}) {
  return showFetchNetDialog<String>(
    context: context,
    lockBack: false,
    builder: (context) => _RenameDialog(info: info, option: option),
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.info, required this.option});

  final MediaInfo info;
  final DownloadOption option;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;
  String? _error;
  String? _suggestion;

  bool get _audio => widget.option.kind == MediaKind.audio;
  bool get _thumbnail => widget.option.kind == MediaKind.thumbnail;

  /// Several files of a post: they're numbered (`name 1`, `name 2`, ...)
  /// straight into the Images, Audio and Video folders.
  bool get _numbered => widget.option.kind == MediaKind.post;

  /// Why [name] can't be used, or `null` when it's free. A name is taken by
  /// a download in the queue, a file in the folder (for a post, its first
  /// numbered file), or a download in History, even one whose file was
  /// deleted since: reusing that name would mix the two up.
  String? _conflict(String name, Set<String> reserved) {
    final services = AppScope.of(context);
    final storage = services.storage;
    final kind = widget.option.kind;
    if (reserved.contains(name.toLowerCase())) return 'A download in the queue already uses this name.';
    final onDisk = _numbered ? storage.baseNameTaken('$name 1', kind: kind) : storage.baseNameTaken(name, kind: kind);
    if (onDisk) {
      return _numbered
          ? 'Files with this name already exist in FetchNet\'s Images, Audio or Video folder.'
          : 'A file with this name already exists in the FetchNet/${MediaFolder.forKind(kind).folderName} folder.';
    }
    final used = services.downloads.historyEntryNamed(name, kind);
    if (used != null) {
      final exists = used.allFiles.any((f) => File(f).existsSync());
      return exists
          ? 'A download in your History already uses this name.'
          : 'A download in your History used this name, but its file was deleted (from your gallery or file '
              'manager, for example). Pick another name so the two aren\'t mixed up.';
    }
    return null;
  }

  bool _taken(String name, Set<String> reserved) => _conflict(name, reserved) != null;

  /// The same video (or song, picture...) saved before, maybe under another
  /// name: shown above the name.
  List<HistoryEntry> _copies = const [];

  /// Checks [name]: when it's taken, says why and suggests a free one.
  /// Returns whether it's free.
  bool _check(String name) {
    final reserved = AppScope.of(context).downloads.reservedNames;
    final why = _conflict(name, reserved);
    if (why == null) {
      if (_error != null) setState(() => _error = _suggestion = null);
      return true;
    }
    var suggestion = '$name (2)';
    for (var i = 3; _taken(suggestion, reserved) && i < 1000; i++) {
      suggestion = '$name ($i)';
    }
    setState(() {
      _error = why;
      _suggestion = suggestion;
    });
    return false;
  }

  String? get _label => switch (widget.option.kind) {
        MediaKind.image => 'Image',
        MediaKind.post => 'Post',
        MediaKind.subtitle => 'Subtitles',
        _ => null,
      };

  String _random() => StorageService.randomFileName(audio: _audio, thumbnail: _thumbnail, label: _label);

  @override
  void initState() {
    super.initState();
    final initial = StorageService.sanitizeFileName(widget.info.title);
    _controller = TextEditingController(text: initial.isEmpty ? _random() : initial);
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
    _controller.addListener(() {
      if (_error != null && _controller.text != _checkedText) setState(() => _error = _suggestion = null);
    });
    // Says right away when the suggested name is taken, or the same media
    // was saved before.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final downloads = AppScope.of(context).downloads;
      setState(() => _copies = [
            for (final e in downloads.savedCopiesOf(widget.info.url))
              if (e.kind == widget.option.kind) e,
          ]);
      _checkedText = _controller.text;
      final name = StorageService.sanitizeFileName(_controller.text);
      if (name.isNotEmpty) _check(name);
    });
  }

  /// The text that was last checked (its error stays until it changes).
  String? _checkedText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _randomize() {
    _controller.text = _random();
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
  }

  void _submit() {
    var name = StorageService.sanitizeFileName(_controller.text);
    if (name.isEmpty) name = _random();
    _checkedText = _controller.text;
    if (!_check(name)) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      title: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(gradient: AppColors.brandGradient, borderRadius: BorderRadius.circular(13)),
            child: Icon(
              switch (widget.option.kind) {
                MediaKind.audio => Icons.music_note_rounded,
                MediaKind.image || MediaKind.thumbnail => Icons.photo_rounded,
                MediaKind.post => Icons.collections_rounded,
                MediaKind.subtitle => Icons.closed_caption_rounded,
                MediaKind.video => Icons.movie_rounded,
              },
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(_numbered ? 'Name the files' : 'Name your file')),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _numbered
                  ? 'Saved to Download/FetchNet as ${widget.option.label}${widget.option.detail != null ? ' (${widget.option.detail})' : ''}, '
                      'numbered (name 1, name 2, …) straight into its Images, Audio and Video folders.'
                  : 'Saved to Download/FetchNet/${MediaFolder.forKind(widget.option.kind).folderName} as '
                      '${widget.option.label}${widget.option.detail != null ? ' (${widget.option.detail})' : ''}.',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (_copies.isNotEmpty) ...[
              const SizedBox(height: 12),
              _SavedBefore(entry: _copies.first, kind: widget.option.kind),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 120,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: _numbered ? 'File names' : 'File name',
                hintText: 'Leave empty for a random name',
                errorText: _error,
                errorMaxLines: 4,
                suffixText: _numbered
                    ? ' 1, 2, …'
                    : widget.option.extension.isEmpty
                    ? null
                    : '.${widget.option.extension}',
                suffixIcon: IconButton(
                  tooltip: 'Random name',
                  icon: const Icon(Icons.casino_rounded),
                  onPressed: _randomize,
                ),
              ),
            ),
            if (_suggestion != null)
              Align(
                alignment: Alignment.centerLeft,
                child: ActionChip(
                  avatar: const Icon(Icons.auto_fix_high_rounded, size: 18),
                  label: Text('Use "$_suggestion"'),
                  onPressed: () {
                    final s = _suggestion!;
                    _controller.text = s;
                    Navigator.pop(context, s);
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        DialogButton(label: 'Cancel', icon: Icons.close_rounded, onPressed: () => Navigator.pop(context)),
        GradientButton(
          label: _copies.isNotEmpty ? 'Download again' : 'Download',
          icon: Icons.download_rounded,
          height: 48,
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// "You already saved this video as “Name.mp4”."
class _SavedBefore extends StatelessWidget {
  const _SavedBefore({required this.entry, required this.kind});

  final HistoryEntry entry;
  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final file = entry.files.length > 1
        ? '“${entry.fileName}” (${entry.files.length} files)'
        : '“${entry.filePath == null ? entry.fileName : p.basename(entry.filePath!)}”';
    final noun = switch (kind) {
      MediaKind.video => 'video',
      MediaKind.audio => 'audio',
      MediaKind.thumbnail => 'thumbnail',
      MediaKind.image => 'picture',
      MediaKind.post => 'post',
      MediaKind.subtitle => 'subtitle file',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'You already saved this $noun as $file. Download it again under a new name, or cancel.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onTertiaryContainer, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
