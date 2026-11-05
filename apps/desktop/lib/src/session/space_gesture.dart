import 'package:sync_relay_core/core.dart' show Presence;

// The Space key as a gesture (ARCHITECTURE "Desktop UI", "Space and the
// radial"): a tap plays or pauses, a hold is BRB; while anyone else is BRB
// a tap toggles your own BRB and a long hold continues without them. Pure:
// fed key-down, the time held and key-up; no timers, no clock of its own.

/// The gesture's timings.
class SpaceTiming {
  /// Held this long from a plain play or pause: BRB.
  final Duration brbHold;

  /// Held this long while someone else is BRB: continue without them.
  final Duration continueHold;

  /// While someone else is BRB, a press shorter than this is a tap (BRB
  /// too, or back); a longer one let go before [continueHold] does
  /// nothing.
  final Duration tapMax;

  /// The hold's words replace the pill's line this long into a press (a
  /// tap never shows them).
  final Duration wordsAfter;
  const SpaceTiming({
    this.brbHold = const Duration(milliseconds: 600),
    this.continueHold = const Duration(milliseconds: 2000),
    this.tapMax = const Duration(milliseconds: 300),
    this.wordsAfter = const Duration(milliseconds: 150),
  });
}

/// What a Space gesture does to the group.
enum SpaceAction {
  /// Plain, the group wants to play: on key-down, before anything else.
  pause,

  /// Plain, paused: a tap (on key-up; a play on key-down would play
  /// before a hold paused again for BRB).
  play,

  /// Plain: held to [SpaceTiming.brbHold]. The group's wish goes back to
  /// what it was at key-down (it wanted to play: it waits for you, then
  /// plays).
  brbKeepPlay,
  brbKeepPause,

  /// You were BRB with nobody else, AFK or out: on key-down. Someone
  /// else is BRB and you are too: a tap.
  back,

  /// Someone else is BRB: a tap makes you BRB too.
  brbToo,

  /// Someone else is BRB: held to [SpaceTiming.continueHold]. They are
  /// out, you are back, the group plays.
  continueWithout,
}

/// Which hold is running.
enum HoldKind { brb, continueWithout }

/// A hold in progress, for the pill: [progress] 0..1 of its time.
class HoldView {
  final HoldKind kind;
  final double progress;
  final Duration held;

  /// Plain: the group wanted to play at key-down (letting go leaves a
  /// pause, else letting go plays).
  final bool wasPlaying;

  /// While someone is BRB: letting go now still counts as a tap.
  final bool tapStill;

  /// You were BRB at key-down (the tap brings you back).
  final bool selfBrb;
  const HoldView(this.kind, this.progress, this.held,
      {this.wasPlaying = false, this.tapStill = false, this.selfBrb = false});
}

/// The Space key's state machine. Key repeats are not fed (the caller
/// drops them); a second key-down without an up is ignored.
class SpaceGesture {
  SpaceTiming timing;
  SpaceGesture({this.timing = const SpaceTiming()});

  /// Null while the key is up.
  _Press? _press;

  bool get down => _press != null;

  /// [self]: where you stand; [othersBrb]: someone else is BRB;
  /// [playing]: the group wants to play.
  List<SpaceAction> keyDown({required Presence self, required bool othersBrb, required bool playing}) {
    if (_press != null) return const [];
    if (othersBrb) {
      _press = _Press(_Mode.someoneBrb, playing, selfBrb: self == Presence.brb);
      return const [];
    }
    if (self != Presence.watching) {
      _press = _Press(_Mode.done, playing);
      return const [SpaceAction.back];
    }
    _press = _Press(_Mode.plain, playing);
    return playing ? const [SpaceAction.pause] : const [];
  }

  /// The key is still down after [held]: may finish a hold.
  List<SpaceAction> tick(Duration held) {
    final p = _press;
    if (p == null) return const [];
    p.held = held;
    switch (p.mode) {
      case _Mode.plain when held >= timing.brbHold:
        p.mode = _Mode.done;
        return [p.wasPlaying ? SpaceAction.brbKeepPlay : SpaceAction.brbKeepPause];
      case _Mode.someoneBrb when held >= timing.continueHold:
        p.mode = _Mode.done;
        return const [SpaceAction.continueWithout];
      default:
        return const [];
    }
  }

  /// The key went up after [held].
  List<SpaceAction> keyUp(Duration held) {
    final out = tick(held);
    if (out.isNotEmpty) {
      _press = null;
      return out;
    }
    final p = _press;
    _press = null;
    if (p == null) return const [];
    return switch (p.mode) {
      // Paused at key-down already when it played.
      _Mode.plain => p.wasPlaying ? const [] : const [SpaceAction.play],
      _Mode.someoneBrb when held < timing.tapMax => [p.selfBrb ? SpaceAction.back : SpaceAction.brbToo],
      _Mode.someoneBrb || _Mode.done => const [],
    };
  }

  /// The window lost the keys mid-press (the key-up may never come): the
  /// press is dropped. A plain pause stays a pause.
  void cancel() => _press = null;

  /// The hold in progress, or null (none, or already done).
  HoldView? hold() {
    final p = _press;
    if (p == null) return null;
    double of(Duration total) =>
        total.inMicroseconds <= 0 ? 1.0 : (p.held.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);
    return switch (p.mode) {
      _Mode.plain => HoldView(HoldKind.brb, of(timing.brbHold), p.held, wasPlaying: p.wasPlaying),
      _Mode.someoneBrb => HoldView(HoldKind.continueWithout, of(timing.continueHold), p.held,
          tapStill: p.held < timing.tapMax, selfBrb: p.selfBrb),
      _Mode.done => null,
    };
  }
}

enum _Mode { plain, someoneBrb, done }

class _Press {
  _Mode mode;
  final bool wasPlaying;
  final bool selfBrb;
  Duration held = Duration.zero;
  _Press(this.mode, this.wasPlaying, {this.selfBrb = false});
}
