import 'dart:io';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

// A page relayed by its formats: an expired format URL (403/410/412) is
// resolved again once, and not again and again when the site keeps
// refusing.

/// yt-dlp that resolves the page to the origin's current format URL.
class _CountingYtDlp extends YtDlp {
  final Uri Function() url;
  var resolves = 0;
  _CountingYtDlp(super.dir, this.url);

  @override
  Future<YtDlpInfo> resolve(String page, {Duration timeout = const Duration(seconds: 25)}) async {
    resolves++;
    final f = YtDlpFormat(id: 'v', url: url());
    return YtDlpInfo(title: 'page', tracks: [(kind: '', format: f)], formats: {'v': f});
  }
}

void main() {
  late HttpServer origin;
  late Directory tmp;
  // Only `/v<gen>.mp4` of the current generation is served; older ones get
  // [refusal] (a format URL that expired).
  var gen = 1;
  var refusal = 412;
  final bytes = Uint8List.fromList(List.generate(100000, (i) => i % 251));

  setUp(() async {
    gen = 1;
    refusal = 412;
    tmp = await Directory.systemTemp.createTemp('page-relay');
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      if (req.uri.path != '/v$gen.mp4') {
        req.response.statusCode = refusal;
        await req.response.close();
        return;
      }
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(req.headers.value('range') ?? '')!;
      final start = int.parse(m.group(1)!), end = int.parse(m.group(2)!);
      req.response
        ..statusCode = 206
        ..headers.contentType = ContentType('video', 'mp4')
        ..headers.set('content-range', 'bytes $start-$end/${bytes.length}')
        ..add(bytes.sublist(start, end + 1));
      await req.response.close();
    });
  });

  tearDown(() async {
    await origin.close(force: true);
    await tmp.delete(recursive: true);
  });

  Uri current() => Uri.parse('http://127.0.0.1:${origin.port}/v$gen.mp4');

  Future<List<int>> read(RelayTrack t, int start, int end) async =>
      [for (final c in await t.bytes!.read(start, end).toList()) ...c];

  for (final status in [403, 410, 412]) {
    test('HTTP $status: the page is resolved again once and the read goes on', () async {
      refusal = status;
      final y = _CountingYtDlp(tmp.path, current);
      final media = PageRelayMedia(Uri.parse('https://example.com/watch'), y);
      addTearDown(media.close);
      final t = (await media.open()).single;
      expect(await t.bytes!.size(), bytes.length);
      expect(await read(t, 0, 999), bytes.sublist(0, 1000));
      gen = 2; // the first URL expired
      expect(await read(t, 5000, 5999), bytes.sublist(5000, 6000));
      expect(y.resolves, 2);
    });
  }

  test('refused again right after a resolve: the read fails, no resolve storm', () async {
    final y = _CountingYtDlp(tmp.path, current);
    final media = PageRelayMedia(Uri.parse('https://example.com/watch'), y);
    addTearDown(media.close);
    final t = (await media.open()).single;
    await t.bytes!.size();
    gen = 2;
    expect(await read(t, 0, 9), bytes.sublist(0, 10));
    gen = 3; // the fresh URL is refused too
    for (var i = 0; i < 5; i++) {
      await expectLater(read(t, 0, 9), throwsA(isA<UpstreamHttpException>().having((e) => e.status, 'status', 412)));
    }
    expect(y.resolves, 2);
  });

  test('another expiry after the gap resolves again', () async {
    final y = _CountingYtDlp(tmp.path, current);
    final media = PageRelayMedia(Uri.parse('https://example.com/watch'), y, refreshGap: Duration.zero);
    addTearDown(media.close);
    final t = (await media.open()).single;
    await t.bytes!.size();
    for (gen = 2; gen <= 4; gen++) {
      expect(await read(t, 100, 199), bytes.sublist(100, 200));
    }
    expect(y.resolves, 4);
  });
}
