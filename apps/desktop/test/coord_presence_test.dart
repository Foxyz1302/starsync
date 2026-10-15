// The session through drops, takeovers and goodbyes: real coordinators
// (real mpv), a real server, and FlakyProxy between a member and it.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_core/testing.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/playback/yt_dlp_app.dart';
import 'package:starsync/src/screens/home/picked_media.dart';
import 'package:starsync/src/session/connection.dart';
import 'package:starsync/src/session/identity.dart';
import 'package:starsync/src/session/notifier.dart';
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/sfx/sfx.dart';
import 'package:starsync/src/sync/sync_client.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

Future<void> _poll(
  FutureOr<bool> Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out waiting for $what');
}

/// Two minutes of small test video with sound (headless mpv needs audio).
Future<String> _media() async {
  final path = '$_tmp/coord_presence_120s.mkv';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=12',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=22050',
    '-t', '120', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '12', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '32k', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

/// Serves [file] with ranges: a link everyone opens directly, so only the
/// sync socket goes through the proxy.
Future<HttpServer> _origin(String file) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
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
  return s;
}

class _RecordingSfx implements SfxService {
  final kinds = <SfxKind>[];
  @override
  Future<void> play(SfxCue cue) async => kinds.add(cue.kind);
}

void main() {
  late List<SessionCoordinator> all;

  setUp(() {
    MediaKit.ensureInitialized();
    all = [];
  });

  tearDown(() async {
    for (final c in all) {
      await c.dispose();
    }
  });

  /// A member: its own install unless [identity] is given.
  Future<SessionCoordinator> member(int port, String name,
      {String secret = 'pw', _RecordingSfx? sfx, ClientIdentity? identity}) async {
    final acc = JellyfinAccounts(store: MemoryJellyfinStore());
    await acc.ensureLoaded(validate: false);
    final n = Notifier(sfx: sfx ?? const NoopSfxService());
    final c = SessionCoordinator(
        notifier: n,
        connection: Connection(notify: n.notify, identity: identity),
        jellyfin: acc,
        trackPrefs: TrackPrefs(store: MemoryJellyfinStore()),
        ytDlp: AppYtDlp(YtDlp('$_tmp/coord_presence_no_ytdlp', enabled: false)));
    all.add(c);
    await c.connect(ConnectParams(host: '127.0.0.1', port: port, secret: secret, name: name));
    await c.playback.player.setVolume(0);
    return c;
  }

  /// [up] puts the video up, everyone readies, it plays.
  Future<void> playTogether(SessionCoordinator up, List<SessionCoordinator> xs, String link) async {
    expect(await up.swapPicked(LinkMedia(link, anyway: true)), isNull);
    await _poll(() => xs.every((x) => x.playback.durationSecs > 100), 'all opened it', timeout: const Duration(seconds: 30));
    for (final x in xs) {
      x.toggleReady();
    }
    await _poll(() => xs.every((x) => x.playback.player.state.playing), 'all playing');
  }

  test('a drop and return while playing: same member, nothing reopened, the state kept throughout',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 'drop'));
    await server.start();
    final origin = await _origin(await _media());
    final proxy = await FlakyProxy.start(server.boundPort);
    try {
      final alice = await member(server.boundPort, 'alice');
      final sounds = _RecordingSfx();
      final bob = await member(proxy.port, 'bob', sfx: sounds);
      await playTogether(alice, [alice, bob], 'http://127.0.0.1:${origin.port}/ep.mkv');
      final id = bob.connection.memberId;
      final token = bob.connection.token;
      final opens = bob.opens;
      final mediaId = bob.serverState.peek()!.mediaId;

      // Bob's link goes half-open (no FIN): unstable from ~3 s, lost at
      // ~9 s, then a new dial through a link that works.
      final link = proxy.links.single;
      link.blackhole();
      var sawStale = false, sawUnstable = false, lostState = false;
      await _poll(() {
        final s = bob.serverState.peek();
        if (s == null || s.media == null) lostState = true;
        if (bob.stateStale.peek()) sawStale = true;
        if (bob.unstable.peek()) sawUnstable = true;
        return proxy.links.length > 1 && bob.connection.state.peek() is ConnOnline;
      }, 'bob back online', timeout: const Duration(seconds: 30));
      expect(lostState, isFalse, reason: 'the state (and the update band off the video) survives the drop');
      expect(sawUnstable, isTrue, reason: '"connection unstable" before lost');
      expect(sawStale, isTrue);
      expect(bob.connection.memberId, id, reason: 'the same member');
      expect(bob.connection.token, token);
      expect(bob.opens, opens, reason: 'the player kept the media');
      expect(bob.serverState.peek()!.mediaId, mediaId);
      // Playing on (a drift correction on the return may seek once).
      await _poll(() => bob.playback.player.state.playing, 'bob playing', timeout: const Duration(seconds: 3));
      expect(server.hub.engine.members.values.where((m) => m.name == 'bob'), hasLength(1));
      // A drop that long is heard once each way.
      await _poll(() => sounds.kinds.contains(SfxKind.back), 'back sound');
      expect(sounds.kinds.where((k) => k == SfxKind.lost), hasLength(1));
      expect(sounds.kinds.where((k) => k == SfxKind.back), hasLength(1));
      // In sync again.
      await Future.delayed(const Duration(seconds: 3));
      final gap = (alice.playback.positionSecs - bob.playback.positionSecs).abs();
      expect(gap, lessThan(1.5), reason: 'in sync after the return');
    } finally {
      await proxy.close();
      await origin.close(force: true);
      await server.stop();
    }
  });

  test('10 flaps in 60 s: at most one lost/back sound, nothing reopened, one member',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 'flaps'));
    await server.start();
    final origin = await _origin(await _media());
    final proxy = await FlakyProxy.start(server.boundPort);
    try {
      final alice = await member(server.boundPort, 'alice');
      final sounds = _RecordingSfx();
      final bob = await member(proxy.port, 'bob', sfx: sounds);
      await playTogether(alice, [alice, bob], 'http://127.0.0.1:${origin.port}/ep.mkv');
      final id = bob.connection.memberId;
      final opens = bob.opens;
      final watcher = SyncClient();
      final feed = <FeedMessage>[];
      final sub = watcher.feeds.listen(feed.add);
      await watcher.connect(wsUri: Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'), secret: 'pw', name: 'watcher');
      // The sync socket: the first link, then each one dialled while
      // reconnecting (the session log upload and pictures go through the
      // proxy too).
      var sync = proxy.links.single;
      final dials = proxy.connections.listen((l) {
        if (bob.connection.state.peek().retrying) sync = l;
      });
      var drops = 0;
      final stopCount = bob.connection.state.subscribe((s) {
        if (s is ConnLost) drops++;
      });
      try {
        for (var i = 0; i < 10; i++) {
          await _poll(() => bob.connection.state.peek() is ConnOnline, 'bob online before flap $i');
          sync.reset();
          await Future.delayed(const Duration(seconds: 5));
        }
        await _poll(() => bob.connection.state.peek() is ConnOnline, 'bob online after the flaps');
        expect(drops, greaterThanOrEqualTo(10), reason: 'every flap dropped the link');
        expect(sounds.kinds.where((k) => k == SfxKind.lost).length, lessThanOrEqualTo(1));
        expect(sounds.kinds.where((k) => k == SfxKind.back).length, lessThanOrEqualTo(1));
        expect(bob.opens, opens, reason: 'no reopen per flap');
        expect(bob.connection.memberId, id);
        expect(server.hub.engine.members.values.where((m) => m.name == 'bob'), hasLength(1));
        expect(feed.where((f) => f.actorId == id && (f.action == 'join' || f.action == 'leave')), isEmpty,
            reason: 'quick returns say nothing to the others');
        expect(bob.playback.player.state.playing, isTrue);
      } finally {
        stopCount();
        await dials.cancel();
        await sub.cancel();
        await watcher.dispose();
      }
    } finally {
      await proxy.close();
      await origin.close(force: true);
      await server.stop();
    }
  });

  test('replaced: opened in another window, the older one stops for good',
      timeout: const Timeout(Duration(minutes: 1)), () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 'replaced'));
    await server.start();
    try {
      final install = ClientIdentity.ephemeral();
      final first = await member(server.boundPort, 'me', identity: install);
      final id = first.connection.memberId;
      final second = await member(server.boundPort, 'me', identity: install);
      expect(second.connection.memberId, id, reason: 'the newer connection took the member over');
      await _poll(() => first.connection.state.peek() is ConnReplaced, 'the first one replaced');
      expect(first.status.peek().line?.text, replacedText);
      // It does not fight back.
      await Future.delayed(const Duration(seconds: 4));
      expect(first.connection.state.peek(), isA<ConnReplaced>());
      expect(first.reconnecting.peek(), isFalse);
      expect(second.connection.state.peek(), isA<ConnOnline>());
      expect(server.hub.engine.members, hasLength(1));
    } finally {
      await server.stop();
    }
  });

  test('leave sends bye (others see "left" at once); update and restart does not',
      timeout: const Timeout(Duration(minutes: 1)), () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 'bye'));
    await server.start();
    final watcher = SyncClient();
    final feed = <FeedMessage>[];
    final sub = watcher.feeds.listen(feed.add);
    try {
      await watcher.connect(wsUri: Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'), secret: 'pw', name: 'watcher');
      final leaver = await member(server.boundPort, 'leaver');
      final id = leaver.connection.memberId;
      final sw = Stopwatch()..start();
      await leaver.leave();
      await _poll(() => feed.any((f) => f.action == 'leave' && f.actorId == id), 'leave line',
          timeout: const Duration(seconds: 3));
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(feed.firstWhere((f) => f.action == 'leave' && f.actorId == id).reason, 'bye');
      expect(server.hub.engine.byId(id), isNull);

      final restarter = await member(server.boundPort, 'restarter');
      final rid = restarter.connection.memberId;
      await restarter.leave(bye: false);
      await _poll(() => server.hub.engine.byId(rid)?.presence == Presence.gone, 'gone, kept for its grace');
      await Future.delayed(const Duration(seconds: 1));
      expect(feed.where((f) => f.action == 'leave' && f.actorId == rid), isEmpty);
    } finally {
      await sub.cancel();
      await watcher.dispose();
      await server.stop();
    }
  });

  test('a dead server: the state stays (stale), the app reconnects, and "stop reconnecting" stops',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 'presence', name: 'presence'));
    await server.start();
    final coord = await member(server.boundPort, 'watcher', secret: 'presence');
    await _poll(() => coord.serverState.peek() != null, 'server state to arrive');
    expect(coord.reconnecting.peek(), isFalse);
    expect(coord.stateStale.peek(), isFalse);

    await server.stop();
    await _poll(() => coord.reconnecting.peek() == true, 'reconnect loop to engage');
    expect(coord.serverState.peek(), isNotNull, reason: 'a drop keeps the last state');
    expect(coord.stateStale.peek(), isTrue);
    coord.cancelReconnect();
    expect(coord.reconnecting.peek(), isFalse);
  });

  test('cancel then retry within the reconnect delay dials only once',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final first = SyncServer(const AppConfig(port: 0, secret: 'race', name: 'race'));
    await first.start();
    final port = first.boundPort;
    SyncServer? second;
    final observer = SyncClient();
    try {
      final coord = await member(port, 'watcher', secret: 'race');
      await first.stop();
      await _poll(() => coord.reconnecting.peek(), 'reconnect to engage');
      second = SyncServer(AppConfig(port: port, secret: 'race', name: 'race'));
      await second.start();
      var joins = 0;
      final sub = observer.feeds.listen((f) {
        if (f.action == 'join' && f.actor == 'watcher') joins++;
      });
      await observer.connect(wsUri: Uri.parse('ws://127.0.0.1:$port/sync'), secret: 'race', name: 'observer');
      // Within the first delay: the first attempt must die with Cancel.
      coord.cancelReconnect();
      coord.retry();
      await _poll(() => !coord.reconnecting.peek() && coord.connection.state.peek().online, 'reconnect to land');
      await Future.delayed(const Duration(seconds: 4));
      await sub.cancel();
      expect(joins, 1, reason: 'a stale attempt dialled a second time');
      expect(second.hub.engine.members.values.where((m) => m.name == 'watcher').length, 1);
    } finally {
      await observer.dispose();
      await second?.stop();
    }
  });

  test('a restarted server (not resumed): the app sends its ready again (force-all included)',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final first = SyncServer(const AppConfig(port: 0, secret: 'force', name: 'force'));
    await first.start();
    final port = first.boundPort;
    final friend = SyncClient();
    SyncServer? second;
    try {
      final coord = await member(port, 'watcher', secret: 'force');
      await friend.connect(wsUri: Uri.parse('ws://127.0.0.1:$port/sync'), secret: 'force', name: 'friend');
      // Never pressed Space locally; a friend marks everyone ready.
      friend.sendForce('all', true);
      await _poll(() => coord.selfMember.peek()?.ready == true, 'forced ready to reach watcher');
      await friend.disconnect();
      await first.stop();
      await _poll(() => coord.reconnecting.peek(), 'reconnect to engage');
      second = SyncServer(AppConfig(port: port, secret: 'force', name: 'force'));
      await second.start();
      await _poll(() => second!.hub.engine.members.values.any((m) => m.name == 'watcher' && m.ready),
          'watcher to come back ready');
    } finally {
      await friend.dispose();
      await second?.stop();
    }
  });

  test('cancel during connect setup aborts without joining', timeout: const Timeout(Duration(minutes: 1)), () async {
    final server = SyncServer(const AppConfig(port: 0, secret: '', name: 'cancel'));
    await server.start();
    final coord = SessionCoordinator();
    try {
      final pending =
          coord.connect(ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: '', name: 'watcher'));
      await coord.cancelConnect();
      await expectLater(pending, throwsA(isA<ConnectCancelled>()));
      await Future.delayed(const Duration(seconds: 2));
      expect(server.hub.engine.members, isEmpty);
      expect(coord.reconnecting.peek(), isFalse);
    } finally {
      await coord.dispose();
      await server.stop();
    }
  });

  test('stop sharing releases the port; stopping your server frees its own', timeout: const Timeout(Duration(minutes: 1)),
      () async {
    Hive.init('$_tmp/hive_coord_test');
    final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = probe.port;
    await probe.close();
    final yours = _graph.yourServer;
    _graph.forms.form
      ..hostPort = '$port'
      ..hostSecret = '';
    try {
      final own = await yours.start(name: 'me');
      expect((await yours.invite()).port, port);
      await yours.stopSharing();
      final rebind = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await rebind.close();
      await yours.stop();
      final again = await ServerSocket.bind(InternetAddress.loopbackIPv4, own);
      await again.close();
    } finally {
      await yours.stop();
    }
  });

  test('feed and chat toasts name their actor exactly', timeout: const Timeout(Duration(minutes: 1)), () async {
    final server = SyncServer(const AppConfig(port: 0, secret: 'toast', name: 'toast'));
    await server.start();
    final sounds = _RecordingSfx();
    final friend = SyncClient();
    try {
      final coord = await member(server.boundPort, 'Bob', secret: 'toast', sfx: sounds);
      await friend.connect(
          wsUri: Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'), secret: 'toast', name: 'Bob Jr');
      friend.sendChat('hi there');
      await _poll(() => coord.toasts.peek().any((t) => t.text == 'Bob Jr: hi there'), 'chat toast');
      final toasts = coord.toasts.peek();
      expect(toasts.firstWhere((t) => t.text == 'Bob Jr joined').actor, 'Bob Jr');
      final chat = toasts.firstWhere((t) => t.text == 'Bob Jr: hi there');
      expect(chat.chat, isTrue);
      expect(chat.actor, 'Bob Jr');
      expect(chat.actorId, friend.memberId, reason: 'matched by member id');
      // Others' chat makes a sound, your own does not.
      expect(sounds.kinds.where((k) => k == SfxKind.chat), hasLength(1));
      coord.sendChat('mine');
      await _poll(() => coord.toasts.peek().any((t) => t.text == 'Bob: mine'), 'own chat');
      expect(sounds.kinds.where((k) => k == SfxKind.chat), hasLength(1));
      expect(sounds.kinds, contains(SfxKind.join));
    } finally {
      await friend.dispose();
      await server.stop();
    }
  });
}
