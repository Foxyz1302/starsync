import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/jellyfin/accounts.dart';
import 'package:watch_together/src/session/session_coordinator.dart';
import 'package:watch_together/src/state/server_isolate.dart';
import 'package:watch_together/src/state/session_state.dart';

Future<void> _poll(
  FutureOr<bool> Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for $what');
}

/// A bare WebSocket viewer: no player, just the wire.
class _Raw {
  final WebSocket ws;
  final msgs = <Map<String, Object?>>[];
  _Raw(this.ws) {
    ws.listen((m) => msgs.add(Map<String, Object?>.from(jsonDecode('$m') as Map)));
  }

  static Future<_Raw> join(int port, String name, {String secret = ''}) async {
    final r = _Raw(await WebSocket.connect('ws://127.0.0.1:$port/sync'));
    r.ws.add(jsonEncode(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: secret,
            user: HelloUser(name: name),
            media: const HelloMedia(name: '', size: 0, duration: 0))
        .toJson()));
    await r.next('welcome');
    return r;
  }

  Future<Map<String, Object?>> next(String type, {bool Function(Map<String, Object?>)? where}) async {
    late Map<String, Object?> found;
    await _poll(() {
      for (final m in msgs) {
        if (m['t'] == type && (where == null || where(m))) {
          found = m;
          msgs.remove(m);
          return true;
        }
      }
      return false;
    }, '$type from server');
    return found;
  }
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  test('server isolate: logs, raw join, crash reported, stop frees port',
      timeout: const Timeout(Duration(minutes: 1)), () async {
    final logs = <String>[];
    final crashes = <String>[];
    final server = await ServerIsolate.start(
        const AppConfig(port: 0, secret: '', name: 'iso'),
        onLog: logs.add,
        onCrash: crashes.add);
    final viewer = await _Raw.join(server.port, 'viewer');
    await viewer.next('state');
    await _poll(() => logs.any((l) => l.contains('join viewer')), 'join log');
    await viewer.ws.close();
    server.isolate.kill(priority: Isolate.immediate);
    await _poll(() => crashes.isNotEmpty, 'crash callback');
    expect(server.isRunning, isFalse);
    await server.stop(); // no-op on a dead isolate

    final clean = await ServerIsolate.start(
        const AppConfig(port: 0, secret: '', name: 'iso'),
        onLog: (_) {},
        onCrash: crashes.add);
    final port = clean.port;
    await clean.stop();
    expect(crashes, hasLength(1), reason: 'a requested stop is not a crash');
    final rebind = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await rebind.close();
  });

  test('bind failure surfaces as a start error',
      timeout: const Timeout(Duration(seconds: 30)), () async {
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      await expectLater(
          ServerIsolate.start(AppConfig(port: blocker.port, secret: '', name: 'x'),
              onLog: (_) {}, onCrash: (_) {}),
          throwsA(isA<StateError>()));
    } finally {
      await blocker.close();
    }
  });

  test('host path: isolate server, host unkickable, crash leaves the session',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    MediaKit.ensureInitialized();
    Hive.init(
        '${Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path}/hive_isolate_test');
    final session = SessionState.instance;
    final port = await _freePort();
    _Raw? friend;
    try {
      await session.host(
          ConnectParams(host: '', port: port, secret: 'pw', name: 'host'),
          ConnectForm());
      expect(session.route.peek(), AppRoute.session);
      await session.coordinator.playback.player.setVolume(0);

      friend = await _Raw.join(port, 'friend', secret: 'pw');
      final state = await friend.next('state',
          where: (m) => (m['members'] as List).any((x) => (x as Map)['name'] == 'host'));
      final hostId = ((state['members'] as List)
          .cast<Map>()
          .firstWhere((m) => m['name'] == 'host'))['id'];
      friend.ws.add(jsonEncode(KickRequest(target: '$hostId').toJson()));
      final err = await friend.next('err');
      expect(err['message'], "can't kick the host");

      // The host can kick the friend (plain loopback peers are not hosts).
      final friendId = ((state['members'] as List)
          .cast<Map>()
          .firstWhere((m) => m['name'] == 'friend'))['id'];
      session.coordinator.kick('$friendId');
      await friend.next('kicked');

      session.hostedServer!.isolate.kill(priority: Isolate.immediate);
      await _poll(() => session.route.peek() == AppRoute.home, 'leave after crash');
      expect(session.serverCrash.peek(), startsWith('server crashed'));
      expect(session.hostedServer, isNull);
      // The killed isolate's socket stays bound in-process; hosting again on
      // the same port must still work.
      session.serverCrash.value = null;
      await session.host(
          ConnectParams(host: '', port: port, secret: 'pw', name: 'host'),
          ConnectForm());
      expect(session.route.peek(), AppRoute.session);
      final again = await _Raw.join(port, 'again', secret: 'pw');
      await again.ws.close();
      await session.leave();
      expect(session.hostedServer, isNull);
    } finally {
      await friend?.ws.close();
      await session.coordinator.leave(silent: true);
      await session.stopServer();
    }
  });

  test('host path: a Jellyfin pick goes up as a ref with the host relay; File swap',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    MediaKit.ensureInitialized();
    final tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;
    Hive.init('$tmp/hive_isolate_jf_test');
    const sid = 'abcdefabcdefabcdefabcdefabcdef12';
    final accounts = JellyfinAccounts.instance;
    await accounts.ensureLoaded(validate: false);
    // An unreachable Jellyfin: only the wire and the relay flag matter here.
    await accounts.link(
        baseUrl: 'http://127.0.0.1:9',
        server: const JellyfinServerInfo(id: sid, name: 'J', version: '10.11.11'),
        auth: const JellyfinAuthResult(
            accessToken: 'HOSTTOKEN', user: JellyfinUser(id: 'u', name: 'u'), serverId: sid));
    final session = SessionState.instance;
    final port = await _freePort();
    _Raw? friend;
    final file = File('$tmp/host file swap.mkv')..writeAsBytesSync(List.filled(4096, 7));
    try {
      await session.host(
          ConnectParams(
              host: '',
              port: port,
              secret: '',
              name: 'host',
              media: const HelloMedia(
                  name: 'Pilot',
                  size: 0,
                  duration: 0,
                  jellyfin: JellyfinRef(serverId: sid, itemId: 'e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1', title: 'Pilot'))),
          ConnectForm());
      await session.coordinator.playback.player.setVolume(0);
      friend = await _Raw.join(port, 'friend');
      final state = await friend.next('state', where: (m) => m['media'] != null);
      final media = state['media'] as Map;
      expect(media['jellyfin'], isA<Map>());
      expect(media.containsKey('url'), isFalse);
      expect(state['relay'], isTrue, reason: "the host's own sign-in relays for guests");
      expect(jsonEncode(state), isNot(contains('HOSTTOKEN')));

      expect(await session.coordinator.swapFile(file.path), isNull);
      final swapped = await friend.next('state',
          where: (m) => (m['media'] as Map?)?['name'] == 'host file swap.mkv');
      expect((swapped['media'] as Map)['jellyfin'], isNull);
      expect(swapped['relay'], isNull);
      expect(await session.coordinator.swapFile('$tmp/missing.mkv'), contains('not found'));
    } finally {
      await friend?.ws.close();
      await session.coordinator.leave(silent: true);
      await session.stopServer();
      await accounts.signOut(sid);
      if (file.existsSync()) file.deleteSync();
    }
  });
}
