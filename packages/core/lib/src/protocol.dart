import 'constants.dart';
import 'errors.dart';

enum MessageKind {
  hello,
  welcome,
  state,
  event,
  chat,
  buffered,
  kicked,
  kick,
  eof,
  err,
  open,
  ack,
  cancel,
}

class HelloUser {
  final String name;
  final String avatar;
  const HelloUser({required this.name, this.avatar = ''});

  Map<String, Object?> toJson() => {'name': name, 'avatar': avatar};

  factory HelloUser.fromJson(Map<String, Object?> json) =>
      HelloUser(name: (json['name'] as String?) ?? '', avatar: (json['avatar'] as String?) ?? '');
}

class HelloMedia {
  final String name;
  final int size;
  final double duration;
  final String? url;
  const HelloMedia({required this.name, required this.size, required this.duration, this.url});

  Map<String, Object?> toJson() => {'name': name, 'size': size, 'duration': duration, if (url != null) 'url': url};

  factory HelloMedia.fromJson(Map<String, Object?> json) => HelloMedia(
        name: (json['name'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
        url: json['url'] as String?,
      );
}

class HelloMessage {
  final int proto;
  final String secret;
  final HelloUser user;
  final HelloMedia media;
  const HelloMessage({required this.proto, required this.secret, required this.user, required this.media});

  Map<String, Object?> toJson() => {
        't': 'hello',
        'proto': proto,
        'secret': secret,
        'user': user.toJson(),
        'media': media.toJson(),
      };

  factory HelloMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'hello') throw const ProtocolException('not a hello message');
    final user = json['user'];
    final media = json['media'];
    if (user is! Map || media is! Map) throw const ProtocolException('hello missing user/media');
    return HelloMessage(
      proto: (json['proto'] as num?)?.toInt() ?? RelayConstants.protoVersion,
      secret: (json['secret'] as String?) ?? '',
      user: HelloUser.fromJson(Map<String, Object?>.from(user)),
      media: HelloMedia.fromJson(Map<String, Object?>.from(media)),
    );
  }
}

class RoomState {
  final double position;
  final bool paused;
  final int mediaId;
  final DateTime serverTime;
  const RoomState({required this.position, required this.paused, required this.mediaId, required this.serverTime});

  Map<String, Object?> toJson() => {
        'position': position,
        'paused': paused,
        'mediaId': mediaId,
        'serverTime': serverTime.toIso8601String(),
      };

  factory RoomState.fromJson(Map<String, Object?> json) => RoomState(
        position: (json['position'] as num?)?.toDouble() ?? 0.0,
        paused: (json['paused'] as bool?) ?? true,
        mediaId: (json['mediaId'] as num?)?.toInt() ?? 0,
        serverTime: DateTime.tryParse('${json['serverTime']}') ?? DateTime.now().toUtc(),
      );
}

class WelcomeMessage {
  final String token;
  final String memberId;
  final String? mediaUrl;
  final Map<String, Object?>? state;
  const WelcomeMessage({required this.token, this.memberId = '', this.mediaUrl, this.state});

  Map<String, Object?> toJson() => {
        't': 'welcome',
        'token': token,
        'memberId': memberId,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        if (state != null) 'state': state,
      };

  factory WelcomeMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'welcome') throw const ProtocolException('not a welcome message');
    final state = json['state'];
    return WelcomeMessage(
      token: (json['token'] as String?) ?? '',
      memberId: (json['memberId'] as String?) ?? '',
      mediaUrl: json['mediaUrl'] as String?,
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
  const SeekIntent({required this.position});

  Map<String, Object?> toJson() => {'t': 'seek', 'position': position};

  factory SeekIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'seek') throw const ProtocolException('not a seek intent');
    return SeekIntent(position: (json['position'] as num?)?.toDouble() ?? 0.0);
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
  const ReportMessage({required this.position, required this.buffered, required this.eventId});

  Map<String, Object?> toJson() =>
      {'t': 'report', 'position': position, 'buffered': buffered, 'eventId': eventId};

  factory ReportMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'report') throw const ProtocolException('not a report');
    return ReportMessage(
      position: (json['position'] as num?)?.toDouble() ?? 0.0,
      buffered: (json['buffered'] as num?)?.toDouble() ?? 0.0,
      eventId: (json['eventId'] as num?)?.toInt() ?? 0,
    );
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

class MemberView {
  final String id;
  final String name;
  final String avatar;
  final bool ready;
  final bool inSet;
  final double buffered;
  final bool stale;
  const MemberView({
    required this.id,
    required this.name,
    this.avatar = '',
    required this.ready,
    required this.inSet,
    required this.buffered,
    required this.stale,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'avatar': avatar,
        'ready': ready,
        'inSet': inSet,
        'buffered': buffered,
        'stale': stale,
      };

  factory MemberView.fromJson(Map<String, Object?> json) => MemberView(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        avatar: (json['avatar'] as String?) ?? '',
        ready: (json['ready'] as bool?) ?? false,
        inSet: (json['inSet'] as bool?) ?? false,
        buffered: (json['buffered'] as num?)?.toDouble() ?? 0.0,
        stale: (json['stale'] as bool?) ?? false,
      );
}

class RoomBroadcast {
  final int eventId;
  final String transport;
  final double position;
  final DateTime serverTime;
  final int mediaId;
  final Map<String, Object?>? media;
  final List<MemberView> members;
  const RoomBroadcast({
    required this.eventId,
    required this.transport,
    required this.position,
    required this.serverTime,
    required this.mediaId,
    this.media,
    required this.members,
  });

  Map<String, Object?> toJson() => {
        't': 'room',
        'eventId': eventId,
        'transport': transport,
        'position': position,
        'serverTime': serverTime.toIso8601String(),
        'mediaId': mediaId,
        if (media != null) 'media': media,
        'members': members.map((m) => m.toJson()).toList(),
      };

  factory RoomBroadcast.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'room') throw const ProtocolException('not a room broadcast');
    final members = json['members'];
    final media = json['media'];
    return RoomBroadcast(
      eventId: (json['eventId'] as num?)?.toInt() ?? 0,
      transport: (json['transport'] as String?) ?? 'held',
      position: (json['position'] as num?)?.toDouble() ?? 0.0,
      serverTime: DateTime.tryParse('${json['serverTime']}') ?? DateTime.now().toUtc(),
      mediaId: (json['mediaId'] as num?)?.toInt() ?? 0,
      media: media is Map ? Map<String, Object?>.from(media) : null,
      members: members is List
          ? members
              .whereType<Map>()
              .map((m) => MemberView.fromJson(Map<String, Object?>.from(m)))
              .toList()
          : const [],
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
      position: (json['position'] as num?)?.toDouble() ?? 0.0,
      doSeek: (json['doSeek'] as bool?) ?? false,
      ignoringOnTheFly: (json['ignoringOnTheFly'] as num?)?.toInt() ?? 0,
    );
  }
}
