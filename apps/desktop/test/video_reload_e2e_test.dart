import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/platform/desktop/media_kit_host.dart';
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/sync/state_diff.dart';

// "Reload video" through the media pipeline: a fresh player from the
// host, the old one retired, the same media opened again and resynced,
// the ready flag untouched; leaving releases every player the host made.

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
    'reload video: a fresh player from the host, same media, resynced, ready untouched; '
    'leave releases every player',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final server = SyncServer(const AppConfig(port: 0, secret: 'reload', name: 'reload', mediaPath: _mediaPath));
      await server.start();
      final host = MediaKitHost()..init();
      final c = SessionCoordinator(players: host);
      try {
        await c.connect(ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: 'reload', name: 'solo'));
        await c.playback.setVolume(0);
        await _poll(() => c.serverState.peek() != null, 'server state');
        c.play();
        await _poll(() => c.playback.playing && c.playback.positionSecs > 2, 'solo playback past 2 s');
        final opens = c.opens;

        final old = c.playback.player;
        final gen = c.playback.generation.peek();
        await c.reloadVideo();
        expect(identical(c.playback.player, old), isFalse, reason: 'a fresh player');
        expect(old.disposed, isTrue, reason: 'the old one retired');
        expect(host.live, 1, reason: 'only the new one is alive');
        expect(c.playback.generation.peek(), gen + 1);
        expect(c.opens, opens + 1, reason: 'the same media opened again');
        expect(c.playback.volume.peek(), 0, reason: 'the volume carried over');
        expect(c.serverState.peek()?.wantsPlay, isTrue);

        await _poll(() {
          final r = c.serverState.peek();
          if (r == null || !c.playback.playing) return false;
          final want = serverPositionAt(r, DateTime.now().toUtc());
          return (c.playback.positionSecs - want).abs() < 1.5 && c.playback.positionSecs > 2;
        }, 'reloaded player playing at the synced position');
        expect(c.serverState.peek()?.transport, 'playing');

        await c.leave();
        expect(c.playback.alive.peek(), isFalse);
        await host.retiring;
        expect(host.live, 0, reason: 'leaving releases every player');
      } finally {
        await c.dispose();
        await server.stop();
      }
    },
  );
}
