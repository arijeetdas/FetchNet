import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/creator_job.dart';
import '../../widgets/app_dialog.dart';

/// The card the creator panels sit in (like the lyrics card).
class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: child,
    );
  }
}

/// "Whole video | Clip", and for a clip where it starts and ends: a range
/// slider, Start / End buttons (tap to type a time), ±1 s nudges and quick
/// lengths. [note] says what happens to it (Shorts / Reels).
class ClipPanel extends StatelessWidget {
  const ClipPanel({
    super.key,
    required this.wholeLabel,
    required this.on,
    required this.onToggle,
    required this.length,
    required this.start,
    required this.end,
    required this.onRange,
    this.note,
  });

  /// "Whole video" / "Whole audio".
  final String wholeLabel;
  final bool on;
  final ValueChanged<bool> onToggle;

  /// The whole video's length.
  final Duration length;
  final Duration start;
  final Duration end;
  final void Function(Duration start, Duration end) onRange;
  final String? note;

  static const _minimum = Duration(seconds: 1);

  void _set(Duration s, Duration e) {
    var a = s < Duration.zero ? Duration.zero : s;
    var b = e > length ? length : e;
    if (b - a < _minimum) {
      // Keep at least a second: move the other end.
      if (s != start) {
        a = b - _minimum;
      } else {
        b = a + _minimum;
      }
      if (b > length) {
        b = length;
        a = length - _minimum;
      }
      if (a < Duration.zero) a = Duration.zero;
    }
    onRange(a, b);
  }

  Future<void> _type(BuildContext context, {required bool isStart}) async {
    final picked = await askClockTime(context, title: isStart ? 'Clip starts at' : 'Clip ends at', initial: isStart ? start : end, max: length);
    if (picked == null) return;
    isStart ? _set(picked, end) : _set(start, picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clipLength = end - start;
    return _PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.content_cut_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Clip', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              ),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(value: false, label: Text(wholeLabel)),
                  const ButtonSegment(value: true, label: Text('Clip')),
                ],
                selected: {on},
                onSelectionChanged: (v) => onToggle(v.first),
              ),
            ],
          ),
          if (on) ...[
            const SizedBox(height: 6),
            RangeSlider(
              values: RangeValues(start.inMilliseconds / 1000, end.inMilliseconds / 1000),
              max: length.inMilliseconds / 1000,
              labels: RangeLabels(clockLabel(start), clockLabel(end)),
              onChanged: (v) => _set(Duration(milliseconds: (v.start * 1000).round()), Duration(milliseconds: (v.end * 1000).round())),
            ),
            Row(
              children: [
                Expanded(
                  child: _TimeControl(label: 'Start', value: start, onTap: () => _type(context, isStart: true), onNudge: (d) => _set(start + d, end)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    children: [
                      Text('Length', style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                      Text(
                        clockLabel(clipLength),
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _TimeControl(
                    label: 'End',
                    value: end,
                    alignEnd: true,
                    onTap: () => _type(context, isStart: false),
                    onNudge: (d) => _set(start, end + d),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (label, secs) in const [('15 s', 15), ('30 s', 30), ('1 min', 60), ('3 min', 180)])
                  if (Duration(seconds: secs) <= length)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(label),
                      onPressed: () {
                        final want = Duration(seconds: secs);
                        // From the start; shifted back when it would run past the end.
                        final s = start + want > length ? length - want : start;
                        onRange(s, s + want);
                      },
                    ),
              ],
            ),
            if (note != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.stay_current_portrait_rounded, size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(note!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// "Start 1:10" (tap to type) with − / + one second.
class _TimeControl extends StatelessWidget {
  const _TimeControl({required this.label, required this.value, required this.onTap, required this.onNudge, this.alignEnd = false});

  final String label;
  final Duration value;
  final VoidCallback onTap;
  final ValueChanged<Duration> onNudge;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const step = Duration(seconds: 1);
    return Column(
      crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Material(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer)),
                  Text(
                    clockLabel(value),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSecondaryContainer,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Nudge(label: '−1 s', tooltip: '$label 1 second earlier', onTap: () => onNudge(-step)),
            const SizedBox(width: 4),
            _Nudge(label: '+1 s', tooltip: '$label 1 second later', onTap: () => onNudge(step)),
          ],
        ),
      ],
    );
  }
}

class _Nudge extends StatelessWidget {
  const _Nudge({required this.label, required this.tooltip, required this.onTap});

  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
          ),
        ),
      ),
    );
  }
}

