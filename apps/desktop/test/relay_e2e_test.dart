import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:watch_together/src/jellyfin/accounts.dart';
import 'package:watch_together/src/jellyfin/track_prefs.dart';
import 'package:watch_together/src/screens/home/picked_media.dart';
import 'package:watch_together/src/session/session_coordinator.dart';

// The relay with real coordinators, real mpv and a dedicated server that
// has no file and no Jellyfin login of its own (the VPS setup): a guest's
// file, and links passed on by a member or fetched by the server.

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

Future<String> _media() async {
  final path = '$_tmp/relay_e2e_20s.mkv';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '20', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

Future<void> _poll(FutureOr<bool> Function() cond, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out waiting for $what');
}

/// Serves one file with ranges; [requests] counts hits.
Future<(HttpServer, List<String>)> _origin(String file) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <String>[];
  s.listen((req) async {
    requests.add(req.uri.toString());
    final size = await File(file).length();
    final r = resolveMediaRequest(rangeHeader: req.headers.value('range'), size: size, filename: 'v.mkv');
    req.response.statusCode = r.status;
    r.headers.forEach(req.response.headers.set);
    try {
      if (r.status == 200 || r.status == 206) {
        await req.response.addStream(File(file).openRead(r.start, (r.end ?? size - 1) + 1));
      }
      await req.response.close();
    } catch (_) {}
  });
  return (s, requests);
}

