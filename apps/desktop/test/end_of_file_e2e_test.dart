import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/session/session_coordinator.dart';

import 'test_clip.dart';

Future<void> _poll(
  FutureOr<bool> Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for $what');
}

void main() {
  test(
    'plays through the last 4 s to finished; seek back plays again',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      MediaKit.ensureInitialized();
      final server = SyncServer(AppConfig(
          port: 0, secret: 'eof', name: 'eof', mediaPath: await testClip()));
      await server.start();
      final c = SessionCoordinator();
      try {
        await c.connect(ConnectParams(
            host: '127.0.0.1',
            port: server.boundPort,
            secret: 'eof',
            name: 'solo'));
        await c.playback.player.setVolume(0);
        await _poll(() => c.serverState.peek() != null, 'server state');
        await _poll(
            () => (c.serverState.peek()?.media?['duration'] as num? ?? 0) > 13,
            'server learns the duration from reports');
        c.play();
        await _poll(() => c.playback.player.state.playing, 'playing');
        c.seekTo(7);
        final transports = <String>[];
        await _poll(() {
          transports.add(c.serverState.peek()?.transport ?? '');
          return c.serverState.peek()?.transport == 'finished';
        }, 'finished at the end');
        // ignore: avoid_print
        print('transports: ${transports.toSet()} '
            'end at ${c.playback.positionSecs.toStringAsFixed(2)}');
        expect(transports, isNot(contains('held')),
            reason: 'never held in the last seconds');
        expect(c.serverState.peek()!.position, closeTo(testClipSecs, 0.15));
        await _poll(() => !c.playback.player.state.playing, 'player stopped');
        expect(c.playback.positionSecs, greaterThan(12));
        expect(c.status.peek().line?.kind, StatusKind.finished);

        c.seekTo(2);
        await _poll(
            () =>
                c.serverState.peek()?.transport == 'playing' &&
                c.playback.player.state.playing &&
                c.playback.positionSecs < 6,
            'seek back from finished plays again');
      } finally {
        await c.dispose();
        await server.stop();
      }
    },
  );
}