/// Snapshot a moment: the moment as a dot on the video's timeline (no
/// "progress" fill: it's one instant), a time to type, and ±1 second /
/// ±1 frame.
class SnapshotPanel extends StatelessWidget {
  const SnapshotPanel({super.key, required this.length, required this.at, required this.onAt, required this.formatLabel, this.fps = 30});

  final Duration length;
  final Duration at;
  final ValueChanged<Duration> onAt;

  /// "JPG" / "PNG".
  final String formatLabel;
  final double fps;

  void _set(Duration d) {
    // The last moment that still has a frame after it.
    final last = length - const Duration(milliseconds: 100);
    onAt(d < Duration.zero ? Duration.zero : (d > last ? (last < Duration.zero ? Duration.zero : last) : d));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final frame = Duration(microseconds: (1000000 / math.max(1, fps)).round());
    return _PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.camera_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Snapshot a moment', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          ...[
            SliderTheme(
              // One instant: the same track on both sides of the dot.
              data: SliderTheme.of(context)
                  .copyWith(activeTrackColor: scheme.surfaceContainerHighest, inactiveTrackColor: scheme.surfaceContainerHighest, trackHeight: 4),
              child: Slider(
                value: (at.inMilliseconds / 1000).clamp(0, length.inMilliseconds / 1000),
                max: math.max(0.001, length.inMilliseconds / 1000),
                label: clockLabel(at),
                onChanged: (v) => _set(Duration(milliseconds: (v * 1000).round())),
              ),
            ),
            Row(
              children: [
                Material(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      final picked = await askClockTime(context, title: 'Snapshot at', initial: at, max: length);
                      if (picked != null) _set(picked);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(
                        clockLabel(at),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: scheme.onSecondaryContainer,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                _Nudge(label: '−1 s', tooltip: '1 second earlier', onTap: () => _set(at - const Duration(seconds: 1))),
                const SizedBox(width: 4),
                _Nudge(label: '−1 f', tooltip: '1 frame earlier', onTap: () => _set(at - frame)),
                const SizedBox(width: 4),
                _Nudge(label: '+1 f', tooltip: '1 frame later', onTap: () => _set(at + frame)),
                const SizedBox(width: 4),
                _Nudge(label: '+1 s', tooltip: '1 second later', onTap: () => _set(at + const Duration(seconds: 1))),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Saves that frame at the video\'s best quality, as a $formatLabel, to Images.',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// Asks for a time ("1:05", "1:02:03", "65"), up to [max]; `null` when
/// cancelled.
Future<Duration?> askClockTime(BuildContext context, {required String title, required Duration initial, required Duration max}) {
  final controller = TextEditingController(text: clockLabel(initial));
  controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
  String? error;
  return showFetchNetDialog<Duration>(
    context: context,
    barrierDismissible: true,
    lockBack: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void submit() {
          final t = parseClock(controller.text);
          if (t == null) {
            setState(() => error = 'Type a time like 1:05 or 1:02:03.');
          } else if (t > max) {
            setState(() => error = 'The video is ${clockLabel(max)} long.');
          } else {
            Navigator.pop(context, t);
          }
        }

        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9:.,]'))],
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(
              hintText: 'm:ss',
              helperText: 'From 0:00 to ${clockLabel(max)}',
              errorText: error,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          actions: [
            DialogButton(label: 'Cancel', icon: Icons.close_rounded, onPressed: () => Navigator.pop(context)),
            DialogButton(label: 'Set', icon: Icons.check_rounded, primary: true, onPressed: submit),
          ],
        );
      },
    ),
  );
}
