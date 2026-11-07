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

/// What the player's status pill says, most pressing first. [you]: you
/// are BRB (the group waits for you); [out] / [afk]: you are out;
/// [waiting]: the group waits for someone's BRB or video; [paused]: a
/// plain pause (with everyone else there and their standing).
enum StatusKind {
  reconnecting,
  problem,
  connecting,
  fetching,
  out,
  afk,
  finished,
  loading,
  you,
  cannotPlay,
  waiting,
  paused,
}

/// The pill's button: stop reconnecting, retry (reconnect), reload the
/// video (your player could not open it); or the whole pill: join (you
/// are out), back (you are BRB or AFK).
enum StatusAction { cancel, retry, reload, join, back }

/// A key and what it does now, for the pill's hint line (`[Space] BRB
/// too`).
typedef KeyHint = (String key, String action);

/// One status line: [text], a muted [detail] or the [keys] that act now,
/// its [level], the members it is about ([who]; [self] for you) and a
/// loading [progress] (0..1).
class StatusLine {
  final StatusKind kind;
  final String text;
  final String? detail;
  final StatusLevel level;
  final List<MemberView> who;
  final bool self;
  final double? progress;
  final StatusAction? action;
  final List<KeyHint> keys;
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
    this.keys = const [],
    String? short,
  }) : short = short ?? text;

  /// The whole pill acts ([StatusAction.join] / [StatusAction.back]).
  bool get tappable => action == StatusAction.join || action == StatusAction.back;

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
  /// Who paused, for a plain pause ("Paused by Bob"): the member id of the
  /// last `pause` line; null when unknown.
  final String? pausedBy;
  /// This member paused the live stream (only here).
  final bool livePaused;
  final DateTime now;
  const StatusFacts({
    this.livePaused = false,
    this.conn = const ConnClosed(),
    this.state,
    this.selfId = '',
    this.playerError = '',
    this.playerFault = '',
    this.ownPlan = false,
    this.fetchFailedFor = -1,
    this.names,
    this.restarts = 0,
    this.pausedBy,
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
  /// "reconnecting…", "3 watching · 1 BRB".
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

/// "Bob", "Bob and Mika", "Bob, Mika and Cleo", "Bob, Mika and 3 more".
String nameList(List<String> names) {
  if (names.length <= 1) return names.join();
  if (names.length <= 3) return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return '${names[0]}, ${names[1]} and ${names.length - 2} more';
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
  if (!relay.sourceGone && !m.gone) return null;
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
  final party = r == null
      ? 'connecting…'
      : stale
          ? 'reconnecting…'
          : partyLine(r.members);
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

/// "3 watching · 1 BRB · 1 out": who is connected, by standing.
String partyLine(List<MemberView> members) {
  final here = [for (final m in members) if (!m.gone) m];
  final watching = here.where((m) => m.presence == Presence.watching).length;
  final brb = here.where((m) => m.brb).length;
  final out = here.where((m) => m.isOut).length;
  return [
    '$watching watching',
    if (brb > 0) '$brb BRB',
    if (out > 0) '$out out',
  ].join(' · ');
}

/// Everyone else connected, watching first, then BRB, AFK and out (the
/// paused pill shows them with their standing before someone plays).
List<MemberView> whoIsIn(List<MemberView> members, String selfId) => [
      for (final p in const [Presence.watching, Presence.brb, Presence.afk, Presence.out])
        for (final m in members)
          if (m.presence == p && !m.gone && m.id != selfId) m,
    ];

/// The keys while someone else is BRB.
const _brbKeys = <KeyHint>[('Space', 'BRB too'), ('Hold Space', 'continue without')];

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
  if (r == null || r.media == null) return null;
  // Out: nobody waits for you, your player stays at your spot.
  if (self != null && self.presence == Presence.out) {
    return const StatusLine(StatusKind.out, "You're out",
        keys: [('Space', 'Join')], action: StatusAction.join, who: [], short: "You're out · Space: Join");
  }
  if (self != null && self.presence == Presence.afk) {
    return const StatusLine(StatusKind.afk, "You're AFK",
        keys: [('Any key', 'back')], action: StatusAction.back, short: "You're AFK");
  }
  if (f.playerFault.isNotEmpty) {
    return StatusLine(StatusKind.problem, _sentence(f.playerFault),
        level: StatusLevel.error, action: StatusAction.reload, short: "Can't play this");
  }
  if (f.playerError.isNotEmpty) {
    return StatusLine(StatusKind.problem, "Can't play this: ${f.playerError}",
        level: StatusLevel.error, action: StatusAction.reload, short: "Can't play this");
  }
  // Live: nobody waits for anyone; only a pause here is worth a line.
  if (r.media?['live'] == true && r.transport != 'finished') {
    return f.livePaused
        ? const StatusLine(StatusKind.paused, 'Paused here only',
            detail: 'The stream goes on for everyone', keys: [('Space', 'back to live')], short: 'Paused here only')
        : null;
  }
  // The server holds everyone for the relay's source (D6): a viewer's
  // buffer ran dry while it is gone.
  if (r.transport == 'held' && (r.hold?.source ?? false)) {
    final relayed = stateMediaRelay(r);
    final id = relayed?.source ?? '';
    final name = source?.name ??
        r.members.where((m) => m.id == id).firstOrNull?.name ??
        f.names?[id] ??
        'the member passing it on';
    return StatusLine(StatusKind.waiting, 'Waiting for $name',
        detail: "$name's connection dropped; what the server had has played",
        level: StatusLevel.warn,
        short: 'Waiting for $name');
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
  MemberView? byId(String id) => r.members.where((m) => m.id == id).firstOrNull;
  final hold = r.hold;
  final wants = r.wantsPlay;
  // BRB: the group waits until they are back ("Waiting for Bob"), or it
  // stays paused then ("Paused · waiting for Bob").
  final brb = [for (final id in hold?.brb ?? const <String>[]) ?byId(id)];
  if (brb.isNotEmpty) {
    final selfBrb = self != null && brb.any((m) => m.id == self.id);
    final others = [for (final m in brb) if (self == null || m.id != self.id) m];
    final names = nameList([if (selfBrb) 'you', for (final m in others) m.name]);
    final text = wants ? 'Waiting for $names' : 'Paused · waiting for $names';
    if (selfBrb) {
      return StatusLine(StatusKind.you, text,
          who: [self, ...others],
          self: true,
          keys: [("Space", "I'm back"), if (others.isNotEmpty) ('Hold Space', 'continue without')],
          action: StatusAction.back,
          short: wants ? 'Waiting for you' : 'Paused · BRB');
    }
    return StatusLine(StatusKind.waiting, text, who: others, keys: _brbKeys, short: text);
  }
  // Members whose player cannot open it: nobody waits for them; say why
  // instead of "waiting for".
  final failed = [
    for (final m in r.members)
      if (m.error.isNotEmpty && isPresent(m) && (self == null || m.id != self.id)) m,
  ];
  // The group wants to play and waits for a video: loading or running dry.
  final need = r.bufferNeed;
  final video = [for (final id in hold?.video ?? const <String>[]) ?byId(id)];
  if (wants && video.isNotEmpty) {
    final you = self != null && video.any((m) => m.id == self.id);
    final first = you ? self : video.first;
    final p = need <= 0 ? 1.0 : (first.buffered / need).clamp(0.0, 1.0);
    if (you) {
      return StatusLine(StatusKind.loading, 'Loading the video…',
          who: [self], self: true, progress: p, detail: '${(p * 100).round()}%');
    }
    final names = nameList([for (final m in video) m.name]);
    return StatusLine(StatusKind.waiting, 'Waiting for $names',
        who: video, progress: video.length == 1 ? p : null, detail: video.length == 1 ? 'Loading · ${(p * 100).round()}%' : 'Loading', short: 'Waiting for $names');
  }
  if (failed.isNotEmpty) {
    final first = failed.first;
    final who = nameList([for (final m in failed) m.name]);
    return StatusLine(StatusKind.cannotPlay, "$who can't play this: ${first.error}",
        who: failed, short: "$who can't play this");
  }
  if (!wants) {
    final by = f.pausedBy;
    final name = by == null
        ? null
        : by == f.selfId
            ? 'you'
            : byId(by)?.name ?? f.names?[by];
    return StatusLine(StatusKind.paused, name == null ? 'Paused' : 'Paused by $name',
        who: whoIsIn(r.members, f.selfId), short: 'Paused');
  }
  return null;
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
