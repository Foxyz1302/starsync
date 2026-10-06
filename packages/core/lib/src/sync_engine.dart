import 'constants.dart';
import 'protocol.dart';

typedef SyncClock = DateTime Function();

enum Transport { playing, held }

enum Correction { none, slowDown, seek }

Correction correctionFor({required double ownPosition, required double serverPosition}) {
  final drift = ownPosition - serverPosition;
  if (drift.abs() > RelayConstants.driftSeekThresholdSecs) return Correction.seek;
  if (drift > RelayConstants.slowDownThresholdSecs) return Correction.slowDown;
  return Correction.none;
}

class EngineMember {
  final String id;
  final String token;
  String name;
  String avatar;
  bool ready = false;
  bool inSet = false;
  double buffered = 0;
  DateTime lastSeen;
  EngineMember({
    required this.id,
    required this.token,
    required this.name,
    this.avatar = '',
    required DateTime now,
  }) : lastSeen = now;

  MemberView view({required bool stale}) => MemberView(
        id: id,
        name: name,
        avatar: avatar,
        ready: ready,
        inSet: inSet,
        buffered: buffered,
        stale: stale,
      );
}

class EngineFeed {
  final List<FeedMessage> pending = [];
  void add(FeedMessage message) => pending.add(message);
  List<FeedMessage> drain() {
    final out = List<FeedMessage>.from(pending);
    pending.clear();
    return out;
  }
}

class SyncEngine {
  final SyncClock clock;
  final Duration staleAfter;
  final Duration dropAfter;
  final EngineFeed feed = EngineFeed();
  final Map<String, EngineMember> members = {};

  int eventId = 0;
  Transport transport = Transport.held;
  double position = 0;
  DateTime serverTime;
  int mediaId = 1;
  HelloMedia? media;
  int _nextId = 1;

  SyncEngine({SyncClock? clock, Duration? staleAfter, Duration? dropAfter})
      : clock = clock ?? (() => DateTime.now().toUtc()),
        staleAfter = staleAfter ?? const Duration(seconds: 15),
        dropAfter = dropAfter ?? const Duration(seconds: 30),
        serverTime = (clock ?? (() => DateTime.now().toUtc()))();

  DateTime get now => clock();

  double positionAt([DateTime? at]) {
    final t = at ?? now;
    if (transport != Transport.playing) return position;
    return position + t.difference(serverTime).inMilliseconds / 1000.0;
  }

  bool isStale(EngineMember member, [DateTime? at]) =>
      (at ?? now).difference(member.lastSeen) > staleAfter;

  String applyJoin(String token, String name, String avatar) {
    final id = 'm${_nextId++}';
    members[token] =
        EngineMember(id: id, token: token, name: name, avatar: avatar, now: now);
    feed.add(FeedMessage(actor: name, action: 'join', at: now));
    return id;
  }

  String? applyLeave(String token) {
    final removed = members.remove(token);
    if (removed == null) return null;
    feed.add(FeedMessage(actor: removed.name, action: 'leave', at: now));
    evaluate();
    return removed.id;
  }

  EngineMember? byId(String id) {
    for (final member in members.values) {
      if (member.id == id) return member;
    }
    return null;
  }

  void applyReady(String token, bool ready, {String source = 'manual'}) {
    final member = members[token];
    if (member == null) return;
    member.lastSeen = now;
    if (member.ready == ready && member.inSet) {
      evaluate();
      return;
    }
    member.ready = ready;
    if (ready) member.inSet = true;
    feed.add(FeedMessage(
        actor: member.name,
        action: ready ? 'ready' : 'unready',
        reason: source,
        at: now));
    evaluate();
  }

