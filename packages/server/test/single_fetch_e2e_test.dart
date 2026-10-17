import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

// The single-fetch source against the two-fetch one: a member passes on
// a page with separate video and audio, served by a fake CDN that can cut
// connections and refuse a busy client (412). Two ways of being the
// source, the same server, real mpv players (headless, the app's pins):
//
//   today   the source's player reads the CDN itself (EDL + headers); the
//           relay source range-reads the CDN again per server pull (what
//           a page with pieces tracks still does).
//   single  one shared reader per track (SharedSource) feeds the
//           source's player (loopback EDL) and the server's pulls.
//
// Each run plays [play] s from the source's first frame, then both
// players seek to 45 s and back to 5 s (as a shared seek does) and the
// time until each plays there is taken.
//
// Opt-in (minutes, needs mpv and ffmpeg): WT_SINGLE_FETCH=1
//   dart test test/single_fetch_e2e_test.dart -r expanded
// WT_SF_SCENARIOS=clean,cuts,lockout,slow and WT_SF_PLAY=<secs> narrow a run.

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;
final _enabled = Platform.environment['WT_SINGLE_FETCH'] == '1';

Future<(String, String)> _media() async {
  final v = '$_tmp/single_fetch_v.mp4', a = '$_tmp/single_fetch_a.m4a';
  if (!await File(v).exists()) {
    final r = await Process.run('ffmpeg', [
      '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30', '-t', '60', '-an',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '4M', '-minrate', '4M', '-maxrate', '4M',
      '-bufsize', '2M', '-g', '30', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', v,
    ]);
    if (r.exitCode != 0) fail('ffmpeg video: ${r.stderr}');
  }
  if (!await File(a).exists()) {
    final r = await Process.run('ffmpeg', [
      '-y', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '60',
      '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', a,
    ]);
    if (r.exitCode != 0) fail('ffmpeg audio: ${r.stderr}');
  }
  return (v, a);
}

class CdnRequest {
  final double at;
  final String path, who, range;
  final int status;
  int sent = 0;
  bool cut = false;
  CdnRequest(this.at, this.path, this.who, this.range, this.status);
}

/// A CDN in the Bilibili mould: Range GETs of two files, Referer
/// required (403 without), a per-connection rate, an optional cut of
/// every answer after a random 0..[cutMax] bytes, and an optional
/// lockout: more than [lockoutBurst] requests in 10 s and every request
/// gets 412 for [lockoutFor].
class FakeCdn {
  final Map<String, List<int>> files;
  final int bytesPerSec;
  final Duration firstByte;
  final int? cutMax;
  final int? lockoutBurst;
  final Duration lockoutFor;
  final _rnd = Random(42);
  final clock = Stopwatch()..start();
  late HttpServer _http;
  final requests = <CdnRequest>[];
  final open = <String, int>{}, maxOpen = <String, int>{};
  double _lockedUntil = -1;
  int lockouts = 0;

  FakeCdn(this.files,
      {this.bytesPerSec = 3 << 20,
      this.firstByte = const Duration(milliseconds: 40),
      this.cutMax,
      this.lockoutBurst,
      this.lockoutFor = const Duration(seconds: 10)});

