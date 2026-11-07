import 'dart:convert';

import 'constants.dart';
import 'errors.dart';
import 'presence.dart';
import 'queue.dart';

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

/// What a media is, independent of where its bytes come from (`media.ref`):
/// an episode, a movie or an extra, by AniList and/or TVDB ids. Carried
/// as is in `swap.media`, `state.media` and `queue[].media` (the server
/// keeps it, at most [RelayConstants.maxMediaRefBytes] of JSON). The app
/// makes it from its library (files), Jellyfin's provider ids and a
/// link's name.
class MediaRef {
  static const kinds = {'episode', 'movie', 'extra'};

  /// `episode`, `movie` or `extra`.
  final String kind;
  final String title;
  final int? anilistId;
  /// The episode number within the AniList entry.
  final int? anilistEp;
  final int? tvdbId;
  /// TVDB season (null: unknown or none, e.g. absolute numbering).
  final int? season;
  final int? ep;
  /// Absolute episode number across seasons.
  final int? absolute;
  const MediaRef(
      {required this.kind,
      this.title = '',
      this.anilistId,
      this.anilistEp,
      this.tvdbId,
      this.season,
      this.ep,
      this.absolute});

  Map<String, Object?> toJson() => {
        'kind': kind,
        if (title.isNotEmpty) 'title': title,
        if (anilistId != null) 'anilistId': anilistId,
        if (anilistEp != null) 'anilistEp': anilistEp,
        if (tvdbId != null) 'tvdbId': tvdbId,
        if (season != null) 'season': season,
        if (ep != null) 'ep': ep,
        if (absolute != null) 'absolute': absolute,
      };

