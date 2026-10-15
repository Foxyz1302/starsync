import 'package:sync_relay_core/core.dart';

import '../jellyfin/session_media.dart' show compareMemberIds;
import '../session/party.dart' show isPresent;

// Who puts an Up next item up. Pure: only what every client sees in
// `state` decides, so all clients agree without a wire message (like the
// Jellyfin auto-advance swapper).

/// Who puts [item] up: [id] a member id; null with [why] when nobody here
/// can (the item is skipped), null without [why] when nobody is around
/// right now (nothing happens).
typedef QueuePerformer = ({String? id, String? why});

/// - A link passed on by its adder, or the adder's file: only the adder
///   (their app has the file, the cookies). Gone (disconnected, in its
///   grace): it waits for them; left for good: skipped.
/// - Jellyfin: the adder when it plays that server with its own account,
///   else the lowest member id that does (`jf[serverId] == true`,
///   present: `in` or joining). Nobody: skipped.
/// - A link everyone opens, or one the server fetches: the adder when
///   present, else the lowest present member id.
QueuePerformer queuePerformer(QueueItem item, List<MemberView> members) {
  MemberView? adder;
  for (final m in members) {
    if (m.id == item.by) adder = m;
  }
  bool active(MemberView m) => isPresent(m);
  if (item.how.adderOnly) {
    if (adder == null) return (id: null, why: '${_name(item)} left');
    if (adder.presence == Presence.gone) return (id: null, why: null);
    return (id: adder.id, why: null);
  }
  final ref = item.media.jellyfin;
  if (item.how == QueueHow.jellyfin && ref != null) {
    bool can(MemberView m) => active(m) && m.jf[ref.serverId] == true;
    if (adder != null && can(adder)) return (id: adder.id, why: null);
    final id = autoAdvanceLowest(members.where(can));
    return id == null ? (id: null, why: 'nobody here has that Jellyfin server') : (id: id, why: null);
  }
  if (adder != null && active(adder)) return (id: adder.id, why: null);
  return (id: autoAdvanceLowest(members.where(active)), why: null);
}

String _name(QueueItem item) => item.byName.isEmpty ? 'who added it' : item.byName;

/// The lowest member id of [members] ("m2" before "m10"), or null.
String? autoAdvanceLowest(Iterable<MemberView> members) {
  final ids = [for (final m in members) m.id]..sort(compareMemberIds);
  return ids.isEmpty ? null : ids.first;
}

/// Who takes an item nobody can put up off the queue (`remove` with why):
/// the lowest member id that is connected (not gone).
String? queueJanitor(List<MemberView> members) =>
    autoAdvanceLowest(members.where((m) => m.presence != Presence.gone));

/// How [item] plays, in a few words for its row: "through Foxyz" (you:
/// "through you"), "server fetches", "everyone fetches", "Jellyfin",
/// "Foxyz's file".
String queueHowLabel(QueueItem item, {required String selfId}) {
  final mine = item.by == selfId && selfId.isNotEmpty;
  final who = mine ? 'you' : _name(item);
  return switch (item.how) {
    QueueHow.through => 'through $who',
    QueueHow.file => mine ? 'your file' : "$who's file",
    QueueHow.server => 'server fetches',
    QueueHow.direct => 'everyone fetches',
    QueueHow.jellyfin => 'Jellyfin',
  };
}

/// "1:23:45" / "23:45" for [secs]; empty when unknown.
String queueClock(double secs) {
  if (secs <= 0) return '';
  final s = secs.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(r)}' : '$m:${two(r)}';
}
