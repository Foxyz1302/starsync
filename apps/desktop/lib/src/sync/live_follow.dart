import '../playback/media_marks.dart' show CachedRanges;
import 'state_diff.dart';

/// What [LiveFollow.step] asks of the player: [actions] (a seek in the
/// player's own time, a rate), or [reload] (the live point ran far ahead
/// of anything this player holds: only a fresh open gets there).
typedef LiveStep = ({List<PlayerAction> actions, bool reload});

/// Keeps this player on the group's live point (ARCHITECTURE "Live
/// streams"): every player plays the same moment of the stream, measured
/// in the stream's own time (mpv's `time-pos` plus `demuxer-start-time`:
/// the stream's timestamps, the same for every viewer and every quality),
/// not at its own distance from its own edge. Within [deadBand] nothing
/// happens; up to [seekOver] off the rate goes [rateStep] up or down (no
/// visible hitch); further off it seeks, but only inside what mpv holds
/// (a live stream seeks in its cache alone), then lets the seek land for
/// [settle]. A point beyond its cache it cannot reach: it plays on where
/// it is (a CDN edge a little late), or, more than [reloadOver] behind,
/// asks for a fresh open.
class LiveFollow {
  static const deadBand = 0.08;
  static const seekOver = 1.0;
  static const rateStep = 0.03;
  static const reloadOver = 20.0;
  static const settle = Duration(seconds: 2);
  // Seeks keep this far inside the cached range's end (mpv stalls on a
  // seek to the very last cached frame).
  static const _endGuard = 0.5;

  double _rate = 1.0;
  DateTime? _seekAt;

  /// The rate this follower last set.
  double get rate => _rate;

  /// A new player or media: nothing set yet.
  void reset() {
    _rate = 1.0;
    _seekAt = null;
  }

  /// [group]: the live point now (stream time; null while the server has
  /// none). [own]: this player's position in stream time; [start]: the
  /// stream time of the player's 0 ([own] minus `time-pos`). [cached]:
  /// what mpv holds, in player time.
  LiveStep step({
    required double? group,
    required double own,
    required double start,
    required CachedRanges cached,
    required DateTime now,
  }) {
    final out = <PlayerAction>[];
    void setRate(double r) {
      if (r == _rate) return;
      _rate = r;
      out.add(RateAction(r));
    }

    if (group == null) {
      setRate(1.0);
      return (actions: out, reload: false);
    }
    final seekAt = _seekAt;
    if (seekAt != null && now.difference(seekAt) < settle) return (actions: out, reload: false);
    final err = own - group;
    if (err.abs() <= deadBand) {
      setRate(1.0);
    } else if (err.abs() <= seekOver) {
      setRate(err > 0 ? 1.0 - rateStep : 1.0 + rateStep);
    } else {
      final target = group - start;
      final reachable = cached.ranges.any((r) =>
          target >= r.start.inMicroseconds / 1e6 && target <= r.end.inMicroseconds / 1e6 - _endGuard);
      setRate(1.0);
      if (reachable) {
        _seekAt = now;
        out.add(SeekAction(target));
      } else if (err < -reloadOver) {
        _seekAt = now;
        return (actions: out, reload: true);
      }
    }
    return (actions: out, reload: false);
  }
}

/// Whether a player's length keeps growing like a live stream's: [seen]
/// the durations it reported, in order. Three rises of at least half a
/// second each (a file's length may be corrected once or twice while it
/// opens, never like that).
bool growsLikeLive(List<double> seen) {
  var rises = 0;
  for (var i = 1; i < seen.length; i++) {
    if (seen[i] - seen[i - 1] >= 0.5) rises++;
  }
  return rises >= 3;
}
