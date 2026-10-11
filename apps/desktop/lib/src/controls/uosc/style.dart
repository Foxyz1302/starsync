import 'package:flutter/material.dart';

// Look of the experimental mpv-style controls, after the uosc theme as the
// owner runs it: flat black panels, white icons, a muted blue fill.

abstract final class UoscStyle {
  /// The active menu row.
  static const fill = Color(0xFF4C6A8E);
  /// Menus and tooltips.
  static const panel = Color(0xF0101010);
  static const hover = Color(0x24FFFFFF);
  static const text = Colors.white;
  static const dim = Color(0xA6FFFFFF);
  static const radius = 4.0;
  static const fontSize = 13.0;
}

/// uosc's clock: "01:51", "1:02:03" style but zero-padded ("01:02:03")
/// once [withHours] (the media is an hour or longer).
String formatUoscTime(Duration d, {bool withHours = false}) {
  final t = d.isNegative ? Duration.zero : d;
  String two(int n) => n.toString().padLeft(2, '0');
  final h = t.inHours, m = t.inMinutes % 60, s = t.inSeconds % 60;
  return withHours || h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Dark rounded hover tip ("Subtitles"), shown above its child.
class UoscTooltip extends StatelessWidget {
  final String message;
  final Widget child;
  const UoscTooltip({super.key, required this.message, required this.child});

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return child;
    return Tooltip(
      message: message,
      preferBelow: false,
      verticalOffset: 26,
      waitDuration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: UoscStyle.panel,
        borderRadius: BorderRadius.circular(UoscStyle.radius),
      ),
      textStyle: const TextStyle(color: UoscStyle.text, fontSize: 12),
      child: child,
    );
  }
}

/// A small dark box with one line of text (the timeline's hover time and
/// chapter title).
class UoscBox extends StatelessWidget {
  final String text;
  final Color color;
  final TextStyle style;
  const UoscBox(
    this.text, {
    super.key,
    this.color = UoscStyle.panel,
    this.style = const TextStyle(color: UoscStyle.text, fontSize: UoscStyle.fontSize),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(UoscStyle.radius)),
      child: Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
    );
  }
}
