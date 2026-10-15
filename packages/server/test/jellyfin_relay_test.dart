import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

const _serverId = 'fakeserver01';
const _item = '0123456789abcdef0123456789abcdef';
const _source = 'fedcba9876543210fedcba9876543210';
const _slowItem = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _nextItem = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _token = 'JF-SECRET-TOKEN';

const _cred = JellyfinCredential(
  baseUrl: 'http://127.0.0.1:1', // port filled in per test
  serverId: _serverId,
  token: _token,
  client: 'Watch Together',
  device: 'host pc "1"',
  deviceId: 'dev-42',
  version: '0.9.0',
);

/// Jellyfin stand-in: `/Videos/{id}/stream` serves [bytes] with ranges (the
/// same table as `/m`), `_slowItem` streams forever until the reader goes
/// away, `/System/Info/Public` gives the server id.
class _FakeJellyfin {
  final HttpServer _server;
  final Uint8List bytes;
  final requests = <HttpRequest>[];
  final auth = <String?>[];
  final uris = <Uri>[];
  final ranges = <String?>[];
  final slowAborted = Completer<void>();
  int status401 = 0;
  _FakeJellyfin._(this._server, this.bytes);

  int get port => _server.port;

  static Future<_FakeJellyfin> start(Uint8List bytes) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final f = _FakeJellyfin._(s, bytes);
    s.listen(f._handle);
    return f;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path == '/System/Info/Public') {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'Id': _serverId, 'ServerName': 'fake', 'Version': '10.11.0'}));
      await res.close();
      return;
    }
    auth.add(req.headers.value(HttpHeaders.authorizationHeader));
    uris.add(req.uri);
    ranges.add(req.headers.value(HttpHeaders.rangeHeader));
    if (status401 > 0) {
      status401--;
      res.statusCode = 401;
      await res.close();
      return;
    }
    final m = RegExp(r'^/Videos/([^/]+)/stream$').firstMatch(req.uri.path);
    if (m == null) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    if (m.group(1) == _slowItem) {
      // Raw socket: dart:io's HttpResponse.flush does not notice a peer that
      // went away, the socket's input closing does.
      final socket = await res.detachSocket(writeHeaders: false);
      socket.listen((_) {}, onError: (_) {}, onDone: () {
        if (!slowAborted.isCompleted) slowAborted.complete();
      });
      socket.write('HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\n'
          'Content-Range: bytes 0-999999999/1000000000\r\nContent-Length: 1000000000\r\n\r\n');
      final chunk = Uint8List(16 * 1024);
      try {
        while (!slowAborted.isCompleted) {
          socket.add(chunk);
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      } catch (_) {}
      socket.destroy();
      return;
    }
    final r = resolveMediaRequest(
        rangeHeader: req.headers.value(HttpHeaders.rangeHeader), size: bytes.length, filename: 'x.mkv');
    res.statusCode = r.status;
    res.headers.clear();
    r.headers.forEach(res.headers.set);
    if (r.status == 200 || r.status == 206) {
      final end = r.end ?? bytes.length - 1;
      res.contentLength = end - r.start + 1;
      res.add(bytes.sublist(r.start, end + 1));
    }
    await res.close();
  }

  Future<void> close() => _server.close(force: true);
}

class _Client {
  final WebSocket ws;
  final raw = <String>[];
  final _welcome = Completer<String>();
  _Client(this.ws) {
    ws.listen((m) {
      raw.add('$m');
      if ('$m'.contains('"t":"welcome"') && !_welcome.isCompleted) _welcome.complete('$m');
    }, onError: (_) {}, onDone: () {});
  }

  void send(Map<String, Object?> j) => ws.add(jsonEncode(j));

  Map<String, Object?>? get lastState {
    for (final f in raw.reversed) {
      final d = jsonDecode(f) as Map;
      if (d['t'] == 'state') return Map<String, Object?>.from(d);
    }
    return null;
  }

  static Future<(_Client, String)> join(int port, String name) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final c = _Client(ws);
    c.send(HelloMessage(
      proto: RelayConstants.protoVersion,
      secret: '',
      user: HelloUser(name: name)).toJson());
    return (c, await c._welcome.future.timeout(const Duration(seconds: 5)));
  }
}

