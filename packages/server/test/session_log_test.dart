import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('session_log'));
  tearDown(() async => dir.delete(recursive: true));

  String read() => File('${dir.path}/session-2026-10-12.log').readAsStringSync();

  test('merges lines of every side in server-clock order after the window', () async {
    var now = DateTime(2026, 10, 12, 18, 0, 30);
    final log = SessionLog(dir.path, window: const Duration(seconds: 15), now: () => now);
    int at(int s, [int ms = 0]) => DateTime(2026, 10, 12, 18, 0, s, ms).millisecondsSinceEpoch;
    log.add(at(12), 'Bob (m2)', 'INFO', 'relay', 'second');
    log.add(at(10, 5), 'server', 'WARNING', 'server_hub', 'first\n  error: boom');
    log.add(at(20), 'Alice (m1)', 'INFO', 'mpv', 'too new');
    log.add(at(14), 'Alice (m1)', 'INFO', 'media', 'open http://h:1/r/default/50989dda73c45a4710751f8aff4a1982/2/0/x?sig=abc');
    log.mark(at(13), 'Alice (m1)', 'Alice', 'stutter\nhere');
    log.flush();
    expect(read().trimRight().split('\n'), [
      '18:00:10.005 [server] WARNING server_hub: first',
      '    error: boom',
      '18:00:12.000 [Bob (m2)] relay: second',
      '18:00:13.000 [Alice (m1)] === PROBLEM marked by Alice: stutter here ===',
      '18:00:14.000 [Alice (m1)] media: open http://h:1/r/default/***/2/0/x?sig=…',
    ]);
    expect(log.recent(const Duration(hours: 1)), endsWith('[Alice (m1)] mpv: too new'), reason: 'waiting lines too');
    now = DateTime(2026, 10, 12, 18, 1);
    await log.close();
    expect(read(), contains('18:00:20.000 [Alice (m1)] mpv: too new'));
  });

  test('takeBatch: notes the version once, opt-out once, dropped lines', () async {
    final now = DateTime(2026, 10, 12, 18);
    final log = SessionLog(dir.path, now: () => now);
    final t = now.millisecondsSinceEpoch;
    log.takeBatch('tok', 'Bob (m2)', 'Bob',
        DiagBatch(version: 'WT 1.0', lines: [DiagLine(t: t, level: 'INFO', logger: 'app', message: 'hi')], dropped: 3));
    log.takeBatch('tok', 'Bob (m2)', 'Bob', DiagBatch(version: 'WT 1.0', lines: [DiagLine(t: t, level: 'INFO', logger: 'app', message: 'again')]));
    log.takeBatch('tok2', 'Cleo (m3)', 'Cleo', const DiagBatch(version: 'WT 1.0', share: false, lines: [DiagLine(t: 0, level: 'INFO', logger: 'app', message: 'never')]));
    log.takeBatch('tok2', 'Cleo (m3)', 'Cleo', const DiagBatch(version: 'WT 1.0', share: false));
    await log.close();
    final text = read();
    expect('shares diagnostics'.allMatches(text).length, 1);
    expect(text, contains('[server] diag: Bob (m2) shares diagnostics (WT 1.0)'));
    expect(text, contains("[server] diag: Cleo (m3) doesn't share diagnostics (WT 1.0)"));
    expect("doesn't share".allMatches(text).length, 1);
    expect(text, contains('[Bob (m2)] WARNING diag: 3 lines dropped'));
    expect(text, isNot(contains('never')));
  });

  group('live', () {
    late SyncServer server;
    setUp(() async {
      server = SyncServer(const AppConfig(port: 0, secret: 's', name: 't'), logDir: dir.path);
      await server.start();
    });
    tearDown(() async => server.stop());

    Future<(WebSocketChannel, String)> join(String name) async {
      final ch = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'));
      final msgs = StreamIterator(ch.stream);
      ch.sink.add(jsonEncode(HelloMessage(
              proto: RelayConstants.protoVersion,
              secret: 's',
              user: HelloUser(name: name))
          .toJson()));
      while (await msgs.moveNext()) {
        final m = jsonDecode('${msgs.current}') as Map;
        if (m['t'] == 'welcome') {
          unawaited(() async {
            while (await msgs.moveNext()) {}
          }());
          return (ch, m['token'] as String);
        }
      }
      throw StateError('no welcome');
    }

    DiagUploader uploader(String token, {String version = 'WT 1.0'}) => DiagUploader(
        target: () => (base: Uri.parse('http://127.0.0.1:${server.boundPort}'), token: token, offsetMs: 0),
        version: version);

    test('members send lines and marks; chat never lands; any member reads it back', () async {
      final (alice, aliceTok) = await join('Alice');
      final (bob, bobTok) = await join('Bob');
      final a = uploader(aliceTok)..start();
      final b = uploader(bobTok)
        ..share = false
        ..start();
      Logger('relay').info('alice line password=hunter2');
      alice.sink.add(jsonEncode(const ChatMessage(text: 'secret chat words').toJson()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await a.flush(), isTrue);
      expect(await b.flush(), isTrue);
      expect(await a.markProblem('audio drifts'), isTrue);
      final text = await a.fetchSessionLog(hours: 1);
      expect(text, isNotNull);
      expect(text, contains('[Alice (m1)] relay: alice line password=***'));
      expect(text, contains('=== PROBLEM marked by Alice: audio drifts ==='));
      expect(text, contains("Bob (m2) doesn't share diagnostics"));
      expect(text, contains('[server] server_hub: join Alice'));
      expect(text, isNot(contains('secret chat words')));
      // Bob reads it too (friends); a stranger does not.
      expect(await b.fetchSessionLog(), contains('PROBLEM'));
      expect(await uploader('0' * 32).fetchSessionLog(), isNull);
      final bad = await HttpClient().postUrl(Uri.parse('http://127.0.0.1:${server.boundPort}/l/default/$aliceTok'));
      bad.add(utf8.encode('not gzip'));
      expect((await bad.close()).statusCode, 400);
      await a.stop();
      await b.stop();
      await alice.sink.close();
      await bob.sink.close();
      await server.stop();
      final files = dir.listSync().map((e) => e.uri.pathSegments.last).where((n) => n.startsWith('session-'));
      final all = [for (final n in files) File('${dir.path}/$n').readAsStringSync()].join();
      expect(all, contains('PROBLEM'));
      expect(all, isNot(contains('secret chat words')));
    });
  });
}
