import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/download_models.dart';
import '../../widgets/app_dialog.dart';

/// What "Clear history" takes out of the list.
enum ClearScope {
  everything('Everything', 'Every download in the list', Icons.delete_sweep_rounded),
  unfinished('Failed and cancelled', 'Downloads that didn\'t finish', Icons.error_outline_rounded),
  missing('Files no longer here', 'Saved files that were moved or deleted', Icons.folder_off_rounded),
  older('Older than 30 days', 'Keeps this month\'s downloads', Icons.event_busy_rounded);

  const ClearScope(this.title, this.subtitle, this.icon);

  final String title;
  final String subtitle;
  final IconData icon;

  /// Whether [e] goes, at [now].
  bool picks(HistoryEntry e, DateTime now) => switch (this) {
        ClearScope.everything => true,
        ClearScope.unfinished => e.status == DownloadStatus.failed || e.status == DownloadStatus.cancelled,
        ClearScope.missing =>
          e.status == DownloadStatus.completed && (e.filePath == null || !File(e.filePath!).existsSync()),
        ClearScope.older => now.difference(e.completedAt ?? e.createdAt).inDays >= 30,
      };
}

/// Asks what to clear from [entries]; `null` when cancelled.
Future<ClearScope?> showClearHistoryDialog(BuildContext context, List<HistoryEntry> entries) =>
    showFetchNetDialog<ClearScope>(
      context: context,
      barrierDismissible: true,
      lockBack: false,
      builder: (context) => _ClearHistoryDialog(entries: entries),
    );

class _ClearHistoryDialog extends StatefulWidget {
  const _ClearHistoryDialog({required this.entries});

  final List<HistoryEntry> entries;

  @override
  State<_ClearHistoryDialog> createState() => _ClearHistoryDialogState();
}

class _ClearHistoryDialogState extends State<_ClearHistoryDialog> {
  ClearScope _scope = ClearScope.everything;
  late final Map<ClearScope, int> _counts;
  late final (int, int, int) _stats;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final all = widget.entries;
    _counts = {for (final s in ClearScope.values) s: all.where((e) => s.picks(e, now)).length};
    int count(DownloadStatus st) => all.where((e) => e.status == st).length;
    _stats = (count(DownloadStatus.completed), count(DownloadStatus.failed), count(DownloadStatus.cancelled));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final n = _counts[_scope]!;
    final (saved, failed, cancelled) = _stats;
    return Dialog(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 26, 22, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ───── Icon, title and what it does ─────
                    Center(
                      child: Container(
                        width: 76,
                        height: 76,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.errorContainer.withValues(alpha: 0.35),
                        ),
                        child: Container(
                          decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.errorContainer),
                          child: Icon(Icons.delete_sweep_rounded, size: 30, color: scheme.onErrorContainer),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Clear history',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.4),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Only the list is cleared. Files you saved stay on your device.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                    ),
                    const SizedBox(height: 16),

                    // ───── What's in the list ─────
                    Row(
                      children: [
                        Expanded(child: _Stat(count: saved, label: 'Saved', icon: Icons.check_circle_rounded)),
                        const SizedBox(width: 8),
                        Expanded(child: _Stat(count: failed, label: 'Failed', icon: Icons.error_rounded)),
                        const SizedBox(width: 8),
                        Expanded(child: _Stat(count: cancelled, label: 'Cancelled', icon: Icons.cancel_rounded)),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 8),
                      child: Text(
                        'WHAT TO CLEAR',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    for (final (i, s) in ClearScope.values.indexed) ...[
                      if (i > 0) const SizedBox(height: 8),
                      _ScopeTile(
                        scope: s,
                        count: _counts[s]!,
                        selected: _scope == s,
                        onTap: () => setState(() => _scope = s),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
              child: Row(
                children: [
                  Expanded(
                    child: DialogButton(
                      label: 'Cancel',
                      icon: Icons.close_rounded,
                      expand: true,
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DialogButton(
                      label: n == 0 ? 'Clear' : 'Clear $n',
                      icon: Icons.delete_rounded,
                      primary: true,
                      destructive: true,
                      expand: true,
                      onPressed: n == 0 ? null : () => Navigator.pop(context, _scope),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.count, required this.label, required this.icon});

  final int count;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: scheme.primary),
              const SizedBox(width: 5),
              Text('$count', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, height: 1.1)),
            ],
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// One choice of what to clear: a radio card with how many it takes.
class _ScopeTile extends StatelessWidget {
  const _ScopeTile({required this.scope, required this.count, required this.selected, required this.onTap});

  final ClearScope scope;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = count > 0;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.55) : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.4),
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected ? scheme.primary : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(scope.icon, size: 19, color: selected ? scheme.onPrimary : scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(scope.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                      Text(scope.subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: selected ? scheme.primary : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