  /// Null when [j] is not a ref (no known `kind`); throws
  /// [ProtocolException] when it is larger than
  /// [RelayConstants.maxMediaRefBytes] as JSON. Ids that are not
  /// non-negative integers are dropped; the title is one line of at most
  /// 200 characters.
  static MediaRef? fromJson(Object? j) {
    if (j is! Map) return null;
    if (utf8.encode(jsonEncode(j)).length > RelayConstants.maxMediaRefBytes) {
      throw const ProtocolException('media.ref too large');
    }
    final kind = j['kind'];
    if (kind is! String || !kinds.contains(kind)) return null;
    int? n(Object? v) => v is num && v.isFinite && v >= 0 && v == v.roundToDouble() ? v.toInt() : null;
    final title = j['title'] is String ? (j['title'] as String).replaceAll(RegExp(r'\s+'), ' ').trim() : '';
    return MediaRef(
      kind: kind,
      title: title.length > 200 ? title.substring(0, 200) : title,
      anilistId: n(j['anilistId']),
      anilistEp: n(j['anilistEp']),
      tvdbId: n(j['tvdbId']),
      season: n(j['season']),
      ep: n(j['ep']),
      absolute: n(j['absolute']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaRef &&
      other.kind == kind &&
      other.title == title &&
      other.anilistId == anilistId &&
      other.anilistEp == anilistEp &&
      other.tvdbId == tvdbId &&
      other.season == season &&
      other.ep == ep &&
      other.absolute == absolute;

  @override
  int get hashCode => Object.hash(kind, title, anilistId, anilistEp, tvdbId, season, ep, absolute);
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
  /// What it is ([MediaRef]); null when unknown.
  final MediaRef? ref;
  const HelloMedia(
      {required this.name,
      required this.size,
      required this.duration,
      this.url,
      this.jellyfin,
      this.relay,
      this.ref});

  HelloMedia copyWith({double? duration, int? size, MediaRelay? relay}) => HelloMedia(
      name: name,
      size: size ?? this.size,
      duration: duration ?? this.duration,
      url: url,
      jellyfin: jellyfin,
      relay: relay ?? this.relay,
      ref: ref);

  Map<String, Object?> toJson() => {
        'name': name,
        'size': size,
        'duration': duration,
        if (url != null) 'url': url,
        if (jellyfin != null) 'jellyfin': jellyfin!.toJson(),
        if (relay != null) 'relay': relay!.toJson(),
        if (ref != null) 'ref': ref!.toJson(),
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
      ref: MediaRef.fromJson(json['ref']),
    );
  }
}

/// One track of a relayed media: [kind] `video` or `audio`; a byte stream
/// (a Range-readable file) unless [pieces] (a segmented playlist relayed
/// piece by piece, served as a media playlist). JSON `{"kind":"video"}`,
/// `{"kind":"audio","as":"pieces"}`.
class RelayTrackSpec {
  final String kind;
  final bool pieces;
  const RelayTrackSpec(this.kind, {this.pieces = false});

  Map<String, Object?> toJson() => {'kind': kind, if (pieces) 'as': 'pieces'};

  /// Null when [j] is not a track entry this side knows.
  static RelayTrackSpec? fromJson(Object? j) {
    if (j is! Map || !MediaRelay.trackKinds.contains(j['kind'])) return null;
    final as = j['as'];
    if (as != null && as != 'bytes' && as != 'pieces') return null;
    return RelayTrackSpec(j['kind'] as String, pieces: as == 'pieces');
  }

  @override
  bool operator ==(Object other) => other is RelayTrackSpec && other.kind == kind && other.pieces == pieces;
  @override
  int get hashCode => Object.hash(kind, pieces);
  @override
  String toString() => pieces ? '$kind pieces' : kind;
}

/// Relayed media: the bytes go through the server's buffer (`/r/...`).
/// Either from the [source] member's machine (it dials the relay channel),
/// or, with [fetch], the server reads the swap's link itself. A swap sends
/// `{}` or `{"fetch":true}`; the server fills in [source] (the swapper's
/// member id, empty with [fetch]) and whether bytes can flow ([live]).
/// [tracks]: the tracks of a media relayed as several played together, or
/// as one segmented playlist; empty for one file. A member swap names
/// them, the server fills them in for [fetch] once it has read the link.
/// [rate] and [need] are the server's measures, 0 while unknown: bytes per
/// second the source (or the server's own fetch) delivers while the
/// buffer asks for bytes, and the media's average bitrate. [queueId]:
/// the Up next item this relay was started for (its warm relay) before
/// it went up; viewers open its `/r/.../<queueId>/...` URLs, so their
/// preloads of it carry on. [sourceGone]: the source member is `gone`
/// (since [sourceGoneSince]): the relay and its buffer stay, viewers play
/// what is buffered; it stays set once the source left for good (the
/// relay has ended then: `live` false, `/r` answers 404).
class MediaRelay {
  final String source;
  final bool fetch;
  final bool live;
  final List<RelayTrackSpec> tracks;
  final int rate;
  final int need;
  final String queueId;
  final bool sourceGone;
  final DateTime? sourceGoneSince;
  const MediaRelay(
      {this.source = '',
      this.fetch = false,
      this.live = false,
      this.tracks = const [],
      this.rate = 0,
      this.need = 0,
      this.queueId = '',
      this.sourceGone = false,
      this.sourceGoneSince});

  /// The source is measured slower than the media plays (both known):
  /// below 85 % of [need], so a rate close to it does not flicker.
  bool get slow => rate > 0 && need > 0 && rate < need * 0.85;

  static const trackKinds = {'video', 'audio'};
  static const maxTracks = 4;

  /// [tracks] as sent: several, or one pieces track; else one file.
  static bool validTracks(List<RelayTrackSpec> t) =>
      t.length <= maxTracks && (t.length > 1 || (t.length == 1 && t.single.pieces));

  /// [sourceGoneSince] null with [sourceGone] true: since now is unknown,
  /// keep the earlier one; pass [sourceGone] false to clear both.
  MediaRelay copyWith(
          {bool? live,
          List<RelayTrackSpec>? tracks,
          int? rate,
          int? need,
          bool? sourceGone,
          DateTime? sourceGoneSince}) =>
      MediaRelay(
          source: source,
          fetch: fetch,
          live: live ?? this.live,
          tracks: tracks ?? this.tracks,
          rate: rate ?? this.rate,
          need: need ?? this.need,
          queueId: queueId,
          sourceGone: sourceGone ?? this.sourceGone,
          sourceGoneSince:
              (sourceGone ?? this.sourceGone) ? (sourceGoneSince ?? this.sourceGoneSince) : null);

  Map<String, Object?> toJson() => {
        if (source.isNotEmpty) 'source': source,
        if (fetch) 'fetch': true,
        if (live) 'live': true,
        if (validTracks(tracks)) 'tracks': [for (final t in tracks) t.toJson()],
        if (rate > 0) 'rate': rate,
        if (need > 0) 'need': need,
        if (queueId.isNotEmpty) 'queueId': queueId,
        if (sourceGone) 'sourceGone': true,
        if (sourceGone && sourceGoneSince != null) 'sourceGoneSince': sourceGoneSince!.toUtc().toIso8601String(),
      };

  /// Unknown kinds, a single byte track or too many make it one file.
  factory MediaRelay.fromJson(Map<String, Object?> json) {
    final t = json['tracks'];
    final specs = t is List ? [for (final e in t) RelayTrackSpec.fromJson(e)] : const <RelayTrackSpec?>[];
    final ok = !specs.contains(null) && validTracks(specs.cast<RelayTrackSpec>());
    final gone = json['sourceGone'] == true;
    return MediaRelay(
        source: json['source'] is String ? json['source'] as String : '',
        fetch: json['fetch'] == true,
        live: json['live'] == true,
        tracks: ok ? List.unmodifiable(specs.cast<RelayTrackSpec>()) : const [],
        rate: _byteRate(json['rate']),
        need: _byteRate(json['need']),
        queueId: json['queueId'] is String ? json['queueId'] as String : '',
        sourceGone: gone,
        sourceGoneSince: gone ? DateTime.tryParse('${json['sourceGoneSince']}') : null);
  }

  /// A bytes-per-second field: a finite non-negative number, else 0.
  static int _byteRate(Object? v) => v is num && v.isFinite && v > 0 ? v.round() : 0;
}

/// The highest wire version both sides speak: the client's
/// [clientMin]..[clientMax] (`hello.protoMin`..`hello.proto`) against this
/// build's [RelayConstants.protoMin]..[RelayConstants.protoMax]; null when
/// the ranges do not meet.
int? pickProto(int clientMin, int clientMax,
    {int serverMin = RelayConstants.protoMin, int serverMax = RelayConstants.protoMax}) {
  final hi = clientMax < serverMax ? clientMax : serverMax;
  final lo = clientMin > serverMin ? clientMin : serverMin;
  return hi >= lo ? hi : null;
}

/// What this app can do (`hello.caps`, `members[].caps`): serve a relay
/// ([source]), resolve links with yt-dlp ([resolve]), play Jellyfin with
/// its own account ([jellyfin]). Unknown entries are ignored. Wire: an
/// object of `true` flags, e.g. `{"source":true,"resolve":true}`.
class ClientCaps {
  final bool source;
  final bool resolve;
  final bool jellyfin;
  const ClientCaps({this.source = false, this.resolve = false, this.jellyfin = false});

  bool get isEmpty => !source && !resolve && !jellyfin;

  Map<String, Object?> toJson() => {
        if (source) 'source': true,
        if (resolve) 'resolve': true,
        if (jellyfin) 'jellyfin': true,
      };

  factory ClientCaps.fromJson(Object? j) => j is Map
      ? ClientCaps(source: j['source'] == true, resolve: j['resolve'] == true, jellyfin: j['jellyfin'] == true)
      : const ClientCaps();

  @override
  bool operator ==(Object other) =>
      other is ClientCaps && other.source == source && other.resolve == resolve && other.jellyfin == jellyfin;
  @override
  int get hashCode => Object.hash(source, resolve, jellyfin);
}

/// `hello.client`: an opaque per-install id ([RelayConstants.minClientIdLength]
/// to [RelayConstants.maxClientIdLength] characters of base64url). Private:
/// never broadcast, never logged.
bool validClientId(String id) =>
    id.length >= RelayConstants.minClientIdLength &&
    id.length <= RelayConstants.maxClientIdLength &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);

/// The first frame of a `/sync` socket. A proto 16 app sends `media: {}`
/// (ignored) so a proto 15 server, which requires it, answers with its
/// "proto mismatch" instead of a parse error.
class HelloMessage {
  /// The client's highest wire version (`hello.proto`).
  final int proto;
  /// The client's lowest wire version (`hello.protoMin`); defaults to
  /// [proto] when absent.
  final int protoMin;
  final String secret;
  final HelloUser user;
  /// The hosting app's own client proves it is the host with this; empty
  /// for everyone else.
  final String hostKey;
  /// Per-install id ([validClientId]): a hello with a known one takes that
  /// member over. Empty: a fresh member every time (tools, tests).
  final String client;
  /// Increasing per [client] (every connect of this install sends a higher
  /// one): an older hello than the member's last gets `err stale`.
  final int seq;
  /// App version (`"1.3.0"`), shown as `members[].app`.
  final String app;
  /// `linux`, `windows`, `macos` or `android`; logged, not broadcast.
  final String platform;
  final ClientCaps caps;
  /// The last `feed.seq` this client saw from this server: `welcome.feed`
  /// replays what came after it (at most [RelayConstants.feedReplayLines]).
  /// Null: no replay.
  final int? feedAfter;
  const HelloMessage(
      {this.proto = RelayConstants.protoMax,
      int? protoMin,
      required this.secret,
      required this.user,
      this.hostKey = '',
      this.client = '',
      this.seq = 0,
      this.app = '',
      this.platform = '',
      this.caps = const ClientCaps(),
      this.feedAfter})
      : protoMin = protoMin ?? (proto < RelayConstants.protoMin ? proto : RelayConstants.protoMin);

