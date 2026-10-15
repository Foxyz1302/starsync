import 'package:sync_relay_core/core.dart';

import 'app_events.dart';
import 'connection.dart';
import 'delivery.dart';
import 'now_playing_info.dart';
import 'party.dart';

// The session's one computed status: what the player's status pill, the
// party strip's server line and the members card's source line say, from
// facts only (the connection, the server's state with its hold reason and
// relay, this player's open/error facts). Nothing writes a status; the
// coordinator computes it ([statusOf]) and [StatusWatch] turns the
// transitions worth a notice into [AppEvent]s for the Notifier (Status →
// Notifier, never back).

/// How bad it is: [ok] and [info] never colour anything, [warn] amber,
/// [error] red.
enum StatusLevel { ok, info, warn, error }

/// What the player's status pill says, most pressing first.
enum StatusKind { reconnecting, problem, connecting, fetching, finished, loading, you, cannotPlay, waiting }

/// The pill's button: stop reconnecting, retry (reconnect), reload the
/// video (your player could not open it), or mark yourself ready (the
/// whole pill).
enum StatusAction { cancel, retry, reload, ready }

/// One status line: [text], a muted [detail], its [level], the members it
/// is about ([who]; [self] for you) and a loading [progress] (0..1).
class StatusLine {
  final StatusKind kind;
  final String text;
  final String? detail;
  final StatusLevel level;
  final List<MemberView> who;
  final bool self;
  final double? progress;
  final StatusAction? action;
  /// The mini player's shorter line.
  final String short;
  const StatusLine(
    this.kind,
    this.text, {
    this.detail,
    this.level = StatusLevel.info,
    this.who = const [],
    this.self = false,
    this.progress,
    this.action,
    String? short,
  }) : short = short ?? text;

  /// Coloured: a problem.
  bool get problem => level == StatusLevel.warn || level == StatusLevel.error;
}

/// The facts a status is computed from.
class StatusFacts {
  final ConnState conn;
  /// The server's latest state (kept through a drop).
  final StateBroadcast? state;
  /// This member's id ('' before the welcome).
  final String selfId;
  /// Why this player cannot open the current media ([playErrorText]).
  final String playerError;
  /// The player itself failed (a reload that failed); '' when fine.
  final String playerFault;
  /// This viewer plays the current Jellyfin item with its own account:
  /// the relay's troubles are not its own.
  final bool ownPlan;
  /// The mediaId the server said it could not fetch (`fetch-fail`), -1.
  final int fetchFailedFor;
  /// Names of members that left (a relay source that left).
  final MemberNames? names;
  /// A reconnect found the server restarted this many times.
  final int restarts;
  final DateTime now;
  const StatusFacts({
    this.conn = const ConnClosed(),
    this.state,
    this.selfId = '',
    this.playerError = '',
    this.playerFault = '',
    this.ownPlan = false,
    this.fetchFailedFor = -1,
    this.names,
    this.restarts = 0,
    required this.now,
  });
}

/// The relay source's trouble, as the transitions watch it.
class SourceTrouble {
  final int mediaId;
  final String sourceId;
  final String name;
  /// Gone since (the source member is `gone`); null when it left.
  final DateTime? since;
  bool get left => since == null;
  const SourceTrouble({required this.mediaId, required this.sourceId, required this.name, this.since});
}

class Status {
  /// The player's pill; null when there is nothing to say (playing,
  /// connected, everyone ready).
  final StatusLine? line;
  /// The party strip's line under the server name: "connecting…",
  /// "reconnecting…", "ready 2/3".
  final String party;
  /// Where the current media comes from (the members card's source line);
  /// null with nothing up or nobody else there.
  final Delivery? delivery;
  /// The relay source this viewer depends on is gone or left.
  final SourceTrouble? source;
  final ConnState conn;
  final StateBroadcast? state;
  final int restarts;
  const Status({
    this.line,
    this.party = '',
    this.delivery,
    this.source,
    this.conn = const ConnClosed(),
    this.state,
    this.restarts = 0,
  });
}

/// "Bob", "Bob and Mika", "Bob, Mika and Cleo", "Bob, Mika and 3 others".
String nameList(List<String> names) {
  if (names.length <= 1) return names.join();
  if (names.length <= 3) return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return '${names[0]}, ${names[1]} and ${names.length - 2} others';
}

