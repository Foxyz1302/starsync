import 'dart:math' as math;

// What one viewer actually watched of one opened item, and the rule that
// turns it into "watched", "barely looked" or "stopped part way". Pure, so
// any tracker (Jellyfin today) applies the same rule. See ARCHITECTURE.md
// "Watched rule".

/// What a [WatchSession] amounts to when it ends.
enum WatchOutcome {
  /// Seen: mark it played and clear the resume point.
  played,

  /// Already played when opened (or earlier in this session): stays played
  /// whatever happened, with no resume point.
  keepPlayed,

  /// Barely watched (a peek, a screenshot): leave the item as it was.
  peek,

  /// Part way: resume from [WatchVerdict.resumeAt].
  partial,
}

class WatchVerdict {
  final WatchOutcome outcome;

  /// Where to resume, seconds ([WatchOutcome.partial] only).
  final double? resumeAt;
  const WatchVerdict(this.outcome, {this.resumeAt});

  @override
  String toString() => 'WatchVerdict(${outcome.name}${resumeAt == null ? '' : ', $resumeAt'})';
}

/// One opening of one item on this client. Fed the player position about
/// once a second ([sample]); only normal playback counts as watched: the
/// stretch between two samples while playing, when the position moved
/// forward no faster than [maxRate] (plus [slack]) and the samples are at
/// most [maxGap] apart. Seeks, skips and pauses add nothing. [covered] is the union of the watched stretches,
/// so rewatching a part does not count twice; [watched] is the plain sum.
class WatchSession {
  /// Played before this opening (Jellyfin `UserData.Played`).
  final bool playedBefore;

  /// The resume point before this opening, seconds (0 = none).
  final double resumeBefore;

  final double maxRate;
  final double slack;
  final double maxGap;

  WatchSession(
      {this.playedBefore = false, this.resumeBefore = 0, this.maxRate = 2, this.slack = 1.5, this.maxGap = 10});

  DateTime? startedAt;
  DateTime? endedAt;
  double? firstPosition;
  double? lastPosition;

  /// The furthest position seen, reached by playing or by a jump.
  double furthest = 0;

  /// Seconds of normal playback, rewatches included.
  double watched = 0;

  final _spans = <(double, double)>[];
  ({double pos, bool playing, DateTime at})? _prev;

  /// Seconds of the item covered by normal playback (rewatches once).
  double get covered => _spans.fold(0.0, (s, e) => s + e.$2 - e.$1);

  /// The watched stretches, sorted and merged.
  List<(double, double)> get spans => List.unmodifiable(_spans);

  void sample(double position, {required bool playing, required DateTime at}) {
    final prev = _prev;
    _prev = (pos: position, playing: playing, at: at);
    startedAt ??= at;
    endedAt = at;
    firstPosition ??= position;
    lastPosition = position;
    furthest = math.max(furthest, position);
    if (prev == null || !prev.playing) return;
    final dt = at.difference(prev.at).inMilliseconds / 1000;
    final dp = position - prev.pos;
    if (dt <= 0 || dt > maxGap || dp <= 0 || dp > dt * maxRate + slack) return;
    watched += dp;
    _add(prev.pos, position);
  }

  void _add(double a, double b) {
    final out = <(double, double)>[];
    var (lo, hi) = (a, b);
    for (final (s, e) in _spans) {
      if (e < lo || s > hi) {
        out.add((s, e));
      } else {
        lo = math.min(lo, s);
        hi = math.max(hi, e);
      }
    }
    out
      ..add((lo, hi))
      ..sort((x, y) => x.$1.compareTo(y.$1));
    _spans
      ..clear()
      ..addAll(out);
  }

  /// The rule, for an item [runtime] seconds long whose ending starts at
  /// [endingStart] (an Outro segment or ED chapter; null = the real end):
  /// - played before: [WatchOutcome.keepPlayed];
  /// - [covered] >= 80 % of the runtime, or the ending was reached
  ///   ([furthest]) with [covered] >= 50 %: [WatchOutcome.played];
  /// - [covered] under max(2 min, 5 %) (at most a quarter of a short
  ///   item): [WatchOutcome.peek];
  /// - else [WatchOutcome.partial] at [lastPosition].
  /// An unknown runtime (0) never makes it played.
  WatchVerdict verdict({required double runtime, double? endingStart}) {
    if (playedBefore) return const WatchVerdict(WatchOutcome.keepPlayed);
    final c = covered;
    if (runtime > 0) {
      final end = endingStart != null && endingStart > 0 && endingStart < runtime ? endingStart : runtime - 2;
      if (c >= 0.8 * runtime || (furthest >= end && c >= 0.5 * runtime)) {
        return const WatchVerdict(WatchOutcome.played);
      }
    }
    final peekBelow = runtime > 0 ? math.min(math.max(120.0, 0.05 * runtime), 0.25 * runtime) : 120.0;
    if (c < peekBelow) return const WatchVerdict(WatchOutcome.peek);
    return WatchVerdict(WatchOutcome.partial, resumeAt: lastPosition ?? 0);
  }
}
