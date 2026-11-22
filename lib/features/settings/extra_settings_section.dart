import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/platform/device_environment.dart';
import '../../models/media_info.dart';
import '../../services/extra_settings.dart';
import 'settings_widgets.dart';

/// Settings → Extra Settings: subtitles, quick download presets, download
/// limits and copied links.
/// The Extra Settings cards, so Settings can place them in its sections.
enum ExtraCard { subtitles, lyrics, presets, downloads, browser }

class ExtraSettingsCards extends StatelessWidget {
  const ExtraSettingsCards({super.key, this.only = ExtraCard.values});

  /// Which cards to show, in this order.
  final List<ExtraCard> only;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final s = services.extras;
    return ListenableBuilder(
      listenable: Listenable.merge([s, services.engine.status]),
      builder: (context, _) {
        final ffmpeg = services.engine.status.value.ffmpegAvailable;
        final cards = <ExtraCard, Widget>{
          ExtraCard.subtitles: _SubtitlesCard(s: s, ffmpeg: ffmpeg),
          ExtraCard.lyrics: _LyricsCard(s: s, ffmpeg: ffmpeg),
          ExtraCard.presets: _PresetsCard(s: s),
          ExtraCard.downloads: _DownloadsCard(s: s),
          ExtraCard.browser: SettingsCard(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: s.blockAds,
                  onChanged: s.setBlockAds,
                  secondary: const _Glyph(Icons.shield_rounded),
                  title: const _Title('Block ads and trackers'),
                  subtitle: const Text(
                    'In Browser Mode: ads, trackers and pop-ups of the sites you open are blocked.',
                  ),
                ),
                const Divider(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: s.detectClipboard,
                  onChanged: s.setDetectClipboard,
                  secondary: const _Glyph(Icons.content_paste_go_rounded),
                  title: const _Title('Detect copied links'),
                  subtitle: const Text('When you come back to FetchNet with a link copied, Home offers to fetch it.'),
                ),
              ],
            ),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, c) in only.indexed) ...[
              if (i > 0) const SizedBox(height: 12),
              cards[c]!,
            ],
          ],
        );
      },
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => GradientGlyph(icon, size: 42);
}

/// A switch's title, in the weight of the other settings cards' titles.
class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900, fontSize: 15));
}

/// A card's title row: a gradient icon, a title and what it's about.
class _Header extends StatelessWidget {
  const _Header({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        GradientGlyph(icon, size: 42),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900, fontSize: 15)),
              const SizedBox(height: 2),
              Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }
}

/// An expandable setting inside a card: title, current value, choices.
class _Expandable extends StatelessWidget {
  const _Expandable({required this.title, required this.value, required this.children});

  final String title;
  final String value;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(title, style: theme.textTheme.bodyLarge),
        subtitle: Text(value, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
        children: children,
      ),
    );
  }
}

class _SubtitlesCard extends StatelessWidget {
  const _SubtitlesCard({required this.s, required this.ffmpeg});

