import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'constants.dart';
import 'presence.dart';
import 'protocol.dart';
import 'queue.dart';

typedef SyncClock = DateTime Function();

/// How the server treats silence, drops and joiners (PROTOCOL.md
/// "Presence"). Everything but [pingInterval] is measured on the engine's
/// clock ([SyncEngine.clock]) by its 1 s sweep ([SyncEngine.tick]), so a
/// test with a fake clock steps through them without waiting;
/// [pingInterval] is the WebSocket's own timer (real time).
class Liveness {
  /// No frame for longer than this: the socket is closed and the member
  /// is `gone`.
  final Duration silence;
  /// A `gone` member is kept this long (`welcome.grace`), then it leaves.
  final Duration grace;
  /// The feed says `gone` only once a member has been gone this long (a
  /// quick return says nothing).
  final Duration goneNotice;
  /// A `joining` member holds a HELD gate at most this long (D2).
  final Duration joinerHold;
  /// A `joining` member is `in` after this at the latest.
  final Duration joiningTimeout;
  /// WebSocket ping on every `/sync` socket.
  final Duration pingInterval;
  const Liveness({
    this.silence = const Duration(seconds: RelayConstants.silenceSecs),
    this.grace = const Duration(seconds: RelayConstants.graceSecs),
    this.goneNotice = const Duration(seconds: RelayConstants.goneNoticeSecs),
    this.joinerHold = const Duration(seconds: RelayConstants.joinerHoldSecs),
    this.joiningTimeout = const Duration(seconds: RelayConstants.joiningTimeoutSecs),
    this.pingInterval = const Duration(seconds: RelayConstants.pingIntervalSecs),
  });
}

enum Transport { playing, held, finished }

enum Correction { none, slowDown, seek }

Correction correctionFor({required double ownPosition, required double serverPosition}) {
  final drift = ownPosition - serverPosition;
  if (drift.abs() > RelayConstants.driftSeekThresholdSecs) return Correction.seek;
  if (drift > RelayConstants.slowDownThresholdSecs) return Correction.slowDown;
  return Correction.none;
}

/// Content hash of a picture: the first 16 hex chars of its sha256.
String avatarHashOf(List<int> bytes) => sha256.convert(bytes).toString().substring(0, 16);

/// `(type, subtype)` of a picture by its magic bytes; null for anything
/// that is not PNG, JPEG, WebP or GIF (those are never stored or served).
(String, String)? avatarImageType(List<int> b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47])) return ('image', 'png');
  if (at(0, const [0xFF, 0xD8, 0xFF])) return ('image', 'jpeg');
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) && at(8, const [0x57, 0x45, 0x42, 0x50])) return ('image', 'webp');
  if (at(0, const [0x47, 0x49, 0x46, 0x38])) return ('image', 'gif');
  return null;
}

class EngineMember {
  final String id;
  final String token;
  /// `hello.client` (empty: none, the member cannot be taken over).
  /// Private: never broadcast, never logged.
  final String client;
  /// The `hello.seq` of the connection that holds it now.
  int seq;
  String name;
  /// Picture bytes, served at `/a/...`; only [avatarHash] is broadcast.
  Uint8List? avatarBytes;
  String avatarHash = '';
  bool ready = false;
  /// In the ready gate's set (joined it while not playing, readied, or
  /// was there at a swap); whether it counts also depends on [presence]
  /// and [error] ([SyncEngine.countsForGate]).
  bool inSet = false;
  double buffered = 0;
  /// Last reported Jellyfin access by ServerId (`report.jf`).
  Map<String, bool> jf = const {};
  /// The hosting app's own member (set by the server from the host key).
  bool host = false;
  /// Its player cannot open the current media (`report.error`): outside
  /// the ready gate until a report clears it or the media changes.
  String error = '';
  /// Bytes per second the server sent it lately (set by the server).
  int rate = 0;
  /// `hello.app`, `hello.platform`, `hello.caps` of its last hello.
  String app;
  String platform;
  ClientCaps caps;
  Presence presence;
  /// When [presence] began (joining since, gone since, ...).
  DateTime presenceSince;
  /// Gone: whether the feed has said so yet (after [Liveness.goneNotice]).
  bool goneNoticed = false;
  /// Gone: it was `away` before, and comes back `away`.
  bool awayBeforeGone = false;
  DateTime lastSeen;
  EngineMember({
    required this.id,
    required this.token,
    required this.name,
    String avatar = '',
    required DateTime now,
    this.client = '',
    this.seq = 0,
    this.app = '',
    this.platform = '',
    this.caps = const ClientCaps(),
    this.presence = Presence.watching,
  })  : lastSeen = now,
        presenceSince = now {
    setAvatar(avatar);
  }

