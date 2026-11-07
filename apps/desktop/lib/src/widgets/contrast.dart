import 'dart:math' as math;

import 'package:flutter/painting.dart';

// Any colour someone picks stays readable where it is used: the text on
// it (a letter avatar's initial) and the name drawn in it on a dark
// background (chat, danmaku). The stored colour never changes; each use
// adjusts its own copy.

/// The WCAG contrast ratio of [a] and [b] (1 to 21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The dark text on light colours.
const initialsDark = Color(0xFF1B1B1F);

/// Text drawn on [background] (a letter avatar's initial): white while it
/// reads (3:1, the large-text bar: initials are large), else whichever of
/// white and [initialsDark] contrasts more.
Color textOn(Color background) {
  const light = Color(0xFFFFFFFF);
  final white = contrastRatio(light, background);
  if (white >= 3) return light;
  return white >= contrastRatio(initialsDark, background) ? light : initialsDark;
}

/// [color] as text on [background]: itself when the contrast reaches
/// [min], else with its lightness moved away from the background's
/// (lifted on a dark one) until it does, hue and saturation kept.
Color readableOn(Color color, Color background, {double min = 4.5}) {
  if (contrastRatio(color, background) >= min) return color;
  final hsl = HSLColor.fromColor(color);
  final up = background.computeLuminance() < 0.5;
  var l = hsl.lightness;
  for (var i = 0; i < 50; i++) {
    l = (l + (up ? 0.02 : -0.02)).clamp(0.0, 1.0);
    final c = hsl.withLightness(l).toColor();
    if (contrastRatio(c, background) >= min || l == 0 || l == 1) return c.withValues(alpha: color.a);
  }
  return hsl.withLightness(l).toColor();
}
