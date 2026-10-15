import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/platform/desktop/media_kit_host.dart';
import 'package:starsync/src/playback/yt_dlp_app.dart';
import 'package:starsync/src/session/media_pipeline.dart';

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

/// A CDN like Bilibili's: 403 without the page's Referer. `/video/...` is
/// the page itself (HTML: the app's probe sends it to yt-dlp).
class _Cdn {
  _Cdn(this._server, this._files) {
    _server.listen(_serve);
  }
  final HttpServer _server;
  final Map<String, String> _files;
  int ok = 0, forbidden = 0;
  final cookies = <String?>[];

  String url(String name) => 'http://127.0.0.1:${_server.port}/$name';

  String page(String id) => 'http://127.0.0.1:${_server.port}/video/$id';
  int subtitles = 0;

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    if (req.uri.pathSegments.firstOrNull == 'video') {
      res.headers.contentType = ContentType.html;
      res.write('<html><title>Fake page</title></html>');
      await res.close();
      return;
    }
    if (req.uri.pathSegments.lastOrNull == 'en.vtt') {
      subtitles++;
      res.write('WEBVTT\n\n00:00.000 --> 00:05.000\nHello\n');
      await res.close();
      return;
    }
    final file = _files[req.uri.pathSegments.lastOrNull];
    if (file == null || req.headers.value('referer') != _referer) {
      forbidden++;
      res.statusCode = HttpStatus.forbidden;
      await res.close();
      return;
    }
    ok++;
    cookies.add(req.headers.value('cookie'));
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

/// A stand-in yt-dlp (the managed copy in its own folder) printing what
/// yt-dlp gives for a split-track page: `requested_formats` with
/// per-format `http_headers` and `cookies`, subtitles with Bilibili's
/// danmaku among them. [fail]: it finds no formats instead.
Future<AppYtDlp> _fakeYtDlp(_Cdn cdn, {required bool headers, bool fail = false}) async {
  final dir = Directory('$_tmp/ytdl_direct_${headers ? 'h' : 'n'}${fail ? 'f' : ''}');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final h = headers ? {'Referer': _referer, 'User-Agent': 'fake-agent'} : <String, String>{};
  final json = jsonEncode({
    'id': 'BV1', 'title': 'Fake page', 'duration': 30, 'extractor': 'fake',
    'format_id': 'v+a', 'ext': 'mp4',
    'requested_formats': [
      {'format_id': 'v', 'url': cdn.url('v.m4s'), 'protocol': 'https', 'ext': 'mp4',
        'vcodec': 'avc1.64001F', 'acodec': 'none', 'width': 320, 'height': 180, 'http_headers': h,
        'cookies': 'SESSDATA=abc; Domain=.127.0.0.1; Path=/'},
      {'format_id': 'a', 'url': cdn.url('a.m4s'), 'protocol': 'https', 'ext': 'm4a',
        'vcodec': 'none', 'acodec': 'mp4a.40.2', 'http_headers': h},
    ],
    'requested_subtitles': {
      'en': {'url': cdn.url('en.vtt'), 'ext': 'vtt', 'name': 'English'},
      'danmaku': {'url': cdn.url('danmaku.xml'), 'ext': 'xml'},
    },
  });
  final f = File('${dir.path}/yt-dlp');
  await f.writeAsString('#!/bin/sh\n'
      'case "\$1" in --version) echo 2099.01.01; exit 0;; esac\n'
      '${fail ? 'echo "ERROR: [fake] BV1: No video formats found!" >&2; exit 1\n' : "cat <<'EOF'\n$json\nEOF\n"}');
  await Process.run('chmod', ['+x', f.path]);
  await File('${dir.path}/last-check').writeAsString(DateTime.now().toIso8601String());
  return AppYtDlp(YtDlp(dir.path, updateEvery: const Duration(days: 9999)));
}

void main() {
  late _Cdn cdn;
  late HttpServer server;

  setUpAll(() async {
    final (v, a) = await _media();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    cdn = _Cdn(server, {'v.m4s': v, 'a.m4s': a});
  });
  tearDownAll(() => server.close(force: true));

  // A page "everyone fetches" opens through the app's own resolve: its
  // stream URLs (an EDL of video + audio) with the CDN's headers; mpv's
  // yt-dlp hook is off.
  test(
    "a page plays from yt-dlp's stream URLs with each CDN's Referer and the cookies; subtitles but danmaku",
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      final host = MediaKitHost()..init();
      final m = MediaPipeline(host: host, links: await _fakeYtDlp(cdn, headers: true));
      final p = m.playback;
      try {
        await m.start();
        expect(host.pinMismatches, isEmpty, reason: 'stream-lavf-o, ytdl=no and the rest took effect');
        expect(await p.player.getProperty('ytdl'), 'no');
        expect(await m.open(cdn.page('BV1fake')), isTrue);
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(end) && (p.duration.peek() == Duration.zero || cdn.subtitles == 0)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        expect(p.duration.peek(), greaterThan(Duration.zero), reason: 'both tracks opened');
        expect(cdn.forbidden, 0, reason: 'every request had the Referer');
        expect(cdn.ok, greaterThanOrEqualTo(2));
        expect(cdn.cookies, everyElement('SESSDATA=abc'));
        expect(cdn.subtitles, 1, reason: 'the page\'s subtitles are added, danmaku is not');
        await _until(() => p.tracks.peek().any((t) => t.isExternal), 'the subtitle track listed');
      } finally {
        await m.dispose();
      }
    },
    skip: Platform.isLinux ? false : 'fake yt-dlp is a shell script',
  );

