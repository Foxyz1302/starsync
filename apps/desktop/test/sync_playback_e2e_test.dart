import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/session/session_coordinator.dart';

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
    await c.playback.player.setProperty('loop-file', 'inf');
  } catch (_) {}
}

void main() {
  test(
    'two app coordinators: one Play for everyone, a pause, a BRB, over a real server',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      MediaKit.ensureInitialized();
      final server = SyncServer(const AppConfig(
        port: _port,
        secret: _secret,
        name: 'server',
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

        await _poll(() => host.serverState.peek() != null, 'host server state');
        // Nothing starts because time passed: the media waits for one Play.
        await Future.delayed(const Duration(seconds: 3));
        expect(host.serverState.peek()?.transport, 'held');
        // One Play is everyone's: both players start once both have it.
        host.play();
        await _poll(
          () =>
              host.serverState.peek()?.transport == 'playing' &&
              viewer.playback.player.state.playing &&
              host.playback.player.state.playing,
          'both players playing on one Play',
        );
        // A pause is anyone's too.
        viewer.pause();
        await _poll(() => !host.playback.player.state.playing && !viewer.playback.player.state.playing,
            'both paused');
        // BRB holds the group; when the viewer is back it plays again (it
        // wanted to when the BRB began).
        viewer.play();
        await _poll(() => host.playback.player.state.playing, 'playing again');
        viewer.brb();
        await _poll(() => !host.playback.player.state.playing, 'held for the BRB');
        expect(host.serverState.peek()?.hold?.brb, [viewer.connection.memberId]);
        viewer.back();
        await _poll(() => host.playback.player.state.playing && viewer.playback.player.state.playing,
            'playing once back');

        // Space, as the keys feed it: a tap pauses (on key-down), a tap plays
        // (on key-up).
        final viewerId = viewer.connection.memberId;
        final hostId = host.connection.memberId;
        void tap(SessionCoordinator c) {
          c.space.keyDown();
          c.space.keyUp();
        }

        Future<void> hold(SessionCoordinator c, Duration d) async {
          c.space.keyDown();
          await Future.delayed(d);
          c.space.tick();
          c.space.keyUp();
        }

        tap(viewer);
        await _poll(() => host.serverState.peek()?.wantsPlay == false && !host.playback.player.state.playing,
            'a tap paused everyone');
        tap(viewer);
        await _poll(() => host.playback.player.state.playing, 'a tap played');
        // A 0.6 s hold: BRB, and it plays again once back (it was playing).
        await hold(viewer, const Duration(milliseconds: 700));
        await _poll(() => host.serverState.peek()?.hold?.brb.contains(viewerId) ?? false, 'BRB by the hold');
        expect(host.serverState.peek()!.wantsPlay, isTrue, reason: 'it plays once the viewer is back');
        expect(host.playback.player.state.playing, isFalse);
        // While the viewer is BRB a tap makes the host BRB too; the viewer's
        // 2 s hold continues without the host: out, the viewer back, playing.
        tap(host);
        await _poll(() => host.serverState.peek()?.hold?.brb.contains(hostId) ?? false, 'BRB too');
        await hold(viewer, const Duration(milliseconds: 2100));
        await _poll(
            () =>
                host.selfOut.peek() &&
                viewer.serverState.peek()?.transport == 'playing' &&
                viewer.playback.player.state.playing,
            'continued without the host');
        expect(host.playback.player.state.playing, isFalse, reason: "out: the host's player stays at its spot");
        // Space while out: in at the current moment.
        tap(host);
        await _poll(() => !host.selfOut.peek() && host.playback.player.state.playing, 'the host joined');
      } finally {
        await host.dispose();
        await viewer.dispose();
        await server.stop();
      }
    },
  );
}