  Map<String, Object?> toJson() => {
        't': 'hello',
        'protoMin': protoMin,
        'proto': proto,
        'secret': secret,
        'user': user.toJson(),
        'media': const <String, Object?>{},
        if (hostKey.isNotEmpty) 'hostKey': hostKey,
        if (client.isNotEmpty) 'client': client,
        if (seq != 0) 'seq': seq,
        if (app.isNotEmpty) 'app': app,
        if (platform.isNotEmpty) 'platform': platform,
        if (!caps.isEmpty) 'caps': caps.toJson(),
        if (feedAfter != null) 'feedAfter': feedAfter,
      };

  /// The client's version range read leniently from a raw hello, before
  /// [HelloMessage.fromJson]: a hello of another version may not parse.
  /// Null when it names none.
  static ({int min, int max})? protoRangeOf(Map<String, Object?> json) {
    final p = json['proto'];
    if (p is! num || !p.isFinite) return null;
    final m = json['protoMin'];
    final max = p.toInt();
    final min = m is num && m.isFinite && m.toInt() <= max ? m.toInt() : max;
    return (min: min, max: max);
  }

  factory HelloMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'hello') throw const ProtocolException('not a hello message');
    final user = json['user'];
    if (user is! Map) throw const ProtocolException('hello missing user');
    final client = json['client'] ?? '';
    if (client is! String || (client.isNotEmpty && !validClientId(client))) {
      throw const ProtocolException('bad client id');
    }
    final proto = finiteInt(json['proto'], 'proto', fallback: RelayConstants.protoMax);
    final feedAfter = json['feedAfter'];
    return HelloMessage(
      proto: proto,
      protoMin: finiteInt(json['protoMin'], 'protoMin', fallback: proto),
      secret: (json['secret'] as String?) ?? '',
      user: HelloUser.fromJson(Map<String, Object?>.from(user)),
      hostKey: (json['hostKey'] as String?) ?? '',
      client: client,
      seq: finiteInt(json['seq'], 'seq'),
      app: _short(json['app'], 32),
      platform: _short(json['platform'], 16),
      caps: ClientCaps.fromJson(json['caps']),
      feedAfter: feedAfter == null ? null : finiteInt(feedAfter, 'feedAfter'),
    );
  }
}

