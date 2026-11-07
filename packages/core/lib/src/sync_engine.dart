import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'constants.dart';
import 'presence.dart';
import 'protocol.dart';
import 'queue.dart';
import 'whats_next.dart';

typedef SyncClock = DateTime Function();

/// How the server treats silence and drops (PROTOCOL.md "Presence").
/// Everything but [pingInterval] is measured on the engine's clock
/// ([SyncEngine.clock]) by its 1 s sweep ([SyncEngine.tick]), so a test
/// with a fake clock steps through them without waiting; [pingInterval]
/// is the WebSocket's own timer (real time).
class Liveness {
  /// No frame for longer than this: the socket is closed and the member
  /// is `gone`.
  final Duration silence;
  /// A `gone` member is kept this long (`welcome.grace`), then it leaves.
  final Duration grace;
  /// The feed says `gone` only once a member has been gone this long (a
  /// quick return says nothing).
  final Duration goneNotice;
  /// WebSocket ping on every `/sync` socket.
  final Duration pingInterval;
  const Liveness({
    this.silence = const Duration(seconds: RelayConstants.silenceSecs),
    this.grace = const Duration(seconds: RelayConstants.graceSecs),
    this.goneNotice = const Duration(seconds: RelayConstants.goneNoticeSecs),
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
  /// The colour it picked (`#rrggbb`, [cleanMemberColor]); '' for none.
  String color = '';
  double buffered = 0;
  /// Last reported Jellyfin access by ServerId (`report.jf`).
  Map<String, bool> jf = const {};
  /// The hosting app's own member (set by the server from the host key).
  bool host = false;
  /// Its player cannot open the current media (`report.error`): never
  /// waited for until a report clears it or the media changes.
  String error = '';
  /// Bytes per second the server sent it lately (set by the server).
  int rate = 0;
  /// `hello.app`, `hello.platform`, `hello.caps` of its last hello.
  String app;
  String platform;
  ClientCaps caps;
  /// Where it stands (`in`, `brb`, `afk`, `out`).
  Presence presence = Presence.watching;
  /// When [presence] began.
  DateTime since;
  /// Its player is not with the group yet (just joined, back from out or
  /// a drop, left behind by a continue): until a report holds the current
  /// media at the server position with the buffer the gate needs.
  bool loading = false;
  /// Someone continued without its video: never waited for until it is
  /// with the group again ([loading] ends).
  bool skipped = false;
  /// Disconnected, kept for the grace.
  bool gone = false;
  DateTime? goneAt;
  /// Gone: whether the feed has said so yet (after [Liveness.goneNotice]).
  bool goneNoticed = false;
  /// Its last reported position in the current media (null before one).
  double? spot;
  /// Where it was in the video when it dropped (`gone` while in): its
  /// `return` line says how much it missed.
  double? droppedAt;
  /// A live stream's edge as its player last reported it (`report.edge`,
  /// stream time); 0 before one.
  double liveEdge = 0;
  /// Its player reached the end of the live stream there (a live report
  /// with a `duration`); null while it goes on.
  double? liveEnd;
  /// The oldest moment of the live stream its player can rewind to
  /// (`report.from`, stream time); 0 when it cannot.
  double liveFrom = 0;
  DateTime lastSeen;
  EngineMember({
    required this.id,
    required this.token,
    required this.name,
    String avatar = '',
    String color = '',
    required DateTime now,
    this.client = '',
    this.seq = 0,
    this.app = '',
    this.platform = '',
    this.caps = const ClientCaps(),
  })  : lastSeen = now,
        since = now {
    setAvatar(avatar);
    setColor(color);
  }

  /// Sets the colour (malformed: none). Returns whether it changed.
  bool setColor(String value) {
    final c = cleanMemberColor(value);
    if (c == color) return false;
    color = c;
    return true;
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

  MemberView view() => MemberView(
        id: id,
        name: name,
        avatarHash: avatarHash,
        color: color,
        buffered: buffered,
        presence: presence,
        since: presence == Presence.watching ? null : since,
        loading: loading && !presence.isOut,
        gone: gone,
        goneSince: gone ? goneAt : null,
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
  final EngineFeed feed = EngineFeed();
  /// Members by token, in join order.
  final Map<String, EngineMember> members = {};

  int eventId = 0;
  Transport transport = Transport.held;
  double position = 0;
  DateTime serverTime;
  int mediaId = 1;
  HelloMedia? media;
  /// The group's wish (`state.wish`): play or pause. A pause lasts until
  /// someone plays; a swap keeps it; it plays when it wants to and nobody
  /// is waited for ([waitedFor]).
  bool wantsPlay = false;
  /// Token of the member who made the current swap; null before any swap.
  String? swapBy;
  /// Art of the current media (`art`), served at `/i/...`; only the hashes
  /// ride in `state.media.art`. Every swap clears it.
  ArtImage? poster;
  ArtImage? banner;
  /// Up next ([EngineQueue]): in `state.queue`, edited by `queue`
  /// messages, taken from by swaps that name an item.
  final EngineQueue queue = EngineQueue();
  /// The shared countdown to Up next's first item (`state.advance`, see
  /// [whatsNext]).
  QueueAdvance? advance;
  /// The relay of Up next item `queueId` waits for its source, who is
  /// `gone` (set by the server: the engine does not hold relays). The
  /// countdown holds while it does.
  bool Function(String queueId)? itemSourceGone;
  // The mediaId whose countdown was cancelled (`cancel`, or a pause during
  // it): it does not start again for that media.
  int _advanceOffFor = -1;
  // The item last asked to play for the current media: not counted down
  // again.
  String? _advancedId;
  // Members passed over for the play request [_passFor] (`queuePass`),
  // and whether its only performer was asked twice.
  final List<String> _pass = [];
  String? _passFor;
  bool _reasked = false;
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
  /// A live stream: how far the group's point ([position]) is behind its
  /// live point (a rewind, `state.behind`); 0 at live.
  double behind = 0;
  // When the group's point of a live stream last moved by a seek.
  DateTime? _liveSeekAt;

  SyncEngine({SyncClock? clock, this.liveness = const Liveness()})
      : clock = clock ?? (() => DateTime.now().toUtc()),
        serverTime = (clock ?? (() => DateTime.now().toUtc()))();

  DateTime get now => clock();

  double positionAt([DateTime? at]) {
    final t = at ?? now;
    if (transport != Transport.playing) return position;
    return position + t.difference(serverTime).inMilliseconds / 1000.0;
  }

  /// The BRB members, connected or not: the group waits for them.
  Iterable<EngineMember> get brbs => members.values.where((m) => m.presence == Presence.brb);

  /// Whether the group waits for [member]'s video: watching, connected,
  /// its player can open the media, nobody continued without it, and not
  /// still loading while the group plays (a joiner never pauses anyone).
  bool videoCounts(EngineMember member) =>
      member.presence == Presence.watching &&
      !member.gone &&
      member.error.isEmpty &&
      !member.skipped &&
      !(member.loading && transport == Transport.playing);

  /// The current media is a live stream ([HelloMedia.live]): the clock is
  /// the group's live point in stream time, set from the players' reports
  /// ([_liveReport]); nobody waits for anyone, pause is each member's own.
  bool get live => media?.live ?? false;

  /// Media length in seconds, null while nobody has reported it.
  double? get duration {
    final d = media?.duration ?? 0;
    return d > 0 ? d : null;
  }

  /// Buffer every watching member needs: [RelayConstants.minBufferSecs],
  /// or less near the end where that much is not left to buffer.
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

  /// Heartbeat (1 s): silence, gone notices, grace, a play request nobody
  /// acted on, end of media, what's next.
  void tick() {
    sweepSilent();
    sweepPresence();
    _askAgain();
    evaluate();
    whatsNext();
  }

  /// A play request nobody acted on within
  /// [RelayConstants.queuePlayTimeoutSecs] is asked again: of someone else
  /// who can put it up when there is one (the one who did not goes into
  /// `queuePass`), else of the same member once more; then the item is
  /// skipped (feed `queue-skip`). While nobody is around it keeps waiting.
  void _askAgain() {
    final play = queue.play;
    if (play == null || !queue.overdue(now)) return;
    final item = queue.item(play);
    if (item == null) return;
    _syncPass();
    final views = [for (final m in members.values) m.view()];
    final perf = queuePerformer(item, views, pass: _pass).id;
    if (perf == null) {
      queue.reask(now);
      return;
    }
    final other = queuePerformer(item, views, pass: [..._pass, perf]).id;
    if (other != null && other != perf) {
      _pass.add(perf);
      queue.reask(now);
    } else if (!_reasked) {
      _reasked = true;
      queue.reask(now);
    } else {
      final name = views.where((m) => m.id == perf).firstOrNull?.name ?? 'who puts it up';
      _skipQueued(item, "$name didn't put it up");
    }
  }

  /// [_pass] belongs to the current play request only.
  void _syncPass() {
    if (_passFor == queue.play) return;
    _passFor = queue.play;
    _pass.clear();
    _reasked = false;
  }

  /// `state.queuePass`: members passed over for the current play request.
  List<String> get queuePass {
    _syncPass();
    return List.unmodifiable(_pass);
  }

  /// What's next (PROTOCOL.md "Queue"), on every tick and queue change:
  /// - a play request (`queuePlay`) nobody here can serve is skipped
  ///   (feed `queue-skip`, actor `server`, with why: [queuePerformer]);
  /// - with nothing up, the first item is asked to play at once;
  /// - over the media's last [RelayConstants.advanceSecs] with an item
  ///   first, the countdown ([advance]) runs, ending at the media's end
  ///   (not for a media whose countdown was cancelled or paused, nor
  ///   again for the item it already asked for); an item coming first
  ///   once the media finished starts a countdown of its own; it follows
  ///   the first item when that changes, keeping its end; a seek, an
  ///   empty queue, `cancel`, a pause and a swap end it. At its end the
  ///   first item is asked to play (`queuePlay`) and the countdown is
  ///   over, unless nobody can put it up (skipped) or its performer is not
  ///   around or its relay's source is `gone` ([itemSourceGone]): then it
  ///   holds until they are back.
  /// Returns whether anything changed.
  bool whatsNext() {
    var changed = false;
    final views = [for (final m in members.values) m.view()];
    final play = queue.play;
    _syncPass();
    if (play != null) {
      final item = queue.item(play);
      final why = item == null ? null : queuePerformer(item, views, pass: _pass).why;
      if (item != null && why != null) {
        _skipQueued(item, why);
        changed = true;
      }
    }
    final first = queue.items.firstOrNull;
    if (media == null) {
      if (first != null && queue.play == null) changed = _due(first, views) || changed;
      return changed;
    }
    var a = advance;
    if (first == null || queue.play != null) {
      if (a != null) {
        advance = null;
        changed = true;
      }
      return changed;
    }
    final off = _advanceOffFor == mediaId || _advancedId == first.id;
    if (transport != Transport.finished) {
      final d = duration;
      final left = d == null ? double.infinity : d - positionAt();
      if (off || left > RelayConstants.advanceSecs || transport != Transport.playing && !wantsPlay) {
        if (a != null) {
          advance = null;
          changed = true;
        }
        return changed;
      }
      // Ends at the media's end (while held its end moves on with now).
      final at = now.add(Duration(milliseconds: ((left - RelayConstants.advanceSecs) * 1000).round()));
      if (a == null || a.id != first.id || (a.at.difference(at).inMilliseconds).abs() > 400) {
        advance = QueueAdvance(id: first.id, at: at, secs: RelayConstants.advanceSecs);
        changed = true;
      }
      return changed;
    }
    if (a == null) {
      if (off) return changed;
      advance = a = QueueAdvance(id: first.id, at: now, secs: RelayConstants.advanceSecs);
      changed = true;
    } else if (a.id != first.id) {
      advance = a = QueueAdvance(id: first.id, at: a.at, secs: a.secs);
      changed = true;
    }
    if (now.isBefore(a.at.add(Duration(seconds: a.secs)))) return changed;
    return _due(first, views) || changed;
  }

  /// [item] should play now: asked for (`queuePlay`), skipped when nobody
  /// can put it up, or held. Returns whether anything changed.
  bool _due(QueueItem item, List<MemberView> views) {
    final perf = queuePerformer(item, views);
    final why = perf.why;
    if (why != null) {
      _skipQueued(item, why);
      return true;
    }
    if (perf.id == null || (itemSourceGone?.call(item.id) ?? false)) return false;
    queue.requestPlay(item.id, now);
    advance = null;
    _advancedId = item.id;
    return true;
  }

  void _skipQueued(QueueItem item, String why) {
    queue.remove(item.id);
    // The countdown goes on with the next item (asked for on the next
    // tick when its time is up).
    final a = advance, first = queue.items.firstOrNull;
    if (a != null && a.id == item.id) {
      advance = first == null ? null : QueueAdvance(id: first.id, at: a.at, secs: a.secs);
    }
    feed.add(FeedMessage(
        actor: 'server', actorId: 'server', action: 'queue-skip', target: item.title, reason: why, at: now));
  }

  /// `cancel` (or a pause during the countdown) for the current media: no
  /// countdown for it any more.
  void cancelAdvance() {
    advance = null;
    _advanceOffFor = mediaId;
  }

  /// A new member ([client] empty: one that cannot be taken over). With
  /// media up it loads first ([EngineMember.loading]).
  String applyJoin(String token, String name, String avatar,
      {String color = '',
      String client = '',
      int seq = 0,
      String app = '',
      String platform = '',
      ClientCaps caps = const ClientCaps()}) {
    final id = 'm${_nextId++}';
    final m = members[token] = EngineMember(
        id: id,
        token: token,
        name: name,
        avatar: avatar,
        color: color,
        now: now,
        client: client,
        seq: seq,
        app: app,
        platform: platform,
        caps: caps)
      ..loading = media != null;
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
  /// `hello.client`): back from `gone` it keeps its standing and loads
  /// again, feed `return` when the feed had said `gone`. Returns whether
  /// it came back from `gone`.
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
    if (!m.gone) return false;
    final noticed = m.goneNoticed;
    m
      ..gone = false
      ..goneAt = null
      ..goneNoticed = false
      ..loading = media != null;
    final at = m.droppedAt;
    m.droppedAt = null;
    if (noticed) {
      // How much of the video it missed (a pause meanwhile: nothing).
      final missed = at == null ? 0 : (positionAt() - at).floor();
      feed.add(FeedMessage(
          actor: m.name,
          actorId: m.id,
          action: 'return',
          at: now,
          missed: missed >= RelayConstants.missedNoticeSecs ? missed : 0));
    }
    evaluate();
    return true;
  }

  /// [token]'s socket closed or fell silent: `gone`, kept for the grace
  /// with everything it had (a BRB is still waited for). No feed line yet
  /// ([Liveness.goneNotice]).
  void applyGone(String token) {
    final m = members[token];
    if (m == null || m.gone) return;
    if (m.presence == Presence.watching && media != null) m.droppedAt = m.spot ?? positionAt();
    m
      ..gone = true
      ..goneAt = now
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
        if (!m.gone && t.difference(m.lastSeen) > liveness.silence) m.token,
    ];
    for (final token in silent) {
      applyGone(token);
    }
    return silent;
  }

  /// The delayed `gone` line, grace expiry (leave).
  void sweepPresence() {
    final t = now;
    for (final m in members.values.toList()) {
      final at = m.goneAt;
      if (!m.gone || at == null) continue;
      final since = t.difference(at);
      if (since >= liveness.grace) {
        applyLeave(m.token, reason: 'grace');
      } else if (!m.goneNoticed && since >= liveness.goneNotice) {
        m.goneNoticed = true;
        feed.add(_line('gone', actor: m));
      }
    }
  }

  /// [m] is with the group again (loading over).
  void _caughtUp(EngineMember m) {
    m
      ..loading = false
      ..skipped = false;
  }

  /// Name, picture and/or colour change ([ProfileIntent]); null leaves
  /// it, an empty [avatar] removes the picture, an empty or malformed
  /// [color] the colour. [name] is already cleaned. A colour change shows
  /// in the state only (no feed line).
  void applyProfile(String token, {String? name, String? avatar, String? color}) {
    final member = members[token];
    if (member == null) return;
    _seen(member);
    final oldName = member.name;
    final renamed = name != null && name != oldName;
    if (renamed) member.name = name;
    if (color != null) member.setColor(color);
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
  /// grace ran out (`grace`). Feed `leave`. The last BRB member leaving
  /// leaves a plain pause: it never plays by itself. Returns its id.
  String? applyLeave(String token, {String reason = ''}) {
    final removed = members.remove(token);
    if (removed == null) return null;
    if (removed.presence == Presence.brb && brbs.isEmpty) wantsPlay = false;
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

  /// Held now at the current position (the clock stops), when playing. A
  /// live stream never holds: it goes on whoever pauses or is BRB.
  void _holdNow() {
    if (transport != Transport.playing || live) return;
    position = positionAt();
    serverTime = now;
    eventId++;
    transport = Transport.held;
  }

  /// `play` / `pause` from [token]: the group's wish. A pause holds at
  /// once and, during the countdown to Up next, stops it at the end; a
  /// play starts when nobody is waited for.
  void applyTransport(String token, bool play) {
    final member = members[token];
    if (member == null) return;
    _seen(member);
    // Live: pause is each member's own (its app never sends it).
    if (live) return;
    if (wantsPlay == play) {
      evaluate();
      return;
    }
    wantsPlay = play;
    feed.add(_line(play ? 'play' : 'pause', actor: member));
    if (!play) {
      if (advance != null && transport != Transport.finished) cancelAdvance();
      _holdNow();
    }
    evaluate(quiet: true);
  }

  /// `presence` from [actorToken] on [targetId] (empty: itself):
  /// - `brb` on anyone ("Wait for Bob"): the group waits for them (held at
  ///   once). [resume] from the first BRB: the group was playing when the
  ///   press began, so it wants to play once the last one is back.
  /// - `out` on anyone ("Don't wait for Bob"): not waited for, not
  ///   watching; its player stays at its spot.
  /// - `afk`, only oneself: an automatic out, never while playing nor on a
  ///   BRB member.
  /// - `in`, only oneself: back from BRB (feed `back`), or from AFK or out
  ///   (feed `in`, loading at the current moment).
  /// Returns [ErrCode.forbidden] for `in` or `afk` on someone else, else
  /// null (no-ops and unknown targets included).
  ErrCode? applyPresence(String actorToken, String targetId, Presence state,
      {PresenceReason reason = PresenceReason.manual, bool resume = false}) {
    final actor = members[actorToken];
    if (actor == null) return null;
    _seen(actor);
    final target = targetId.isEmpty ? actor : byId(targetId);
    if (target == null) return null;
    final self = identical(actor, target);
    if ((state == Presence.watching || state == Presence.afk) && !self) return ErrCode.forbidden;
    final was = target.presence;
    if (was == state) return null;
    switch (state) {
      case Presence.brb:
        final first = brbs.isEmpty;
        _set(target, Presence.brb);
        if (was.isOut) target.loading = media != null;
        if (self && resume && first) wantsPlay = true;
        _holdNow();
        feed.add(_line('brb', actor: actor, target: self ? null : target));
      case Presence.out:
        _set(target, Presence.out);
        feed.add(_line('out', actor: actor, target: self ? null : target, reason: _why(reason)));
      case Presence.afk:
        if (was != Presence.watching || transport == Transport.playing) return null;
        _set(target, Presence.afk);
        feed.add(_line('afk', actor: actor));
      case Presence.watching:
        _set(target, Presence.watching);
        if (was.isOut) {
          target.loading = media != null;
          feed.add(_line('in', actor: actor));
        } else {
          feed.add(_line('back', actor: actor));
        }
    }
    evaluate();
    return null;
  }

  String _why(PresenceReason r) => r == PresenceReason.manual ? '' : r.wire;

  void _set(EngineMember m, Presence p) {
    m
      ..presence = p
      ..since = now;
  }

  /// `continue` from [actorToken]: without [targetId] (a member id), or,
  /// when empty, without everyone the group waits for, and then it plays.
  /// A BRB member becomes `out` (reason `continue`); someone whose video
  /// holds the group stays `in` and catches up ([EngineMember.skipped]).
  /// Continuing without everyone also brings the actor back from its own
  /// BRB.
  void applyContinue(String actorToken, {String targetId = ''}) {
    final actor = members[actorToken];
    if (actor == null) return;
    _seen(actor);
    final need = requiredBufferSecs();
    bool videoWaited(EngineMember m) => videoCounts(m) && (m.loading || m.buffered < need);
    void without(EngineMember m) {
      if (m.presence == Presence.brb) {
        if (identical(m, actor) && targetId.isEmpty) {
          _set(m, Presence.watching);
          return;
        }
        _set(m, Presence.out);
      } else if (videoWaited(m)) {
        m
          ..skipped = true
          ..loading = true;
      }
    }

    if (targetId.isNotEmpty) {
      final target = byId(targetId);
      if (target == null) return;
      without(target);
      feed.add(_line('continue', actor: actor, target: target));
    } else {
      for (final m in members.values) {
        without(m);
      }
      wantsPlay = true;
      feed.add(_line('continue', actor: actor));
    }
    evaluate();
  }

  void applySeek(String token, double seekPosition, {int seq = 0}) {
    final member = members[token];
    if (member == null) return;
    if (!seekPosition.isFinite || seekPosition < 0) return;
    _seen(member);
    if (live) {
      _liveSeek(member, seekPosition, seq);
      return;
    }
    position = seekPosition;
    serverTime = now;
    eventId++;
    _seekBy = member.id;
    _seekSeq = seq;
    _seekEventId = eventId;
    // Where a dropped member was says nothing about what it missed now.
    for (final m in members.values) {
      m.droppedAt = null;
    }
    feed.add(_line('seek', actor: member));
    // A seek stops the countdown to Up next.
    advance = null;
    // Seeking back from the end: held, and plays again when it wants to.
    if (transport == Transport.finished) {
      transport = Transport.held;
      evaluate();
    }
  }

  /// Returns false (no state change) for media with non-finite numbers.
  /// [queueId]: the Up next item this swap puts up; it leaves the queue
  /// (any other swap drops the continuation item, [EngineQueue.auto]).
  /// [restore]: what played before a restart, put back where it was (the
  /// server takes it only while nothing is up; see `swap.restore`): held
  /// at its position, wanting to play when it played, or finished.
  /// Everyone keeps their standing and the group its wish.
  bool applySwap(String actorToken, HelloMedia next, {String? queueId, SwapRestore? restore}) {
    if (!next.duration.isFinite || next.size < 0) return false;
    final actor = members[actorToken];
    queue.swapped(queueId);
    advance = null;
    _advancedId = null;
    mediaId++;
    media = next;
    swapBy = actorToken;
    poster = null;
    banner = null;
    position = 0;
    serverTime = now;
    eventId++;
    transport = Transport.held;
    for (final member in members.values) {
      member
        ..error = ''
        ..buffered = 0
        ..skipped = false
        ..spot = null
        ..droppedAt = null
        ..liveEdge = 0
        ..liveEnd = null
        ..liveFrom = 0;
    }
    behind = 0;
    _liveSeekAt = null;
    // A live stream restored after a restart starts from a fresh live
    // point (the players' next reports).
    if (restore != null && !next.live) {
      final d = next.duration;
      position = restore.position < 0 ? 0 : (d > 0 && restore.position > d ? d : restore.position);
      if (restore.transport == 'finished' && d > 0) {
        position = d;
        transport = Transport.finished;
      }
      if (restore.transport == 'playing') wantsPlay = true;
    }
    feed.add(_line('swap', actor: actor, reason: restore == null ? '' : 'restore'));
    evaluate();
    return true;
  }

  /// [edge]: a live stream's edge as the member's player sees it
  /// (`report.edge`); with it, [reportPosition] is in stream time and a
  /// [duration] says the player reached the stream's end there.
  void applyReport(String token, double reportPosition, double buffered, int reportEventId,
      {double duration = 0,
      int mediaId = 0,
      Map<String, bool>? jf,
      String error = '',
      double edge = 0,
      double from = 0}) {
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
    if (!earlier && reportEventId >= eventId) member.spot = reportPosition;
    final m = media;
    final liveNow = m != null && mediaId == this.mediaId && edge.isFinite && edge > 0;
    if (liveNow && !m.live) {
      // A player found it live (its length keeps growing): from now on it
      // is, with a live point set from the reports.
      media = m.copyWith(live: true, duration: 0);
      position = 0;
      serverTime = now;
      eventId++;
      transport = Transport.held;
    }
    if (live) {
      if (mediaId == this.mediaId && (liveNow || duration > 0)) {
        member.liveFrom = from.isFinite && from > 0 ? from : 0;
        _liveReport(member, reportPosition, edge, duration.isFinite ? duration : 0);
        if (member.loading && !member.presence.isOut && liveNow) _caughtUp(member);
      }
      if (member.loading && member.error.isNotEmpty) {
        member
          ..loading = false
          ..skipped = false
          ..droppedAt = null;
      }
      evaluate();
      return;
    }
    // First report of the length wins; only for the media the client has open.
    if (m != null && m.duration <= 0 && mediaId == this.mediaId &&
        duration.isFinite && duration > 0) {
      media = m.copyWith(duration: duration);
    }
    if (member.loading && !member.presence.isOut) {
      // Loading ends when it cannot open the media (it is not waited for
      // by its error), or once it holds the media at the server's
      // position with the buffer the gate needs: it comes in in sync.
      final t = now;
      if (member.error.isNotEmpty) {
        member
          ..loading = false
          ..skipped = false
          ..droppedAt = null;
      } else if (!earlier &&
          reportEventId >= eventId &&
          (reportPosition - positionAt(t)).abs() <= RelayConstants.driftSeekThresholdSecs &&
          member.buffered >= requiredBufferSecs(t)) {
        _caughtUp(member);
      }
    }
    if (reportEventId < eventId) return;
    evaluate();
  }

  /// A live report of [member]: its player at [pos] with the stream's edge
  /// at [edge] (stream time), or at its end at [ended]. The first one sets
  /// the group's live point: halfway from that player's position to its
  /// edge (a player opens a live stream six segments behind its edge, so
  /// that is three segments, where players play a live stream by
  /// default), [RelayConstants.liveMarginSecs] further back; behind its
  /// edge when it plays far from it (a stitched ad). It is set again when
  /// it runs past every member's edge (the stream stalled or started over)
  /// or far behind it (its clock jumped ahead).
  void _liveReport(EngineMember member, double pos, double edge, double ended) {
    if (ended > 0) {
      member.liveEnd = ended;
    } else {
      member.liveEnd = null;
      member.liveEdge = edge;
    }
    if (edge <= 0) return;
    final lag = edge - pos;
    final back = lag >= 0 && lag <= RelayConstants.liveMaxLagSecs ? lag / 2 : RelayConstants.liveFallbackLagSecs;
    final point = edge - back - RelayConstants.liveMarginSecs;
    final t = now;
    if (transport == Transport.held) {
      _setLivePoint(point, t);
      return;
    }
    if (transport != Transport.playing) return;
    // Just moved by a seek: the players are still opening the stream at the
    // new point (their edges say where they were).
    final seekAt = _liveSeekAt;
    if (seekAt != null && t.difference(seekAt).inMilliseconds < RelayConstants.liveSeekSettleSecs * 1000) return;
    var top = 0.0;
    for (final m in members.values) {
      if (!m.gone && m.liveEdge > top) top = m.liveEdge;
    }
    // Stalled: the group's point is past what any player has. A jump: the
    // live point (where the group would be without a rewind) far behind it.
    final g = positionAt(t);
    if (g > top + RelayConstants.liveStallSecs || g + behind < top - 2 * RelayConstants.liveMaxLagSecs) {
      _setLivePoint(point, t);
    }
  }

  void _setLivePoint(double point, DateTime t) {
    position = point < 0 ? 0 : point;
    serverTime = t;
    eventId++;
    transport = Transport.playing;
    behind = 0;
    // The group watches it; what comes after it plays on.
    wantsPlay = true;
  }

  /// The live point now: where the group's point would be without a
  /// rewind.
  double liveTop([DateTime? at]) => positionAt(at) + behind;

  /// The oldest moment of the live stream every member watching it can
  /// rewind to (the latest of their `report.from`), stream time; 0 when
  /// one of them cannot rewind, or the span up to the live point is under
  /// [RelayConstants.liveMinWindowSecs].
  double liveFrom([DateTime? at]) {
    if (!live || transport != Transport.playing) return 0;
    var from = 0.0;
    var any = false;
    for (final m in members.values) {
      if (m.gone || m.presence.isOut || m.liveEdge <= 0) continue;
      if (m.liveFrom <= 0) return 0;
      any = true;
      if (m.liveFrom > from) from = m.liveFrom;
    }
    if (!any || liveTop(at) - from < RelayConstants.liveMinWindowSecs) return 0;
    return from;
  }

  /// A seek over a live stream: within what every member can rewind to
  /// ([liveFrom]) the group's point moves there and runs on at 1x behind
  /// the live point; at or past the live point it goes back to it (Go
  /// live, which needs no window).
  void _liveSeek(EngineMember member, double target, int seq) {
    if (transport != Transport.playing) return;
    final t = now;
    final top = liveTop(t);
    final String reason;
    if (target >= top - 1) {
      if (behind <= 0) return;
      position = top;
      behind = 0;
      reason = 'live';
    } else {
      final from = liveFrom(t);
      if (from <= 0) return;
      position = target < from ? from : target;
      behind = top - position;
      reason = '';
    }
    serverTime = t;
    eventId++;
    _liveSeekAt = t;
    _seekBy = member.id;
    _seekSeq = seq;
    _seekEventId = eventId;
    feed.add(_line('seek', actor: member, reason: reason));
  }

  /// A live stream ends once a member's player reached its end and nobody
  /// else's still sees it go on past there (one player losing the stream
  /// is not the end); what comes next goes up at once (no countdown:
  /// nobody knew the end was near).
  void _liveEnd(DateTime t) {
    if (transport != Transport.playing) return;
    double? end;
    for (final m in members.values) {
      final e = m.liveEnd;
      if (!m.gone && e != null && (end == null || e > end)) end = e;
    }
    if (end == null) return;
    for (final m in members.values) {
      if (!m.gone && m.liveEnd == null && m.liveEdge > end + RelayConstants.liveStallSecs) return;
    }
    position = end;
    serverTime = t;
    eventId++;
    transport = Transport.finished;
    final first = queue.items.firstOrNull;
    if (first != null && queue.play == null && _advanceOffFor != mediaId) {
      advance = QueueAdvance(
          id: first.id,
          at: t.subtract(const Duration(seconds: RelayConstants.advanceSecs)),
          secs: RelayConstants.advanceSecs);
    }
    feed.add(_line('finished'));
    whatsNext();
  }

  /// An error means the group stops waiting for its video; clearing it
  /// waits for its video again.
  void _setError(EngineMember member, String error) {
    if (member.error == error) return;
    member.error = error;
    evaluate();
  }

  /// The gate: while playing, the end of the media finishes it and a
  /// watched video short of the buffer holds it (feed `pause` by the
  /// server); while held, it plays when it wants to, nobody is BRB, and
  /// every watched video has the buffer (feed `resume` by the server,
  /// unless [quiet]: a member's `play` said it already).
  void evaluate({bool quiet = false}) {
    final t = now;
    if (transport == Transport.finished) return;
    if (live) {
      _liveEnd(t);
      return;
    }
    final need = requiredBufferSecs(t);
    if (transport == Transport.playing) {
      final d = duration;
      if (d != null && positionAt(t) >= d) {
        position = d;
        serverTime = t;
        eventId++;
        transport = Transport.finished;
        // A countdown that ran to the end: what comes next goes up now.
        final a = advance;
        if (a != null) advance = QueueAdvance(id: a.id, at: t.subtract(Duration(seconds: a.secs)), secs: a.secs);
        feed.add(_line('finished'));
        whatsNext();
        return;
      }
      final blocked = brbs.isNotEmpty || members.values.any((m) => videoCounts(m) && m.buffered < need);
      if (blocked) {
        _holdNow();
        feed.add(_line('pause'));
      }
      return;
    }
    if (!wantsPlay || brbs.isNotEmpty) return;
    final watched = members.values.where(videoCounts).toList();
    if (watched.isEmpty) return;
    if (watched.every((m) => m.buffered >= need)) {
      serverTime = t;
      eventId++;
      transport = Transport.playing;
      if (!quiet) feed.add(_line('resume'));
    }
  }

  /// `state.hold` while HELD with media up: who the group waits for
  /// ([HoldInfo]); null when nobody is. [sourceGone]: the current media's
  /// relay source is `gone` (the short buffers are its doing).
  HoldInfo? holdInfo({bool sourceGone = false}) {
    if (transport != Transport.held || media == null || live) return null;
    final need = requiredBufferSecs();
    final brb = [for (final m in brbs) m.id];
    final video = !wantsPlay
        ? const <String>[]
        : [
            for (final m in members.values)
              if (videoCounts(m) && (m.loading || m.buffered < need)) m.id,
          ];
    final h = HoldInfo(brb: brb, video: video, source: sourceGone && video.isNotEmpty);
    return h.isEmpty ? null : h;
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
      members: [for (final m in members.values) m.view()],
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
      wantsPlay: wantsPlay,
      queuePass: queuePass,
      liveFrom: liveFrom(),
      behind: live && transport == Transport.playing ? behind : 0,
    );
  }
}