  /// Sets the picture from base64 (empty or undecodable: none). Returns
  /// whether it changed.
  bool setAvatar(String base64) {
    Uint8List? bytes;
    if (base64.isNotEmpty) {
      try {
        bytes = base64Decode(base64);
      } on FormatException {
        bytes = null;
      }
    }
    if (bytes != null && avatarImageType(bytes) == null) bytes = null;
    final hash = bytes == null || bytes.isEmpty ? '' : avatarHashOf(bytes);
    if (hash == avatarHash) return false;
    avatarHash = hash;
    avatarBytes = hash.isEmpty ? null : bytes;
    return true;
  }

  /// When it went `gone`; null otherwise.
  DateTime? get goneSince => presence == Presence.gone ? presenceSince : null;

  MemberView view({required bool inGate}) => MemberView(
        id: id,
        name: name,
        avatarHash: avatarHash,
        ready: ready,
        inSet: inGate,
        buffered: buffered,
        presence: presence,
        goneSince: goneSince,
        jf: jf,
        host: host,
        error: error,
        rate: rate,
        app: app,
        caps: caps,
      );
}

/// Picture bytes from base64 when they decode, are at most [maxBytes] and
/// are a known image type (see [avatarImageType]); else null.
Uint8List? decodePicture(String base64, int maxBytes) {
  // Base64 is 4 chars per 3 bytes: skip decoding what cannot fit.
  if (base64.isEmpty || base64.length > (maxBytes + 2) ~/ 3 * 4) return null;
  try {
    final bytes = base64Decode(base64);
    if (bytes.length > maxBytes || avatarImageType(bytes) == null) return null;
    return bytes;
  } on FormatException {
    return null;
  }
}

/// One picture of the current media's art, by content hash.
class ArtImage {
  final String hash;
  final Uint8List bytes;
  ArtImage(this.bytes) : hash = avatarHashOf(bytes);
}

/// The feed lines the engine made: [pending] until the server sends them
/// ([drain]); each gets the next [FeedMessage.seq]. The last
/// [RelayConstants.feedReplayLines] stay for a reconnect's replay ([after]).
class EngineFeed {
  final List<FeedMessage> pending = [];
  final List<FeedMessage> _recent = [];
  int _seq = 0;

  /// The `seq` of the last line (0 before any).
  int get lastSeq => _seq;

  void add(FeedMessage message) {
    final line = message.copyWith(seq: ++_seq);
    pending.add(line);
    _recent.add(line);
    if (_recent.length > RelayConstants.feedReplayLines) _recent.removeAt(0);
  }

  List<FeedMessage> drain() {
    final out = List<FeedMessage>.from(pending);
    pending.clear();
    return out;
  }

  /// Kept lines after [seq] (`hello.feedAfter`), oldest first, marked
  /// `replayed`. Lines still [pending] are left out (they go out to
  /// everyone anyway).
  List<FeedMessage> after(int seq) => [
        for (final f in _recent)
          if (f.seq > seq && !pending.contains(f)) f.copyWith(replayed: true),
      ];
}

class SyncEngine {
  final SyncClock clock;
  final Liveness liveness;
  final PresencePolicy policy;
  final EngineFeed feed = EngineFeed();
  /// Members by token, in join order.
  final Map<String, EngineMember> members = {};

