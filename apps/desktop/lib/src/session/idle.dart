enum IdleEvent { none, warn, unready }

/// Idle auto-unready clock. Idle time counts from the later of the user's
/// last input and the last moment playback was running: watching is
/// activity, so a long watch followed by a pause starts a fresh 10 min.
/// The unready also always trails its warning by the full grace period.
class IdleTracker {
  static const warnAfter = Duration(minutes: 8);
  static const unreadyAfter = Duration(minutes: 10);

  DateTime _lastActive;
  DateTime? _warnedAt;

  IdleTracker(DateTime now) : _lastActive = now;

  void activity(DateTime now) {
    _lastActive = now;
    _warnedAt = null;
  }

  /// Called once per tick. Warn and unready only matter while self is
  /// ready; while playing the ready flag gates nothing.
  IdleEvent tick(DateTime now, {required bool playing, required bool selfReady}) {
    if (playing) {
      activity(now);
      return IdleEvent.none;
    }
    if (!selfReady) return IdleEvent.none;
    final warnedAt = _warnedAt;
    if (warnedAt != null) {
      if (now.difference(warnedAt) >= unreadyAfter - warnAfter) {
        activity(now);
        return IdleEvent.unready;
      }
      return IdleEvent.none;
    }
    if (now.difference(_lastActive) >= warnAfter) {
      _warnedAt = now;
      return IdleEvent.warn;
    }
    return IdleEvent.none;
  }
}
