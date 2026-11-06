import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../widgets/brand.dart';
import 'yt_player_controller.dart';

/// The player's settings: quality, speed, loop, fit, listen only, autoplay
/// and a sleep timer.
Future<void> showYtPlayerSettings(BuildContext context, YtPlayerController controller) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => _SettingsSheet(controller: controller),
  );
}

enum _Page { main, quality, speed, sleep }

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.controller});

  final YtPlayerController controller;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  _Page _page = _Page.main;

  YtPlayerController get c => widget.controller;

  void _go(_Page p) => setState(() => _page = p);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: KeyedSubtree(
            key: ValueKey(_page),
            child: switch (_page) {
              _Page.main => _main(context),
              _Page.quality => _quality(context),
              _Page.speed => _speed(context),
              _Page.sleep => _sleep(context),
            },
          ),
        ),
      ),
    );
  }

  Widget _list(List<Widget> children) => ListView(
    shrinkWrap: true,
    padding: EdgeInsets.fromLTRB(8, 0, 8, 16 + MediaQuery.paddingOf(context).bottom),
    children: children,
  );

  Widget _header(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 16, 4),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Back',
          onPressed: () => _go(_Page.main),
          icon: const Icon(Icons.arrow_back_rounded),
          style: IconButton.styleFrom(shape: const CircleBorder()),
        ),
        const SizedBox(width: 4),
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      ],
    ),
  );

  String get _qualityLabel {
    if (c.listenOnly) return 'Audio only';
    if (c.qualityAuto) {
      final a = c.autoStream;
      return a == null ? 'Auto' : 'Auto (${a.label})';
    }
    return c.currentVideo?.label ?? 'Auto';
  }

  String get _sleepLabel {
    if (c.sleepAtEnd) return 'End of video';
    final at = c.sleepAt;
    if (at == null) return 'Off';
    final left = at.difference(DateTime.now());
    return '${left.inMinutes + 1} min left';
  }

  Widget _main(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget icon(IconData i) => Icon(i, color: scheme.primary);
    return _list([
      ListTile(
        leading: icon(Icons.high_quality_rounded),
        title: const Text('Quality'),
        subtitle: Text(_qualityLabel),
        trailing: const Icon(Icons.chevron_right_rounded),
        enabled: c.streams != null && !c.listenOnly,
        onTap: () => _go(_Page.quality),
      ),
      ListTile(
        leading: icon(Icons.speed_rounded),
        title: const Text('Playback speed'),
        subtitle: Text(c.speed == 1 ? 'Normal' : '${c.speed}×'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _go(_Page.speed),
      ),
      SwitchListTile(
        secondary: icon(Icons.headphones_rounded),
        title: const Text('Listen only'),
        subtitle: const Text('Audio without the picture, saves data'),
        value: c.listenOnly,
        onChanged: c.streams?.audio == null ? null : c.setListenOnly,
      ),
      SwitchListTile(
        secondary: icon(Icons.repeat_one_rounded),
        title: const Text('Loop video'),
        value: c.loop,
        onChanged: c.setLoop,
      ),
      SwitchListTile(
        secondary: icon(Icons.skip_next_rounded),
        title: const Text('Autoplay'),
        subtitle: const Text('Play the next video in Up next'),
        value: c.autoplay,
        onChanged: c.setAutoplay,
      ),
      ListTile(
        leading: icon(Icons.aspect_ratio_rounded),
        title: const Text('Picture'),
        trailing: SegmentedButton<BoxFit>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: BoxFit.contain, icon: Icon(Icons.fit_screen_rounded), label: Text('Fit')),
            ButtonSegment(value: BoxFit.cover, icon: Icon(Icons.crop_free_rounded), label: Text('Fill')),
          ],
          selected: {c.fit},
          onSelectionChanged: (s) => c.setFit(s.first),
        ),
      ),
      ListTile(
        leading: icon(Icons.bedtime_rounded),
        title: const Text('Sleep timer'),
        subtitle: Text(_sleepLabel),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _go(_Page.sleep),
      ),
    ]);
  }

  Widget _check(bool on) => Icon(
    on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
    color: on ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline,
  );

  Widget _quality(BuildContext context) {
    final streams = c.streams?.video ?? const [];
    final auto = c.autoStream;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _header('Quality'),
        Flexible(
          child: _list([
            ListTile(
              leading: _check(c.qualityAuto),
              title: const Text('Auto'),
              subtitle: Text(auto == null ? 'Best for this device' : 'Best for this device · ${auto.label}'),
              onTap: () {
                c.setQuality(null);
                Navigator.of(context).pop();
              },
            ),
            for (final s in streams)
              ListTile(
                leading: _check(!c.qualityAuto && identical(s, c.currentVideo)),
                title: Row(
                  children: [
                    Text(s.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (s.badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          gradient: AppColors.brandGradient,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          s.badge!,
                          style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  [?s.codec?.toUpperCase(), if (s.sizeBytes != null) '~${formatBytes(s.sizeBytes)}'].join(' · '),
                ),
                onTap: () {
                  c.setQuality(s);
                  Navigator.of(context).pop();
                },
              ),
          ]),
        ),
      ],
    );
  }

  Widget _speed(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _header('Playback speed'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.slow_motion_video_rounded, size: 20),
              Expanded(
                child: Slider(
                  value: c.speed.clamp(0.25, 3.0),
                  min: 0.25,
                  max: 3,
                  divisions: 55,
                  label: '${c.speed.toStringAsFixed(2)}×',
                  onChanged: (v) => c.setSpeed((v * 20).round() / 20),
                ),
              ),
              SizedBox(width: 52, child: Text('${c.speed.toStringAsFixed(2)}×', textAlign: TextAlign.end)),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 20 + MediaQuery.paddingOf(context).bottom),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in kPlaybackSpeeds)
                ChoiceChip(
                  label: Text(s == 1 ? 'Normal' : '$s×'),
                  selected: c.speed == s,
                  onSelected: (_) => c.setSpeed(s),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sleep(BuildContext context) {
    void set(Duration? d, {bool end = false}) {
      c.setSleepTimer(d, endOfVideo: end);
      Navigator.of(context).pop();
    }

    final on = c.sleepTimerOn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _header('Sleep timer'),
        Flexible(
          child: _list([
            ListTile(leading: _check(!on), title: const Text('Off'), onTap: () => set(null)),
            for (final m in const [10, 15, 30, 45, 60, 90])
              ListTile(
                leading: _check(false),
                title: Text('$m minutes'),
                onTap: () => set(Duration(minutes: m)),
              ),
            ListTile(
              leading: _check(c.sleepAtEnd),
              title: const Text('End of this video'),
              onTap: () => set(null, end: true),
            ),
          ]),
        ),
      ],
    );
  }
}