  int eventId = 0;
  Transport transport = Transport.held;
  double position = 0;
  DateTime serverTime;
  int mediaId = 1;
  HelloMedia? media;
  /// Token of the member who made the current swap; null before any swap.
  String? swapBy;
  /// Art of the current media (`art`), served at `/i/...`; only the hashes
  /// ride in `state.media.art`. Every swap clears it.
  ArtImage? poster;
  ArtImage? banner;
  /// Up next ([EngineQueue]): in `state.queue`, edited by `queue`
  /// messages, taken from by swaps that name an item.
  final EngineQueue queue = EngineQueue();
  /// The shared countdown to Up next (`state.advance`); reserved: only
  /// `cancel` touches it today.
  QueueAdvance? advance;
  /// A member went `gone` (its socket closed or fell silent): the server
  /// closes the socket and marks a relay it serves.
  void Function(EngineMember member)? onGone;
  /// A member left for good (`bye`, grace over): the server forgets its
  /// token and ends a relay it served.
  void Function(EngineMember member)? onLeft;
  int _nextId = 1;
  // Who sent the seek that produced [_seekEventId], for the echo check.
  String? _seekBy;
  int _seekSeq = 0;
  int _seekEventId = -1;

  SyncEngine({SyncClock? clock, this.liveness = const Liveness()})
      : clock = clock ?? (() => DateTime.now().toUtc()),
        policy = PresencePolicy(joinerHold: liveness.joinerHold),
        serverTime = (clock ?? (() => DateTime.now().toUtc()))();

  DateTime get now => clock();

  double positionAt([DateTime? at]) {
    final t = at ?? now;
    if (transport != Transport.playing) return position;
    return position + t.difference(serverTime).inMilliseconds / 1000.0;
  }

  /// Whether [member] counts for the ready gate now: in the set, no
  /// player error, and its presence counts ([PresencePolicy], D2).
  bool countsForGate(EngineMember member, [DateTime? at]) =>
      member.inSet &&
      member.error.isEmpty &&
      policy.countsFor(member.presence, Purpose.gate,
          playing: transport == Transport.playing, joiningFor: (at ?? now).difference(member.presenceSince));

  /// Media length in seconds, null while nobody has reported it.
  double? get duration {
    final d = media?.duration ?? 0;
    return d > 0 ? d : null;
  }

  /// Buffer every in-set member needs: [RelayConstants.minBufferSecs], or
  /// less near the end where that much is not left to buffer.
  double requiredBufferSecs([DateTime? at]) {
    final d = duration;
    const full = RelayConstants.minBufferSecs;
    if (d == null) return full;
    final left = d - positionAt(at) - RelayConstants.endSlackSecs;
    return left.clamp(0.0, full).toDouble();
  }

  /// Any frame from a member.
  void _seen(EngineMember member) => member.lastSeen = now;

  /// Any frame from [token]'s socket (a ping, a chat): it is not silent.
  void touch(String token) {
    final m = members[token];
    if (m != null) _seen(m);
  }

  FeedMessage _line(String action, {EngineMember? actor, EngineMember? target, String reason = ''}) => FeedMessage(
      actor: actor?.name ?? 'server',
      actorId: actor?.id ?? 'server',
      action: action,
      target: target?.name,
      targetId: target?.id ?? '',
      reason: reason,
      at: now);

  /// Heartbeat (1 s): silence, joining timeouts, gone notices, grace,
  /// a stale play request, end of media.
  void tick() {
    sweepSilent();
    sweepPresence();
    queue.tick(now);
    evaluate();
  }

  /// Joining: loads in the background until its reports hold the media
  /// (D2); with nothing up there is nothing to load.
  Presence get _arriving => media == null ? Presence.watching : Presence.joining;

  /// A new member ([client] empty: one that cannot be taken over).
  String applyJoin(String token, String name, String avatar,
      {String client = '', int seq = 0, String app = '', String platform = '', ClientCaps caps = const ClientCaps()}) {
    final id = 'm${_nextId++}';
    // Joining while not playing: in the set, so the start waits for them
    // (at most [Liveness.joinerHold]); while playing, out until they ready
    // (a late joiner never pauses).
    final m = members[token] = EngineMember(
        id: id,
        token: token,
        name: name,
        avatar: avatar,
        now: now,
        client: client,
        seq: seq,
        app: app,
        platform: platform,
        caps: caps,
        presence: _arriving)
      ..inSet = transport != Transport.playing;
    feed.add(_line('join', actor: m));
    evaluate();
    return id;
  }

