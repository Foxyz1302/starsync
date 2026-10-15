// restructure: rewrite in step 1 (Connection + Identity + Presence):
// "proto mismatch rejected" (min/max range, refusal frame) and "silent
// socket dropped and member removed" (Gone with grace); the rest stays.
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
          '${Directory.systemTemp.path}/server_test_${DateTime.now().microsecondsSinceEpoch}.mkv');
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
      expect(resp.headers.contentType?.mimeType, contentTypeForFile(name));
      expect(contentTypeForFile(name), isNot('application/octet-stream'));
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

    test('art: swapper only, current mediaId, hashes in state, /i serves', () async {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List<int>.generate(200, (i) => (i * 3) % 256)]);
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, ...List<int>.generate(200, (i) => i % 256)]);
      final clients = <WebSocketChannel>[];
      final subs = <StreamSubscription<Object?>>[];
      Future<(WebSocketChannel, List<Map<String, Object?>>, String)> connect(String name) async {
        final ch = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'));
        final messages = <Map<String, Object?>>[];
        clients.add(ch);
        subs.add(ch.stream.listen((m) => messages.add(Map<String, Object?>.from(jsonDecode('$m') as Map))));
        ch.sink.add(jsonEncode(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: 'shh',
            user: HelloUser(name: name),
            media: const HelloMedia(name: 'f.bin', size: 8192, duration: 10.0)).toJson()));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!messages.any((m) => m['t'] == 'welcome')) {
          if (DateTime.now().isAfter(deadline)) fail('no welcome');
          await Future.delayed(const Duration(milliseconds: 20));
        }
        return (ch, messages, messages.firstWhere((m) => m['t'] == 'welcome')['token'] as String);
      }

      Future<Map<String, Object?>> waitFor(
          List<Map<String, Object?>> messages, bool Function(Map<String, Object?>) test) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          for (final m in messages) {
            if (test(m)) return m;
          }
          await Future.delayed(const Duration(milliseconds: 20));
        }
        fail('timed out; got $messages');
      }

      Map<String, Object?>? artOf(Map<String, Object?> state) =>
          (state['media'] as Map?)?['art'] as Map<String, Object?>?;
      Future<HttpClientResponse> artGet(String token, String hash) async =>
          (await http.get('127.0.0.1', server.boundPort, '/i/default/$token/$hash')).close();

      try {
        final (a, aMsgs, aToken) = await connect('alice');
        final (b, bMsgs, bToken) = await connect('bob');
        a.sink.add(jsonEncode(const SwapIntent(
            media: HelloMedia(name: 'Show - 01.mkv', size: 1, duration: 0, url: 'http://example.com/a.mkv')).toJson()));
        final swapped = await waitFor(bMsgs, (m) => m['t'] == 'state' && (m['media'] as Map?)?['name'] == 'Show - 01.mkv');
        final mediaId = swapped['mediaId'] as int;

        // Not the swapper, or a stale mediaId: ignored.
        b.sink.add(jsonEncode(ArtMessage(mediaId: mediaId, poster: base64Encode(png)).toJson()));
        a.sink.add(jsonEncode(ArtMessage(mediaId: mediaId - 1, poster: base64Encode(png)).toJson()));
        await Future.delayed(const Duration(milliseconds: 300));
        expect(server.hub.engine.poster, isNull);

        a.sink.add(jsonEncode(ArtMessage(mediaId: mediaId, poster: base64Encode(jpeg), banner: base64Encode(png)).toJson()));
        final withArt = await waitFor(bMsgs, (m) => m['t'] == 'state' && artOf(m) != null);
        final art = artOf(withArt)!;
        expect(art, {'poster': avatarHashOf(jpeg), 'banner': avatarHashOf(png)});

        // Any member (a guest without Jellyfin) fetches it.
        final ok = await artGet(bToken, art['poster'] as String);
        expect(ok.statusCode, 200);
        expect(ok.headers.contentType?.mimeType, 'image/jpeg');
        expect(ok.headers.value('cache-control'), contains('immutable'));
        expect(await ok.expand((c) => c).toList(), jpeg);
        final unknown = await artGet(bToken, '0123456789abcdef');
        expect(unknown.statusCode, 404);
        await unknown.drain();
        final noToken = await artGet('nope', art['poster'] as String);
        expect(noToken.statusCode, 401);
        await noToken.drain();

        // Any swap clears the art.
        b.sink.add(jsonEncode(const SwapIntent(
            media: HelloMedia(name: 'Other.mkv', size: 1, duration: 0, url: 'http://example.com/b.mkv')).toJson()));
        final cleared = await waitFor(aMsgs, (m) => m['t'] == 'state' && (m['media'] as Map?)?['name'] == 'Other.mkv');
        expect(artOf(cleared), isNull);
        final gone = await artGet(aToken, art['poster'] as String);
        expect(gone.statusCode, 404);
        await gone.drain();
      } finally {
        for (final sub in subs) {
          await sub.cancel();
        }
        for (final ch in clients) {
          try {
            await ch.sink.close();
          } catch (_) {}
        }
      }
    });

    test('profile: rename + avatar feed, state carries hash, /a gated', () async {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, ...List<int>.generate(296, (i) => (i * 7) % 256)]);
      final ch = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'));
      final messages = <Map<String, Object?>>[];
      final sub = ch.stream.listen(
          (m) => messages.add(Map<String, Object?>.from(jsonDecode('$m') as Map)));
      Future<Map<String, Object?>> waitFor(bool Function(Map<String, Object?>) test) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          for (final m in messages) {
            if (test(m)) return m;
          }
          await Future.delayed(const Duration(milliseconds: 20));
        }
        fail('timed out; got $messages');
      }

      Map<String, Object?> member(Map<String, Object?> state) =>
          Map<String, Object?>.from((state['members'] as List).single as Map);
      Future<HttpClientResponse> avatarGet(String token, String hash) async =>
          (await http.get('127.0.0.1', server.boundPort, '/a/default/$token/$hash')).close();

      try {
        ch.sink.add(jsonEncode(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: 'shh',
            user: HelloUser(name: 'alice', avatar: base64Encode(png)),
            media: const HelloMedia(name: 'f.bin', size: 8192, duration: 10.0)).toJson()));
        final welcome = await waitFor((m) => m['t'] == 'welcome');
        final token = welcome['token'] as String;
        final first = member(Map<String, Object?>.from(welcome['state'] as Map));
        expect(first.containsKey('avatar'), isFalse, reason: 'no base64 in state');
        final hash = first['avatarHash'] as String;
        expect(hash, avatarHashOf(png));

        final ok = await avatarGet(token, hash);
        expect(ok.statusCode, 200);
        expect(ok.headers.contentType?.mimeType, 'image/png');
        expect(ok.headers.value('cache-control'), contains('max-age'));
        expect(await ok.expand((c) => c).toList(), png);
        final unknown = await avatarGet(token, '0123456789abcdef');
        expect(unknown.statusCode, 404);
        await unknown.drain();
        final noToken = await avatarGet('nope', hash);
        expect(noToken.statusCode, 401);
        await noToken.drain();

        // Rename: feed rename (actor new, target old); chat uses the new name.
        messages.clear();
        ch.sink.add(jsonEncode(const ProfileIntent(name: '  bob  ').toJson()));
        final rename = await waitFor((m) => m['t'] == 'feed' && m['action'] == 'rename');
        expect(rename['actor'], 'bob');
        expect(rename['target'], 'alice');
        final renamed = await waitFor((m) => m['t'] == 'state' && member(m)['name'] == 'bob');
        expect(member(renamed)['avatarHash'], hash, reason: 'picture unchanged');
        ch.sink.add(jsonEncode(const ChatMessage(text: 'hi').toJson()));
        expect((await waitFor((m) => m['t'] == 'chat'))['from'], 'bob');

        // Picture only: feed avatar; removing it drops the hash and the bytes.
        messages.clear();
        ch.sink.add(jsonEncode(const ProfileIntent(avatar: '').toJson()));
        final pic = await waitFor((m) => m['t'] == 'feed' && m['action'] == 'avatar');
        expect(pic['actor'], 'bob');
        await waitFor((m) => m['t'] == 'state' && !member(m).containsKey('avatarHash'));
        final gone = await avatarGet(token, hash);
        expect(gone.statusCode, 404);
        await gone.drain();

        // Too large: rejected, nothing changes.
        messages.clear();
        ch.sink.add(jsonEncode(
            ProfileIntent(avatar: 'x' * (RelayConstants.maxAvatarBytes + 1)).toJson()));
        final err = await waitFor((m) => m['t'] == 'err');
        expect(err['message'], 'rejected: avatar too large');
      } finally {
        await sub.cancel();
        try {
          await ch.sink.close();
        } catch (_) {}
      }
    });
  });
}
