// yt-dlp output parsing, the relay track pick, chunked upstream reads and
// the link classifier.
// The live test (real download from GitHub, a real tweet) runs only with
// YTDLP_LIVE=1.
library;

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

Map<String, Object?> _f(String id, String protocol, Object? vcodec, Object? acodec, int? height,
        {String ext = 'mp4', num tbr = 0, Map<String, Object?> extra = const {}}) =>
    {
      'format_id': id, 'protocol': protocol, 'vcodec': vcodec, 'acodec': acodec, 'height': height, //
      'ext': ext, 'tbr': tbr, 'url': 'https://cdn.example/$id', 'http_headers': {'User-Agent': 'UA'}, ...extra,
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
      expect((info.title, info.uploader, info.duration, info.thumbnail, info.extractor, info.tracks.single.format.id),
          ('a girl. - https://t.co/x', 'a girl.', 6.3, 'https://pbs/x.jpg', 'Twitter', 'http-2176'));
    });
  });

  group('relay tracks', () {
    // YouTube now: only video-only and audio-only https files (+ HLS).
    final youtube = [
      _f('139', 'https', 'none', 'mp4a.40.5', null, ext: 'm4a', tbr: 49),
      _f('140', 'https', 'none', 'mp4a.40.2', null, ext: 'm4a', tbr: 129),
      _f('140-drc', 'https', 'none', 'mp4a.40.2', null, ext: 'm4a', tbr: 129),
      _f('251', 'https', 'none', 'opus', null, ext: 'webm', tbr: 135),
      _f('248', 'https', 'vp9', 'none', 1080, ext: 'webm', tbr: 2600),
      _f('137', 'https', 'avc1.640028', 'none', 1080, tbr: 4400),
      _f('299', 'https', 'avc1.64002a', 'none', 1080, tbr: 6000,
          extra: {'downloader_options': {'http_chunk_size': 10485760}}),
      _f('401', 'https', 'av01.0.12M.08', 'none', 2160, tbr: 18000),
      _f('96', 'm3u8_native', 'avc1', 'mp4a', 1080),
    ];

    test('YouTube: the most compact codec up to 1080p (VP9 over h264 here) + m4a audio, with the chunk size', () {
      final t = pickTracks(youtube);
      expect([for (final x in t) (x.kind, x.format.id)], [('video', '248'), ('audio', '140')]);
      expect(YtDlpInfo.parse({'title': 'x', 'formats': youtube}).formats['299']?.chunkSize, 10485760);
      expect(YtDlpInfo.parse({'title': 'x', 'formats': youtube}).formats['137']?.height, 1080);
    });

    test('a single file wins unless the pair is taller; nothing relayable: empty; live: none', () {
      final single = _f('22', 'https', 'avc1', 'mp4a', 720);
      expect(pickTracks([single, ...youtube]).map((x) => x.kind), ['video', 'audio']);
      expect(pickTracks([_f('18', 'https', 'avc1', 'mp4a', 1080), ...youtube]).single.format.id, '18');
      expect(pickTracks([_f('96', 'm3u8_native', 'avc1', 'mp4a', 1080)]).single.format.isPieces, isTrue);
      expect(pickTracks([_f('96', 'rtmp', 'avc1', 'mp4a', 1080)]), isEmpty);
      final live = YtDlpInfo.parse({'title': 'x', 'is_live': true, 'formats': youtube});
      expect(live.isLive, isTrue);
      expect(live.tracks, isEmpty);
      expect(LinkProbe.page(Uri.parse('https://x'), info: live).relayProblem, liveStreamText);
    });

    test('vp9 when there is no avc1; the drc variant only when alone', () {
      final t = pickTracks([youtube[2], youtube[4]]);
      expect([for (final x in t) x.format.id], ['248', '140-drc']);
    });
  });

  test('play errors in plain words; a probe refuses unread pages and 4xx links', () {
    expect(playErrorText('[BiliBili] BV1x: Unable to download webpage: HTTP Error 412: Precondition Failed'),
        needsCookiesText);
    expect(playErrorText('Sign in to confirm your age'), needsCookiesText);
    expect(playErrorText('the video server answered HTTP error 403 Forbidden'), notAllowedText);
    expect(playErrorText('HTTP Error 404: Not Found'), notFoundText);
    expect(playErrorText('Unsupported URL: https://example.com/login/403'), unsupportedUrlText);
    expect(playErrorText('cannot open the link: SocketException: Failed host lookup'), unreachableText);
    expect(playErrorText('the video stream could not be opened'), 'the video stream could not be opened');
    expect(playErrorText(notAllowedText), notAllowedText);
    final u = Uri.parse('https://x/v.mp4');
    expect(LinkProbe.page(u, ytDlpError: 'HTTP Error 412: Precondition Failed').problem, needsCookiesText);
    expect(LinkProbe.page(u, ytDlpError: 'odd failure', status: 403).problem, notAllowedText);
    expect(LinkProbe.page(u, ytDlpError: 'odd failure').problem, 'odd failure');
    expect(LinkProbe.page(u, info: YtDlpInfo.parse({'title': 'x', 'formats': []}), status: 404).problem, isNull);
    expect(LinkProbe.file(u, 10).problem, isNull);
  });

  test('viewer URL: one track plain, several an mpv EDL with %length% framing', () {
    expect(relayViewerUrl('http://h:1/r/default/t/3', 'a/b c'), 'http://h:1/r/default/t/3/a_b%20c');
    const v = 'http://h:1/r/default/t/3/0/x', a = 'http://h:1/r/default/t/3/1/x';
    expect(relayViewerUrl('http://h:1/r/default/t/3', 'x', tracks: const [RelayTrackSpec('video'), RelayTrackSpec('audio')]),
        'edl://!no_clip;%${v.length}%$v;!new_stream;!no_clip;%${a.length}%$a');
    expect(relayViewerUrl('http://h:1/r/default/t/3', 'x', tracks: const [RelayTrackSpec('video', pieces: true)]),
        'http://h:1/r/default/t/3/0/x.m3u8');
    expect(mpvEdl(['http://x/a;b,c']), 'edl://!no_clip;%14%http://x/a;b,c');
  });

  test('upstream reads go in GETs of at most the chunk size, back to back', () async {
    final data = List.generate(2500, (i) => i % 251);
    final seen = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(req.headers.value('range')!)!;
      final s = int.parse(m.group(1)!), e = min(int.parse(m.group(2)!), data.length - 1);
      seen.add('$s-$e');
      req.response
        ..statusCode = 206
        ..headers.set('content-range', 'bytes $s-$e/${data.length}')
        ..add(data.sublist(s, e + 1));
      await req.response.close();
    });
    final b = HttpRelayBytes(Uri.parse('http://127.0.0.1:${server.port}/f.mp4'), chunkSize: 1000);
    addTearDown(b.close);
    expect([for (final c in await b.read(100, 2400).toList()) ...c], data.sublist(100, 2401));
    expect(seen, ['100-1099', '1100-2099', '2100-2400']);
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
    final media = LinkRelayMedia(url, ytDlp: y, probe: probe);
    final bytes = (await media.open()).single.bytes!;
    final size = await bytes.size();
    var n = 0;
    await for (final c in bytes.read(0, size - 1)) {
      n += c.length;
    }
    await media.close();
    expect(n, size);
  }, timeout: const Timeout(Duration(minutes: 3)), skip: Platform.environment['YTDLP_LIVE'] == '1' ? false : 'YTDLP_LIVE not set');

  test('pieces only without a file: the tweet\'s HLS video + audio; DASH fragments; muxed HLS', () {
    final tweet = [
      _f('hls-audio-128000-Audio', 'm3u8_native', 'none', null, null, tbr: 128),
      _f('hls-430', 'm3u8_native', 'avc1.64001F', 'none', 598, tbr: 430),
    ];
    expect([for (final t in pickTracks(tweet)) (t.kind, t.format.id, t.format.isPieces)],
        [('video', 'hls-430', true), ('audio', 'hls-audio-128000-Audio', true)]);
    // A byte file (even a shorter one) comes first.
    expect(pickTracks([...tweet, _f('http-832', 'https', null, null, 360)]).single.format.id, 'http-832');
    final dash = _f('v', 'http_dash_segments', 'avc1', 'none', 1080, extra: {
      'fragment_base_url': 'https://cdn.example/b/',
      'fragments': [
        {'path': 'init.mp4'},
        {'path': 's1.m4s', 'duration': 4.0},
        {'url': 'https://other.example/s2.m4s', 'duration': 2.5},
      ],
    });
    final t = pickTracks([dash, _f('a', 'http_dash_segments', 'none', 'mp4a', null, extra: {'fragments': [{'url': 'https://cdn.example/a', 'duration': 6.5}]})]);
    final p = dashPieces(t.first.format.fragments!);
    expect(p.sources.map((s) => '${s.url}'), ['https://cdn.example/b/init.mp4', 'https://cdn.example/b/s1.m4s', 'https://other.example/s2.m4s']);
    expect((p.list.pieces.first.role, p.list.pieces[2].map, p.list.duration), (RelayPieceRole.init, 0, 6.5));
    // A muxed playlist wins unless the pair is taller.
    final muxed = _f('m', 'm3u8_native', 'avc1', 'mp4a', 720);
    expect(pickTracks([muxed, ...tweet]).single.format.id, 'm');
    expect(pickTracks([muxed, ...tweet]).single.kind, 'video');
  });

  test('codec order: HEVC, then AV1, then VP9, then h264 at the same height', () {
    final audio = _f('140', 'https', 'none', 'mp4a.40.2', null);
    String pick(List<String> codecs) => pickSplit([
          for (final (i, c) in codecs.indexed) _f('v$i', 'https', c, 'none', 1080),
          audio,
        ])!.$1.id;
    expect(pick(['avc1.640033', 'vp09.00.40.08', 'av01.0.08M.08', 'hvc1.1.6.L12']), 'v3');
    expect(pick(['avc1.640033', 'vp09.00.40.08', 'av01.0.08M.08']), 'v2');
    expect(pick(['avc1.640033', 'vp09.00.40.08']), 'v1');
  });
}
