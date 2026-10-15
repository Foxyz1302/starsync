// restructure: rewrite in step 1 (Connection + Identity + Presence): both
// tests pin today's rules (a silent member is stale, then removed; a reset
// socket loses its member, so the redial is a new one, P1); with grace they
// expect `gone` and the same member back.
//
// A client reaching the server through FlakyProxy (DEVELOPMENT.md "Tests").
import 'dart:async';
import 'dart:convert';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_core/testing.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A bare `/sync` client: hello, then a report every 100 ms (any frame
/// keeps a member fresh).
class _Client {
  final WebSocketChannel ch;
  final frames = <Map<String, Object?>>[];
  bool ended = false;
  Timer? _reports;
  late final StreamSubscription<dynamic> _sub;

  _Client(int port, {String resume = ''})
      : ch = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port/sync')) {
    ch.ready.then((_) {}, onError: (_) {});
    _sub = ch.stream.listen((m) => frames.add(Map<String, Object?>.from(jsonDecode('$m') as Map)),
        onDone: () => ended = true, onError: (_) => ended = true);
    ch.sink.add(jsonEncode(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: 'shh',
            user: const HelloUser(name: 'alice'),
            media: const HelloMedia(name: 'f.bin', size: 1, duration: 10.0),
            resume: resume)
        .toJson()));
  }

  Map<String, Object?>? get welcome => frames.where((f) => f['t'] == 'welcome').firstOrNull;
  String get token => welcome!['token'] as String;
  String get memberId => welcome!['memberId'] as String;

  void startReports() => _reports = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!ended) {
          ch.sink.add(jsonEncode(const ReportMessage(position: 0, buffered: 0, eventId: 0).toJson()));
        }
      });

  Future<void> close() async {
    _reports?.cancel();
    try {
      await _sub.cancel();
    } catch (_) {}
    try {
      await ch.sink.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
  }
}

Future<void> until(bool Function() ok, String what, {Duration limit = const Duration(seconds: 6)}) async {
  final end = DateTime.now().add(limit);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('$what: not within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late SyncServer server;
  late FlakyProxy proxy;
  final clients = <_Client>[];

  setUp(() async {
    // Short limits so the demo runs in a couple of seconds.
    server = SyncServer(AppConfig(port: 0, secret: 'shh', name: 'test'),
        liveness: const Liveness(staleAfter: Duration(milliseconds: 600), dropAfter: Duration(milliseconds: 1500)));
    await server.start();
    proxy = await FlakyProxy.start(server.boundPort);
  });

  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    clients.clear();
    await proxy.close();
    await server.stop();
  });

  _Client dial({String resume = ''}) {
    final c = _Client(proxy.port, resume: resume);
    clients.add(c);
    return c;
  }

  test('a blackholed client goes stale, then is removed; it never hears of it', () async {
    final c = dial();
    await until(() => c.welcome != null, 'welcome');
    c.startReports();
    final engine = server.hub.engine;
    EngineMember? member() => engine.members[c.token];
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(engine.isStale(member()!), isFalse, reason: 'reports through the proxy keep it fresh');

    proxy.last!.blackhole();
    final seen = c.frames.length;
    await until(() => member() != null && engine.isStale(member()!), 'stale');
    await until(() => member() == null, 'removed');
    expect(server.hub.sockets.containsKey(c.token), isFalse);
    // Half-open: the server's close never reached the client.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.ended, isFalse);
    expect(c.frames.length, seen);
    expect(proxy.last!.isClosed, isFalse);
    expect(proxy.last!.dropped, greaterThan(0));
  });

  test('a reset client sees the drop at once and redials; today it comes back as a new member', () async {
    final c = dial();
    await until(() => c.welcome != null, 'welcome');
    final first = c.memberId;
    proxy.last!.reset();
    await until(() => c.ended, 'client sees the reset');
    await until(() => !server.hub.engine.members.containsKey(c.token), 'server forgets the socket');

    final again = dial(resume: c.token);
    await until(() => again.welcome != null, 'welcome after redial');
    expect(proxy.links, hasLength(2));
    expect(again.memberId, isNot(first), reason: 'P1: no grace yet');
    expect(server.hub.engine.members, hasLength(1));
  });
}
