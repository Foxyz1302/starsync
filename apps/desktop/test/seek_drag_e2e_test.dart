import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/sync/state_diff.dart';

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

/// 120 s, keyframe every second (seeks land fast). Needs an audio track:
/// without a video output attached (headless) mpv refuses a video-only file.
Future<String> _media() async {
  final path = '$_tmp/seek_drag_120s.mp4';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '120', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24',
    '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

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
    'seek bar drag: one seek to the release point, no yank back',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      MediaKit.ensureInitialized();
      final media = await _media();
      final server = SyncServer(AppConfig(
          port: 0, secret: 'drag', name: 'drag', mediaPath: media));
      await server.start();
      final c = SessionCoordinator();
      try {
        await c.connect(ConnectParams(
            host: '127.0.0.1',
            port: server.boundPort,
            secret: 'drag',
            name: 'solo'));
        await c.playback.player.setVolume(0);
        await _poll(() => c.serverState.peek() != null, 'server state');
        c.toggleReady();
        await _poll(
            () => c.playback.player.state.playing && c.playback.positionSecs > 1,
            'solo playback');

        // What media_kit's MaterialDesktopSeekBar does: player.seek on every
        // pointer move (here 2.5 s of dragging from 20 s to 80 s), then once
        // more on release.
        final positions = <double>[];
        final sampler = Timer.periodic(const Duration(milliseconds: 100),
            (_) => positions.add(c.playback.positionSecs));
        const moves = 130; // ~4 s of dragging
        for (var i = 0; i <= moves; i++) {
          final at = 20 + 60 * i / moves;
          unawaited(c.playback.player.seek(Duration(milliseconds: (at * 1000).round())));
          await Future.delayed(const Duration(milliseconds: 30));
        }
        await c.playback.player.seek(const Duration(seconds: 80));
        final releasedAt = positions.length;
        await Future.delayed(const Duration(seconds: 5));
        sampler.cancel();

        final seeks = c.feedLog.peek().where((f) => f.action == 'seek').length;
        final r = c.serverState.peek()!;
        final serverPos = serverPositionAt(r, DateTime.now().toUtc());
        final during = positions.sublist(0, releasedAt);
        final after = positions.sublist(releasedAt);
        // ignore: avoid_print
        print('seek feeds=$seeks server=${serverPos.toStringAsFixed(2)} '
            'local=${c.playback.positionSecs.toStringAsFixed(2)} '
            'during=${during.map((p) => p.toStringAsFixed(1)).join(' ')} '
            'after release=${after.map((p) => p.toStringAsFixed(1)).join(' ')}');
        for (var i = 1; i < during.length; i++) {
          expect(during[i], greaterThan(during[i - 1] - 2),
              reason: 'drag never yanked backwards (sample $i)');
        }
        expect(seeks, 1, reason: 'one seek per drag, sent on release');
        expect(serverPos, inInclusiveRange(80, 87),
            reason: 'server follows the release point');
        expect((c.playback.positionSecs - serverPos).abs(), lessThan(1.0));
        for (final p in after) {
          expect(p, greaterThanOrEqualTo(79), reason: 'no yank back after release');
        }
      } finally {
        await c.dispose();
        await server.stop();
      }
    },
  );

  test(
    'drag on one client: the other follows with exactly one seek',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      MediaKit.ensureInitialized();
      final media = await _media();
      final server = SyncServer(AppConfig(
          port: 0, secret: 'drag2', name: 'drag2', mediaPath: media));
      await server.start();
      final a = SessionCoordinator();
      final b = SessionCoordinator();
      try {
        for (final (c, name) in [(a, 'a'), (b, 'b')]) {
          await c.connect(ConnectParams(
              host: '127.0.0.1',
              port: server.boundPort,
              secret: 'drag2',
              name: name));
          await c.playback.player.setVolume(0);
        }
        await _poll(() => a.serverState.peek()?.members.length == 2, 'both in');
        a.toggleReady();
        b.toggleReady();
        await _poll(
            () => a.playback.player.state.playing && b.playback.player.state.playing,
            'both playing');
        final bSamples = <double>[];
        final sampler = Timer.periodic(const Duration(milliseconds: 100),
            (_) => bSamples.add(b.playback.positionSecs));
        for (var i = 0; i <= 100; i++) {
          unawaited(a.playback.player
              .seek(Duration(milliseconds: (30000 + 400 * i))));
          await Future.delayed(const Duration(milliseconds: 30));
        }
        await a.playback.player.seek(const Duration(seconds: 70));
        await Future.delayed(const Duration(seconds: 4));
        sampler.cancel();
        final seeks = b.feedLog.peek().where((f) => f.action == 'seek').length;
        // ignore: avoid_print
        print('b saw $seeks seek(s); a=${a.playback.positionSecs.toStringAsFixed(2)} '
            'b=${b.playback.positionSecs.toStringAsFixed(2)}');
        expect(seeks, 1);
        expect(b.playback.positionSecs, greaterThan(70));
        expect((a.playback.positionSecs - b.playback.positionSecs).abs(),
            lessThan(1.0));
        expect(bSamples.where((p) => p > 31 && p < 69), isEmpty,
            reason: 'b never jumps to mid-drag positions');
      } finally {
        await a.dispose();
        await b.dispose();
        await server.stop();
      }
    },
  );
}
