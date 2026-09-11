import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:watch_together/src/session/session_coordinator.dart';

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
    'dead server clears room state and reconnects instead of freezing',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      MediaKit.ensureInitialized();
      final server = RoomServer(
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
        await _poll(() => coord.room.peek() != null, 'room state to arrive');
        expect(coord.reconnecting.peek(), isFalse);

        await server.stop();
        await _poll(
          () => coord.reconnecting.peek() == true,
          'reconnect loop to engage',
        );
        await _poll(
          () => coord.room.peek() == null,
          'stale room (ghost members) to clear',
        );
        coord.cancelReconnect();
        expect(coord.reconnecting.peek(), isFalse);
      } finally {
        await coord.dispose();
      }
    },
  );
}
