import 'constants.dart';
import 'errors.dart';

/// Reads an optional JSON number as a finite double. JSON like 1e400 decodes to
/// Infinity, which would later break jsonEncode on every broadcast.
double finiteDouble(Object? value, String field, {double fallback = 0.0}) {
  if (value == null) return fallback;
  final d = (value as num).toDouble();
  if (!d.isFinite) throw ProtocolException('$field must be finite');
  return d;
}

/// Same as [finiteDouble] but for integers.
int finiteInt(Object? value, String field, {int fallback = 0}) {
  if (value == null) return fallback;
  final n = value as num;
  if (!n.isFinite) throw ProtocolException('$field must be finite');
  return n.toInt();
}

/// A member name as shown to everyone: trimmed, cut to
/// [RelayConstants.maxNameLength], `?` when empty.
String cleanMemberName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.substring(0, trimmed.length.clamp(0, RelayConstants.maxNameLength));
}

class HelloUser {
  final String name;
  final String avatar;
  const HelloUser({required this.name, this.avatar = ''});

  Map<String, Object?> toJson() => {'name': name, 'avatar': avatar};

  factory HelloUser.fromJson(Map<String, Object?> json) =>
      HelloUser(name: (json['name'] as String?) ?? '', avatar: (json['avatar'] as String?) ?? '');
}

/// A Jellyfin item the session plays, by reference: each viewer resolves it
/// with its own account (or through the server's relay). Never carries a URL
/// or a token.
class JellyfinRef {
  /// Jellyfin `ServerId` (`/System/Info/Public`), the key accounts are stored by.
  final String serverId;
  final String itemId;
  final String? mediaSourceId;
  /// Display text: item name, and e.g. "Show - S01E02" for episodes.
  final String title;
  final String? subtitle;
  /// Length from Jellyfin's RunTimeTicks, informational; the sync clock
  /// still uses the length a client reports.
  final double? runtimeSecs;
  const JellyfinRef({
    required this.serverId,
    required this.itemId,
    this.mediaSourceId,
    this.title = '',
    this.subtitle,
    this.runtimeSecs,
  });

  Map<String, Object?> toJson() => {
        'serverId': serverId,
        'itemId': itemId,
        if (mediaSourceId != null) 'mediaSourceId': mediaSourceId,
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        if (runtimeSecs != null) 'runtimeSecs': runtimeSecs,
      };

