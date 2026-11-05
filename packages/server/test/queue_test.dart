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
    final whileGone = await b.state((s) => s.members.any((m) => m.id == aliceId && m.gone));
    expect(whileGone.queue.single.by, aliceId);
    final again = await _Peer.join(server.boundPort, 'alice', client: install, seq: 2);
    final back = await again.state((s) => s.members.any((m) => m.id == aliceId && !m.gone));
    expect(back.queue.single.by, aliceId, reason: 'the same member: its items are its own again');
    expect(back.members.where((m) => m.name == 'alice'), hasLength(1));
  });

  test('after a restart, the first offer of what played wins; later ones are ignored', () async {
    final a = await _Peer.join(server.boundPort, 'alice');
    final b = await _Peer.join(server.boundPort, 'bob');
    const media = HelloMedia(name: 'v', size: 0, duration: 600, url: 'https://example.com/v.mp4');
    a.send(const SwapIntent(media: media, restore: SwapRestore(position: 120.5, transport: 'playing')).toJson());
    final back = await b.state((s) => s.media != null);
    expect((back.position, back.transport), (120.5, 'held'));
    final line = await b.until((m) => m['t'] == 'feed' && m['action'] == 'swap');
    expect(line['reason'], 'restore');
    b.send(const SwapIntent(
            media: HelloMedia(name: 'w', size: 0, duration: 0, url: 'https://example.com/w.mp4'),
            restore: SwapRestore(position: 3))
        .toJson());
    a.msgs.clear();
    final later = await a.state((s) => true);
    expect((later.mediaId, later.media?['name'], later.position), (back.mediaId, 'v', 120.5));
  });

  group('the countdown (state.advance), on a fake clock', () {
    late DateTime t;
    late SyncServer clocked;

    setUp(() async {
      t = DateTime.utc(2026, 1, 1);
      clocked = SyncServer(const AppConfig(port: 0, secret: 's', name: 't'), clock: () => t);
      await clocked.start();
    });

    tearDown(() => clocked.stop());

    /// Moves the clock on; everyone keeps talking; one heartbeat.
    void step(int secs) {
      t = t.add(Duration(seconds: secs));
      final engine = clocked.hub.engine;
      for (final token in engine.members.keys) {
        engine.touch(token);
      }
      clocked.hub.heartbeat();
    }

    /// Alice and bob in; a 20 s video up, both ready with a full buffer,
    /// then played to its end; [queue] what bob adds first.
    Future<(_Peer, _Peer)> playToEnd(List<QueueItem> queue) async {
      final a = await _Peer.join(clocked.boundPort, 'alice');
      final b = await _Peer.join(clocked.boundPort, 'bob');
      a.send(const SwapIntent(media: HelloMedia(name: 'Ep01', size: 0, duration: 20, url: 'https://example.com/1.mp4'))
          .toJson());
      final up = await b.state((s) => s.media != null);
      a.send(const TransportIntent(play: true).toJson());
      for (final p in [a, b]) {
        p.send(ReportMessage(position: 0, buffered: 100, eventId: up.eventId + 1, mediaId: up.mediaId).toJson());
      }
      await b.state((s) => s.transport == 'playing');
      for (final q in queue) {
        b.send(QueueIntent.add(q).toJson());
      }
      await b.state((s) => s.queue.length == queue.length);
      step(21);
      return (a, b);
    }

    const next = QueueItem(
        media: HelloMedia(name: 'n', size: 0, duration: 0, url: 'https://example.com/n.mp4'),
        how: QueueHow.direct,
        title: 'Next');

    test('everyone sees the same countdown; at its end the first item is asked for', () async {
      final (a, b) = await playToEnd([next]);
      final s = await a.state((s) => s.advance != null);
      expect(s.transport, 'finished');
      expect([s.advance!.id, s.advance!.secs], [s.queue.first.id, RelayConstants.advanceSecs]);
      expect((await b.state((s) => s.advance != null)).advance!.at, s.advance!.at);
      step(5);
      expect((await a.state((s) => true)).queuePlay, isNull);
      step(5);
      final due = await a.state((s) => s.queuePlay != null);
      expect(due.queuePlay, s.queue.first.id);
      expect(due.advance, isNull);
    });

    test('cancel is shared: the countdown stops for everyone', () async {
      final (a, b) = await playToEnd([next]);
      await a.state((s) => s.advance != null);
      b.send(const QueueIntent.cancel().toJson());
      await a.state((s) => s.advance == null);
      final line = await a.until((m) => m['t'] == 'feed' && m['action'] == 'advance-cancel');
      expect(line['actor'], 'bob');
      step(15);
      expect(clocked.hub.engine.queue.play, isNull);
    });

    test('an item whose adder left is skipped by the server, with why', () async {
      final (a, b) = await playToEnd([
        const QueueItem(
            media: HelloMedia(name: 'f.mkv', size: 10, duration: 0), how: QueueHow.file, title: 'Bobs', key: 'k1234567890'),
      ]);
      await a.state((s) => s.advance != null);
      b.send(const ByeMessage().toJson());
      await a.until((m) => m['t'] == 'feed' && m['action'] == 'leave');
      step(10);
      final skip = await a.until((m) => m['t'] == 'feed' && m['action'] == 'queue-skip');
      expect([skip['actorId'], skip['target'], skip['reason']], ['server', 'Bobs', 'bob left']);
      expect((await a.state((s) => true)).queue, isEmpty);
    });
  });
}
