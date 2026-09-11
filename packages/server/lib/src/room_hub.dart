import 'dart:async';
import 'dart:convert';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';
import 'package:web_socket/web_socket.dart';

import 'session.dart';

final _hubLog = createLogger('room_hub');

class RoomHub {
  final SessionMap sessions;
  final String expectedSecret;
  final RoomEngine engine;
  final Map<String, RelicWebSocket> sockets = {};

  RoomHub(this.sessions, this.expectedSecret, {RoomEngine? engine})
      : engine = engine ?? RoomEngine();

  Session get session => sessions.getOrCreate('default', expectedSecret);

  void broadcastRoom() {
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
    broadcastRoom();
    broadcastFeed();
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
    await session.kick(member.token, reason: reason);
  }
}

void wsErr(RelicWebSocket ws, String message) {
  ws.trySendText(jsonEncode({'t': 'err', 'message': message}));
}

void mountSyncRoute(
  RelicApp app,
  RoomHub hub,
  String Function(String sid, String token, SessionMedia? media) urlBuilder,
) {
  app.get('/sync', (final req) {
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
              hub.engine.applySeek(token, intent.position);
              hub.changed();
            case 'swap':
              if (token == null) return;
              final intent = SwapIntent.fromJson(decoded);
              hub.engine.applySwap(token, intent.media);
              final current = session.media;
              if (current?.file != null &&
                  current!.name == intent.media.name &&
                  current.size == intent.media.size) {
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
                  token, report.position, report.buffered, report.eventId);
              hub.broadcastRoom();
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
              final by = viewer?.name ?? '?';
              unawaited(hub.session.kick(member.token,
                  reason: kickReq.reason.isEmpty
                      ? 'kicked by $by'
                      : kickReq.reason));
          }
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
          if (token != null) hub.forgetSocket(token);
        },
        onDone: () {
          if (!firstText.isCompleted) {
            firstText.completeError(StateError('closed before hello'));
          } else if (token != null) {
            hub.forgetSocket(token);
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
      if (hello.secret != session.secret) {
        _hubLog.warning('reject ${hello.user.name}: wrong secret');
        wsErr(ws, 'wrong secret');
        await close();
        return;
      }
      try {
        token = session.issueToken(hello.user.name, hello.user.avatar);
      } catch (e) {
        _hubLog.warning('reject ${hello.user.name}: $e');
        wsErr(ws, 'rejected: $e');
        await close();
        return;
      }
      final memberId = hub.engine.applyJoin(token, hello.user.name, hello.user.avatar);
      final activeToken = token;
      hub.sockets[activeToken] = ws;
      session.tokens[activeToken]!.onKick = (reason) async {
        ws.trySendText(jsonEncode(KickedMessage(reason: reason).toJson()));
        await Future.delayed(const Duration(milliseconds: 200));
        await ws.tryClose();
        hub.forgetSocket(activeToken);
      };
      final media = session.media;
      final welcome = WelcomeMessage(
        token: activeToken,
        memberId: memberId,
        mediaUrl: media?.file != null ? urlBuilder('default', activeToken, media) : media?.url,
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
