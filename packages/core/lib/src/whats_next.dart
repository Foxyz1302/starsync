import 'protocol.dart';
import 'queue.dart';

// What's next, the rules every side reads the same way (PROTOCOL.md
// "Queue", ARCHITECTURE.md "What's next"): who puts an Up next item up.
// Pure and only on what `state` carries, so the server (which holds the
// countdown and skips what nobody can play) and every app agree without
// a wire message.

/// Who puts an Up next item up: [id] a member id; null with [why] when
/// nobody here can (the server skips the item), null without [why] when
/// nobody is around right now (it waits).
typedef QueuePerformer = ({String? id, String? why});

/// Connected and not out (`in` or `brb`, loading or not): can do things
/// for the party now (put an Up next item up).
bool isPresentMember(MemberView m) => !m.gone && !m.isOut;

/// - A link passed on by its adder, or the adder's file: only the adder
///   (their app has the file, the cookies). Gone (disconnected, in its
///   grace): it waits for them; left for good: skipped.
/// - Jellyfin: the adder when it plays that server with its own account,
///   else the lowest member id that does (`jf[serverId] == true`,
///   present). Nobody: skipped.
/// - A link everyone opens, or one the server fetches: the adder when
///   present, else the lowest present member id; nobody present: it waits.
/// [pass]: members passed over for this play request (`state.queuePass`:
/// they did not put it up in time); they count as unable, unless the item
/// is theirs alone.
QueuePerformer queuePerformer(QueueItem item, List<MemberView> members, {List<String> pass = const []}) {
  MemberView? adder;
  for (final m in members) {
    if (m.id == item.by) adder = m;
  }
  if (item.how.adderOnly) {
    if (adder == null) return (id: null, why: '${item.byName.isEmpty ? 'who added it' : item.byName} left');
    if (adder.gone) return (id: null, why: null);
    return (id: adder.id, why: null);
  }
  bool present(MemberView m) => isPresentMember(m) && !pass.contains(m.id);
  final ref = item.media.jellyfin;
  if (item.how == QueueHow.jellyfin && ref != null) {
    bool can(MemberView m) => present(m) && m.jf[ref.serverId] == true;
    if (adder != null && can(adder)) return (id: adder.id, why: null);
    final id = lowestMemberId(members.where(can));
    return id == null ? (id: null, why: 'nobody here has that Jellyfin server') : (id: id, why: null);
  }
  if (adder != null && present(adder)) return (id: adder.id, why: null);
  return (id: lowestMemberId(members.where(present)), why: null);
}

/// The lowest member id of [members] ("m2" before "m10"), or null.
String? lowestMemberId(Iterable<MemberView> members) {
  final ids = [for (final m in members) m.id]..sort(compareMemberIds);
  return ids.isEmpty ? null : ids.first;
}

/// "m2" before "m10": numeric suffix order, then plain text.
int compareMemberIds(String a, String b) {
  final na = int.tryParse(a.replaceFirst(RegExp(r'^\D+'), ''));
  final nb = int.tryParse(b.replaceFirst(RegExp(r'^\D+'), ''));
  if (na != null && nb != null && na != nb) return na.compareTo(nb);
  return a.compareTo(b);
}

/// Who may add the continuation ([QueueItem.auto]) of the current media:
/// who put it up ([swapBy], a member id), or, when that member is not
/// present ([isPresentMember]), the first member (in [members] order, the
/// join order) who is.
bool mayAddContinuation(String memberId, String? swapBy, List<MemberView> members) {
  if (memberId.isEmpty) return false;
  if (memberId == swapBy) return true;
  final swapper = members.where((m) => m.id == swapBy).firstOrNull;
  if (swapper != null && isPresentMember(swapper)) return false;
  return members.where(isPresentMember).firstOrNull?.id == memberId;
}

/// Whole seconds left of [advance] at [now] (server clock), at least 0.
int advanceSecondsLeft(QueueAdvance advance, DateTime now) {
  final end = advance.at.add(Duration(seconds: advance.secs));
  final ms = end.difference(now).inMilliseconds;
  return ms <= 0 ? 0 : (ms / 1000).ceil();
}
