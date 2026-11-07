import '../playback/media_marks.dart' show CachedRanges;
import 'state_diff.dart';

/// What [LiveFollow.step] asks of the player: [actions] (a seek in the
/// player's own time, a rate), or [reload] (the live point is out of
/// anything this player holds: only an open at it gets there).
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
/// asks for a fresh open. A point before its cache (a rewind) it asks to
/// open at when the stream lets it rewind (`rewind`), else it plays on.
/// Paused (the group's point held), it only seeks, past [pausedSeekOver]
/// (a seek there shows nothing moving), so it plays on in step.
class LiveFollow {
  static const deadBand = 0.08;
  static const seekOver = 1.0;
  static const rateStep = 0.03;
  static const reloadOver = 20.0;
  static const pausedSeekOver = 0.25;
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

  /// This member seeked its player itself at [now] (ahead of the server's
  /// state, which still has the old point for a moment): it lands first.
  void noteSeek(DateTime now) => _seekAt = now;

  /// The group's point moved (someone else's seek, a pause, a play): no
  /// waiting for an earlier seek to land, the new point counts at once.
  void moved() => _seekAt = null;

  /// Whether mpv's cache ([cached], player time) holds [at] (player
  /// time), far enough inside its end for a seek to land.
  static bool holds(CachedRanges cached, double at) => cached.ranges
      .any((r) => at >= r.start.inMicroseconds / 1e6 && at <= r.end.inMicroseconds / 1e6 - _endGuard);

  /// [group]: the live point now (stream time; null while the server has
  /// none). [own]: this player's position in stream time; [start]: the
  /// stream time of the player's 0 ([own] minus `time-pos`). [cached]:
  /// what mpv holds, in player time. [rewind]: the stream can be opened
  /// further back. [paused]: the group's point is held there.
  LiveStep step({
    required double? group,
    required double own,
    required double start,
    required CachedRanges cached,
    required DateTime now,
    bool rewind = false,
    bool paused = false,
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
    if (err.abs() <= deadBand || (paused && err.abs() <= pausedSeekOver)) {
      setRate(1.0);
    } else if (!paused && err.abs() <= seekOver) {
      setRate(err > 0 ? 1.0 - rateStep : 1.0 + rateStep);
    } else {
      final target = group - start;
      final reachable = holds(cached, target);
      setRate(1.0);
      if (reachable) {
        _seekAt = now;
        out.add(SeekAction(target));
      } else if (err < -reloadOver || (rewind && err > 0)) {
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

/// A live stream's seek bar (ARCHITECTURE "Live streams"): its window from
/// [from] (stream time, the oldest moment every member reaches) to the
/// live point, [length] long; this player at [position] in it and what it
/// holds ([cached]), both from the window's start.
class LiveBar {
  final double from;
  final Duration length;
  final Duration position;
  final CachedRanges cached;
  const LiveBar({required this.from, required this.length, required this.position, required this.cached});

  /// [top]: the live point; [own]: this player's position, [start] its 0,
  /// [cached] in player time (the rest in stream time).
  factory LiveBar.of(
      {required double from,
      required double top,
      required double own,
      required double start,
      required CachedRanges cached}) {
    final span = top > from ? top - from : 0.0;
    Duration d(double secs) => Duration(microseconds: (secs.clamp(0.0, span) * 1e6).round());
    final shift = start - from;
    return LiveBar(
      from: from,
      length: d(span),
      position: d(own - from),
      cached: CachedRanges([
        for (final r in cached.ranges)
          if (r.end.inMicroseconds / 1e6 + shift > 0)
            (start: d(r.start.inMicroseconds / 1e6 + shift), end: d(r.end.inMicroseconds / 1e6 + shift)),
      ]),
    );
  }

  /// The stream time at [at] on the bar.
  double streamTime(Duration at) => from + at.inMicroseconds / 1e6;
}