/// A short plain string field: one line, at most [max] characters.
String _short(Object? v, int max) {
  if (v is! String) return '';
  final line = v.replaceAll(RegExp(r'\s+'), ' ').trim();
  return line.length > max ? line.substring(0, max) : line;
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
  /// The wire version of this connection ([pickProto]).
  final int proto;
  /// The hello took over this client's member (same [memberId] and
  /// [token], everything it had kept); false for a new member.
  final bool resumed;
  /// Random per server boot: a client that held a member of another
  /// instance knows the server restarted (not that its grace ran out).
  final String instance;
  /// Seconds a `gone` member is kept ([RelayConstants.graceSecs]).
  final int grace;
  /// Feed lines after `hello.feedAfter`, oldest first, each `replayed`.
  final List<FeedMessage> feed;
  const WelcomeMessage(
      {required this.token,
      this.memberId = '',
      this.mediaUrl,
      this.relayUrl,
      this.state,
      this.proto = RelayConstants.protoMax,
      this.resumed = false,
      this.instance = '',
      this.grace = RelayConstants.graceSecs,
      this.feed = const []});

  Map<String, Object?> toJson() => {
        't': 'welcome',
        'proto': proto,
        'token': token,
        'memberId': memberId,
        'resumed': resumed,
        'instance': instance,
        'grace': grace,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        if (relayUrl != null) 'relayUrl': relayUrl,
        if (state != null) 'state': state,
        if (feed.isNotEmpty) 'feed': [for (final f in feed) f.toJson()],
      };

  factory WelcomeMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'welcome') throw const ProtocolException('not a welcome message');
    final state = json['state'];
    final feed = json['feed'];
    return WelcomeMessage(
      token: (json['token'] as String?) ?? '',
      memberId: (json['memberId'] as String?) ?? '',
      mediaUrl: json['mediaUrl'] as String?,
      relayUrl: json['relayUrl'] as String?,
      state: state is Map ? Map<String, Object?>.from(state) : null,
      proto: finiteInt(json['proto'], 'proto', fallback: 0),
      resumed: json['resumed'] == true,
      instance: json['instance'] is String ? json['instance'] as String : '',
      grace: finiteInt(json['grace'], 'grace', fallback: 0),
      feed: feed is List
          ? [
              for (final f in feed)
                if (f is Map && f['t'] == 'feed') FeedMessage.fromJson(Map<String, Object?>.from(f)),
            ]
          : const [],
    );
  }
}

/// Error codes of `err.code` (PROTOCOL.md "Errors"). Terminal ones
/// ([version], [secret], [replaced], [stale], a refused `hello` with
/// [rejected] or [bad]) are followed by a close ([CloseCodes]).
enum ErrCode {
  /// No common wire version: `min`/`max`/`server` say the server's.
  version,
  /// Wrong `hello.secret`.
  secret,
  /// Understood but refused (an avatar too large, a fetch the server
  /// cannot do).
  rejected,
  /// Malformed (a bad hello, a non-finite number, a bad swap or queue item).
  bad,
  /// Another hello with this client id took the member over (the client
  /// stops: "opened in another window").
  replaced,
  /// This hello is older (`hello.seq`) than the member's current one.
  stale,
  /// Not allowed for this member (e.g. setting someone else `in`).
  forbidden,
  /// Over a rate limit (reserved; nudges over the cap are dropped silently).
  rate,
  /// A list is full (Up next at [RelayConstants.maxQueueItems]).
  full;

  static ErrCode? parse(Object? v) {
    for (final c in values) {
      if (c.name == v) return c;
    }
    return null;
  }
}