  /// The member with `hello.client` [client]; null for none (or empty).
  EngineMember? byClient(String client) {
    if (client.isEmpty) return null;
    for (final m in members.values) {
      if (m.client == client) return m;
    }
    return null;
  }

  /// A newer hello of the same client took [token]'s member over (see
  /// `hello.client`): back from `gone` it is `joining` again (`away` if it
  /// was), ready flag kept, feed `return` when the feed had said `gone`.
  /// Returns whether it came back from `gone`.
  bool applyTakeover(String token,
      {required int seq, String app = '', String platform = '', ClientCaps caps = const ClientCaps()}) {
    final m = members[token];
    if (m == null) return false;
    m
      ..seq = seq
      ..app = app
      ..platform = platform
      ..caps = caps;
    _seen(m);
    if (m.presence != Presence.gone) return false;
    final noticed = m.goneNoticed;
    m
      ..goneNoticed = false
      ..presence = m.awayBeforeGone ? Presence.away : _arriving
      ..presenceSince = now
      ..awayBeforeGone = false
      ..inSet = m.error.isEmpty && (m.ready || transport != Transport.playing);
    if (noticed) feed.add(_line('return', actor: m));
    evaluate();
    return true;
  }

  /// [token]'s socket closed or fell silent: `gone`, kept for the grace
  /// with everything it had. No feed line yet ([Liveness.goneNotice]).
  void applyGone(String token) {
    final m = members[token];
    if (m == null || m.presence == Presence.gone) return;
    m
      ..awayBeforeGone = m.presence == Presence.away
      ..presence = Presence.gone
      ..presenceSince = now
      ..goneNoticed = false;
    evaluate();
    onGone?.call(m);
  }

  /// Members with no frame for [Liveness.silence] go `gone`. Returns
  /// their tokens.
  List<String> sweepSilent() {
    final t = now;
    final silent = [
      for (final m in members.values)
        if (m.presence != Presence.gone && t.difference(m.lastSeen) > liveness.silence) m.token,
    ];
    for (final token in silent) {
      applyGone(token);
    }
    return silent;
  }

  /// Joining timeouts, the delayed `gone` line, grace expiry (leave).
  void sweepPresence() {
    final t = now;
    for (final m in members.values.toList()) {
      final since = t.difference(m.presenceSince);
      switch (m.presence) {
        case Presence.joining:
          if (since >= liveness.joiningTimeout) _becomeIn(m);
        case Presence.gone:
          if (since >= liveness.grace) {
            applyLeave(m.token, reason: 'grace');
          } else if (!m.goneNoticed && since >= liveness.goneNotice) {
            m.goneNoticed = true;
            feed.add(_line('gone', actor: m));
          }
        case Presence.watching:
        case Presence.away:
          break;
      }
    }
  }

  /// Joining is over: `in`. In the set if it is ready, or (not playing)
  /// if it was in it; while playing an unready member waits for its own
  /// `ready`, so coming in never pauses anyone.
  void _becomeIn(EngineMember m) {
    if (m.presence != Presence.joining) return;
    m
      ..presence = Presence.watching
      ..presenceSince = now
      ..inSet = m.error.isEmpty && (m.ready || (transport != Transport.playing && m.inSet));
    evaluate();
  }

  /// Name and/or picture change ([ProfileIntent]); null leaves it, an
  /// empty [avatar] removes the picture. [name] is already cleaned.
  void applyProfile(String token, {String? name, String? avatar}) {
    final member = members[token];
    if (member == null) return;
    _seen(member);
    final oldName = member.name;
    final renamed = name != null && name != oldName;
    if (renamed) member.name = name;
    final pictured = avatar != null && member.setAvatar(avatar);
    if (renamed) {
      feed.add(FeedMessage(
          actor: name, actorId: member.id, action: 'rename', target: oldName, targetId: member.id, at: now));
    } else if (pictured) {
      feed.add(_line('avatar', actor: member));
    }
  }