  final ExtraSettings s;
  final bool ffmpeg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final codes = s.subtitleLanguageCodes;
    final names = {for (final (c, n) in ExtraSettings.subtitleLanguages) c: n};
    final langLabel = codes.contains('all') ? 'All available' : codes.map((c) => names[c] ?? c).join(', ');
    return SettingsCard(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.subtitles,
          onChanged: s.setSubtitles,
          secondary: const _Glyph(Icons.closed_caption_rounded),
          title: const _Title('Download subtitles'),
          subtitle: const Text('Saved with videos, on sites that have them (YouTube, Vimeo, TED and many more).'),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !s.subtitles
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Divider(height: 8),
                    _Expandable(
                      title: 'Format',
                      value: s.subtitleFormat.label,
                      children: [
                        RadioGroup<SubtitleFormat>(
                          groupValue: s.subtitleFormat,
                          onChanged: (v) {
                            if (v != null) s.setSubtitleFormat(v);
                          },
                          child: Column(
                            children: [
                              for (final f in SubtitleFormat.values)
                                RadioListTile<SubtitleFormat>(
                                  contentPadding: EdgeInsets.zero,
                                  value: f,
                                  title: Text(f.label),
                                  subtitle: Text(f.detail),
                                ),
                            ],
                          ),
                        ),
                        if (!ffmpeg && s.subtitleFormat != SubtitleFormat.best)
                          _Note('Converting to ${s.subtitleFormat.label} needs FFmpeg (Settings → Engines). '
                              'Until then, subtitles are saved as the site provides them.'),
                      ],
                    ),
                    _Expandable(
                      title: 'Languages',
                      value: langLabel,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (code, name) in ExtraSettings.subtitleLanguages)
                                FilterChip(
                                  label: Text(name),
                                  selected: codes.contains(code),
                                  onSelected: (on) {
                                    var next = [...codes];
                                    if (code == 'all') {
                                      next = on ? ['all'] : ['en'];
                                    } else {
                                      next.remove('all');
                                      on ? next.add(code) : next.remove(code);
                                      if (next.isEmpty) next = ['en'];
                                    }
                                    s.setSubtitleLanguageCodes(next);
                                  },
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        SwitchListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                          value: s.autoCaptions,
                          onChanged: s.setAutoCaptions,
                          title: const Text('Automatic captions'),
                          subtitle: const Text(
                            'When a language has no subtitles of its own, take the captions the site generates (YouTube).',
                          ),
                        ),
                        _Note('Each video\'s own list of subtitles can be changed before downloading it.'),
                      ],
                    ),
                    const Divider(height: 8),
                    // Merged or separate: one switch (shown only while
                    // subtitles are on).
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      value: ffmpeg && s.mergeSubtitles,
                      onChanged: ffmpeg ? s.setMergeSubtitles : null,
                      title: const Text('Merge into the video'),
                      subtitle: Text(
                        !ffmpeg
                            ? 'Needs FFmpeg (Settings → Engines). Until then, subtitles are saved as separate files.'
                            : s.mergeSubtitles
                                ? 'One file: players show the subtitles as a track you can turn on, in sync with the video.'
                                : 'Off: saved next to the video as separate files, e.g. "Video.en.srt".',
                      ),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: !(ffmpeg && s.mergeSubtitles)
                          ? const SizedBox(width: double.infinity)
                          : SwitchListTile(
                              contentPadding: const EdgeInsets.only(left: 20, right: 4),
                              value: s.keepSubtitleFiles,
                              onChanged: s.setKeepSubtitleFiles,
                              title: const Text('Also keep separate files'),
                              subtitle: const Text('For players and editors that load subtitle files.'),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
                      child: Text(
                        'Only for video downloads. Sites without subtitles simply download the video.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _LyricsCard extends StatelessWidget {
  const _LyricsCard({required this.s, required this.ffmpeg});

  final ExtraSettings s;
  final bool ffmpeg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final merge = ffmpeg && s.mergeLyrics;
    return SettingsCard(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.lyrics,
          onChanged: s.setLyrics,
          secondary: const _Glyph(Icons.lyrics_rounded),
          title: const _Title('Add lyrics to music'),
          subtitle: const Text(
            'Songs saved as audio get their synced lyrics, so music players show each line as it\'s sung.',
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !s.lyrics
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Divider(height: 8),
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      value: merge,
                      onChanged: ffmpeg ? s.setMergeLyrics : null,
                      title: const Text('Put lyrics inside the song'),
                      subtitle: Text(
                        !ffmpeg
                            ? 'Needs FFmpeg (Settings → Engines). Until then, lyrics are saved as .lrc files.'
                            : merge
                                ? 'Any player that reads lyrics from the file shows them, wherever the song goes.'
                                : 'Off: saved next to the song as a .lrc file, e.g. "Song.lrc".',
                      ),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: !merge
                          ? const SizedBox(width: double.infinity)
                          : SwitchListTile(
                              contentPadding: const EdgeInsets.only(left: 20, right: 4),
                              value: s.keepLyricsFile,
                              onChanged: s.setKeepLyricsFile,
                              title: const Text('Also keep a .lrc file'),
                              subtitle: const Text('For players that only read lyrics files.'),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
                      child: Text(
                        'Lyrics come from LRCLIB, a free lyrics library, matched by artist, title and length. '
                        'Audio that isn\'t a song LRCLIB knows is saved as it is.',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

class _PresetsCard extends StatelessWidget {
  const _PresetsCard({required this.s});

  final ExtraSettings s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SettingsCard(
      children: [
        const _Header(
          icon: Icons.bolt_rounded,
          title: 'Quick download presets',
          subtitle: 'Picked first in a video\'s formats, and used when downloading several videos of a playlist or channel at once.',
        ),
        const SizedBox(height: 12),
        _Choice<int>(
          label: 'Video quality',
          value: s.presetVideoHeight,
          items: [for (final h in ExtraSettings.videoPresets) (h, ExtraSettings.videoPresetLabel(h))],
          onChanged: s.setPresetVideoHeight,
        ),
        _Choice<AudioPreset>(
          label: 'Audio format',
          value: s.presetAudio,
          items: [for (final a in AudioPreset.values) (a, a.label)],
          onChanged: s.setPresetAudio,
        ),
        const SizedBox(height: 8),
        Text('Playlists and channels download as', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        SegmentedButton<MediaKind>(
          segments: const [
            ButtonSegment(value: MediaKind.video, icon: Icon(Icons.movie_rounded), label: Text('Video')),
            ButtonSegment(value: MediaKind.audio, icon: Icon(Icons.music_note_rounded), label: Text('Audio')),
          ],
          selected: {s.presetKind},
          showSelectedIcon: false,
          onSelectionChanged: (v) => s.setPresetKind(v.first),
        ),
        const SizedBox(height: 8),
        Text(
          'A video without the preset\'s quality downloads at the closest one below it.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// A label with a dropdown of choices.
class _Choice<T> extends StatelessWidget {
  const _Choice({required this.label, required this.value, required this.items, required this.onChanged});

  final String label;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          DropdownButton<T>(
            value: value,
            underline: const SizedBox(),
            borderRadius: BorderRadius.circular(14),
            items: [for (final (v, text) in items) DropdownMenuItem(value: v, child: Text(text))],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

class _DownloadsCard extends StatelessWidget {
  const _DownloadsCard({required this.s});

  final ExtraSettings s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final atOnce = s.maxConcurrent;
    return SettingsCard(
      children: [
        const _Header(
          icon: Icons.tune_rounded,
          title: 'Download behaviour',
          subtitle: 'Pause, resume and the queue are on the Downloads tab; unfinished downloads carry on when you open FetchNet again.',
        ),
        if (DeviceEnvironment.isAndroid) ...[
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: s.wifiOnly,
            onChanged: s.setWifiOnly,
            title: const Text('Wi-Fi only'),
            subtitle: const Text('Downloads wait while you\'re on mobile data, and carry on over Wi-Fi.'),
          ),
        ],
        const Divider(height: 20),
        _Choice<int>(
          label: 'Speed limit (each download)',
          value: ExtraSettings.speedLimits.contains(s.speedLimitKbps) ? s.speedLimitKbps : 0,
          items: [for (final k in ExtraSettings.speedLimits) (k, ExtraSettings.speedLabel(k))],
          onChanged: s.setSpeedLimitKbps,
        ),
        const Divider(height: 20),
        Row(
          children: [
            Expanded(child: Text('Downloads at once', style: theme.textTheme.bodyMedium)),
            Text(
              '$atOnce',
              style: theme.textTheme.titleMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        Slider(
          value: atOnce.toDouble(),
          min: 1,
          max: ExtraSettings.maxConcurrentLimit.toDouble(),
          divisions: ExtraSettings.maxConcurrentLimit - 1,
          label: '$atOnce',
          onChanged: (v) => s.setMaxConcurrent(v.round()),
        ),
        Text(
          'The rest wait in the queue and start as others finish.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