/// Close codes of the server's sockets (PROTOCOL.md "Close codes").
abstract class CloseCodes {
  /// Relay channel: not (or no longer) the source; the source stops.
  static const relayNotSource = 4001;
  /// Relay channel: its `info` differs from the media's first one (another
  /// file); the relay ends and the source stops.
  static const relayOtherMedia = 4002;
  /// Relay channel: a newer channel for the same relay replaced it; the
  /// source stops.
  static const relayReplaced = 4003;
  /// `/sync`: refused at hello, `err` `version`.
  static const version = 4010;
  /// `/sync`: refused at hello, `err` `secret`.
  static const secret = 4011;
  /// `/sync`: refused at hello, `err` `rejected` or `bad`.
  static const refused = 4012;
  /// `/sync`: another hello took the member over (`err` `replaced`).
  static const replaced = 4013;
  /// `/sync`: an older hello than the member's (`err` `stale`).
  static const stale = 4014;
  /// `/sync`: no frame for the silence limit; the member is `gone`.
  static const silent = 4015;
  /// `/sync`: the hosting app stopped sharing its server; the member has
  /// left (feed `leave`, reason `closed`) and nothing reconnects.
  static const closed = 4016;
  /// `/sync`: the member left (`bye`, or grace over).
  static const left = 1000;
}

/// Server to client: `{"t":"err","code":..., "message":..., "for":...}`.
/// [message] is plain text for people (a proto 15 app shows it as is);
/// [code] is for programs. For [ErrCode.version]: [min]/[max] the server's
/// range and [server] its app version. [forType]: the `t` of the frame
/// that failed, when there is one (`for` on the wire).
class ErrorFrame {
  final ErrCode? code;
  final String message;
  final String? forType;
  final int? min;
  final int? max;
  final String? server;
  const ErrorFrame({required this.code, required this.message, this.forType, this.min, this.max, this.server});

  /// The stable refusal of a hello whose versions do not meet ours:
  /// `{"t":"err","code":"version","min":16,"max":16,"server":"1.3.0",
  /// "message":"proto mismatch: got 15, want 16..16"}`.
  factory ErrorFrame.version({required int got, required String server}) => ErrorFrame(
      code: ErrCode.version,
      message: 'proto mismatch: got $got, want ${RelayConstants.protoMin}..${RelayConstants.protoMax}',
      forType: 'hello',
      min: RelayConstants.protoMin,
      max: RelayConstants.protoMax,
      server: server);

  Map<String, Object?> toJson() => {
        't': 'err',
        if (code != null) 'code': code!.name,
        'message': message,
        if (forType != null) 'for': forType,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (server != null) 'server': server,
      };

  /// A proto 15 server's `err` has no [code].
  factory ErrorFrame.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'err') throw const ProtocolException('not an err frame');
    final min = json['min'], max = json['max'];
    return ErrorFrame(
      code: ErrCode.parse(json['code']),
      message: json['message'] is String ? json['message'] as String : '',
      forType: json['for'] is String ? json['for'] as String : null,
      min: min is num && min.isFinite ? min.toInt() : null,
      max: max is num && max.isFinite ? max.toInt() : null,
      server: json['server'] is String ? json['server'] as String : null,
    );
  }
}

/// Client to server: set [target] (a member id; empty = oneself) to
/// [state] (PROTOCOL.md "Presence"): `brb` and `out` on anyone (Wait for
/// Bob, Don't wait for Bob), `in` and `afk` only on oneself (else `err`
/// `forbidden`). [resume] with `brb`: the group was playing when this
/// press began (its own pause on key-down came first), so it plays again
/// once the last one is back. [reason] goes into the feed line.
class PresenceIntent {
  final String target;
  final Presence state;
  final PresenceReason reason;
  final bool resume;
  const PresenceIntent({this.target = '', required this.state, this.reason = PresenceReason.manual, this.resume = false});

  Map<String, Object?> toJson() => {
        't': 'presence',
        if (target.isNotEmpty) 'target': target,
        'state': state.wire,
        if (reason != PresenceReason.manual) 'reason': reason.wire,
        if (resume) 'resume': true,
      };

  factory PresenceIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'presence') throw const ProtocolException('not a presence intent');
    final state = Presence.parse(json['state']);
    if (state == null) throw const ProtocolException('presence state must be in, brb, afk or out');
    return PresenceIntent(
        target: json['target'] is String ? json['target'] as String : '',
        state: state,
        reason: PresenceReason.parse(json['reason']),
        resume: json['resume'] == true);
  }
}

/// Client to server: the group's wish, `{"t":"play"}` or `{"t":"pause"}`
/// (anyone's). Playing waits for whoever the group waits for.
class TransportIntent {
  final bool play;
  const TransportIntent({required this.play});

  Map<String, Object?> toJson() => {'t': play ? 'play' : 'pause'};

  factory TransportIntent.fromJson(Map<String, Object?> json) {
    final t = json['t'];
    if (t != 'play' && t != 'pause') throw const ProtocolException('not a play or pause intent');
    return TransportIntent(play: t == 'play');
  }
}

/// Client to server: continue without [target] (a member id), or
/// without everyone the group waits for (empty; the group then plays). A
/// BRB member becomes `out`; someone whose video holds the group stays
/// `in` and catches up.
class ContinueIntent {
  final String target;
  const ContinueIntent({this.target = ''});

  Map<String, Object?> toJson() => {'t': 'continue', if (target.isNotEmpty) 'target': target};

