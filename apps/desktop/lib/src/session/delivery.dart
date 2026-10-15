import 'package:sync_relay_core/core.dart';

import '../jellyfin/session_media.dart';
import 'party.dart';

// Who fetches the current media and how it spreads, from the state alone:
// the members card's source line and each member's route and buffer.

/// "4.1 MB/s", "850 kB/s".
String formatRate(int bytesPerSec) {
  if (bytesPerSec >= 1000000) {
    final mb = bytesPerSec / 1e6;
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB/s';
  }
  return '${(bytesPerSec / 1000).round()} kB/s';
}

/// How the current media reaches the party.
enum DeliveryKind {
  /// A link every app opens itself.
  link,
  /// The hosting app's file, read by everyone from its server.
  hostFile,
  /// A file the dedicated server was started with.
  serverFile,
  /// A member's machine passes it on through the server.
  memberRelay,
  /// The server reads the link itself.
  serverFetch,
  /// Jellyfin: own accounts, the server's login for the rest.
  jellyfin,
}

/// How a member gets the bytes.
enum DeliveryRoute {
  /// It serves them (a relay source, the host's file).
  source,
  /// It reads them from the server.
  server,
  /// It fetches them itself (a link, its own Jellyfin account).
  direct,
}

enum BufferHealth { good, low, starving }

/// The relay source's condition.
enum SourceState {
  ok,
  /// Measured slower than the media's bitrate.
  slow,
  /// Its channel is down (or the server has not read the link yet).
  waiting,
  /// It left the server.
  left,
}

/// Members' names by id, kept after they leave: "Foxyz left" needs the
/// name the state no longer has.
class MemberNames {
  final _names = <String, String>{};

  void observe(StateBroadcast r) {
    if (_names.length > 256) _names.clear();
    for (final m in r.members) {
      _names[m.id] = m.name;
    }
  }

  String? operator [](String id) => _names[id];
}

/// The member [m]'s route and buffer.
class MemberDelivery {
  /// Null when unknown (a Jellyfin member that has not reported yet).
  final DeliveryRoute? route;
  final DeliveryKind kind;
  /// Bytes per second the server sends it lately.
  final int rate;
  /// Null when it does not count: sitting out, reconnecting, cannot play.
  final BufferHealth? health;
  final double buffered;
  /// The media is a Jellyfin item (direct = its own account).
  final bool jellyfin;
  const MemberDelivery({
    required this.route,
    required this.kind,
    this.jellyfin = false,
    required this.rate,
    required this.health,
    required this.buffered,
  });

  /// "via server · 3.2 MB/s", "direct", "passes it on"; empty when unknown.
  String get short => switch (route) {
        DeliveryRoute.source => kind == DeliveryKind.hostFile ? 'hosts the file' : 'passes it on',
        DeliveryRoute.server => rate > 0 ? 'via server · ${formatRate(rate)}' : 'via server',
        DeliveryRoute.direct => jellyfin ? 'own Jellyfin account' : 'direct',
        null => '',
      };

  /// [short] and the buffer: "via server · 3.2 MB/s · 45 s buffered".
  String get detail => [
        if (short.isNotEmpty) short,
        if (health != null) health == BufferHealth.starving ? 'buffer empty' : '${buffered.round()} s buffered',
      ].join(' · ');
}

/// The current media's path for everyone: what the members card's source
/// line says.
class Delivery {
  final DeliveryKind kind;
  /// The member serving it ([DeliveryKind.memberRelay], [DeliveryKind.hostFile]); empty otherwise.
  final String sourceId;
  final String sourceName;
  final bool sourceIsSelf;
  final SourceState state;
  /// `media.relay.rate` / `need` (0 unknown).
  final int rate, need;
  /// Members (not sitting out, not the source) reading from the server,
  /// and fetching it themselves.
  final int viaServer, direct;
  const Delivery({
    required this.kind,
    this.sourceId = '',
    this.sourceName = '',
    this.sourceIsSelf = false,
    this.state = SourceState.ok,
    this.rate = 0,
    this.need = 0,
    this.viaServer = 0,
    this.direct = 0,
  });

