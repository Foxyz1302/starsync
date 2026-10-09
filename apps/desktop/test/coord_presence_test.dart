import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:hive_ce/hive.dart';
import 'package:watch_together/src/session/session_coordinator.dart';
import 'package:watch_together/src/sfx/sfx.dart';
import 'package:watch_together/src/state/session_state.dart';
import 'package:watch_together/src/sync/sync_client.dart';

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

void main() {
  test(
    'dead server clears server state and reconnects instead of freezing',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      MediaKit.ensureInitialized();
      final server = SyncServer(
          const AppConfig(port: 0, secret: 'presence', name: 'presence'));
      await server.start();
      final coord = SessionCoordinator();
      try {
        await coord.connect(ConnectParams(
          host: '127.0.0.1',
          port: server.boundPort,
          secret: 'presence',
          name: 'watcher',
        ));
        await coord.playback.player.setVolume(0);
        await _poll(() => coord.serverState.peek() != null, 'server state to arrive');
        expect(coord.reconnecting.peek(), isFalse);

        await server.stop();
        await _poll(
          () => coord.reconnecting.peek() == true,
          'reconnect loop to engage',
        );
        await _poll(
          () => coord.serverState.peek() == null,
          'stale state (ghost members) to clear',
        );
        coord.cancelReconnect();
        expect(coord.reconnecting.peek(), isFalse);
      } finally {
        await coord.dispose();
      }
    },
  );

  test(
    'cancel then retry within the reconnect delay dials only once',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      MediaKit.ensureInitialized();
      final first = SyncServer(
          const AppConfig(port: 0, secret: 'race', name: 'race'));
      await first.start();
      final port = first.boundPort;
      final coord = SessionCoordinator();
      SyncServer? second;
      final observer = SyncClient();
      try {
        await coord.connect(ConnectParams(
            host: '127.0.0.1', port: port, secret: 'race', name: 'watcher'));
        await coord.playback.player.setVolume(0);
        await first.stop();
        await _poll(() => coord.reconnecting.peek(), 'reconnect to engage');
        second = SyncServer(
            AppConfig(port: port, secret: 'race', name: 'race'));
        await second.start();
        var joins = 0;
        final sub = observer.feeds.listen((f) {
          if (f.action == 'join' && f.actor == 'watcher') joins++;
        });
        await observer.connect(
            wsUri: Uri.parse('ws://127.0.0.1:$port/sync'),
            secret: 'race',
            name: 'observer');
        // Within the 1.5 s delay: the first attempt must die with Cancel.
        coord.cancelReconnect();
        coord.retry();
        await _poll(() => !coord.reconnecting.peek() && coord.serverState.peek() != null,
            'reconnect to land');
        await Future.delayed(const Duration(seconds: 4));
        await sub.cancel();
        expect(joins, 1, reason: 'a stale attempt dialled a second time');
        expect(
            second.hub.engine.members.values
                .where((m) => m.name == 'watcher')
                .length,
            1);
      } finally {
        await observer.dispose();
        await coord.dispose();
        await second?.stop();
      }
    },
  );

  test(
    'reconnect restores the server-side ready flag (force-all included)',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      MediaKit.ensureInitialized();
      final first = SyncServer(
          const AppConfig(port: 0, secret: 'force', name: 'force'));
      await first.start();
      final port = first.boundPort;
      final coord = SessionCoordinator();
      final friend = SyncClient();
      SyncServer? second;
      try {
        await coord.connect(ConnectParams(
            host: '127.0.0.1', port: port, secret: 'force', name: 'watcher'));
        await coord.playback.player.setVolume(0);
        await friend.connect(
            wsUri: Uri.parse('ws://127.0.0.1:$port/sync'),
            secret: 'force',
            name: 'friend');
        // Never pressed Space locally; a friend marks everyone ready.
        friend.sendForce('all', true);
        await _poll(() => coord.selfMember.peek()?.ready == true,
            'forced ready to reach watcher');
        await friend.disconnect();
        await first.stop();
        await _poll(() => coord.reconnecting.peek(), 'reconnect to engage');
        second = SyncServer(
            AppConfig(port: port, secret: 'force', name: 'force'));
        await second.start();
        await _poll(
            () => second!.hub.engine.members.values
                .any((m) => m.name == 'watcher' && m.ready),
            'watcher to come back ready');
      } finally {
        await friend.dispose();
        await coord.dispose();
        await second?.stop();
      }
    },
  );

  test(
    'cancel during connect setup aborts without joining',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      MediaKit.ensureInitialized();
      final server = SyncServer(
          const AppConfig(port: 0, secret: '', name: 'cancel'));
      await server.start();
      final coord = SessionCoordinator();
      try {
        final pending = coord.connect(ConnectParams(
            host: '127.0.0.1',
            port: server.boundPort,
            secret: '',
            name: 'watcher'));
        await coord.cancelConnect();
        await expectLater(pending, throwsA(isA<ConnectCancelled>()));
        await Future.delayed(const Duration(seconds: 2));
        expect(server.hub.engine.members, isEmpty);
        expect(coord.reconnecting.peek(), isFalse);
      } finally {
        await coord.dispose();
        await server.stop();
      }
    },
  );

  test(
    'cancelling a host setup releases the port',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      MediaKit.ensureInitialized();
      Hive.init(
          '${Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path}/hive_coord_test');
      final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final port = probe.port;
      await probe.close();
      final session = SessionState.instance;
      try {
        final pending = session.host(
            ConnectParams(host: '', port: port, secret: '', name: 'host'),
            ConnectForm());
        await session.cancelPending();
        await expectLater(pending, throwsA(isA<ConnectCancelled>()));
        expect(session.route.peek(), isNot(AppRoute.session));
        final rebind = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        await rebind.close();
      } finally {
        await session.coordinator.leave(silent: true);
        await session.stopServer();
      }
    },
  );

  test(
    'feed and chat toasts name their actor exactly',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      MediaKit.ensureInitialized();
      final server = SyncServer(const AppConfig(port: 0, secret: 'toast', name: 'toast'));
      await server.start();
      final sounds = _RecordingSfx();
      final coord = SessionCoordinator(sfx: sounds);
      final friend = SyncClient();
      try {
        await coord.connect(ConnectParams(
            host: '127.0.0.1', port: server.boundPort, secret: 'toast', name: 'Bob'));
        await coord.playback.player.setVolume(0);
        await friend.connect(
            wsUri: Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'), secret: 'toast', name: 'Bob Jr');
        friend.sendChat('hi there');
        await _poll(() => coord.toasts.peek().any((t) => t.text == 'Bob Jr: hi there'), 'chat toast');
        final toasts = coord.toasts.peek();
        expect(toasts.firstWhere((t) => t.text == 'Bob Jr joined').actor, 'Bob Jr');
        expect(toasts.firstWhere((t) => t.text == 'Bob Jr: hi there').actor, 'Bob Jr');
        // Others' chat makes a sound, your own does not.
        expect(sounds.kinds.where((k) => k == SfxKind.chat), hasLength(1));
        coord.sendChat('mine');
        await _poll(() => coord.toasts.peek().any((t) => t.text == 'Bob: mine'), 'own chat');
        expect(sounds.kinds.where((k) => k == SfxKind.chat), hasLength(1));
        expect(sounds.kinds, contains(SfxKind.join));
      } finally {
        await friend.dispose();
        await coord.dispose();
        await server.stop();
      }
    },
  );
}

class _RecordingSfx implements SfxService {
  final kinds = <SfxKind>[];
  @override
  Future<void> play(SfxCue cue) async => kinds.add(cue.kind);
}