  factory JellyfinRef.fromJson(Map<String, Object?> json) {
    final runtime = json['runtimeSecs'];
    return JellyfinRef(
      serverId: (json['serverId'] as String?) ?? '',
      itemId: (json['itemId'] as String?) ?? '',
      mediaSourceId: json['mediaSourceId'] as String?,
      title: (json['title'] as String?) ?? '',
      subtitle: json['subtitle'] as String?,
      runtimeSecs: runtime == null ? null : finiteDouble(runtime, 'runtimeSecs'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JellyfinRef &&
      other.serverId == serverId &&
      other.itemId == itemId &&
      other.mediaSourceId == mediaSourceId &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.runtimeSecs == runtimeSecs;

  @override
  int get hashCode =>
      Object.hash(serverId, itemId, mediaSourceId, title, subtitle, runtimeSecs);
}

class HelloMedia {
  final String name;
  final int size;
  final double duration;
  final String? url;
  /// Set for Jellyfin media; then there is no [url] (the server drops one).
  final JellyfinRef? jellyfin;
  /// Relayed media (bytes from the source member through the server).
  final MediaRelay? relay;
  const HelloMedia(
      {required this.name,
      required this.size,
      required this.duration,
      this.url,
      this.jellyfin,
      this.relay});

  HelloMedia copyWith({double? duration, int? size, MediaRelay? relay}) => HelloMedia(
      name: name,
      size: size ?? this.size,
      duration: duration ?? this.duration,
      url: url,
      jellyfin: jellyfin,
      relay: relay ?? this.relay);

  Map<String, Object?> toJson() => {
        'name': name,
        'size': size,
        'duration': duration,
        if (url != null) 'url': url,
        if (jellyfin != null) 'jellyfin': jellyfin!.toJson(),
        if (relay != null) 'relay': relay!.toJson(),
      };

  factory HelloMedia.fromJson(Map<String, Object?> json) {
    final jf = json['jellyfin'];
    final relay = json['relay'];
    return HelloMedia(
      name: (json['name'] as String?) ?? '',
      size: finiteInt(json['size'], 'size', fallback: 0),
      duration: finiteDouble(json['duration'], 'duration'),
      url: json['url'] as String?,
      jellyfin: jf is Map ? JellyfinRef.fromJson(Map<String, Object?>.from(jf)) : null,
      relay: relay is Map ? MediaRelay.fromJson(Map<String, Object?>.from(relay)) : null,
    );
  }
}

/// Relayed media: the bytes go through the server's buffer (`/r/...`).
/// Either from the [source] member's machine (it dials the relay channel),
/// or, with [fetch], the server reads the swap's link itself. A swap sends
/// `{}` or `{"fetch":true}`; the server fills in [source] (the swapper's
/// member id, empty with [fetch]) and whether bytes can flow ([live]).
class MediaRelay {
  final String source;
  final bool fetch;
  final bool live;
  const MediaRelay({this.source = '', this.fetch = false, this.live = false});

  MediaRelay copyWith({bool? live}) => MediaRelay(source: source, fetch: fetch, live: live ?? this.live);

  Map<String, Object?> toJson() => {
        if (source.isNotEmpty) 'source': source,
        if (fetch) 'fetch': true,
        if (live) 'live': true,
      };

  factory MediaRelay.fromJson(Map<String, Object?> json) => MediaRelay(
      source: json['source'] is String ? json['source'] as String : '',
      fetch: json['fetch'] == true,
      live: json['live'] == true);
}

class HelloMessage {
  final int proto;
  final String secret;
  final HelloUser user;
  final HelloMedia media;
  /// The hosting app's own client proves it is the host with this; empty
  /// for everyone else.
  final String hostKey;
  /// Token from this client's previous `welcome`, sent on reconnect: if the
  /// server still has that member (an unclean drop it has not noticed), the
  /// connection takes it over instead of leaving a ghost.
  final String resume;
  const HelloMessage(
      {required this.proto,
      required this.secret,
      required this.user,
      required this.media,
      this.hostKey = '',
      this.resume = ''});

  Map<String, Object?> toJson() => {
        't': 'hello',
        'proto': proto,
        'secret': secret,
        'user': user.toJson(),
        'media': media.toJson(),
        if (hostKey.isNotEmpty) 'hostKey': hostKey,
        if (resume.isNotEmpty) 'resume': resume,
      };

  factory HelloMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'hello') throw const ProtocolException('not a hello message');
    final user = json['user'];
    final media = json['media'];
    if (user is! Map || media is! Map) throw const ProtocolException('hello missing user/media');
    return HelloMessage(
      proto: finiteInt(json['proto'], 'proto', fallback: RelayConstants.protoVersion),
      secret: (json['secret'] as String?) ?? '',
      user: HelloUser.fromJson(Map<String, Object?>.from(user)),
      media: HelloMedia.fromJson(Map<String, Object?>.from(media)),
      hostKey: (json['hostKey'] as String?) ?? '',
      resume: (json['resume'] as String?) ?? '',
    );
  }
}

class SyncState {
  final double position;
  final bool paused;
  final int mediaId;
  final DateTime serverTime;
  const SyncState({required this.position, required this.paused, required this.mediaId, required this.serverTime});

  Map<String, Object?> toJson() => {
        'position': position,
        'paused': paused,
        'mediaId': mediaId,
        'serverTime': serverTime.toIso8601String(),
      };

  factory SyncState.fromJson(Map<String, Object?> json) => SyncState(
        position: finiteDouble(json['position'], 'position'),
        paused: (json['paused'] as bool?) ?? true,
        mediaId: finiteInt(json['mediaId'], 'mediaId', fallback: 0),
        serverTime: DateTime.tryParse('${json['serverTime']}') ?? DateTime.now().toUtc(),
      );
}

class WelcomeMessage {
  final String token;
  final String memberId;
  final String? mediaUrl;
  /// This member's `/j/...` URL for the current Jellyfin media when the
  /// server can relay it (`state.relay`); private like [token].
  final String? relayUrl;
  final Map<String, Object?>? state;
  const WelcomeMessage(
      {required this.token, this.memberId = '', this.mediaUrl, this.relayUrl, this.state});

  Map<String, Object?> toJson() => {
        't': 'welcome',
        'token': token,
        'memberId': memberId,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        if (relayUrl != null) 'relayUrl': relayUrl,
        if (state != null) 'state': state,
      };

