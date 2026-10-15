import 'constants.dart';

// Presence (D1, PROTOCOL.md "Presence"): where a member stands, and one
// table of what each standing counts for. Pure, so the server's engine and
// the app read the same rules.

/// A member's presence, `members[].presence` on the wire ([wire]).
enum Presence {
  /// New, back from `gone`, or back from `away`: loading the current media
  /// in the background until its reports hold it with `bufferNeed`, then
  /// [watching]. Wire `joining`.
  joining,

  /// Watching, in full (D1 "In"). Wire `in` (a Dart keyword, hence the name).
  watching,

  /// Sat out (by itself or by someone else): still in the server (chat,
  /// feed, chosen notifications), never counted for the gate, the ready
  /// counter or watched tracking. Wire `away`.
  away,

  /// Disconnected and kept for the grace period (`welcome.grace`) with
  /// everything it had (ready flag, queue items, relay, picture). Wire
  /// `gone`.
  gone;

  String get wire => this == watching ? 'in' : name;

  /// Null for anything else.
  static Presence? parse(Object? v) {
    if (v == 'in') return watching;
    for (final p in values) {
      if (p != watching && p.name == v) return p;
    }
    return null;
  }
}

/// Why a member set itself (or someone) `away` or `in`
/// (`presence.reason`): by hand, idle, its window minimised, or the app
/// closing (`bye`, reserved for the app's own record).
enum PresenceReason {
  manual,
  idle,
  minimised,
  bye;

  static PresenceReason parse(Object? v) {
    for (final r in values) {
      if (r.name == v) return r;
    }
    return manual;
  }
}

/// What a presence is asked about ([PresencePolicy.countsFor]).
enum Purpose {
  /// The ready gate: who the server waits for before it plays.
  gate,

  /// "2/3 ready": who the ready counter counts.
  readyCounter,

  /// Watched tracking (Jellyfin played, history): who is watching.
  tracking,

  /// Getting Up next ready (warm relay readers, preloads).
  preload,

  /// Social notifications (joins, queue adds, chat pop-ups) in full.
  notifySocial,
}

/// The one table of what a presence counts for (D1, D2):
///
/// | purpose        | joining | in  | away | gone |
/// |----------------|---------|-----|------|------|
/// | gate           | D2 *    | yes | no   | no   |
/// | readyCounter   | yes     | yes | no   | no   |
/// | tracking       | no      | yes | no   | no   |
/// | preload        | yes     | yes | no   | no   |
/// | notifySocial   | yes     | yes | no   | no   |
///
/// \* A `joining` member never holds a PLAYING gate (it loads in the
/// background and comes in already in sync); while HELD it holds at most
/// [joinerHold] from the moment it started joining, then the others go on
/// without it.
class PresencePolicy {
  /// How long a joiner may hold a HELD gate (D2).
  final Duration joinerHold;
  const PresencePolicy({this.joinerHold = const Duration(seconds: RelayConstants.joinerHoldSecs)});

  /// Whether a member with [presence] counts for [purpose]. For
  /// [Purpose.gate] a `joining` member needs the gate's context: [playing]
  /// (the transport is `playing`) and [joiningFor] (how long it has been
  /// joining, on the server's clock).
  bool countsFor(Presence presence, Purpose purpose,
      {bool playing = false, Duration joiningFor = Duration.zero}) {
    switch (presence) {
      case Presence.watching:
        return true;
      case Presence.away:
      case Presence.gone:
        return false;
      case Presence.joining:
        switch (purpose) {
          case Purpose.gate:
            return !playing && joiningFor < joinerHold;
          case Purpose.tracking:
            return false;
          case Purpose.readyCounter:
          case Purpose.preload:
          case Purpose.notifySocial:
            return true;
        }
    }
  }
}

/// D9 "alone": no other member is connected. [others] are the presences
/// of everyone but oneself; `in`, `joining` and `away` are company, `gone`
/// is not. Auto sit-out (never when alone) and the social notifications
/// read this one definition.
bool isAlone(Iterable<Presence> others) => others.every((p) => p == Presence.gone);