  factory ContinueIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'continue') throw const ProtocolException('not a continue intent');
    return ContinueIntent(target: json['target'] is String ? json['target'] as String : '');
  }
}

/// Client to server: leave now (the Leave button, the app closing). The
/// member leaves at once (feed `leave`, no grace) and the socket closes.
class ByeMessage {
  const ByeMessage();
  Map<String, Object?> toJson() => {'t': 'bye'};
}

/// Client to server: poke [target] (a member id). The server passes it on
/// to that member only, as a [NudgeNotice].
class NudgeIntent {
  final String target;
  const NudgeIntent({required this.target});

  Map<String, Object?> toJson() => {'t': 'nudge', 'target': target};

  factory NudgeIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'nudge') throw const ProtocolException('not a nudge intent');
    return NudgeIntent(target: (json['target'] as String?) ?? '');
  }
}

/// Server to the nudged member: who poked it ([from] member id, [name]).
class NudgeNotice {
  final String from;
  final String name;
  const NudgeNotice({required this.from, required this.name});

  Map<String, Object?> toJson() => {'t': 'nudge', 'from': from, 'name': name};

  factory NudgeNotice.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'nudge') throw const ProtocolException('not a nudge notice');
    return NudgeNotice(from: (json['from'] as String?) ?? '', name: (json['name'] as String?) ?? '');
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

/// `swap.restore`: what played before the server restarted, offered back
/// by an app that still holds it: at [position] (seconds), [transport]
/// as it was (`playing`, `held` or `finished`). The server takes it only
/// while it has no media (the first offer wins, later ones are ignored).
class SwapRestore {
  final double position;
  final String transport;
  const SwapRestore({required this.position, this.transport = 'held'});

  Map<String, Object?> toJson() => {'position': position, 'transport': transport};

  static SwapRestore? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = j['transport'];
    return SwapRestore(
        position: finiteDouble(j['position'], 'restore.position'),
        transport: t == 'playing' || t == 'finished' ? t as String : 'held');
  }
}

class SwapIntent {
  final HelloMedia media;
  /// The Up next item this swap puts up (`queue[].id`); the server takes
  /// it out of the queue with the swap, and ignores the swap when it is no
  /// longer queued (someone else put it up first).
  final String? queueId;
  /// Puts back what played before a server restart ([SwapRestore]).
  final SwapRestore? restore;
  const SwapIntent({required this.media, this.queueId, this.restore});

  Map<String, Object?> toJson() => {
        't': 'swap',
        'media': media.toJson(),
        if (queueId != null) 'queueId': queueId,
        if (restore != null) 'restore': restore!.toJson(),
      };

  factory SwapIntent.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'swap') throw const ProtocolException('not a swap intent');
    final media = json['media'];
    if (media is! Map) throw const ProtocolException('swap missing media');
    final queueId = json['queueId'];
    return SwapIntent(
        media: HelloMedia.fromJson(Map<String, Object?>.from(media)),
        queueId: queueId is String && queueId.isNotEmpty ? queueId : null,
        restore: SwapRestore.fromJson(json['restore']));
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
  /// Why the player cannot open [mediaId] (short plain text); empty while
  /// it can.
  final String error;
  const ReportMessage(
      {required this.position,
      required this.buffered,
      required this.eventId,
      this.duration = 0,
      this.mediaId = 0,
      this.jf,
      this.error = ''});

  Map<String, Object?> toJson() => {
        't': 'report',
        'position': position,
        'buffered': buffered,
        'eventId': eventId,
        if (duration > 0) 'duration': duration,
        if (mediaId != 0) 'mediaId': mediaId,
        if (jf != null) 'jf': jf,
        if (error.isNotEmpty) 'error': error,
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
      error: memberErrorFromJson(json['error']),
    );
  }
}

