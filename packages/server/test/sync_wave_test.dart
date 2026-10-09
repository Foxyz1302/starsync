import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

/// TCP relay that can go silent without closing: the server sees a socket
/// that is open but never talks again (an unclean drop it cannot detect).
class _FreezableProxy {
  final ServerSocket _listener;
  final List<Socket> _open = [];
  bool frozen = false;
  _FreezableProxy._(this._listener);

  int get port => _listener.port;

  static Future<_FreezableProxy> start(int target) async {
    final l = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = _FreezableProxy._(l);
    l.listen((client) async {
      final upstream = await Socket.connect(InternetAddress.loopbackIPv4, target);
      p._open..add(client)..add(upstream);
      client.listen((d) {
        if (!p.frozen) upstream.add(d);
      }, onError: (_) {}, onDone: () {});
      upstream.listen((d) {
        if (!p.frozen) client.add(d);
      }, onError: (_) {}, onDone: () {});
    });
    return p;
  }

  Future<void> close() async {
    for (final s in _open) {
      s.destroy();
    }
    await _listener.close();
  }
}

class _Client {
  final WebSocket ws;
  final frames = <Map<String, Object?>>[];
  final _welcome = Completer<Map<String, Object?>>();
  _Client(this.ws) {
    ws.listen((m) {
      final d = Map<String, Object?>.from(jsonDecode('$m') as Map);
      frames.add(d);
      if (d['t'] == 'welcome' && !_welcome.isCompleted) _welcome.complete(d);
    }, onError: (_) {}, onDone: () {});
  }

  StateBroadcast? get lastState {
    for (final f in frames.reversed) {
      if (f['t'] == 'state') return StateBroadcast.fromJson(f);
    }
    return null;
  }

  void send(Map<String, Object?> j) => ws.add(jsonEncode(j));

  static Future<(_Client, WelcomeMessage)> join(int port, String name,
      {String resume = ''}) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final c = _Client(ws);
    c.send(HelloMessage(
      proto: RelayConstants.protoVersion,
      secret: 'w',
      user: HelloUser(name: name),
      media: const HelloMedia(name: '', size: 0, duration: 0),
      resume: resume,
    ).toJson());
    final w = await c._welcome.future.timeout(const Duration(seconds: 5));
    return (c, WelcomeMessage.fromJson(w));
  }
}

Future<void> _until(FutureOr<bool> Function() cond, String what,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  fail('timed out waiting for $what');
}

void main() {
  late SyncServer server;
  setUp(() async {
    server = SyncServer(const AppConfig(port: 0, secret: 'w', name: 'wave'));
    await server.start();
  });
  tearDown(() => server.stop());

  test('reconnect after an unclean drop takes over the old member, no ghost',
      () async {
    final proxy = await _FreezableProxy.start(server.boundPort);
    final other = (await _Client.join(server.boundPort, 'other')).$1;
    final (first, welcome) = await _Client.join(proxy.port, 'alice');
    first.send(const ReadyIntent(ready: true).toJson());
    await _until(() => server.hub.engine.members[welcome.token]?.ready == true,
        'ready');
    proxy.frozen = true; // unclean drop: the server's socket stays open

    final (second, again) =
        await _Client.join(server.boundPort, 'alice', resume: welcome.token);
    expect(again.memberId, welcome.memberId);
    expect(again.token, welcome.token,
        reason: 'same token keeps the media URL valid');
    expect(server.hub.engine.members.length, 2,
        reason: 'alice once (taken over) plus other, no ghost');
    expect(server.hub.engine.members[welcome.token]!.ready, isTrue,
        reason: 'ready survives the takeover');
    // The frozen old socket closing later must not remove the new one.
    await proxy.close();
    await Future.delayed(const Duration(seconds: 2));
    expect(server.hub.engine.members.containsKey(welcome.token), isTrue);
    expect(server.hub.sockets.containsKey(welcome.token), isTrue);
    second.send(const ChatMessage(text: 'still here').toJson());
    await _until(
        () => other.frames.any((f) => f['t'] == 'chat' && f['text'] == 'still here'),
        'chat from the resumed member');
    await other.ws.close();
    await second.ws.close();
  });

  test('unknown resume token joins as a new member', () async {
    final (a, wa) = await _Client.join(server.boundPort, 'a', resume: 'nope');
    expect(wa.token, isNot('nope'));
    await a.ws.close();
  });

  test('ping gets a pong with the client stamp and the server clock', () async {
    final (c, _) = await _Client.join(server.boundPort, 'p');
    final before = DateTime.now().millisecondsSinceEpoch;
    c.send(const PingMessage(clientMs: 1234).toJson());
    await _until(() => c.frames.any((f) => f['t'] == 'pong'), 'pong');
    final pong = PongMessage.fromJson(c.frames.firstWhere((f) => f['t'] == 'pong'));
    expect(pong.clientMs, 1234);
    expect(pong.serverMs, greaterThanOrEqualTo(before));
    await c.ws.close();
  });

  test('seek echo carries seekBy/seekSeq; report teaches the duration',
      () async {
    final (c, w) = await _Client.join(server.boundPort, 's');
    c.send(const SeekIntent(position: 12, seq: 3).toJson());
    await _until(() => c.lastState?.seekSeq == 3, 'seek echo');
    expect(c.lastState!.seekBy, w.memberId);
    server.hub.engine.media = const HelloMedia(name: 'f', size: 1, duration: 0);
    c.send(ReportMessage(
            position: 12,
            buffered: 5,
            eventId: c.lastState!.eventId,
            duration: 1440,
            mediaId: c.lastState!.mediaId)
        .toJson());
    await _until(() => c.lastState?.media?['duration'] == 1440, 'duration');
    await c.ws.close();
  });
}
