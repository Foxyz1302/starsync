import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

class _ProbeClient {
  final WebSocket ws;
  final Completer<void> welcomed = Completer<void>();
  final Completer<String> closed = Completer<String>();
  _ProbeClient(this.ws) {
    ws.listen(
      (m) {
        if (!welcomed.isCompleted) {
          final decoded = jsonDecode('$m') as Map;
          expect(decoded['t'], 'welcome');
          welcomed.complete();
        }
      },
      onDone: () {
        if (!closed.isCompleted) {
          closed.complete('done code=${ws.closeCode} reason=${ws.closeReason}');
        }
      },
      onError: (Object e) {
        if (!closed.isCompleted) closed.complete('error $e');
      },
    );
  }

  static Future<_ProbeClient> hello(int port, String name) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final c = _ProbeClient(ws);
    ws.add(jsonEncode({
      't': 'hello',
      'proto': RelayConstants.protoVersion,
      'secret': 'cycle',
      'user': {'name': name},
      'media': {'name': '', 'size': 0, 'duration': 0.0},
    }));
    await c.welcomed.future.timeout(const Duration(seconds: 5));
    return c;
  }
}

Future<void> _pollBool(
  FutureOr<bool> Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out: $what');
}

void main() {
  group('presence lifecycle live', () {
    late SyncServer server;

    setUp(() async {
      server = SyncServer(
          const AppConfig(port: 0, secret: 'cycle', name: 'cycle'));
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('a clean close is not a leave: the member is gone at once, kept', () async {
      final client = await _ProbeClient.hello(server.boundPort, 'alice');
      await _pollBool(() => server.hub.engine.members.length == 1, 'join visible');
      await client.ws.close();
      await _pollBool(() => server.hub.engine.members.values.single.presence == Presence.gone, 'gone');
      expect(server.session.tokens, hasLength(1), reason: 'its token works through the grace');
      expect(server.hub.sockets, isEmpty);
    });

    test('bye leaves at once: member, token and socket go', () async {
      final client = await _ProbeClient.hello(server.boundPort, 'alice');
      await _pollBool(() => server.hub.engine.members.length == 1, 'join visible');
      client.ws.add(jsonEncode(const ByeMessage().toJson()));
      final outcome = await client.closed.future.timeout(const Duration(seconds: 5));
      expect(outcome, contains('code=${CloseCodes.left}'));
      expect(server.hub.engine.members, isEmpty);
      expect(server.session.tokens, isEmpty);
      expect(server.hub.sockets, isEmpty);
    });

    test('server stop closes client sockets', () async {
      final client = await _ProbeClient.hello(server.boundPort, 'bob');
      await _pollBool(
          () => server.hub.engine.members.length == 1, 'join visible');
      await server.stop();
      final outcome = await client.closed.future
          .timeout(const Duration(seconds: 5), onTimeout: () => 'TIMEOUT');
      expect(outcome, isNot('TIMEOUT'), reason: 'client never saw close');
    });
  });
}