  bool get relayed => kind == DeliveryKind.memberRelay || kind == DeliveryKind.serverFetch;

  /// Rate against bitrate, both known: 1 = exactly what the media needs.
  double? get headroom => rate > 0 && need > 0 ? rate / need : null;

  String get title {
    final who = sourceIsSelf ? 'You' : sourceName;
    switch (kind) {
      case DeliveryKind.link:
        return 'Everyone plays the link directly';
      case DeliveryKind.serverFile:
        return 'The server has the file';
      case DeliveryKind.hostFile:
        return sourceIsSelf ? 'You host the file' : '$who hosts the file';
      case DeliveryKind.jellyfin:
        return viaServer == 0 ? 'Everyone streams it from Jellyfin' : 'From Jellyfin';
      case DeliveryKind.serverFetch:
        return switch (state) {
          SourceState.waiting => 'The server is getting the video…',
          SourceState.slow => 'The server fetches it slower than it plays',
          _ => 'The server fetches it',
        };
      case DeliveryKind.memberRelay:
        return switch (state) {
          SourceState.left => '$sourceName left: playing what the server has',
          SourceState.waiting => sourceIsSelf ? 'Reconnecting you to the server…' : 'Waiting for $who to reconnect',
          SourceState.slow => sourceIsSelf ? 'Your upload is slower than the video' : "$who's upload is slower than the video",
          SourceState.ok => sourceIsSelf ? 'You pass it on through the server' : '$who passes it on through the server',
        };
    }
  }

  /// "3 through the server · 4.1 MB/s, needs 2.3 MB/s"; empty when
  /// there is nothing to add.
  String get detail {
    final parts = <String>[
      if (direct > 0 && (kind == DeliveryKind.jellyfin || kind == DeliveryKind.memberRelay))
        '$direct with their own account',
      if (viaServer > 0 && kind != DeliveryKind.link) '$viaServer through the server',
      if (rate > 0 && state != SourceState.left) need > 0 ? '${formatRate(rate)}, needs ${formatRate(need)}' : formatRate(rate),
    ];
    return parts.join(' · ');
  }

  /// The hover text: what the numbers mean.
  String get explain => switch (kind) {
        DeliveryKind.memberRelay || DeliveryKind.serverFetch => [
            if (rate > 0)
              '${kind == DeliveryKind.serverFetch ? 'The server gets' : sourceIsSelf ? 'You send' : '$sourceName sends'} '
                  '${formatRate(rate)} while the server asks for more.',
            if (need > 0) 'The video averages ${formatRate(need)}.',
            if (state == SourceState.slow) 'Slower than the video: the others will pause to buffer.',
            if (rate == 0) 'The speed shows once bytes have flowed for a few seconds.',
          ].join(' '),
        DeliveryKind.hostFile || DeliveryKind.serverFile => 'Everyone else reads the file from the server.',
        DeliveryKind.jellyfin => 'Members with an account on that Jellyfin stream it themselves; '
            'the rest through the server.',
        DeliveryKind.link => 'Each app opens the link itself; the server only keeps time.',
      };
}