  factory WelcomeMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'welcome') throw const ProtocolException('not a welcome message');
    final state = json['state'];
    return WelcomeMessage(
      token: (json['token'] as String?) ?? '',
      memberId: (json['memberId'] as String?) ?? '',
      mediaUrl: json['mediaUrl'] as String?,
      relayUrl: json['relayUrl'] as String?,
      state: state is Map ? Map<String, Object?>.from(state) : null,
    );
  }
}

class KickedMessage {
  final String reason;
  const KickedMessage({this.reason = ''});

  Map<String, Object?> toJson() => {'t': 'kicked', 'reason': reason};

  factory KickedMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'kicked') throw const ProtocolException('not a kicked message');
    return KickedMessage(reason: (json['reason'] as String?) ?? '');
  }
}

class KickRequest {
  final String target;
  final String reason;
  const KickRequest({required this.target, this.reason = ''});

  Map<String, Object?> toJson() => {'t': 'kick', 'target': target, 'reason': reason};

  factory KickRequest.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'kick') throw const ProtocolException('not a kick request');
    return KickRequest(
      target: (json['target'] as String?) ?? '',
      reason: (json['reason'] as String?) ?? '',
    );
  }
}

class ReadyIntent {
  final bool ready;
  final String source;
  const ReadyIntent({required this.ready, this.source = 'manual'});

  Map<String, Object?> toJson() => {'t': 'ready', 'ready': ready, 'source': source};

  factory ReadyIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'ready') throw const ProtocolException('not a ready intent');
    return ReadyIntent(
      ready: (json['ready'] as bool?) ?? false,
      source: (json['source'] as String?) ?? 'manual',
    );
  }
}

class ForceIntent {
  final String target;
  final bool ready;
  const ForceIntent({required this.target, required this.ready});

  Map<String, Object?> toJson() => {'t': 'force', 'target': target, 'ready': ready};

  factory ForceIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'force') throw const ProtocolException('not a force intent');
    return ForceIntent(
      target: (json['target'] as String?) ?? '',
      ready: (json['ready'] as bool?) ?? false,
    );
  }
}

class SeekIntent {
  final double position;
  /// Client-chosen, increasing per connection; echoed in `state.seekSeq` so
  /// the sender recognises its own seek.
  final int seq;
  const SeekIntent({required this.position, this.seq = 0});

  Map<String, Object?> toJson() =>
      {'t': 'seek', 'position': position, if (seq != 0) 'seq': seq};

  factory SeekIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'seek') throw const ProtocolException('not a seek intent');
    return SeekIntent(
        position: finiteDouble(json['position'], 'position'),
        seq: finiteInt(json['seq'], 'seq'));
  }
}

class SwapIntent {
  final HelloMedia media;
  const SwapIntent({required this.media});

  Map<String, Object?> toJson() => {'t': 'swap', 'media': media.toJson()};

  factory SwapIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'swap') throw const ProtocolException('not a swap intent');
    final media = json['media'];
    if (media is! Map) throw const ProtocolException('swap missing media');
    return SwapIntent(media: HelloMedia.fromJson(Map<String, Object?>.from(media)));
  }
}

class ReportMessage {
  final double position;
  final double buffered;
  final int eventId;
  /// Length of the open media in seconds, 0 while unknown.
  final double duration;
  /// The `mediaId` the client has open; [duration] belongs to it.
  final int mediaId;
  /// Jellyfin access by `ServerId`: true = plays with its own account,
  /// false = through the server's relay. Null leaves the last one in place.
  final Map<String, bool>? jf;
  const ReportMessage(
      {required this.position,
      required this.buffered,
      required this.eventId,
      this.duration = 0,
      this.mediaId = 0,
      this.jf});

  Map<String, Object?> toJson() => {
        't': 'report',
        'position': position,
        'buffered': buffered,
        'eventId': eventId,
        if (duration > 0) 'duration': duration,
        if (mediaId != 0) 'mediaId': mediaId,
        if (jf != null) 'jf': jf,
      };

  factory ReportMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'report') throw const ProtocolException('not a report');
    return ReportMessage(
      position: finiteDouble(json['position'], 'position'),
      buffered: finiteDouble(json['buffered'], 'buffered'),
      eventId: finiteInt(json['eventId'], 'eventId', fallback: 0),
      duration: finiteDouble(json['duration'], 'duration'),
      mediaId: finiteInt(json['mediaId'], 'mediaId'),
      jf: jfAccessFromJson(json['jf']),
    );
  }
}

