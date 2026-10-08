import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:watch_together/src/files/thumbnails.dart';

// Real libmpv: frames grabbed with vo=null + screenshot-to-file. The test
// media comes from ffmpeg (this machine only; the app never needs it).

late Directory _tmp;

/// 8 s, 640x360: red until 1.5 s, green until 4 s, then blue; a keyframe
/// every 0.5 s, so the 25% frame (2 s) is green.
Future<String> _media(String name) async {
  final path = '${_tmp.path}/$name';
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'color=c=red:size=640x360:rate=24:duration=1.5',
    '-f', 'lavfi', '-i', 'color=c=green:size=640x360:rate=24:duration=2.5',
    '-f', 'lavfi', '-i', 'color=c=blue:size=640x360:rate=24:duration=4',
    '-filter_complex', '[0][1][2]concat=n=3:v=1:a=0',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '12', '-pix_fmt', 'yuv420p',
    path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

void main() {
  setUpAll(() {
    MediaKit.ensureInitialized();
    _tmp = Directory.systemTemp.createTempSync('files_thumbs_');
    thumbnailCacheRoot = () async => Directory('${_tmp.path}/cache');
  });
  tearDownAll(() => _tmp.deleteSync(recursive: true));

  test('a JPEG of the 25% frame plus the duration, then from the cache',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final path = await _media('a.mkv');
    final sw = Stopwatch()..start();
    final t = await thumbnailFor(path);
    final first = sw.elapsedMilliseconds;
    expect(t, isNotNull);
    expect(t!.duration.inMilliseconds, closeTo(8000, 100));
    final bytes = File(t.imagePath).readAsBytesSync();
    expect(bytes.sublist(0, 2), [0xFF, 0xD8]); // JPEG
    final image = img.decodeJpg(bytes)!;
    expect(image.width, thumbnailWidth);
    expect(image.height, 270);
    final px = image.getPixel(image.width ~/ 2, image.height ~/ 2);
    expect(px.g, greaterThan(100), reason: 'green frame, got $px');
    expect(px.r, lessThan(60));
    expect(px.b, lessThan(60));

    sw.reset();
    final again = await thumbnailFor(path);
    final cachedMs = sw.elapsedMilliseconds;
    expect(again?.imagePath, t.imagePath);
    expect(again?.duration, t.duration);
    // ignore: avoid_print
    print('thumbnail: first $first ms, cached $cachedMs ms');
    expect(cachedMs, lessThan(first));
  });

  test('several at once (2 at a time), same file deduplicated',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final paths = [for (var i = 0; i < 4; i++) await _media('m$i.mp4')];
    final sw = Stopwatch()..start();
    final results = await Future.wait([
      for (final p in paths) thumbnailFor(p),
      thumbnailFor(paths.first),
    ]);
    // ignore: avoid_print
    print('4 thumbnails in ${sw.elapsedMilliseconds} ms');
    expect(results.every((t) => t != null), isTrue);
    expect(results.first!.imagePath, results.last!.imagePath);
  });

  test('not a video, missing, cancelled: null, never a throw',
      timeout: const Timeout(Duration(minutes: 1)), () async {
    final text = File('${_tmp.path}/notes.mkv')..writeAsStringSync('hello');
    expect(await thumbnailFor(text.path), isNull);
    // The failure is remembered: the second answer comes from the cache.
    final sw = Stopwatch()..start();
    expect(await thumbnailFor(text.path), isNull);
    expect(sw.elapsedMilliseconds, lessThan(500));

    expect(await thumbnailFor('${_tmp.path}/missing.mkv'), isNull);

    final path = await _media('c.mkv');
    expect(await thumbnailFor(path, cancelled: () => true), isNull);
    // A cancellation is not a remembered failure.
    expect(await thumbnailFor(path), isNotNull);
  });
}
