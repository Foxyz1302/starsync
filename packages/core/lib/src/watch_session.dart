import 'dart:math' as math;

// What one viewer actually watched of one opened item, and the rule that
// turns it into "watched", "barely looked" or "stopped part way" (D3).
// Pure, so every tracker (the device history, Jellyfin, AniList later)
// applies the same rule. See ARCHITECTURE.md "Watch tracking".

/// What a [WatchSession] amounts to when it ends.
enum WatchOutcome {
  /// Seen: mark it played and clear the resume point.
  played,

  /// Already played when opened (or earlier in this session): stays played
  /// whatever happened, with no resume point.
  keepPlayed,

  /// Barely watched (a peek, a screenshot visit, skipping around): leave
  /// the item as it was.
  peek,

  /// Part way: resume from [WatchVerdict.resumeAt].
  partial,
}

class WatchVerdict {
  final WatchOutcome outcome;

  /// Where to resume, seconds ([WatchOutcome.partial] only).
  final double? resumeAt;
  const WatchVerdict(this.outcome, {this.resumeAt});

  /// It counts as watched (played now, or played before).
  bool get watched => outcome == WatchOutcome.played || outcome == WatchOutcome.keepPlayed;

  @override
  String toString() => 'WatchVerdict(${outcome.name}${resumeAt == null ? '' : ', $resumeAt'})';
}

/// One opening of one item on this app. Fed about once a second
/// ([sample]) with the player's position, whether the media plays here
/// (the server's transport is playing and this player plays it) and
/// whether this viewer is In (present: `in`, from the presence the server
/// reports for it). The basis is [timeIn]: wall time the media played
/// while this viewer was In. Time sat out (Away), joining, gone, paused or
/// held never counts, nor does a jump: skipping around adds only the time
/// actually played. Two samples further apart than [maxGap] add nothing
/// (the app stalled). A resume carries the earlier watch: when what played
/// here starts at about the resume point ([resumeBefore], 60 s either
/// way) and nothing before it played, the time up to it counts as watched
/// before ([credited]).
class WatchSession {
  /// Played before this opening (Jellyfin `UserData.Played`, the device's
  /// watch history); set once known (Jellyfin answers after the open).
  bool playedBefore;

  /// The resume point before this opening, seconds (0 = none).
  double resumeBefore;

  final double maxGap;

  WatchSession({this.playedBefore = false, this.resumeBefore = 0, this.maxGap = 10});

  DateTime? startedAt;
  DateTime? endedAt;
  double? firstPosition;
  double? lastPosition;

  /// The furthest position seen while In, reached by playing or by a jump.
  double furthest = 0;

  /// Seconds the media played while this viewer was In.
  double timeIn = 0;

  /// The lowest position it played from while In; null before any.
  double? playedFrom;

  /// [timeIn] plus the time before the resume point when this opening
  /// continued from it.
  double get credited {
    final from = playedFrom;
    final resumed = resumeBefore > 0 && from != null && (from - resumeBefore).abs() <= 60;
    return timeIn + (resumed ? resumeBefore : 0);
  }

  ({DateTime at, double pos, bool counting})? _prev;

  void sample(double position, {required bool playing, required bool present, required DateTime at}) {
    final prev = _prev;
    _prev = (at: at, pos: position, counting: playing && present);
    startedAt ??= at;
    endedAt = at;
    if (present) {
      firstPosition ??= position;
      lastPosition = position;
      furthest = math.max(furthest, position);
    }
    if (prev == null || !prev.counting) return;
    final dt = at.difference(prev.at).inMilliseconds / 1000;
    if (dt <= 0 || dt > maxGap) return;
    timeIn += dt;
    final from = playedFrom;
    playedFrom = from == null ? prev.pos : math.min(from, prev.pos);
  }

  /// The rule, for an item [runtime] seconds long whose ending starts at
  /// [endingStart] (an Outro segment or ED chapter; null = the real end):
  /// - played before: [WatchOutcome.keepPlayed];
  /// - [credited] time In >= 70 % of the runtime, or the ending was
  ///   reached ([furthest]) with it >= 40 %: [WatchOutcome.played]. The
  ///   ending is the earlier of [endingStart] and the last 15 % (at most
  ///   4 min): someone who watched that far and stops is done with it.
  ///   Any watch Jellyfin's own rule counts (a position past 90 %, reached
  ///   by playing) counts here too, also with the opening and ending
  ///   skipped;
  /// - [credited] under max(2 min, 5 %) (at most a quarter of a short
  ///   item): [WatchOutcome.peek];
  /// - else [WatchOutcome.partial] at [lastPosition].
  /// An unknown runtime (0) never makes it played.
  WatchVerdict verdict({required double runtime, double? endingStart}) {
    if (playedBefore) return const WatchVerdict(WatchOutcome.keepPlayed);
    final t = credited;
    if (runtime > 0) {
      final tail = runtime - math.min(240.0, 0.15 * runtime);
      final end = endingStart != null && endingStart > 0 && endingStart < tail ? endingStart : tail;
      if (t >= 0.7 * runtime || (furthest >= end && t >= 0.4 * runtime)) {
        return const WatchVerdict(WatchOutcome.played);
      }
    }
    final peekBelow = runtime > 0 ? math.min(math.max(120.0, 0.05 * runtime), 0.25 * runtime) : 120.0;
    if (t < peekBelow) return const WatchVerdict(WatchOutcome.peek);
    return WatchVerdict(WatchOutcome.partial, resumeAt: lastPosition ?? 0);
  }
}
