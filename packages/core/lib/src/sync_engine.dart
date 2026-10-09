import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'constants.dart';
import 'protocol.dart';

typedef SyncClock = DateTime Function();

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
  String name;
  /// Picture bytes, served at `/a/...`; only [avatarHash] is broadcast.
  Uint8List? avatarBytes;
  String avatarHash = '';
  bool ready = false;
  bool inSet = false;
  double buffered = 0;
  /// Last reported Jellyfin access by ServerId (`report.jf`).
  Map<String, bool> jf = const {};
  /// The hosting app's own member (set by the server from the host key).
  bool host = false;
  DateTime lastSeen;
  EngineMember({
    required this.id,
    required this.token,
    required this.name,
    String avatar = '',
    required DateTime now,
  }) : lastSeen = now {
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

  MemberView view({required bool stale}) => MemberView(
        id: id,
        name: name,
        avatarHash: avatarHash,
        ready: ready,
        inSet: inSet,
        buffered: buffered,
        stale: stale,
        jf: jf,
        host: host,
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
  /// Token of the member who made the current swap; null before any swap.
  String? swapBy;
  /// Art of the current media (`art`), served at `/i/...`; only the hashes
  /// ride in `state.media.art`. Every swap clears it.
  ArtImage? poster;
  ArtImage? banner;
  int _nextId = 1;
  // Who sent the seek that produced [_seekEventId], for the echo check.
  String? _seekBy;
  int _seekSeq = 0;
  int _seekEventId = -1;

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

  /// Any frame from a member: fresh again. Back in the set: a ready member
  /// the stale sweep (or a swap while it was stale) took out (ready &&
  /// !inSet only arises from those), and any member back from stale while
  /// not playing (like a join then).
  void _seen(EngineMember member) {
    final wasStale = isStale(member);
    member.lastSeen = now;
    if (!member.inSet &&
        (member.ready || (wasStale && transport != Transport.playing))) {
      member.inSet = true;
    }
  }

  /// Heartbeat: stale sweep, end of media.
  void tick() {
    sweepStale();
    evaluate();
  }

  String applyJoin(String token, String name, String avatar) {
    final id = 'm${_nextId++}';
    // Joining while not playing: in the set, so the start waits for them;
    // while playing, out until they ready (a late joiner never pauses).
    members[token] =
        EngineMember(id: id, token: token, name: name, avatar: avatar, now: now)
          ..inSet = transport != Transport.playing;
    feed.add(FeedMessage(actor: name, action: 'join', at: now));
    return id;
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
      feed.add(FeedMessage(actor: name, action: 'rename', target: oldName, at: now));
    } else if (pictured) {
      feed.add(FeedMessage(actor: member.name, action: 'avatar', at: now));
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
    return null;
  }

  /// `state.media.art`; null when there is none.
  Map<String, Object?>? get artJson => poster == null && banner == null
      ? null
      : {
          if (poster != null) 'poster': poster!.hash,
          if (banner != null) 'banner': banner!.hash,
        };

  /// A reconnect took over [token]'s member (see `hello.resume`).
  void applyResume(String token) {
    final member = members[token];
    if (member == null) return;
    _seen(member);
    evaluate();
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
    _seen(member);
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
    feed.add(FeedMessage(actor: member.name, action: 'seek', at: now));
    // Seeking back from the end: held, and resumes once the gate passes.
    if (transport == Transport.finished) {
      transport = Transport.held;
      evaluate();
    }
  }

  /// Returns false (no state change) for media with non-finite numbers.
  bool applySwap(String actorToken, HelloMedia next) {
    if (!next.duration.isFinite || next.size < 0) return false;
    final actor = members[actorToken];
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
    // (a stale member rejoins the set with its next frame if still ready).
    final t = now;
    for (final member in members.values) {
      member.inSet = !isStale(member, t);
      member.buffered = 0;
    }
    feed.add(FeedMessage(actor: actor?.name ?? '?', action: 'swap', at: now));
    return true;
  }

  void applyReport(String token, double reportPosition, double buffered, int reportEventId,
      {double duration = 0, int mediaId = 0, Map<String, bool>? jf}) {
    final member = members[token];
    if (member == null) return;
    if (!reportPosition.isFinite) return;
    _seen(member);
    if (jf != null) member.jf = Map.unmodifiable(jf);
    member.buffered = !buffered.isFinite || buffered < 0 ? 0 : buffered;
    final m = media;
    // First report of the length wins; only for the media the client has open.
    if (m != null && m.duration <= 0 && mediaId == this.mediaId &&
        duration.isFinite && duration > 0) {
      media = m.copyWith(duration: duration);
    }
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
    if (transport == Transport.finished) return;
    final need = requiredBufferSecs(t);
    if (transport == Transport.playing) {
      final d = duration;
      if (d != null && positionAt(t) >= d) {
        position = d;
        serverTime = t;
        eventId++;
        transport = Transport.finished;
        feed.add(FeedMessage(actor: 'server', action: 'finished', at: t));
        return;
      }
      final blocked = members.values
          .where((m) => m.inSet)
          .any((m) => !m.ready || m.buffered < need || isStale(m, t));
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
    final allGood = inSet.every(
        (m) => m.ready && m.buffered >= need && !isStale(m, t));
    if (allGood) {
      serverTime = t;
      eventId++;
      transport = Transport.playing;
      feed.add(FeedMessage(actor: 'server', action: 'resume', at: t));
    }
  }

  /// [relay]: whether the server can relay the current Jellyfin media; the
  /// engine does not know the server's credential.
  StateBroadcast broadcast({bool relay = false}) {
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
      members: members.values.map((m) => m.view(stale: isStale(m))).toList(),
      seekBy: bySeek ? _seekBy : null,
      seekSeq: bySeek ? _seekSeq : null,
      relay: relay,
    );
  }
}
