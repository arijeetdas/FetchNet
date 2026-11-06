import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_services.dart';
import '../../services/update_service.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/brand.dart';
import '../../widgets/liquid_nav_bar.dart';
import '../../widgets/toast.dart';
import '../downloads/downloads_screen.dart';
import '../history/history_screen.dart';
import '../home/home_screen.dart';
import '../settings/settings_screen.dart';

/// Breakpoints shared by every screen.
class Breakpoints {
  Breakpoints._();

  /// Side rail instead of bottom bar.
  static const rail = 840.0;

  /// Extended rail with labels.
  static const wide = 1200.0;

  static bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= rail;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// Page currently shown.
  int _index = 0;

  /// Where the mobile nav selector is heading; the page follows once it settles.
  int _navTarget = 0;
  late final AppServices _services;

  static const _destinations = [
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.download_outlined, Icons.download_rounded, 'Downloads'),
    (Icons.history_outlined, Icons.history_rounded, 'History'),
    (Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
  ];

  /// Update-check result already reported to the user.
  UpdateState? _reported;
  Timer? _onlineWatch;

  @override
  void initState() {
    super.initState();
    _services = AppScope.of(context);
    _services.tabRequest.addListener(_onTabRequest);
    _services.updates.addListener(_onUpdateState);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onUpdateState());
  }

  @override
  void dispose() {
    _services.tabRequest.removeListener(_onTabRequest);
    _services.updates.removeListener(_onUpdateState);
    _onlineWatch?.cancel();
    super.dispose();
  }

  /// Startup notices: a toast only when the update check failed, and an
  /// exit countdown when there's no internet at all.
  void _onUpdateState() {
    if (!mounted) return;
    final state = _services.updates.state;
    if (state == UpdateState.checking || state == UpdateState.idle || state == _reported) return;
    _reported = state;
    switch (state) {
      case UpdateState.failed:
        showSnack(context, "Couldn't check for updates", kind: ToastKind.error);
      case UpdateState.offline:
        _showOffline();
      default:
        break;
    }
  }

  void _showOffline() {
    AppToast.show(
      context,
      'No internet connection. FetchNet needs the internet to fetch and download media.',
      kind: ToastKind.error,
      actionLabel: 'Exit',
      onAction: _exitApp,
      persistent: true,
      countdownSeconds: 10,
    );
    // Back online before the countdown ends: stay open.
    _onlineWatch?.cancel();
    _onlineWatch = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!await UpdateService.hasInternet() || !mounted || !timer.isActive) return;
      timer.cancel();
      _reported = null;
      showSnack(context, "You're back online", kind: ToastKind.success);
      unawaited(_services.updates.check());
    });
  }

  void _exitApp() {
    _onlineWatch?.cancel();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemNavigator.pop();
    } else {
      exit(0);
    }
  }

  bool get _usesFloatingBar => MediaQuery.sizeOf(context).width < Breakpoints.rail;

  void _onTabRequest() {
    final index = _services.tabRequest.value;
    if (_usesFloatingBar) {
      if (index != _navTarget) setState(() => _navTarget = index);
    } else {
      _show(index);
    }
  }

  /// Selector target changed (tap or request); keep the request notifier in
  /// sync so a later request for the same tab still fires.
  void _target(int index) {
    _services.tabRequest.value = index;
    if (index != _navTarget) setState(() => _navTarget = index);
  }

  void _show(int index) {
    _services.tabRequest.value = index;
    if (index == _index && index == _navTarget) return;
    setState(() => _index = _navTarget = index);
  }

  Widget _icon(int i, bool selected) {
    final d = _destinations[i];
    final icon = Icon(selected ? d.$2 : d.$1);
    if (i == 3) {
      return ListenableBuilder(
        listenable: _services.updates,
        builder: (context, _) => Badge(isLabelVisible: _services.updates.updateAvailable, child: icon),
      );
    }
    if (i != 1) return icon;
    return ListenableBuilder(
      listenable: _services.downloads,
      builder: (context, _) {
        final count = _services.downloads.activeCount;
        return Badge(isLabelVisible: count > 0, label: Text('$count'), child: icon);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= Breakpoints.rail;
    final extended = width >= Breakpoints.wide;
    final scheme = Theme.of(context).colorScheme;

    final body = FadeIndexedStack(
      index: _index,
      children: const [HomeScreen(), DownloadsScreen(), HistoryScreen(), SettingsScreen()],
    );

    if (!useRail) {
      return Scaffold(
        extendBody: true,
        body: body,
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.4 : 0.12),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_services.downloads, _services.updates]),
                    builder: (context, _) => LiquidNavBar(
                      target: _navTarget,
                      onTargetChanged: _target,
                      onSettled: _show,
                      items: [
                        for (var i = 0; i < _destinations.length; i++)
                          LiquidNavItem(
                            icon: _destinations[i].$1,
                            selectedIcon: _destinations[i].$2,
                            label: _destinations[i].$3,
                            badge: i == 1 ? _services.downloads.activeCount : 0,
                            dot: i == 3 && _services.updates.updateAvailable,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: AuroraBackground(
        intensity: 0.5,
        child: Row(
          children: [
            SafeArea(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
                ),
                child: NavigationRail(
                  extended: extended,
                  minExtendedWidth: 220,
                  selectedIndex: _index,
                  onDestinationSelected: _show,
                  labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
                    child: extended
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const FetchNetLogo(size: 40),
                              const SizedBox(width: 12),
                              GradientText(
                                'FetchNet',
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                              ),
                            ],
                          )
                        : const FetchNetLogo(size: 44),
                  ),
                  destinations: [
                    for (var i = 0; i < _destinations.length; i++)
                      NavigationRailDestination(
                        icon: _icon(i, false),
                        selectedIcon: _icon(i, true),
                        label: Text(_destinations[i].$3),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Standard page frame: centered, max width, title header.
class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.title,
    required this.slivers,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.maxWidth = 980,
  });

  final String title;
  final String? subtitle;

  /// Big icon before the heading (e.g. [PageGlyph]).
  final Widget? leading;
  final List<Widget> actions;
  final List<Widget> slivers;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = Breakpoints.isWide(context);
    final content = SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _Constrained(
              maxWidth: maxWidth,
              child: Padding(
                padding: EdgeInsets.fromLTRB(wide ? 28 : 20, wide ? 28 : 16, wide ? 28 : 12, 8),
                child: Row(
                  children: [
                    if (leading != null) ...[leading!, const SizedBox(width: 14)],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.headlineMedium),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                subtitle!,
                                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                        ],
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ),
            ),
          ),
          for (final s in slivers)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wide ? 28 : 16),
              sliver: SliverConstrainedCrossAxis(maxExtent: maxWidth, sliver: s),
            ),
          SliverToBoxAdapter(child: SizedBox(height: 32 + MediaQuery.paddingOf(context).bottom)),
        ],
      ),
    );
    return wide ? content : AuroraBackground(intensity: 0.5, child: content);
  }
}

class _Constrained extends StatelessWidget {
  const _Constrained({required this.maxWidth, required this.child});

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
      );
}

/// Like [IndexedStack] (every page keeps its state) but cross-fades with a
/// slight rise when the index changes.
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1);
  late int _previous = widget.index;

  @override
  void didUpdateWidget(FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _previous = oldWidget.index;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_c.value);
        final fadingOut = _c.isAnimating;
        return Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              Offstage(
                offstage: i != widget.index && !(fadingOut && i == _previous),
                child: TickerMode(
                  enabled: i == widget.index,
                  child: IgnorePointer(
                    ignoring: i != widget.index,
                    child: Opacity(
                      opacity: i == widget.index ? t : (i == _previous ? 1 - t : 0),
                      child: Transform.translate(
                        offset: Offset(0, i == widget.index ? (1 - t) * 14 : 0),
                        child: widget.children[i],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
