import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('server auth live', () {
    late File file;
    late Uint8List bytes;
    late SyncServer server;
    late HttpClient http;

    setUp(() async {
      bytes = Uint8List.fromList(List<int>.generate(8192, (i) => i % 251));
      file = File(
          '${Directory.systemTemp.path}/server_test_${DateTime.now().microsecondsSinceEpoch}.bin');
      await file.writeAsBytes(bytes);
      server = SyncServer(AppConfig(
          port: 0, secret: 'shh', name: 'test', mediaPath: file.path));
      await server.start();
      http = HttpClient();
    });

    tearDown(() async {
      http.close();
      await server.stop();
      await file.delete();
    });

    Future<HttpClientResponse> mediaGet(String path, {String? range}) async {
      final req = await http.get('127.0.0.1', server.boundPort, path);
      if (range != null) req.headers.set('range', range);
      return req.close();
    }

    Future<String> hello(String secret,
        {int proto = RelayConstants.protoVersion,
        Duration timeout = const Duration(seconds: 5)}) async {
      final ch = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'));
      final msg = HelloMessage(
          proto: proto,
          secret: secret,
          user: const HelloUser(name: 'alice'),
          media:
              const HelloMedia(name: 'f.bin', size: 8192, duration: 10.0)).toJson();
      ch.sink.add(jsonEncode(msg));
      try {
        final first = await ch.stream.first.timeout(timeout);
        await ch.sink.close();
        return '$first';
      } catch (_) {
        try {
          await ch.sink.close();
        } catch (_) {}
        rethrow;
      }
    }

    test('health reports name, proto, viewers, bytes', () async {
      final req = await http.get('127.0.0.1', server.boundPort, '/health');
      final resp = await req.close();
      expect(resp.statusCode, 200);
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body) as Map;
      expect(decoded['ok'], isTrue);
      expect(decoded['name'], 'test');
      expect(decoded['proto'], RelayConstants.protoVersion);
      expect(decoded['viewers'], 0);
      expect(decoded['bytesServed'], 0);
      expect(decoded.containsKey('media'), isFalse, reason: 'no media name leak');
    });

    test('wrong secret gets err, right secret gets welcome+token', () async {
      final bad = await hello('wrong');
      expect(jsonDecode(bad)['t'], 'err');

      final good = await hello('shh');
      final decoded = jsonDecode(good) as Map;
      expect(decoded['t'], 'welcome');
      final token = decoded['token'] as String;
      expect(token, hasLength(32));
      expect(decoded['mediaUrl'], contains(token));

      final req = await http.get('127.0.0.1', server.boundPort, '/health');
      final resp = await req.close();
      await resp.drain();
      expect(server.session.tokens.length, 1);
    });

    test('proto mismatch rejected', () async {
      final reply =
          await hello('shh', proto: RelayConstants.protoVersion + 99);
      expect(jsonDecode(reply)['t'], 'err');
      expect(server.session.tokens, isEmpty);
    });

    test('media: no token 401, bad token 401, good token 200 byte-exact',
        () async {
      final good = await hello('shh');
      final token = (jsonDecode(good) as Map)['token'] as String;
      final name = file.path.split(Platform.pathSeparator).last;

      var resp = await mediaGet('/m/default/notoken/$name');
      expect(resp.statusCode, 401);
      await resp.drain();

      resp = await mediaGet('/m/default/deadbeefdeadbeefdeadbeefdeadbeef/$name');
      expect(resp.statusCode, 401);
      await resp.drain();

      resp = await mediaGet('/m/default/$token/$name', range: 'bytes=0-99');
      expect(resp.statusCode, 206);
      expect(resp.headers.value('content-range'), 'bytes 0-99/8192');
      final body = <int>[];
      await for (final c in resp) {
        body.addAll(c);
      }
      expect(body, bytes.sublist(0, 100));
      expect(server.session.tokens[token]!.bytesServed, 100);
    });

    test('unknown session -> 410', () async {
      final resp = await mediaGet('/m/nosuch/abc/file');
      expect(resp.statusCode, 410);
      await resp.drain();
    });

    test('kick: WS drops and media goes 403', () async {
      final ch = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'));
      final firstCompleter = Completer<String>();
      var wsClosed = false;
      final sub = ch.stream.listen(
        (m) {
          if (!firstCompleter.isCompleted) firstCompleter.complete('$m');
        },
        onDone: () => wsClosed = true,
      );
      final msg = HelloMessage(
          proto: RelayConstants.protoVersion,
          secret: 'shh',
          user: const HelloUser(name: 'mallory'),
          media:
              const HelloMedia(name: 'f.bin', size: 8192, duration: 10.0)).toJson();
      ch.sink.add(jsonEncode(msg));
      final first =
          await firstCompleter.future.timeout(const Duration(seconds: 5));
      final token = (jsonDecode(first) as Map)['token'] as String;

      await server.session.kick(token);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!wsClosed && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(wsClosed, isTrue);
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        await ch.sink.close();
      } catch (_) {}

      final name = file.path.split(Platform.pathSeparator).last;
      final resp = await mediaGet('/m/default/$token/$name');
      expect(resp.statusCode, 403);
      await resp.drain();
    });

    test('kick delivers reason then drops; instant rejoin works', () async {
      final ch = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'));
      final messages = <String>[];
      var wsClosed = false;
      final sub = ch.stream.listen(
        (m) => messages.add('$m'),
        onDone: () => wsClosed = true,
      );
      HelloMessage helloFor(String who) => HelloMessage(
          proto: RelayConstants.protoVersion,
          secret: 'shh',
          user: HelloUser(name: who),
          media: const HelloMedia(
              name: 'f.bin', size: 8192, duration: 10.0));
      ch.sink.add(jsonEncode(helloFor(' sleepy').toJson()));
      Map<String, Object?>? welcome;
      final welcomeDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(welcomeDeadline)) {
        for (final m in messages) {
          final decoded = jsonDecode(m) as Map;
          if (decoded['t'] == 'welcome') {
            welcome = Map<String, Object?>.from(decoded);
          }
        }
        if (welcome != null) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(welcome, isNotNull);
      final token = welcome!['token'] as String;

      await server.session.kick(token, reason: 'idle too long');
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      Map<String, Object?>? kicked;
      while (DateTime.now().isBefore(deadline)) {
        for (final m in messages.skip(1)) {
          final decoded = jsonDecode(m) as Map;
          if (decoded['t'] == 'kicked') {
            kicked = Map<String, Object?>.from(decoded);
          }
        }
        if (wsClosed && kicked != null) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(wsClosed, isTrue);
      expect(kicked, isNotNull);
      expect(kicked!['reason'], 'idle too long');
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        await ch.sink.close();
      } catch (_) {}

      final rejoin = await hello('shh');
      final decoded = jsonDecode(rejoin) as Map;
      expect(decoded['t'], 'welcome');
      final token2 = decoded['token'] as String;
      expect(token2, isNot(token));
      final name = file.path.split(Platform.pathSeparator).last;
      final resp = await mediaGet('/m/default/$token2/$name');
      expect(resp.statusCode, 200);
      await resp.drain();
    });

    test('kick via socket: peer kicked, unknown target errors', () async {
      Future<(WebSocketChannel, String, String, List<String>)> join(String who,
          [String host = '127.0.0.1']) async {
        final ch = WebSocketChannel.connect(
            Uri.parse('ws://$host:${server.boundPort}/sync'));
        final messages = <String>[];
        ch.stream.listen((m) => messages.add('$m'));
        final msg = HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: 'shh',
            user: HelloUser(name: who),
            media: const HelloMedia(
                name: 'f.bin', size: 8192, duration: 10.0)).toJson();
        ch.sink.add(jsonEncode(msg));
        Map<String, Object?>? welcome;
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          for (final m in messages) {
            final decoded = jsonDecode(m) as Map;
            if (decoded['t'] == 'welcome') {
              welcome = Map<String, Object?>.from(decoded);
            }
          }
          if (welcome != null) break;
          await Future.delayed(const Duration(milliseconds: 50));
        }
        expect(welcome, isNotNull,
            reason: 'no welcome for $who: $messages');
        final w = welcome!;
        return (ch, w['token'] as String, w['memberId'] as String, messages);
      }

      Map<String, Object?>? findType(List<String> messages, String type) {
        for (final m in messages) {
          final decoded = jsonDecode(m) as Map;
          if (decoded['t'] == type) return Map<String, Object?>.from(decoded);
        }
        return null;
      }

      Future<Map<String, Object?>?> waitType(
          List<String> messages, String type, Duration timeout) async {
        final deadline = DateTime.now().add(timeout);
        while (DateTime.now().isBefore(deadline)) {
          final found = findType(messages, type);
          if (found != null) return found;
          await Future.delayed(const Duration(milliseconds: 50));
        }
        return findType(messages, type);
      }

      final (a, _, _, messagesA) = await join('alice');
      final (b, tokenB, idB, messagesB) = await join('bob');
      try {
        a.sink.add(jsonEncode(
            KickRequest(target: idB, reason: 'afk?').toJson()));
        final kicked = await waitType(
            messagesB, 'kicked', const Duration(seconds: 5));
        expect(kicked, isNotNull);
        expect(kicked!['reason'], 'afk?');
        expect(server.session.gate(tokenB), MediaGate.forbidden);

        a.sink.add(
            jsonEncode(const KickRequest(target: 'm99').toJson()));
        final err = await waitType(
            messagesA, 'err', const Duration(seconds: 5));
        expect(err, isNotNull);
      } finally {
        try {
          await a.sink.close();
        } catch (_) {}
        try {
          await b.sink.close();
        } catch (_) {}
      }
    });

    test('silent socket dropped and member removed', () async {
      final ch = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'));
      final messages = <String>[];
      var wsClosed = false;
      final sub = ch.stream.listen(
        (m) => messages.add('$m'),
        onDone: () => wsClosed = true,
      );
      final msg = HelloMessage(
          proto: RelayConstants.protoVersion,
          secret: 'shh',
          user: const HelloUser(name: 'ghost'),
          media: const HelloMedia(
              name: 'f.bin', size: 8192, duration: 10.0)).toJson();
      ch.sink.add(jsonEncode(msg));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (messages.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      final token =
          (jsonDecode(messages.firstWhere((m) => (jsonDecode(m) as Map)['t'] == 'welcome')) as Map)['token']
              as String;
      server.hub.engine.members[token]!.lastSeen =
          DateTime.now().toUtc().subtract(const Duration(seconds: 61));
      server.hub.dropSilentSockets();
      final closeDeadline = DateTime.now().add(const Duration(seconds: 5));
      while ((!wsClosed ||
              server.hub.engine.members.containsKey(token) ||
              server.session.tokens.containsKey(token)) &&
          DateTime.now().isBefore(closeDeadline)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(wsClosed, isTrue);
      expect(server.hub.engine.members.containsKey(token), isFalse);
      expect(server.session.tokens.containsKey(token), isFalse);
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        await ch.sink.close();
      } catch (_) {}
    });

    test('any frame touches lastSeen (heartbeat baseline)', () async {
      final good = await hello('shh');
      final token = (jsonDecode(good) as Map)['token'] as String;
      final viewer = server.session.tokens[token]!;
      viewer.touch(DateTime.utc(2020, 1, 1));
      expect(viewer.isStale(const Duration(seconds: 30)), isTrue);

      final ch = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'));
      final sub = ch.stream.listen((_) {});
      ch.sink.add(jsonEncode(HelloMessage(
              proto: RelayConstants.protoVersion,
              secret: 'shh',
              user: const HelloUser(name: 'hb'),
              media: const HelloMedia(
                  name: 'f.bin', size: 8192, duration: 10.0))
          .toJson()));
      await Future.delayed(const Duration(seconds: 1));
      final hbToken = server.session.tokens.keys
          .firstWhere((k) => server.session.tokens[k]!.name == 'hb');
      expect(server.session.tokens[hbToken]!.isStale(const Duration(seconds: 30)), isFalse);
      expect(viewer.isStale(const Duration(seconds: 30)), isTrue);
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        await ch.sink.close();
      } catch (_) {}
    });
  });
}
