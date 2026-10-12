import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('redactLog', () {
    const tok = '50989dda73c45a4710751f8aff4a1982';

    test('signed URLs keep scheme, host, path and parameter names only', () {
      final out = redactLog('GET https://upos-hz-mirrorakam.akamaized.net/a/b-30080.m4s?deadline=1791826934&upsig=0f61b79b&hdnts=exp~acl -> 403');
      expect(out, 'GET https://upos-hz-mirrorakam.akamaized.net/a/b-30080.m4s?deadline&upsig&hdnts=… -> 403');
      expect(redactLog('https://jf.example/Videos/1/stream?static=true&api_key=abc123'),
          'https://jf.example/Videos/1/stream?static&api_key=***');
      expect(redactLog('http://user:pw@host/x#frag'), 'http://***@host/x');
    });

    test('member tokens in server paths', () {
      expect(redactLog('open http://1.2.3.4:8080/r/default/$tok/2/0/name'), 'open http://1.2.3.4:8080/r/default/***/2/0/name');
      expect(redactLog('ws://h:1/r/default/$tok/source?q=7'), 'ws://h:1/r/default/***/source?q=…');
      expect(redactLog('/m/default/$tok/file.mkv range=bytes=0-'), '/m/default/***/file.mkv range=bytes=0-');
      expect(redactLog('edl://!no_clip;%160%http://h/r/default/$tok/2/0/n;!new_stream;!no_clip;%160%http://h/r/default/$tok/2/1/n'),
          isNot(contains(tok)));
    });

    test('secret values by name: pairs, JSON, quoted, headers, bearer', () {
      expect(redactLog('api_key=abc123&x=1'), 'api_key=***&x=1');
      expect(redactLog('{"token":"$tok","name":"bob","secret":"hunter2"}'), '{"token":"***","name":"bob","secret":"***"}');
      expect(redactLog('MediaBrowser Client="WT", Device="pc", Token="deadbeef"'), contains('Token="***"'));
      expect(redactLog('headers: {Cookie: SESSDATA=abc; bili_jct=x}'), 'headers: {Cookie: ***');
      expect(redactLog('Authorization: Bearer abcdefgh12345678'), 'Authorization: ***');
      expect(redactLog('sent Bearer abcdefgh12345678 to it'), 'sent Bearer *** to it');
      expect(redactLog('password=pw1 hostKey=k1 X-Emby-Token=t1'), 'password=*** hostKey=*** X-Emby-Token=***');
    });

    test('leaves ordinary text alone', () {
      const plain = 'yt-dlp cookies: 5 for youtube.com; relay pull 3 failed: upstream HTTP 403; tokens: 2 members';
      expect(redactLog(plain), plain);
    });

    test('formatLogLine redacts the error and stack too', () {
      final line = formatLogLine(DateTime(2026, 1, 2, 3, 4, 5, 6), 'WARNING', 'relay', 'read failed',
          error: 'HttpException: upstream HTTP 403, uri = https://cdn/x.m4s?sig=abc');
      expect(line, '2026-01-02 03:04:05.006 WARNING relay: read failed\n  error: HttpException: upstream HTTP 403, uri = https://cdn/x.m4s?sig=…');
      expect(logLineTime(line), DateTime(2026, 1, 2, 3, 4, 5, 6));
    });
  });

  test('LogThrottle lets a burst through, then counts what it dropped', () {
    var now = DateTime(2026);
    final t = LogThrottle(burst: 2, window: const Duration(seconds: 10), now: () => now);
    expect([t.allow('a'), t.allow('a'), t.allow('a'), t.allow('b')], ['', '', null, '']);
    now = now.add(const Duration(seconds: 11));
    expect(t.allow('a'), '(1 more like this dropped) ');
  });

  group('LogFiles', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('logfiles'));
    tearDown(() async => dir.delete(recursive: true));

    test('rolls by size and day, prunes by age and total, reads recent lines', () {
      var now = DateTime(2026, 10, 12, 10);
      File('${dir.path}/app-2026-10-01.log').writeAsStringSync('old\n');
      File('${dir.path}/server-2026-10-01.log').writeAsStringSync('not ours\n');
      final f = LogFiles(dir.path, maxFileBytes: 100, maxTotalBytes: 1000, now: () => now)..open();
      expect(File('${dir.path}/app-2026-10-01.log').existsSync(), isFalse);
      expect(File('${dir.path}/server-2026-10-01.log').existsSync(), isTrue);
      String line(String m) => formatLogLine(now, 'INFO', 't', m);
      f.write(line('a' * 60));
      f.write(line('b'));
      expect(f.currentPath, endsWith('app-2026-10-12.log'));
      f.write(line('b2'));
      expect(f.currentPath, endsWith('app-2026-10-12.1.log'));
      now = DateTime(2026, 10, 13, 9);
      f.write(line('c'));
      f.write('  continuation of c');
      expect(f.currentPath, endsWith('app-2026-10-13.log'));
      final recent = f.recent(const Duration(hours: 2));
      expect(recent, '${line('c')}\n  continuation of c');
      expect(f.recent(const Duration(days: 2)).split('\n').first, contains('a' * 60));
      f.close();
      // Total cap: the oldest go first.
      final small = LogFiles(dir.path, maxFileBytes: 100, maxTotalBytes: 150, now: () => now)..open();
      expect(small.files().map((x) => x.uri.pathSegments.last), ['app-2026-10-12.1.log', 'app-2026-10-13.log']);
      small.close();
    });
  });
}
