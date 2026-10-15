import 'package:sync_relay_core/core.dart';

// The app's reading of presence (PROTOCOL.md "Presence"): every count,
// list and wait in the UI goes through these, on top of core's
// [PresencePolicy] and [isAlone].

/// What each presence counts for (the one table, shared with the server).
const presencePolicy = PresencePolicy();

/// Counted in "2/3 ready" and waited for by name: its presence counts for
/// the ready counter and its player can open the media.
bool countsForReady(MemberView m) => m.error.isEmpty && presencePolicy.countsFor(m.presence, Purpose.readyCounter);

/// Connected and watching (`in` or `joining`): can do things for the
/// party now (put up an Up next item, the auto-advance swap).
bool isPresent(MemberView m) => m.presence == Presence.watching || m.presence == Presence.joining;

/// Nobody but [selfId] is connected in [members] (D9, core's [isAlone]).
bool aloneIn(List<MemberView> members, String selfId) =>
    isAlone([for (final m in members) if (m.id != selfId) m.presence]);

/// "3 min" / "40 s": how long since [since] (a `goneSince`), at [now].
String sinceText(DateTime since, DateTime now) {
  final d = now.difference(since);
  if (d.inMinutes >= 1) return '${d.inMinutes} min';
  return '${d.inSeconds.clamp(0, 59)} s';
}
