import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  test('a batch survives gzip both ways; a bomb or junk is refused', () {
    const b = DiagBatch(
        version: 'WT 1.0',
        lines: [DiagLine(t: 5, level: 'WARNING', logger: 'mpv', message: 'x\n  error: y')],
        dropped: 2,
        marks: [DiagMark(t: 7, note: 'lag')]);
    final back = DiagBatch.decode(b.encode());
    expect(back.toJson(), b.toJson());
    expect(DiagBatch.decode(const DiagBatch(share: false).encode()).share, isFalse);
    expect(() => DiagBatch.decode(gzip.encode(List.filled(2 << 20, 32)), maxBytes: 1 << 20), throwsFormatException);
    expect(() => DiagBatch.decode(utf8.encode('plain')), throwsFormatException);
  });

  group('DiagUploader', () {
    late HttpServer http;
    final got = <DiagBatch>[];
    var accept = true;
    setUp(() async {
      got.clear();
      accept = true;
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((req) async {
        final body = await req.fold<List<int>>([], (a, c) => a..addAll(c));
        if (accept) got.add(DiagBatch.decode(body));
        req.response.statusCode = accept ? 204 : 503;
        await req.response.close();
      });
    });
    tearDown(() => http.close(force: true));

    DiagUploader make({bool connected = true, int buffer = 1 << 20}) => DiagUploader(
        target: () => connected ? (base: Uri.parse('http://127.0.0.1:${http.port}'), token: 't', offsetMs: 1000) : null,
        version: 'WT 1.0',
        bufferBytes: buffer);

    test('sends its records on the server clock, not the hosted server\'s; keeps them while it cannot', () async {
      final u = make()..start();
      Logger('relay').info('hello api_key=abc');
      Logger('server.relay').info('the server logs this itself');
      await Future<void>.delayed(Duration.zero);
      accept = false;
      expect(await u.flush(), isFalse);
      expect(u.pending, 1);
      accept = true;
      expect(await u.flush(), isTrue);
      final line = got.single.lines.single;
      expect(line.message, 'hello api_key=***');
      expect(line.logger, 'relay');
      expect(got.single.version, 'WT 1.0');
      await u.stop();
    });

    test('a full buffer drops the oldest and says how many', () async {
      final u = make(buffer: 400);
      for (var i = 0; i < 10; i++) {
        u.add(DiagLine(t: i, level: 'INFO', logger: 'a', message: 'line $i ${'x' * 40}'));
      }
      expect(await u.flush(), isTrue);
      expect(got.single.dropped, greaterThan(0));
      expect(got.single.lines.last.message, startsWith('line 9'));
      expect(got.single.lines.first.t, greaterThanOrEqualTo(1000), reason: 'offset to the server clock');
    });

    test('opted out: no lines, one "does not share" per connection; marks still go', () async {
      final u = make()
        ..share = false
        ..start();
      Logger('relay').info('private');
      expect(await u.flush(), isTrue);
      expect(await u.flush(), isTrue);
      expect(got.length, 1);
      expect(got.single.share, isFalse);
      expect(got.single.lines, isEmpty);
      expect(await u.markProblem('it\nfroze'), isTrue);
      expect(got.last.marks.single.note, 'it froze');
      await u.stop();
    });
  });
}