  /// Picture bytes of a current member by [EngineMember.avatarHash].
  Uint8List? avatarFor(String hash) {
    if (hash.isEmpty) return null;
    for (final member in members.values) {
      if (member.avatarHash == hash) return member.avatarBytes;
    }
    return null;
  }

  /// Art for the current media from [token]: only from the member who made
  /// the current swap (or the host) and only for the current [forMediaId].
  /// It replaces any earlier art; an absent or invalid field is none.
  /// Returns whether it was taken.
  bool applyArt(String token, int forMediaId, {String? poster, String? banner}) {
    final member = members[token];
    if (member == null || media == null || forMediaId != mediaId) return false;
    if (token != swapBy && !member.host) return false;
    _seen(member);
    final p = poster == null ? null : decodePicture(poster, RelayConstants.maxPosterBytes);
    final b = banner == null ? null : decodePicture(banner, RelayConstants.maxBannerBytes);
    this.poster = p == null ? null : ArtImage(p);
    this.banner = b == null ? null : ArtImage(b);
    return true;
  }

  /// Bytes of the current media's art by hash.
  Uint8List? artFor(String hash) {
    if (hash.isEmpty) return null;
    if (poster?.hash == hash) return poster!.bytes;
    if (banner?.hash == hash) return banner!.bytes;
    return queue.thumbFor(hash);
  }

  /// `state.media.art`; null when there is none.
  Map<String, Object?>? get artJson => poster == null && banner == null
      ? null
      : {
          if (poster != null) 'poster': poster!.hash,
          if (banner != null) 'banner': banner!.hash,
        };

  /// [token]'s member leaves for good: `bye` ([reason] `bye`), or its
  /// grace ran out (`grace`). Feed `leave`. Returns its id.
  String? applyLeave(String token, {String reason = ''}) {
    final removed = members.remove(token);
    if (removed == null) return null;
    feed.add(_line('leave', actor: removed, reason: reason));
    evaluate();
    onLeft?.call(removed);
    return removed.id;
  }

  EngineMember? byId(String id) {
    for (final member in members.values) {
      if (member.id == id) return member;
    }
    return null;
  }

  /// `presence` from [actorToken] on [targetId] (empty: itself). `away`:
  /// anyone may set anyone (the host too); `in`: only itself, through
  /// `joining` while media is up (D2). Returns [ErrCode.forbidden] when
  /// someone else is set `in`, else null (no-ops and unknown targets
  /// included).
  ErrCode? applyPresence(String actorToken, String targetId, Presence state,
      {PresenceReason reason = PresenceReason.manual}) {
    final actor = members[actorToken];
    if (actor == null) return null;
    _seen(actor);
    final target = targetId.isEmpty ? actor : byId(targetId);
    if (target == null) return null;
    final self = identical(actor, target);
    final why = reason == PresenceReason.manual ? '' : reason.name;
    if (state == Presence.away) {
      if (target.presence == Presence.gone) {
        if (target.awayBeforeGone) return null;
        target.awayBeforeGone = true;
      } else {
        if (target.presence == Presence.away) return null;
        target
          ..presence = Presence.away
          ..presenceSince = now;
      }
      feed.add(_line('away', actor: actor, target: self ? null : target, reason: why));
      evaluate();
      return null;
    }
    if (state != Presence.watching) return null;
    if (!self) return ErrCode.forbidden;
    if (target.presence != Presence.away) return null;
    target
      ..presence = _arriving
      ..presenceSince = now
      ..inSet = target.error.isEmpty && (target.ready || transport != Transport.playing);
    feed.add(_line('in', actor: actor, reason: why));
    evaluate();
    return null;
  }

  void applyReady(String token, bool ready, {String source = 'manual'}) {
    final member = members[token];
    if (member == null) return;
    _seen(member);
    if (member.ready == ready && (member.inSet || member.error.isNotEmpty)) {
      evaluate();
      return;
    }
    member.ready = ready;
    if (ready && member.error.isEmpty) member.inSet = true;
    feed.add(_line(ready ? 'ready' : 'unready', actor: member, reason: source));
    evaluate();
  }

