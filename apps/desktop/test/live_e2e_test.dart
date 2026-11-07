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

// A live stream watched together (ARCHITECTURE "Live streams"): ffmpeg
// makes a live HLS stream (2 s segments, no end), served twice over HTTP:
// as it is, and as a CDN edge whose playlist runs 3 s late. Three app
// coordinators against a real server open it as a page their resolver
// says is live (no yt-dlp); the third reads the late edge. Measured: how
// far apart the three players are in the stream's own time (printed);
// then a pause here only, back to live, and the stream's end.

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
    final ffmpeg = await Process.start('ffmpeg', [
      '-v', 'error', '-re',
      '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=30',
      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '60', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
      '-f', 'hls', '-hls_time', '2', '-hls_list_size', '8', '-hls_flags', 'delete_segments+program_date_time',
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
      // A playlist with its six segments, as a live one has.
      await _poll(() => File('${dir.path}/live.m3u8').existsSync() &&
          File('${dir.path}/live.m3u8').readAsStringSync().split('#EXTINF').length > 7, 'the live playlist');
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

      // A pause is b's own: the group and the others go on.
      b.togglePlay();
      await _poll(() => !b.playback.playing, 'b paused');
      await Future.delayed(const Duration(seconds: 4));
      expect(a.playback.playing && c.playback.playing, isTrue, reason: 'the others go on');
      expect(a.serverState.peek()!.transport, 'playing');
      // Playing again: back on the live point (a seek in its cache).
      b.togglePlay();
      await Future.delayed(const Duration(seconds: 5));
      final back = await _spread(all);
      // ignore: avoid_print
      print('after a 4 s pause here only and back to live: spread ${((back ?? -1) * 1000).round()} ms');
      expect(back, isNotNull);
      expect(back!, lessThan(0.6));

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

      // No seeking: a seek request changes nothing.
      final before = a.serverState.peek()!.eventId;
      a.seekTo(1);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(a.serverState.peek()!.eventId, before);

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
}
