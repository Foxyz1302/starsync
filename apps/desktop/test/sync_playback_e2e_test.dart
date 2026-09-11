import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:watch_together/src/session/session_coordinator.dart';

const _port = 18080;
const _secret = 'e2e-secret';
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

Future<void> _quiet(SessionCoordinator c) async {
  await c.playback.player.setVolume(0);
  try {
    final dynamic platform = c.playback.player.platform;
    await platform?.setProperty('loop-file', 'inf');
  } catch (_) {}
}

void main() {
  test(
    'two app coordinators split play on readiness over real server',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      MediaKit.ensureInitialized();
      final server = RoomServer(const AppConfig(
        port: _port,
        secret: _secret,
        name: 'room',
        mediaPath: _mediaPath,
      ));
      await server.start();

      final host = SessionCoordinator();
      final viewer = SessionCoordinator();
      try {
        await host.connect(const ConnectParams(
          host: '127.0.0.1',
          port: _port,
          secret: _secret,
          name: 'host',
        ));
        await viewer.connect(const ConnectParams(
          host: '127.0.0.1',
          port: _port,
          secret: _secret,
          name: 'viewer',
        ));
        await _quiet(host);
        await _quiet(viewer);

        expect(host.playback.player.state.playing, isFalse,
            reason: 'media must open paused, not autoplay');
        expect(viewer.playback.player.state.playing, isFalse);

        await _poll(() => host.room.peek() != null, 'host room state');
        host.toggleReady();
        await Future.delayed(const Duration(seconds: 5));
        expect(host.room.peek()?.transport, 'held',
            reason: 'one Space with company present must not solo-play');
        expect(host.playback.player.state.playing, isFalse);
        expect(viewer.playback.player.state.playing, isFalse);

        viewer.toggleReady();
        await _poll(
          () =>
              host.room.peek()?.transport == 'playing' &&
              viewer.playback.player.state.playing &&
              host.playback.player.state.playing,
          'both players playing once quorum readies',
        );
      } finally {
        await host.dispose();
        await viewer.dispose();
        await server.stop();
      }
    },
  );
}
