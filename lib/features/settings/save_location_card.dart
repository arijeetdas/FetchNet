import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/app_services.dart';
import '../../core/platform/device_environment.dart';
import '../../core/platform/native_bridge.dart';
import '../../services/storage_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import 'settings_widgets.dart';

/// Settings → Save location: where downloads go (Download/FetchNet unless
/// another folder is chosen), its Images, Audio and Video folders, and
/// buttons to change it, open it or go back to the default.
class SaveLocationCard extends StatefulWidget {
  const SaveLocationCard({super.key});

  @override
  State<SaveLocationCard> createState() => _SaveLocationCardState();
}

class _SaveLocationCardState extends State<SaveLocationCard> {
  bool _busy = false;

  Future<void> _change() async {
    final storage = AppScope.of(context).storage;
    Uri? uri;
    try {
      uri = await FilePicker.pickDirectory(
        dialogTitle: 'Choose where FetchNet saves downloads',
        initialDirectory: storage.downloadDir,
      );
    } catch (_) {
      if (mounted) showSnack(context, 'Couldn\'t open the folder picker.', kind: ToastKind.error);
      return;
    }
    if (uri == null || !mounted) return;
    final picked = folderPathOf(uri);
    if (picked == null) {
      await _explain('This folder isn\'t on the phone\'s own storage.');
      return;
    }
    if (storage.downloadDir != null && p.equals(p.normalize(picked), p.normalize(storage.downloadDir!))) return;
    setState(() => _busy = true);
    final change = await storage.chooseFolder(picked);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!change.ok) {
      await _explain(change.error!);
      return;
    }
    final made = change.created;
    showSnack(
      context,
      made.isEmpty
          ? 'Saving to ${storage.shortName()}. Its Images, Audio and Video folders were already there.'
          : 'Saving to ${storage.shortName()}. Made the ${_list(made)} folder${made.length == 1 ? '' : 's'}.',
      kind: ToastKind.success,
    );
  }

  Future<void> _explain(String error) => showFetchNetDialog<void>(
        context: context,
        barrierDismissible: true,
        lockBack: false,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          icon: const Icon(Icons.folder_off_rounded),
          title: const Text('Can\'t save there'),
          content: Text(
            DeviceEnvironment.isAndroid
                ? '$error\n\nPick a folder inside Download or Documents on the phone\'s storage (not a memory card).'
                : error,
          ),
          actions: [
            DialogButton(label: 'OK', icon: Icons.check_rounded, primary: true, onPressed: () => Navigator.pop(context)),
          ],
        ),
      );

  Future<void> _useDefault() async {
    final storage = AppScope.of(context).storage;
    setState(() => _busy = true);
    await storage.useDefaultFolder();
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(context, 'Saving to ${storage.shortName()} again.', kind: ToastKind.success);
  }

  static String _list(List<String> names) =>
      names.length < 2 ? names.join() : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

  @override
  Widget build(BuildContext context) {
    final storage = AppScope.of(context).storage;
    return ListenableBuilder(
      listenable: storage,
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final dir = storage.downloadDir;
        final custom = storage.isCustom && storage.customProblem == null;
        final canPick = DeviceEnvironment.isAndroid || DeviceEnvironment.isDesktop;
        return SettingsCard(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const GradientGlyph(Icons.folder_rounded),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Save location', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
                      const SizedBox(height: 2),
                      Text(
                        'Every download goes here, sorted into folders by type.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusChip(
                  label: custom ? 'Your folder' : 'Default',
                  icon: custom ? Icons.bookmark_rounded : Icons.home_rounded,
                  tone: custom ? ChipTone.accent : ChipTone.muted,
                ),
              ],
            ),
            const SizedBox(height: 14),
            // The folder, and its three subfolders.
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.folder_open_rounded, size: 18, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SelectableText(
                          dir == null ? (storage.error ?? 'Preparing…') : storage.displayPath(),
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                  if (dir != null) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final f in MediaFolder.values)
                          _FolderChip(
                            name: f.folderName,
                            icon: switch (f) {
                              MediaFolder.images => Icons.image_rounded,
                              MediaFolder.audio => Icons.music_note_rounded,
                              MediaFolder.video => Icons.movie_rounded,
                            },
                            present: Directory(p.join(dir, f.folderName)).existsSync(),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (storage.customProblem != null) ...[
              const SizedBox(height: 12),
              TipBox(icon: Icons.warning_amber_rounded, text: storage.customProblem!),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (canPick)
                  GradientButton(
                    label: 'Change folder',
                    icon: Icons.drive_folder_upload_rounded,
                    height: 44,
                    loading: _busy,
                    onPressed: _busy ? null : _change,
                  ),
                if (DeviceEnvironment.isDesktop && dir != null)
                  FilledButton.tonalIcon(
                    onPressed: () => NativeBridge.openFolder(dir),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Open'),
                  ),
                if (storage.isCustom)
                  TextButton.icon(
                    onPressed: _busy ? null : _useDefault,
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('Use default'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TipBox(
              icon: Icons.info_outline_rounded,
              text: DeviceEnvironment.isAndroid
                  ? 'Choose any folder inside Download or Documents. Missing Images, Audio and Video folders are made for you; '
                      'videos show in your Gallery and songs in music apps.'
                  : 'Choose any folder you can write to. Missing Images, Audio and Video folders are made for you; '
                      'files you already saved stay where they are.',
            ),
          ],
        );
      },
    );
  }
}

/// "✓ Audio" (there) or "+ Audio" (made on the first download).
class _FolderChip extends StatelessWidget {
  const _FolderChip({required this.name, required this.icon, required this.present});

  final String name;
  final IconData icon;
  final bool present;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: present ? '$name folder is there' : '$name folder will be made',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: present ? scheme.primaryContainer.withValues(alpha: 0.7) : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: present ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text(
              name,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: present ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A picked folder as a file path: a file URI as it is; on Android, a
/// folder of the phone's own storage (`primary:Download/Clips` →
/// `/storage/emulated/0/Download/Clips`), or the Downloads app's folder.
/// `null` for a memory card or another app's storage, which FetchNet can't
/// write to by path.
String? folderPathOf(Uri uri) {
  if (uri.scheme == 'file') return uri.toFilePath();
  if (uri.scheme.isEmpty && uri.path.startsWith('/')) return uri.path;
  if (uri.scheme != 'content') return null;
  final segments = uri.pathSegments;
  final at = segments.indexOf('tree');
  if (at < 0 || at + 1 >= segments.length) return null;
  final id = segments[at + 1];
  if (id.startsWith('raw:')) return id.substring(4);
  if (uri.host == 'com.android.providers.downloads.documents' && id == 'downloads') return '/storage/emulated/0/Download';
  if (uri.host != 'com.android.externalstorage.documents') return null;
  final colon = id.indexOf(':');
  if (colon < 0 || id.substring(0, colon) != 'primary') return null;
  final rest = id.substring(colon + 1).replaceAll(RegExp(r'/+$'), '');
  return rest.isEmpty ? '/storage/emulated/0' : '/storage/emulated/0/$rest';
}
