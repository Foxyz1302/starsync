import 'package:sync_relay_core/core.dart' show Presence;

import '../platform/ports/shell_port.dart' show WindowActivity;

/// The AFK timings, in one place.
abstract final class AfkTimes {
  /// No input for this long while nothing plays (a plain pause, the end,
  /// nothing on): AFK. Watching counts as input, so a pause after a long
  /// watch starts fresh.
  static const idle = Duration(minutes: 10);

  /// Minimised (or hidden) for this long while it plays: Out
  /// (`minimised`).
  static const minimised = Duration(minutes: 10);

  /// Input this soon after AFK began does not end it (the click or key
  /// that happened to land with it).
  static const guard = Duration(milliseconds: 1200);
}

/// What [AfkWatch.tick] asks the session to do.
enum AfkStep {
  /// Nothing.
  stay,

  /// Go AFK (`presence` `afk`).
  afk,

  /// Go out, minimised while it played (`presence` `out`, `minimised`).
  outMinimised,

  /// Back from AFK (`presence` `in`): any input after [AfkTimes.guard].
  back,
}

/// AFK, an automatic Out: no input for [AfkTimes.idle] while nothing
/// plays sets this member AFK (never during playback, never on a BRB
/// member, never when alone); any input after [AfkTimes.guard] brings it
/// back. Minimised for [AfkTimes.minimised] while it plays sets it Out
/// (Space or Join brings that back, not the window). Pure: the session
/// feeds it input, window changes and a 1 s [tick].
class AfkWatch {
  final Duration idleAfter;
  final Duration minimisedAfter;
  AfkWatch(DateTime now, {this.idleAfter = AfkTimes.idle, this.minimisedAfter = AfkTimes.minimised})
      : _lastActive = now;

  DateTime _lastActive;
  DateTime? _minimisedSince;
  // When this member was first seen AFK, and whether input came after the
  // guard since.
  DateTime? _afkSince;
  bool _inputSinceAfk = false;
  // A step sent, not yet seen in a state.
  AfkStep _sent = AfkStep.stay;
  DateTime? _sentAt;
  static const _echoWait = Duration(seconds: 10);

  /// Keyboard, mouse or any action in the app.
  void input(DateTime now) {
    _lastActive = now;
    final since = _afkSince;
    if (since != null && now.difference(since) >= AfkTimes.guard) _inputSinceAfk = true;
  }

  /// The window's focus or visibility changed.
  void window(WindowActivity a, DateTime now) {
    switch (a) {
      case WindowActivity.minimised:
      case WindowActivity.hidden:
        _minimisedSince ??= now;
      case WindowActivity.focused:
        _minimisedSince = null;
        input(now);
      case WindowActivity.unfocused:
        _minimisedSince = null;
    }
  }

  /// Once a second. [self]: this member's standing in the latest state
  /// (null: not in one, or disconnected); [playing]: the group plays;
  /// [alone]: nobody else connected ([isAlone]).
  AfkStep tick(DateTime now, {required Presence? self, required bool playing, required bool alone}) {
    if (playing) _lastActive = now;
    if (self == Presence.afk) {
      _afkSince ??= now;
      final sent = _sentAt;
      // The AFK sent came back; a back sent waits for its echo.
      if (_sent == AfkStep.afk || sent == null || now.difference(sent) >= _echoWait) _sentAt = null;
      if (_sentAt != null) return AfkStep.stay;
      if (_inputSinceAfk) {
        _inputSinceAfk = false;
        return _send(AfkStep.back, now);
      }
      return AfkStep.stay;
    }
    _afkSince = null;
    _inputSinceAfk = false;
    final sent = _sentAt;
    if (sent != null && now.difference(sent) < _echoWait) return AfkStep.stay;
    _sentAt = null;
    if (self != Presence.watching || alone) return AfkStep.stay;
    final since = _minimisedSince;
    if (playing && since != null && now.difference(since) >= minimisedAfter) return _send(AfkStep.outMinimised, now);
    if (!playing && now.difference(_lastActive) >= idleAfter) return _send(AfkStep.afk, now);
    return AfkStep.stay;
  }

  AfkStep _send(AfkStep step, DateTime now) {
    _sent = step;
    _sentAt = now;
    return step;
  }
}
