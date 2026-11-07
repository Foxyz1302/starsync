import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/platform/ports/link_resolver.dart';
import 'package:starsync/src/playback/yt_dlp_app.dart';
import 'package:starsync/src/screenshot/screenshots.dart' show StillFrames;
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/sync/state_diff.dart' show serverPositionAt;

// A live stream watched together (ARCHITECTURE "Live streams"): ffmpeg
// makes a live HLS stream (2 s segments, no end), served twice over HTTP:
// as it is, and as a CDN edge whose playlist runs 3 s late. Three app
// coordinators against a real server open it as a page their resolver
// says is live (no yt-dlp); the third reads the late edge. Measured: how
// far apart the three players are in the stream's own time (printed);
// then a pause for everyone and play from the paused moment, behind live,
// Go live; rewinding (the playlist keeps 180 s) inside every cache
// (a click and a drag) and past it (each opens it again there), how long
// until the picture is there; a pause at the window's start that falls out
// of it (play resumes at the oldest moment everyone reaches), Go live; and
// the stream's end. A second stream whose playlist keeps a few segments
// (no rewinding): a pause for everyone, play back at live.

const _port = 18091;
final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

/// A page every member resolves to [stream] (its own CDN edge), live.
class _LiveLinks implements LinkResolver {
  final String stream;
  _LiveLinks(this.stream);
  @override
  Future<YtDlp> get ytDlp async => YtDlp('$_tmp/live_e2e_no_ytdlp', enabled: false);
  @override
  void warmUp() {}
  @override
  bool get resolvesLinks => true;
  @override
  Future<LinkProbe> probe(String url, {Duration keep = Duration.zero, bool fresh = false}) async =>
      LinkProbe.page(Uri.parse(url), info: YtDlpInfo(title: 'Test live', isLive: true, play: YtDlpPlay([stream])));
  @override
  void release(String url) {}
}

/// Serves [dir]; with [lag], the playlist as it was that long ago.
Future<HttpServer> _serve(String dir, {Duration lag = Duration.zero}) async {
  final history = Queue<(DateTime, String)>();
  Timer? snap;
  if (lag > Duration.zero) {
    snap = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final f = File('$dir/live.m3u8');
      if (!f.existsSync()) return;
      history.add((DateTime.now(), f.readAsStringSync()));
      while (history.length > 600) {
        history.removeFirst();
      }
    });
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final name = req.uri.pathSegments.isEmpty ? '' : req.uri.pathSegments.last;
    final res = req.response;
    try {
      if (name.endsWith('.m3u8')) {
        var body = File('$dir/$name').existsSync() ? File('$dir/$name').readAsStringSync() : '';
        if (lag > Duration.zero) {
          final cut = DateTime.now().subtract(lag);
          for (final (at, b) in history) {
            if (at.isAfter(cut)) break;
            body = b;
          }
        }
        res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        res.write(body);
      } else {
        final f = File('$dir/$name');
        if (!f.existsSync()) {
          res.statusCode = 404;
        } else {
          res.headers.contentType = ContentType('video', 'mp2t');
          await res.addStream(f.openRead());
        }
      }
    } catch (_) {}
    await res.close();
  }, onDone: () => snap?.cancel());
  return server;
}

