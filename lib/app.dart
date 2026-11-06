import 'package:flutter/material.dart';

import 'core/app_services.dart';
import 'core/theme.dart';
import 'features/onboarding/onboarding_flow.dart';
import 'features/shell/home_shell.dart';

class FetchNetApp extends StatelessWidget {
  const FetchNetApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: services,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: services.themeMode,
        builder: (context, mode, _) => MaterialApp(
          title: 'FetchNet',
          navigatorKey: services.navigatorKey,
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: const _StartGate(),
        ),
      ),
    );
  }
}

/// First launch: onboarding (Welcome → Disclaimer) → app. Afterwards straight into the app.
class _StartGate extends StatefulWidget {
  const _StartGate();

  @override
  State<_StartGate> createState() => _StartGateState();
}

class _StartGateState extends State<_StartGate> {
  late bool _welcomeSeen;
  late bool _accepted;

  @override
  void initState() {
    super.initState();
    final prefs = AppScope.of(context).prefs;
    _welcomeSeen = prefs.welcomeSeen;
    _accepted = prefs.disclaimerAccepted;
    if (_accepted) AppScope.of(context).start();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final Widget page;
    if (_accepted) {
      page = const HomeShell(key: ValueKey('shell'));
    } else {
      page = OnboardingFlow(
        key: const ValueKey('onboarding'),
        initialPage: _welcomeSeen ? 1 : 0,
        onWelcomeSeen: () async {
          _welcomeSeen = true;
          await services.prefs.setWelcomeSeen();
        },
        onAccepted: () async {
          await services.prefs.acceptDisclaimer();
          if (!mounted) return;
          setState(() => _accepted = true);
          services.start();
        },
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: page,
    );
  }
}
