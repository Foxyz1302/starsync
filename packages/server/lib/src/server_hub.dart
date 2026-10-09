import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';
import 'package:web_socket/web_socket.dart';

import 'relay_routes.dart';
import 'session.dart';

final _hubLog = createLogger('server_hub');

class ServerHub {
  final SessionMap sessions;
  final String expectedSecret;
  /// See [AppConfig.hostKey]; empty means nobody is the host.
  final String hostKey;
  final SyncEngine engine;
  final Map<String, RelicWebSocket> sockets = {};
  /// The server's Jellyfin login for the `/j/...` relay; null = no relay.
  JellyfinCredential? jellyfin;
  /// Reads web pages for "the server fetches it"; null = files only.
  final YtDlp? ytDlp;

  ServerHub(this.sessions, this.expectedSecret,
      {SyncEngine? engine, this.hostKey = '', this.jellyfin, this.ytDlp})
      : engine = engine ?? SyncEngine();

  /// The current media is a Jellyfin ref on the server [jellyfin] logs in to.
  bool get relayAvailable {
    final ref = session.media?.jellyfin;
    final cred = jellyfin;
    return ref != null && cred != null && cred.serverId.isNotEmpty && cred.serverId == ref.serverId;
  }

  StateBroadcast stateBroadcast() => engine.broadcast(relay: relayAvailable);

  /// The relay of the current media (`/r/...`), if it is relayed.
  ActiveRelay? relay;

  /// Replaces the relay (null: the new media is not relayed). The old
  /// buffer is dropped with it.
  void setRelay(ActiveRelay? next) {
    relay?.dispose();
    relay = next;
  }

  /// `media.relay` for a relayed swap by [token]: who serves the bytes
  /// and, from a member, its tracks (the server finds a fetched link's).
  MediaRelay relayFor(String token, MediaRelay requested) => requested.fetch
      ? const MediaRelay(fetch: true)
      : MediaRelay(source: engine.members[token]?.id ?? '', tracks: requested.tracks);

  /// The relay's channel came up or went down, or a fetched link was read:
  /// `media.relay.live` and `tracks` follow.
  void relayLiveChanged(ActiveRelay r) {
    final m = engine.media;
    if (!identical(relay, r) || m?.relay == null) return;
    final was = m!.relay!;
    if (was.live == r.live && was.tracks.join(',') == r.tracks.join(',')) return;
    engine.media = m.copyWith(relay: was.copyWith(live: r.live, tracks: r.tracks));
    changed();
  }

  bool isHostKey(String key) => hostKey.isNotEmpty && key == hostKey;

  /// The member a reconnecting client may take over with its old token:
  /// still known.
  EngineMember? resumable(String token) {
    if (token.isEmpty || !session.tokens.containsKey(token)) return null;
    return engine.members[token];
  }

  Session get session => sessions.getOrCreate('default', expectedSecret);

  void broadcastState() {
    final raw = jsonEncode(stateBroadcast().toJson());
    for (final ws in sockets.values.toList()) {
      ws.trySendText(raw);
    }
  }

  void broadcastFeed() {
    for (final feed in engine.feed.drain()) {
      final raw = jsonEncode(feed.toJson());
      for (final ws in sockets.values.toList()) {
        ws.trySendText(raw);
      }
    }
  }

  void dropSilentSockets() {
    for (final token in engine.sweepDropped()) {
      final ws = sockets[token];
      if (ws != null) unawaited(ws.tryClose());
      forgetSocket(token);
    }
  }

