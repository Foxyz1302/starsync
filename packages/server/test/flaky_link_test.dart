// A client reaching the server through FlakyProxy (DEVELOPMENT.md "Tests"):
// a dead link makes the member `gone` (kept with everything it had), and
// the same app dialling again gets the same member back (P1).
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

  _Client(int port, {int seq = 1})
      : ch = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port/sync')) {
    ch.ready.then((_) {}, onError: (_) {});
    _sub = ch.stream.listen((m) => frames.add(Map<String, Object?>.from(jsonDecode('$m') as Map)),
        onDone: () => ended = true, onError: (_) => ended = true);
    ch.sink.add(jsonEncode(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: 'shh',
            user: const HelloUser(name: 'alice'),
            client: clientId,
            seq: seq)
        .toJson()));
  }

  static const clientId = 'flakyLinkTestClient01';

  void send(Map<String, Object?> j) => ch.sink.add(jsonEncode(j));

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
    // Short limits so the demo runs in a few seconds; silence well above
    // a busy CI runner's stalls (600 ms marked a reporting client gone).
    server = SyncServer(AppConfig(port: 0, secret: 'shh', name: 'test'),
        liveness: const Liveness(silence: Duration(milliseconds: 1500)));
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

  _Client dial({int seq = 1}) {
    final c = _Client(proxy.port, seq: seq);
    clients.add(c);
    return c;
  }

  test('a blackholed client goes gone with its BRB, queue item and relay; it comes back as itself', () async {
    final c = dial();
    await until(() => c.welcome != null, 'welcome');
    c.startReports();
    final engine = server.hub.engine;
    EngineMember? member() => engine.members[c.token];
    c.send(const PresenceIntent(state: Presence.brb).toJson());
    c.send(const QueueIntent.add(QueueItem(
            media: HelloMedia(name: 'f.mkv', size: 10, duration: 0), how: QueueHow.file, title: 'f', key: 'key-of-f-1'))
        .toJson());
    c.send(const SwapIntent(media: HelloMedia(name: 'mine.mkv', size: 100, duration: 0, relay: MediaRelay())).toJson());
    await until(() => engine.queue.length == 1 && server.hub.relay != null && member()!.presence == Presence.brb, 'BRB, queued, relayed');
    await Future<void>.delayed(const Duration(milliseconds: 2000));
    expect(member()!.gone, isFalse, reason: 'reports through the proxy keep it present');

    proxy.last!.blackhole();
    final seen = c.frames.length;
    await until(() => member()?.gone ?? false, 'gone');
    expect(member()!.presence, Presence.brb);
    expect(engine.queue.items.single.by, c.memberId);
    expect(server.hub.relay, isNotNull, reason: 'the relay lives through the grace (D6)');
    expect(engine.media!.relay!.sourceGone, isTrue);
    expect(server.hub.sockets.containsKey(c.token), isFalse);
    // Half-open: the server's close never reached the client.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.ended, isFalse);
    expect(c.frames.length, seen);
    expect(proxy.last!.isClosed, isFalse);
    expect(proxy.last!.dropped, greaterThan(0));

    final again = dial(seq: 2);
    await until(() => again.welcome != null, 'welcome after redial');
    expect(again.welcome!['resumed'], isTrue);
    expect([again.memberId, again.token], [c.memberId, c.token]);
    expect(engine.members, hasLength(1));
    expect(member()!.loading, isTrue, reason: 'media is up: it loads, then comes in (D2)');
    expect(member()!.presence, Presence.brb, reason: 'BRB survives the drop');
    expect(engine.media!.relay!.sourceGone, isFalse);
    final actions = [for (final f in again.frames) if (f['t'] == 'feed') f['action']];
    expect(actions, isNot(contains('join')), reason: 'a return, not a join');
  });

  test('a reset client sees the drop at once and redials into the same member', () async {
    final c = dial();
    await until(() => c.welcome != null, 'welcome');
    proxy.last!.reset();
    await until(() => c.ended, 'client sees the reset');
    await until(() => server.hub.engine.members[c.token]?.gone ?? false, 'server sees it gone');

    final again = dial(seq: 2);
    await until(() => again.welcome != null, 'welcome after redial');
    expect(proxy.links, hasLength(2));
    expect([again.memberId, again.token], [c.memberId, c.token]);
    expect(server.hub.engine.members, hasLength(1));
  });
}
