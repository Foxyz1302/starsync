import 'package:sync_relay_core/core.dart';

// The app's reading of presence (PROTOCOL.md "Presence"): every count,
// list and wait in the UI goes through these, on top of core's
// [PresencePolicy] and [isAlone].

/// What each standing counts for (the one table, shared with the server).
const presencePolicy = PresencePolicy();

/// Watching with the group: connected, not out (AFK or Out) and its
/// player can open the media. Whose buffer the members card shows.
bool watchingNow(MemberView m) => !m.gone && !m.isOut && m.error.isEmpty;

/// Connected and not out (`in` or `brb`): can do things for the party now
/// (put up an Up next item; core's [isPresentMember]).
bool isPresent(MemberView m) => isPresentMember(m);

/// Nobody but [selfId] is connected in [members] (D9, core's [isAlone]).
bool aloneIn(List<MemberView> members, String selfId) =>
    isAlone([for (final m in members) if (m.id != selfId) m.gone]);

/// "3 min" / "40 s": how long since [since] (a `goneSince`), at [now].
String sinceText(DateTime since, DateTime now) {
  final d = now.difference(since);
  if (d.inMinutes >= 1) return '${d.inMinutes} min';
  return '${d.inSeconds.clamp(0, 59)} s';
}
