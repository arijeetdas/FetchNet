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

  @override
  void initState() {
    super.initState();
    final initial = StorageService.sanitizeFileName(widget.info.title);
    _controller = TextEditingController(text: initial.isEmpty ? StorageService.randomFileName(audio: _audio, thumbnail: _thumbnail) : initial);
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
    _controller.text = StorageService.randomFileName(audio: _audio, thumbnail: _thumbnail);
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
  }

  void _submit() {
    final services = AppScope.of(context);
    var name = StorageService.sanitizeFileName(_controller.text);
    if (name.isEmpty) name = StorageService.randomFileName(audio: _audio, thumbnail: _thumbnail);
    final reserved = services.downloads.reservedNames;
    if (services.storage.baseNameTaken(name) || reserved.contains(name.toLowerCase())) {
      setState(() {
        _error = 'A file with this name already exists in the FetchNet folder.';
        _suggestion = services.storage.uniqueBaseName(name, alsoTaken: reserved);
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
            child: Icon(_audio ? Icons.music_note_rounded : Icons.movie_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('Name your file')),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320, maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Saved to Download/FetchNet as ${widget.option.label}${widget.option.detail != null ? ' (${widget.option.detail})' : ''}.',
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
                labelText: 'File name',
                hintText: 'Leave empty for a random name',
                errorText: _error,
                errorMaxLines: 2,
                suffixText: '.${widget.option.extension}',
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
