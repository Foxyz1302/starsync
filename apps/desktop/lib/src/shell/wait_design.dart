import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart' show MemberView;

import '../app/app_graph.dart';
import '../screens/home/ui.dart' show devTools;
import '../session/session_coordinator.dart';
import '../session/space_gesture.dart' show HoldView;
import '../session/space_key.dart' show holdKeysFor;
import '../widgets/app_menu.dart' show AppGlass;
import 'avatar.dart';
import 'motion.dart';
import 'player_status.dart';

// Dev builds only, until real evenings decide (removed before release):
// how the group's waiting shows. A is the pill at the bottom centre (the
// default, and the only one in a release); C is a card in the middle of
// the paused picture; D is C fading with the controls. Env
// STARSYNC_WAIT_DESIGN=a|c|d; no setting.

enum WaitDesign { a, c, d }

/// The waiting design of this run ([WaitDesign.a] in a release).
final WaitDesign waitDesign = _design();

WaitDesign _design() {
  if (!devTools) return WaitDesign.a;
  return switch (Platform.environment['STARSYNC_WAIT_DESIGN']) {
    'c' => WaitDesign.c,
    'd' => WaitDesign.d,
    _ => WaitDesign.a,
  };
}

/// A line about the group waiting for someone's BRB (or yours): what
/// designs C and D show as the card.
bool isWaitLine(StatusLine l) => l.kind == StatusKind.you || (l.kind == StatusKind.waiting && l.keys.isNotEmpty);

/// Design C's card in the middle of the paused picture: the line as a
/// title, who the group waits for large (64 px) with their name and "BRB ·
/// 4 min", and the keys; a Space hold sweeps a fill across it and swaps
/// the keys for what keeping on and letting go do. [shown] false: it fades
/// out (design D with the controls hidden; a hold always shows it).
class WaitCard extends StatelessWidget {
  final bool shown;
  const WaitCard({super.key, this.shown = true});

  static const avatar = 64.0;
  static const _most = 4;

  @override
  Widget build(BuildContext context) {
    final coord = AppScope.of(context).coordinator;
    return ValueListenableBuilder<HoldView?>(
      valueListenable: coord.space.hold,
      builder: (context, hold, _) => PartyWatch(builder: (context) {
        final line = coord.status.value.line;
        final waiting = line != null && isWaitLine(line);
        final visible = waiting && (shown || hold != null);
        return IgnorePointer(
          child: Stack(children: [
            Positioned.fill(
              child: AnimatedOpacity(
                duration: easeTime,
                curve: ease,
                opacity: visible ? 1 : 0,
                child: const ColoredBox(color: Color(0x47000000)),
              ),
            ),
            Center(
              child: AnimatedSwitcher(
                duration: easeTime,
                switchInCurve: ease,
                switchOutCurve: Curves.easeIn,
                child: !visible ? const SizedBox.shrink(key: ValueKey('no-card')) : _card(context, coord, line, hold),
              ),
            ),
          ]),
        );
      }),
    );
  }

  Widget _card(BuildContext context, SessionCoordinator coord, StatusLine line, HoldView? hold) {
    final r = coord.serverState.value;
    final me = coord.connection.memberId;
    final others = [for (final m in r?.members ?? const <MemberView>[]) if (m.brb && m.id != me) m];
    final who = line.who.take(_most).toList();
    final more = line.who.length - who.length;
    final keys = hold != null && hold.held.inMilliseconds >= 150 ? holdKeysFor(hold, others) : line.keys;
    final shape = AvatarShape.of(context);
    String ago(MemberView m) {
      final s = m.since;
      if (s == null) return 'now';
      final d = coord.connection.serverNow().difference(s);
      if (d.inMinutes < 1) return 'now';
      return d.inMinutes < 60 ? '${d.inMinutes} min' : '${d.inHours} h';
    }

    Widget person(MemberView m) => SizedBox(
          width: 88,
          child: Column(
            children: [
              StatusAvatar(info: memberAvatarInfo(m, r, coord), size: avatar, badges: false),
              const SizedBox(height: 7),
              Text(m.id == me ? 'You' : m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text('BRB · ${ago(m)}', maxLines: 1, style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
            ],
          ),
        );
    return ConstrainedBox(
      key: const ValueKey('wait-card'),
      constraints: const BoxConstraints(maxWidth: 560),
      child: AppGlass(
        radius: 20,
        child: Stack(
          children: [
            Positioned.fill(child: HoldFill(hold: coord.space.hold)),
            Padding(
              padding: const EdgeInsets.fromLTRB(19, 15, 19, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(line.text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700, height: 1.2)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final m in who) person(m),
                      if (more > 0)
                        Container(
                          width: avatar,
                          height: avatar,
                          margin: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12), borderRadius: shape.radius(avatar)),
                          child: Text('+$more',
                              style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
                  if (keys.isNotEmpty) ...[
                    const SizedBox(height: 11),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 140),
                      child: KeyHints(keys, key: ValueKey(keys.map((k) => k.$1 + k.$2).join())),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
