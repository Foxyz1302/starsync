import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

/// A bare client: the wire only.
class _Raw {
  final WebSocket ws;
  final msgs = <Map<String, Object?>>[];
  final done = Completer<int?>();
  Map<String, Object?> welcome = const {};
  _Raw(this.ws) {
    ws.listen((m) => msgs.add(Map<String, Object?>.from(jsonDecode('$m') as Map)),
        onDone: () => done.complete(ws.closeCode), onError: (_) {});
  }

  static Future<_Raw> join(String host, int port, String name,
      {String secret = '', String hostKey = '', String client = ''}) async {
    final r = _Raw(await WebSocket.connect('ws://$host:$port/sync'));
    r.ws.add(jsonEncode(HelloMessage(
            secret: secret, user: HelloUser(name: name), hostKey: hostKey, client: client, seq: 1)
        .toJson()));
    r.welcome = await r.next('welcome');
    return r;
  }

  Future<Map<String, Object?>> next(String type, {bool Function(Map<String, Object?>)? where}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      for (final m in msgs) {
        if (m['t'] == type && (where == null || where(m))) {
          msgs.remove(m);
          return m;
        }
      }
      if (done.isCompleted) throw StateError('closed (${ws.closeCode}) before $type');
      await Future.delayed(const Duration(milliseconds: 50));
    }
    fail('timed out waiting for $type');
  }
}

Future<void> _poll(bool Function() cond, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  fail('timed out: $what');
}

/// This machine's first non-loopback IPv4 address, if it has one.
Future<InternetAddress?> _lanAddress() async {
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      if (!a.isLoopback) return a;
    }
  }
  return null;
}

void main() {
  test('share and unshare: one hub, the host and Up next stay, guests are told', () async {
    final server = SyncServer(const AppConfig(port: 0, secret: '', name: 'own', hostKey: 'HK'), loopbackOnly: true);
    await server.start();
    _Raw? host, guest;
    try {
      host = await _Raw.join('127.0.0.1', server.boundPort, 'me', hostKey: 'HK', client: 'hostclient00000000000a');
      await host.next('state');
      final hostId = server.hub.engine.members.values.single.id;
      host.ws.add(jsonEncode({
        't': 'queue',
        'op': 'add',
        'item': {
          'media': {'name': 'a', 'size': 0, 'duration': 0, 'url': 'http://example.com/a.mp4'},
          'how': 'direct',
          'title': 'A',
        },
      }));
      await _poll(() => server.hub.engine.queue.items.length == 1, 'queued');
      final lan = await _lanAddress();
      if (lan != null) {
        await expectLater(Socket.connect(lan, server.boundPort, timeout: const Duration(seconds: 3)),
            throwsA(isA<SocketException>()),
            reason: 'not shared: loopback only');
      }

      final port = await server.share(port: 0, secret: 'pw');
      expect(server.sharedPort, port);
      // A guest without the password is refused; with it, joins.
      await expectLater(_Raw.join('127.0.0.1', port, 'nopw'), throwsA(anything));
      guest = await _Raw.join(lan?.address ?? '127.0.0.1', port, 'guest', secret: 'pw', client: 'guestclient0000000000a');
      await _poll(() => server.hub.engine.members.length == 2, 'guest in');
      expect(server.hub.engine.members.values.map((m) => m.id), contains(hostId));
      // The host's own reconnect needs no password (its key).
      expect(host.done.isCompleted, isFalse, reason: 'sharing does not touch the host');

      await server.unshare();
      expect(server.sharedPort, isNull);
      expect(await guest.done.future.timeout(const Duration(seconds: 5)), CloseCodes.closed);
      await _poll(() => server.hub.engine.members.length == 1, 'guest left');
      expect(server.hub.engine.members.values.single.id, hostId, reason: 'the same member, never reconnected');
      expect(server.hub.engine.queue.items, hasLength(1), reason: 'Up next stays');
      expect(host.done.isCompleted, isFalse);
      expect(server.session.secret, '');
      final leave = await host.next('feed', where: (m) => m['action'] == 'leave');
      expect(leave['reason'], 'closed');
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 3)),
          throwsA(isA<SocketException>()),
          reason: 'the listener is gone');
      // Shared again: same hub, the queue still there.
      final again = await server.share(port: port, secret: '');
      expect(again, port);
      final g2 = await _Raw.join('127.0.0.1', port, 'guest2', client: 'guestclient0000000000b');
      final st = await g2.next('state');
      expect((st['queue'] as List), hasLength(1));
      await g2.ws.close();
    } finally {
      await host?.ws.close();
      await guest?.ws.close();
      await server.stop();
    }
  });

  test('welcome.animeFlow: the configured address, replaced by share', () async {
    final server = SyncServer(
        const AppConfig(port: 0, secret: '', name: 'own', hostKey: 'HK', animeFlow: 'https://anime.example.org/api'),
        loopbackOnly: true);
    await server.start();
    try {
      final host = await _Raw.join('127.0.0.1', server.boundPort, 'me', hostKey: 'HK');
      expect(host.welcome['animeFlow'], 'https://anime.example.org/api');
      await host.ws.close();
      await server.share(port: 0, secret: '', animeFlow: 'https://flow.example.net/v1/');
      final again = await _Raw.join('127.0.0.1', server.boundPort, 'me2');
      expect(again.welcome['animeFlow'], 'https://flow.example.net/v1');
      await again.ws.close();
      await server.share(port: 0, secret: '', animeFlow: '');
      final none = await _Raw.join('127.0.0.1', server.boundPort, 'me3');
      expect(none.welcome.containsKey('animeFlow'), isFalse);
      await none.ws.close();
    } finally {
      await server.stop();
    }
  });

  test('the host key stands in for the password', () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 'own', hostKey: 'HK'));
    await server.start();
    try {
      final host = await _Raw.join('127.0.0.1', server.boundPort, 'me', hostKey: 'HK');
      await host.ws.close();
      await expectLater(_Raw.join('127.0.0.1', server.boundPort, 'x', hostKey: 'nope'), throwsA(anything));
    } finally {
      await server.stop();
    }
  });
}