/// The current media's [Delivery]; null with nothing up or nobody else in
/// the server. [names] remembers a source that left.
Delivery? deliveryOf(StateBroadcast r, {required String selfId, MemberNames? names}) {
  final media = r.media;
  if (media == null || r.members.length < 2) return null;
  final rel = media['relay'];
  final relay = rel is Map ? MediaRelay.fromJson(Map<String, Object?>.from(rel)) : null;
  final ref = refOfStateMedia(media);
  final url = media['url'];
  final kind = relay != null
      ? (relay.fetch ? DeliveryKind.serverFetch : DeliveryKind.memberRelay)
      : ref != null
          ? DeliveryKind.jellyfin
          : url is String && url.isNotEmpty
              ? DeliveryKind.link
              : r.members.any((m) => m.host)
                  ? DeliveryKind.hostFile
                  : DeliveryKind.serverFile;
  final sourceId = switch (kind) {
    DeliveryKind.memberRelay => relay!.source,
    DeliveryKind.hostFile => r.members.firstWhere((m) => m.host).id,
    _ => '',
  };
  final source = r.members.where((m) => m.id == sourceId).firstOrNull;
  var via = 0, direct = 0;
  for (final m in r.members) {
    if (!isPresent(m) || m.id == sourceId) continue;
    switch (routeOf(m, kind, sourceId, ref, r.relay)) {
      case DeliveryRoute.server:
        via++;
      case DeliveryRoute.direct:
        direct++;
      default:
        break;
    }
  }
  // A Jellyfin item that everyone streams with their own account: the
  // relay stands by, nothing goes through it.
  if (kind == DeliveryKind.memberRelay && ref != null && via == 0 && source != null) {
    return Delivery(kind: DeliveryKind.jellyfin, direct: direct);
  }
  final state = relay == null
      ? SourceState.ok
      : kind == DeliveryKind.memberRelay && source == null
          ? SourceState.left
          : !relay.live
              ? SourceState.waiting
              : relay.slow
                  ? SourceState.slow
                  : SourceState.ok;
  return Delivery(
    kind: kind,
    sourceId: sourceId,
    sourceName: source?.name ?? names?[sourceId] ?? 'The member passing it on',
    sourceIsSelf: sourceId.isNotEmpty && sourceId == selfId,
    state: state,
    rate: relay?.rate ?? 0,
    need: relay?.need ?? 0,
    viaServer: via,
    direct: direct,
  );
}

/// How [m] gets media of [kind] served by [sourceId]. Jellyfin: by its
/// last `report.jf` for [ref]'s server ([jellyfinRelay]: the server can
/// relay it); null before it reported.
DeliveryRoute? routeOf(MemberView m, DeliveryKind kind, String sourceId, JellyfinRef? ref, bool jellyfinRelay) {
  if (sourceId.isNotEmpty && m.id == sourceId) return DeliveryRoute.source;
  switch (kind) {
    case DeliveryKind.link:
      return DeliveryRoute.direct;
    case DeliveryKind.hostFile:
    case DeliveryKind.serverFile:
    case DeliveryKind.serverFetch:
      return DeliveryRoute.server;
    case DeliveryKind.memberRelay:
    case DeliveryKind.jellyfin:
      final own = ref == null ? null : m.jf[ref.serverId];
      if (own == true) return DeliveryRoute.direct;
      if (kind == DeliveryKind.memberRelay) return DeliveryRoute.server;
      return own == false && jellyfinRelay ? DeliveryRoute.server : null;
  }
}

/// [m]'s route and buffer for [d] (from [deliveryOf] on [r]).
MemberDelivery memberDeliveryOf(MemberView m, StateBroadcast r, Delivery d) {
  final counts = countsForReady(m);
  final need = r.bufferNeed;
  final ref = refOfStateMedia(r.media);
  final health = !counts
      ? null
      : m.buffered >= need
          ? BufferHealth.good
          : r.transport == 'playing' && m.buffered < 1
              ? BufferHealth.starving
              : BufferHealth.low;
  return MemberDelivery(
    route: m.presence == Presence.away ? null : routeOf(m, d.kind, d.sourceId, ref, r.relay),
    kind: d.kind,
    jellyfin: ref != null,
    rate: m.rate,
    health: health,
    buffered: m.buffered,
  );
}

/// What the source is told once per media when it is too slow; null
/// while it keeps up (or this member is not the source).
String? slowSourceWarning(StateBroadcast r, String selfId) {
  final rel = r.media?['relay'];
  if (rel is! Map || selfId.isEmpty) return null;
  final relay = MediaRelay.fromJson(Map<String, Object?>.from(rel));
  if (relay.source != selfId || !relay.slow) return null;
  return 'Your upload (${formatRate(relay.rate)}) is slower than this video needs '
      '(${formatRate(relay.need)}): the others will pause to buffer now and then.';
}