  int get port => _http.port;
  String url(String path) => 'http://127.0.0.1:$port/$path?sig=abc';
  static const headers = {'Referer': 'https://www.example-video.site/', 'User-Agent': 'Mozilla/5.0 test'};

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((req) => unawaited(_serve(req)));
  }

  Future<void> close() => _http.close(force: true);

  double get now => clock.elapsedMicroseconds / 1e6;

  Future<void> _serve(HttpRequest req) async {
    final path = req.uri.pathSegments.isEmpty ? '' : req.uri.pathSegments.first;
    final who = req.headers.value('x-who') ?? 'player';
    final range = req.headers.value(HttpHeaders.rangeHeader) ?? '';
    final data = files[path];
    final t = now;
    final recent = requests.where((r) => r.at > t - 10).length;
    int status;
    if (data == null) {
      status = 404;
    } else if (req.headers.value('referer') == null) {
      status = 403;
    } else if (t < _lockedUntil) {
      status = 412;
    } else if (lockoutBurst != null && recent >= lockoutBurst!) {
      _lockedUntil = t + lockoutFor.inMicroseconds / 1e6;
      lockouts++;
      status = 412;
    } else {
      status = 206;
    }
    final log = CdnRequest(t, path, who, range, status);
    requests.add(log);
    final res = req.response;
    if (status != 206) {
      res.statusCode = status;
      await res.close();
      return;
    }
    final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    var start = 0, end = data!.length - 1;
    if (m != null) {
      if (m[1]!.isEmpty) {
        start = max(0, data.length - int.parse(m[2]!));
      } else {
        start = int.parse(m[1]!);
        if (m[2]!.isNotEmpty) end = min(end, int.parse(m[2]!));
      }
    }
    if (start >= data.length) {
      res.statusCode = 416;
      await res.close();
      return;
    }
    res.statusCode = m == null ? 200 : 206;
    res.headers
      ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.connectionHeader, 'close')
      ..contentLength = end - start + 1;
    if (m != null) res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${data.length}');
    open[path] = (open[path] ?? 0) + 1;
    maxOpen[path] = max(maxOpen[path] ?? 0, open[path]!);
    final cutAt = cutMax == null ? null : _rnd.nextInt(cutMax!);
    Socket? s;
    try {
      await Future<void>.delayed(firstByte);
      s = await res.detachSocket(writeHeaders: true);
      final sw = Stopwatch()..start();
      var pos = start;
      const chunk = 16 * 1024;
      while (pos <= end) {
        var n = min(chunk, end - pos + 1);
        if (cutAt != null && log.sent + n > cutAt) {
          n = cutAt - log.sent;
          if (n > 0) s.add(data.sublist(pos, pos + n));
          log.sent += max(0, n);
          await s.flush();
          log.cut = true;
          s.destroy();
          return;
        }
        s.add(data.sublist(pos, pos + n));
        await s.flush();
        pos += n;
        log.sent += n;
        final ahead = log.sent / bytesPerSec - sw.elapsedMicroseconds / 1e6;
        if (ahead > 0.002) await Future<void>.delayed(Duration(microseconds: (ahead * 1e6).round()));
      }
      await s.close();
    } catch (_) {
      // The client went away (a seek, a cancelled pull).
      s?.destroy();
    } finally {
      open[path] = open[path]! - 1;
    }
  }
}

/// A headless mpv with the app's pins, watched over its JSON IPC.
class Probe {
  final String label;
  final Stopwatch clock;
  final double startedAt;
  late Process _proc;
  Socket? _ipc;
  double? firstFrame; // seconds on [clock]
  double pos = 0;
  var stalls = 0;
  double stalled = 0;
  double? _stallSince;
  final errors = <String>[];
  Probe(this.label, this.clock) : startedAt = clock.elapsedMicroseconds / 1e6;

  double get _now => clock.elapsedMicroseconds / 1e6;

