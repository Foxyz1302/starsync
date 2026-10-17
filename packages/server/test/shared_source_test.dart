import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

// The single-fetch source (SharedSource): one upstream reader per track
// feeds this app's player (a loopback endpoint) and the upload to the
// server. Its loopback answers, a cut and a resume, seeks of either
// reader, the two kept within one window, and the memory bound.

const _mib = 1 << 20;

/// An in-memory upstream: every read logged by its start, at most
/// [rate] bytes per second when set.
class _Upstream implements RelayBytes {
  final Uint8List data;
  final int? rate;
  final reads = <int>[];
  var open = 0, maxOpen = 0, bytes = 0;
  _Upstream(this.data, {this.rate});

  @override
  Future<int> size() async => data.length;

  @override
  Stream<List<int>> read(int start, int end) async* {
    reads.add(start);
    open++;
    maxOpen = max(maxOpen, open);
    try {
      const chunk = 64 * 1024;
      for (var pos = start; pos <= end; pos += chunk) {
        final n = min(chunk, end - pos + 1);
        if (rate != null) await Future<void>.delayed(Duration(microseconds: n * 1000000 ~/ rate!));
        bytes += n;
        yield Uint8List.sublistView(data, pos, pos + n);
      }
    } finally {
      open--;
    }
  }

  @override
  Future<void> close() async {}
}

Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 7 + (i >> 16)) % 251));

Future<(HttpClientResponse, List<int>)> _get(String url, {String? range, String method = 'GET'}) async {
  final c = HttpClient();
  try {
    final req = await c.openUrl(method, Uri.parse(url));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final body = <int>[];
    await for (final b in res) {
      body.addAll(b);
    }
    return (res, body);
  } finally {
    c.close(force: true);
  }
}

Future<List<int>> _readAll(Stream<List<int>> s) async => [for (final c in await s.toList()) ...c];

/// The upload's track [i] (what the relay source reads).
Future<RelayBytes> _upload(SharedSource s, [int i = 0]) async => (await s.upload.open())[i].bytes!;

