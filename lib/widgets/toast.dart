import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

enum ToastKind { info, success, error }

/// Glassy toast that drops in from the top. Only one is shown at a time.
class AppToast {
  AppToast._();

  static OverlayEntry? _entry;
  static GlobalKey<_ToastViewState>? _key;

  static void show(
    BuildContext context,
    String message, {
    ToastKind kind = ToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
    bool persistent = false,
    int? countdownSeconds,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _removeNow();
    final key = GlobalKey<_ToastViewState>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        key: key,
        message: message,
        kind: kind,
        actionLabel: actionLabel,
        onAction: onAction,
        duration: duration ?? const Duration(seconds: 4),
        persistent: persistent,
        countdownSeconds: countdownSeconds,
        onDismissed: () {
          if (_entry == entry) {
            _entry = null;
            _key = null;
          }
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _entry = entry;
    _key = key;
    overlay.insert(entry);
  }

  static void _removeNow() {
    final entry = _entry;
    _entry = null;
    _key = null;
    if (entry != null && entry.mounted) entry.remove();
  }

  /// Animates the current toast away, if any.
  static void dismiss() => _key?.currentState?._hide();

  /// Whether a toast is on screen.
  static bool get isShowing => _entry != null;
}

class _ToastView extends StatefulWidget {
  const _ToastView({
    super.key,
    required this.message,
    required this.kind,
    required this.duration,
    required this.onDismissed,
    this.actionLabel,
    this.onAction,
    this.persistent = false,
    this.countdownSeconds,
  });

  final String message;
  final ToastKind kind;
  final Duration duration;
  final VoidCallback onDismissed;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Stays until [AppToast.dismiss] or its action; can't be swiped away.
  final bool persistent;

  /// Counts down next to the action label and runs the action at zero.
  final int? countdownSeconds;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 220),
  );
  Timer? _timer;
  Timer? _ticker;
  int? _remaining;
  double _drag = 0;
  bool _hiding = false;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _remaining = widget.countdownSeconds;
    if (_remaining != null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _hiding) return;
        setState(() => _remaining = _remaining! - 1);
        if (_remaining! <= 0) {
          _ticker?.cancel();
          widget.onAction?.call();
          _hide();
        }
      });
    }
    if (!widget.persistent) _timer = Timer(widget.duration, _hide);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ticker?.cancel();
    _c.dispose();
    super.dispose();
  }

  Future<void> _hide() async {
    if (_hiding || !mounted) return;
    _hiding = true;
    _timer?.cancel();
    _ticker?.cancel();
    await _c.reverse();
    widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final (icon, accent) = switch (widget.kind) {
      ToastKind.success => (Icons.check_rounded, const Color(0xFF22C55E)),
      ToastKind.error => (Icons.priority_high_rounded, scheme.error),
      ToastKind.info => (Icons.bolt_rounded, scheme.primary),
    };
    final top = MediaQuery.paddingOf(context).top + 12;
    final enter = CurvedAnimation(parent: _c, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);

    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedBuilder(
          animation: enter,
          builder: (context, child) => Opacity(
            opacity: _c.value.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(_drag, (1 - enter.value) * -36),
              child: Transform.scale(scale: 0.92 + 0.08 * enter.value, child: child),
            ),
          ),
          child: GestureDetector(
            onTap: widget.persistent ? null : _hide,
            onHorizontalDragUpdate: widget.persistent ? null : (d) => setState(() => _drag += d.delta.dx),
            onHorizontalDragEnd: widget.persistent
                ? null
                : (d) {
                    if (_drag.abs() > 80 || d.primaryVelocity!.abs() > 600) {
                      _hide();
                    } else {
                      setState(() => _drag = 0);
                    }
                  },
            onVerticalDragEnd: widget.persistent
                ? null
                : (d) {
                    if ((d.primaryVelocity ?? 0) < -200) _hide();
                  },
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Material(
                type: MaterialType.transparency,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
                      decoration: BoxDecoration(
                        color: (dark ? const Color(0xFF1C1430) : Colors.white).withValues(alpha: dark ? 0.78 : 0.82),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: (dark ? Colors.white : scheme.primary).withValues(alpha: dark ? 0.12 : 0.14)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(color: accent.withValues(alpha: 0.16), shape: BoxShape.circle),
                            child: Icon(icon, size: 18, color: accent),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              widget.message,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.3),
                            ),
                          ),
                          if (widget.actionLabel != null) ...[
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () {
                                widget.onAction?.call();
                                _hide();
                              },
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                backgroundColor: scheme.primary.withValues(alpha: 0.12),
                                shape: const StadiumBorder(),
                              ),
                              child: Text(
                                _remaining == null ? widget.actionLabel! : '${widget.actionLabel!} · ${_remaining}s',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