  void applyForce(String actorToken, String target, bool ready) {
    final actor = members[actorToken];
    final actorName = actor?.name ?? '?';
    if (target == 'all') {
      for (final member in members.values) {
        member.ready = ready;
        if (ready) member.inSet = true;
      }
    } else {
      final member = byId(target);
      if (member == null) return;
      member.ready = ready;
      if (ready) member.inSet = true;
      feed.add(FeedMessage(
          actor: actorName,
          action: ready ? 'force-ready' : 'force-unready',
          target: member.name,
          at: now));
      evaluate();
      return;
    }
    feed.add(FeedMessage(
        actor: actorName,
        action: ready ? 'force-play' : 'force-hold',
        at: now));
    evaluate();
  }

  void applySeek(String token, double seekPosition) {
    final member = members[token];
    if (member == null) return;
    if (!seekPosition.isFinite || seekPosition < 0) return;
    member.lastSeen = now;
    position = seekPosition;
    serverTime = now;
    eventId++;
    feed.add(FeedMessage(actor: member.name, action: 'seek', at: now));
  }

  /// Returns false (no state change) for media with non-finite numbers.
  bool applySwap(String actorToken, HelloMedia next) {
    if (!next.duration.isFinite || next.size < 0) return false;
    final actor = members[actorToken];
    mediaId++;
    media = next;
    position = 0;
    serverTime = now;
    eventId++;
    transport = Transport.held;
    for (final member in members.values) {
      member.ready = false;
      member.inSet = false;
      member.buffered = 0;
    }
    feed.add(FeedMessage(actor: actor?.name ?? '?', action: 'swap', at: now));
    return true;
  }

  void applyReport(String token, double reportPosition, double buffered, int reportEventId) {
    final member = members[token];
    if (member == null) return;
    if (!reportPosition.isFinite) return;
    member.lastSeen = now;
    member.buffered = !buffered.isFinite || buffered < 0 ? 0 : buffered;
    if (reportEventId < eventId) return;
    evaluate();
  }

  void sweepStale() {
    var changed = false;
    for (final member in members.values) {
      if (isStale(member) && member.inSet) {
        member.inSet = false;
        changed = true;
        feed.add(FeedMessage(actor: member.name, action: 'stale', reason: 'no signal', at: now));
      }
    }
    if (changed) evaluate();
  }

  List<String> sweepDropped() {
    final t = now;
    final dropped = <String>[];
    for (final member in members.values.toList()) {
      if (t.difference(member.lastSeen) > dropAfter) {
        members.remove(member.token);
        dropped.add(member.token);
        feed.add(FeedMessage(actor: member.name, action: 'leave', reason: 'silent too long', at: t));
      }
    }
    if (dropped.isNotEmpty) evaluate();
    return dropped;
  }

  void evaluate() {
    final t = now;
    if (transport == Transport.playing) {
      final blocked = members.values
          .where((m) => m.inSet)
          .any((m) => !m.ready || m.buffered < RelayConstants.minBufferSecs || isStale(m, t));
      if (blocked) {
        position = positionAt(t);
        serverTime = t;
        eventId++;
        transport = Transport.held;
        feed.add(FeedMessage(actor: 'server', action: 'pause', at: t));
      }
      return;
    }
    final inSet = members.values.where((m) => m.inSet).toList();
    if (inSet.isEmpty) return;
    final freshCount =
        members.values.where((m) => !isStale(m, t)).length;
    final quorum = inSet.length >= 2 || freshCount <= 1;
    final allGood = inSet.every(
        (m) => m.ready && m.buffered >= RelayConstants.minBufferSecs && !isStale(m, t));
    if (allGood && quorum) {
      serverTime = t;
      eventId++;
      transport = Transport.playing;
      feed.add(FeedMessage(actor: 'server', action: 'resume', at: t));
    }
  }

  StateBroadcast broadcast() => StateBroadcast(
        eventId: eventId,
        transport: transport == Transport.playing ? 'playing' : 'held',
        position: position,
        serverTime: serverTime,
        mediaId: mediaId,
        media: media?.toJson(),
        members: members.values.map((m) => m.view(stale: isStale(m))).toList(),
      );
}