/// Reads a `jf` map (`{serverId: bool}`), dropping non-bool entries and
/// keys over 64 characters, at most 8 entries (it rides in every `state`);
/// null when absent or not a map.
Map<String, bool>? jfAccessFromJson(Object? value) {
  if (value is! Map) return null;
  final out = <String, bool>{};
  for (final e in value.entries) {
    if (out.length >= 8) break;
    final k = e.key;
    if (k is String && k.length <= 64 && e.value is bool) out[k] = e.value as bool;
  }
  return out;
}

/// Clock probe: the client sends its own clock in [clientMs]; the server
/// answers with a [PongMessage] carrying it back plus its clock.
class PingMessage {
  final int clientMs;
  const PingMessage({required this.clientMs});

  Map<String, Object?> toJson() => {'t': 'ping', 'c': clientMs};

  factory PingMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'ping') throw const ProtocolException('not a ping');
    return PingMessage(clientMs: finiteInt(json['c'], 'c'));
  }
}

class PongMessage {
  final int clientMs;
  final int serverMs;
  const PongMessage({required this.clientMs, required this.serverMs});

  Map<String, Object?> toJson() => {'t': 'pong', 'c': clientMs, 's': serverMs};

  factory PongMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'pong') throw const ProtocolException('not a pong');
    return PongMessage(
        clientMs: finiteInt(json['c'], 'c'), serverMs: finiteInt(json['s'], 's'));
  }
}

class ChatMessage {
  final String text;
  const ChatMessage({required this.text});

  Map<String, Object?> toJson() => {'t': 'chat', 'text': text};

  factory ChatMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'chat') throw const ProtocolException('not a chat message');
    return ChatMessage(text: (json['text'] as String?) ?? '');
  }
}

/// Changes this member's name and/or picture mid-session. Null fields stay
/// as they are; an empty [avatar] removes the picture.
class ProfileIntent {
  final String? name;
  /// Base64 PNG, like `hello.user.avatar`.
  final String? avatar;
  const ProfileIntent({this.name, this.avatar});

  Map<String, Object?> toJson() => {
        't': 'profile',
        if (name != null) 'name': name,
        if (avatar != null) 'avatar': avatar,
      };

  factory ProfileIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'profile') throw const ProtocolException('not a profile intent');
    return ProfileIntent(name: json['name'] as String?, avatar: json['avatar'] as String?);
  }
}

/// Cover art for the current media, sent by the member who swapped it in
/// (or the host). Base64 picture bytes; null = none.
class ArtMessage {
  final int mediaId;
  final String? poster;
  final String? banner;
  const ArtMessage({required this.mediaId, this.poster, this.banner});

  Map<String, Object?> toJson() => {
        't': 'art',
        'mediaId': mediaId,
        if (poster != null) 'poster': poster,
        if (banner != null) 'banner': banner,
      };

  factory ArtMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'art') throw const ProtocolException('not an art message');
    final poster = json['poster'];
    final banner = json['banner'];
    return ArtMessage(
        mediaId: finiteInt(json['mediaId'], 'mediaId'),
        poster: poster is String ? poster : null,
        banner: banner is String ? banner : null);
  }
}

class MemberView {
  final String id;
  final String name;
  /// Content hash of the member's picture, fetched at `/a/...`; empty when
  /// none.
  final String avatarHash;
  final bool ready;
  final bool inSet;
  final double buffered;
  final bool stale;
  /// Last `report.jf` of this member; empty when never reported.
  final Map<String, bool> jf;
  /// The hosting app's own member (sent the server's host key).
  final bool host;
  const MemberView({
    required this.id,
    required this.name,
    this.avatarHash = '',
    required this.ready,
    required this.inSet,
    required this.buffered,
    required this.stale,
    this.jf = const {},
    this.host = false,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        if (avatarHash.isNotEmpty) 'avatarHash': avatarHash,
        'ready': ready,
        'inSet': inSet,
        'buffered': buffered,
        'stale': stale,
        if (jf.isNotEmpty) 'jf': jf,
        if (host) 'host': true,
      };

  factory MemberView.fromJson(Map<String, Object?> json) => MemberView(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        avatarHash: (json['avatarHash'] as String?) ?? '',
        ready: (json['ready'] as bool?) ?? false,
        inSet: (json['inSet'] as bool?) ?? false,
        buffered: finiteDouble(json['buffered'], 'buffered'),
        stale: (json['stale'] as bool?) ?? false,
        jf: jfAccessFromJson(json['jf']) ?? const {},
        host: json['host'] == true,
      );
}

class StateBroadcast {
  /// Buffer an in-set member needs before playback can go on, as the
  /// server's gate counts it: [RelayConstants.minBufferSecs], less near the
  /// end (mpv cannot buffer past it), none once finished.
  double get bufferNeed {
    if (transport == 'finished') return 0;
    final d = (media?['duration'] as num?)?.toDouble() ?? 0;
    const full = RelayConstants.minBufferSecs;
    if (d <= 0) return full;
    return (d - position - RelayConstants.endSlackSecs).clamp(0.0, full).toDouble();
  }

