import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

class _Peer {
  final WebSocket ws;
  final List<Map<String, Object?>> msgs = [];
  _Peer(this.ws) {
    ws.listen((m) => msgs.add(Map<String, Object?>.from(jsonDecode('$m') as Map)));
  }

  static Future<_Peer> join(int port, String name, {String client = '', int seq = 0}) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final p = _Peer(ws);
    p.send(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: 's',
            user: HelloUser(name: name),
            client: client,
            seq: seq)
        .toJson());
    await p.until((m) => m['t'] == 'welcome');
    return p;
  }

  void send(Map<String, Object?> json) => ws.add(jsonEncode(json));

  Future<Map<String, Object?>> until(bool Function(Map<String, Object?> m) test) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(end)) {
      for (final m in msgs) {
        if (test(m)) {
          msgs.remove(m);
          return m;
        }
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
    fail('nothing matched in $msgs');
  }

  /// The next state whose queue passes [test].
  Future<StateBroadcast> state(bool Function(StateBroadcast s) test) async {
    final m = await until((m) => m['t'] == 'state' && test(StateBroadcast.fromJson(m)));
    return StateBroadcast.fromJson(m);
  }
}

void main() {
  late SyncServer server;

  setUp(() async {
    server = SyncServer(const AppConfig(port: 0, secret: 's', name: 't'));
    await server.start();
  });

  tearDown(() => server.stop());

  test('queued items reach everyone; a server-fetched link stays on the server; a swap takes its item', () async {
    final a = await _Peer.join(server.boundPort, 'alice');
    final b = await _Peer.join(server.boundPort, 'bob');
    a.send(const QueueIntent.add(QueueItem(
            media: HelloMedia(name: 'https://example.com/v?token=secret', size: 0, duration: 0,
                url: 'https://example.com/v?token=secret'),
            how: QueueHow.server,
            title: 'A video',
            sub: 'Example'))
        .toJson());
    a.send(const QueueIntent.add(
            QueueItem(
                media: HelloMedia(name: 'x', size: 0, duration: 0, url: 'https://example.com/x.mp4'),
                how: QueueHow.direct,
                title: 'Direct'),
            next: true)
        .toJson());
    final s = await b.state((s) => s.queue.length == 2);
    expect([for (final q in s.queue) q.title], ['Direct', 'A video']);
    final fetched = s.queue[1];
    expect(fetched.byName, 'alice');
    expect(jsonEncode(s.toJson()), isNot(contains('secret')), reason: 'the fetched URL is never broadcast');
    expect(fetched.media.relay?.fetch, isTrue);

    // Bob puts the fetched item up without knowing its URL; the server fills it in.
    b.send(SwapIntent(
            media: const HelloMedia(name: 'A video', size: 0, duration: 0, relay: MediaRelay(fetch: true)),
            queueId: fetched.id)
        .toJson());
    final after = await a.state((s) => s.media != null);
    expect(after.media?['name'], 'A video');
    expect(after.queue.single.title, 'Direct');
    final mediaId = after.mediaId;

    // A second swap of the same item (a race) is ignored.
    a.send(SwapIntent(
            media: const HelloMedia(name: 'A video', size: 0, duration: 0, relay: MediaRelay(fetch: true)),
            queueId: fetched.id)
        .toJson());
    a.msgs.clear();
    final later = await a.state((s) => true);
    expect(later.mediaId, mediaId);
  });

  test('a bad add answers the sender; adder-only items need a key', () async {
    final a = await _Peer.join(server.boundPort, 'alice');
    a.send(const QueueIntent.add(QueueItem(
            media: HelloMedia(name: 'f.mkv', size: 10, duration: 0), how: QueueHow.file, title: 'f'))
        .toJson());
    final err = await a.until((m) => m['t'] == 'err');
    expect('${err['message']}', contains('key'));
    a.send(const QueueIntent.add(QueueItem(
            media: HelloMedia(name: 'f.mkv', size: 10, duration: 0, url: 'file:///home/me/f.mkv'),
            how: QueueHow.file,
            title: 'f',
            key: 'k1234567890'))
        .toJson());
    final s = await a.state((s) => s.queue.isNotEmpty);
    expect(s.queue.single.media.url, isNull, reason: 'an adder-only item carries no path or link');
    expect(s.queue.single.key, 'k1234567890');
  });

  test("an adder's items keep its lasting id through a drop and wait while it is gone", () async {
    const install = 'queueTestInstallId0001';
    final a = await _Peer.join(server.boundPort, 'alice', client: install, seq: 1);
    final b = await _Peer.join(server.boundPort, 'bob');
    a.send(const QueueIntent.add(QueueItem(
            media: HelloMedia(name: 'f.mkv', size: 10, duration: 0), how: QueueHow.file, title: 'f', key: 'k1234567890'))
        .toJson());
    final added = (await b.state((s) => s.queue.isNotEmpty)).queue.single;
    final aliceId = added.by;
    await a.ws.close();
    // Gone: still a member, so whoever would put the item up waits for it
    // instead of skipping it.
    final whileGone = await b.state((s) => s.members.any((m) => m.id == aliceId && m.presence == Presence.gone));
    expect(whileGone.queue.single.by, aliceId);
    final again = await _Peer.join(server.boundPort, 'alice', client: install, seq: 2);
    final back = await again.state((s) => s.members.any((m) => m.id == aliceId && m.presence != Presence.gone));
    expect(back.queue.single.by, aliceId, reason: 'the same member: its items are its own again');
    expect(back.members.where((m) => m.name == 'alice'), hasLength(1));
  });
}