  static Future<Probe> start(String label, String url, Stopwatch clock, {Map<String, String> headers = const {}}) async {
    final p = Probe(label, clock);
    final sock = '$_tmp/sf-${label.hashCode}-${DateTime.now().microsecondsSinceEpoch}.sock';
    p._proc = await Process.start('mpv', [
      '--no-config', '--vo=null', '--ao=null', '--idle=no', '--keep-open=yes', '--input-ipc-server=$sock',
      '--cache=yes', '--demuxer-max-bytes=268435456', '--demuxer-max-back-bytes=67108864',
      '--demuxer-readahead-secs=150', '--cache-secs=150', '--ytdl=no', '--network-timeout=5',
      '--stream-lavf-o=reconnect_streamed=1,reconnect_on_http_error=5xx,reconnect_delay_max=4,reconnect_max_retries=3',
      '--msg-level=all=warn',
      if (headers.isNotEmpty) '--http-header-fields=${headers.entries.map((e) => '${e.key}: ${e.value}').join(',')}',
      url,
    ]);
    p._proc.stdout.drain<void>();
    p._proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (p.errors.length < 40) p.errors.add(l);
    });
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      try {
        p._ipc = await Socket.connect(InternetAddress(sock, type: InternetAddressType.unix), 0);
        break;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    p._ipc!.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(p._on, onError: (_) {});
    p._send(['observe_property', 1, 'time-pos']);
    p._send(['observe_property', 2, 'paused-for-cache']);
    return p;
  }

  void _send(List<Object> cmd) => _ipc?.write('${jsonEncode({'command': cmd})}\n');

  void _on(String line) {
    final Map j;
    try {
      j = jsonDecode(line) as Map;
    } catch (_) {
      return;
    }
    switch (j['event']) {
      case 'playback-restart':
        firstFrame ??= _now;
      case 'property-change':
        if (j['name'] == 'time-pos' && j['data'] is num) pos = (j['data'] as num).toDouble();
        if (j['name'] == 'paused-for-cache' && firstFrame != null) {
          if (j['data'] == true && _stallSince == null) {
            _stallSince = _now;
            stalls++;
          } else if (j['data'] == false && _stallSince != null) {
            stalled += _now - _stallSince!;
            _stallSince = null;
          }
        }
      case 'end-file':
        if (j['reason'] == 'error') errors.add('end-file error ${j['file_error'] ?? ''}');
    }
  }

  double get stalledNow => stalled + (_stallSince == null ? 0 : _now - _stallSince!);

  /// Seeks to [to] s; the seconds until it plays there (null: not within
  /// [limit]).
  Future<double?> seek(double to, {Duration limit = const Duration(seconds: 20)}) async {
    final t0 = _now;
    _send(['seek', to, 'absolute']);
    final end = DateTime.now().add(limit);
    // Past the target and not waiting for the cache.
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (pos >= to + 0.3 && pos < to + 5 && _stallSince == null) return _now - t0;
    }
    return null;
  }

  Future<void> stop() async {
    _send(['quit']);
    await _proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      _proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    await _ipc?.close().catchError((_) {});
  }
}

class _Member {
  final WebSocket ws;
  final raw = <String>[];
  late WelcomeMessage welcome;
  _Member(this.ws);

  static Future<_Member> join(int port, String name) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final m = _Member(ws);
    final w = Completer<String>();
    ws.listen((f) {
      m.raw.add('$f');
      if ('$f'.contains('"t":"welcome"') && !w.isCompleted) w.complete('$f');
    }, onError: (_) {});
    ws.add(jsonEncode(
        HelloMessage(proto: RelayConstants.protoVersion, secret: 'pw', user: HelloUser(name: name)).toJson()));
    m.welcome = WelcomeMessage.fromJson(
        Map<String, Object?>.from(jsonDecode(await w.future.timeout(const Duration(seconds: 5))) as Map));
    return m;
  }

  Map<String, Object?>? get lastState {
    for (final f in raw.reversed) {
      final d = jsonDecode(f) as Map;
      if (d['t'] == 'state') return Map<String, Object?>.from(d);
    }
    return null;
  }

  Map<String, Object?>? get relay => (lastState?['media'] as Map?)?['relay'] as Map<String, Object?>?;
}

class _Tracks implements RelayMedia {
  final List<RelayTrack> tracks;
  _Tracks(this.tracks);
  @override
  Future<List<RelayTrack>> open() async => tracks;
  @override
  Future<void> close() async {
    for (final t in tracks) {
      await t.bytes?.close();
    }
  }
}

