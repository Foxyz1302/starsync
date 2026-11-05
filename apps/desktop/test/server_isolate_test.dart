// Your server: one hub for the app's life, a network listener attached
// by Invite and detached by Stop sharing, nothing restarts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/screens/home/picked_media.dart';
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/state/server_isolate.dart';
import 'package:sync_relay_server/server.dart' show SyncServer;

import 'package:starsync/src/session/invite.dart' show InviteLink;
import 'package:starsync/src/session/navigation.dart' show Place;

import 'test_graph.dart';


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
    ws.listen((m) => msgs.add(Map<String, Object?>.from(jsonDecode('$m') as Map)),
        onDone: () => done.complete(ws.closeCode), onError: (_) {});
  }

  final done = Completer<int?>();

  static Future<_Raw> join(int port, String name, {String secret = '', String host = '127.0.0.1'}) async {
    final r = _Raw(await WebSocket.connect('ws://$host:$port/sync'));
    r.ws.add(jsonEncode(HelloMessage(secret: secret, user: HelloUser(name: name)).toJson()));
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

/// This machine's first LAN address (the invite's); loopback when none.
Future<String> _lanHost() async {
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      if (!a.isLoopback) return a.address;
    }
  }
  return '127.0.0.1';
}

List<Map> _members(Map<String, Object?> state) => (state['members'] as List).cast<Map>();

