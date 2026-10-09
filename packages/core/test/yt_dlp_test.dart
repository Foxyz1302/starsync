// yt-dlp output parsing, the single-file pick and the link classifier.
// The live test (real download from GitHub, a real tweet) runs only with
// YTDLP_LIVE=1.
library;

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

Map<String, Object?> _f(String id, String protocol, Object? vcodec, Object? acodec, int? height,
        {String ext = 'mp4', num tbr = 0}) =>
    {
      'format_id': id, 'protocol': protocol, 'vcodec': vcodec, 'acodec': acodec, 'height': height, //
      'ext': ext, 'tbr': tbr, 'url': 'https://cdn.example/$id', 'http_headers': {'User-Agent': 'UA'},
    };

void main() {
  group('single-file pick', () {
    test('a tweet: the tallest progressive mp4 (codecs unknown), not the split HLS', () {
      final f = pickSingleFile([
        _f('hls-audio', 'm3u8_native', 'none', null, null),
        _f('http-256', 'https', null, null, 270, tbr: 256),
        _f('http-2176', 'https', null, null, 598, tbr: 2176),
        _f('http-832', 'https', null, null, 360, tbr: 832),
        _f('hls-430', 'm3u8_native', 'avc1', 'none', 598),
      ])!;
      expect((f.id, f.height), ('http-2176', 598));
      expect(f.headers, {'User-Agent': 'UA'});
    });

    test('split or HLS only: none', () {
      expect(
          pickSingleFile([
            _f('140', 'https', 'none', 'mp4a', null, ext: 'm4a'),
            _f('137', 'https', 'avc1', 'none', 1080),
            _f('96', 'm3u8_native', 'avc1', 'mp4a', 1080),
          ]),
          isNull);
    });

    test('up to 1080p, else the shortest above; mp4/webm win ties', () {
      expect(
          pickSingleFile([
            _f('4k', 'https', 'vp9', 'opus', 2160, ext: 'webm'),
            _f('720', 'https', 'avc1', 'mp4a', 720),
            _f('1080mkv', 'https', 'avc1', 'mp4a', 1080, ext: 'mkv'),
            _f('1080', 'https', 'avc1', 'mp4a', 1080),
          ])!.id,
          '1080');
      expect(
          pickSingleFile([
            _f('4k', 'https', 'vp9', 'opus', 2160, ext: 'webm'),
            _f('1440', 'https', 'vp9', 'opus', 1440, ext: 'webm'),
          ])!.id,
          '1440');
    });

    test('info: metadata, a playlist answer uses its first entry', () {
      final info = YtDlpInfo.parse({
        '_type': 'playlist',
        'entries': [
          {
            'title': 'a girl. - https://t.co/x', 'uploader': 'a girl.', 'duration': 6.3, //
            'thumbnail': 'https://pbs/x.jpg', 'extractor_key': 'Twitter',
            'formats': [_f('http-2176', 'https', null, null, 598)],
          },
        ],
      });
      expect((info.title, info.uploader, info.duration, info.thumbnail, info.extractor, info.single?.id),
          ('a girl. - https://t.co/x', 'a girl.', 6.3, 'https://pbs/x.jpg', 'Twitter', 'http-2176'));
    });
  });

  test('link classifier: media types and media file names are files; pages, HLS, errors are not', () {
    bool file(int status, String type, String url) =>
        looksLikeMediaFile(status: status, contentType: type, url: Uri.parse(url));
    expect(file(206, 'video/mp4', 'https://a/watch'), isTrue);
    expect(file(200, 'audio/mpeg', 'https://a/x'), isTrue);
    expect(file(206, 'application/octet-stream', 'https://a/dir/ep%201.MKV?sig=1'), isTrue);
    expect(file(206, 'application/octet-stream', 'https://a/download'), isFalse);
    expect(file(200, 'text/html', 'https://x.com/u/status/1/video/1'), isFalse);
    expect(file(200, 'text/html', 'https://a/fake.mp4'), isFalse);
    expect(file(200, 'application/vnd.apple.mpegurl', 'https://a/index.m3u8'), isFalse);
    expect(file(403, 'video/mp4', 'https://a/x.mp4'), isFalse);
  });

  test('a page title in a /r/ URL stays one path segment', () {
    expect(relayUrlName('a girl. - https://t.co/x'), 'a%20girl.%20-%20https%3A__t.co_x');
  });

  test('page title: og:title first (any attribute order), else <title>, entities decoded', () {
    expect(htmlTitle('<title>Plain</title><meta content="Tom &amp; Jerry &#39;24" property="og:title">'),
        "Tom & Jerry '24");
    expect(htmlTitle("<head><TITLE>\n  A  &quot;page&quot;\n</TITLE></head>"), 'A "page"');
    expect(htmlTitle('<p>nothing</p>'), isNull);
  });

  test('release files: checksums, asset per platform, error text', () {
    final sums = parseSha256Sums('${'a' * 64}  yt-dlp\n${'B' * 64}  yt-dlp.exe\ngarbage\n');
    expect(sums, {'yt-dlp': 'a' * 64, 'yt-dlp.exe': 'b' * 64});
    expect(ytDlpAssetName(Abi.linuxX64), 'yt-dlp_linux');
    expect(ytDlpAssetName(Abi.linuxArm64, musl: true), 'yt-dlp_musllinux_aarch64');
    expect(ytDlpAssetName(Abi.windowsX64), 'yt-dlp.exe');
    expect(ytDlpAssetName(Abi.androidArm), isNull);
    expect(ytDlpErrorText('WARNING: x\nERROR: [twitter] 123: No video could be found in this tweet\n'),
        'No video could be found in this tweet');
    expect(ytDlpErrorText('ERROR: Unsupported URL: https://example.com/'), 'Unsupported URL: https://example.com/');
  });

  test('live: download yt-dlp, resolve a tweet, relay its single file', () async {
    final dir = await Directory.systemTemp.createTemp('ytdlp_live');
    addTearDown(() => dir.delete(recursive: true));
    final y = YtDlp(dir.path);
    expect(await y.ensure(), y.managedPath, reason: '${y.lastError}');
    expect(y.version, isNotNull);
    final url = Uri.parse('https://x.com/velcrotea/status/2108421180701188522/video/1');
    final probe = await probeLink(url, ytDlp: y);
    expect(probe.isPage, isTrue);
    expect(probe.title, startsWith('a girl.'));
    expect(probe.relayProblem, isNull);
    final bytes = LinkRelayBytes(url, ytDlp: y, probe: probe);
    final size = await bytes.size();
    var n = 0;
    await for (final c in bytes.read(0, size - 1)) {
      n += c.length;
    }
    await bytes.close();
    expect(n, size);
  }, timeout: const Timeout(Duration(minutes: 3)), skip: Platform.environment['YTDLP_LIVE'] == '1' ? false : 'YTDLP_LIVE not set');
}
