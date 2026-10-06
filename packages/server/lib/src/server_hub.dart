import 'dart:async';
import 'dart:convert';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';
import 'package:web_socket/web_socket.dart';

import 'session.dart';

final _hubLog = createLogger('server_hub');

class ServerHub {
  final SessionMap sessions;
  final String expectedSecret;
  /// See [AppConfig.hostKey]; empty means nobody is the host.
  final String hostKey;
  final SyncEngine engine;
  final Map<String, RelicWebSocket> sockets = {};

  ServerHub(this.sessions, this.expectedSecret,
      {SyncEngine? engine, this.hostKey = ''})
      : engine = engine ?? SyncEngine();

  bool isHostKey(String key) => hostKey.isNotEmpty && key == hostKey;

  /// The member a reconnecting client may take over with its old token:
  /// still known and not kicked.
  EngineMember? resumable(String token) {
    if (token.isEmpty) return null;
    final viewer = session.tokens[token];
    if (viewer == null || viewer.kicked) return null;
    return engine.members[token];
  }

  Session get session => sessions.getOrCreate('default', expectedSecret);

  void broadcastState() {
    final raw = jsonEncode(engine.broadcast().toJson());
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
    final viewer = session.tokens[token];
    if (viewer != null && !viewer.kicked) session.tokens.remove(token);
    sockets.remove(token);
    changed();
  }

  Future<void> kickById(String targetId, String reason) async {
    final member = engine.byId(targetId);
    if (member == null) throw const AuthException('unknown kick target');
    if (session.tokens[member.token]?.isHost ?? false) {
      throw const AuthException("can't kick the host");
    }
    await session.kick(member.token, reason: reason);
  }
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

void mountSyncRoute(
  RelicApp app,
  ServerHub hub,
  String Function(String sid, String token, SessionMedia? media, String host)
      urlBuilder,
) {
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
            case 'report':
              if (token == null) return;
              final report = ReportMessage.fromJson(decoded);
              hub.engine.applyReport(
                  token, report.position, report.buffered, report.eventId,
                  duration: report.duration, mediaId: report.mediaId);
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
            case 'kick':
              final kickReq = KickRequest.fromJson(decoded);
              final member = hub.engine.byId(kickReq.target);
              if (member == null) {
                wsErr(ws, 'unknown kick target');
                return;
              }
              if (session.tokens[member.token]?.isHost ?? false) {
                wsErr(ws, "can't kick the host");
                return;
              }
              final by = viewer?.name ?? '?';
              unawaited(hub.session.kick(member.token,
                  reason: kickReq.reason.isEmpty
                      ? 'kicked by $by'
                      : kickReq.reason));
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
        memberId = hub.engine.applyJoin(token, hello.user.name, hello.user.avatar);
      }
      session.tokens[token]!.isHost = hub.isHostKey(hello.hostKey);
      final activeToken = token;
      hub.sockets[activeToken] = ws;
      session.tokens[activeToken]!.onKick = (reason) async {
        ws.trySendText(jsonEncode(KickedMessage(reason: reason).toJson()));
        await Future.delayed(const Duration(milliseconds: 200));
        await ws.tryClose();
        hub.forgetSocketOf(activeToken, ws);
      };
      final media = session.media;
      final welcome = WelcomeMessage(
        token: activeToken,
        memberId: memberId,
        mediaUrl: media?.file != null ? urlBuilder('default', activeToken, media, dialledHost) : media?.url,
        state: hub.engine.broadcast().toJson(),
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
