import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The length of [testClip], in seconds.
const testClipSecs = 13.8;

/// A short clip for the real-mpv tests (`sync_playback_e2e`,
/// `video_reload_e2e`, `end_of_file_e2e`): [testClipSecs] of a test
/// picture and a tone (headless mpv won't open a video-only file), a
/// keyframe every second, index first. Made once with ffmpeg in
/// `WT_TEST_TMP` (default: the system temp) and kept there.
Future<String> testClip() async {
  final tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;
  final path = '$tmp/starsync_test_clip.mp4';
  if (await File(path).exists()) return path;
  // Written under its own name, then moved: test files run in parallel.
  final part = '$tmp/starsync_test_clip.$pid.mp4';
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '$testClipSecs', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24',
    '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', part,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  await File(part).rename(path);
  return path;
}