/// Reads a `report.error` / `members[].error`: trimmed, single line, at
/// most [RelayConstants.maxMemberErrorLength] characters; empty otherwise.
String memberErrorFromJson(Object? value) {
  if (value is! String) return '';
  final line = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  const max = RelayConstants.maxMemberErrorLength;
  return line.length > max ? line.substring(0, max) : line;
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
  final double buffered;
  /// Where it stands ([Presence]).
  final Presence presence;
  /// When [presence] began (BRB, AFK, Out); null for `in`.
  final DateTime? since;
  /// Its player is not with the group yet (just joined, back from out or
  /// a drop, or left behind by a continue): the "Loading" label.
  final bool loading;
  /// Disconnected and kept for the grace: the "Reconnecting" label.
  final bool gone;
  /// When it went [gone]; null otherwise.
  final DateTime? goneSince;
  /// Last `report.jf` of this member; empty when never reported.
  final Map<String, bool> jf;
  /// The hosting app's own member (sent the server's host key).
  final bool host;
  /// Why its player cannot open the current media (`report.error`); empty
  /// while it can. Errored: never waited for.
  final String error;
  /// Bytes per second the server sent this member lately (its file, the
  /// Jellyfin relay or the relay); 0 when none.
  final int rate;
  /// Its app version (`hello.app`); empty when it sent none.
  final String app;
  /// What its app can do (`hello.caps`).
  final ClientCaps caps;
  const MemberView({
    required this.id,
    required this.name,
    this.avatarHash = '',
    this.buffered = 0,
    this.presence = Presence.watching,
    this.since,
    this.loading = false,
    this.gone = false,
    this.goneSince,
    this.jf = const {},
    this.host = false,
    this.error = '',
    this.rate = 0,
    this.app = '',
    this.caps = const ClientCaps(),
  });

  /// BRB.
  bool get brb => presence == Presence.brb;

  /// AFK or Out: not watching, not waited for.
  bool get isOut => presence.isOut;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        if (avatarHash.isNotEmpty) 'avatarHash': avatarHash,
        'buffered': buffered,
        'presence': presence.wire,
        if (presence != Presence.watching && since != null) 'since': since!.toUtc().toIso8601String(),
        if (loading) 'loading': true,
        if (gone)
          'goneSince': (goneSince ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)).toUtc().toIso8601String(),
        if (jf.isNotEmpty) 'jf': jf,
        if (host) 'host': true,
        if (error.isNotEmpty) 'error': error,
        if (rate > 0) 'rate': rate,
        if (app.isNotEmpty) 'app': app,
        if (!caps.isEmpty) 'caps': caps.toJson(),
      };

  factory MemberView.fromJson(Map<String, Object?> json) {
    final presence = Presence.parse(json['presence']) ?? Presence.watching;
    final gone = json['goneSince'] != null;
    return MemberView(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      avatarHash: (json['avatarHash'] as String?) ?? '',
      buffered: finiteDouble(json['buffered'], 'buffered'),
      presence: presence,
      since: presence == Presence.watching || json['since'] == null ? null : DateTime.tryParse('${json['since']}'),
      loading: json['loading'] == true,
      gone: gone,
      goneSince: gone ? DateTime.tryParse('${json['goneSince']}') : null,
      jf: jfAccessFromJson(json['jf']) ?? const {},
      host: json['host'] == true,
      error: memberErrorFromJson(json['error']),
      rate: MediaRelay._byteRate(json['rate']),
      app: _short(json['app'], 32),
      caps: ClientCaps.fromJson(json['caps']),
    );
  }
}

/// `state.hold`: present while `transport` is `held` with media up and
/// someone is waited for: [brb] the BRB members (whatever the wish),
/// [video] the members whose video holds the group (only while it wants
/// to play: still loading, or a buffer short of `bufferNeed`), [source]
/// the relayed media's source is `gone` (the short buffers are its doing).
class HoldInfo {
  final List<String> brb;
  final List<String> video;
  final bool source;
  const HoldInfo({this.brb = const [], this.video = const [], this.source = false});

  bool get isEmpty => brb.isEmpty && video.isEmpty;

  /// Everyone waited for, BRB first.
  List<String> get members => [...brb, ...video];

  Map<String, Object?> toJson() => {
        if (brb.isNotEmpty) 'brb': brb,
        if (video.isNotEmpty) 'video': video,
        if (source) 'source': true,
      };

  static HoldInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    List<String> ids(Object? v) => v is List ? v.whereType<String>().toList() : const [];
    final h = HoldInfo(brb: ids(j['brb']), video: ids(j['video']), source: j['source'] == true);
    return h.isEmpty ? null : h;
  }
}

/// `state.advance`: the shared countdown to Up next's first item over the
/// media's last [secs] (or from an item coming first once it finished).
/// At [at] + [secs] (server clock; the media's end while it plays) the
/// server sets `queuePlay` to [id] (holding while its performer or its
/// relay's source is `gone`); `{"t":"queue","op":"cancel"}`, a pause and
/// a seek clear it for everyone (see `SyncEngine.whatsNext`).
class QueueAdvance {
  final String id;
  final DateTime at;
  final int secs;
  const QueueAdvance({required this.id, required this.at, required this.secs});

  Map<String, Object?> toJson() => {'id': id, 'at': at.toUtc().toIso8601String(), 'secs': secs};

  static QueueAdvance? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    final at = DateTime.tryParse('${j['at']}');
    final secs = j['secs'];
    if (at == null || secs is! num || !secs.isFinite || secs < 0) return null;
    return QueueAdvance(id: j['id'] as String, at: at, secs: secs.toInt());
  }
}

class StateBroadcast {
  /// Buffer a watching member needs before playback can go on, as the
  /// server's gate counts it: [RelayConstants.minBufferSecs], less near the
  /// end (mpv cannot buffer past it), none once finished.
  double get bufferNeed => bufferNeedAt(DateTime.now().toUtc());

