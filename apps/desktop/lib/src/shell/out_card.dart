import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show Presence;

import '../app/app_graph.dart';
import '../controls/controls_probe.dart';
import '../controls/model/controls_layout.dart' show liveTimeText;
import '../playback/media_marks.dart' show formatClock;
import '../sync/state_diff.dart' show serverPositionAt;
import '../widgets/app_menu.dart' show AppGlass, AppMenuStyle;
import 'motion.dart';
import 'player_status.dart' show Keycap;

// Out (`Presence.out`: the player's ×, the radial, a card, minimised while
// it played): the player keeps your spot's still picture, dimmed, and a
// small card in its middle says so, where the others are and one Join
// (Space too). AFK keeps the status pill: any input brings it back.

/// You are out (tracked: call inside a builder).
bool selfOutNow(BuildContext context) =>
    AppScope.of(context).coordinator.selfMember.value?.presence == Presence.out;

/// The dim over your spot's picture while you are out; it takes no
/// clicks (the controls stay usable over it).
class OutScrim extends StatelessWidget {
  const OutScrim({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: SignalBuilder(
          builder: (context) => AnimatedOpacity(
            key: const ValueKey('out-scrim'),
            duration: easeTime,
            curve: ease,
            opacity: selfOutNow(context) ? 1 : 0,
            child: const ColoredBox(color: Color(0x99000000)),
          ),
        ),
      );
}

/// The card in the middle of the player while you are out: "You're out",
/// what the others are watching and where ("12:34 / 24:00", playing or
/// paused, ticking), and Join (Space). [compact]: the mini player (no
/// title: its hover bar has it). The mouse on it holds the controls up
/// ([hold]).
class OutCard extends StatefulWidget {
  final bool compact;
  final ControlsHold? hold;
  const OutCard({super.key, this.compact = false, this.hold});

  @override
  State<OutCard> createState() => _OutCardState();
}

class _OutCardState extends State<OutCard> {
  // While shown, the others' position moves on: redraw each second.
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _ticking(bool on) {
    if (on && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!on) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final out = selfOutNow(context);
      _ticking(out);
      final card = out ? _card(context) : const SizedBox.shrink(key: ValueKey('out-none'));
      return Center(
        child: fadeThrough(
          out ? ControlsHoldRegion(key: const ValueKey('out-card'), hold: widget.hold, child: card) : card,
          expand: false,
        ),
      );
    });
  }

  Widget _card(BuildContext context) {
    final coord = AppScope.of(context).coordinator;
    final small = widget.compact;
    final r = coord.serverState.value;
    final now = coord.nowPlaying.value;
    final media = r?.media;
    final duration = (media?['duration'] as num?)?.toDouble() ?? 0;
    Duration secs(double s) => Duration(milliseconds: (s * 1000).round());
    final at = r == null ? 0.0 : serverPositionAt(r, coord.connection.serverNow());
    final where = media?['live'] == true && r != null
        ? liveTimeText(r.liveBehindAt(coord.connection.serverNow()))
        : duration > 0
            ? '${formatClock(secs(at.clamp(0, duration)))} / ${formatClock(secs(duration))}'
            : formatClock(secs(at));
    final (IconData icon, String state) = switch (r?.transport) {
      'playing' => (Icons.play_arrow_rounded, 'playing'),
      'finished' => (Icons.stop_rounded, 'finished'),
      _ => (Icons.pause_rounded, 'paused'),
    };
    const dim = TextStyle(color: Colors.white60, fontSize: 12.5, height: 1.25);
    final title = [?now?.title, if (now?.episode case final e? when e.isNotEmpty) e].join(' · ');
    return AppGlass(
      radius: small ? 10 : AppMenuStyle.radius,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: small ? 260 : 360),
        child: Padding(
          padding: small ? const EdgeInsets.fromLTRB(14, 10, 14, 12) : const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_off_rounded, size: small ? 15 : 18, color: Colors.white60),
                  SizedBox(width: small ? 6 : 8),
                  Text("You're out",
                      style: TextStyle(color: Colors.white, fontSize: small ? 14 : 17, fontWeight: FontWeight.w700)),
                ],
              ),
              SizedBox(height: small ? 6 : 10),
              if (media == null)
                const Text('Nothing is on right now', style: dim)
              else ...[
                if (!small && title.isNotEmpty)
                  Text('The others are watching $title',
                      key: const ValueKey('out-title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: dim.copyWith(color: Colors.white70)),
                if (!small && title.isNotEmpty) const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 16, color: Colors.white70),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('$where · $state',
                          key: const ValueKey('out-where'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: dim.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                  ],
                ),
              ],
              SizedBox(height: small ? 10 : 16),
              FilledButton(
                key: const ValueKey('out-join'),
                onPressed: coord.join,
                style: FilledButton.styleFrom(
                  visualDensity: small ? VisualDensity.compact : null,
                  padding: EdgeInsets.only(left: small ? 12 : 16, right: small ? 8 : 10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Join'),
                    const SizedBox(width: 10),
                    // Space joins too.
                    Keycap('Space', ink: Theme.of(context).colorScheme.onPrimary),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
