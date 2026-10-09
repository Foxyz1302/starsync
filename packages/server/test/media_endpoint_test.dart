import 'dart:io';
import 'dart:typed_data';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

void main() {
  group('resolveMediaRequest pure table', () {
    test('no Range -> 200 full with exact length', () {
      final r = resolveMediaRequest(rangeHeader: null, size: 1000, filename: 'a.mkv');
      expect(r.status, 200);
      expect(r.headers['accept-ranges'], 'bytes');
      expect(r.headers['content-type'], 'video/x-matroska');
      expect(r.headers['content-length'], '1000');
      expect(r.start, 0);
      expect(r.end, isNull);
    });

    test('closed range -> 206 exact bytes + content-range', () {
      final r = resolveMediaRequest(rangeHeader: 'bytes=0-99', size: 1000, filename: 'a.mkv');
      expect(r.status, 206);
      expect(r.headers['content-range'], 'bytes 0-99/1000');
      expect(r.headers['content-length'], '100');
    });

    test('open-ended range -> 206 to EOF', () {
      final r = resolveMediaRequest(rangeHeader: 'bytes=900-', size: 1000, filename: 'b.mp4');
      expect(r.status, 206);
      expect(r.headers['content-range'], 'bytes 900-999/1000');
      expect(r.headers['content-length'], '100');
      expect(r.headers['content-type'], 'video/mp4');
    });

    test('suffix range -> tail (mkv cues probe)', () {
      final r = resolveMediaRequest(rangeHeader: 'bytes=-500', size: 1000, filename: 'c.mkv');
      expect(r.status, 206);
      expect(r.start, 500);
      expect(r.headers['content-length'], '500');
    });

    test('out-of-range start -> 416 with bytes */size', () {
      final r = resolveMediaRequest(rangeHeader: 'bytes=5000-6000', size: 1000, filename: 'a.mkv');
      expect(r.status, 416);
      expect(r.headers['content-range'], 'bytes */1000');
    });

    test('gates: gone/auth/forbidden/offline', () {
      expect(
          resolveMediaRequest(rangeHeader: null, size: 10, filename: 'a.mkv', gate: MediaGate.gone).status,
          410);
      expect(
          resolveMediaRequest(rangeHeader: null, size: 10, filename: 'a.mkv', gate: MediaGate.unauthorized)
              .status,
          401);
      final off =
          resolveMediaRequest(rangeHeader: null, size: 10, filename: 'a.mkv', gate: MediaGate.offline);
      expect(off.status, 503);
      expect(off.headers['retry-after'], isNotEmpty);
    });

    test('content types by extension', () {
      expect(contentTypeForFile('x.MKV'), 'video/x-matroska');
      expect(contentTypeForFile('x.mp4'), 'video/mp4');
      expect(contentTypeForFile('x.webm'), 'video/webm');
      expect(contentTypeForFile('x.avi'), 'video/x-msvideo');
      expect(contentTypeForFile('x.unknown'), 'application/octet-stream');
    });
  });

  group('live Relic media route (byte-exact)', () {
    late File file;
    late Uint8List bytes;
    late RelicApp app;
    late RelicServer server;
    late HttpClient client;

    setUp(() async {
      bytes = Uint8List.fromList(List<int>.generate(65536, (i) => i % 251));
      file = File('${Directory.systemTemp.path}/media_test_${DateTime.now().microsecondsSinceEpoch}.bin');
      await file.writeAsBytes(bytes);
      app = RelicApp();
      mountMediaRoute(app, file);
      server = await app.serve(address: InternetAddress.loopbackIPv4, port: 0);
      client = HttpClient();
    });

    tearDown(() async {
      client.close();
      await app.close();
      await file.delete();
    });

    Future<HttpClientResponse> get(String path, {String? range}) async {
      final req = await client.get('127.0.0.1', server.port, path);
      if (range != null) req.headers.set('range', range);
      return req.close();
    }

    Future<List<int>> readAll(HttpClientResponse resp) async {
      final out = <int>[];
      await for (final chunk in resp) {
        out.addAll(chunk);
      }
      return out;
    }

    test('200 full body matches file bytes', () async {
      final resp = await get('/m/file');
      expect(resp.statusCode, 200);
      expect(resp.headers.value('accept-ranges'), 'bytes');
      expect(resp.headers.value('content-length'), '${bytes.length}');
      expect(await readAll(resp), bytes);
    });

    test('206 closed range byte-exact', () async {
      final resp = await get('/m/file', range: 'bytes=100-199');
      expect(resp.statusCode, 206);
      expect(resp.headers.value('content-range'), 'bytes 100-199/${bytes.length}');
      expect(resp.headers.value('content-length'), '100');
      expect(await readAll(resp), bytes.sublist(100, 200));
    });

    test('206 open-ended streams to EOF', () async {
      final resp = await get('/m/file', range: 'bytes=${bytes.length - 1000}-');
      expect(resp.statusCode, 206);
      expect(resp.headers.value('content-length'), '1000');
      expect(await readAll(resp), bytes.sublist(bytes.length - 1000));
    });

    test('206 suffix tail byte-exact', () async {
      final resp = await get('/m/file', range: 'bytes=-256');
      expect(resp.statusCode, 206);
      expect(await readAll(resp), bytes.sublist(bytes.length - 256));
    });

    test('seek storm: 20 rapid seeks all byte-exact', () async {
      for (var i = 0; i < 20; i++) {
        final start = (i * 997) % (bytes.length - 512);
        final resp = await get('/m/file', range: 'bytes=$start-${start + 511}');
        expect(resp.statusCode, 206);
        expect(await readAll(resp), bytes.sublist(start, start + 512));
      }
    });

    test('onLog hook records method/range/status/bytes', () async {
      final seen = <MediaLog>[];
      final logApp = RelicApp();
      mountMediaRoute(logApp, file, route: '/m/logged', onLog: seen.add);
      final logServer =
          await logApp.serve(address: InternetAddress.loopbackIPv4, port: 0);
      try {
        final req = await client.get('127.0.0.1', logServer.port, '/m/logged');
        req.headers.set('range', 'bytes=0-9');
        final resp = await req.close();
        await resp.drain();
        expect(resp.statusCode, 206);
      } finally {
        await logApp.close();
      }
      expect(seen, hasLength(1));
      expect(seen.single.status, 206);
      expect(seen.single.bytesWritten, 10);
      expect(seen.single.rangeHeader, 'bytes=0-9');
      expect(seen.single.toString(), contains('206'));
    });
  });
}
