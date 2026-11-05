import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../widgets/brand.dart';
import 'disclaimer_content.dart';

/// First-launch flow: Welcome → Disclaimer, as two pages of one screen so the
/// background, step indicator and buttons stay put while the content glides.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({
    super.key,
    required this.initialPage,
    required this.onWelcomeSeen,
    required this.onAccepted,
  });

  final int initialPage;
  final Future<void> Function() onWelcomeSeen;
  final Future<void> Function() onAccepted;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late final PageController _pages = PageController(initialPage: widget.initialPage);
  late int _page = widget.initialPage;
  bool _agreed = false;
  bool _entering = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  double get _position => _pages.hasClients && _pages.position.hasContentDimensions
      ? (_pages.page ?? _page.toDouble())
      : _page.toDouble();

  Future<void> _go(int page) async {
    if (page == 1) widget.onWelcomeSeen();
    await _pages.animateToPage(
      page,
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeInOutCubicEmphasized,
    );
  }

  Future<void> _enter() async {
    if (!_agreed || _entering) return;
    setState(() => _entering = true);
    await widget.onAccepted();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(0);
      },
      child: Scaffold(
        body: AuroraBackground(
          animate: true,
          child: SafeArea(
            child: AnimatedBuilder(
              animation: _pages,
              builder: (context, _) {
                final p = _position.clamp(0.0, 1.0);
                return Column(
                  children: [
                    _TopBar(progress: p),
                    Expanded(
                      child: PageView(
                        controller: _pages,
                        physics: const NeverScrollableScrollPhysics(),
                        onPageChanged: (i) => setState(() => _page = i),
                        children: [
                          _Parallax(offset: p, child: const _WelcomePage()),
                          _Parallax(
                            offset: p - 1,
                            child: _DisclaimerPage(
                              agreed: _agreed,
                              onChanged: (v) => setState(() => _agreed = v),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _BottomBar(
                      progress: p,
                      canEnter: _agreed,
                      entering: _entering,
                      onPrevious: () => _go(0),
                      onNext: () => _go(1),
                      onEnter: _enter,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades and drifts page content slightly slower than the page itself.
class _Parallax extends StatelessWidget {
  const _Parallax({required this.offset, required this.child});

  /// 0 when the page is centered, ±1 when fully off-screen.
  final double offset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final o = offset.clamp(-1.0, 1.0);
    return Opacity(
      opacity: (1 - o.abs() * 0.85).clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(o * 70, 0),
        child: Transform.scale(scale: 1 - o.abs() * 0.04, child: child),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final step = progress < 0.5 ? 1 : 2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Row(
            children: [
              const FetchNetLogo(size: 30, glow: false),
              const SizedBox(width: 10),
              Text('FetchNet', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
              const Spacer(),
              Text(
                'Step $step of 2',
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 64,
                height: 6,
                child: Row(
                  children: [
                    for (var i = 0; i < 2; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                              FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: i == 0 ? 1 : progress,
                                child: const DecoratedBox(
                                  decoration: BoxDecoration(gradient: AppColors.brandGradient),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.progress,
    required this.canEnter,
    required this.entering,
    required this.onPrevious,
    required this.onNext,
    required this.onEnter,
  });

  final double progress;
  final bool canEnter;
  final bool entering;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) {
    final onDisclaimer = progress > 0.5;
    // The Previous button grows in with the page transition.
    final prevT = Curves.easeOutCubic.transform(progress);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Row(
            children: [
              ClipRect(
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: prevT,
                  child: Opacity(
                    opacity: prevT,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SizedBox(
                        height: 54,
                        width: 146,
                        child: OutlinedButton.icon(
                          onPressed: onDisclaimer ? onPrevious : null,
                          icon: const Icon(Icons.arrow_back_rounded),
                          label: const Text('Previous'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(a), child: child),
                  ),
                  child: onDisclaimer
                      ? GradientButton(
                          key: const ValueKey('enter'),
                          label: 'Enter FetchNet',
                          icon: Icons.check_circle_rounded,
                          expand: true,
                          loading: entering,
                          onPressed: canEnter ? onEnter : null,
                        )
                      : GradientButton(
                          key: const ValueKey('next'),
                          label: 'Get started',
                          icon: Icons.arrow_forward_rounded,
                          expand: true,
                          onPressed: onNext,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Welcome ─────────────────────────

class _WelcomePage extends StatefulWidget {
  const _WelcomePage();

  @override
  State<_WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<_WelcomePage> with TickerProviderStateMixin {
  late final AnimationController _float =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat(reverse: true);
  late final AnimationController _intro =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();

  static const _features = [
    (Icons.link_rounded, 'Paste any link', 'YouTube and 1000+ other sites supported by yt-dlp.'),
    (Icons.high_quality_rounded, 'Pick your quality', 'Video up to 4K, or MP3 / M4A audio.'),
    (Icons.travel_explore_rounded, 'Browser Mode', 'Open tricky pages in the built-in browser and grab the media there.'),
    (Icons.photo_library_rounded, 'Right where you expect', 'Saved to Download/FetchNet — videos show up in your gallery.'),
  ];

  @override
  void dispose() {
    _float.dispose();
    _intro.dispose();
    super.dispose();
  }

  Widget _reveal(int order, Widget child) {
    final start = (order * 0.09).clamp(0.0, 0.7);
    final anim = CurvedAnimation(parent: _intro, curve: Interval(start, start + 0.45, curve: Curves.easeOutCubic));
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Opacity(
        opacity: anim.value,
        child: Transform.translate(offset: Offset(0, (1 - anim.value) * 18), child: child),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, c) {
        final twoColumns = c.maxWidth >= 560;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                children: [
                  SizedBox(height: c.maxHeight > 700 ? 24 : 8),
                  _reveal(
                    0,
                    AnimatedBuilder(
                      animation: _float,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, math.sin(_float.value * math.pi) * -7),
                        child: child,
                      ),
                      child: SizedBox(
                        width: 180,
                        height: 150,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 170,
                              height: 170,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [AppColors.violetBright.withValues(alpha: 0.35), Colors.transparent],
                                ),
                              ),
                            ),
                            const FetchNetLogo(size: 108),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _reveal(
                    1,
                    Text(
                      'Welcome to',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _reveal(
                    1,
                    GradientText(
                      'FetchNet',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -2),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _reveal(
                    2,
                    Text(
                      'Save the videos and music you love — beautifully simple, powered by the open-source yt-dlp engine.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _reveal(
                    3,
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: const [
                        _Pill(icon: Icons.memory_rounded, text: 'Powered by yt-dlp'),
                        _Pill(icon: Icons.public_rounded, text: '1000+ sites'),
                        _Pill(icon: Icons.lock_outline_rounded, text: 'No account needed'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (twoColumns)
                    Column(
                      children: [
                        for (var row = 0; row < _features.length; row += 2)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(child: _reveal(4 + row, _FeatureCard(feature: _features[row]))),
                                  const SizedBox(width: 12),
                                  Expanded(child: _reveal(5 + row, _FeatureCard(feature: _features[row + 1]))),
                                ],
                              ),
                            ),
                          ),
                      ],
                    )
                  else
                    for (var i = 0; i < _features.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _reveal(4 + i, _FeatureCard(feature: _features[i])),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: scheme.primary),
          const SizedBox(width: 6),
          Text(text, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.feature});

  final (IconData, String, String) feature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final (icon, title, body) = feature;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: (dark ? Colors.white : Colors.white).withValues(alpha: dark ? 0.05 : 0.6),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.08 : 0.8)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: AppColors.brandGradient,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.violetBright.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(
                      body,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Disclaimer ─────────────────────────

class _DisclaimerPage extends StatefulWidget {
  const _DisclaimerPage({required this.agreed, required this.onChanged});

  final bool agreed;
  final ValueChanged<bool> onChanged;

  @override
  State<_DisclaimerPage> createState() => _DisclaimerPageState();
}

class _DisclaimerPageState extends State<_DisclaimerPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: ShapeDecoration(
                        gradient: const LinearGradient(colors: [AppColors.violet, AppColors.orchid]),
                        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
                        shadows: [
                          BoxShadow(
                            color: AppColors.violetBright.withValues(alpha: 0.35),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.shield_rounded, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Before you begin', style: theme.textTheme.headlineSmall),
                          const SizedBox(height: 2),
                          Text(
                            'A short, important read about how FetchNet works.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: dark ? 0.05 : 0.65),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.08 : 0.85)),
                      ),
                      child: const DisclaimerBody(),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: widget.agreed ? AppColors.brandGradient : null,
                    color: widget.agreed ? null : scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                  padding: const EdgeInsets.all(1.6),
                  child: Material(
                    color: widget.agreed
                        ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), scheme.surface)
                        : scheme.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(18.4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18.4),
                      onTap: () => widget.onChanged(!widget.agreed),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
                        child: Row(
                          children: [
                            Checkbox(value: widget.agreed, onChanged: (v) => widget.onChanged(v ?? false)),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                'I have read and understood this disclaimer. I accept full responsibility for my '
                                'use of FetchNet and will only use it in accordance with the law.',
                                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
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