  final int eventId;
  final String transport;
  final double position;
  final DateTime serverTime;
  final int mediaId;
  final Map<String, Object?>? media;
  final List<MemberView> members;
  /// Member id and seq of the seek that made [eventId]; null when the
  /// current event is not a seek.
  final String? seekBy;
  final int? seekSeq;
  /// The server can relay the current Jellyfin media (`/j/...`) for viewers
  /// without their own access to it.
  final bool relay;
  const StateBroadcast({
    required this.eventId,
    required this.transport,
    required this.position,
    required this.serverTime,
    required this.mediaId,
    this.media,
    required this.members,
    this.seekBy,
    this.seekSeq,
    this.relay = false,
  });

  Map<String, Object?> toJson() => {
        't': 'state',
        'eventId': eventId,
        'transport': transport,
        'position': position,
        'serverTime': serverTime.toIso8601String(),
        'mediaId': mediaId,
        if (media != null) 'media': media,
        'members': members.map((m) => m.toJson()).toList(),
        if (seekBy != null) 'seekBy': seekBy,
        if (seekSeq != null) 'seekSeq': seekSeq,
        if (relay) 'relay': true,
      };

  factory StateBroadcast.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'state') throw const ProtocolException('not a state broadcast');
    final members = json['members'];
    final media = json['media'];
    return StateBroadcast(
      eventId: finiteInt(json['eventId'], 'eventId', fallback: 0),
      transport: (json['transport'] as String?) ?? 'held',
      position: finiteDouble(json['position'], 'position'),
      serverTime: DateTime.tryParse('${json['serverTime']}') ?? DateTime.now().toUtc(),
      mediaId: finiteInt(json['mediaId'], 'mediaId', fallback: 0),
      media: media is Map ? Map<String, Object?>.from(media) : null,
      members: members is List
          ? members
              .whereType<Map>()
              .map((m) => MemberView.fromJson(Map<String, Object?>.from(m)))
              .toList()
          : const [],
      seekBy: json['seekBy'] as String?,
      seekSeq: json['seekSeq'] == null ? null : finiteInt(json['seekSeq'], 'seekSeq'),
      relay: (json['relay'] as bool?) ?? false,
    );
  }
}

class FeedMessage {
  final String actor;
  final String action;
  final String? target;
  final String reason;
  final DateTime at;
  const FeedMessage({
    required this.actor,
    required this.action,
    this.target,
    this.reason = '',
    required this.at,
  });

  Map<String, Object?> toJson() => {
        't': 'feed',
        'actor': actor,
        'action': action,
        if (target != null) 'target': target,
        'reason': reason,
        'at': at.toIso8601String(),
      };

  factory FeedMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'feed') throw const ProtocolException('not a feed message');
    return FeedMessage(
      actor: (json['actor'] as String?) ?? '',
      action: (json['action'] as String?) ?? '',
      target: json['target'] as String?,
      reason: (json['reason'] as String?) ?? '',
      at: DateTime.tryParse('${json['at']}') ?? DateTime.now().toUtc(),
    );
  }
}

class SyncEvent {  final String kind;
  final double position;
  final bool doSeek;
  final int ignoringOnTheFly;
  const SyncEvent({required this.kind, required this.position, this.doSeek = false, this.ignoringOnTheFly = 0});

  Map<String, Object?> toJson() => {
        't': 'event',
        'kind': kind,
        'position': position,
        'doSeek': doSeek,
        'ignoringOnTheFly': ignoringOnTheFly,
      };

  factory SyncEvent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'event') throw const ProtocolException('not an event message');
    return SyncEvent(
      kind: (json['kind'] as String?) ?? '',
      position: finiteDouble(json['position'], 'position'),
      doSeek: (json['doSeek'] as bool?) ?? false,
      ignoringOnTheFly: finiteInt(json['ignoringOnTheFly'], 'ignoringOnTheFly', fallback: 0),
    );
  }
}
