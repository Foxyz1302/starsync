import 'package:flutter/material.dart';

import '../playback/media_marks.dart' show formatClock;

/// A live stream's time, in both skins: LIVE, red while this player is on
/// the group's point at live, grey while you paused it here (a click goes
/// back, as Space does). Once everyone watches it behind live (a rewind,
/// [behind] seconds), how far behind ("−2:30") and Go live, which takes
/// everyone back to live.
class LiveBadge extends StatelessWidget {
  final bool paused;
  final double behind;
  final double scale;
  final VoidCallback onBackToLive;
  final VoidCallback onGoLive;
  const LiveBadge(
      {super.key,
      required this.paused,
      this.behind = 0,
      required this.scale,
      required this.onBackToLive,
      required this.onGoLive});

  static const red = Color(0xFFE53935);

  /// Behind live by less than this shows LIVE.
  static const atLive = 1.0;

  /// "−2:30": [secs] behind live.
  static String behindText(double secs) => '−${formatClock(Duration(milliseconds: (secs * 1000).round()))}';

  @override
  Widget build(BuildContext context) {
    final rewound = behind >= atLive;
    final style = TextStyle(color: Colors.white, fontSize: 12 * scale, fontWeight: FontWeight.w700, letterSpacing: 0.6);
    final badge = Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(
        color: paused || rewound ? Colors.white24 : red,
        borderRadius: BorderRadius.circular(4 * scale),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!rewound) ...[
            Container(
              width: 6 * scale,
              height: 6 * scale,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            ),
            SizedBox(width: 5 * scale),
          ],
          Text(rewound ? behindText(behind) : 'LIVE', style: style),
        ],
      ),
    );
    final time = Tooltip(
      message: paused
          ? 'Paused here only: back to ${rewound ? 'the others' : 'live'} (Space)'
          : rewound
              ? 'Everyone watches ${behindText(behind)} behind live'
              : 'Live: everyone sees the same moment',
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
    if (!rewound) return time;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        time,
        Tooltip(
          message: 'Everyone back to live',
          waitDuration: const Duration(milliseconds: 500),
          child: TextButton(
            key: const ValueKey('go-live'),
            onPressed: onGoLive,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 8 * scale),
              minimumSize: Size(0, 28 * scale),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6 * scale,
                  height: 6 * scale,
                  decoration: const BoxDecoration(color: red, shape: BoxShape.circle),
                ),
                SizedBox(width: 5 * scale),
                Text('Go live', style: style.copyWith(letterSpacing: 0)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
