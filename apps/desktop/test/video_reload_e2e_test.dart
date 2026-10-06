import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:watch_together/src/session/session_coordinator.dart';
import 'package:watch_together/src/sync/room_diff.dart';

const _mediaPath = '/home/foxyz/Videos/chiyo.mp4';

Future<void> _poll(
  FutureOr<bool> Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 30),
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
    'reload video: new player, same media, resynced, ready untouched; '
    'leave disposes the player',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      MediaKit.ensureInitialized();
      final server = RoomServer(const AppConfig(
          port: 0, secret: 'reload', name: 'reload', mediaPath: _mediaPath));
      await server.start();
      final c = SessionCoordinator();
      try {
        await c.connect(ConnectParams(
            host: '127.0.0.1',
            port: server.boundPort,
            secret: 'reload',
            name: 'solo'));
        await c.playback.player.setVolume(0);
        await _poll(() => c.room.peek() != null, 'room state');
        c.toggleReady();
        await _poll(
            () => c.playback.player.state.playing && c.playback.positionSecs > 2,
            'solo playback past 2 s');

        final old = c.playback.player;
        final gen = c.playback.generation.peek();
        await c.reloadVideo();
        expect(identical(c.playback.player, old), isFalse);
        expect(c.playback.generation.peek(), gen + 1);
        expect(c.selfMember.peek()?.ready, isTrue);

        await _poll(() {
          final r = c.room.peek();
          if (r == null || !c.playback.player.state.playing) return false;
          final want = roomPositionAt(r, DateTime.now().toUtc());
          return (c.playback.positionSecs - want).abs() < 1.5 &&
              c.playback.positionSecs > 2;
        }, 'reloaded player playing at the synced position');
        expect(c.selfMember.peek()?.ready, isTrue);
        expect(c.room.peek()?.transport, 'playing');

        await c.leave();
        expect(c.playback.alive.peek(), isFalse);
      } finally {
        await c.dispose();
        await server.stop();
      }
    },
  );
}