  /// [bufferNeed] at [now]: while playing the position has moved on since
  /// [serverTime] (the local clock is close enough for this).
  double bufferNeedAt(DateTime now) {
    if (transport == 'finished') return 0;
    final d = (media?['duration'] as num?)?.toDouble() ?? 0;
    const full = RelayConstants.minBufferSecs;
    if (d <= 0) return full;
    final moved = transport == 'playing' ? now.difference(serverTime).inMilliseconds / 1000 : 0;
    return (d - (position + moved) - RelayConstants.endSlackSecs).clamp(0.0, full).toDouble();
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
  /// The server can relay Up next's first item the same way (it is a
  /// Jellyfin ref on the server's login), so viewers without access get
  /// it ready before it goes up.
  final bool relayNext;
  /// Up next, in order (see `QueueItem`); empty when nothing is queued.
  final List<QueueItem> queue;
  /// The queued item someone asked to play now, waiting for the member
  /// who can put it up; null when none.
  final String? queuePlay;
  /// Who the group waits for ([HoldInfo]); null unless `held` with media
  /// up and someone is waited for.
  final HoldInfo? hold;
  /// The group's wish: play (true) or pause. It plays when it wants to
  /// and nobody is waited for.
  final bool wantsPlay;
  /// Members passed over for the current play request (`queuePlay`): they
  /// did not put it up in time, so [queuePerformer] asks someone else.
  final List<String> queuePass;
  /// The shared countdown to Up next's first item ([QueueAdvance]); null when none runs.
  final QueueAdvance? advance;
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
    this.relayNext = false,
    this.queue = const [],
    this.queuePlay,
    this.hold,
    this.advance,
    this.wantsPlay = false,
    this.queuePass = const [],
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
        if (relayNext) 'relayNext': true,
        if (queue.isNotEmpty) 'queue': [for (final q in queue) q.toJson()],
        if (queuePlay != null) 'queuePlay': queuePlay,
        if (hold != null) 'hold': hold!.toJson(),
        if (advance != null) 'advance': advance!.toJson(),
        'wish': wantsPlay ? 'play' : 'pause',
        if (queuePass.isNotEmpty) 'queuePass': queuePass,
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
      relayNext: json['relayNext'] == true,
      queue: json['queue'] is List
          ? (json['queue'] as List).map(QueueItem.fromJson).whereType<QueueItem>().toList()
          : const [],
      queuePlay: json['queuePlay'] is String ? json['queuePlay'] as String : null,
      hold: HoldInfo.fromJson(json['hold']),
      advance: QueueAdvance.fromJson(json['advance']),
      wantsPlay: json['wish'] == 'play',
      queuePass: json['queuePass'] is List ? (json['queuePass'] as List).whereType<String>().toList() : const [],
    );
  }
}

/// One line of the activity feed. [actor] / [target] are display names
/// (as they were then); [actorId] / [targetId] the member ids (`server`
/// for the server's own lines, empty when none), so clients match people
/// by id, not by name. [seq] increases by one per line for the server's
/// life; [replayed] marks lines repeated in `welcome.feed` (log them, do
/// not toast them).
class FeedMessage {
  final String actor;
  final String action;
  final String? target;
  final String reason;
  final DateTime at;
  final String actorId;
  final String targetId;
  final int seq;
  final bool replayed;
  /// `return`: seconds of the video the member missed while it was away
  /// (at least [RelayConstants.missedNoticeSecs]); 0 otherwise.
  final int missed;
  const FeedMessage({
    required this.actor,
    required this.action,
    this.target,
    this.reason = '',
    required this.at,
    this.actorId = '',
    this.targetId = '',
    this.seq = 0,
    this.replayed = false,
    this.missed = 0,
  });

  FeedMessage copyWith({int? seq, bool? replayed}) => FeedMessage(
      actor: actor,
      action: action,
      target: target,
      reason: reason,
      at: at,
      actorId: actorId,
      targetId: targetId,
      seq: seq ?? this.seq,
      replayed: replayed ?? this.replayed,
      missed: missed);

  Map<String, Object?> toJson() => {
        't': 'feed',
        'seq': seq,
        'actor': actor,
        if (actorId.isNotEmpty) 'actorId': actorId,
        'action': action,
        if (target != null) 'target': target,
        if (targetId.isNotEmpty) 'targetId': targetId,
        'reason': reason,
        'at': at.toIso8601String(),
        if (replayed) 'replayed': true,
        if (missed > 0) 'missed': missed,
      };

  factory FeedMessage.fromJson(Map<String, Object?> json) {
    if (json['t'] != 'feed') throw const ProtocolException('not a feed message');
    return FeedMessage(
      actor: (json['actor'] as String?) ?? '',
      action: (json['action'] as String?) ?? '',
      target: json['target'] as String?,
      reason: (json['reason'] as String?) ?? '',
      at: DateTime.tryParse('${json['at']}') ?? DateTime.now().toUtc(),
      actorId: json['actorId'] is String ? json['actorId'] as String : '',
      targetId: json['targetId'] is String ? json['targetId'] as String : '',
      seq: finiteInt(json['seq'], 'seq'),
      replayed: json['replayed'] == true,
      missed: json['missed'] is num && (json['missed'] as num).isFinite && (json['missed'] as num) > 0
          ? (json['missed'] as num).toInt()
          : 0,
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
