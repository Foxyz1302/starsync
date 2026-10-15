import 'package:flutter/material.dart';

import '../../widgets/app_menu.dart' show AppMenuStyle;

// The Minimal skin's look: the app's glass and accent (the theme's primary)
// on a thick timeline band, with soft rounded buttons in two glass capsules.

abstract final class MinimalStyle {
  /// The timeline band (no blur: it spans the width over the picture).
  static const band = Color(0xCC0E0E12);

  /// The capsules holding the buttons: the player pills' glass.
  static const capsule = AppMenuStyle.pillGlass;
  static const hover = Color(0x1FFFFFFF);
  static const text = Colors.white;
  static const dim = Color(0xB3FFFFFF);
  static const radius = 10.0;
  static const fontSize = 13.0;

  /// The tooltips and the timeline's hover tip.
  static const tip = Color(0xEB18181C);

  /// A button's box at scale 1.
  static const button = 38.0;

  /// The capsules' padding around the buttons.
  static const capsulePad = 4.0;
}

/// The Minimal skin's tooltip: the app's dark glass colour, above.
class MinimalTooltip extends StatelessWidget {
  final String message;
  final Widget child;
  const MinimalTooltip({super.key, required this.message, required this.child});

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return child;
    return Tooltip(
      message: message,
      preferBelow: false,
      verticalOffset: 28,
      waitDuration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: MinimalStyle.tip,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppMenuStyle.border, width: 0.5),
      ),
      textStyle: const TextStyle(color: MinimalStyle.text, fontSize: 12),
      child: child,
    );
  }
}

/// A Minimal button: a white icon on a rounded square that lights on hover
/// ([accent]: filled with the theme's primary, the play button), an
/// optional [label] and a count [badge]. Never takes focus.
class MinimalButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final String? label;
  final int? badge;
  final bool accent;
  final Color? color;
  final double scale;
  const MinimalButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.label,
    this.badge,
    this.accent = false,
    this.color,
    this.scale = 1,
  });

  @override
  State<MinimalButton> createState() => _MinimalButtonState();
}

class _MinimalButtonState extends State<MinimalButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final primary = Theme.of(context).colorScheme.primary;
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final enabled = w.onPressed != null;
    final size = MinimalStyle.button * w.scale;
    final fg = !enabled
        ? MinimalStyle.dim.withValues(alpha: 0.35)
        : w.accent
        ? onPrimary
        : (w.color ?? MinimalStyle.text);
    final bg = w.accent
        ? (_hover ? Color.lerp(primary, Colors.white, 0.18)! : primary)
        : (_hover && enabled ? MinimalStyle.hover : Colors.transparent);
    final badge = w.badge;
    return MinimalTooltip(
      message: w.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: w.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: size,
            constraints: BoxConstraints(minWidth: size),
            padding: EdgeInsets.symmetric(horizontal: w.label == null ? 0 : 10 * w.scale),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(w.accent ? size / 2 : MinimalStyle.radius * w.scale),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(w.icon, color: fg, size: (w.accent ? 26 : 22) * w.scale),
                    if (badge != null && badge > 0)
                      Positioned(
                        right: -7,
                        top: -5,
                        child: Container(
                          key: const ValueKey('minimal-badge'),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(color: primary, borderRadius: BorderRadius.circular(999)),
                          child: Text(
                            '$badge',
                            style: TextStyle(color: onPrimary, fontSize: 9, height: 1.35, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                  ],
                ),
                if (w.label != null) ...[
                  SizedBox(width: 6 * w.scale),
                  Text(
                    w.label!,
                    style: TextStyle(
                      color: fg,
                      fontSize: MinimalStyle.fontSize * w.scale,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A glass capsule around a row of Minimal buttons.
class MinimalCapsule extends StatelessWidget {
  final List<Widget> children;
  final double scale;
  const MinimalCapsule({super.key, required this.children, this.scale = 1});

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(MinimalStyle.radius * scale + MinimalStyle.capsulePad);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: MinimalStyle.capsule,
        borderRadius: r,
        border: Border.all(color: AppMenuStyle.border, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(MinimalStyle.capsulePad),
        child: Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: children),
      ),
    );
  }
}
