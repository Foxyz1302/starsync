// restructure: rewrite in step 1 (Connection + Identity + Presence): "anyone
// sits anyone out" (Away); the rest stays.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

class _Peer {
  final WebSocket ws;
  final List<Map<String, Object?>> msgs = [];
  bool closed = false;
  _Peer(this.ws) {
    ws.listen((m) => msgs.add(Map<String, Object?>.from(jsonDecode('$m') as Map)),
        onDone: () => closed = true);
  }

  static Future<_Peer> join(String host, int port, String name,
      {String secret = '', String hostKey = ''}) async {
    final ws = await WebSocket.connect('ws://$host:$port/sync');
    final p = _Peer(ws);
    ws.add(jsonEncode(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: secret,
            user: HelloUser(name: name),
            media: const HelloMedia(name: '', size: 0, duration: 0),
            hostKey: hostKey)
        .toJson()));
    await p.next('welcome');
    return p;
  }

  void send(String raw) => ws.add(raw);

  Future<Map<String, Object?>> next(String type,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      for (final m in msgs) {
        if (m['t'] == type) {
          msgs.remove(m);
          return m;
        }
      }
      await Future.delayed(const Duration(milliseconds: 30));
    }
    fail('no $type in $msgs');
  }
}

Future<String?> _lan() async {
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      if (!a.isLoopback) return a.address;
    }
  }
  return null;
}