  test(
    'a 403 is a load error, not a reconnect loop',
    timeout: const Timeout(Duration(minutes: 1)),
    () async {
      final m = MediaPipeline(host: MediaKitHost()..init(), links: await _fakeYtDlp(cdn, headers: false));
      final p = m.playback;
      final errors = <String>[];
      p.onLoadError = errors.add;
      try {
        await m.start();
        var logs = 0;
        final sub = p.player.logs.listen((_) => logs++);
        final before = cdn.forbidden;
        await m.open(cdn.page('BV2fake'));
        await Future.delayed(const Duration(seconds: 8));
        await sub.cancel();
        // ignore: avoid_print
        print('403s: ${cdn.forbidden - before}, log lines: $logs, errors: $errors');
        expect(cdn.forbidden - before, lessThan(10), reason: 'no retry loop on 403');
        expect(errors, hasLength(1));
        // The status only when ffmpeg logs through this mpv (see the host).
        expect(errors.single, anyOf(contains('403'), contains('could not be opened')));
        expect(logs, lessThan(30), reason: 'warnings and errors only');
      } finally {
        await m.dispose();
      }
    },
    skip: Platform.isLinux ? false : 'fake yt-dlp is a shell script',
  );

  // D11: yt-dlp finds no video; the error names the cookies it used.
  test('a page yt-dlp finds no video on: the error says which cookies were used', () async {
    final m = MediaPipeline(host: MediaKitHost()..init(), links: await _fakeYtDlp(cdn, headers: true, fail: true));
    final got = <(String, String?)>[];
    m.onError = (raw, {cookies}) => got.add((raw, cookies));
    try {
      await m.start();
      expect(await m.open(cdn.page('BV3fake')), isFalse);
      expect(got.single.$1, contains('No video formats found'));
      expect(got.single.$2, 'no cookies were used');
      expect(withCookieNote(playErrorText(got.single.$1), got.single.$2),
          'No video found: it may need signing in (no cookies were used)');
    } finally {
      await m.dispose();
    }
  }, skip: Platform.isLinux ? false : 'fake yt-dlp is a shell script');
}

Future<void> _until(bool Function() cond, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future.delayed(const Duration(milliseconds: 100));
  }
}