void main() {
  group('loopback endpoint', () {
    late SharedSource src;
    late Uint8List data;
    setUp(() async {
      data = _bytes(3 * _mib + 123);
      src = SharedSource(RelayMedia.single(_Upstream(data)));
      await src.start();
    });
    tearDown(() => src.close());

    test('answers ranges like the server (200, 206, suffix, 416), connection: close', () async {
      final url = src.playerUrl;
      expect(url, startsWith('http://127.0.0.1:'));

      var (res, body) = await _get(url);
      expect(res.statusCode, 200);
      expect(res.contentLength, data.length);
      expect(res.headers.value('accept-ranges'), 'bytes');
      expect(res.headers.value('connection'), 'close');
      expect(body, data);

      (res, body) = await _get(url, range: 'bytes=1000-1999');
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 1000-1999/${data.length}');
      expect(body, data.sublist(1000, 2000));

      (res, body) = await _get(url, range: 'bytes=-50');
      expect(res.statusCode, 206);
      expect(body, data.sublist(data.length - 50));

      (res, body) = await _get(url, range: 'bytes=${2 * _mib}-');
      expect(res.statusCode, 206);
      expect(body, data.sublist(2 * _mib));

      (res, body) = await _get(url, range: 'bytes=${data.length}-');
      expect(res.statusCode, 416);
      expect(res.headers.value('content-range'), 'bytes */${data.length}');

      (res, body) = await _get(url, method: 'HEAD');
      expect(res.statusCode, 200);
      expect(res.contentLength, data.length);
      expect(body, isEmpty);
    });

    test('a wrong secret or track is 404', () async {
      final u = Uri.parse(src.playerUrl);
      expect((await _get(u.replace(path: '/nope/0').toString())).$1.statusCode, 404);
      expect((await _get(u.replace(path: '${u.pathSegments[0]}/1').toString())).$1.statusCode, 404);
    });

    test('two tracks: an EDL of one loopback URL per track, no headers', () async {
      final two = SharedSource(_TwoTracks(_Upstream(_bytes(_mib)), _Upstream(_bytes(_mib ~/ 2))));
      addTearDown(two.close);
      await two.open();
      final url = two.playerUrl;
      expect(url, startsWith('edl://'));
      expect(RegExp(r'http://127\.0\.0\.1:\d+/[0-9a-f]+/[01]').allMatches(url).length, 2);
      expect([for (final t in await two.upload.open()) t.kind], ['video', 'audio']);
      expect(await (await _upload(two, 1)).size(), _mib ~/ 2);
    });

    test('the player can open before the sizes are read: the endpoint waits for them', () async {
      final slow = _SlowSize(_Upstream(data));
      final s = SharedSource(RelayMedia.single(slow));
      addTearDown(s.close);
      await s.open();
      final pending = _get(s.playerUrl, range: 'bytes=0-99');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      slow.go.complete();
      final (res, body) = await pending;
      expect(res.statusCode, 206);
      expect(body, data.sublist(0, 100));
    });
  });

  group('ResumingBytes', () {
    late HttpServer cdn;
    late Uint8List data;
    // Per request: cut after this many bytes (null: whole), or answer
    // this status.
    late List<Object?> script;
    var requests = 0;
    setUp(() async {
      data = _bytes(_mib + 77);
      requests = 0;
      cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      cdn.listen((req) async {
        final step = requests < script.length ? script[requests] : null;
        requests++;
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(req.headers.value('range') ?? '')!;
        final start = int.parse(m[1]!), end = int.parse(m[2]!);
        if (step is String) {
          req.response.statusCode = int.parse(step);
          await req.response.close();
          return;
        }
        req.response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes $start-$end/${data.length}')
          ..contentLength = end - start + 1;
        final s = await req.response.detachSocket();
        final cut = step as int?;
        if (cut == -1) {
          await s.flush();
          return; // headers only, then silence
        }
        final stop = cut == null ? end + 1 : min(end + 1, start + cut);
        s.add(data.sublist(start, stop));
        await s.flush();
        if (stop <= end) {
          s.destroy();
        } else {
          await s.close();
        }
      });
    });
    tearDown(() => cdn.close(force: true));

    HttpRelayBytes http() => HttpRelayBytes(Uri.parse('http://127.0.0.1:${cdn.port}/v.mp4'), chunkSize: 0);
    Duration quick(int _) => const Duration(milliseconds: 20);

    test('a cut goes on from the byte it reached', () async {
      script = [100000, 300000, 5];
      final r = ResumingBytes(http(), backoff: quick);
      expect(await _readAll(r.read(0, data.length - 1)), data);
      expect(r.retries, 3);
      expect(requests, 4);
      expect(r.bytesIn, data.length);
    });

    test('412, 429 and 5xx back off and try again; 403 and 404 are final', () async {
      script = ['412', '429', '503', null];
      final r = ResumingBytes(http(), backoff: quick);
      expect(await _readAll(r.read(10, 5009)), data.sublist(10, 5010));
      expect(r.retries, 3);

      for (final status in ['403', '404']) {
        script = [status];
        requests = 0;
        final f = ResumingBytes(http(), backoff: quick);
        await expectLater(_readAll(f.read(0, 99)),
            throwsA(isA<UpstreamHttpException>().having((e) => e.status, 'status', int.parse(status))));
        expect(requests, 1, reason: status);
      }
    });

    test('an answer that goes silent is cut after the stall limit and resumed', () async {
      script = [-1, null];
      final r = ResumingBytes(http(), backoff: quick, stall: const Duration(milliseconds: 300));
      final sw = Stopwatch()..start();
      expect(await _readAll(r.read(0, 199999)), data.sublist(0, 200000));
      expect(r.retries, 1);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(250));
    });

    test('cancelling stops it during a pause', () async {
      script = ['503', '503', '503'];
      final r = ResumingBytes(http(), backoff: (_) => const Duration(seconds: 30));
      final sub = r.read(0, 99).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final sw = Stopwatch()..start();
      await sub.cancel();
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(requests, 1);
    });
  });

  group('the shared buffer: seeks, one window, memory', () {
    test('cut upstream: both readers get every byte through one resuming reader', () async {
      final data = _bytes(6 * _mib);
      final up = _Cutting(data, every: 700 * 1024);
      final s = SharedSource(RelayMedia.single(up), backoff: (_) => const Duration(milliseconds: 10));
      addTearDown(s.close);
      await s.start();
      final upload = await _upload(s);
      final results = await Future.wait([
        _get(s.playerUrl).then((r) => r.$2),
        _readAll(upload.read(0, data.length - 1)),
      ]);
      expect(results[0], data);
      expect(results[1], data);
      expect(s.resumes, greaterThan(3));
      expect(up.maxOpen, 1, reason: 'one upstream reader');
      expect(up.bytes, lessThan(data.length + 3 * _mib), reason: 'each byte read about once');
    });

    test('the player seeks far ahead and back: the reader follows it, the head is kept', () async {
      final data = _bytes(40 * _mib);
      final up = _Upstream(data);
      final s = SharedSource(RelayMedia.single(up), ahead: 4 * _mib, back: _mib);
      addTearDown(s.close);
      await s.start();
      expect((await _get(s.playerUrl, range: 'bytes=0-${_mib - 1}')).$2, data.sublist(0, _mib));
      final before = up.reads.length;
      final at = 30 * _mib + 12345;
      expect((await _get(s.playerUrl, range: 'bytes=$at-${at + _mib - 1}')).$2, data.sublist(at, at + _mib));
      final seekReads = up.reads.sublist(before);
      expect(seekReads.where((r) => r >= 30 * _mib - RelayConstants.relaySliceBytes && r <= at), isNotEmpty,
          reason: 'a new upstream read at the seek: $seekReads');
      final again = up.reads.length;
      expect((await _get(s.playerUrl, range: 'bytes=1000-1999')).$2, data.sublist(1000, 2000));
      expect(up.reads.sublist(again).where((r) => r < RelayConstants.relayPinBytes), isEmpty,
          reason: 'the head is pinned: no upstream read for it');
    });

    test('player and upload reading together share one sequential read (no hand-overs)', () async {
      final data = _bytes(24 * _mib);
      final up = _Upstream(data, rate: 60 * _mib);
      final s = SharedSource(RelayMedia.single(up));
      addTearDown(s.close);
      await s.start();
      final upload = await _upload(s);
      final out = await Future.wait([
        _get(s.playerUrl).then((r) => r.$2),
        _readAll(upload.read(0, data.length - 1)),
      ]);
      expect(out[0], data);
      expect(out[1], data);
      // The tail pin, the head, then one sequential read (a slice-boundary
      // hand-over between the two would be a new read per 256 KiB).
      expect(up.reads.length, lessThanOrEqualTo(6), reason: '${up.reads}');
      expect(up.bytes, lessThanOrEqualTo(data.length + 2 * RelayConstants.relayPinBytes));
    });

    test('the upload does not run ahead of a reading player by more than the window; free once the player stops', () async {
      final data = _bytes(48 * _mib);
      final up = _Upstream(data);
      final s = SharedSource(RelayMedia.single(up), ahead: 4 * _mib, back: _mib);
      addTearDown(s.close);
      await s.start();
      final buffer = s.tracks.single.buffer;
      // The player has a request open at 0 and stops reading after its
      // first bytes (mpv with a full cache).
      final player = StreamIterator(buffer.read(SharedSource.playerViewer, 0, data.length - 1));
      expect(await player.moveNext(), isTrue);
      final upload = await _upload(s);
      final far = 30 * _mib;
      final got = <int>[];
      final sub = upload.read(far, far + _mib - 1).listen(got.addAll);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(got, isEmpty, reason: 'held: 30 MiB is past the player + 4 MiB');
      expect(up.reads.where((r) => r >= 20 * _mib && r < data.length - RelayConstants.relayPinBytes), isEmpty,
          reason: 'nothing asked upstream for it: ${up.reads}');
      await player.cancel();
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (got.length < _mib && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await sub.cancel();
      expect(got, data.sublist(far, far + _mib));
    });

    test('the player is held the same way when the upload lags; the tail is always served', () async {
      final data = _bytes(48 * _mib);
      final up = _Upstream(data);
      final s = SharedSource(RelayMedia.single(up), ahead: 4 * _mib, back: _mib);
      addTearDown(s.close);
      await s.start();
      final buffer = s.tracks.single.buffer;
      final upload = StreamIterator((await _upload(s)).read(0, data.length - 1));
      expect(await upload.moveNext(), isTrue);
      // The tail (an mp4 index) is pinned: never held.
      final tail = data.length - 1000;
      expect((await _get(s.playerUrl, range: 'bytes=$tail-')).$2, data.sublist(tail));
      final got = <int>[];
      final sub = buffer.read(SharedSource.playerViewer, 20 * _mib, 21 * _mib - 1).listen(got.addAll);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(got, isEmpty);
      await upload.cancel();
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (got.length < _mib && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await sub.cancel();
      expect(got.length, _mib);
    });

    test('memory stays within the budget while the player reads the whole media', () async {
      final data = _bytes(64 * _mib);
      final up = _Upstream(data);
      const ahead = 8 * _mib, back = 2 * _mib;
      final s = SharedSource(RelayMedia.single(up), ahead: ahead, back: back);
      addTearDown(s.close);
      await s.start();
      final buffer = s.tracks.single.buffer;
      var peak = 0;
      var n = 0;
      await for (final c in buffer.read(SharedSource.playerViewer, 0, data.length - 1)) {
        n += c.length;
        peak = max(peak, buffer.cachedBytes);
      }
      expect(n, data.length);
      expect(peak, lessThanOrEqualTo(ahead + back + 2 * RelayConstants.relayPinBytes + RelayConstants.relaySliceBytes));
    });

    test('closing under open reads ends them plainly', () async {
      final data = _bytes(8 * _mib);
      final s = SharedSource(RelayMedia.single(_Upstream(data, rate: _mib)));
      await s.start();
      final upload = await _upload(s);
      final errors = <Object>[];
      final sub = upload.read(0, data.length - 1).listen((_) {}, onError: errors.add);
      final player = _get(s.playerUrl).then((r) => r.$2.length, onError: (_) => -1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await s.close();
      await player;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(errors.every((e) => e is RelayEnded), isTrue, reason: '$errors');
    });
  });
}

class _TwoTracks implements RelayMedia {
  final RelayBytes v, a;
  _TwoTracks(this.v, this.a);
  @override
  Future<List<RelayTrack>> open() async => [RelayTrack('video', v), RelayTrack('audio', a)];
  @override
  Future<void> close() async {}
}

class _SlowSize implements RelayBytes {
  final RelayBytes inner;
  final go = Completer<void>();
  _SlowSize(this.inner);
  @override
  Future<int> size() async {
    await go.future;
    return inner.size();
  }

  @override
  Stream<List<int>> read(int start, int end) => inner.read(start, end);
  @override
  Future<void> close() => inner.close();
}

/// An upstream whose every read is cut after [every] bytes.
class _Cutting extends _Upstream {
  final int every;
  _Cutting(super.data, {required this.every});

  @override
  Stream<List<int>> read(int start, int end) async* {
    var n = 0;
    await for (final c in super.read(start, end)) {
      if (n + c.length > every) throw const HttpException('Connection closed while receiving data');
      n += c.length;
      yield c;
    }
  }
}
