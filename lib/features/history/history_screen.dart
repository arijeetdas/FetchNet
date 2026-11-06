import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_services.dart';
import '../../core/format.dart';
import '../../core/platform/native_bridge.dart';
import '../../models/download_models.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/kind_icon.dart';
import '../../widgets/motion/page_motions.dart';
import '../shell/home_shell.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _query = '';
  DownloadStatus? _filter;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: services.history,
      builder: (context, _) {
        final all = services.history.entries;
        final q = _query.toLowerCase();
        final entries = all.where((e) {
          if (_filter != null && e.status != _filter) return false;
          if (q.isEmpty) return true;
          return e.title.toLowerCase().contains(q) || e.fileName.toLowerCase().contains(q) || e.url.toLowerCase().contains(q);
        }).toList();

        return PageFrame(
          title: 'History',
          subtitle: all.isEmpty ? null : '${all.length} download${all.length == 1 ? '' : 's'}',
          leading: const PageGlyph(PageGlyphKind.history),
          actions: [
            if (all.isNotEmpty)
              IconButton.filledTonal(
                tooltip: 'Clear history',
                icon: const Icon(Icons.delete_sweep_rounded),
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    title: 'Clear history?',
                    message: 'This removes the list of past downloads. Files already saved stay on your device.',
                    confirmLabel: 'Clear',
                    destructive: true,
                  );
                  if (ok) await services.history.clear();
                },
              ),
          ],
          slivers: [
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 10, bottom: 6),
                child: Center(child: HistoryMotion()),
              ),
            ),
            if (all.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        onChanged: (v) => setState(() => _query = v),
                        decoration: const InputDecoration(
                          hintText: 'Search history',
                          prefixIcon: Icon(Icons.search_rounded),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final (label, status) in const [
                            ('All', null),
                            ('Completed', DownloadStatus.completed),
                            ('Failed', DownloadStatus.failed),
                            ('Cancelled', DownloadStatus.cancelled),
                          ])
                            ChoiceChip(
                              label: Text(label),
                              selected: _filter == status,
                              onSelected: (_) => setState(() => _filter = status),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (entries.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 64),
                  child: Column(
                    children: [
                      Text(all.isEmpty ? 'No downloads yet' : 'No matches', style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
              )
            else
              SliverList.separated(
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _HistoryTile(entry: entries[i]),
              ),
          ],
        );
      },
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  bool get _fileExists => entry.filePath != null && File(entry.filePath!).existsSync();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color) = switch (entry.status) {
      DownloadStatus.completed => (Icons.check_circle_rounded, Colors.green),
      DownloadStatus.failed => (Icons.error_rounded, scheme.error),
      DownloadStatus.cancelled => (Icons.cancel_rounded, scheme.outline),
      _ => (Icons.schedule_rounded, scheme.outline),
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showActions(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
                child: Icon(
                  kindIcon(entry.kind),
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(
                      [entry.quality, if (entry.sizeBytes != null) formatBytes(entry.sizeBytes), formatDate(entry.createdAt)].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(icon, color: color, size: 20),
              const Icon(Icons.more_vert_rounded),
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final exists = _fileExists;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(entry.title, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                entry.status == DownloadStatus.failed && entry.error != null
                    ? entry.error!
                    : '${entry.fileName} · ${entry.quality}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (exists)
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: const Text('Open file'),
                onTap: () {
                  Navigator.pop(sheet);
                  NativeBridge.openFile(entry.filePath!);
                },
              ),
            ListTile(
              leading: const Icon(Icons.replay_rounded),
              title: const Text('Download again'),
              onTap: () {
                Navigator.pop(sheet);
                services.incomingLink.value = entry.url;
                services.tabRequest.value = 0;
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('Copy link'),
              onTap: () {
                Navigator.pop(sheet);
                Clipboard.setData(ClipboardData(text: entry.url));
                showSnack(context, 'Link copied', kind: ToastKind.success);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Remove from history'),
              onTap: () {
                Navigator.pop(sheet);
                services.history.remove(entry.id);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
