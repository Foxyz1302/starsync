import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

import 'session_coordinator.dart';
import 'space_gesture.dart';

/// The Space key in a server: [SpaceGesture] on the session. The window's
/// key handler ([AppKeys]) feeds it key-down, every frame while held, and
/// key-up; it drops the press when the window loses the keys. [hold]
/// follows the press every frame (the pill's fill), [holdLine] says what
/// keeping on and letting go do, from [SpaceTiming.wordsAfter] on.
class SpaceKey {
  final SessionCoordinator coord;
  SpaceKey(this.coord);

  final gesture = SpaceGesture();
  final _press = Stopwatch();

  /// The hold in progress (every frame while held), or null.
  final hold = ValueNotifier<HoldView?>(null);

  /// The pill's words for the hold, changed only when they change; null
  /// before [SpaceTiming.wordsAfter] and when nothing is held.
  final holdLine = ValueNotifier<StatusLine?>(null);

  bool get down => gesture.down;

  MemberView? get _self => coord.selfMember.peek();

  List<MemberView> get _othersBrb {
    final r = coord.serverState.peek();
    final me = coord.connection.memberId;
    return [for (final m in r?.members ?? const <MemberView>[]) if (m.brb && m.id != me) m];
  }

  /// Space went down (not a repeat).
  void keyDown() {
    if (gesture.down) return;
    // Live: Space pauses and plays this player only (nobody waits, so no
    // BRB hold); out, it joins.
    if (coord.live.peek()) {
      coord.togglePlay();
      return;
    }
    _press
      ..reset()
      ..start();
    _apply(gesture.keyDown(
      self: _self?.presence ?? Presence.watching,
      othersBrb: _othersBrb.isNotEmpty,
      playing: coord.serverState.peek()?.wantsPlay ?? false,
    ));
    _show();
  }

  /// Every frame while held; [held]: how long (the frame clock's, so
  /// tests step it), else the wall clock since key-down.
  void tick([Duration? held]) {
    if (!gesture.down) return;
    _apply(gesture.tick(held ?? _press.elapsed));
    _show();
  }

  /// Space went up after [held] (as [tick]).
  void keyUp([Duration? held]) {
    if (!gesture.down) return;
    _press.stop();
    _apply(gesture.keyUp(held ?? _press.elapsed));
    _clear();
  }

  /// The window lost the keys mid-press: dropped, nothing more happens.
  void cancel() {
    if (!gesture.down) return;
    gesture.cancel();
    _press.stop();
    _clear();
  }

  void _clear() {
    hold.value = null;
    holdLine.value = null;
  }

  void _apply(List<SpaceAction> actions) {
    for (final a in actions) {
      switch (a) {
        case SpaceAction.pause:
          coord.pause();
        case SpaceAction.play:
          coord.play();
        case SpaceAction.brbKeepPlay:
          coord.brb(resume: true);
        case SpaceAction.brbKeepPause:
          coord.brb();
        case SpaceAction.back:
          coord.back();
        case SpaceAction.brbToo:
          coord.brb();
        case SpaceAction.continueWithout:
          coord.continueWithout();
      }
    }
  }

  void _show() {
    final h = gesture.hold();
    hold.value = h;
    if (h == null || h.held < gesture.timing.wordsAfter) {
      holdLine.value = null;
      return;
    }
    final line = holdLineFor(h, self: _self, othersBrb: _othersBrb);
    final was = holdLine.value;
    if (was == null || was.text != line.text || was.detail != line.detail) holdLine.value = line;
  }

  void dispose() {
    hold.dispose();
    holdLine.dispose();
  }
}

/// What the pill says during a hold [h]: what keeping on does, and what
/// letting go does now.
StatusLine holdLineFor(HoldView h, {MemberView? self, List<MemberView> othersBrb = const []}) {
  if (h.kind == HoldKind.brb) {
    return StatusLine(StatusKind.you, 'Keep holding: BRB',
        detail: h.wasPlaying ? 'Let go: just pause' : 'Let go: play', who: [?self], self: true);
  }
  return StatusLine(StatusKind.waiting, 'Keep holding: continuing without ${nameList([for (final m in othersBrb) m.name])}',
      detail: h.tapStill ? (h.selfBrb ? "Let go now: I'm back" : 'Let go now: BRB too') : 'Let go: keep waiting',
      who: othersBrb);
}

/// The keys a hold [h] offers, as keycaps (the dev-only centre card).
List<KeyHint> holdKeysFor(HoldView h, List<MemberView> othersBrb) {
  if (h.kind == HoldKind.brb) return [('Keep holding', 'BRB'), ('Let go', h.wasPlaying ? 'just pause' : 'play')];
  final names = nameList([for (final m in othersBrb) m.name]);
  return h.tapStill
      ? [('Let go', h.selfBrb ? "I'm back" : 'BRB too'), ('Keep holding', 'continue without $names')]
      : [('Keep holding', 'continue without $names'), ('Let go', 'keep waiting')];
}