  /// Ready (or unready) [target] (a member id) or `all`. Members `away`
  /// are left alone.
  void applyForce(String actorToken, String target, bool ready) {
    final actor = members[actorToken];
    if (target == 'all') {
      for (final member in members.values) {
        if (member.presence == Presence.away) continue;
        member.ready = ready;
        if (ready && member.error.isEmpty) member.inSet = true;
      }
    } else {
      final member = byId(target);
      if (member == null || member.presence == Presence.away) return;
      member.ready = ready;
      if (ready && member.error.isEmpty) member.inSet = true;
      feed.add(_line(ready ? 'force-ready' : 'force-unready', actor: actor, target: member));
      evaluate();
      return;
    }
    feed.add(_line(ready ? 'force-play' : 'force-hold', actor: actor));
    evaluate();
  }

  void applySeek(String token, double seekPosition, {int seq = 0}) {
    final member = members[token];
    if (member == null) return;
    if (!seekPosition.isFinite || seekPosition < 0) return;
    _seen(member);
    position = seekPosition;
    serverTime = now;
    eventId++;
    _seekBy = member.id;
    _seekSeq = seq;
    _seekEventId = eventId;
    feed.add(_line('seek', actor: member));
    // Seeking back from the end: held, and resumes once the gate passes.
    if (transport == Transport.finished) {
      transport = Transport.held;
      evaluate();
    }
  }

  /// Returns false (no state change) for media with non-finite numbers.
  /// [queueId]: the Up next item this swap puts up; it leaves the queue
  /// (any other swap drops the continuation item, [EngineQueue.auto]).
  bool applySwap(String actorToken, HelloMedia next, {String? queueId}) {
    if (!next.duration.isFinite || next.size < 0) return false;
    final actor = members[actorToken];
    queue.swapped(queueId);
    advance = null;
    mediaId++;
    media = next;
    swapBy = actorToken;
    poster = null;
    banner = null;
    position = 0;
    serverTime = now;
    eventId++;
    transport = Transport.held;
    // Ready flags stay; everyone here now waits for everyone else here now
    // (who counts is up to presence: `away` and `gone` never do).
    for (final member in members.values) {
      member.error = '';
      member.inSet = true;
      member.buffered = 0;
    }
    feed.add(_line('swap', actor: actor));
    return true;
  }

  void applyReport(String token, double reportPosition, double buffered, int reportEventId,
      {double duration = 0, int mediaId = 0, Map<String, bool>? jf, String error = ''}) {
    final member = members[token];
    if (member == null) return;
    if (!reportPosition.isFinite) return;
    _setError(member, mediaId == this.mediaId ? error : '');
    _seen(member);
    if (jf != null) member.jf = Map.unmodifiable(jf);
    // A report for an earlier media (sent before the swap reached the
    // client) says nothing about this one's buffer.
    final earlier = mediaId != 0 && mediaId != this.mediaId;
    member.buffered = earlier || !buffered.isFinite || buffered < 0 ? 0 : buffered;
    final m = media;
    // First report of the length wins; only for the media the client has open.
    if (m != null && m.duration <= 0 && mediaId == this.mediaId &&
        duration.isFinite && duration > 0) {
      media = m.copyWith(duration: duration);
    }
    if (member.presence == Presence.joining) {
      // Joining ends when it cannot open the media (it stays out of the
      // gate by its error), or once it holds the media at the server's
      // position with the buffer the gate needs: it comes in in sync.
      final t = now;
      if (member.error.isNotEmpty) {
        _becomeIn(member);
      } else if (!earlier &&
          reportEventId >= eventId &&
          (reportPosition - positionAt(t)).abs() <= RelayConstants.driftSeekThresholdSecs &&
          member.buffered >= requiredBufferSecs(t)) {
        _becomeIn(member);
      }
    }
    if (reportEventId < eventId) return;
    evaluate();
  }

