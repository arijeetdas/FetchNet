import 'dart:ui';

import 'package:flutter/material.dart';

import 'toast.dart';

export 'toast.dart' show ToastKind;

/// Shows a dialog with a scale-and-fade entrance over a blurred backdrop.
Future<T?> showFetchNetDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = false,
  bool lockBack = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'Dialog',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (context, anim1, anim2) => PopScope(canPop: !lockBack, child: builder(context)),
    transitionBuilder: (context, anim1, anim2, child) {
      final curve = CurvedAnimation(parent: anim1, curve: Curves.easeOutBack);
      return Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: anim1.value * 6, sigmaY: anim1.value * 6),
              child: const SizedBox.expand(),
            ),
          ),
          ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1).animate(curve),
            child: FadeTransition(opacity: anim1, child: child),
          ),
        ],
      );
    },
  );
}

/// Confirmation dialog in the app's style.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showFetchNetDialog<bool>(
    context: context,
    barrierDismissible: true,
    lockBack: false,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: Text(title),
      content: Text(message),
      actions: [
        DialogButton(label: 'Cancel', icon: Icons.close_rounded, onPressed: () => Navigator.pop(context, false)),
        DialogButton(
          label: confirmLabel,
          icon: destructive ? Icons.delete_rounded : Icons.check_rounded,
          primary: true,
          destructive: destructive,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Button used inside every popup: a filled (or tonal) rounded rectangle with
/// a filled icon.
class DialogButton extends StatelessWidget {
  const DialogButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.destructive = false,
    this.expand = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool destructive;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(
      minimumSize: Size(expand ? double.infinity : 0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontWeight: FontWeight.w800),
      backgroundColor: destructive ? (primary ? scheme.error : scheme.errorContainer) : null,
      foregroundColor: destructive ? (primary ? scheme.onError : scheme.onErrorContainer) : null,
    );
    final iconWidget = Icon(icon, size: 20);
    return primary
        ? FilledButton.icon(onPressed: onPressed, style: style, icon: iconWidget, label: Text(label))
        : FilledButton.tonalIcon(onPressed: onPressed, style: style, icon: iconWidget, label: Text(label));
  }
}

/// Short toast message (see [AppToast]).
void showSnack(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  AppToast.show(context, message, kind: kind, actionLabel: actionLabel, onAction: onAction);
}
