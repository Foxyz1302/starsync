import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../app/app_graph.dart';
import 'app_shutdown.dart';
import 'ports/player_host.dart';

// The close smoke run (CI, `tool/smoke_windows.ps1` / `tool/smoke_linux.sh`):
// env `STARSYNC_SMOKE=<media file>` makes the app, once up, open that file
// in a session player with a video output through the media pipeline,
// play a second and close the normal way ([shutDownApp]). Progress goes to
// `STARSYNC_SMOKE_OUT` (one line per step: `start`, `opened <ms> render=<mode>`,
// `closing`, or `skip <why>` / `fail <why>`), so the script can tell a
// runner that cannot show a window (skip) from a close that hangs or
// leaves a process behind (fail).

/// The smoke run's media, or null for a normal start.
String? get smokeMedia {
  final m = Platform.environment['STARSYNC_SMOKE'];
  return m == null || m.isEmpty ? null : m;
}

Future<void> runSmoke(AppGraph graph, String media) async {
  final outPath = Platform.environment['STARSYNC_SMOKE_OUT'];
  void step(String line) {
    debugPrint('smoke: $line'); // into the app log too
    if (outPath == null || outPath.isEmpty) return;
    try {
      File(outPath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  step('start');
  final sw = Stopwatch()..start();
  final pipe = graph.coordinator.media;
  try {
    if (!await File(media).exists()) {
      step('fail no media file at $media');
    } else {
      await pipe.start();
      await pipe.playback.setVolume(0);
      // The video output the session view would make: the render path
      // (EGL / ANGLE) is what breaks on some machines.
      final video = pipe.playback.video;
      await video.ready.timeout(const Duration(seconds: 15));
      final ok = await pipe.open(media);
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (ok && pipe.playback.durationSecs <= 0 && DateTime.now().isBefore(end)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (pipe.playback.durationSecs <= 0) {
        step('fail the media did not open in 20 s');
      } else {
        await pipe.playback.player.play();
        await Future.delayed(const Duration(seconds: 1));
        final mode = graph.ports.players.renderMode.peek();
        step('opened ${sw.elapsedMilliseconds} render=${mode.name}');
        if (mode == RenderMode.unknown) await Future.delayed(const Duration(seconds: 2));
      }
    }
  } on TimeoutException {
    step('skip the video output did not come up (no display for this runner?)');
  } catch (e) {
    step('fail $e');
  }
  step('closing');
  await shutDownApp();
}