/// One run: [mode] `today` or `single` against [cdn] for [play] seconds
/// after the source's first frame.
Future<Map<String, Object?>> _run(String mode, FakeCdn cdn, int play) async {
  final server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 't'));
  await server.start();
  final alice = await _Member.join(server.boundPort, 'alice');
  final bob = await _Member.join(server.boundPort, 'bob');
  alice.ws.add(jsonEncode({
    't': 'swap',
    'media': {
      'name': 'page',
      'duration': 60,
      'relay': {
        'tracks': [
          {'kind': 'video'},
          {'kind': 'audio'},
        ],
      },
    },
  }));
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (alice.relay == null) {
    if (DateTime.now().isAfter(until)) fail('no relay state');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final mediaId = alice.lastState!['mediaId'] as int;
  final sourceUrl = Uri.parse('ws://127.0.0.1:${server.boundPort}/r/default/${alice.welcome.token}/source');
  RelayTrack upstream(String kind, String path) => RelayTrack(
      kind, HttpRelayBytes(Uri.parse(cdn.url(path)), headers: {...FakeCdn.headers, 'X-Who': 'relay'}));
  final upstreamMedia = _Tracks([upstream('video', 'v'), upstream('audio', 'a')]);

  final clock = Stopwatch()..start();
  final reqBefore = cdn.requests.length;
  RelaySource source;
  SharedSource? shared;
  Probe sourcePlayer;
  if (mode == 'today') {
    // As switchTo does: the relay source first (not awaited), then the
    // player on the CDN's URLs with the page's headers.
    source = RelaySource(sourceUrl, upstreamMedia, name: 'page', duration: 60);
    unawaited(source.start());
    sourcePlayer = await Probe.start('source', mpvEdl([cdn.url('v'), cdn.url('a')]), clock,
        headers: {...FakeCdn.headers, 'X-Who': 'player'});
  } else {
    // As the app does: the player opens at once (the loopback endpoint
    // waits for the sizes), the relay source starts meanwhile.
    shared = SharedSource(upstreamMedia);
    await shared.open();
    source = RelaySource(sourceUrl, shared.upload, name: 'page', duration: 60);
    unawaited(source.start());
    sourcePlayer = await Probe.start('source', shared.playerUrl, clock);
  }
  // Viewers open once the relay is live (relayWaitsForSource).
  while (bob.relay?['live'] != true) {
    if (clock.elapsed > const Duration(seconds: 20)) fail('relay never live');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final liveAt = clock.elapsedMicroseconds / 1e6;
  final base = 'http://127.0.0.1:${server.boundPort}/r/default/${bob.welcome.token}/$mediaId';
  final viewer = await Probe.start('viewer', mpvEdl(['$base/0/page', '$base/1/page']), clock);

  // Play: both from their first frame, no sync engine (stalls show as lag).
  var sharedPeak = 0;
  final peakTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (shared != null) sharedPeak = max(sharedPeak, shared.cachedBytes);
  });
  final end = DateTime.now().add(Duration(seconds: play + 15));
  while (DateTime.now().isBefore(end)) {
    if (sourcePlayer.firstFrame != null && clock.elapsedMicroseconds / 1e6 > sourcePlayer.firstFrame! + play) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final t = clock.elapsedMicroseconds / 1e6;
  double lag(Probe p) => p.firstFrame == null ? double.nan : (t - p.firstFrame!) - p.pos;
  final lags = (lag(sourcePlayer), lag(viewer)), stalls = (sourcePlayer.stalls, viewer.stalls);
  final positions = (sourcePlayer.pos, viewer.pos);
  // A shared seek far ahead, then back.
  final ahead = await Future.wait([sourcePlayer.seek(45), viewer.seek(45)]);
  final back = await Future.wait([sourcePlayer.seek(5), viewer.seek(5)]);
  final reqs = cdn.requests.sublist(reqBefore);
  int count(bool Function(CdnRequest r) f) => reqs.where(f).length;
  // Peak requests in any 1 s window.
  var peak = 0;
  for (final r in reqs) {
    peak = max(peak, reqs.where((q) => q.at >= r.at && q.at < r.at + 1).length);
  }
  final out = <String, Object?>{
    'mode': mode,
    'sourceFirstFrame': sourcePlayer.firstFrame,
    'live': liveAt,
    'viewerFirstFrame': viewer.firstFrame,
    'sourcePos': positions.$1,
    'viewerPos': positions.$2,
    'sourceLag': lags.$1,
    'viewerLag': lags.$2,
    'sourceStalls': stalls.$1,
    'viewerStalls': stalls.$2,
    'seekAheadSource': ahead[0],
    'seekAheadViewer': ahead[1],
    'seekBackSource': back[0],
    'seekBackViewer': back[1],
    'cdnRequests': reqs.length,
    'byPlayer': count((r) => r.who == 'player'),
    'byRelay': count((r) => r.who == 'relay'),
    'cdnMiB': reqs.fold<int>(0, (a, r) => a + r.sent) / (1 << 20),
    'cuts': count((r) => r.cut),
    'refused412': count((r) => r.status == 412),
    'peakReqPerSec': peak,
    'maxOpenV': cdn.maxOpen['v'],
    'maxOpenA': cdn.maxOpen['a'],
    'resumes': shared?.resumes,
    'sharedPeakMiB': shared == null ? null : sharedPeak / (1 << 20),
    'sourceErrors': sourcePlayer.errors.take(4).toList(),
    'viewerErrors': viewer.errors.take(4).toList(),
  };
  peakTimer.cancel();
  await sourcePlayer.stop();
  await viewer.stop();
  await source.close();
  await shared?.close();
  if (shared == null) await upstreamMedia.close();
  await alice.ws.close();
  await bob.ws.close();
  await server.stop();
  return out;
}

