import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

// The relay end to end inside one process: a real SyncServer, the real
// RelaySource from core, viewers as plain HTTP range requests.

class _Member {
  final WebSocket ws;
  final raw = <String>[];
  late WelcomeMessage welcome;
  _Member(this.ws);

  static Future<_Member> join(int port, String name, {String secret = 'pw'}) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final m = _Member(ws);
    final w = Completer<String>();
    ws.listen((f) {
      m.raw.add('$f');
      if ('$f'.contains('"t":"welcome"') && !w.isCompleted) w.complete('$f');
    }, onError: (_) {});
    ws.add(jsonEncode(HelloMessage(
      proto: RelayConstants.protoVersion,
      secret: secret,
      user: HelloUser(name: name),
      media: const HelloMedia(name: '', size: 0, duration: 0),
    ).toJson()));
    m.welcome = WelcomeMessage.fromJson(
        Map<String, Object?>.from(jsonDecode(await w.future.timeout(const Duration(seconds: 5))) as Map));
    return m;
  }

  void send(Map<String, Object?> j) => ws.add(jsonEncode(j));

  Map<String, Object?>? get lastState {
    for (final f in raw.reversed) {
      final d = jsonDecode(f) as Map;
      if (d['t'] == 'state') return Map<String, Object?>.from(d);
    }
    return null;
  }

  Map<String, Object?>? get media => lastState?['media'] as Map<String, Object?>?;
}