Future<void> _until(bool Function() cond, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Uint8List bytes;
  late _FakeJellyfin jf;
  late SyncServer server;
  late HttpClient http;
  final clients = <_Client>[];

  JellyfinCredential cred({String serverId = _serverId}) => JellyfinCredential(
      baseUrl: 'http://127.0.0.1:${jf.port}/',
      serverId: serverId,
      token: _cred.token,
      client: _cred.client,
      device: _cred.device,
      deviceId: _cred.deviceId,
      version: _cred.version);

  Future<void> startServer(JellyfinCredential? c) async {
    server = SyncServer(AppConfig(port: 0, secret: '', name: 't', jellyfin: c));
    await server.start();
  }

  setUp(() async {
    bytes = Uint8List.fromList(List<int>.generate(100000, (i) => (i * 7) % 256));
    jf = await _FakeJellyfin.start(bytes);
    http = HttpClient();
  });

  tearDown(() async {
    for (final c in clients) {
      await c.ws.close();
    }
    clients.clear();
    http.close(force: true);
    await server.stop();
    await jf.close();
  });

  Future<(_Client, WelcomeMessage)> join(String name) async {
    final (c, raw) = await _Client.join(server.boundPort, name);
    clients.add(c);
    return (c, WelcomeMessage.fromJson(Map<String, Object?>.from(jsonDecode(raw) as Map)));
  }

  Map<String, Object?> refSwap(String itemId, {String? url, String serverId = _serverId}) => {
        't': 'swap',
        'media': {
          'name': 'Pilot',
          'size': 0,
          'duration': 0,
          if (url != null) 'url': url,
          'jellyfin': {
            'serverId': serverId,
            'itemId': itemId,
            'mediaSourceId': _source,
            'title': 'Pilot',
            'subtitle': 'Show - S01E01',
            'runtimeSecs': 1440.0,
          },
        },
      };

  Future<String> swapToRef(_Client c, String itemId, {String? url}) async {
    final before = c.raw.length;
    c.send(refSwap(itemId, url: url));
    late String state;
    await _until(() {
      for (final f in c.raw.skip(before)) {
        if (f.contains('"t":"state"') && f.contains(itemId)) {
          state = f;
          return true;
        }
      }
      return false;
    }, 'state with the ref');
    return state;
  }

  Future<HttpClientResponse> relayGet(String token, String itemId, {String? range}) async {
    final req = await http.get('127.0.0.1', server.boundPort, '/j/default/$token/$itemId');
    if (range != null) req.headers.set('range', range);
    return req.close();
  }

  Future<List<int>> readAll(HttpClientResponse r) async => [for (final c in await r.toList()) ...c];

  group('wire', () {
    test('ref swap: state carries the ref and relay, never a URL or token', () async {
      await startServer(cred());
      final (a, _) = await join('alice');
      final state = await swapToRef(a, _item, url: 'http://jf/Videos/x/stream?api_key=LEAK');
      final decoded = jsonDecode(state) as Map;
      expect(decoded['relay'], true);
      final media = decoded['media'] as Map;
      expect(media.containsKey('url'), isFalse);
      expect(media['jellyfin'], {
        'serverId': _serverId,
        'itemId': _item,
        'mediaSourceId': _source,
        'title': 'Pilot',
        'subtitle': 'Show - S01E01',
        'runtimeSecs': 1440.0,
      });
      expect(state, isNot(contains('LEAK')));
      expect(state, isNot(contains(_token)));
      expect(state, isNot(contains('http')));
      expect(server.session.media!.url, isNull);

      // A later joiner gets its own relay URL in welcome, no mediaUrl.
      final (_, w) = await join('bob');
      expect(w.mediaUrl, isNull);
      expect(w.relayUrl, 'http://127.0.0.1:${server.boundPort}/j/default/${w.token}/$_item');
      expect(w.state!['relay'], true);
      expect(jsonEncode(w.state), isNot(contains(_token)));
    });

    test('no relay without a credential, or for another Jellyfin server', () async {
      await startServer(cred(serverId: 'otherserver'));
      final (a, _) = await join('alice');
      final state = jsonDecode(await swapToRef(a, _item)) as Map;
      expect(state.containsKey('relay'), isFalse);
      final (_, w) = await join('bob');
      expect(w.relayUrl, isNull);
      expect((await relayGet(w.token, _item)).statusCode, 404);
    });

    test('bad ref ids are rejected', () async {
      await startServer(cred());
      final (a, _) = await join('alice');
      a.send(refSwap('../../Users'));
      await _until(() => a.raw.any((f) => f.contains('bad swap media')), 'err');
      expect(server.session.media, isNull);
    });

    test('report jf shows on the member', () async {
      await startServer(cred());
      final (a, w) = await join('alice');
      a.send(const ReportMessage(position: 0, buffered: 0, eventId: 0, jf: {_serverId: false}).toJson());
      await _until(() {
        final members = a.lastState?['members'] as List?;
        return members != null && members.any((m) => (m as Map)['jf'] != null);
      }, 'member jf');
      final m = (a.lastState!['members'] as List).cast<Map>().firstWhere((m) => m['id'] == w.memberId);
      expect(m['jf'], {_serverId: false});
    });
  });

  group('relay endpoint', () {
    late String token;

    Future<void> setUpRef(String itemId) async {
      await startServer(cred());
      final (a, w) = await join('alice');
      token = w.token;
      await swapToRef(a, itemId);
    }

    test('sends exactly the configured Authorization fields, static original stream', () async {
      await setUpRef(_item);
      final r = await relayGet(token, _item, range: 'bytes=0-9');
      await r.drain<void>();
      expect(jf.auth.single,
          'MediaBrowser Client="Watch%20Together", Device="host%20pc%20%221%22", DeviceId="dev-42", Version="0.9.0", Token="JF-SECRET-TOKEN"');
      expect(jf.uris.single.path, '/Videos/$_item/stream');
      expect(jf.uris.single.queryParameters, {'static': 'true', 'mediaSourceId': _source});
    });

    test('no Range: 200 full body, headers passed through', () async {
      await setUpRef(_item);
      final r = await relayGet(token, _item);
      expect(r.statusCode, 200);
      expect(r.headers.value('content-length'), '${bytes.length}');
      expect(r.headers.value('accept-ranges'), 'bytes');
      expect(r.headers.contentType?.mimeType, 'video/x-matroska');
      expect(await readAll(r), bytes);
      expect(jf.ranges.single, isNull);
    });

    test('closed, open-ended and suffix ranges forward and come back byte-exact', () async {
      await setUpRef(_item);
      var r = await relayGet(token, _item, range: 'bytes=100-199');
      expect(r.statusCode, 206);
      expect(r.headers.value('content-range'), 'bytes 100-199/${bytes.length}');
      expect(r.headers.value('content-length'), '100');
      expect(await readAll(r), bytes.sublist(100, 200));

      r = await relayGet(token, _item, range: 'bytes=99000-');
      expect(r.statusCode, 206);
      expect(r.headers.value('content-range'), 'bytes 99000-99999/${bytes.length}');
      expect(await readAll(r), bytes.sublist(99000));

      r = await relayGet(token, _item, range: 'bytes=-256');
      expect(r.statusCode, 206);
      expect(r.headers.value('content-range'), 'bytes 99744-99999/${bytes.length}');
      expect(await readAll(r), bytes.sublist(bytes.length - 256));
      expect(jf.ranges, ['bytes=100-199', 'bytes=99000-', 'bytes=-256']);
    });

    test('unsatisfiable range: 416 with Content-Range passed through', () async {
      await setUpRef(_item);
      final r = await relayGet(token, _item, range: 'bytes=500000-');
      expect(r.statusCode, 416);
      expect(r.headers.value('content-range'), 'bytes */${bytes.length}');
      await r.drain<void>();
    });

    test('bytes are counted as sent', () async {
      await setUpRef(_item);
      await readAll(await relayGet(token, _item, range: 'bytes=0-999'));
      await readAll(await relayGet(token, _item, range: 'bytes=-24'));
      expect(server.session.tokens[token]!.bytesServed, 1024);
    });

    test('gates: bad token 401, other item 403, unknown session 410', () async {
      await setUpRef(_item);
      expect((await relayGet('nope', _item)).statusCode, 401);
      expect((await relayGet(token, _slowItem)).statusCode, 403);
      final req = await http.get('127.0.0.1', server.boundPort, '/j/other/$token/$_item');
      expect((await req.close()).statusCode, 410);
      expect(jf.uris, isEmpty, reason: 'nothing reached Jellyfin');
    });

    test('Up next first item on the login: relayNext, and /j serves it too', () async {
      await setUpRef(_item);
      final a = clients.first;
      expect(a.lastState!.containsKey('relayNext'), isFalse);
      expect((await relayGet(token, _nextItem)).statusCode, 403);
      a.send(const QueueIntent.add(QueueItem(
              media: HelloMedia(
                  name: 'Next',
                  size: 0,
                  duration: 0,
                  jellyfin: JellyfinRef(serverId: _serverId, itemId: _nextItem, mediaSourceId: _source)),
              how: QueueHow.jellyfin,
              title: 'Next'))
          .toJson());
      await _until(() => a.lastState?['relayNext'] == true, 'relayNext');
      final res = await relayGet(token, _nextItem, range: 'bytes=0-99');
      expect(res.statusCode, 206);
      expect(await readAll(res), bytes.sublist(0, 100));
      expect((await relayGet(token, _item, range: 'bytes=0-9')).statusCode, 206, reason: 'the current one still');
      expect((await relayGet(token, _slowItem)).statusCode, 403, reason: 'nothing else');
    });

    test('non-Jellyfin media: 404', () async {
      await startServer(cred());
      final (a, w) = await join('alice');
      a.send(const SwapIntent(media: HelloMedia(name: 'x', size: 0, duration: 0, url: 'http://x/a.mkv')).toJson());
      await _until(() => server.session.media?.url != null, 'url swap');
      expect((await relayGet(w.token, _item)).statusCode, 404);
    });

    test('Jellyfin rejecting the credential is a 502, not the viewer\'s 401', () async {
      await setUpRef(_item);
      jf.status401 = 1;
      expect((await relayGet(token, _item)).statusCode, 502);
    });

    test('viewer disconnect aborts the upstream transfer', () async {
      await setUpRef(_slowItem);
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.boundPort);
      socket.write('GET /j/default/$token/$_slowItem HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-\r\n\r\n');
      var got = 0;
      final enough = Completer<void>();
      socket.listen((d) {
        got += d.length;
        if (got > 64 * 1024 && !enough.isCompleted) enough.complete();
      }, onError: (_) {}, onDone: () {});
      await enough.future.timeout(const Duration(seconds: 5));
      socket.destroy();
      await jf.slowAborted.future.timeout(const Duration(seconds: 5));
      final served = server.session.tokens[token]!.bytesServed;
      expect(served, greaterThan(0));
      expect(served, lessThan(1000000000));
    });
  });

  test('several logins (your server shared): an item goes through its own server\'s login', () async {
    await startServer(null);
    // Two linked accounts; the default one is on another Jellyfin.
    const other = JellyfinCredential(
      baseUrl: 'http://127.0.0.1:1',
      serverId: 'otherserver',
      token: 'OTHER-TOKEN',
      client: 'Watch Together',
      device: 'host pc',
      deviceId: 'dev-1',
      version: '0.9.0',
    );
    await server.share(port: 0, secret: '', jellyfin: [other, cred()]);
    expect(server.hub.jellyfinLogins.map((c) => c.serverId), ['otherserver', _serverId]);
    final (a, _) = await join('alice');
    final state = jsonDecode(await swapToRef(a, _item)) as Map;
    expect(state['relay'], true);
    final (_, w) = await join('bob');
    final r = await relayGet(w.token, _item, range: 'bytes=0-9');
    expect(r.statusCode, 206);
    expect(await readAll(r), bytes.sublist(0, 10));
    expect(jf.auth.single, contains('Token="$_token"'));
    expect(jf.auth.single, isNot(contains('OTHER-TOKEN')));
  });

  test('a credential without serverId looks it up at start', () async {
    await startServer(cred(serverId: ''));
    expect(server.hub.jellyfin!.serverId, _serverId);
  });
}
