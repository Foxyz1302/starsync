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
  final closed = Completer<int?>();
  _Client(this.ws) {
    ws.listen((m) {
      final d = Map<String, Object?>.from(jsonDecode('$m') as Map);
      frames.add(d);
      if (d['t'] == 'welcome' && !_welcome.isCompleted) _welcome.complete(d);
    }, onError: (_) {}, onDone: () {
      if (!closed.isCompleted) closed.complete(ws.closeCode);
    });
  }

  StateBroadcast? get lastState {
    for (final f in frames.reversed) {
      if (f['t'] == 'state') return StateBroadcast.fromJson(f);
    }
    return null;
  }

  void send(Map<String, Object?> j) => ws.add(jsonEncode(j));

  static Future<(_Client, WelcomeMessage)> join(int port, String name,
      {String client = '', int seq = 0}) async {
    final c = await dial(port, name, client: client, seq: seq);
    final w = await c._welcome.future.timeout(const Duration(seconds: 5));
    return (c, WelcomeMessage.fromJson(w));
  }

  /// Sends the hello and returns at once (a refused one gets no welcome).
  static Future<_Client> dial(int port, String name, {String client = '', int seq = 0}) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final c = _Client(ws);
    c.send(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: 'w',
            user: HelloUser(name: name),
            client: client,
            seq: seq)
        .toJson());
    return c;
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

  const alice = 'aliceInstallIdAAAAAAAA';

  test('an unclean drop: the same app takes its member over (id, token, ready), no ghost', () async {
    final proxy = await _FreezableProxy.start(server.boundPort);
    final other = (await _Client.join(server.boundPort, 'other')).$1;
    final (first, welcome) = await _Client.join(proxy.port, 'alice', client: alice, seq: 1);
    expect(welcome.resumed, isFalse);
    expect(welcome.instance, server.hub.instance);
    expect(welcome.proto, RelayConstants.protoMax);
    expect(welcome.grace, RelayConstants.graceSecs);
    first.send(const ReadyIntent(ready: true).toJson());
    await _until(() => server.hub.engine.members[welcome.token]?.ready == true, 'ready');
    proxy.frozen = true; // unclean drop: the server's socket stays open

    final (second, again) = await _Client.join(server.boundPort, 'alice', client: alice, seq: 2);
    expect(again.resumed, isTrue);
    expect(again.memberId, welcome.memberId);
    expect(again.token, welcome.token, reason: 'same token keeps the media URL valid');
    expect(server.hub.engine.members.length, 2, reason: 'alice once (taken over) plus other, no ghost');
    expect(server.hub.engine.members[welcome.token]!.ready, isTrue, reason: 'ready survives the takeover');
    // The frozen old socket closing later must not touch the member.
    await proxy.close();
    await Future.delayed(const Duration(seconds: 2));
    expect(server.hub.engine.members[welcome.token]!.presence, isNot(Presence.gone));
    expect(server.hub.sockets.containsKey(welcome.token), isTrue);
    second.send(const ChatMessage(text: 'still here').toJson());
    await _until(() => other.frames.any((f) => f['t'] == 'chat' && f['text'] == 'still here'),
        'chat from the resumed member');
    await other.ws.close();
    await second.ws.close();
  });

  test('a takeover tells the older socket: err replaced, then its close code', () async {
    final (first, welcome) = await _Client.join(server.boundPort, 'alice', client: alice, seq: 1);
    final (second, again) = await _Client.join(server.boundPort, 'alice', client: alice, seq: 1);
    expect([again.resumed, again.memberId, again.token], [true, welcome.memberId, welcome.token],
        reason: 'the same seq takes over too');
    expect(await first.closed.future.timeout(const Duration(seconds: 5)), CloseCodes.replaced);
    final err = first.frames.lastWhere((f) => f['t'] == 'err');
    expect(err['code'], 'replaced');
    // Frames from the old socket (had it stayed open) no longer count.
    expect(server.hub.sockets[welcome.token], isNotNull);
    await second.ws.close();
  });

  test("an older hello than the member's gets err stale and is closed", () async {
    final (current, welcome) = await _Client.join(server.boundPort, 'alice', client: alice, seq: 5);
    final older = await _Client.dial(server.boundPort, 'alice', client: alice, seq: 4);
    expect(await older.closed.future.timeout(const Duration(seconds: 5)), CloseCodes.stale);
    expect(older.frames.single['code'], 'stale');
    expect(server.hub.sockets.containsKey(welcome.token), isTrue, reason: 'the current one stays');
    expect(server.hub.engine.members, hasLength(1));
    await current.ws.close();
  });

  test('without a client id, or with another, it is a new member', () async {
    final (a, wa) = await _Client.join(server.boundPort, 'a');
    final (b, wb) = await _Client.join(server.boundPort, 'a');
    final (c, wc) = await _Client.join(server.boundPort, 'a', client: 'someOtherInstallId0001');
    expect({wa.memberId, wb.memberId, wc.memberId}, hasLength(3));
    expect([wa.resumed, wb.resumed, wc.resumed], [false, false, false]);
    await a.ws.close();
    await b.ws.close();
    await c.ws.close();
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
