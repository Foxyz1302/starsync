import 'package:flutter/material.dart';

import '../../playback/media_marks.dart';
import '../../widgets/app_menu.dart' show AppGlass;

// The player's floating action pills (Skip OP / ED / 1:30, Next episode):
// plain widgets fed by values and callbacks, so tests pump them without a
// player. They live in the action area, outside the controls.

/// The player's action pill (Next episode, Skip OP / ED / 1:30): the
/// status pill's glass ([AppGlass.pill]) at [height], faint at rest, lit
/// on hover. Lives in the player's action area, outside the auto-hiding
/// controls (also in fullscreen); `PillGate` shows it with them.
class FloatingPill extends StatefulWidget {
  /// Every action pill's height: the status pill's without avatars.
  static const height = 44.0;
  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  /// Key of the tap target (tests find the pill by it).
  final Key? tapKey;
  const FloatingPill({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.icon = Icons.chevron_right_rounded,
    this.tapKey,
  });

  @override
  State<FloatingPill> createState() => _FloatingPillState();
}

class _FloatingPillState extends State<FloatingPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    const fade = Duration(milliseconds: 150);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.tooltip,
        child: AnimatedOpacity(
          duration: fade,
          opacity: _hover ? 1 : 0.45,
          child: GestureDetector(
            key: widget.tapKey,
            onTap: widget.onPressed,
            child: AppGlass.pill(
              child: AnimatedContainer(
                duration: fade,
                height: FloatingPill.height,
                padding: const EdgeInsets.only(left: 16, right: 12),
                color: _hover ? Colors.white12 : Colors.transparent,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.label,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 6),
                    Icon(widget.icon, color: Colors.white, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Skip OP" / "Skip ED" / "Skip 1:30" for a [SkipOffer].
class SkipPill extends StatelessWidget {
  final SkipOffer offer;
  final VoidCallback onPressed;
  const SkipPill({super.key, required this.offer, required this.onPressed});

  static String labelFor(SkipKind kind) => switch (kind) {
        SkipKind.opening => 'Skip OP',
        SkipKind.ending => 'Skip ED',
        SkipKind.fixed => 'Skip 1:30',
      };

  @override
  Widget build(BuildContext context) {
    return FloatingPill(
      label: labelFor(offer.kind),
      tooltip: offer.kind == SkipKind.fixed
          ? 'Skip 1:30 for everyone (Shift+Right)'
          : 'Skip to ${formatClock(offer.target)} for everyone',
      icon: Icons.fast_forward_rounded,
      tapKey: const ValueKey('skip-pill'),
      onPressed: onPressed,
    );
  }
}
