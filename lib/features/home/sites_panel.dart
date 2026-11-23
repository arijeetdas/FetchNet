import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../services/sites_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/site_icon.dart';
import 'home_kit.dart';
import '../../ui_kit/kit.dart';

/// Shortcuts to popular sites on Home, plus "Add site" and a plain browser.
class SitesPanel extends StatelessWidget {
  const SitesPanel({super.key, required this.onOpen, required this.onBrowser});

  final ValueChanged<Site> onOpen;
  final VoidCallback onBrowser;

  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: services.sites,
      builder: (context, _) {
        final sites = services.sites.all;
        final hasCustom = services.sites.custom.isNotEmpty;
        return HomePanel(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HomeSectionTitle(
                icon: Icons.public_rounded,
                title: 'Popular sites',
                subtitle: 'Open a site, sign in if needed, and save media from any page.',
                trailing: hasCustom
                    ? IconButton(
                        tooltip: 'Edit sites',
                        onPressed: () => _showManageSheet(context),
                        icon: const Icon(Icons.tune_rounded),
                      )
                    : null,
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, c) {
                  final columns = c.maxWidth >= 600 ? 6 : c.maxWidth >= 400 ? 4 : 3;
                  final width = (c.maxWidth - _gap * (columns - 1)) / columns;
                  final tiles = <Widget>[
                    for (final site in sites)
                      _Tile(
                        label: site.name,
                        icon: SiteIcon(site: site, size: 40),
                        onTap: () => onOpen(site),
                        onLongPress: site.isFixed ? null : () => _showSiteActions(context, site),
                      ),
                    _Tile(
                      label: 'Add site',
                      icon: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
                        ),
                        child: Icon(Icons.add_rounded, color: scheme.onPrimaryContainer),
                      ),
                      onTap: () => _addSite(context),
                    ),
                  ];
                  return Wrap(
                    spacing: _gap,
                    runSpacing: _gap,
                    children: [
                      for (final (i, t) in tiles.indexed)
                        SizedBox(width: width, child: EntranceMotion(index: i, step: const Duration(milliseconds: 40), child: t)),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              _BrowserCard(onTap: onBrowser),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _addSite(BuildContext context) async {
    final result = await showFetchNetDialog<PinResult>(
      context: context,
      barrierDismissible: true,
      lockBack: false,
      builder: (_) => const _AddSiteDialog(),
    );
    if (result == null || !context.mounted) return;
    showPinResult(context, result);
  }

  static Future<void> _showSiteActions(BuildContext context, Site site) async {
    final services = AppScope.of(context);
    final index = services.sites.custom.indexWhere((s) => s.key == site.key);
    final last = services.sites.custom.length - 1;
    await showKitSheet<void>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: SiteIcon(site: site, size: 36),
              title: Text(site.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(site.key),
            ),
            const Divider(indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.arrow_back_rounded),
              title: const Text('Move earlier'),
              enabled: index > 0,
              onTap: () {
                Navigator.pop(context);
                services.sites.move(index, index - 1);
              },
            ),
            ListTile(
              leading: const Icon(Icons.arrow_forward_rounded),
              title: const Text('Move later'),
              enabled: index >= 0 && index < last,
              onTap: () {
                Navigator.pop(context);
                services.sites.move(index, index + 1);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error),
              title: Text('Remove', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                services.sites.remove(site);
                showSnack(context, '${site.name} removed');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static Future<void> _showManageSheet(BuildContext context) async {
    final services = AppScope.of(context);
    await showKitSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 600),
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
            child: ListenableBuilder(
              listenable: services.sites,
              builder: (context, _) {
                final custom = services.sites.custom;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: Text('Edit sites', style: theme.textTheme.titleLarge),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Text(
                        'Drag to reorder the sites you added. YouTube, Instagram, Facebook and X always stay first.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    for (final site in SitesService.fixed)
                      ListTile(
                        dense: true,
                        leading: SiteIcon(site: site, size: 30),
                        title: Text(site.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        trailing: Icon(Icons.lock_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
                      ),
                    const Divider(indent: 16, endIndent: 16),
                    if (custom.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          'You haven\'t added any sites yet.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      )
                    else
                      Flexible(
                        child: ReorderableListView.builder(
                          shrinkWrap: true,
                          buildDefaultDragHandles: false,
                          itemCount: custom.length,
                          onReorderItem: (from, to) => services.sites.move(from, to),
                          itemBuilder: (context, i) {
                            final site = custom[i];
                            return ListTile(
                              key: ValueKey(site.key),
                              leading: SiteIcon(site: site, size: 34),
                              title: Text(site.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text(site.key),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Remove',
                                    icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
                                    onPressed: () => services.sites.remove(site),
                                  ),
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(Icons.drag_indicator_rounded),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 12),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Toast for the outcome of adding / pinning a site.
void showPinResult(BuildContext context, PinResult result) {
  showSnack(
    context,
    result.message,
    kind: switch (result.outcome) {
      PinOutcome.added => ToastKind.success,
      PinOutcome.alreadyPinned => ToastKind.info,
      _ => ToastKind.error,
    },
  );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.icon, required this.onTap, this.onLongPress});

  final String label;
  final Widget icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PressableScale(
      scale: 0.94,
      child: Material(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: scheme.primary.withValues(alpha: 0.12), blurRadius: 16, offset: const Offset(0, 6))],
                  ),
                  child: icon,
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The plain built-in browser, as a wide card under the sites.
class _BrowserCard extends StatelessWidget {
  const _BrowserCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PressableScale(
      scale: 0.98,
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: AppColors.brandGradient,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(color: AppColors.violetBright.withValues(alpha: 0.3), blurRadius: 14, offset: const Offset(0, 6)),
                    ],
                  ),
                  child: const Icon(Icons.travel_explore_rounded, color: Colors.white, size: 23),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Browser Mode',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, color: scheme.onPrimaryContainer),
                      ),
                      Text(
                        'Open any page, play the media, and FetchNet finds the videos, audio and images on it.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer.withValues(alpha: 0.85), height: 1.35),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_rounded, color: scheme.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddSiteDialog extends StatefulWidget {
  const _AddSiteDialog();

  @override
  State<_AddSiteDialog> createState() => _AddSiteDialogState();
}

class _AddSiteDialogState extends State<_AddSiteDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AppScope.of(context).sites.pin(_controller.text);
    if (!mounted) return;
    if (result.outcome == PinOutcome.invalid) {
      setState(() {
        _busy = false;
        _error = result.message;
      });
      return;
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return KitAlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      icon: Icon(Icons.add_link_rounded, color: scheme.primary),
      title: const Text('Add a site'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'FetchNet checks that yt-dlp supports the site, then adds it with its name and icon.',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'e.g. dailymotion.com',
                prefixIcon: const Icon(Icons.public_rounded),
                errorText: _error,
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const EnergyLoader(size: 22),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Checking with yt-dlp…', style: theme.textTheme.bodyMedium)),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        DialogButton(
          label: 'Cancel',
          icon: Icons.close_rounded,
          onPressed: _busy ? null : () => Navigator.pop(context),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => DialogButton(
            label: 'Add',
            icon: Icons.add_rounded,
            primary: true,
            onPressed: _busy || _controller.text.trim().isEmpty ? null : _submit,
          ),
        ),
      ],
    );
  }
}
