import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Colours taken from a cover picture: a deep background (two tones for a
/// gradient) and a vivid accent for the controls. The background is always
/// dark enough for white text.
class ArtPalette {
  const ArtPalette({required this.top, required this.bottom, required this.accent});

  final Color top;
  final Color bottom;
  final Color accent;

  /// Reads [bytes] at a tiny size (fast) and picks its colours; `null` when
  /// the picture can't be read.
  static Future<ArtPalette?> fromBytes(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 48, targetHeight: 48);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      if (data == null) return null;
      return fromPixels(data.buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }

  /// [rgba]: pixels, 4 bytes each.
  static ArtPalette? fromPixels(Uint8List rgba) {
    // Colours counted in coarse buckets (4 bits per channel).
    final counts = <int, int>{};
    final sums = <int, List<int>>{};
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      counts[key] = (counts[key] ?? 0) + 1;
      final s = sums.putIfAbsent(key, () => [0, 0, 0]);
      s[0] += r;
      s[1] += g;
      s[2] += b;
    }
    if (counts.isEmpty) return null;
    Color average(int key) {
      final n = counts[key]!, s = sums[key]!;
      return Color.fromARGB(255, s[0] ~/ n, s[1] ~/ n, s[2] ~/ n);
    }

    // The most common colour sets the mood; the most colourful common one
    // becomes the accent.
    final keys = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final dominant = HSLColor.fromColor(average(keys.first));
    var vivid = dominant;
    var best = -1.0;
    final total = counts.values.fold(0, (a, b) => a + b);
    for (final k in keys.take(24)) {
      final c = HSLColor.fromColor(average(k));
      var score = c.saturation * counts[k]! * (1 - (c.lightness - 0.5).abs());
      // A colour that stands out from the background (and isn't a speck)
      // makes a livelier accent: up to twice the weight.
      final hueGap = ((c.hue - dominant.hue).abs() % 360).clamp(0, 360);
      final gap = hueGap > 180 ? 360 - hueGap : hueGap;
      if (counts[k]! >= total * 0.04 && dominant.saturation >= 0.08) score *= 1 + (gap.clamp(0, 90) / 90);
      if (score > best) {
        best = score;
        vivid = c;
      }
    }
    // Grey covers: a soft violet keeps FetchNet's look.
    final base = dominant.saturation < 0.08 ? dominant.withHue(265).withSaturation(0.18) : dominant;
    var top = base.withLightness(base.lightness.clamp(0.16, 0.26)).withSaturation((base.saturation * 0.9).clamp(0.1, 0.65));
    // Bright hues (yellow, cyan) look light even when dark in HSL: darker
    // until white text reads well on them.
    while (top.toColor().computeLuminance() > 0.09 && top.lightness > 0.08) {
      top = top.withLightness(top.lightness - 0.02);
    }
    final bottom = top.withLightness((top.lightness * 0.45).clamp(0.05, 0.1)).withHue((top.hue + 12) % 360);
    final accentHsl = (vivid.saturation < 0.15 ? base : vivid)
        .withLightness(0.66)
        .withSaturation(((vivid.saturation < 0.15 ? base : vivid).saturation).clamp(0.45, 0.85));
    return ArtPalette(top: top.toColor(), bottom: bottom.toColor(), accent: accentHsl.toColor());
  }

  static ArtPalette lerp(ArtPalette a, ArtPalette b, double t) => ArtPalette(
        top: Color.lerp(a.top, b.top, t)!,
        bottom: Color.lerp(a.bottom, b.bottom, t)!,
        accent: Color.lerp(a.accent, b.accent, t)!,
      );
}
