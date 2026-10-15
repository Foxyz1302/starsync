import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../playback/media_marks.dart' show formatClock;
import '../state/session_state.dart';
import '../sync/state_diff.dart' show serverPositionAt;
import 'now_playing_title.dart';
import 'start_banner.dart';

/// In place of the video while self sits out: the media's start card
/// (cover, title, episode), where the others are ("12:34 / 24:00",
/// playing or paused) and "Join back" (or Space). [compact]: the mini
/// player.
class SitOutCard extends StatefulWidget {
  final bool compact;
  const SitOutCard({super.key, this.compact = false});

  @override
  State<SitOutCard> createState() => _SitOutCardState();
}

class _SitOutCardState extends State<SitOutCard> {
  // The position moves on while playing: redraw each second.
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    final small = widget.compact;
    return ListenableBuilder(
      listenable: artChanges(),
      builder: (context, _) => SignalBuilder(builder: (context) {
        final r = coord.serverState.value;
        final now = coord.nowPlaying.value;
        final playing = r?.transport == 'playing';
        final duration = (r?.media?['duration'] as num?)?.toDouble() ?? 0;
        final at = r == null ? 0.0 : serverPositionAt(r, coord.connection.serverNow());
        Duration secs(double s) => Duration(milliseconds: (s * 1000).round());
        final where = r?.media == null
            ? 'Nothing is up'
            : duration > 0
                ? '${formatClock(secs(at.clamp(0, duration)))} / ${formatClock(secs(duration))}'
                : formatClock(secs(at));
        final text = TextStyle(color: Colors.white, fontSize: small ? 12 : 15);
        final panel = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("You're sitting out", style: text.copyWith(fontWeight: FontWeight.w700, fontSize: small ? 13 : 20)),
            SizedBox(height: small ? 4 : 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (r?.media != null) ...[
                  Icon(playing ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      color: Colors.white70, size: small ? 14 : 18),
                  const SizedBox(width: 4),
                ],
                Text(where, key: const ValueKey('sit-out-position'), style: text.copyWith(color: Colors.white70)),
              ],
            ),
            SizedBox(height: small ? 8 : 16),
            FilledButton.icon(
              key: const ValueKey('join-back'),
              onPressed: coord.joinBack,
              icon: Icon(Icons.login_rounded, size: small ? 16 : 20),
              label: Text(small ? 'Join back' : 'Join back (Space)'),
              style: small
                  ? FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    )
                  : null,
            ),
          ],
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            if (now != null) StartCard(now: now) else const ColoredBox(color: Color(0xFF0C0D11)),
            // Small: the card's title sits at the bottom, so the panel goes up top.
            Align(
              alignment: small ? const Alignment(0, -0.35) : Alignment.center,
              child: panel,
            ),
          ],
        );
      }),
    );
  }
}