  void sweepClosedSockets() {
    for (final entry in sockets.entries.toList()) {
      var closed = false;
      try {
        closed = entry.value.isClosed;
      } catch (_) {
        closed = true;
      }
      if (closed) forgetSocket(entry.key);
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

  void broadcastChat(String from, String text) {
    final clean = text.length > RelayConstants.maxChatLength
        ? text.substring(0, RelayConstants.maxChatLength)
        : text;
    final raw = jsonEncode(
        ChatMessage(text: clean).toJson()..addAll({'from': from}));
    for (final ws in sockets.values.toList()) {
      ws.trySendText(raw);
    }
    engine.feed.add(
        FeedMessage(actor: from, action: 'chat', at: engine.now));
    broadcastFeed();
  }

  void changed() {
    broadcastState();
    broadcastFeed();
  }

  /// Like [forgetSocket], but only while [ws] is still the member's socket:
  /// after a resume the old socket's close must not remove the member.
  void forgetSocketOf(String token, RelicWebSocket ws) {
    if (!identical(sockets[token], ws)) return;
    forgetSocket(token);
  }

  void forgetSocket(String token) {
    engine.applyLeave(token);
    session.tokens.remove(token);
    sockets.remove(token);
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

void wsErr(RelicWebSocket ws, String message) {
  ws.trySendText(jsonEncode({'t': 'err', 'message': message}));
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
  String Function(String sid, String token, int mediaId, String name, List<RelayTrackSpec> tracks, String host)?
      relayMediaUrlBuilder,
}) {
  app.get('/sync', (final req) {
    // Host the client dialled (Host header), so file URLs work for remote joiners.
    final dialledHost = req.url.hasPort
        ? '${req.url.host.contains(':') ? '[${req.url.host}]' : req.url.host}:${req.url.port}'
        : (req.url.host.contains(':') ? '[${req.url.host}]' : req.url.host);
    return WebSocketUpgrade((final ws) async {
      ws.pingInterval = Duration(seconds: RelayConstants.pingIntervalSecs);
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
        final session = hub.session;
        final viewer = token == null ? null : session.tokens[token];
        viewer?.touch();
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
              final parsed = SwapIntent.fromJson(decoded).media;
              if (parsed.jellyfin != null) {
                // By reference only: no URL (it could carry a token) is
                // stored or broadcast for Jellyfin media.
                final ref = sanitizeJellyfinRef(parsed.jellyfin!);
                // Relayed for viewers without access: from the swapper's
                // machine (its own sign-in never leaves it).
                final relayReq = parsed.relay == null || parsed.relay!.fetch ? null : parsed.relay;
                final media = ref == null
                    ? null
                    : HelloMedia(
                        name: sanitizeMediaName(parsed.name.isEmpty ? ref.title : parsed.name),
                        size: parsed.size,
                        duration: parsed.duration,
                        jellyfin: ref,
                        relay: relayReq == null ? null : hub.relayFor(token, const MediaRelay()));
                if (media == null || !hub.engine.applySwap(token, media)) {
                  wsErr(ws, 'bad swap media');
                  return;
                }
                session.media = SessionMedia(
                    name: media.name,
                    size: media.size,
                    duration: media.duration,
                    jellyfin: ref,
                    mediaId: hub.engine.mediaId);
                hub.setRelay(relayReq == null ? null : _memberRelay(hub, token, media.name, const []));
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
                  wsErr(ws, 'relay fetch needs an http(s) url');
                  return;
                }
                // The server would fetch any address it can reach (its own
                // network, a VPN) for whoever asks: only for members who
                // know the password.
                if (relayReq.fetch && session.secret.isEmpty) {
                  wsErr(ws, 'server fetch needs a server password');
                  return;
                }
                final media = HelloMedia(
                    name: name,
                    size: parsed.size,
                    duration: parsed.duration,
                    relay: hub.relayFor(token, relayReq));
                if (!hub.engine.applySwap(token, media)) {
                  wsErr(ws, 'bad swap media');
                  return;
                }
                session.media = SessionMedia(
                    name: name, size: parsed.size, duration: parsed.duration, mediaId: hub.engine.mediaId);
                late final ActiveRelay active;
                active = relayReq.fetch
                    ? ActiveRelay.fetch(hub.engine.mediaId, name, link!,
                        ytDlp: hub.ytDlp,
                        onLiveChanged: () => hub.relayLiveChanged(active),
                        onFail: (why) => wsErr(ws, "The server can't fetch this link: $why"))
                    : _memberRelay(hub, token, name, media.relay!.tracks);
                hub.setRelay(active);
                hub.changed();
                return;
              }
              final intent = SwapIntent(
                  media: HelloMedia(
                      name: sanitizeMediaName(parsed.name),
                      size: parsed.size,
                      duration: parsed.duration,
                      url: parsed.url));
              final current = session.media;
              final matchesFile = current?.file != null &&
                  current!.name == intent.media.name &&
                  current.size == intent.media.size;
              if (!matchesFile && (intent.media.url ?? '').isEmpty) {
                wsErr(ws, 'swap needs a url or the hosted file');
                return;
              }
              if (!hub.engine.applySwap(token, intent.media)) {
                wsErr(ws, 'bad swap media');
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
                wsErr(ws, 'rejected: avatar too large');
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
              hub.engine.applyReport(
                  token, report.position, report.buffered, report.eventId,
                  duration: report.duration, mediaId: report.mediaId, jf: report.jf);
              hub.changed();
            case 'ping':
              final ping = PingMessage.fromJson(decoded);
              ws.trySendText(jsonEncode(PongMessage(
                      clientMs: ping.clientMs,
                      serverMs: hub.engine.now.millisecondsSinceEpoch)
                  .toJson()));
            case 'chat':
              final chat = ChatMessage.fromJson(decoded);
              hub.broadcastChat(viewer?.name ?? '?', chat.text);
            case 'out':
              if (token == null) return;
              final intent = OutIntent.fromJson(decoded);
              hub.engine.applyOut(token, intent.target, intent.out);
              hub.changed();
            case 'nudge':
              if (token == null) return;
              hub.nudge(token, NudgeIntent.fromJson(decoded).target);
          }
        } on ProtocolException catch (e) {
          wsErr(ws, 'bad message: ${e.message}');
        } catch (_) {
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
          if (token != null) hub.forgetSocketOf(token, ws);
        },
        onDone: () {
          if (!firstText.isCompleted) {
            firstText.completeError(StateError('closed before hello'));
          } else if (token != null) {
            hub.forgetSocketOf(token, ws);
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
      HelloMessage hello;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) throw const ProtocolException('hello must be an object');
        hello = HelloMessage.fromJson(Map<String, Object?>.from(decoded));
      } catch (e) {
        _hubLog.warning('reject: bad hello: $e');
        wsErr(ws, 'bad hello: $e');
        await close();
        return;
      }
      if (hello.proto != RelayConstants.protoVersion) {
        _hubLog.warning(
            'reject ${hello.user.name}: proto mismatch: got ${hello.proto}, want ${RelayConstants.protoVersion}');
        wsErr(ws, 'proto mismatch: got ${hello.proto}, want ${RelayConstants.protoVersion}');
        await close();
        return;
      }
      final session = hub.session;
      if (session.secret.isNotEmpty && hello.secret != session.secret) {
        _hubLog.warning('reject ${hello.user.name}: wrong secret');
        wsErr(ws, 'wrong secret');
        await close();
        return;
      }
      final resumed = hub.resumable(hello.resume);
      String memberId;
      if (resumed != null) {
        // Unclean drop the server has not noticed yet: take the member over
        // (same token, id, ready flag) and drop the dead socket quietly.
        token = hello.resume;
        memberId = resumed.id;
        final old = hub.sockets.remove(token);
        if (old != null) unawaited(old.tryClose());
        hub.engine.applyResume(token);
        _hubLog.info('resume ${hello.user.name} ($memberId)');
      } else {
        try {
          token = session.issueToken(hello.user.name, hello.user.avatar);
        } catch (e) {
          _hubLog.warning('reject ${hello.user.name}: $e');
          wsErr(ws, 'rejected: $e');
          await close();
          return;
        }
        memberId = hub.engine.applyJoin(token, session.tokens[token]!.name, hello.user.avatar);
      }
      final isHost = hub.isHostKey(hello.hostKey);
      session.tokens[token]!.isHost = isHost;
      hub.engine.members[token]?.host = isHost;
      final activeToken = token;
      hub.sockets[activeToken] = ws;
      final media = session.media;
      final relay = hub.relayAvailable;
      final relayed = hub.relay;
      final welcome = WelcomeMessage(
        token: activeToken,
        memberId: memberId,
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
                ? relayMediaUrlBuilder(
                    'default', activeToken, relayed.mediaId, relayed.name, relayed.tracks, dialledHost)
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
      _hubLog.info('join ${hello.user.name} ($memberId)');
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
      tracks: tracks, onLiveChanged: () => hub.relayLiveChanged(r));
  return r;
}