Future<void> _until(bool Function() cond, String what, {int secs = 5}) async {
  final deadline = DateTime.now().add(Duration(seconds: secs));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory tmp;
  late File file;
  late Uint8List bytes;
  late SyncServer server;
  late HttpClient http;
  final cleanup = <Future<void> Function()>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('relay-test');
    final rnd = Random(7);
    // 5.5 slices: exercises the short last slice.
    bytes = Uint8List.fromList(List.generate(5 * RelayBuffer.slice + 500000, (_) => rnd.nextInt(256)));
    file = File('${tmp.path}/ep 01.mkv')..writeAsBytesSync(bytes);
    server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 't'));
    await server.start();
    http = HttpClient();
  });

  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
    http.close(force: true);
    await server.stop();
    await tmp.delete(recursive: true);
  });

  Future<_Member> join(String name) async {
    final m = await _Member.join(server.boundPort, name);
    cleanup.add(() => m.ws.close());
    return m;
  }

  Future<RelaySource> startSource(_Member m, {RelayMedia? from, String? queueId}) async {
    final src = RelaySource(
        Uri.parse('ws://127.0.0.1:${server.boundPort}/r/default/${m.welcome.token}/source'
            '${queueId == null ? '' : '?q=$queueId'}'),
        from ?? RelayMedia.single(FileRelayBytes(file)),
        backoff: (_) => const Duration(milliseconds: 100));
    await src.start();
    cleanup.add(src.close);
    return src;
  }

  Future<void> swapRelay(_Member m, {String name = 'ep 01.mkv', Map<String, Object?> relay = const {}, String? url}) async {
    final before = m.raw.length;
    m.send({
      't': 'swap',
      'media': {'name': name, 'size': bytes.length, 'duration': 0, if (url != null) 'url': url, 'relay': relay},
    });
    await _until(() => m.raw.skip(before).any((f) => f.contains('"relay"') && f.contains('"t":"state"')), 'relay state');
  }

  String viewerUrl(_Member v, int mediaId) =>
      'http://127.0.0.1:${server.boundPort}/r/default/${v.welcome.token}/$mediaId/${Uri.encodeComponent('ep 01.mkv')}';

  Future<(int, Map<String, String>, List<int>)> get(String url, {String? range}) async {
    final req = await http.getUrl(Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final body = <int>[for (final c in await res.toList()) ...c];
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    return (res.statusCode, h, body);
  }

  int mediaIdOf(_Member m) => m.lastState!['mediaId'] as int;

  group('member as source', () {
    test('state names the source, no URL; live once the channel is up', () async {
      final alice = await join('alice');
      await swapRelay(alice);
      expect(alice.media!['relay'], {'source': alice.welcome.memberId});
      expect(alice.media!.containsKey('url'), isFalse);
      await startSource(alice);
      await _until(() => (alice.media?['relay'] as Map?)?['live'] == true, 'live');
    });

    test('viewers get byte-exact ranges, including the short last slice and 416', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      await swapRelay(alice);
      await startSource(alice);
      final url = viewerUrl(bob, mediaIdOf(alice));
      final n = bytes.length;
      for (final (range, start, end) in [
        (null, 0, n - 1),
        ('bytes=0-99', 0, 99),
        ('bytes=${RelayBuffer.slice - 10}-${RelayBuffer.slice + 10}', RelayBuffer.slice - 10, RelayBuffer.slice + 10),
        ('bytes=${n - 777}-', n - 777, n - 1),
        ('bytes=-333', n - 333, n - 1),
      ]) {
        final (status, h, body) = await get(url, range: range);
        expect(status, range == null ? 200 : 206, reason: '$range');
        expect(body, bytes.sublist(start, end + 1), reason: '$range');
        if (range != null) expect(h['content-range'], 'bytes $start-$end/$n');
        expect(h['content-type'], 'video/x-matroska');
      }
      final (status, h, _) = await get(url, range: 'bytes=${n + 5}-');
      expect(status, 416);
      expect(h['content-range'], 'bytes */$n');
    });

    test('a late joiner gets its own /r/ URL in welcome', () async {
      final alice = await join('alice');
      await swapRelay(alice);
      final carol = await join('carol');
      expect(carol.welcome.mediaUrl, viewerUrl(carol, mediaIdOf(alice)));
    });

    test('nobody watching: the source uploads nothing', () async {
      final alice = await join('alice');
      await swapRelay(alice);
      final src = await startSource(alice);
      await _until(() => server.hub.relay!.live, 'live');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(src.bytesSent, 0);
    });

    test('several viewers: each byte crosses the source link about once', () async {
      final alice = await join('alice');
      final viewers = [for (final n in ['b', 'c', 'd']) await join(n)];
      await swapRelay(alice);
      final src = await startSource(alice);
      final id = mediaIdOf(alice);
      final got = await Future.wait([for (final v in viewers) get(viewerUrl(v, id))]);
      for (final (status, _, body) in got) {
        expect(status, 200);
        expect(body.length, bytes.length);
      }
      expect(src.bytesSent, lessThan(bytes.length * 1.3));
    });

    test('only the source may open the channel', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      await swapRelay(alice);
      final impostor = await startSource(bob);
      await impostor.done.timeout(const Duration(seconds: 5));
      expect(server.hub.relay!.live, isFalse);
    });

    test('a new swap drops the buffer, old URLs 404, the source stops', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      await swapRelay(alice);
      final src = await startSource(alice);
      final oldId = mediaIdOf(alice);
      expect((await get(viewerUrl(bob, oldId), range: 'bytes=0-9')).$1, 206);
      final buf = server.hub.relay!.buffers.single;
      alice.send({
        't': 'swap',
        'media': {'name': 'x', 'size': 0, 'duration': 0, 'url': 'http://example.invalid/x.mkv'},
      });
      await _until(() => mediaIdOf(alice) != oldId, 'swap');
      expect(server.hub.relay, isNull);
      expect(buf.cachedBytes, 0);
      await src.done.timeout(const Duration(seconds: 5));
      expect((await get(viewerUrl(bob, oldId), range: 'bytes=0-9')).$1, 404);
    });

    test('server stop drops the relay', () async {
      final alice = await join('alice');
      await swapRelay(alice);
      final buf = server.hub.relay!.buffers.single;
      await server.stop();
      expect(server.hub.relay, isNull);
      expect(buf.cachedBytes, 0);
      server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 't'));
      await server.start();
    });

    test('source drops and comes back: buffered bytes keep serving, the rest resumes', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      await swapRelay(alice);
      final src = await startSource(alice);
      final url = viewerUrl(bob, mediaIdOf(alice));
      expect((await get(url, range: 'bytes=0-${RelayBuffer.slice * 2 - 1}')).$3,
          bytes.sublist(0, RelayBuffer.slice * 2));
      await src.close();
      await src.done;
      await _until(() => !server.hub.relay!.live, 'down');
      expect((await get(url, range: 'bytes=0-99')).$3, bytes.sublist(0, 100));
      final pending = get(url, range: 'bytes=${RelayBuffer.slice * 4}-');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await startSource(alice);
      final (status, _, body) = await pending.timeout(const Duration(seconds: 10));
      expect(status, 206);
      expect(body, bytes.sublist(RelayBuffer.slice * 4));
    });

    test('two tracks: each byte-exact at its own URL, welcome is an EDL of both', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      final audio = Uint8List.fromList(List.generate(RelayBuffer.slice + 1234, (i) => i * 7 % 256));
      final audioFile = File('${tmp.path}/a.m4a')..writeAsBytesSync(audio);
      await swapRelay(alice, relay: {
        'tracks': [
          {'kind': 'video'},
          {'kind': 'audio'},
        ],
      });
      expect((alice.media!['relay'] as Map)['tracks'], [
        {'kind': 'video'},
        {'kind': 'audio'},
      ]);
      await startSource(alice,
          from: _Tracks([RelayTrack('video', FileRelayBytes(file)), RelayTrack('audio', FileRelayBytes(audioFile))]));
      final id = mediaIdOf(alice);
      final base = 'http://127.0.0.1:${server.boundPort}/r/default/${bob.welcome.token}/$id';
      final name = Uri.encodeComponent('ep 01.mkv');
      final (vs, _, v) = await get('$base/0/$name', range: 'bytes=1000-');
      final (aStatus, _, a) = await get('$base/1/$name');
      expect((vs, aStatus), (206, 200));
      expect(v, bytes.sublist(1000));
      expect(a, audio);
      // The single-file URL and a track past the end are not this media.
      expect((await get('$base/$name')).$1, 404);
      expect((await get('$base/2/$name')).$1, 404);
      final carol = await join('carol');
      final carolBase = base.replaceFirst(bob.welcome.token, carol.welcome.token);
      expect(carol.welcome.mediaUrl, mpvEdl(['$carolBase/0/$name', '$carolBase/1/$name']));
    });

    test('a pieces track and a bytes track: playlist, whole pieces, Range inside a piece', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      await swapRelay(alice, relay: {
        'tracks': [
          {'kind': 'video', 'as': 'pieces'},
          {'kind': 'audio'},
        ],
      });
      final pieces = [for (var i = 0; i < 4; i++) Uint8List.fromList(List.generate(1000 + i, (j) => (i * 31 + j) % 256))];
      final shape = RelayPieceList([
        const RelayPiece.init(),
        for (var i = 1; i < 4; i++) const RelayPiece.segment(6, map: 0),
      ]);
      final reads = <int>[];
      await startSource(alice,
          from: _Tracks([
            RelayTrack.pieces('video', _MemPieces(shape, pieces, reads)),
            RelayTrack('audio', FileRelayBytes(file)),
          ]));
      final id = mediaIdOf(alice);
      final base = 'http://127.0.0.1:${server.boundPort}/r/default/${bob.welcome.token}/$id';
      final name = Uri.encodeComponent('ep 01.mkv');
      final (ps, ph, playlist) = await get('$base/0/$name.m3u8');
      expect(ps, 200);
      expect(ph['content-type'], startsWith('application/vnd.apple.mpegurl'));
      expect(utf8.decode(playlist), shape.playlist());
      expect((await get('$base/0/p/2')).$3, pieces[2]);
      final (rs, rh, part) = await get('$base/0/p/3', range: 'bytes=10-19');
      expect((rs, rh['content-range']), (206, 'bytes 10-19/1003'));
      expect(part, pieces[3].sublist(10, 20));
      expect((await get('$base/1/$name', range: 'bytes=5-')).$3, bytes.sublist(5));
      expect((await get('$base/0/p/4')).$1, 404);
      expect((await get('$base/1/p/0')).$1, 404);
      expect(reads, isNot(contains(-1)));
      final carol = await join('carol');
      final carolBase = base.replaceFirst(bob.welcome.token, carol.welcome.token);
      expect(carol.welcome.mediaUrl, mpvEdl(['$carolBase/0/$name.m3u8', '$carolBase/1/$name']));
    });

    test('Jellyfin swap can carry a relay', () async {
      final alice = await join('alice');
      final before = alice.raw.length;
      alice.send({
        't': 'swap',
        'media': {
          'name': 'Pilot',
          'size': 0,
          'duration': 0,
          'jellyfin': {'serverId': 'srv1', 'itemId': '0123456789abcdef0123456789abcdef', 'title': 'Pilot'},
          'relay': {},
        },
      });
      await _until(() => alice.raw.skip(before).any((f) => f.contains('"jellyfin"')), 'state');
      expect(alice.media!['relay'], {'source': alice.welcome.memberId});
      expect(server.hub.relay!.sourceToken, alice.welcome.token);
    });
  });

  group('server fetches the link', () {
    late HttpServer origin;
    final ranges = <(String, int)>[];
    setUp(() async {
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      ranges.clear();
      origin.listen((req) async {
        if (req.uri.path == '/watch') {
          req.response.headers.contentType = ContentType.html;
          req.response.write('<title>page</title>');
          await req.response.close();
          return;
        }
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(req.headers.value('range') ?? '');
        if (m != null) ranges.add((req.uri.path, int.parse(m.group(2)!) - int.parse(m.group(1)!) + 1));
        final r = resolveMediaRequest(
            rangeHeader: req.headers.value('range'), size: bytes.length, filename: 'x.mkv');
        req.response.statusCode = r.status;
        r.headers.forEach(req.response.headers.set);
        if (r.status == 200 || r.status == 206) {
          final end = r.end ?? bytes.length - 1;
          req.response.add(bytes.sublist(r.start, end + 1));
        }
        await req.response.close();
      });
    });
    tearDown(() => origin.close(force: true));

    test('byte-exact, the link is never broadcast', () async {
      final alice = await join('alice');
      final link = 'http://127.0.0.1:${origin.port}/secret/file.mkv?api_key=KEY';
      await swapRelay(alice, relay: {'fetch': true}, url: link);
      expect(jsonEncode(alice.lastState), isNot(contains('KEY')));
      await _until(() => server.hub.relay!.live, 'live');
      final bob = await join('bob');
      expect(jsonEncode(bob.welcome.toJson()), isNot(contains('KEY')));
      final (status, _, body) = await get(bob.welcome.mediaUrl!, range: 'bytes=1000-');
      expect(status, 206);
      expect(body, bytes.sublist(1000));
    });

    test('a page with separate video and audio: two tracks, read in chunks', () async {
      final alice = await join('alice');
      final y = _FakeYtDlp(tmp.path, [
        (
          kind: 'video',
          format: YtDlpFormat(id: 'v', url: Uri.parse('http://127.0.0.1:${origin.port}/v.mp4'), chunkSize: 300000),
        ),
        (kind: 'audio', format: YtDlpFormat(id: 'a', url: Uri.parse('http://127.0.0.1:${origin.port}/a.m4a'))),
      ]);
      await server.stop();
      server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 't'), ytDlp: y);
      await server.start();
      final m = await _Member.join(server.boundPort, 'alice');
      cleanup.add(() => m.ws.close());
      await alice.ws.close();
      await swapRelay(m, relay: {'fetch': true}, url: 'http://127.0.0.1:${origin.port}/watch?v=1');
      await _until(() => (m.media?['relay'] as Map?)?['live'] == true, 'live');
      expect((m.media!['relay'] as Map)['tracks'], [
        {'kind': 'video'},
        {'kind': 'audio'},
      ]);
      final bob = await _Member.join(server.boundPort, 'bob');
      cleanup.add(() => bob.ws.close());
      final url = bob.welcome.mediaUrl!;
      expect(url, startsWith('edl://!no_clip;%'));
      final parts = RegExp(r'%\d+%([^;]+)').allMatches(url).map((x) => x.group(1)!).toList();
      expect(parts, hasLength(2));
      expect((await get(parts[0])).$3, bytes);
      expect((await get(parts[1], range: 'bytes=5-')).$3, bytes.sublist(5));
      // The 300 000-byte chunk size: no upstream GET for the video asked for more.
      expect(ranges.where((r) => r.$1 == '/v.mp4').every((r) => r.$2 <= 300000), isTrue);
    });

    test('an open server (no password) refuses to fetch', () async {
      await server.stop();
      server = SyncServer(const AppConfig(port: 0, secret: '', name: 'open'));
      await server.start();
      final m = await _Member.join(server.boundPort, 'mallory', secret: '');
      cleanup.add(() => m.ws.close());
      m.send({
        't': 'swap',
        'media': {
          'name': 'x', 'size': 0, 'duration': 0,
          'url': 'http://127.0.0.1:${origin.port}/x.mkv', 'relay': {'fetch': true},
        },
      });
      await _until(() => m.raw.any((f) => f.contains('server fetch needs a server password')), 'err');
      expect(server.hub.relay, isNull);
    });

    test('a non-http link is refused', () async {
      final alice = await join('alice');
      alice.send({
        't': 'swap',
        'media': {'name': 'x', 'size': 0, 'duration': 0, 'url': 'file:///etc/passwd', 'relay': {'fetch': true}},
      });
      await _until(() => alice.raw.any((f) => f.contains('relay fetch needs')), 'err');
      expect(server.hub.relay, isNull);
    });
  });

  group('warm relay (Up next)', () {
    late HttpServer origin;
    var originBytes = 0;
    setUp(() async {
      originBytes = 0;
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((req) async {
        final r = resolveMediaRequest(rangeHeader: req.headers.value('range'), size: bytes.length, filename: 'x.mkv');
        req.response.statusCode = r.status;
        r.headers.forEach(req.response.headers.set);
        if (r.status == 200 || r.status == 206) {
          final end = r.end ?? bytes.length - 1;
          originBytes += end - r.start + 1;
          req.response.add(bytes.sublist(r.start, end + 1));
        }
        await req.response.close();
      });
    });
    tearDown(() => origin.close(force: true));

    List<Map> queueOf(_Member m) => [for (final q in (m.lastState?['queue'] as List?) ?? const []) q as Map];
    Map? headRelay(_Member m) => (queueOf(m).firstOrNull?['media'] as Map?)?['relay'] as Map?;

    Future<String> add(_Member m, Map<String, Object?> item, {bool next = false}) async {
      final had = {for (final q in queueOf(m)) q['id']};
      m.send({'t': 'queue', 'op': 'add', 'at': next ? 'next' : 'end', 'item': item});
      await _until(() => queueOf(m).any((q) => !had.contains(q['id'])), 'queued');
      return queueOf(m).firstWhere((q) => !had.contains(q['id']))['id'] as String;
    }

    Map<String, Object?> through(String key) => {
          'media': {'name': 'ep 01.mkv', 'size': bytes.length, 'duration': 0},
          'how': 'through',
          'title': 'Ep 1',
          'key': key,
        };

    String qUrl(_Member v, String queueId) =>
        'http://127.0.0.1:${server.boundPort}/r/default/${v.welcome.token}/$queueId/${Uri.encodeComponent('ep 01.mkv')}';

    test('a link the server fetches: preloaded from its queue id, promoted at the swap with its buffer', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      final id = await add(alice, {
        'media': {'name': 'ep 01.mkv', 'size': 0, 'duration': 0, 'url': 'http://127.0.0.1:${origin.port}/x.mkv'},
        'how': 'server',
        'title': 'Ep 1',
      });
      await _until(() => headRelay(bob)?['live'] == true, 'warm relay live');
      expect(headRelay(bob), {'fetch': true, 'live': true});
      expect(jsonEncode(bob.lastState), isNot(contains('x.mkv')));
      expect((await get(qUrl(bob, id))).$3, bytes);
      // Small: the warm budget is far over this file, so all of it is in.
      final fetched = originBytes;
      alice.send({
        't': 'swap',
        'queueId': id,
        'media': {'name': 'Ep 1', 'size': 0, 'duration': 0, 'relay': {'fetch': true}},
      });
      await _until(() => (bob.media?['relay'] as Map?)?['queueId'] == id, 'promoted');
      expect(bob.media!['relay'], {'fetch': true, 'live': true, 'queueId': id});
      expect(bob.media!['name'], 'ep 01.mkv', reason: 'the URL name the preload used');
      expect(queueOf(bob), isEmpty);
      expect(server.hub.warm, isNull);
      // The same buffer: both URLs serve it, nothing is fetched again.
      expect((await get(qUrl(bob, id))).$3, bytes);
      expect((await get(viewerUrl(bob, mediaIdOf(bob)))).$3, bytes);
      expect(originBytes, fetched);
      final carol = await join('carol');
      expect(carol.welcome.mediaUrl, qUrl(carol, id));
    });

    test('a link passed on: its adder feeds it before the swap, and the swap keeps that source', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      final id = await add(alice, through('k-abcdefgh'));
      expect(headRelay(bob), {'source': alice.welcome.memberId});
      final src = await startSource(alice, queueId: id);
      await _until(() => headRelay(bob)?['live'] == true, 'warm relay live');
      expect((await get(qUrl(bob, id), range: 'bytes=0-99')).$3, bytes.sublist(0, 100));
      // Only its source may feed it.
      final impostor = await startSource(bob, queueId: id);
      await impostor.done.timeout(const Duration(seconds: 5));
      alice.send({
        't': 'swap',
        'queueId': id,
        'media': {'name': 'ep 01.mkv', 'size': bytes.length, 'duration': 0, 'relay': {}},
      });
      await _until(() => (bob.media?['relay'] as Map?)?['queueId'] == id, 'promoted');
      expect(bob.media!['relay'], {'source': alice.welcome.memberId, 'live': true, 'queueId': id});
      expect((await get(qUrl(bob, id))).$3, bytes);
      expect(src.bytesSent, lessThan(bytes.length * 1.3));
      // Still the source of the media it now relays.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.hub.relay!.live, isTrue);
    });

    test('dropped when the item stops being first: its URLs 404, its source stops', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      final id = await add(alice, through('k-abcdefgh'));
      final src = await startSource(alice, queueId: id);
      await _until(() => headRelay(bob)?['live'] == true, 'warm relay live');
      await add(alice, through('k-ijklmnop'), next: true);
      await src.done.timeout(const Duration(seconds: 5));
      expect((await get(qUrl(bob, id))).$1, 404);
      expect(server.hub.warm!.queueId, isNot(id));
    });

    test('not for an adder alone; dropped when its adder leaves', () async {
      final alice = await join('alice');
      await add(alice, through('k-abcdefgh'));
      expect(headRelay(alice), isNull);
      final bob = await join('bob');
      await _until(() => headRelay(bob) != null, 'warm relay once someone could read it');
      await alice.ws.close();
      await _until(() => bob.lastState!['members'] is List && (bob.lastState!['members'] as List).length == 1, 'left');
      expect(queueOf(bob), hasLength(1));
      expect(headRelay(bob), isNull);
      expect(server.hub.warm, isNull);
    });

    test('a Jellyfin item: fed by the first member with an account, for those without', () async {
      final alice = await join('alice');
      final bob = await join('bob');
      void report(_Member m, bool access) => m.send({
            't': 'report', 'position': 0, 'buffered': 0, 'eventId': 0, 'jf': {'srv1': access}, //
          });
      report(alice, true);
      report(bob, false);
      final id = await add(alice, {
        'media': {
          'name': 'Pilot',
          'size': 0,
          'duration': 0,
          'jellyfin': {'serverId': 'srv1', 'itemId': '0123456789abcdef0123456789abcdef', 'title': 'Pilot'},
        },
        'how': 'jellyfin',
        'title': 'Pilot',
      });
      await _until(() => headRelay(bob) != null, 'warm relay');
      expect(headRelay(bob), isEmpty, reason: 'nobody feeds it yet');
      final refused = await startSource(bob, queueId: id);
      await refused.done.timeout(const Duration(seconds: 5));
      await startSource(alice, queueId: id);
      await _until(() => headRelay(bob)?['live'] == true, 'live');
      expect(headRelay(bob)!['source'], alice.welcome.memberId);
      report(bob, true);
      await _until(() => headRelay(alice) == null, 'dropped once everyone has an account');
    });
  });

  group('buffer', () {
    // A feed that serves [bytes] in-process and counts what it sends.
    late RelayBuffer buf;
    late LocalRelayFeed feed;
    late _CountingBytes counted;
    setUp(() {
      buf = RelayBuffer(ahead: 2 * RelayBuffer.slice, back: RelayBuffer.slice, pin: RelayBuffer.slice);
      counted = _CountingBytes(FileRelayBytes(file));
      feed = LocalRelayFeed(RelayTrack('', counted), buf);
      buf.attach(feed, bytes.length);
    });
    tearDown(() async {
      buf.dispose();
      await feed.close();
    });

    Future<List<int>> read(String v, int start, int end) async =>
        [for (final c in await buf.read(v, start, end).toList()) ...c];

    test('keeps pinned head/tail plus a window around the viewer', () async {
      expect(await read('a', 0, bytes.length - 1), bytes);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // ahead 2 + back 1 + 2 pinned slices: never all 6.
      expect(buf.cachedBytes, lessThanOrEqualTo(5 * RelayBuffer.slice));
    });

    test('a superseded request does not hold the feed', () async {
      // Like mpv after a seek: the old request stays open, unread.
      final old = buf.read('a', 0, bytes.length - 1).listen((_) {})..pause();
      final s = 3 * RelayBuffer.slice;
      expect(await read('a', s, s + 999).timeout(const Duration(seconds: 5)), bytes.sublist(s, s + 1000));
      await old.cancel();
    });

    test('dispose frees everything and ends waiting readers', () async {
      await read('a', 0, 10);
      buf.dispose();
      expect(buf.cachedBytes, 0);
    });
  });
}

