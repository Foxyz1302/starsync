// Identity, grace and the feed across reconnects, on a fake clock: the
// server's limits ([Liveness]) are stepped through, not waited for.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

class _Peer {
  final WebSocket ws;
  final frames = <Map<String, Object?>>[];
  late final WelcomeMessage welcome;
  _Peer(this.ws) {
    ws.listen((m) => frames.add(Map<String, Object?>.from(jsonDecode('$m') as Map)), onError: (_) {});
  }

  static Future<_Peer> join(int port, String name, {String client = '', int seq = 0, int? feedAfter}) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final p = _Peer(ws);
    ws.add(jsonEncode(HelloMessage(
            secret: 's', user: HelloUser(name: name), client: client, seq: seq, app: '1.3.0', feedAfter: feedAfter)
        .toJson()));
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!p.frames.any((f) => f['t'] == 'welcome')) {
      if (DateTime.now().isAfter(end)) fail('no welcome: ${p.frames}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    p.welcome = WelcomeMessage.fromJson(p.frames.firstWhere((f) => f['t'] == 'welcome'));
    return p;
  }

  List<Map<String, Object?>> get feed => [for (final f in frames) if (f['t'] == 'feed') f];
}

Future<void> _until(bool Function() ok, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  const install = 'presenceTestInstall001';
  late DateTime t;
  late SyncServer server;
  final peers = <_Peer>[];

  Future<_Peer> join(String name, {String client = '', int seq = 0, int? feedAfter}) async {
    final p = await _Peer.join(server.boundPort, name, client: client, seq: seq, feedAfter: feedAfter);
    peers.add(p);
    return p;
  }

  /// Moves the server's clock on and runs one heartbeat.
  void step(Duration d) {
    t = t.add(d);
    server.hub.heartbeat();
  }

  setUp(() async {
    t = DateTime.utc(2026, 1, 1);
    server = SyncServer(const AppConfig(port: 0, secret: 's', name: 't'), clock: () => t);
    await server.start();
  });

  tearDown(() async {
    for (final p in peers) {
      await p.ws.close();
    }
    peers.clear();
    await server.stop();
  });

  test('a gone member leaves when its grace runs out; it comes back as a new member', () async {
    final alice = await join('alice', client: install, seq: 1);
    final bob = await join('bob');
    await alice.ws.close();
    await _until(() => server.hub.engine.byClient(install)?.presence == Presence.gone, 'gone');
    expect(alice.welcome.grace, RelayConstants.graceSecs);
    // Bob keeps talking; alice says nothing.
    for (var i = 0; i < 59; i++) {
      server.hub.engine.touch(bob.welcome.token);
      step(const Duration(seconds: 10));
    }
    expect(server.hub.engine.byClient(install), isNotNull, reason: '9 min 50 s: still kept');
    expect(server.session.tokens.containsKey(alice.welcome.token), isTrue);
    server.hub.engine.touch(bob.welcome.token);
    step(const Duration(seconds: 10));
    expect(server.hub.engine.byClient(install), isNull);
    expect(server.session.tokens.containsKey(alice.welcome.token), isFalse, reason: 'its URLs stop working');
    await _until(() => bob.feed.any((f) => f['action'] == 'leave'), 'leave line');
    final leave = bob.feed.firstWhere((f) => f['action'] == 'leave');
    expect([leave['actorId'], leave['reason']], [alice.welcome.memberId, 'grace']);
    final again = await join('alice', client: install, seq: 2);
    expect(again.welcome.resumed, isFalse);
    expect(again.welcome.memberId, isNot(alice.welcome.memberId));
  });

  test('a quick return says nothing; a slow one says gone, then return; never join', () async {
    final alice = await join('alice', client: install, seq: 1);
    final bob = await join('bob');
    await alice.ws.close();
    await _until(() => server.hub.engine.byClient(install)?.presence == Presence.gone, 'gone');
    await _until(
        () => bob.frames.any((f) =>
            f['t'] == 'state' && (f['members'] as List).any((m) => (m as Map)['presence'] == 'gone')),
        'presence in state at once');
    step(const Duration(seconds: 5));
    final quick = await join('alice', client: install, seq: 2);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(quick.welcome.resumed, isTrue);
    expect(bob.feed.map((f) => f['action']), isNot(anyOf(contains('gone'), contains('return'), contains('leave'))));
    expect(bob.feed.where((f) => f['action'] == 'join'), hasLength(1), reason: "bob's own join only");
    await quick.ws.close();
    await _until(() => server.hub.engine.byClient(install)?.presence == Presence.gone, 'gone again');
    step(const Duration(seconds: 10));
    await _until(() => bob.feed.any((f) => f['action'] == 'gone'), 'gone line after 10 s');
    await join('alice', client: install, seq: 3);
    await _until(() => bob.feed.any((f) => f['action'] == 'return'), 'return line');
    final ret = bob.feed.firstWhere((f) => f['action'] == 'return');
    expect([ret['actor'], ret['actorId']], ['alice', alice.welcome.memberId]);
  });

  test('feed lines carry ids and seq; a reconnect replays what came after feedAfter', () async {
    final alice = await join('alice', client: install, seq: 1);
    final bob = await join('bob');
    bob.ws.add(jsonEncode(const ReadyIntent(ready: true).toJson()));
    await _until(() => alice.feed.any((f) => f['action'] == 'ready'), 'ready line');
    final seqs = [for (final f in alice.feed) f['seq'] as int];
    expect(seqs, orderedEquals([...seqs]..sort()));
    final ready = alice.feed.firstWhere((f) => f['action'] == 'ready');
    expect(ready['actorId'], bob.welcome.memberId);
    final last = seqs.last;
    await alice.ws.close();
    bob.ws.add(jsonEncode(const ChatMessage(text: 'while you were out').toJson()));
    bob.ws.add(jsonEncode(const ReadyIntent(ready: false).toJson()));
    await _until(() => server.hub.engine.feed.lastSeq >= last + 2, 'lines while away');
    final again = await join('alice', client: install, seq: 2, feedAfter: last);
    final replayed = again.welcome.feed;
    expect(replayed.map((f) => f.action), containsAllInOrder(['chat', 'unready']));
    expect(replayed.every((f) => f.replayed && f.seq > last), isTrue);
    expect(again.feed, isEmpty, reason: 'replayed only inside welcome');
  });

  test('a server restart: resumed false, another instance', () async {
    final alice = await join('alice', client: install, seq: 1);
    final before = alice.welcome.instance;
    expect(before, isNotEmpty);
    await server.stop();
    server = SyncServer(const AppConfig(port: 0, secret: 's', name: 't'), clock: () => t);
    await server.start();
    final again = await join('alice', client: install, seq: 2);
    expect(again.welcome.resumed, isFalse);
    expect(again.welcome.instance, isNot(before));
  });

  test('members carry presence and app; the client id is never broadcast nor logged', () async {
    final records = <String>[];
    final sub = Logger.root.onRecord.listen((r) => records.add('${r.message} ${r.error ?? ''}'));
    addTearDown(sub.cancel);
    final alice = await join('alice', client: install, seq: 3);
    final old = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/sync');
    old.add(jsonEncode(const HelloMessage(secret: 's', user: HelloUser(name: 'alice'), client: install, seq: 1).toJson()));
    await old.drain<void>().timeout(const Duration(seconds: 5));
    expect(old.closeCode, CloseCodes.stale);
    await alice.ws.close();
    await _until(() => server.hub.engine.byClient(install)?.presence == Presence.gone, 'gone');
    final again = await join('alice', client: install, seq: 4);
    await _until(() => again.frames.any((f) => f['t'] == 'state'), 'state');
    final state = again.frames.lastWhere((f) => f['t'] == 'state');
    final me = (state['members'] as List).cast<Map>().single;
    expect([me['presence'], me['app']], ['in', '1.3.0']);
    final everything = [...records, ...again.frames.map(jsonEncode), ...alice.frames.map(jsonEncode)].join('\n');
    expect(records, isNotEmpty);
    expect(everything, isNot(contains(install)));
    expect(redactLog('bad hello: {"client":"$install"}'), isNot(contains(install)));
  });

  test('server close code for a refused secret; the err names its code', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/sync');
    final frames = <String>[];
    ws.listen((m) => frames.add('$m'), onError: (_) {});
    ws.add(jsonEncode(const HelloMessage(secret: 'nope', user: HelloUser(name: 'x')).toJson()));
    await _until(() => ws.closeCode != null, 'closed');
    expect(ws.closeCode, CloseCodes.secret);
    expect((jsonDecode(frames.single) as Map)['code'], 'secret');
  });
}