void main() {
  late SyncServer server;
  late List<SessionCoordinator> all;

  Future<SessionCoordinator> member(String name) async {
    final acc = JellyfinAccounts(store: MemoryJellyfinStore());
    await acc.ensureLoaded(validate: false);
    final c = SessionCoordinator(jellyfin: acc, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
    all.add(c);
    await c.connect(ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: 'pw', name: name));
    await c.playback.player.setVolume(0);
    return c;
  }

  Future<void> playTogether(List<SessionCoordinator> xs) async {
    await _poll(() => xs.every((x) => x.playback.durationSecs > 19), 'all opened it');
    for (final x in xs) {
      x.toggleReady();
    }
    await _poll(() => xs.every((x) => x.playback.player.state.playing), 'all playing');
    await Future.delayed(const Duration(seconds: 3));
    final pos = [for (final x in xs) x.playback.positionSecs];
    // ignore: avoid_print
    print('positions after 3 s: $pos');
    for (final p in pos) {
      expect((p - pos.first).abs(), lessThan(1.0), reason: 'in sync: $pos');
    }
    for (final x in xs) {
      x.toggleReady();
    }
    await _poll(() => xs.every((x) => !x.playback.player.state.playing), 'held');
  }

  setUp(() async {
    MediaKit.ensureInitialized();
    all = [];
    server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 'vps'));
    await server.start();
  });

  tearDown(() async {
    for (final x in all) {
      await x.dispose();
    }
    await server.stop();
  });

  test('a guest puts up a file: it plays for everyone through the relay', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    final file = await _media();
    final alice = await member('alice');
    final bob = await member('bob');
    expect(await bob.swapPicked(FileMedia(file)), isNull);
    await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.source == bob.sync.memberId, 'relay state');
    final state = alice.serverState.peek()!;
    expect(state.media!.containsKey('url'), isFalse);
    expect(bob.relaying.peek(), isTrue);
    await playTogether([alice, bob]);
    final relay = server.hub.relay!;
    expect(relay.buffer.bytesToViewers, greaterThan(0), reason: 'alice played through the relay');
    expect(relay.sourceToken, bob.sync.token);

    // The next swap retires bob's source and the buffer.
    alice.swapPicked(const LinkMedia('http://127.0.0.1:1/none.mkv'));
    await _poll(() => !bob.relaying.peek(), 'source stopped');
    expect(server.hub.relay, isNull);
  });

  test('links: through me, and fetched by the server; never broadcast', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    final (origin, hits) = await _origin(await _media());
    try {
      final alice = await member('alice');
      final bob = await member('bob');
      final link = 'http://127.0.0.1:${origin.port}/private/ep.mkv?api_key=SECRET';

      expect(await bob.swapPicked(LinkMedia(link, relay: LinkRelay.me)), isNull);
      await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.source == bob.sync.memberId, 'me state');
      expect(alice.serverState.peek()!.toJson().toString(), isNot(contains('SECRET')));
      await playTogether([alice, bob]);
      expect(server.hub.relay!.buffer.bytesToViewers, greaterThan(0));

      final before = hits.length;
      expect(await alice.swapPicked(LinkMedia(link, relay: LinkRelay.server)), isNull);
      await _poll(() => stateMediaRelay(bob.serverState.peek()!)?.fetch == true, 'fetch state');
      expect(bob.serverState.peek()!.toJson().toString(), isNot(contains('SECRET')));
      expect(alice.relaying.peek(), isFalse, reason: 'the server fetches, nobody sources');
      await playTogether([alice, bob]);
      expect(hits.length, greaterThan(before));

      // A page instead of a file is refused up front.
      final page = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      page.listen((r) {
        r.response.headers.contentType = ContentType.html;
        r.response.write('<html></html>');
        r.response.close();
      });
      expect(await alice.swapPicked(LinkMedia('http://127.0.0.1:${page.port}/watch?v=x', relay: LinkRelay.me)),
          contains('cannot pass this link on'));
      await page.close(force: true);
    } finally {
      await origin.close(force: true);
    }
  });

  test('the source drops uncleanly and resumes: it keeps its copy and keeps serving',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final file = await _media();
    final proxy = await _Blackhole.start(server.boundPort);
    try {
      final alice = await member('alice');
      final acc = JellyfinAccounts(store: MemoryJellyfinStore());
      await acc.ensureLoaded(validate: false);
      final bob = SessionCoordinator(jellyfin: acc, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      all.add(bob);
      await bob.connect(ConnectParams(host: '127.0.0.1', port: proxy.port, secret: 'pw', name: 'bob'));
      await bob.playback.player.setVolume(0);
      expect(await bob.swapPicked(FileMedia(file)), isNull);
      await _poll(() => server.hub.relay?.live == true, 'source live');
      await _poll(() => alice.playback.durationSecs > 19 && bob.playback.durationSecs > 19, 'both opened');
      final token = bob.sync.token;

      // Bob's network goes silent (no FIN): states stop, he reconnects
      // with `resume`, the server still has him.
      proxy.cut();
      await _poll(() => bob.reconnecting.peek(), 'reconnect engaged', timeout: const Duration(seconds: 15));
      await _poll(() => !bob.reconnecting.peek() && bob.serverState.peek() != null, 'back',
          timeout: const Duration(seconds: 20));
      expect(bob.sync.token, token, reason: 'resumed as the same member');
      await _poll(() => server.hub.relay?.live == true, 'source redialled', timeout: const Duration(seconds: 15));
      expect(bob.relaying.peek(), isTrue);
      expect(bob.playback.durationSecs, greaterThan(19), reason: 'still his own copy');

      // Alice can still get bytes the buffer never had.
      alice.seekTo(17);
      await _poll(() => (alice.playback.positionSecs - 17).abs() < 1.5, 'alice seeked');
    } finally {
      await proxy.close();
    }
  });
}

/// TCP proxy whose [cut] silently stops forwarding on every connection made
/// so far (no FIN, like a dead Wi-Fi); later connections work.
class _Blackhole {
  final ServerSocket _server;
  final _conns = <(Socket, Socket, List<bool>)>[];
  _Blackhole(this._server);
  int get port => _server.port;

  static Future<_Blackhole> start(int target) async {
    final b = _Blackhole(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    b._server.listen((c) async {
      final up = await Socket.connect('127.0.0.1', target);
      final dead = [false];
      b._conns.add((c, up, dead));
      c.listen((d) {
        if (!dead[0]) up.add(d);
      }, onDone: () => dead[0] ? null : up.destroy(), onError: (_) {});
      up.listen((d) {
        if (!dead[0]) c.add(d);
      }, onDone: () => dead[0] ? null : c.destroy(), onError: (_) {});
    });
    return b;
  }

  void cut() {
    for (final (_, _, dead) in _conns) {
      dead[0] = true;
    }
  }

  Future<void> close() async {
    await _server.close();
    for (final (a, b, _) in _conns) {
      a.destroy();
      b.destroy();
    }
  }
}