class _CountingBytes implements RelayBytes {
  final RelayBytes inner;
  int sent = 0;
  _CountingBytes(this.inner);
  @override
  Future<int> size() => inner.size();
  @override
  Stream<List<int>> read(int start, int end) => inner.read(start, end).map((c) {
        sent += c.length;
        return c;
      });
  @override
  Future<void> close() => inner.close();
}

class _Tracks implements RelayMedia {
  final List<RelayTrack> tracks;
  _Tracks(this.tracks);
  @override
  Future<List<RelayTrack>> open() async => tracks;
  @override
  Future<void> close() async {}
}

/// A pieces track from memory; [reads] logs the pieces pulled.
class _MemPieces implements RelayPieces {
  final RelayPieceList shape;
  final List<Uint8List> data;
  final List<int> reads;
  _MemPieces(this.shape, this.data, this.reads);
  @override
  Future<RelayPieceList> list() async => shape;
  @override
  Stream<List<int>> read(int index) async* {
    reads.add(index);
    yield data[index];
  }

  @override
  Future<void> close() async {}
}

/// yt-dlp that "resolves" any page to [tracks].
class _FakeYtDlp extends YtDlp {
  final List<YtDlpTrack> tracks;
  _FakeYtDlp(super.dir, this.tracks);
  @override
  Future<YtDlpInfo> resolve(String url, {Duration timeout = const Duration(seconds: 25)}) async =>
      YtDlpInfo(title: 'page', tracks: tracks, formats: {for (final t in tracks) t.format.id: t.format});
}
