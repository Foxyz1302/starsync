import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:starsync/src/playback/playback_controller.dart';

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;
const _referer = 'https://www.bilibili.com/';

/// Separate video-only and audio-only files, like Bilibili's DASH .m4s.
Future<(String, String)> _media() async {
  final v = '$_tmp/ytdl_headers_v.mp4', a = '$_tmp/ytdl_headers_a.m4a';
  for (final (path, args) in [
    (v, ['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-c:v', 'libx264', '-preset', 'ultrafast']),
    (a, ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-c:a', 'aac']),
  ]) {
    if (await File(path).exists()) continue;
    final r = await Process.run('ffmpeg', ['-y', '-v', 'error', ...args, '-t', '30', path]);
    if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  }
  return (v, a);
}

/// A CDN like Bilibili's: 403 without the page's Referer.
class _Cdn {
  _Cdn(this._server, this._files) {
    _server.listen(_serve);
  }
  final HttpServer _server;
  final Map<String, String> _files;
  int ok = 0, forbidden = 0;

  String url(String name) => 'http://127.0.0.1:${_server.port}/$name';

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    final file = _files[req.uri.pathSegments.lastOrNull];
    if (file == null || req.headers.value('referer') != _referer) {
      forbidden++;
      res.statusCode = HttpStatus.forbidden;
      await res.close();
      return;
    }
    ok++;
    final bytes = await File(file).readAsBytes();
    var start = 0, end = bytes.length - 1;
    final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(req.headers.value('range') ?? '');
    res.headers.set('accept-ranges', 'bytes');
    if (range != null) {
      start = int.tryParse(range[1]!) ?? 0;
      end = int.tryParse(range[2]!) ?? end;
      res.statusCode = HttpStatus.partialContent;
      res.headers.set('content-range', 'bytes $start-$end/${bytes.length}');
    }
    res.contentLength = end - start + 1;
    res.add(bytes.sublist(start, end + 1));
    await res.close();
  }
}

/// A stand-in yt-dlp printing what yt-dlp gives for a split-track page:
/// `requested_formats` with per-format `http_headers`, none at the top.
Future<String> _fakeYtDlp(_Cdn cdn, {required bool headers}) async {
  final dir = await Directory('$_tmp/ytdl_headers_fake').create(recursive: true);
  final h = headers ? {'Referer': _referer, 'User-Agent': 'fake-agent'} : <String, String>{};
  final json = jsonEncode({
    'id': 'BV1', 'title': 'Fake page', 'duration': 30, 'extractor': 'fake',
    'format_id': 'v+a', 'ext': 'mp4',
    'requested_formats': [
      {'format_id': 'v', 'url': cdn.url('v.m4s'), 'protocol': 'https', 'ext': 'mp4',
        'vcodec': 'avc1.64001F', 'acodec': 'none', 'width': 320, 'height': 180, 'http_headers': h},
      {'format_id': 'a', 'url': cdn.url('a.m4s'), 'protocol': 'https', 'ext': 'm4a',
        'vcodec': 'none', 'acodec': 'mp4a.40.2', 'http_headers': h},
    ],
  });
  final f = File('${dir.path}/yt-dlp-${headers ? 'h' : 'n'}');
  await f.writeAsString("#!/bin/sh\ncat <<'EOF'\n$json\nEOF\n");
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

void main() {
  late _Cdn cdn;
  late HttpServer server;

  setUpAll(() async {
    MediaKit.ensureInitialized();
    final (v, a) = await _media();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    cdn = _Cdn(server, {'v.m4s': v, 'a.m4s': a});
  });
  tearDownAll(() => server.close(force: true));

  test(
    "mpv's yt-dlp hook sends each format's Referer to the CDN",
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      final p = PlaybackController();
      try {
        await p.init();
        expect(p.pinMismatches, isEmpty, reason: 'stream-lavf-o and the rest took effect');
        await p.useYtDlp(await _fakeYtDlp(cdn, headers: true));
        await p.openUrl('https://www.bilibili.com/video/BV1fake');
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(end) && p.duration.peek() == Duration.zero) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        expect(p.duration.peek(), greaterThan(Duration.zero), reason: 'both tracks opened');
        expect(cdn.forbidden, 0, reason: 'every request had the Referer');
        expect(cdn.ok, greaterThanOrEqualTo(2));
      } finally {
        await p.dispose();
      }
    },
    skip: Platform.isLinux ? false : 'fake yt-dlp is a shell script',
  );

  test(
    'a 403 is a load error, not a reconnect loop',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      final p = PlaybackController();
      final errors = <String>[];
      p.onLoadError = errors.add;
      try {
        await p.init();
        var logs = 0;
        final sub = p.player.stream.log.listen((_) => logs++);
        await p.useYtDlp(await _fakeYtDlp(cdn, headers: false));
        final before = cdn.forbidden;
        await p.openUrl('https://www.bilibili.com/video/BV2fake');
        await Future.delayed(const Duration(seconds: 8));
        await sub.cancel();
        // ignore: avoid_print
        print('403s: ${cdn.forbidden - before}, log lines: $logs, errors: $errors');
        expect(cdn.forbidden - before, lessThan(10), reason: 'no retry loop on 403');
        expect(errors, hasLength(1));
        // The status only when ffmpeg logs through this mpv (see _onLog).
        expect(errors.single, anyOf(contains('403'), contains('could not be opened')));
        expect(logs, lessThan(30), reason: 'warnings and errors only');
      } finally {
        await p.dispose();
      }
    },
    skip: Platform.isLinux ? false : 'fake yt-dlp is a shell script',
  );
}
