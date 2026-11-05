// Presence (PROTOCOL.md "Presence"): where a member stands, and one table
// of what each standing counts for. Pure, so the server's engine and the
// app read the same rules.

/// A member's standing, `members[].presence` on the wire ([wire]). One
/// each; Loading (`members[].loading`) and Reconnecting
/// (`members[].goneSince`) are only labels on top of it.
enum Presence {
  /// Watching. The group waits only for their video. Wire `in` (a Dart
  /// keyword, hence the name).
  watching,

  /// Be right back, set on purpose: the group waits until they are back
  /// or someone continues without them. Never runs out; kept across a
  /// drop, an app restart (the app reports it again) and new media.
  brb,

  /// Out, set automatically (no input for a while with nothing playing).
  /// Counts exactly like [out]; only the badge differs.
  afk,

  /// Out: not waited for, not counted as watched; the player stays at
  /// its spot. Never stops a member passing the video on.
  out;

  String get wire => this == watching ? 'in' : name;

  /// Not watching and not waited for ([afk] or [out]).
  bool get isOut => this == afk || this == out;

  /// Null for anything else.
  static Presence? parse(Object? v) {
    if (v == 'in') return watching;
    for (final p in values) {
      if (p != watching && p.name == v) return p;
    }
    return null;
  }
}

/// Why a member went [Presence.out] (`presence.reason`, the feed line's
/// `reason`): by hand, its window minimised while it played, its player
/// closed, or left out by someone continuing without it.
enum PresenceReason {
  manual,
  minimised,
  closed,
  continued;

  /// The wire name (`continue` for [continued], a Dart keyword).
  String get wire => this == continued ? 'continue' : name;

  static PresenceReason parse(Object? v) {
    if (v == 'continue') return continued;
    for (final r in values) {
      if (r.name == v) return r;
    }
    return manual;
  }
}

/// What a standing is asked about ([PresencePolicy.countsFor]).
enum Purpose {
  /// Watched tracking (Jellyfin played, history): who is watching.
  tracking,

  /// Getting Up next ready (warm relay readers, preloads).
  preload,

  /// Social notifications (joins, queue adds, chat pop-ups) in full.
  notifySocial,
}

/// The one table of what a standing counts for (who the group waits for
/// is the gate's own rule, `SyncEngine.waitsFor`):
///
/// | purpose        | in  | brb | afk | out | gone (any) |
/// |----------------|-----|-----|-----|-----|------------|
/// | tracking       | yes | yes | no  | no  | no         |
/// | preload        | yes | yes | no  | no  | no         |
/// | notifySocial   | yes | yes | no  | no  | no         |
///
/// A member still loading (`loading`) counts like `in` for preload and
/// notifications, not for tracking.
class PresencePolicy {
  const PresencePolicy();

  /// Whether a member with [presence] counts for [purpose]; [gone]: it is
  /// disconnected (in its grace), [loading]: its player is not with the
  /// group yet.
  bool countsFor(Presence presence, Purpose purpose, {bool gone = false, bool loading = false}) {
    if (gone || presence.isOut) return false;
    return switch (purpose) {
      Purpose.tracking => !loading,
      Purpose.preload || Purpose.notifySocial => true,
    };
  }
}

/// D9 "alone": no other member is connected. [othersGone] says, for
/// everyone but oneself, whether they are disconnected; anyone connected
/// (whatever their standing) is company.
bool isAlone(Iterable<bool> othersGone) => othersGone.every((g) => g);