  /// An error takes the member out of the set (the gate stops waiting for
  /// it); clearing it puts it back like a join: in the set unless playing,
  /// then only if it is ready (the others hold for its buffer).
  void _setError(EngineMember member, String error) {
    if (member.error == error) return;
    member.error = error;
    if (error.isNotEmpty) {
      member.inSet = false;
    } else {
      member.inSet = member.ready || transport != Transport.playing;
    }
    // Leaving the set may let the others start.
    evaluate();
  }

  void evaluate() {
    final t = now;
    if (transport == Transport.finished) return;
    final need = requiredBufferSecs(t);
    if (transport == Transport.playing) {
      final d = duration;
      if (d != null && positionAt(t) >= d) {
        position = d;
        serverTime = t;
        eventId++;
        transport = Transport.finished;
        feed.add(_line('finished'));
        return;
      }
      final blocked =
          members.values.where((m) => countsForGate(m, t)).any((m) => !m.ready || m.buffered < need);
      if (blocked) {
        position = positionAt(t);
        serverTime = t;
        eventId++;
        transport = Transport.held;
        feed.add(_line('pause'));
      }
      return;
    }
    final inSet = members.values.where((m) => countsForGate(m, t)).toList();
    if (inSet.isEmpty) return;
    if (inSet.every((m) => m.ready && m.buffered >= need)) {
      serverTime = t;
      eventId++;
      transport = Transport.playing;
      feed.add(_line('resume'));
    }
  }

  /// `state.hold` while HELD with media up: who the gate waits for and why
  /// ([HoldReason]). [sourceGone]: the current media's relay source is
  /// `gone` (a short buffer then reads [HoldReason.source]).
  HoldInfo? holdInfo({bool sourceGone = false}) {
    if (transport != Transport.held || media == null) return null;
    final t = now;
    final need = requiredBufferSecs(t);
    final gate = members.values.where((m) => countsForGate(m, t)).toList();
    if (gate.isEmpty) return const HoldInfo(reason: HoldReason.start);
    final joining = gate.where((m) => m.presence == Presence.joining && (!m.ready || m.buffered < need)).toList();
    if (joining.isNotEmpty) {
      final until = joining.map((m) => m.presenceSince.add(liveness.joinerHold)).reduce((a, b) => a.isBefore(b) ? a : b);
      return HoldInfo(reason: HoldReason.joining, members: [for (final m in joining) m.id], until: until);
    }
    final unready = gate.where((m) => !m.ready).toList();
    if (unready.isNotEmpty) return HoldInfo(reason: HoldReason.ready, members: [for (final m in unready) m.id]);
    final short = gate.where((m) => m.buffered < need).toList();
    if (short.isNotEmpty) {
      return HoldInfo(
          reason: sourceGone ? HoldReason.source : HoldReason.buffer, members: [for (final m in short) m.id]);
    }
    return null;
  }

  /// [relay]: whether the server can relay the current Jellyfin media; the
  /// engine does not know the server's credential.
  /// [warm]: the server's warm relay for Up next's first item, shown as
  /// that item's `media.relay`. [sourceGone]: see [holdInfo].
  StateBroadcast broadcast(
      {bool relay = false,
      bool relayNext = false,
      ({String id, MediaRelay relay})? warm,
      bool sourceGone = false}) {
    final bySeek = _seekEventId == eventId;
    final t = now;
    return StateBroadcast(
      eventId: eventId,
      transport: transport.name,
      position: position,
      serverTime: serverTime,
      mediaId: mediaId,
      media: media == null
          ? null
          : {
              ...media!.toJson(),
              if (members[swapBy]?.id case final id?) 'swapBy': id,
              if (artJson != null) 'art': artJson,
            },
      members: [for (final m in members.values) m.view(inGate: countsForGate(m, t))],
      seekBy: bySeek ? _seekBy : null,
      seekSeq: bySeek ? _seekSeq : null,
      relay: relay,
      relayNext: relayNext,
      queue: [
        for (final q in queue.items)
          warm != null && q.id == warm.id ? q.copyWith(media: q.media.copyWith(relay: warm.relay)) : q,
      ],
      queuePlay: queue.play,
      hold: holdInfo(sourceGone: sourceGone),
      advance: advance,
    );
  }
}
