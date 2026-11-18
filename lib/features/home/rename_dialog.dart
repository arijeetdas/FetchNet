import 'package:flutter/material.dart';

import '../../core/app_services.dart';
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

  /// Whether [name] is in use: for a post, its first numbered file.
  bool _taken(String name, Set<String> reserved) {
    final storage = AppScope.of(context).storage;
    final kind = widget.option.kind;
    if (reserved.contains(name.toLowerCase())) return true;
    return _numbered ? storage.baseNameTaken('$name 1', kind: kind) : storage.baseNameTaken(name, kind: kind);
  }

  String? get _label => switch (widget.option.kind) {
        MediaKind.image => 'Image',
        MediaKind.post => 'Post',
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
      if (_error != null) setState(() => _error = _suggestion = null);
    });
  }

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
    final services = AppScope.of(context);
    var name = StorageService.sanitizeFileName(_controller.text);
    if (name.isEmpty) name = _random();
    final reserved = services.downloads.reservedNames;
    final kind = widget.option.kind;
    if (_taken(name, reserved)) {
      var suggestion = '$name (2)';
      for (var i = 3; _taken(suggestion, reserved) && i < 1000; i++) {
        suggestion = '$name ($i)';
      }
      setState(() {
        _error = _numbered
            ? 'Files with this name already exist in FetchNet\'s Images, Audio or Video folder.'
            : 'A file with this name already exists in the FetchNet/${MediaFolder.forKind(kind).folderName} folder.';
        _suggestion = suggestion;
      });
      return;
    }
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
                errorMaxLines: 2,
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
        GradientButton(label: 'Download', icon: Icons.download_rounded, height: 48, onPressed: _submit),
      ],
    );
  }
}