String _sentence(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// "(2 min)" from a minute on, nothing before.
String _forHow(DateTime since, DateTime now) =>
    now.difference(since).inMinutes >= 1 ? ' (${sinceText(since, now)})' : '';

/// "Bob's connection dropped — playing what the server has (2 min)",
/// "Bob left — playing what the server has".
String sourceTroubleText(SourceTrouble t, DateTime now) => t.left
    ? '${t.name} left — playing what the server has'
    : "${t.name}'s connection dropped — playing what the server has${_forHow(t.since!, now)}";

/// The relayed media's source this viewer reads from is gone or left.
SourceTrouble? sourceTroubleOf(StateBroadcast r, String selfId, MemberNames? names) {
  final relay = stateMediaRelay(r);
  if (relay == null || relay.fetch || relay.source.isEmpty || relay.source == selfId) return null;
  final m = r.members.where((m) => m.id == relay.source).firstOrNull;
  final name = m?.name ?? names?[relay.source] ?? 'The member passing it on';
  if (m == null) return SourceTrouble(mediaId: r.mediaId, sourceId: relay.source, name: name);
  if (!relay.sourceGone && m.presence != Presence.gone) return null;
  return SourceTrouble(
      mediaId: r.mediaId,
      sourceId: relay.source,
      name: name,
      since: relay.sourceGoneSince ?? m.goneSince ?? r.serverTime);
}

/// The status from [f].
Status statusOf(StatusFacts f) {
  final r = f.state;
  final stale = r != null && (f.conn.retrying || f.conn is ConnReplaced || f.conn is ConnRefused);
  final counted = (r?.members ?? const <MemberView>[]).where(countsForReady).toList();
  final party = r == null
      ? 'connecting…'
      : stale
          ? 'reconnecting…'
          : 'ready ${counted.where((m) => m.ready).length}/${counted.length}';
  final self = r == null || f.selfId.isEmpty ? null : r.members.where((m) => m.id == f.selfId).firstOrNull;
  final source = r == null || f.ownPlan ? null : sourceTroubleOf(r, f.selfId, f.names);
  return Status(
    line: _line(f, r, self, source),
    party: party,
    delivery: r == null ? null : deliveryOf(r, selfId: f.selfId, names: f.names, now: f.now),
    source: source,
    conn: f.conn,
    state: r,
    restarts: f.restarts,
  );
}

StatusLine? _line(StatusFacts f, StateBroadcast? r, MemberView? self, SourceTrouble? source) {
  switch (f.conn) {
    case ConnLost() || ConnReconnecting():
      return const StatusLine(StatusKind.reconnecting, 'Reconnecting…',
          level: StatusLevel.warn, action: StatusAction.cancel);
    case ConnUnstable():
      return const StatusLine(StatusKind.reconnecting, 'Connection unstable…', level: StatusLevel.warn);
    case ConnReplaced(:final message) || ConnRefused(:final message):
      return StatusLine(StatusKind.problem, _sentence(message), level: StatusLevel.error, action: StatusAction.retry);
    case ConnConnecting():
      return const StatusLine(StatusKind.connecting, 'Connecting…');
    case ConnOnline() || ConnClosed():
      break;
  }
  final away = self?.presence == Presence.away;
  if (r == null || r.media == null) return null;
  // Sitting out: the join-back card says it; nobody waits for you.
  if (away) return null;
  if (f.playerFault.isNotEmpty) {
    return StatusLine(StatusKind.problem, _sentence(f.playerFault),
        level: StatusLevel.error, action: StatusAction.reload, short: "Can't play this");
  }
  if (f.playerError.isNotEmpty) {
    return StatusLine(StatusKind.problem, "Can't play this: ${f.playerError}",
        level: StatusLevel.error, action: StatusAction.reload, short: "Can't play this");
  }
  // The relay: what everyone reads comes through the server.
  final relay = f.ownPlan ? null : stateMediaRelay(r);
  if (relay != null && relay.source != f.selfId) {
    if (relay.fetch && !relay.live) {
      if (f.fetchFailedFor == r.mediaId) {
        return const StatusLine(StatusKind.problem, "The server couldn't fetch this video", level: StatusLevel.error);
      }
      return const StatusLine(StatusKind.fetching, 'The server is getting the video…');
    }
    if (source != null) {
      return StatusLine(StatusKind.problem, sourceTroubleText(source, f.now),
          level: StatusLevel.warn,
          short: source.left ? '${source.name} left' : "${source.name}'s connection dropped");
    }
    if (!relay.fetch && !relay.live) {
      final who = r.members.where((m) => m.id == relay.source).firstOrNull?.name ?? 'the member who put it up';
      return StatusLine(StatusKind.problem, 'Waiting for $who to pass the video on', level: StatusLevel.warn);
    }
  }
  if (r.transport == 'playing') return null;
  if (r.transport == 'finished') {
    return const StatusLine(StatusKind.finished, 'Finished · seek back or pick the next video', short: 'Finished');
  }
  // Members whose player cannot open it: the server does not wait for
  // them; say why instead of "waiting for".
  final failed = [
    for (final m in r.members)
      if (m.error.isNotEmpty && isPresent(m) && (self == null || m.id != self.id)) m,
  ];
  // As the server holds playback: someone in the ready set short of the
  // minimum buffer.
  final need = r.bufferNeed;
  for (final m in r.members) {
    if (m.inSet && m.buffered < need) {
      final you = self != null && m.id == self.id;
      final p = (m.buffered / need).clamp(0.0, 1.0);
      return StatusLine(StatusKind.loading, you ? 'Loading the video…' : '${m.name} is loading…',
          who: [m], self: you, progress: p, detail: '${(p * 100).round()}%');
    }
  }
  if (failed.isNotEmpty) {
    final first = failed.first;
    final who = nameList([for (final m in failed) m.name]);
    final unready = self != null && !self.ready;
    return StatusLine(StatusKind.cannotPlay, "$who can't play this: ${first.error}",
        who: failed,
        short: "$who can't play this",
        detail: unready ? "Press Space when you're ready" : null,
        action: unready ? StatusAction.ready : null);
  }
  if (self != null && !self.ready) {
    return StatusLine(StatusKind.you, "Press Space when you're ready",
        who: [self], self: true, action: StatusAction.ready, detail: 'or click here', short: 'Press Space when ready');
  }
  // Members sitting out or gone are never waited for nor counted.
  final active = [for (final m in r.members) if (countsForReady(m)) m];
  final others = [
    for (final m in active)
      if ((self == null || m.id != self.id) && !(m.inSet && m.ready)) m,
  ];
  if (others.isEmpty) return null;
  final ready = active.where((m) => m.ready).length;
  return StatusLine(StatusKind.waiting, 'Waiting for ${nameList([for (final m in others) m.name])}',
      who: others, detail: '$ready/${active.length} ready');
}

/// How long the relay's source must be gone before it is worth a notice
/// (a quick reconnect says nothing).
const sourceDropNotice = Duration(seconds: 5);

/// Turns status transitions worth a notice into events: the source this
/// viewer reads from gone for [sourceDropNotice] (or left), another window
/// took over, the server restarted, the media starting for the first time.
/// Idempotent: [step] may run on every status change and every second.
class StatusWatch {
  final _dropped = <String>{};
  final _seenHeld = <int>{};
  final _started = <int>{};
  bool _replaced = false;
  int _restarts = 0;
  bool _first = true;

  List<AppEvent> step(Status s, DateTime now) {
    final out = <AppEvent>[];
    final src = s.source;
    if (src != null) {
      final key = '${src.mediaId}/${src.sourceId}/${src.left ? 'left' : src.since!.toIso8601String()}';
      final due = src.left || now.difference(src.since!) >= sourceDropNotice;
      // Once per drop, and once when it left.
      if (due && _dropped.add(key)) out.add(RelaySourceDropped(src.name, left: src.left));
    }
    final replaced = s.conn is ConnReplaced;
    if (replaced && !_replaced) out.add(const Replaced());
    _replaced = replaced;
    if (!_first && s.restarts > _restarts) out.add(const ServerRestarted());
    _restarts = s.restarts;
    _first = false;
    final r = s.state;
    if (r != null && r.media != null) {
      if (r.transport == 'held') _seenHeld.add(r.mediaId);
      if (r.transport == 'playing' && _seenHeld.contains(r.mediaId) && _started.add(r.mediaId)) {
        final now = nowPlayingOf(r.media);
        out.add(PlaybackStarted([?now?.title, ?now?.episode].join(' · ')));
      }
    }
    return out;
  }

  /// A new session.
  void reset() {
    _dropped.clear();
    _seenHeld.clear();
    _started.clear();
    _replaced = false;
    _restarts = 0;
    _first = true;
  }
}
