// The Connection against a scripted fake server: what a hello says, a
// reconnect's hello, refusals in plain words, the backoff.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/session/connection.dart';
import 'package:starsync/src/session/identity.dart';
import 'package:starsync/src/sync/sync_client.dart';

/// A `/sync` endpoint that hands each socket and its hello to [onHello].
class _Fake {
  final HttpServer _server;
  final hellos = <Map<String, Object?>>[];
  void Function(WebSocket ws, Map<String, Object?> hello) onHello;
  _Fake(this._server, this.onHello) {
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      var first = true;
      ws.listen((m) {
        if (!first) return;
        first = false;
        final hello = Map<String, Object?>.from(jsonDecode('$m') as Map);
        hellos.add(hello);
        onHello(ws, hello);
      }, onError: (_) {});
    });
  }

  static Future<_Fake> start(void Function(WebSocket ws, Map<String, Object?> hello) onHello) async =>
      _Fake(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), onHello);

  int get port => _server.port;
  Future<void> close() => _server.close(force: true);
}

void _welcome(WebSocket ws, {String instance = 'boot-1', bool resumed = false}) => ws.add(jsonEncode(WelcomeMessage(
        token: 'tok', memberId: 'm1', instance: instance, resumed: resumed,
        state: StateBroadcast(
                eventId: 1, transport: 'held', position: 0, serverTime: DateTime.now().toUtc(), mediaId: 0, members: const [])
            .toJson())
    .toJson()));

Future<void> _poll(FutureOr<bool> Function() cond, String what, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  fail('timed out waiting for $what');
}

ConnectParams _params(int port) => ConnectParams(host: '127.0.0.1', port: port, secret: 's', name: 'me');

void main() {
  test('the hello: version range, client id, a rising seq, app, platform, caps; feedAfter only on a reconnect',
      () async {
    final fake = await _Fake.start((ws, hello) {
      _welcome(ws);
      // One feed line, then the link dies.
      ws.add(jsonEncode(FeedMessage(actor: 'Ann', action: 'join', at: DateTime.now().toUtc(), seq: 5).toJson()));
    });
    final id = ClientIdentity.ephemeral();
    final c = Connection(identity: id, caps: () => const ClientCaps(source: true, resolve: true),
        reconnectDelay: const Duration(milliseconds: 50));
    try {
      c.begin(_params(fake.port));
      await c.dial(c.invalidate());
      await _poll(() => c.client.lastFeedSeq == 5, 'the feed line');
      final h = fake.hellos.single;
      expect(h['proto'], RelayConstants.protoMax);
      expect(h['protoMin'], RelayConstants.protoMin);
      expect(h['client'], id.clientId);
      expect((h['client'] as String).length, 22);
      expect(validClientId(h['client'] as String), isTrue);
      expect(h['seq'], 1);
      expect(h['app'], appVersion);
      expect(h['platform'], Platform.operatingSystem);
      expect(h['caps'], {'source': true, 'resolve': true});
      expect(h.containsKey('feedAfter'), isFalse, reason: 'a first join replays nothing');
      expect(h['media'], <String, Object?>{}, reason: 'a proto 15 server answers its own proto mismatch');

      await c.client.drop();
      // A dropped socket: no status from it; drive the drop the way the
      // silence check does.
      c.scheduleReconnect();
      await _poll(() => fake.hellos.length == 2 && c.state.peek() is ConnOnline, 'the reconnect');
      expect(fake.hellos[1]['seq'], 2);
      expect(fake.hellos[1]['client'], id.clientId);
      expect(fake.hellos[1]['feedAfter'], 5);
    } finally {
      await c.dispose();
      await fake.close();
    }
  });

  test('a proto 15 host refuses in its own words: "the host runs an older Starsync"', () async {
    final fake = await _Fake.start((ws, hello) {
      ws.add(jsonEncode({'t': 'err', 'message': 'proto mismatch: got 16, want 15'}));
      ws.close(1008, 'refused');
    });
    final c = Connection();
    try {
      c.begin(_params(fake.port));
      await expectLater(c.dial(c.invalidate()), throwsA(isA<HelloRefused>()));
      final s = c.state.peek();
      expect(s, isA<ConnRefused>());
      expect((s as ConnRefused).code, 'version');
      expect(s.message, 'the host runs an older Starsync — they need to update');
    } finally {
      await c.dispose();
      await fake.close();
    }
  });

  test('refusals in plain words', () {
    HelloRefused v({int? min, int? max}) =>
        HelloRefused(error: ErrorFrame(code: ErrCode.version, message: 'proto mismatch', min: min, max: max));
    expect(connectErrorText(v(min: 15, max: 15)), contains('older Starsync'));
    expect(connectErrorText(v(min: RelayConstants.protoMax + 1, max: RelayConstants.protoMax + 2)),
        contains('newer Starsync'));
    expect(connectErrorText(const HelloRefused(error: ErrorFrame(code: ErrCode.secret, message: 'wrong secret'))),
        'wrong server password (401)');
    expect(connectErrorText(const HelloRefused(closeCode: CloseCodes.replaced)), replacedText);
    expect(connectErrorText(const HelloRefused(error: ErrorFrame(code: ErrCode.stale, message: 'older'))), replacedText);
  });

  test('backoff: about 1 s first, doubling, capped near 15 s, with jitter', () {
    final c = Connection();
    for (var i = 0; i < 20; i++) {
      final first = c.delayFor(1).inMilliseconds;
      expect(first, inInclusiveRange(800, 1200));
      expect(c.delayFor(2).inMilliseconds, inInclusiveRange(1600, 2400));
      expect(c.delayFor(30).inMilliseconds, inInclusiveRange(12000, 18000));
    }
    unawaited(c.dispose());
  });

  test('replaced is terminal: no more attempts', () async {
    late WebSocket held;
    final fake = await _Fake.start((ws, hello) {
      held = ws;
      _welcome(ws);
    });
    final c = Connection(reconnectDelay: const Duration(milliseconds: 50));
    try {
      c.begin(_params(fake.port));
      await c.dial(c.invalidate());
      held.add(jsonEncode(const ErrorFrame(code: ErrCode.replaced, message: 'another connection').toJson()));
      await held.close(CloseCodes.replaced, 'replaced');
      await _poll(() => c.state.peek() is ConnReplaced, 'replaced');
      await Future.delayed(const Duration(milliseconds: 500));
      expect(c.state.peek(), isA<ConnReplaced>());
      expect(fake.hellos, hasLength(1), reason: 'it never dials again by itself');
    } finally {
      await c.dispose();
      await fake.close();
    }
  });
}