Future<void> _poll(FutureOr<bool> Function() cond, String what, {Duration timeout = const Duration(seconds: 40)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out waiting for $what');
}

/// Where [c]'s player is in the stream's own time, read from mpv now.
Future<double?> _streamPos(SessionCoordinator c) async {
  final start = c.playback.knownStreamStart;
  if (start == null || c.playback.current == null) return null;
  final tp = double.tryParse(await c.playback.player.getProperty('time-pos'));
  return tp == null ? null : tp + start;
}

/// The spread of [cs]' stream positions at one moment (each read's delay
/// taken out), in seconds; null while one has none.
Future<double?> _spread(List<SessionCoordinator> cs) async {
  final t0 = DateTime.now();
  final at = <double>[];
  for (final c in cs) {
    final p = await _streamPos(c);
    if (p == null) return null;
    at.add(p - DateTime.now().difference(t0).inMicroseconds / 1e6);
  }
  at.sort();
  return at.last - at.first;
}

/// [cs]' spread sampled every half second for [secs]: median and max, in
/// seconds; printed with [what].
Future<({double median, double max})> _spreadOver(List<SessionCoordinator> cs, int secs, String what) async {
  final spreads = <double>[];
  final end = DateTime.now().add(Duration(seconds: secs));
  while (DateTime.now().isBefore(end)) {
    final s = await _spread(cs);
    if (s != null) spreads.add(s);
    await Future.delayed(const Duration(milliseconds: 500));
  }
  if (spreads.isEmpty) fail('no spread for $what');
  spreads.sort();
  final r = (median: spreads[spreads.length ~/ 2], max: spreads.last);
  // ignore: avoid_print
  print('$what: spread over ${spreads.length} samples median ${(r.median * 1000).round()} ms, '
      'max ${(r.max * 1000).round()} ms');
  return r;
}

/// The group's live point now and how far back everyone can rewind, from
/// [c]'s state (stream time).
({double point, double top, double from}) _group(SessionCoordinator c) {
  final r = c.serverState.peek()!;
  final point = serverPositionAt(r, c.connection.serverNow());
  return (point: point, top: point + r.behind, from: r.liveFrom);
}

/// How long after a seek to [target] (stream time) by [c], started right
/// after this is called, each player's picture is there (mpv's position
/// within a second of it, read every 10 ms: the target as it runs on, or
/// the group's point once the state has the seek); printed with [what],
/// the seeker first.
Future<void> _seekLatency(SessionCoordinator c, List<SessionCoordinator> all, double target, String what) async {
  final t0 = DateTime.now();
  final before = c.serverState.peek()!.eventId;
  final took = <SessionCoordinator, int>{};
  final end = t0.add(const Duration(seconds: 20));
  while (took.length < all.length && DateTime.now().isBefore(end)) {
    await Future.delayed(const Duration(milliseconds: 10));
    final moved = DateTime.now().difference(t0).inMicroseconds / 1e6;
    for (final co in all) {
      if (took.containsKey(co)) continue;
      final p = await _streamPos(co);
      final r = co.serverState.peek()!;
      final at = r.eventId > before ? _group(co).point : target + (r.transport == 'playing' ? moved : 0);
      if (p != null && (p - at).abs() < 1) took[co] = DateTime.now().difference(t0).inMilliseconds;
    }
  }
  String ms(SessionCoordinator co) => took.containsKey(co) ? '${took[co]} ms' : 'not there';
  // ignore: avoid_print
  print('$what: picture there after: seeker ${ms(c)}; others '
      '${[for (final co in all) if (co != c) ms(co)].join(', ')}');
}

/// Everyone rewinds to [target] (by [c]); waits until they all play it
/// (within a second), then samples their spread for [secs].
Future<({double median, double max})> _rewind(
    SessionCoordinator c, List<SessionCoordinator> all, double target, String what,
    {int secs = 10, bool drag = false}) async {
  final before = c.serverState.peek()!.eventId;
  // A drag on the seek bar: a seek on every move, 60 ms apart, onto the
  // target (timed from the last).
  if (drag) {
    for (final d in [12.0, 9.0, 6.0, 3.0]) {
      c.seekLive(target + d);
      await Future.delayed(const Duration(milliseconds: 60));
    }
  }
  final latency = _seekLatency(c, all, target, what);
  c.seekLive(target);
  await _poll(() => c.serverState.peek()!.eventId > before, 'the rewind in the state');
  await latency;
  try {
    await _poll(() async {
      final g = _group(c).point;
      for (final co in all) {
        final p = await _streamPos(co);
        if (p == null || (p - g).abs() > 1) return false;
      }
      return true;
    }, 'everyone at the rewound point ($what)', timeout: const Duration(seconds: 60));
  } catch (_) {
    final g = _group(c);
    for (final co in all) {
      final start = co.playback.knownStreamStart;
      // ignore: avoid_print
      print('at ${g.point.toStringAsFixed(1)} (from ${g.from.toStringAsFixed(1)}, top ${g.top.toStringAsFixed(1)}): '
          'player at ${(await _streamPos(co))?.toStringAsFixed(1)}, start $start, '
          'cached ${co.playback.cached.peek().ranges.map((r) => '${r.start.inMilliseconds / 1000}-${r.end.inMilliseconds / 1000}').join(',')}, '
          'edge ${co.playback.liveWindow.edgeAt(DateTime.now().microsecondsSinceEpoch / 1e6)?.toStringAsFixed(1)}');
    }
    rethrow;
  }
  await Future.delayed(const Duration(seconds: 3));
  return _spreadOver(all, secs, what);
}

void main() {
  // Opt-in: `WT_LIVE_URL=<a live page>` (YouTube, Twitch, ...) resolved by
  // a real yt-dlp (downloaded into WT_TEST_TMP), two members, the spread
  // printed. Needs the network; no sign-in.
  final liveUrl = Platform.environment['WT_LIVE_URL'];
  test('a real live page: two members on the same moment', skip: liveUrl == null ? 'set WT_LIVE_URL' : null,
      timeout: const Timeout(Duration(minutes: 4)), () async {
    MediaKit.ensureInitialized();
    final server = SyncServer(AppConfig(port: _port + 1, secret: '', name: 'server'));
    // Each member resolves the page itself (its own stream URLs); the
    // first gets yt-dlp in place.
    final links = AppYtDlp(YtDlp('$_tmp/live_e2e_ytdlp'));
    expect(await (await links.ytDlp).ensure(), isNotNull);
    final a = SessionCoordinator(ytDlp: links);
    final b = SessionCoordinator(ytDlp: AppYtDlp(YtDlp('$_tmp/live_e2e_ytdlp')));
    final all = [a, b];
    try {
      await server.start();
      for (final (co, name) in [(a, 'a'), (b, 'b')]) {
        co.playback.volume.value = 0;
        await co.connect(ConnectParams(host: '127.0.0.1', port: _port + 1, secret: '', name: name));
      }
      expect(await a.swapLink(liveUrl!), isNull);
      await _poll(() => all.every((co) => co.live.peek() && co.playback.knownStreamStart != null),
          'every player has the live stream', timeout: const Duration(seconds: 90));
      for (final co in all) {
        await co.playback.player.setProperty('mute', 'yes');
      }
      await Future.delayed(const Duration(seconds: 15));
      final spreads = <double>[];
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(end)) {
        final s = await _spread(all);
        if (s != null) spreads.add(s);
        await Future.delayed(const Duration(milliseconds: 500));
      }
      spreads.sort();
      final edgeA = a.playback.durationSecs - a.playback.positionSecs;
      // ignore: avoid_print
      print('real live spread over ${spreads.length} samples: median ${(spreads[spreads.length ~/ 2] * 1000).round()} ms, '
          'max ${(spreads.last * 1000).round()} ms; ${edgeA.toStringAsFixed(1)} s behind the edge');
      expect(spreads[spreads.length ~/ 2], lessThan(0.25));

      // Rewinding, when the stream lets everyone: five minutes back (or
      // the window's start), then Go live.
      for (final co in all) {
        final w = co.playback.liveWindow.playlist;
        // ignore: avoid_print
        print('player window: ${w == null ? 'none' : '${w.count} segments, ${w.secs.toStringAsFixed(0)} s'}');
      }
      final g = _group(a);
      if (g.from <= 0) {
        // ignore: avoid_print
        print('no rewind window for the group');
        return;
      }
      // ignore: avoid_print
      print('group window: ${(g.top - g.from).toStringAsFixed(1)} s back from the live point');
      final target = g.point - 300 > g.from ? g.point - 300 : g.from;
      final far = await _rewind(b, all, target, 'real live rewound ${(g.point - target).round()} s', secs: 20);
      expect(far.median, lessThan(0.25));
      final at = a.serverState.peek()!.eventId;
      a.goLive();
      await _poll(() => a.serverState.peek()!.eventId > at, 'go live in the state');
      await Future.delayed(const Duration(seconds: 8));
      final live = await _spreadOver(all, 15, 'real live back to live');
      expect(live.median, lessThan(0.25));
    } finally {
      for (final co in all) {
        await co.dispose();
      }
      await server.stop();
    }
  });

  test('a live stream: everyone on the same moment, pause here only, the end', timeout: const Timeout(Duration(minutes: 4)),
      () async {
    MediaKit.ensureInitialized();
    final dir = Directory('$_tmp/live_e2e_$pid')..createSync(recursive: true);
    // 180 s of it at once, then in real time: a playlist of up to 90
    // segments (2 s each) that can be rewound, its start well before
    // where the players opened it for the whole test.
    final ffmpeg = await Process.start('ffmpeg', [
      '-v', 'error',
      '-readrate', '1', '-readrate_initial_burst', '180', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=30',
      '-readrate', '1', '-readrate_initial_burst', '180', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '60', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
      '-f', 'hls', '-hls_time', '2', '-hls_list_size', '90', '-hls_flags', 'delete_segments+program_date_time',
      '${dir.path}/live.m3u8',
    ]);
    final edge = await _serve(dir.path);
    final late = await _serve(dir.path, lag: const Duration(seconds: 3));
    final server = SyncServer(AppConfig(port: _port, secret: '', name: 'server'));
    final page = 'http://127.0.0.1:${edge.port}/channel';
    final direct = 'http://127.0.0.1:${edge.port}/live.m3u8';
    final lagged = 'http://127.0.0.1:${late.port}/live.m3u8';
    final a = SessionCoordinator(ytDlp: _LiveLinks(direct));
    final b = SessionCoordinator(ytDlp: _LiveLinks(direct));
    final c = SessionCoordinator(ytDlp: _LiveLinks(lagged));
    final all = [a, b, c];
    try {
      await server.start();
      // The whole burst written (the playlist full), then on in real time.
      await _poll(() => File('${dir.path}/live.m3u8').existsSync() &&
          File('${dir.path}/live.m3u8').readAsStringSync().split('#EXTINF').length > 88, 'the live playlist');
      for (final (co, name) in [(a, 'a'), (b, 'b'), (c, 'c')]) {
        co.playback.volume.value = 0;
        await co.connect(ConnectParams(host: '127.0.0.1', port: _port, secret: '', name: name));
      }
      expect(await a.swapLink(page), isNull);
      await _poll(() => all.every((co) => co.live.peek() && co.playback.knownStreamStart != null),
          'every player has the live stream');
      for (final co in all) {
        await co.playback.player.setProperty('mute', 'yes');
      }
      final r = a.serverState.peek()!;
      expect(r.media!['live'], isTrue);
      await _poll(() => a.serverState.peek()!.transport == 'playing', 'the live point');
      expect(a.serverState.peek()!.hold, isNull);

      // Alignment: sampled for 20 s once everyone settled.
      await Future.delayed(const Duration(seconds: 8));
      final spreads = <double>[];
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(end)) {
        final s = await _spread(all);
        if (s != null) spreads.add(s);
        await Future.delayed(const Duration(milliseconds: 500));
      }
      spreads.sort();
      final median = spreads[spreads.length ~/ 2], worst = spreads.last;
      // ignore: avoid_print
      print('live spread over ${spreads.length} samples: median ${(median * 1000).round()} ms, '
          'p90 ${(spreads[(spreads.length * 0.9).floor()] * 1000).round()} ms, max ${(worst * 1000).round()} ms '
          '(one of three on a CDN edge 3 s late)');
      expect(median, lessThan(0.25));
      expect(worst, lessThan(0.6));

      // A pause is everyone's: the group's point stops, the stream goes on.
      await _poll(() => a.serverState.peek()!.liveFrom > 0, 'the rewind window');
      b.togglePlay();
      await _poll(() => all.every((co) => !co.playback.playing), 'everyone paused');
      final pausedAt = a.serverState.peek()!;
      expect(pausedAt.transport, 'held');
      await Future.delayed(const Duration(seconds: 4));
      expect(a.serverState.peek()!.position, pausedAt.position, reason: 'the paused moment holds');
      expect(a.liveBehind.peek(), greaterThan(3), reason: 'the stream went on: behind live');
      final pausedSpread = await _spread(all);
      // ignore: avoid_print
      print('paused for everyone: spread ${((pausedSpread ?? -1) * 1000).round()} ms');
      expect(pausedSpread!, lessThan(0.3));
      // Play (by another member): everyone from the paused moment, behind
      // live.
      c.togglePlay();
      await _poll(() => all.every((co) => co.playback.playing), 'everyone playing again');
      expect(a.serverState.peek()!.behind, greaterThan(3));
      expect(a.liveBehind.peek(), greaterThan(3));
      await Future.delayed(const Duration(seconds: 3));
      final back = await _spreadOver(all, 5, 'played on from a 4 s pause, behind live');
      expect(back.median, lessThan(0.25));
      // Go live catches up.
      final paused = a.serverState.peek()!.eventId;
      a.goLive();
      await _poll(() => a.serverState.peek()!.eventId > paused && a.serverState.peek()!.behind == 0, 'back at live');
      await Future.delayed(const Duration(seconds: 4));
      final caughtUp = await _spreadOver(all, 5, 'Go live after the pause');
      expect(caughtUp.median, lessThan(0.25));

      // A screenshot decoded again (GPU frames): a hidden player opens the
      // stream at its own place and finds the same moment of the stream.
      final shot = a.playback.current!;
      final stills = StillFrames(a.playback.host);
      try {
        final still = await stills.frameAt(
            url: shot.opened!.url,
            headers: shot.opened!.headers,
            at: shot.state.position,
            streamStart: a.playback.knownStreamStart);
        expect(still, isNotNull, reason: 'the same moment of the live stream in a hidden player');
      } finally {
        await stills.close();
      }

      // The seek bar's own path does not seek a live stream.
      final before = a.serverState.peek()!.eventId;
      a.seekTo(1);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(a.serverState.peek()!.eventId, before);

      // Rewinding: the playlist keeps 180 s, so everyone can.
      for (final co in all) {
        final w = co.playback.liveWindow.playlist!;
        // ignore: avoid_print
        print('player window: ${w.count} segments, ${w.secs.toStringAsFixed(0)} s');
      }
      var g = _group(a);
      // ignore: avoid_print
      print('group window: ${(g.top - g.from).toStringAsFixed(1)} s back from the live point');
      expect(g.top - g.from, greaterThan(RelayConstants.liveMinWindowSecs));
      expect(a.liveBar.peek(), isNotNull, reason: 'a seek bar over the window');
      // A little back: inside every player's cache (a seek there).
      final near = await _rewind(b, all, g.point - 15, 'rewound 15 s (in the cache)');
      expect(a.liveBehind.peek(), closeTo(15, 1.5));
      expect(near.median, lessThan(0.25));
      await _rewind(b, all, _group(b).point - 10, 'dragged 10 s back (in the cache)', secs: 2, drag: true);
      // To the window's start: past every cache (each opens it again there).
      g = _group(a);
      final far = await _rewind(a, all, g.from, 'rewound to the window start (opened again)');
      expect(a.serverState.peek()!.behind, greaterThan(40));
      expect(far.median, lessThan(0.25));
      expect(far.max, lessThan(0.6));
      // Paused at the window's start: the window moves on past the paused
      // moment, so play resumes at the oldest moment everyone still reaches
      // (everyone opens it there first).
      c.togglePlay();
      await _poll(() => all.every((co) => !co.playback.playing), 'everyone paused');
      final held = a.serverState.peek()!.position;
      await _poll(() => a.serverState.peek()!.liveFrom > held + 4, 'the paused moment out of the window',
          timeout: const Duration(seconds: 30));
      final resumeFrom = a.serverState.peek()!.liveFrom;
      c.togglePlay();
      await _poll(() => a.serverState.peek()!.transport == 'playing', 'playing again', timeout: const Duration(seconds: 30));
      final resumed = a.serverState.peek()!;
      // ignore: avoid_print
      print('paused ${(resumeFrom - held).toStringAsFixed(1)} s past the window: resumed '
          '${(resumed.position - held).toStringAsFixed(1)} s later than the paused moment');
      expect(resumed.position, greaterThanOrEqualTo(resumeFrom - 0.01));
      await _poll(() async {
        final g = _group(a).point;
        for (final co in all) {
          final p = await _streamPos(co);
          if (p == null || (p - g).abs() > 1) return false;
        }
        return true;
      }, 'everyone at the oldest moment they reach', timeout: const Duration(seconds: 30));
      await Future.delayed(const Duration(seconds: 3));
      final back2 = await _spreadOver(all, 5, 'resumed at the window start after a long pause');
      expect(back2.median, lessThan(0.25));
      // Go live: everyone back to the live point.
      final behindBefore = a.serverState.peek()!.eventId;
      c.goLive();
      await _poll(() => a.serverState.peek()!.eventId > behindBefore, 'go live in the state');
      expect(a.serverState.peek()!.behind, 0);
      await Future.delayed(const Duration(seconds: 6));
      final live = await _spreadOver(all, 8, 'back to live');
      expect(live.median, lessThan(0.25));

      // The stream ends (ffmpeg writes its end): the group's media ends.
      ffmpeg.stdin.write('q');
      await ffmpeg.stdin.flush();
      await _poll(() => a.serverState.peek()!.transport == 'finished', 'the end of the stream',
          timeout: const Duration(seconds: 60));
      // Every player stays at the end (a play would start the finished
      // playlist over).
      await Future.delayed(const Duration(seconds: 3));
      expect(all.every((co) => co.playback.completed && !co.playback.playing), isTrue);
    } finally {
      ffmpeg.kill();
      for (final co in all) {
        await co.dispose();
      }
      await server.stop();
      await edge.close(force: true);
      await late.close(force: true);
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('a live stream nobody can rewind: a pause for everyone, play back at live, BRB holds nothing',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    MediaKit.ensureInitialized();
    final dir = Directory('$_tmp/live_e2e_short_$pid')..createSync(recursive: true);
    // A playlist of six segments (2 s each), as Twitch keeps: no window.
    final ffmpeg = await Process.start('ffmpeg', [
      '-v', 'error',
      '-readrate', '1', '-readrate_initial_burst', '16', '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=30',
      '-readrate', '1', '-readrate_initial_burst', '16', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '60', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
      '-f', 'hls', '-hls_time', '2', '-hls_list_size', '6', '-hls_flags', 'delete_segments+program_date_time',
      '${dir.path}/live.m3u8',
    ]);
    final edge = await _serve(dir.path);
    final server = SyncServer(AppConfig(port: _port + 2, secret: '', name: 'server'));
    final direct = 'http://127.0.0.1:${edge.port}/live.m3u8';
    final a = SessionCoordinator(ytDlp: _LiveLinks(direct));
    final b = SessionCoordinator(ytDlp: _LiveLinks(direct));
    final all = [a, b];
    try {
      await server.start();
      await _poll(() => File('${dir.path}/live.m3u8').existsSync() &&
          File('${dir.path}/live.m3u8').readAsStringSync().split('#EXTINF').length > 6, 'the live playlist');
      for (final (co, name) in [(a, 'a'), (b, 'b')]) {
        co.playback.volume.value = 0;
        await co.connect(ConnectParams(host: '127.0.0.1', port: _port + 2, secret: '', name: name));
      }
      expect(await a.swapLink('http://127.0.0.1:${edge.port}/channel'), isNull);
      await _poll(() => all.every((co) => co.live.peek() && co.playback.knownStreamStart != null),
          'every player has the live stream');
      for (final co in all) {
        await co.playback.player.setProperty('mute', 'yes');
      }
      await _poll(() => a.serverState.peek()!.transport == 'playing', 'the live point');
      await Future.delayed(const Duration(seconds: 6));
      expect(a.serverState.peek()!.liveFrom, 0, reason: 'six segments: no rewinding');
      expect(a.liveBar.peek(), isNull);
      // BRB holds nothing on it.
      b.brb();
      await Future.delayed(const Duration(seconds: 1));
      expect(a.serverState.peek()!.transport, 'playing');
      b.back();
      // A pause is everyone's.
      a.togglePlay();
      await _poll(() => all.every((co) => !co.playback.playing), 'everyone paused');
      expect(a.serverState.peek()!.transport, 'held');
      await Future.delayed(const Duration(seconds: 6));
      expect(b.liveBehind.peek(), greaterThan(5), reason: 'behind live while paused');
      // Play: it cannot go on from the paused moment, so back at live.
      b.togglePlay();
      await _poll(() => a.serverState.peek()!.transport == 'playing', 'playing again');
      final r = a.serverState.peek()!;
      expect(r.behind, 0);
      expect(a.liveBackAtLive.peek() || b.liveBackAtLive.peek(), isTrue, reason: '"back at live" in the pill');
      await _poll(() async {
        final g = _group(a).point;
        for (final co in all) {
          final p = await _streamPos(co);
          if (p == null || (p - g).abs() > 1) return false;
        }
        return true;
      }, 'everyone at live');
      await Future.delayed(const Duration(seconds: 3));
      final live = await _spreadOver(all, 6, 'no window: back at live after a 6 s pause');
      expect(live.median, lessThan(0.25));
    } finally {
      ffmpeg.kill();
      for (final co in all) {
        await co.dispose();
      }
      await server.stop();
      await edge.close(force: true);
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
