import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../volume.dart' show maxVolume;

// uosc's volume slider (`elements/Volume.lua`) as it flashes on a volume
// change: a vertical band at the right edge, black at `opacity.slider`
// with a white gauge from the bottom, notches at 100 %, the value at the
// bottom (black on the gauge, white off it).

/// The flashed uosc volume slider; size it with [UoscVolumeSlider.width]
/// and the height uosc gives it (see [UoscVolumeSlider.heightFor]).
class UoscVolumeSlider extends StatelessWidget {
  /// 0..[maxVolume].
  final double volume;
  const UoscVolumeSlider({super.key, required this.volume});

  /// `volume_size`.
  static const width = 40.0;

  /// uosc: min(size * 8, 80 % of the room between the bars), less the
  /// mute button (one [width]) below it.
  static double heightFor(double room) => math.min(width * 8, room * 0.8) - width;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('uosc-volume-flash'),
    painter: UoscVolumePainter(
      volume: volume,
      fontFamily: DefaultTextStyle.of(context).style.fontFamily ?? Theme.of(context).textTheme.bodyMedium?.fontFamily,
    ),
  );
}

class UoscVolumePainter extends CustomPainter {
  final double volume;
  final String? fontFamily;
  const UoscVolumePainter({required this.volume, this.fontFamily});

  /// `volume_border`, `border_radius`.
  static const border = 1.0;
  static const radius = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= w) return;
    final v = volume.clamp(0.0, maxVolume);
    final nudgeY = h - (h * (100 / maxVolume)).roundToDouble();
    final nudge = (w * 0.18).roundToDouble();
    final spacing = (w * 0.2).roundToDouble();
    Path notches(double inset) {
      final n = nudge - inset;
      return Path()
        ..moveTo(0, nudgeY - nudge)
        ..lineTo(inset + n, nudgeY)
        ..lineTo(0, nudgeY + nudge)
        ..close()
        ..moveTo(w, nudgeY - nudge)
        ..lineTo(w - inset - n, nudgeY)
        ..lineTo(w, nudgeY + nudge)
        ..close();
    }

    final bg = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(radius + border));
    final volumeY = border + (h - border * 2) * (1 - math.min(v / maxVolume, 1));
    final gauge = RRect.fromRectAndRadius(
      Rect.fromLTRB(border, math.min(volumeY, h - border), w - border, h - border),
      const Radius.circular(radius),
    );
    // The notches cut into both.
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addPath(notches(0), Offset.zero),
    );
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(bg)
        ..addRRect(gauge),
      Paint()..color = Colors.black.withValues(alpha: 0.9),
    );
    canvas.restore();
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addPath(notches(border), Offset.zero),
    );
    canvas.drawRRect(gauge, Paint()..color = Colors.white);
    canvas.restore();

    // round(volume * 10) / 10, as Lua prints it ("85", "85.5").
    final tenths = (v * 10).round();
    final text = tenths % 10 == 0 ? '${tenths ~/ 10}' : (tenths / 10).toString();
    final fontSize = (w * 0.6 - text.length * (w / 20)).roundToDouble();
    TextPainter label(Color color) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: fontFamily, fontSize: fontSize, height: 1, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dark = label(Colors.black), light = label(Colors.white);
    final at = Offset((w - dark.width) / 2, h - spacing - dark.height);
    canvas.save();
    canvas.clipRRect(gauge);
    dark.paint(canvas, at);
    canvas.restore();
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(gauge),
    );
    light.paint(canvas, at);
    canvas.restore();
  }

  @override
  bool shouldRepaint(UoscVolumePainter old) => old.volume != volume || old.fontFamily != fontFamily;
}
