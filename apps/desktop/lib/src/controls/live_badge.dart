import 'package:flutter/material.dart';

/// A live stream's time and timeline, in both skins: LIVE, red while this
/// player is on the group's live point, grey while you paused it here (a
/// click goes back to live, as Space does).
class LiveBadge extends StatelessWidget {
  final bool paused;
  final double scale;
  final VoidCallback onBackToLive;
  const LiveBadge({super.key, required this.paused, required this.scale, required this.onBackToLive});

  static const red = Color(0xFFE53935);

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(
        color: paused ? Colors.white24 : red,
        borderRadius: BorderRadius.circular(4 * scale),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6 * scale,
            height: 6 * scale,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          ),
          SizedBox(width: 5 * scale),
          Text(
            'LIVE',
            style: TextStyle(
                color: Colors.white, fontSize: 12 * scale, fontWeight: FontWeight.w700, letterSpacing: 0.6),
          ),
        ],
      ),
    );
    return Tooltip(
      message: paused ? 'Paused here only: back to live (Space)' : 'Live: everyone sees the same moment',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: paused ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          key: const ValueKey('live-badge'),
          onTap: paused ? onBackToLive : null,
          child: Padding(padding: EdgeInsets.symmetric(horizontal: 8 * scale), child: badge),
        ),
      ),
    );
  }
}
