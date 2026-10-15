import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/platform/desktop/media_kit_host.dart';
import 'package:starsync/src/session/media_pipeline.dart';

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

/// 240 s at a constant 8 Mbit/s: the bitrate of a 1.4 GB / 24 min episode.
Future<String> _media() async {
  final path = '$_tmp/readahead_240s.mp4';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '240', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '48',
    '-b:v', '8M', '-minrate', '8M', '-maxrate', '8M', '-bufsize', '4M',
    '-x264-params', 'nal-hrd=cbr', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
    '-movflags', '+faststart', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

void main() {
  test('pins read back as set', () {
    expect(pinMatches('150', '150.000000'), isTrue);
    expect(pinMatches('268435456', '268435456'), isTrue);
    expect(pinMatches('150', '10.000000'), isFalse);
    expect(pinMatches('a=1,b=2', 'a=1,b=2'), isTrue);
  });

  test(
    'read-ahead grows far past 10 s from the server media endpoint',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      MediaKit.ensureInitialized();
      final media = await _media();
      final server = SyncServer(AppConfig(
          port: 0, secret: '', name: 'readahead', mediaPath: media));
      await server.start();
      final host = MediaKitHost();
      final m = MediaPipeline(host: host);
      final p = m.playback;
      try {
        await m.start();
        expect(host.pinMismatches, isEmpty,
            reason: 'every pinned mpv property took effect');
        final token = server.session.issueToken('probe', '');
        await m.open(
            'http://127.0.0.1:${server.boundPort}/m/default/$token/readahead.mp4');
        var best = 0.0;
        final end = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(end) && best < 120) {
          await Future.delayed(const Duration(milliseconds: 500));
          best = p.bufferedSecsAhead;
        }
        // ignore: avoid_print
        print('buffered ahead: ${best.toStringAsFixed(1)} s, '
            'served ${server.session.totalBytesServed >> 20} MiB');
        expect(best, greaterThan(120),
            reason: 'paused player reads ahead about two minutes');
      } finally {
        await m.dispose();
        await server.stop();
      }
    },
  );
}
