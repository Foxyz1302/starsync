import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';
import 'package:web_socket/web_socket.dart';

import 'queue_ops.dart';
import 'relay_routes.dart';
import 'relay_stats.dart';
import 'session.dart';

final _hubLog = createLogger('server_hub');

class ServerHub {
  final SessionMap sessions;
  final String expectedSecret;
  /// See [AppConfig.hostKey]; empty means nobody is the host.
  final String hostKey;
  final SyncEngine engine;
  /// The `/sync` socket of each member that has one, by token; a `gone`
  /// member has none.
  final Map<String, RelicWebSocket> sockets = {};
  /// The server's Jellyfin login for the `/j/...` relay; null = no relay.
  JellyfinCredential? jellyfin;
  /// Reads web pages for "the server fetches it"; null = files only.
  final YtDlp? ytDlp;
  /// Random per server boot (`welcome.instance`).
  final String instance = _randomId();

  ServerHub(this.sessions, this.expectedSecret,
      {SyncEngine? engine, this.hostKey = '', this.jellyfin, this.ytDlp})
      : engine = engine ?? SyncEngine() {
    this.engine
      ..onGone = _memberGone
      ..onLeft = _memberLeft;
  }

  static String _randomId() {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(12, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  /// A member went `gone`: a socket still open (silent) is closed; a
  /// relay it serves goes on from its buffer (`media.relay.sourceGone`).
  void _memberGone(EngineMember m) {
    _hubLog.info('gone ${m.name} (${m.id})');
    final ws = sockets.remove(m.token);
    if (ws != null) unawaited(closeWith(ws, CloseCodes.silent, 'silent'));
    refreshRelaySource();
  }

  /// A member left for good (`bye`, grace over): its token stops working,
  /// a relay it serves ends.
  void _memberLeft(EngineMember m) {
    _hubLog.info('leave ${m.name} (${m.id})');
    final ws = sockets.remove(m.token);
    if (ws != null) unawaited(closeWith(ws, CloseCodes.left, 'left'));
    session.tokens.remove(m.token);
    final r = relay;
    if (r != null && !r.fetch && r.sourceToken == m.token) {
      _endRelay(r, 'its source left', sourceGone: true, since: m.goneSince ?? engine.now);
    }
  }

  /// The current relay ends (its source left, or sent another media):
  /// the buffer goes, `/r` answers 404, `media.relay` stays with `live`
  /// false.
  void _endRelay(ActiveRelay r, String why, {bool sourceGone = false, DateTime? since}) {
    if (!identical(relay, r)) return;
    _hubLog.info('relay of "${r.name}" ended: $why');
    setRelay(null);
    final m = engine.media;
    final was = m?.relay;
    if (m != null && was != null) {
      engine.media = m.copyWith(
          relay: was.copyWith(live: false, rate: 0, sourceGone: sourceGone, sourceGoneSince: since));
    }
  }

  /// The source of [r] sent an `info` unlike its first (another media):
  /// the relay ends (warm: dropped, made again from the next `info`).
  void relayOtherMedia(ActiveRelay r) {
    if (identical(warm, r)) {
      _setWarm(null);
    } else {
      _endRelay(r, 'its source sent another media');
    }
    changed();
  }

  /// `media.relay.sourceGone` / `sourceGoneSince` follow the current
  /// relay's source member (`gone` or back).
  void refreshRelaySource() {
    final r = relay, m = engine.media;
    final was = m?.relay;
    if (r == null || m == null || was == null || r.fetch || r.sourceToken == null) return;
    final src = engine.members[r.sourceToken];
    final gone = src == null || src.presence == Presence.gone;
    if (gone == was.sourceGone) return;
    _hubLog.info('relay of "${r.name}": source ${gone ? 'gone, viewers play what is buffered' : 'back'}');
    engine.media = m.copyWith(relay: was.copyWith(sourceGone: gone, sourceGoneSince: src?.goneSince ?? engine.now));
  }

  bool get _sourceGone => engine.media?.relay?.sourceGone ?? false;

  /// The current media is a Jellyfin ref on the server [jellyfin] logs in to.
  bool get relayAvailable => _onLogin(session.media?.jellyfin);

  /// Up next's first item is a Jellyfin ref on that server: `/j` serves it
  /// too, so viewers without access get it ready.
  bool get relayNextAvailable => _onLogin(nextJellyfinRef);

  /// Up next's first item's Jellyfin ref (null: none, or not a ref).
  JellyfinRef? get nextJellyfinRef => engine.queue.items.firstOrNull?.media.jellyfin;

  bool _onLogin(JellyfinRef? ref) {
    final cred = jellyfin;
    return ref != null && cred != null && cred.serverId.isNotEmpty && cred.serverId == ref.serverId;
  }

  /// What the swapper reads when the server cannot fetch a link ([why]
  /// from the relay). A yt-dlp failure on a server without cookies says
  /// so, unless cookies would not help (unknown site, gone, unreachable).
  String fetchFailText(String why) {
    const head = "The server can't fetch this link";
    final y = ytDlp;
    final plain = playErrorText(why);
    final cookiesMightHelp = y != null &&
        y.enabled &&
        why.contains('yt-dlp') &&
        !const {unsupportedUrlText, notFoundText, unreachableText}.contains(plain) &&
        y.cookies.read(count: false) == null;
    return cookiesMightHelp
        ? '$head: it has no cookies (set them in Settings → Player → yt-dlp on the hosting app, or --yt-dlp-cookies)'
        : '$head: $why';
  }

  StateBroadcast stateBroadcast() => engine.broadcast(
      relay: relayAvailable, relayNext: relayNextAvailable, warm: _warmView(), sourceGone: _sourceGone);

  /// The relay of the current media (`/r/...`), if it is relayed.
  ActiveRelay? relay;

  /// Replaces the relay (null: the new media is not relayed). The old
  /// buffer is dropped with it.
  void setRelay(ActiveRelay? next) {
    if (!identical(relay, next)) {
      final old = relay;
      if (old != null) _hubLog.info('relay of "${old.name}" dropped (sent ${_sent(old)})');
      old?.dispose();
    }
    relay = next;
  }

  static String _sent(ActiveRelay r) =>
      '${(r.buffers.fold<int>(0, (a, b) => a + b.bytesFromFeed) / 1048576).toStringAsFixed(1)} MiB in';

  /// The warm relay: Up next's first item relayed before it goes up, so
  /// every viewer preloads it (see ARCHITECTURE "Getting ready"); null
  /// when that item is not relayed (or nobody would read it).
  ActiveRelay? warm;

  void _setWarm(ActiveRelay? next) {
    if (!identical(warm, next)) {
      final old = warm;
      if (old != null) _hubLog.info('warm relay of Up next ${old.queueId} ("${old.name}") dropped (${_sent(old)})');
      old?.dispose();
      if (next != null) {
        _hubLog.info('warm relay of Up next ${next.queueId} ("${next.name}"): '
            '${next.fetch ? 'the server fetches it' : next.sourceId.isEmpty ? 'from the first member with an account' : 'from ${next.sourceId}'}');
      }
    }
    warm = next;
  }

  /// Drops both relays (server stop).
  void dropRelays() {
    setRelay(null);
    _setWarm(null);
  }

  /// `queue[0].media.relay` while the warm relay exists.
  ({String id, MediaRelay relay})? _warmView() {
    final w = warm, id = w?.queueId;
    if (w == null || id == null) return null;
    final src = w.sourceToken == null ? null : engine.members[w.sourceToken];
    final gone = src?.presence == Presence.gone;
    return (
      id: id,
      relay: MediaRelay(
          source: w.fetch ? '' : w.sourceId,
          fetch: w.fetch,
          live: w.live,
          tracks: w.live ? w.tracks : const [],
          sourceGone: gone,
          sourceGoneSince: gone ? src?.goneSince : null),
    );
  }

  /// Keeps [warm] on Up next's first item when it is relayed: a link the
  /// server fetches (its fetch starts now), a link passed on or a file
  /// (its adder's app feeds it, while someone else is here to read it;
  /// not the host's own file), a
  /// Jellyfin item that someone here cannot play and the server's login
  /// does not cover (the first member with an account feeds it). Called
  /// on every change; anything else drops it.
  void syncWarm() {
    final first = engine.queue.items.firstOrNull;
    final w = warm;
    if (w != null && (first == null || w.queueId != first.id || !_keepWarm(w, first))) _setWarm(null);
    if (warm == null && first != null) _setWarm(_newWarm(first));
  }

  bool _othersHere(String? memberId) =>
      engine.members.values.any((m) => m.id != memberId && m.presence != Presence.gone);

  /// A Jellyfin [ref] someone here cannot play while someone can, outside
  /// the server's login.
  bool _jellyfinNeedsWarm(JellyfinRef ref) =>
      !_onLogin(ref) &&
      engine.members.values
          .any((m) => engine.policy.countsFor(m.presence, Purpose.preload) && m.jf[ref.serverId] != true) &&
      engine.members.values.any((m) => m.jf[ref.serverId] == true);

  bool _keepWarm(ActiveRelay w, QueueItem first) {
    switch (first.how) {
      case QueueHow.server:
        return w.fetch;
      case QueueHow.through:
      case QueueHow.file:
        final adder = engine.byId(first.by);
        return adder != null && adder.token == w.sourceToken && _othersHere(adder.id);
      case QueueHow.jellyfin:
        final ref = first.media.jellyfin;
        final src = w.sourceToken;
        return ref != null && _jellyfinNeedsWarm(ref) && (src == null || engine.members.containsKey(src));
      case QueueHow.direct:
        return false;
    }
  }

  ActiveRelay? _newWarm(QueueItem first) {
    final id = first.id;
    final name = sanitizeMediaName(first.media.name.isEmpty ? first.title : first.media.name);
    late final ActiveRelay r;
    switch (first.how) {
      case QueueHow.server:
        final url = Uri.tryParse(engine.queue.privateUrlOf(id) ?? '');
        if (url == null || session.secret.isEmpty) return null;
        r = ActiveRelay.fetchLink(-1, name, url, ytDlp: ytDlp, queueId: id, onLiveChanged: () => relayLiveChanged(r));
      case QueueHow.through:
      case QueueHow.file:
        final adder = engine.byId(first.by);
        // The host's own file plays from its `/m` URL, never relayed.
        if (adder == null || !_othersHere(adder.id) || (adder.host && first.how == QueueHow.file)) return null;
        r = ActiveRelay.warmFromMember(id, name, adder.token,
            sourceId: adder.id, onLiveChanged: () => relayLiveChanged(r));
      case QueueHow.jellyfin:
        final ref = first.media.jellyfin;
        if (ref == null || !_jellyfinNeedsWarm(ref)) return null;
        r = ActiveRelay.warmFromMember(id, name, null, onLiveChanged: () => relayLiveChanged(r));
      case QueueHow.direct:
        return null;
    }
    return r;
  }

  /// The relay `/r/.../<key>/...` reads: the current one by its media id,
  /// or by the queue id it was started for, or the warm one.
  ActiveRelay? relayAt(String key) {
    final r = relay, w = warm;
    final mediaId = int.tryParse(key);
    if (mediaId != null) return r != null && r.mediaId == mediaId ? r : null;
    if (key.isEmpty) return null;
    if (w != null && w.queueId == key) return w;
    if (r != null && r.queueId == key) return r;
    return null;
  }

  /// The relay member [token] may feed on its channel: the current one
  /// ([queueId] null), or the one of Up next item [queueId] (warm or
  /// already promoted). A warm Jellyfin item takes the first member with
  /// an account on that server that dials in.
  ActiveRelay? sourceOf(String token, String? queueId) {
    if (queueId == null || queueId.isEmpty) {
      final r = relay;
      return r != null && r.sourceToken == token ? r : null;
    }
    final r = relayAt(queueId);
    if (r == null || r.fetch) return null;
    if (r.sourceToken == null && identical(r, warm)) {
      final ref = engine.queue.item(queueId)?.media.jellyfin;
      final m = engine.members[token];
      if (ref == null || m == null || m.jf[ref.serverId] != true) return null;
      r
        ..sourceToken = token
        ..sourceId = m.id;
      broadcastState();
    }
    return r.sourceToken == token ? r : null;
  }

  /// A swap of Up next item [queueId] by [token]: its warm relay, when it
  /// can become the media's (the same kind of relay; a member's from its
  /// own source with the same tracks), else null. Taken either way: the
  /// item goes up now.
  ActiveRelay? takeWarm(String? queueId, String token, {required bool fetch, List<RelayTrackSpec> tracks = const []}) {
    final w = warm;
    if (queueId == null || w == null || w.queueId != queueId) return null;
    warm = null;
    final ok = fetch
        ? w.fetch && !w.failed
        : !w.fetch && w.sourceToken == token && (!w.known || _sameTracks(w.tracks, tracks));
    if (ok) {
      _hubLog.info('warm relay of Up next $queueId promoted (${_sent(w)}, live ${w.live})');
      w.ensureTracks(tracks);
      return w;
    }
    _hubLog.info('warm relay of Up next $queueId not promoted (${w.failed ? 'its fetch failed' : 'another kind or source'})');
    w.dispose();
    return null;
  }

  static bool _sameTracks(List<RelayTrackSpec> a, List<RelayTrackSpec> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  /// `media.relay` for a relayed swap by [token]: who serves the bytes
  /// and, from a member, its tracks (the server finds a fetched link's).
  MediaRelay relayFor(String token, MediaRelay requested) => requested.fetch
      ? const MediaRelay(fetch: true)
      : MediaRelay(source: engine.members[token]?.id ?? '', tracks: requested.tracks);

  /// `media.relay` of a promoted warm relay [w] (Up next item [queueId]).
  MediaRelay promotedRelay(ActiveRelay w, String queueId) => w.fetch
      ? MediaRelay(fetch: true, live: w.live, tracks: w.live ? w.tracks : const [], queueId: queueId)
      : MediaRelay(source: w.sourceId, live: w.live, tracks: w.tracks, queueId: queueId);

  /// The relay's channel came up or went down, or a fetched link was read:
  /// `media.relay.live` and `tracks` follow (the warm one's in `queue`).
  void relayLiveChanged(ActiveRelay r) {
    if (identical(warm, r)) {
      broadcastState();
      return;
    }
    final m = engine.media;
    if (!identical(relay, r) || m?.relay == null) return;
    final was = m!.relay!;
    if (was.live == r.live && was.tracks.join(',') == r.tracks.join(',')) return;
    if (was.live != r.live) _hubLog.info('relay of "${r.name}" ${r.live ? 'live' : 'not live (source away)'}');
    engine.media = m.copyWith(relay: was.copyWith(live: r.live, tracks: r.tracks));
    changed();
  }

  final _readRates = ReadRates();
  var _statTicks = 0;

  static String _kbs(int bytesPerSec) => '${(bytesPerSec / 1024).round()} KiB/s';

  /// Once a second: each member's read rate (`members[].rate`) and the
  /// relay's source rate and bitrate (`media.relay.rate` / `need`). Goes
  /// out with the next state.
  void sampleRates() {
    final tokens = session.tokens;
    final rates = _readRates.sample(engine.now, {
      for (final t in engine.members.keys) t: tokens[t]?.bytesServed ?? 0,
    });
    for (final m in engine.members.values) {
      m.rate = rates[m.token] ?? 0;
    }
    final r = relay, m = engine.media;
    final was = m?.relay;
    if (r == null || m == null || was == null || r.mediaId != engine.mediaId) return;
    r.sampleRate();
    final rate = r.rate, need = r.need(m.duration);
    if (++_statTicks % 30 == 0 && r.live) {
      final readers = engine.members.values.where((x) => x.rate > 0).map((x) => '${x.name} ${_kbs(x.rate)}');
      _hubLog.info('relay stats "${r.name}": source ${_kbs(rate)}, needs ${_kbs(need)}, '
          'buffered ${(r.cachedBytes / 1048576).toStringAsFixed(1)} MiB, ${_sent(r)}'
          '${readers.isEmpty ? '' : '; reading: ${readers.join(', ')}'}');
    }
    if (rate != was.rate || need != was.need) {
      engine.media = m.copyWith(relay: was.copyWith(rate: rate, need: need));
    }
  }

  bool isHostKey(String key) => hostKey.isNotEmpty && key == hostKey;

  /// A member for the log: `name (id)`, never its token or client id.
  String who(String token) {
    final m = engine.members[token];
    if (m != null) return '${m.name} (${m.id})';
    final v = session.tokens[token];
    return v != null ? '${v.name} (no member)' : 'unknown member';
  }

  Session get session => sessions.getOrCreate('default', expectedSecret);

  void broadcastState() {
    final raw = jsonEncode(stateBroadcast().toJson());
    for (final ws in sockets.values.toList()) {
      ws.trySendText(raw);
    }
  }

  /// Once a second: closed sockets, then the engine's sweep (silence,
  /// joining, gone notices, grace), relay source, warm relay, rates, and
  /// a state for everyone.
  void heartbeat() {
    sweepClosedSockets();
    engine.tick();
    refreshRelaySource();
    syncWarm();
    sampleRates();
    broadcastState();
    broadcastFeed();
  }

  void broadcastFeed() {
    for (final feed in engine.feed.drain()) {
      final raw = jsonEncode(feed.toJson());
      for (final ws in sockets.values.toList()) {
        ws.trySendText(raw);
      }
    }
  }

  /// Relic's server-side `onDone` does not fire for every dead peer:
  /// sockets are polled with `isClosed` too.
  void sweepClosedSockets() {
    for (final entry in sockets.entries.toList()) {
      var closed = false;
      try {
        closed = entry.value.isClosed;
      } catch (_) {
        closed = true;
      }
      if (closed) socketClosed(entry.key, entry.value);
    }
  }

  Future<void> closeAllSockets() async {
    final all = sockets.values.toList();
    sockets.clear();
    for (final ws in all) {
      try {
        await ws.tryClose();
      } catch (_) {}
    }
  }

  void broadcastChat(String from, String text, {String fromId = ''}) {
    final clean = text.length > RelayConstants.maxChatLength
        ? text.substring(0, RelayConstants.maxChatLength)
        : text;
    final raw = jsonEncode(
        ChatMessage(text: clean).toJson()..addAll({'from': from, if (fromId.isNotEmpty) 'fromId': fromId}));
    for (final ws in sockets.values.toList()) {
      ws.trySendText(raw);
    }
    engine.feed.add(FeedMessage(actor: from, actorId: fromId, action: 'chat', at: engine.now));
    broadcastFeed();
  }

  /// The server's own fetch of [name] failed: everyone hears it (the
  /// swapper also gets the reason as an error), not just "getting it…".
  void fetchFailed(String name) {
    engine.feed.add(FeedMessage(actor: 'server', actorId: 'server', action: 'fetch-fail', target: name, at: engine.now));
    broadcastFeed();
  }

  void changed() {
    syncWarm();
    broadcastState();
    broadcastFeed();
  }

  /// [ws], [token]'s socket, closed: the member is `gone` (kept for the
  /// grace). A socket that is no longer the member's (taken over) changes
  /// nothing.
  void socketClosed(String token, RelicWebSocket ws) {
    if (!identical(sockets[token], ws)) return;
    sockets.remove(token);
    engine.applyGone(token);
    changed();
  }

  /// `bye`: [token]'s member leaves now.
  void bye(String token) {
    engine.applyLeave(token, reason: 'bye');
    changed();
  }

  /// Passes a nudge from [fromToken] to the member [targetId] only;
  /// over the sender's rate cap, to itself or to nobody it is dropped.
  void nudge(String fromToken, String targetId) {
    final from = engine.members[fromToken];
    final target = engine.byId(targetId);
    final viewer = session.tokens[fromToken];
    if (from == null || target == null || viewer == null || identical(from, target)) return;
    if (!viewer.takeNudge(engine.now)) return;
    sockets[target.token]?.trySendText(jsonEncode(NudgeNotice(from: from.id, name: from.name).toJson()));
  }
}

/// How a swap's media plays, for the log (a link's query cut to names).
String _swapKind(HelloMedia m) {
  final relay = m.relay;
  final url = (m.url ?? '').isEmpty ? '' : ' ${logUrl(m.url)}';
  if (m.jellyfin != null) return 'Jellyfin item ${m.jellyfin!.itemId}${relay == null ? '' : ', relayed from the swapper'}';
  if (relay == null) return url.isEmpty ? 'hosted file' : 'link, everyone fetches it:$url';
  if (relay.fetch) return 'link, the server fetches it:$url';
  final tracks = relay.tracks.isEmpty ? 'one file' : relay.tracks.map((t) => t.toJson().values.join('/')).join(' + ');
  return 'through the swapper ($tracks, ${m.size} bytes)';
}

/// `GET /a/<sid>/<token>/<hash>`: a current member's picture by its
/// content hash, for members (valid token) only. The bytes for a
/// hash never change, so clients may cache them for good.
void mountAvatarRoute(RelicApp app, ServerHub hub) =>
    _mountPictureRoute(app, hub, 'a', hub.engine.avatarFor);

/// `GET /i/<sid>/<token>/<hash>`: the current media's art (`art`) by hash,
/// same rules as [mountAvatarRoute].
void mountArtRoute(RelicApp app, ServerHub hub) =>
    _mountPictureRoute(app, hub, 'i', hub.engine.artFor);

void _mountPictureRoute(RelicApp app, ServerHub hub, String prefix, Uint8List? Function(String hash) lookup) {
  Response status(int code) => Response(code, body: Body.fromString('status $code'));
  app.get('/$prefix/:sid/:token/:hash', (final req) {
    final sid = req.pathParameters.raw[#sid] ?? '';
    final token = req.pathParameters.raw[#token] ?? '';
    final hash = req.pathParameters.raw[#hash] ?? '';
    final session = hub.sessions.get(sid);
    if (session == null) return status(410);
    switch (session.gate(token)) {
      case MediaGate.unauthorized:
        return status(401);
      default:
        break;
    }
    final bytes = lookup(hash);
    final type = bytes == null ? null : avatarImageType(bytes);
    if (bytes == null || type == null) return status(404);
    return Response.ok(
      body: Body.fromData(bytes, mimeType: MimeType(type.$1, type.$2)),
      headers: Headers.build((h) {
        h['cache-control'] = ['private, max-age=31536000, immutable'];
      }),
    );
  });
}

/// Media names are shown to everyone and must never carry a URL (api_key etc.).
/// A URL-looking name is reduced to its last path segment, no query/fragment.
String sanitizeMediaName(String name) {
  final trimmed = name.trim();
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed)) return name;
  final uri = Uri.tryParse(trimmed);
  final segments = uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
  if (segments.isNotEmpty) return segments.last;
  return 'media';
}

/// Sends `err` [code] with [message] (plain text for people) and, when a
/// frame failed, its type as `for`. The socket stays open.
void wsErr(RelicWebSocket ws, ErrCode code, String message, {String? forType}) {
  ws.trySendText(jsonEncode(ErrorFrame(code: code, message: message, forType: forType).toJson()));
}

/// Closes [ws] with [code] (see [CloseCodes]); a socket that is already
/// gone is fine.
Future<void> closeWith(RelicWebSocket ws, int code, String reason) async {
  try {
    await ws.close(code, reason);
  } catch (_) {
    await ws.tryClose();
  }
}

/// Jellyfin ids are path segments of upstream requests: keep them plain.
final _jellyfinId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

/// The swap's Jellyfin ref cleaned for broadcast (names like
/// [sanitizeMediaName]), or null when its ids are unusable.
JellyfinRef? sanitizeJellyfinRef(JellyfinRef ref) {
  if (!_jellyfinId.hasMatch(ref.serverId) || !_jellyfinId.hasMatch(ref.itemId)) return null;
  final source = ref.mediaSourceId;
  if (source != null && !_jellyfinId.hasMatch(source)) return null;
  final runtime = ref.runtimeSecs;
  return JellyfinRef(
    serverId: ref.serverId,
    itemId: ref.itemId,
    mediaSourceId: source,
    title: sanitizeMediaName(ref.title),
    subtitle: ref.subtitle == null ? null : sanitizeMediaName(ref.subtitle!),
    runtimeSecs: runtime == null || runtime < 0 ? null : runtime,
  );
}

/// [relayUrlBuilder] builds a member's `/j/...` URL for `welcome.relayUrl`.
void mountSyncRoute(
  RelicApp app,
  ServerHub hub,
  String Function(String sid, String token, SessionMedia? media, String host)
      urlBuilder, {
  String Function(String sid, String token, String itemId, String host)? relayUrlBuilder,
  /// `key`: the media id, or the queue id of a relay started in Up next.
  String Function(String sid, String token, String key, String name, List<RelayTrackSpec> tracks, String host)?
      relayMediaUrlBuilder,
}) {
  app.get('/sync', (final req) {
    // Host the client dialled (Host header), so file URLs work for remote joiners.
    final dialledHost = req.url.hasPort
        ? '${req.url.host.contains(':') ? '[${req.url.host}]' : req.url.host}:${req.url.port}'
        : (req.url.host.contains(':') ? '[${req.url.host}]' : req.url.host);
    return WebSocketUpgrade((final ws) async {
      ws.pingInterval = hub.engine.liveness.pingInterval;
      final firstText = Completer<String>();
      String? token;
      var welcomed = false;
      late StreamSubscription<WebSocketEvent> sub;
      Future<void> close() async {
        try {
          await sub.cancel();
        } catch (_) {}
        await ws.tryClose();
      }

      void handleIntent(String text) {
        // A socket another hello took over says nothing for the member.
        if (token != null && !identical(hub.sockets[token], ws)) return;
        final session = hub.session;
        final viewer = token == null ? null : session.tokens[token];
        viewer?.touch(hub.engine.now);
        if (token != null) hub.engine.touch(token);
        Map<String, Object?> decoded;
        try {
          final parsed = jsonDecode(text);
          if (parsed is! Map) return;
          decoded = Map<String, Object?>.from(parsed);
        } catch (_) {
          return;
        }
        final type = decoded['t'];
        try {
          switch (type) {
            case 'ready':
              if (token == null) return;
              final intent = ReadyIntent.fromJson(decoded);
              hub.engine.applyReady(token, intent.ready, source: intent.source);
              hub.changed();
            case 'force':
              if (token == null) return;
              final intent = ForceIntent.fromJson(decoded);
              hub.engine.applyForce(token, intent.target, intent.ready);
              hub.changed();
            case 'seek':
              if (token == null) return;
              final intent = SeekIntent.fromJson(decoded);
              hub.engine.applySeek(token, intent.position, seq: intent.seq);
              hub.changed();
            case 'swap':
              if (token == null) return;
              final swap = SwapIntent.fromJson(decoded);
              var parsed = swap.media;
              final queueId = swap.queueId;
              _hubLog.info('swap by ${hub.who(token)}: "${parsed.name}" ${_swapKind(parsed)}'
                  '${queueId == null ? '' : ' (Up next $queueId)'}');
              if (queueId != null) {
                // Already put up by someone else: nothing to do.
                if (!hub.engine.queue.has(queueId)) return;
                // A server-fetched item's link never left the server.
                final hidden = hub.engine.queue.privateUrlOf(queueId);
                if (hidden != null && (parsed.url ?? '').isEmpty) {
                  parsed = HelloMedia(
                      name: parsed.name,
                      size: parsed.size,
                      duration: parsed.duration,
                      url: hidden,
                      relay: parsed.relay,
                      ref: parsed.ref);
                }
              }
              if (parsed.jellyfin != null) {
                // By reference only: no URL (it could carry a token) is
                // stored or broadcast for Jellyfin media.
                final ref = sanitizeJellyfinRef(parsed.jellyfin!);
                // Relayed for viewers without access: from the swapper's
                // machine (its own sign-in never leaves it).
                final relayReq = parsed.relay == null || parsed.relay!.fetch ? null : parsed.relay;
                // Up next's warm relay of this item carries on as its relay.
                final promoted = relayReq == null || ref == null ? null : hub.takeWarm(queueId, token, fetch: false);
                final media = ref == null
                    ? null
                    : HelloMedia(
                        name: promoted?.name ?? sanitizeMediaName(parsed.name.isEmpty ? ref.title : parsed.name),
                        size: parsed.size,
                        duration: parsed.duration,
                        jellyfin: ref,
                        ref: parsed.ref,
                        relay: relayReq == null
                            ? null
                            : promoted != null
                                ? hub.promotedRelay(promoted, queueId!)
                                : hub.relayFor(token, const MediaRelay()));
                if (media == null || !hub.engine.applySwap(token, media, queueId: queueId)) {
                  promoted?.dispose();
                  wsErr(ws, ErrCode.bad, 'bad swap media', forType: 'swap');
                  return;
                }
                session.media = SessionMedia(
                    name: media.name,
                    size: media.size,
                    duration: media.duration,
                    jellyfin: ref,
                    mediaId: hub.engine.mediaId);
                hub.setRelay(relayReq == null
                    ? null
                    : promoted != null
                        ? (promoted..promote(hub.engine.mediaId))
                        : _memberRelay(hub, token, media.name, const []));
                hub.changed();
                return;
              }
              final relayReq = parsed.relay;
              if (relayReq != null) {
                // Relayed file or link: no URL is stored or broadcast (a
                // link may be private to the swapper; the server keeps a
                // fetched one to itself).
                final name = sanitizeMediaName(parsed.name.isEmpty ? 'media' : parsed.name);
                final link = Uri.tryParse(parsed.url ?? '');
                if (relayReq.fetch &&
                    (link == null || !(link.isScheme('http') || link.isScheme('https')) || link.host.isEmpty)) {
                  wsErr(ws, ErrCode.bad, 'relay fetch needs an http(s) url', forType: 'swap');
                  return;
                }
                // The server would fetch any address it can reach (its own
                // network, a VPN) for whoever asks: only for members who
                // know the password.
                if (relayReq.fetch && session.secret.isEmpty) {
                  wsErr(ws, ErrCode.rejected, 'server fetch needs a server password', forType: 'swap');
                  return;
                }
                // Up next's warm relay of this item carries on as its relay
                // (its buffer, its feed, its `/r/.../<queueId>/` URLs).
                final promoted = hub.takeWarm(queueId, token, fetch: relayReq.fetch, tracks: relayReq.tracks);
                final shown = promoted?.name ?? name;
                final media = HelloMedia(
                    name: shown,
                    size: parsed.size,
                    duration: parsed.duration,
                    ref: parsed.ref,
                    relay: promoted != null ? hub.promotedRelay(promoted, queueId!) : hub.relayFor(token, relayReq));
                if (!hub.engine.applySwap(token, media, queueId: queueId)) {
                  promoted?.dispose();
                  wsErr(ws, ErrCode.bad, 'bad swap media', forType: 'swap');
                  return;
                }
                session.media = SessionMedia(
                    name: shown, size: parsed.size, duration: parsed.duration, mediaId: hub.engine.mediaId);
                void failed(String why) {
                  wsErr(ws, ErrCode.rejected, hub.fetchFailText(why), forType: 'swap');
                  hub.fetchFailed(shown);
                }
                late final ActiveRelay active;
                if (promoted != null) {
                  active = promoted..promote(hub.engine.mediaId);
                  if (active.fetch) {
                    active.onFail = failed;
                  }
                } else {
                  active = relayReq.fetch
                      ? ActiveRelay.fetchLink(hub.engine.mediaId, name, link!,
                          ytDlp: hub.ytDlp, onLiveChanged: () => hub.relayLiveChanged(active), onFail: failed)
                      : _memberRelay(hub, token, name, media.relay!.tracks);
                }
                hub.setRelay(active);
                hub.changed();
                return;
              }
              final intent = SwapIntent(
                  media: HelloMedia(
                      name: sanitizeMediaName(parsed.name),
                      size: parsed.size,
                      duration: parsed.duration,
                      url: parsed.url,
                      ref: parsed.ref));
              final current = session.media;
              final matchesFile = current?.file != null &&
                  current!.name == intent.media.name &&
                  current.size == intent.media.size;
              if (!matchesFile && (intent.media.url ?? '').isEmpty) {
                wsErr(ws, ErrCode.bad, 'swap needs a url or the hosted file', forType: 'swap');
                return;
              }
              if (!hub.engine.applySwap(token, intent.media, queueId: queueId)) {
                wsErr(ws, ErrCode.bad, 'bad swap media', forType: 'swap');
                return;
              }
              hub.setRelay(null);
              if (matchesFile) {
                session.media = SessionMedia(
                    name: current.name,
                    size: current.size,
                    duration: intent.media.duration,
                    url: intent.media.url,
                    file: current.file,
                    mediaId: hub.engine.mediaId);
              } else {
                session.media = SessionMedia(
                    name: intent.media.name,
                    size: intent.media.size,
                    duration: intent.media.duration,
                    url: intent.media.url,
                    mediaId: hub.engine.mediaId);
              }
              hub.changed();
            case 'profile':
              if (token == null || viewer == null) return;
              final intent = ProfileIntent.fromJson(decoded);
              final avatar = intent.avatar;
              if (avatar != null && avatar.length > RelayConstants.maxAvatarBytes) {
                wsErr(ws, ErrCode.rejected, 'rejected: avatar too large', forType: 'profile');
                return;
              }
              final name = intent.name == null ? null : cleanMemberName(intent.name!);
              // Chat names the sender by its token's name.
              if (name != null) viewer.name = name;
              hub.engine.applyProfile(token, name: name, avatar: avatar);
              hub.changed();
            case 'art':
              if (token == null) return;
              final art = ArtMessage.fromJson(decoded);
              if (hub.engine.applyArt(token, art.mediaId, poster: art.poster, banner: art.banner)) {
                hub.broadcastState();
              }
            case 'report':
              if (token == null) return;
              final report = ReportMessage.fromJson(decoded);
              final before = hub.engine.members[token]?.error ?? '';
              if (report.error != before && report.mediaId == hub.engine.mediaId) {
                _hubLog.warning(report.error.isEmpty
                    ? '${hub.who(token)}: player error cleared'
                    : '${hub.who(token)}: cannot play media ${report.mediaId}: ${report.error}');
              }
              hub.engine.applyReport(
                  token, report.position, report.buffered, report.eventId,
                  duration: report.duration, mediaId: report.mediaId, jf: report.jf, error: report.error);
              hub.changed();
            case 'ping':
              final ping = PingMessage.fromJson(decoded);
              ws.trySendText(jsonEncode(PongMessage(
                      clientMs: ping.clientMs,
                      serverMs: hub.engine.now.millisecondsSinceEpoch)
                  .toJson()));
            case 'chat':
              final chat = ChatMessage.fromJson(decoded);
              hub.broadcastChat(viewer?.name ?? '?', chat.text, fromId: hub.engine.members[token]?.id ?? '');
            case 'presence':
              if (token == null) return;
              final intent = PresenceIntent.fromJson(decoded);
              final refused = hub.engine.applyPresence(token, intent.target, intent.state, reason: intent.reason);
              if (refused != null) {
                wsErr(ws, refused, 'only a member itself comes back in', forType: 'presence');
              }
              hub.changed();
            case 'bye':
              if (token == null) return;
              _hubLog.info('bye from ${hub.who(token)}');
              hub.bye(token);
            case 'nudge':
              if (token == null) return;
              hub.nudge(token, NudgeIntent.fromJson(decoded).target);
            case 'queue':
              if (token == null) return;
              handleQueueIntent(hub, token, ws, decoded);
          }
        } on ProtocolException catch (e) {
          _hubLog.info('${token == null ? 'a socket' : hub.who(token)}: bad $type message: ${e.message}');
          wsErr(ws, ErrCode.bad, 'bad message: ${e.message}', forType: type is String ? type : null);
        } catch (e, st) {
          _hubLog.warning('${token == null ? 'a socket' : hub.who(token)}: $type message failed: $e', e, st);
          return;
        }
      }

      sub = ws.events.listen(
        (event) {
          if (event is! TextDataReceived) return;
          if (!firstText.isCompleted) {
            firstText.complete(event.text);
          } else if (welcomed) {
            handleIntent(event.text);
          }
        },
        onError: (_) {
          if (token != null) hub.socketClosed(token, ws);
        },
        onDone: () {
          if (!firstText.isCompleted) {
            firstText.completeError(StateError('closed before hello'));
          } else if (token != null) {
            hub.socketClosed(token, ws);
          }
        },
      );
      String raw;
      try {
        raw = await firstText.future.timeout(const Duration(seconds: 10));
      } catch (_) {
        await close();
        return;
      }
      Future<void> refuse(ErrorFrame err, int code, String log) async {
        _hubLog.warning('reject: $log');
        ws.trySendText(jsonEncode(err.toJson()));
        try {
          await sub.cancel();
        } catch (_) {}
        await closeWith(ws, code, err.code?.name ?? 'refused');
      }

      // The version first, read leniently: another version's hello may
      // not parse as ours.
      final Map<String, Object?> raw0;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) throw const ProtocolException('hello must be an object');
        raw0 = Map<String, Object?>.from(decoded);
      } catch (e) {
        await refuse(ErrorFrame(code: ErrCode.bad, message: 'bad hello: $e', forType: 'hello'), CloseCodes.refused,
            'bad hello: $e');
        return;
      }
      final range = HelloMessage.protoRangeOf(raw0);
      final proto = range == null ? null : pickProto(range.min, range.max);
      if (proto == null) {
        final got = range?.max ?? 0;
        await refuse(ErrorFrame.version(got: got, server: appVersion), CloseCodes.version,
            'proto mismatch: got ${range == null ? 'none' : '${range.min}..${range.max}'}, '
            'want ${RelayConstants.protoMin}..${RelayConstants.protoMax}');
        return;
      }
      HelloMessage hello;
      try {
        hello = HelloMessage.fromJson(raw0);
      } catch (e) {
        await refuse(ErrorFrame(code: ErrCode.bad, message: 'bad hello: $e', forType: 'hello'), CloseCodes.refused,
            'bad hello: $e');
        return;
      }
      final session = hub.session;
      if (session.secret.isNotEmpty && hello.secret != session.secret) {
        await refuse(const ErrorFrame(code: ErrCode.secret, message: 'wrong secret', forType: 'hello'),
            CloseCodes.secret, '${cleanMemberName(hello.user.name)}: wrong secret');
        return;
      }
      if (hello.user.avatar.length > RelayConstants.maxAvatarBytes) {
        await refuse(
            const ErrorFrame(code: ErrCode.rejected, message: 'rejected: avatar too large', forType: 'hello'),
            CloseCodes.refused,
            '${cleanMemberName(hello.user.name)}: avatar too large');
        return;
      }
      final known = hub.engine.byClient(hello.client);
      if (known != null && hello.seq < known.seq) {
        await refuse(
            const ErrorFrame(
                code: ErrCode.stale, message: 'an older connection of this app (a newer one holds it)', forType: 'hello'),
            CloseCodes.stale,
            '${known.name} (${known.id}): an older hello than the member\'s');
        return;
      }
      final String memberId;
      final bool resumed;
      final about = '${hello.app.isEmpty ? 'no version' : hello.app}${hello.platform.isEmpty ? '' : ' on ${hello.platform}'}';
      if (known != null) {
        // This app again (a reconnect, or opened anew): it takes its
        // member over, same token and id; an older socket still open is
        // told and closed.
        token = known.token;
        memberId = known.id;
        resumed = true;
        final old = hub.sockets[known.token];
        hub.sockets[known.token] = ws;
        if (old != null && !identical(old, ws)) {
          old.trySendText(jsonEncode(const ErrorFrame(
                  code: ErrCode.replaced, message: 'this member was opened from another connection of the same app')
              .toJson()));
          unawaited(closeWith(old, CloseCodes.replaced, 'replaced'));
        }
        final back = hub.engine.applyTakeover(known.token,
            seq: hello.seq, app: hello.app, platform: hello.platform, caps: hello.caps);
        final name = cleanMemberName(hello.user.name);
        session.tokens[known.token]?.name = name;
        hub.engine.applyProfile(known.token, name: name, avatar: hello.user.avatar);
        _hubLog.info('${back ? 'return' : 'takeover'} ${known.name} ($memberId), $about');
      } else {
        try {
          token = session.issueToken(hello.user.name, hello.user.avatar);
        } catch (e) {
          await refuse(ErrorFrame(code: ErrCode.rejected, message: 'rejected: $e', forType: 'hello'),
              CloseCodes.refused, '${cleanMemberName(hello.user.name)}: $e');
          return;
        }
        memberId = hub.engine.applyJoin(token, session.tokens[token]!.name, hello.user.avatar,
            client: hello.client, seq: hello.seq, app: hello.app, platform: hello.platform, caps: hello.caps);
        resumed = false;
        hub.sockets[token] = ws;
        _hubLog.info('join ${session.tokens[token]!.name} ($memberId), $about');
      }
      final activeToken = token;
      final isHost = hub.isHostKey(hello.hostKey);
      session.tokens[activeToken]!.isHost = isHost;
      hub.engine.members[activeToken]?.host = isHost;
      hub.refreshRelaySource();
      final media = session.media;
      final relay = hub.relayAvailable;
      final relayed = hub.relay;
      final feedAfter = hello.feedAfter;
      final welcome = WelcomeMessage(
        token: activeToken,
        memberId: memberId,
        proto: proto,
        resumed: resumed,
        instance: hub.instance,
        grace: hub.engine.liveness.grace.inSeconds,
        feed: feedAfter == null ? const [] : hub.engine.feed.after(feedAfter),
        // Jellyfin media resolves per member (own account first); only
        // relayed files and links start from the /r/ URL, and never for
        // the source itself (it plays its own copy).
        // A fetched link not read yet has no URL: the state's `live` opens it.
        mediaUrl: relayed != null &&
                media != null &&
                media.jellyfin == null &&
                relayed.sourceToken != activeToken &&
                relayed.mediaId == media.mediaId &&
                relayMediaUrlBuilder != null
            ? (relayed.known
                ? relayMediaUrlBuilder('default', activeToken, relayed.queueId ?? '${relayed.mediaId}', media.name,
                    relayed.tracks, dialledHost)
                : null)
            : media?.file != null
                ? urlBuilder('default', activeToken, media, dialledHost)
                : media?.url,
        relayUrl: relay && relayUrlBuilder != null
            ? relayUrlBuilder('default', activeToken, media!.jellyfin!.itemId, dialledHost)
            : null,
        state: hub.stateBroadcast().toJson(),
      );
      try {
        ws.sendText(jsonEncode(welcome.toJson()));
      } catch (_) {
        await close();
        return;
      }
      welcomed = true;
      hub.changed();
      try {
        await sub.asFuture();
      } catch (_) {}
    });
  });
}

ActiveRelay _memberRelay(ServerHub hub, String token, String name, List<RelayTrackSpec> tracks) {
  late final ActiveRelay r;
  r = ActiveRelay.fromMember(hub.engine.mediaId, name, token,
      tracks: tracks, sourceId: hub.engine.members[token]?.id ?? '', onLiveChanged: () => hub.relayLiveChanged(r));
  return r;
}
