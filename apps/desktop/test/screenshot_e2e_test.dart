import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:starsync/src/platform/desktop/media_kit_host.dart';
import 'package:starsync/src/platform/ports/player_host.dart';
import 'package:starsync/src/screenshot/screenshots.dart';

// Real libmpv: the frame decoded again by a hidden player
// ([decodeStillFrame], the fallback when mpv cannot hand over the frame
// on screen), with and without subtitles. Media from ffmpeg into
// WT_TEST_TMP (default: system temp).

late Directory _tmp;

/// 4 s: red until 2 s, then green; silent audio; a subtitle track with a
/// white block at the bottom the whole time. [sar] stretches the pixels
/// (an anamorphic file).
Future<String> _media(String name, {String sar = '1'}) async {
  final ass = File('${_tmp.path}/$name.ass')
    ..writeAsStringSync('''[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Sans,40,&H00FFFFFF,&H000000FF,&H00FFFFFF,&H00FFFFFF,0,0,0,0,100,100,0,0,3,0,0,2,0,0,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\\p1}m 0 0 l 300 0 300 60 0 60{\\p0}
''');
  final path = '${_tmp.path}/$name';
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'color=c=red:size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'color=c=green:size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
    '-i', ass.path,
    '-filter_complex', '[0][1]concat=n=2:v=1:a=0,setsar=$sar[v]',
    '-map', '[v]', '-map', '2:a', '-map', '3',
    '-t', '4', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-c:s', 'ass',
    path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

({int r, int g, int b}) _px(RawFrame f, double fx, double fy) {
  final x = (f.width * fx).floor(), y = (f.height * fy).floor();
  final i = (y * f.width + x) * 4;
  return (r: f.rgba[i], g: f.rgba[i + 1], b: f.rgba[i + 2]);
}

void main() {
  late MediaKitHost host;
  setUpAll(() {
    MediaKit.ensureInitialized();
    final root = Platform.environment['WT_TEST_TMP'];
    _tmp = (root == null ? Directory.systemTemp : Directory(root)).createTempSync('screenshot_e2e_');
    host = MediaKitHost(hwdecSetting: () => 'no');
  });
  tearDownAll(() async {
    await host.disposeAll();
    _tmp.deleteSync(recursive: true);
  });

  test('the frame at a moment, the subtitles drawn in on the second copy',
      timeout: const Timeout(Duration(minutes: 1)), () async {
    final path = await _media('a.mkv');
    final sw = Stopwatch()..start();
    final grab = await decodeStillFrame(host, url: path, at: const Duration(milliseconds: 2500), sid: 1);
    // ignore: avoid_print
    print('still frame in ${sw.elapsedMilliseconds} ms');
    expect(grab, isNotNull);
    final clean = grab!.clean, subs = grab.subs!;
    expect((clean.width, clean.height), (640, 360));
    expect((subs.width, subs.height), (640, 360));
    // 2.5 s: green, not the red before it.
    final mid = _px(clean, 0.5, 0.3);
    expect(mid.g, greaterThan(100), reason: '$mid');
    expect(mid.r, lessThan(60), reason: '$mid');
    // The block at the bottom only with subtitles.
    final bottomClean = _px(clean, 0.5, 0.85), bottomSubs = _px(subs, 0.5, 0.85);
    expect(bottomClean.r, lessThan(60), reason: 'clean $bottomClean');
    expect(bottomSubs.r, greaterThan(200), reason: 'subs $bottomSubs');
    expect(_px(subs, 0.5, 0.3), mid, reason: 'the same frame under the subtitles');
    expect(host.live, 0, reason: 'the hidden player is gone');
  });

  test('without subtitles: one copy; an anamorphic file at its display size',
      timeout: const Timeout(Duration(minutes: 1)), () async {
    final path = await _media('wide.mkv', sar: '2');
    final grab = await decodeStillFrame(host, url: path, at: const Duration(milliseconds: 500));
    expect(grab, isNotNull);
    expect(grab!.subs, isNull);
    expect((grab.clean.width, grab.clean.height), (1280, 360));
    expect(_px(grab.clean, 0.5, 0.5).r, greaterThan(200));
  });

  test('nothing to decode: null, never a throw', timeout: const Timeout(Duration(minutes: 1)), () async {
    expect(await decodeStillFrame(host, url: '${_tmp.path}/missing.mkv', at: Duration.zero), isNull);
    final txt = File('${_tmp.path}/not-video.mkv')..writeAsStringSync('hello');
    expect(await decodeStillFrame(host, url: txt.path, at: Duration.zero), isNull);
  });
}
