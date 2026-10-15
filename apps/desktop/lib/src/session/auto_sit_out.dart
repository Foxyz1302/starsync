import 'package:sync_relay_core/core.dart' show Presence, PresenceReason;

import '../platform/ports/shell_port.dart' show WindowActivity;

/// The auto sit-out timings, in one place.
abstract final class AutoSitOutTimes {
  /// Not playing and no input for this long: away (`idle`). Watching
  /// counts as activity, so a pause after a long watch starts fresh.
  static const idle = Duration(minutes: 5);

  /// Minimised (or hidden) for this long, playing or not: away
  /// (`minimised`).
  static const minimised = Duration(minutes: 10);
}

/// What [AutoSitOut.tick] asks the session to do.
sealed class AutoSitOutStep {
  const AutoSitOutStep();
}

/// Nothing to do.
final class AutoStay extends AutoSitOutStep {
  const AutoStay();
}

/// Sit this member out (`presence` `away` with [reason]).
final class AutoAway extends AutoSitOutStep {
  final PresenceReason reason;
  const AutoAway(this.reason);
}

/// Bring this member back `in`: it was set away automatically and the
/// user is back.
final class AutoBack extends AutoSitOutStep {
  const AutoBack();
}

/// Auto sit-out: idle for
/// [AutoSitOutTimes.idle] while nothing plays, or minimised for
/// [AutoSitOutTimes.minimised] (playing or not), sets this member away;
/// input or the window's focus brings it back, but only from an away
/// this set ([autoAway]); a manual away (own or someone else's) stays.
/// Never when alone (nobody to hold up or to tell). Pure: the session
/// feeds it input, window changes and a 1 s [tick].
class AutoSitOut {
  final Duration idleAfter;
  final Duration minimisedAfter;
  AutoSitOut(DateTime now,
      {this.idleAfter = AutoSitOutTimes.idle, this.minimisedAfter = AutoSitOutTimes.minimised})
      : _lastActive = now;

  DateTime _lastActive;
  DateTime? _minimisedSince;
  bool _activitySinceAway = false;
  bool _autoAway = false;
  // An away sent, not yet seen in a state.
  DateTime? _sentAt;
  static const _echoWait = Duration(seconds: 10);

  /// The member is away because this set it (not by hand, not someone
  /// else).
  bool get autoAway => _autoAway;

  /// Keyboard, mouse or any action in the app.
  void input(DateTime now) {
    _lastActive = now;
    _activitySinceAway = true;
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

  /// The user sat out (or came back) by hand: an away is no longer ours.
  void manual() {
    _autoAway = false;
    _sentAt = null;
  }

  /// Once a second. [self]: this member's presence in the latest state
  /// (null: not in one); [alone]: nobody else connected ([isAlone]);
  /// [enabled]: the setting (and not a solo session).
  AutoSitOutStep tick(DateTime now,
      {required Presence? self, required bool playing, required bool alone, required bool enabled}) {
    if (playing) _lastActive = now;
    if (self == null || self == Presence.gone) return const AutoStay();
    if (self != Presence.away) {
      final sent = _sentAt;
      if (sent != null && now.difference(sent) < _echoWait) return const AutoStay();
      _sentAt = null;
      _autoAway = false;
    } else {
      _sentAt = null;
      if (_autoAway && _activitySinceAway && _minimisedSince == null) {
        _autoAway = false;
        return const AutoBack();
      }
      return const AutoStay();
    }
    if (!enabled || alone) return const AutoStay();
    final since = _minimisedSince;
    final PresenceReason? reason;
    if (since != null && now.difference(since) >= minimisedAfter) {
      reason = PresenceReason.minimised;
    } else if (!playing && now.difference(_lastActive) >= idleAfter) {
      reason = PresenceReason.idle;
    } else {
      reason = null;
    }
    if (reason == null) return const AutoStay();
    _autoAway = true;
    _activitySinceAway = false;
    _sentAt = now;
    return AutoAway(reason);
  }
}