void main() {
  test('single fetch vs today: one upstream reader per track, both players in step', () async {
    final (vPath, aPath) = await _media();
    final files = {'v': await File(vPath).readAsBytes(), 'a': await File(aPath).readAsBytes()};
    final play = int.tryParse(Platform.environment['WT_SF_PLAY'] ?? '') ?? 20;
    final wanted = (Platform.environment['WT_SF_SCENARIOS'] ?? 'clean,cuts,lockout').split(',');
    final scenarios = <String, FakeCdn Function()>{
      'clean': () => FakeCdn(files),
      'cuts': () => FakeCdn(files, cutMax: 2 << 20),
      'lockout': () => FakeCdn(files, cutMax: 2 << 20, lockoutBurst: 40),
      // A per-connection rate about 1.5x the media's: today's two
      // connections get twice what one shared reader gets.
      'slow': () => FakeCdn(files, bytesPerSec: 768 << 10),
    };
    final results = <String, Map<String, Object?>>{};
    for (final name in wanted) {
      for (final mode in ['today', 'single']) {
        final cdn = scenarios[name]!();
        await cdn.start();
        // Anything raised outside a handler (server.stop() under open /r
        // answers among it) is counted: there must be none.
        var teardown = 0;
        final teardownErrors = <String>[];
        final done = Completer<Map<String, Object?>>();
        runZonedGuarded(() async => done.complete(await _run(mode, cdn, play)), (e, st) {
          teardown++;
          if (teardownErrors.length < 3) teardownErrors.add('$e');
        });
        final r = {...await done.future, 'teardownErrors': teardown, 'teardownSample': teardownErrors};
        await cdn.close();
        results['$name/$mode'] = r;
        // ignore: avoid_print
        print('RESULT $name/$mode ${jsonEncode(r, toEncodable: (o) => '$o')}');
      }
    }
    for (final e in results.entries.where((e) => e.key.endsWith('/single'))) {
      final r = e.value;
      expect(r['byPlayer'], 0, reason: '${e.key}: the source player never reads the CDN');
      expect(r['sourceFirstFrame'], isNotNull, reason: e.key);
      expect(r['viewerFirstFrame'], isNotNull, reason: e.key);
      // One reader per track. The fake CDN counts a GET as open until its
      // next write fails, so a cancelled one (the hand-over to the tail
      // pin at the start) can overlap its successor and the next one.
      expect((r['maxOpenV'] as int?) ?? 0, lessThanOrEqualTo(3), reason: e.key);
      expect((r['maxOpenA'] as int?) ?? 0, lessThanOrEqualTo(3), reason: e.key);
      expect(r['refused412'], 0, reason: '${e.key}: one reader never trips the lockout');
      expect(r['seekAheadSource'], isNotNull, reason: '${e.key}: the source plays after a seek ahead');
      expect(r['seekBackSource'], isNotNull, reason: '${e.key}: the source plays after a seek back');
      expect(r['seekAheadViewer'], isNotNull, reason: e.key);
      expect(r['seekBackViewer'], isNotNull, reason: e.key);
    }
    for (final e in results.entries) {
      expect(e.value['teardownErrors'], 0, reason: '${e.key}: ${e.value['teardownSample']}');
    }
  }, skip: _enabled ? false : 'opt-in: WT_SINGLE_FETCH=1 (real mpv, minutes)', timeout: const Timeout(Duration(minutes: 15)));
}