void _hive(String name) {
  MediaKit.ensureInitialized();
  Hive.init('${Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path}/$name');
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

  test('your server: Invite attaches the network listener and Stop sharing detaches it; '
      'members and Up next never reset; a crash brings a new one home',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    _hive('hive_your_server_test');
    final graph = testGraph();
    final coord = graph.coordinator;
    final yours = graph.yourServer;
    final tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;
    final file = File('$tmp/your server file.mkv')..writeAsBytesSync(List.filled(4096, 7));
    final port = await _freePort();
    _Raw? friend;
    try {
      expect(await graph.navigation.goHome(), isTrue);
      expect(graph.navigation.place.peek(), Place.yours);
      await coord.playback.player.setVolume(0);
      final ownPort = yours.port.peek()!;
      final me = coord.connection.memberId;
      expect(me, isNotEmpty);
      // Only this app can reach it: a LAN address of this machine is refused.
      final lan = await _lanHost();
      if (lan != '127.0.0.1') {
        await expectLater(Socket.connect(lan, ownPort, timeout: const Duration(seconds: 3)),
            throwsA(isA<SocketException>()));
      }
      expect(coord.alone.peek(), isTrue);
      expect(await coord.swapPicked(FileMedia(file.path)), isNull);
      await _poll(() => coord.serverState.peek()?.media?['name'] == 'your server file.mkv', 'media up');

      graph.forms.form
        ..hostPort = '$port'
        ..hostSecret = 'pw';
      final invite = await yours.invite();
      expect(invite.port, port);
      expect(invite.password, isTrue);
      // The link is the key: the password it was shared with, even when
      // the setting changes later.
      graph.forms.form.hostSecret = 'changed';
      expect(InviteLink.parse(yours.inviteLink(invite))?.secret, 'pw');
      graph.forms.form.hostSecret = 'pw';
      expect(yours.shared.peek(), invite);
      expect(identical(await yours.invite(), invite), isTrue, reason: 'already shared: the same invite');

      friend = await _Raw.join(port, 'friend', secret: 'pw', host: lan);
      final state = await friend.next('state', where: (m) => _members(m).length == 2 && m['media'] != null);
      expect(_members(state).firstWhere((m) => m['id'] == me)['host'], isTrue);
      friend.ws.add(jsonEncode({
        't': 'queue',
        'op': 'add',
        'item': {
          'media': {'name': 'b', 'size': 0, 'duration': 0, 'url': 'http://example.com/b.mp4'},
          'how': 'direct',
          'title': 'B',
        },
      }));
      await _poll(() => coord.queue.items.peek().length == 1, 'queued by the friend');
      expect(coord.alone.peek(), isFalse);
      // Anyone may set the host out; its player stays, the server serves on.
      friend.ws.add(jsonEncode(PresenceIntent(target: me, state: Presence.out).toJson()));
      await _poll(() => coord.selfOut.peek(), 'host out');
      final friendId = _members(state).firstWhere((m) => m['name'] == 'friend')['id'];
      coord.nudgeMember('$friendId');
      expect((await friend.next('nudge'))['name'], isNotEmpty);
      coord.join();

      await yours.stopSharing();
      expect(await friend.done.future.timeout(const Duration(seconds: 5)), CloseCodes.closed,
          reason: 'told: their app does not retry');
      await _poll(() => coord.alone.peek(), 'alone again');
      expect(coord.connection.memberId, me, reason: 'the same member, never reconnected');
      expect(coord.restarts.peek(), 0);
      expect(coord.queue.items.peek(), hasLength(1), reason: 'Up next stays');
      expect(coord.serverState.peek()?.media?['name'], 'your server file.mkv');
      expect(yours.port.peek(), ownPort, reason: 'nothing restarted');
      final freed = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await freed.close();

      // A crash: said, and home again on a new server.
      yours.server!.isolate.kill(priority: Isolate.immediate);
      await _poll(() => yours.crash.peek() != null, 'crash reported');
      await _poll(() => graph.navigation.place.peek() == Place.yours && yours.port.peek() != null, 'home again');
      expect(yours.crash.peek(), startsWith('server crashed'));
    } finally {
      await friend?.ws.close();
      await graph.navigation.leave();
      await yours.stop();
      if (file.existsSync()) file.deleteSync();
    }
  });

  test('a friend\'s server and back: yours keeps what plays and Up next', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    _hive('hive_your_server_switch_test');
    final graph = testGraph();
    final coord = graph.coordinator;
    final yours = graph.yourServer;
    final theirs = SyncServer(const AppConfig(port: 0, secret: '', name: "Bob's server"));
    await theirs.start();
    try {
      expect(await graph.navigation.goHome(), isTrue);
      await coord.playback.player.setVolume(0);
      final ownPort = yours.port.peek();
      coord.connection.sendSwap(const HelloMedia(name: 'mine', size: 0, duration: 0, url: 'http://127.0.0.1:9/mine.mp4'));
      expect(await coord.queue.add(const LinkMedia('http://127.0.0.1:9/next.mp4', relay: LinkRelay.direct, anyway: true)), isNull);
      await _poll(() => coord.serverState.peek()?.media?['name'] == 'mine' && coord.queue.items.peek().length == 1,
          'media and Up next on your server');

      await graph.navigation.join(ConnectParams(host: '127.0.0.1', port: theirs.boundPort, secret: '', name: 'me'));
      expect(graph.navigation.place.peek(), Place.friend);
      expect(graph.navigation.serverLabel.peek(), "Bob's server");
      expect(coord.hostFile, isNull, reason: 'not your server');
      await _poll(() => theirs.hub.engine.members.length == 1, 'in their server');
      expect(yours.port.peek(), ownPort, reason: 'yours stays up, quiet');
      expect(graph.forms.recents.peek().first.port, '${theirs.boundPort}');

      expect(await graph.navigation.leaveFriend(), isTrue);
      expect(graph.navigation.place.peek(), Place.yours);
      await _poll(() => coord.serverState.peek()?.media?['name'] == 'mine', 'your media again');
      expect(coord.queue.items.peek(), hasLength(1));
      expect(yours.port.peek(), ownPort);
      await _poll(() => theirs.hub.engine.members.isEmpty, 'left theirs with bye');
    } finally {
      await graph.navigation.leave();
      await yours.stop();
      await theirs.stop();
    }
  });

  test('a friend\'s server restarts: its name and version are read again', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    _hive('hive_friend_restart_test');
    final graph = testGraph();
    final first = SyncServer(const AppConfig(port: 0, secret: '', name: 'Old name'));
    await first.start();
    final port = first.boundPort;
    SyncServer? second;
    try {
      expect(await graph.navigation.goHome(), isTrue);
      await graph.navigation.join(ConnectParams(host: '127.0.0.1', port: port, secret: '', name: 'me'));
      expect(graph.navigation.serverLabel.peek(), 'Old name');
      await first.stop();
      second = SyncServer(AppConfig(port: port, secret: '', name: 'New name'));
      await second.start();
      await _poll(() => graph.navigation.serverLabel.peek() == 'New name', 'the new name after the restart',
          timeout: const Duration(seconds: 30));
    } finally {
      await graph.navigation.leave();
      await graph.yourServer.stop();
      await second?.stop();
    }
  });

  test('a friend stops sharing: told, and you are back home on yours', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    _hive('hive_your_server_closed_test');
    final me = testGraph();
    final bob = testGraph();
    final port = await _freePort();
    try {
      expect(await bob.navigation.goHome(), isTrue);
      await bob.coordinator.playback.player.setVolume(0);
      bob.forms.form
        ..hostPort = '$port'
        ..hostSecret = '';
      final invite = await bob.yourServer.invite();
      expect(await me.navigation.goHome(), isTrue);
      await me.coordinator.playback.player.setVolume(0);
      final mine = me.yourServer.port.peek();
      await me.navigation.join(ConnectParams(host: '127.0.0.1', port: invite.port, secret: '', name: 'me'));
      expect(me.navigation.place.peek(), Place.friend);
      await _poll(() => !bob.coordinator.alone.peek(), 'bob sees me');

      await bob.yourServer.stopSharing();
      await _poll(() => me.navigation.place.peek() == Place.yours, 'back home');
      expect(me.yourServer.port.peek(), mine, reason: 'the same server as before');
      await _poll(() => me.notifier.toasts.peek().any((t) => t.text.contains('stopped sharing')), 'told why');
      await _poll(() => bob.coordinator.alone.peek(), 'bob alone again');
    } finally {
      await me.navigation.leave();
      await bob.navigation.leave();
      await me.yourServer.stop();
      await bob.yourServer.stop();
    }
  });
}