void main() {
  late SyncServer server;
  late File file;

  setUp(() async {
    file = File('${Directory.systemTemp.path}/hard_${DateTime.now().microsecondsSinceEpoch}.bin')
      ..writeAsBytesSync(List.filled(64, 1));
    server = SyncServer(AppConfig(port: 0, secret: '', name: 't', mediaPath: file.path));
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await file.delete();
  });

  test('Infinity seek/report is rejected and sync keeps broadcasting', () async {
    final a = await _Peer.join('127.0.0.1', server.boundPort, 'a');
    a.send('{"t":"seek","position":1e400}');
    a.send('{"t":"report","position":1e400,"buffered":1e400,"eventId":0}');
    final err = await a.next('err');
    expect('${err['message']}', contains('finite'));
    expect(server.hub.engine.position, 0);
    // still alive: a valid seek round-trips through a broadcast
    a.send('{"t":"seek","position":5}');
    for (var i = 0; i < 50 && server.hub.engine.position != 5; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(server.hub.engine.position, 5);
    await a.ws.close();
  });

  test('empty swap rejected with err, no state change', () async {
    final a = await _Peer.join('127.0.0.1', server.boundPort, 'a');
    final before = server.hub.engine.mediaId;
    a.send(jsonEncode({
      't': 'swap',
      'media': {'name': 'x', 'size': 0, 'duration': 0, 'url': ''}
    }));
    await a.next('err');
    expect(server.hub.engine.mediaId, before);
    await a.ws.close();
  });

  test('swap name that is a URL is reduced to last segment', () async {
    expect(sanitizeMediaName('http://j:8096/Videos/1/stream.mkv?api_key=SECRET#x'),
        'stream.mkv');
    expect(sanitizeMediaName('movie.mkv'), 'movie.mkv');
    final a = await _Peer.join('127.0.0.1', server.boundPort, 'a');
    a.send(jsonEncode({
      't': 'swap',
      'media': {
        'name': 'http://j/Videos/1/stream.mkv?api_key=SECRET',
        'size': 0,
        'duration': 1,
        'url': 'http://j/Videos/1/stream.mkv?api_key=SECRET'
      }
    }));
    for (var i = 0; i < 50 && server.hub.engine.mediaId == 1; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(server.hub.engine.media!.name, 'stream.mkv');
    expect(server.session.media!.name, 'stream.mkv');
    await a.ws.close();
  });

  test('anyone sits anyone out (host too); nudges reach only the target, capped', () async {
    await server.stop();
    server = SyncServer(AppConfig(port: 0, secret: '', name: 't', hostKey: 'hk'));
    await server.start();
    final host =
        await _Peer.join('127.0.0.1', server.boundPort, 'host', hostKey: 'hk');
    final friend = await _Peer.join('127.0.0.1', server.boundPort, 'friend');
    final third = await _Peer.join('127.0.0.1', server.boundPort, 'third');
    String idOf(String name) =>
        server.hub.engine.members.values.firstWhere((m) => m.name == name).id;
    EngineMember of(String name) =>
        server.hub.engine.members.values.firstWhere((m) => m.name == name);
    friend.send(jsonEncode(OutIntent(target: idOf('host'), out: true).toJson()));
    var feed = await friend.next('feed');
    while (feed['action'] != 'out') {
      feed = await friend.next('feed');
    }
    expect([feed['actor'], feed['target']], ['friend', 'host']);
    expect(of('host').out, isTrue);
    expect(of('host').inSet, isFalse);
    // Only oneself comes back.
    friend.send(jsonEncode(OutIntent(target: idOf('host'), out: false).toJson()));
    host.send(jsonEncode(OutIntent(target: idOf('host'), out: false).toJson()));
    await Future.delayed(const Duration(milliseconds: 200));
    expect(of('host').out, isFalse);

    // 5 at once: 3 pass (per second), only to the target.
    for (var i = 0; i < 5; i++) {
      friend.send(jsonEncode(NudgeIntent(target: idOf('host')).toJson()));
    }
    await Future.delayed(const Duration(milliseconds: 300));
    final got = host.msgs.where((m) => m['t'] == 'nudge').toList();
    expect(got, hasLength(3));
    expect(got.first, {'t': 'nudge', 'from': idOf('friend'), 'name': 'friend'});
    expect(third.msgs.where((m) => m['t'] == 'nudge'), isEmpty);
    expect(friend.msgs.where((m) => m['t'] == 'nudge'), isEmpty);
    await host.ws.close();
    await friend.ws.close();
    await third.ws.close();
  });

  test('nudge cap: 20 per minute', () {
    final v = ViewerToken(token: 't', name: 'n');
    final t0 = DateTime.utc(2026);
    var passed = 0;
    for (var i = 0; i < 30; i++) {
      if (v.takeNudge(t0.add(Duration(milliseconds: 500 * i)))) passed++;
    }
    expect(passed, 20);
    expect(v.takeNudge(t0.add(const Duration(seconds: 61))), isTrue);
  });

  test('state marks the host member for everyone', () async {
    await server.stop();
    server = SyncServer(AppConfig(port: 0, secret: '', name: 't', hostKey: 'hk'));
    await server.start();
    final host = await _Peer.join('127.0.0.1', server.boundPort, 'host', hostKey: 'hk');
    final friend = await _Peer.join('127.0.0.1', server.boundPort, 'friend');
    final state = StateBroadcast.fromJson(await friend.next('state'));
    final byName = {for (final m in state.members) m.name: m};
    expect(byName['host']!.host, isTrue);
    expect(byName['friend']!.host, isFalse);
    final raw = server.hub.stateBroadcast().toJson()['members'] as List;
    expect([for (final m in raw) (m as Map)['host']], containsAll([true, null]));
    await host.ws.close();
    await friend.ws.close();
  });

  test('no hostKey configured: nobody is the host', () async {
    final a = await _Peer.join('127.0.0.1', server.boundPort, 'a', hostKey: '');
    final b = await _Peer.join('127.0.0.1', server.boundPort, 'b', hostKey: 'x');
    expect(server.session.tokens.values.where((t) => t.isHost), isEmpty);
    expect(server.hub.stateBroadcast().members.where((m) => m.host), isEmpty);
    await a.ws.close();
    await b.ws.close();
  });

  test('empty secret accepts any hello secret', () async {
    final a = await _Peer.join('127.0.0.1', server.boundPort, 'a', secret: 'whatever');
    expect(server.hub.engine.members, hasLength(1));
    await a.ws.close();
  });

  test('/health exposes no media name', () async {
    final c = HttpClient();
    final r = await (await c.get('127.0.0.1', server.boundPort, '/health')).close();
    final body = jsonDecode(await r.transform(utf8.decoder).join()) as Map;
    c.close();
    expect(body['ok'], isTrue);
    expect(body.containsKey('media'), isFalse);
  });

  test('file media URL uses the host the client dialled', () async {
    final lan = await _lan();
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/sync');
    final p = _Peer(ws);
    ws.add(jsonEncode(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: '',
            user: const HelloUser(name: 'a'),
            media: const HelloMedia(name: '', size: 0, duration: 0))
        .toJson()));
    final w = await p.next('welcome');
    expect('${w['mediaUrl']}', startsWith('http://127.0.0.1:${server.boundPort}/m/'));
    await ws.close();
    if (lan != null) {
      final q = await _Peer.join(lan, server.boundPort, 'b');
      // welcome consumed in join; re-check via session state instead
      await q.ws.close();
      final ws2 = await WebSocket.connect('ws://$lan:${server.boundPort}/sync');
      final p2 = _Peer(ws2);
      ws2.add(jsonEncode(HelloMessage(
              proto: RelayConstants.protoVersion,
              secret: '',
              user: const HelloUser(name: 'c'),
              media: const HelloMedia(name: '', size: 0, duration: 0))
          .toJson()));
      final w2 = await p2.next('welcome');
      expect('${w2['mediaUrl']}', startsWith('http://$lan:${server.boundPort}/m/'));
      await ws2.close();
    }
  });
}
