import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_core/testing.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/playback/yt_dlp_app.dart';
import 'package:starsync/src/screens/home/picked_media.dart';
import 'package:starsync/src/session/connection.dart' show ConnOnline;
import 'package:starsync/src/session/session_coordinator.dart';

// The relay with real coordinators, real mpv and a dedicated server that
// has no file and no Jellyfin login of its own (the VPS setup): a guest's
// file, and links passed on by a member or fetched by the server.

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

Future<String> _media() async {
  final path = '$_tmp/relay_e2e_20s.mkv';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '20', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

Future<void> _poll(FutureOr<bool> Function() cond, String what,
    {Duration timeout = const Duration(seconds: 30), Duration every = const Duration(milliseconds: 200)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(every);
  }
  fail('timed out waiting for $what');
}

/// 60 s at about 3 Mbit/s: long enough that a slow source's relay holds
/// only part of it. An mp4 with its index first: headless players have no
/// video track selected (vid=no), and mkv's cues list only the video, so
/// an mkv would be seeked by scanning from its start (an app's player,
/// with its video output, uses the cues).
Future<String> _longMedia() async {
  final path = '$_tmp/relay_e2e_60s.mp4';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '60', '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '3M', '-minrate', '3M', '-maxrate', '3M',
    '-bufsize', '2M', '-g', '24', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

/// A file read at most [bytesPerSec] (a source's uplink).
class _SlowFile implements RelayBytes {
  final File file;
  final int bytesPerSec;
  _SlowFile(this.file, this.bytesPerSec);

  @override
  Future<int> size() => file.length();

  @override
  Stream<List<int>> read(int start, int end) async* {
    const chunk = 32 * 1024;
    final sw = Stopwatch()..start();
    var sent = 0;
    await for (final c in file.openRead(start, end + 1)) {
      for (var o = 0; o < c.length; o += chunk) {
        final part = c.sublist(o, o + chunk > c.length ? c.length : o + chunk);
        sent += part.length;
        final due = sent * 1000 ~/ bytesPerSec - sw.elapsedMilliseconds;
        if (due > 0) await Future<void>.delayed(Duration(milliseconds: due));
        yield part;
      }
    }
  }

  @override
  Future<void> close() async {}
}

/// A member that is only a source: it sits out (out of the gate), puts
/// [file] up relayed and feeds it at [bytesPerSec]. [drop] goes away
/// without a `bye` (the member `gone`, the relay kept); [back] returns as
/// the same member and feeds again.
class _BareSource {
  final int port;
  final File file;
  final String name;
  static const _client = 'bareSourceClient01';
  var _seq = 0;
  WebSocket? ws;
  String token = '';
  RelaySource? src;
  Timer? _alive;
  _BareSource(this.port, this.file) : name = 'slow.mp4';

  Future<void> join() async {
    final w = ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final welcome = Completer<Map>();
    w.listen((f) {
      final j = jsonDecode('$f') as Map;
      if (j['t'] == 'welcome' && !welcome.isCompleted) welcome.complete(j);
    }, onError: (_) {});
    w.add(jsonEncode(HelloMessage(
            secret: 'pw', user: const HelloUser(name: 'bob'), client: _client, seq: ++_seq)
        .toJson()));
    token = (await welcome.future.timeout(const Duration(seconds: 5)))['token'] as String;
    w.add(jsonEncode(const PresenceIntent(state: Presence.out).toJson()));
    // Not silent, like an app (a silent member goes gone).
    _alive?.cancel();
    _alive = Timer.periodic(const Duration(seconds: 1),
        (_) => w.add(jsonEncode({'t': 'report', 'position': 0, 'buffered': 0, 'eventId': 0})));
  }

  Future<void> swap() async {
    ws!.add(jsonEncode({
      't': 'swap',
      'media': {'name': name, 'size': await file.length(), 'duration': 0, 'relay': <String, Object?>{}},
    }));
  }

  Future<void> feed(int bytesPerSec) async {
    final s = src = RelaySource(Uri.parse('ws://127.0.0.1:$port/r/default/$token/source'),
        RelayMedia.single(_SlowFile(file, bytesPerSec)),
        name: name);
    await s.start();
  }

  /// Gone without a word: the channel and the socket close, no `bye`.
  Future<void> drop() async {
    _alive?.cancel();
    await src?.close();
    await ws?.close();
  }

  Future<void> back(int bytesPerSec) async {
    await join();
    await feed(bytesPerSec);
  }

  Future<void> close() async {
    _alive?.cancel();
    await src?.close();
    await ws?.close();
  }
}

/// Serves one file with ranges; [requests] lists hits (user agent, URL).
Future<(HttpServer, List<String>)> _origin(String file) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <String>[];
  s.listen((req) async {
    requests.add('${req.headers.value('user-agent')} ${req.uri}');
    final size = await File(file).length();
    final r = resolveMediaRequest(rangeHeader: req.headers.value('range'), size: size, filename: 'v.mkv');
    req.response.statusCode = r.status;
    r.headers.forEach(req.response.headers.set);
    try {
      if (r.status == 200 || r.status == 206) {
        await req.response.addStream(File(file).openRead(r.start, (r.end ?? size - 1) + 1));
      }
      await req.response.close();
    } catch (_) {}
  });
  return (s, requests);
}

void main() {
  late SyncServer server;
  late List<SessionCoordinator> all;
  late List<Object> serverErrors;

  Future<SessionCoordinator> member(String name) async {
    final acc = JellyfinAccounts(store: MemoryJellyfinStore());
    await acc.ensureLoaded(validate: false);
    final c = SessionCoordinator(
        jellyfin: acc,
        trackPrefs: TrackPrefs(store: MemoryJellyfinStore()),
        ytDlp: AppYtDlp(YtDlp('$_tmp/relay_e2e_no_ytdlp', enabled: false)));
    all.add(c);
    await c.connect(ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: 'pw', name: name));
    await c.playback.player.setVolume(0);
    return c;
  }

  Future<void> playTogether(List<SessionCoordinator> xs) async {
    await _poll(() => xs.every((x) => x.playback.durationSecs > 19), 'all opened it');
    for (final x in xs) {
      x.play();
    }
    await _poll(() => xs.every((x) => x.playback.player.state.playing), 'all playing');
    await Future.delayed(const Duration(seconds: 3));
    final pos = [for (final x in xs) x.playback.positionSecs];
    // ignore: avoid_print
    print('positions after 3 s: $pos');
    for (final p in pos) {
      expect((p - pos.first).abs(), lessThan(1.0), reason: 'in sync: $pos');
    }
    for (final x in xs) {
      x.play();
    }
    await _poll(() => xs.every((x) => !x.playback.player.state.playing), 'held');
  }

  setUp(() async {
    MediaKit.ensureInitialized();
    all = [];
    server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 'vps'));
    // Relic reports an error writing a response (a relay read cut short
    // when its relay is dropped at a swap or at the stop in tearDown) to
    // the zone the server started in, as it logs it outside tests;
    // anything else fails the test.
    serverErrors = [];
    await runZonedGuarded(server.start, (e, _) {
      if ('$e'.contains('Content size below specified contentLength') || '$e'.contains('did not arrive')) return;
      serverErrors.add(e);
    });
  });

  tearDown(() async {
    for (final x in all) {
      await x.dispose();
    }
    await server.stop();
    expect(serverErrors, isEmpty, reason: 'server errors');
  });

  test('a guest puts up a file: it plays for everyone through the relay', timeout: const Timeout(Duration(minutes: 2)),
      () async {
    final file = await _media();
    final alice = await member('alice');
    final bob = await member('bob');
    expect(await bob.swapPicked(FileMedia(file)), isNull);
    await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.source == bob.connection.memberId, 'relay state');
    final state = alice.serverState.peek()!;
    expect(state.media!.containsKey('url'), isFalse);
    expect(bob.relaying.peek(), isTrue);
    await playTogether([alice, bob]);
    final relay = server.hub.relay!;
    expect(relay.buffers.single.bytesToViewers, greaterThan(0), reason: 'alice played through the relay');
    expect(relay.sourceToken, bob.connection.token);

    // The next swap retires bob's source and the buffer. Nothing answers
    // at that link, so its probe refuses it unless put up anyway.
    expect(await alice.swapPicked(const LinkMedia('http://127.0.0.1:1/none.mkv', anyway: true)), isNull);
    await _poll(() => !bob.relaying.peek(), 'source stopped');
    expect(server.hub.relay, isNull);
  });

  test('links: through me, and fetched by the server; never broadcast', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    final (origin, hits) = await _origin(await _media());
    try {
      final alice = await member('alice');
      final bob = await member('bob');
      final link = 'http://127.0.0.1:${origin.port}/private/ep.mkv?api_key=SECRET';

      expect(await bob.swapPicked(LinkMedia(link, relay: LinkRelay.me)), isNull);
      await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.source == bob.connection.memberId, 'me state');
      expect(alice.serverState.peek()!.toJson().toString(), isNot(contains('SECRET')));
      await playTogether([alice, bob]);
      expect(server.hub.relay!.buffers.single.bytesToViewers, greaterThan(0));
      // Read once: bob's player plays his shared reader's loopback, so
      // every hit at the origin is that reader's (Dart's), none mpv's.
      final one = bob.media.shared.currentFor(link);
      expect(one, isNotNull);
      expect(one!.bytesIn, greaterThan(0));
      expect(hits.where((h) => !h.startsWith('Dart/')), isEmpty, reason: '$hits');

      final before = hits.length;
      expect(await alice.swapPicked(LinkMedia(link, relay: LinkRelay.server)), isNull);
      await _poll(() => stateMediaRelay(bob.serverState.peek()!)?.fetch == true, 'fetch state');
      expect(bob.serverState.peek()!.toJson().toString(), isNot(contains('SECRET')));
      expect(alice.relaying.peek(), isFalse, reason: 'the server fetches, nobody sources');
      await playTogether([alice, bob]);
      expect(hits.length, greaterThan(before));

      // A page is refused up front when this computer cannot read it (here
      // yt-dlp is off, and the refusal says so).
      final page = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      page.listen((r) {
        r.response.headers.contentType = ContentType.html;
        r.response.write('<html></html>');
        r.response.close();
      });
      expect(await alice.swapPicked(LinkMedia('http://127.0.0.1:${page.port}/watch?v=x', relay: LinkRelay.me)),
          'yt-dlp is turned off');
      await page.close(force: true);
    } finally {
      await origin.close(force: true);
    }
  });

  test('a source that dials in after mpv would have given up (5 s): viewers wait for it, then play',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final file = await _media();
    final alice = await member('alice');
    // Bob is a bare client: he puts a file up and starts passing it on
    // only 7 s later (a slow first upstream read, a slow own player).
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/sync');
    final welcome = Completer<Map>();
    ws.listen((f) {
      final j = jsonDecode('$f') as Map;
      if (j['t'] == 'welcome' && !welcome.isCompleted) welcome.complete(j);
    }, onError: (_) {});
    ws.add(jsonEncode(const HelloMessage(secret: 'pw', user: HelloUser(name: 'bob')).toJson()));
    final token = (await welcome.future.timeout(const Duration(seconds: 5)))['token'] as String;
    final size = await File(file).length();
    ws.add(jsonEncode({
      't': 'swap',
      'media': {'name': 'late.mkv', 'size': size, 'duration': 0, 'relay': <String, Object?>{}},
    }));
    await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.source.isNotEmpty ?? false, 'relay state');
    await Future.delayed(const Duration(seconds: 7));
    expect(alice.playerError.peek(), isEmpty, reason: 'no "could not be opened" while the source is on its way');
    expect(alice.status.peek().line?.text, 'Waiting for bob to pass the video on');
    final src = RelaySource(Uri.parse('ws://127.0.0.1:${server.boundPort}/r/default/$token/source'),
        RelayMedia.single(FileRelayBytes(File(file))));
    await src.start();
    try {
      await _poll(() => alice.playback.durationSecs > 19, 'alice opened it once the source was up');
      expect(alice.playerError.peek(), isEmpty);
    } finally {
      await src.close();
      await ws.close();
    }
  });

  test('the source drops uncleanly and comes back: the others play on, the relay continues (D6)',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final file = await _media();
    final proxy = await FlakyProxy.start(server.boundPort);
    try {
      final alice = await member('alice');
      final acc = JellyfinAccounts(store: MemoryJellyfinStore());
      await acc.ensureLoaded(validate: false);
      final bob = SessionCoordinator(jellyfin: acc, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      all.add(bob);
      await bob.connect(ConnectParams(host: '127.0.0.1', port: proxy.port, secret: 'pw', name: 'bob'));
      await bob.playback.player.setVolume(0);
      expect(await bob.swapPicked(FileMedia(file)), isNull);
      await _poll(() => server.hub.relay?.live == true, 'source live');
      await _poll(() => alice.playback.durationSecs > 19 && bob.playback.durationSecs > 19, 'both opened');
      final token = bob.connection.token;
      final opens = bob.opens;

      // Bob's network goes silent (no FIN) on every link he has, the sync
      // socket and his relay channel, and new ones too, long enough for
      // the server to call him gone: the relay stays (`sourceGone`).
      proxy.onConnect = (l) => l.blackhole();
      for (final l in proxy.links) {
        l.blackhole();
      }
      await _poll(() => bob.reconnecting.peek(), 'reconnect engaged', timeout: const Duration(seconds: 15));
      await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.sourceGone ?? false, 'source gone for alice',
          timeout: const Duration(seconds: 25));
      expect(alice.serverState.peek()!.media, isNotNull);
      expect(server.hub.relay, isNotNull, reason: 'the relay is kept through the grace');
      // His link comes back: the same member, his source dials its channel
      // again with the same `info` and the relay continues.
      proxy.onConnect = null;
      await _poll(() => bob.connection.state.peek() is ConnOnline, 'back', timeout: const Duration(seconds: 30));
      expect(bob.connection.token, token, reason: 'resumed as the same member');
      expect(bob.serverState.peek(), isNotNull, reason: 'the state stayed through the drop');
      await _poll(() => server.hub.relay?.live == true && !(stateMediaRelay(alice.serverState.peek()!)?.sourceGone ?? true),
          'source redialled', timeout: const Duration(seconds: 25));
      expect(bob.relaying.peek(), isTrue);
      expect(bob.opens, opens, reason: 'still his own copy, not reopened');

      // Alice can still get bytes the buffer never had.
      alice.seekTo(17);
      await _poll(() => (alice.playback.positionSecs - 17).abs() < 1.5, 'alice seeked');
    } finally {
      await proxy.close();
    }
  });

  // A seek into a part the relay has not buffered yet. The source's
  // uplink is about 3x the media's bitrate; the time from the seek to the
  // player playing there again is printed and loosely bounded.
  test('a seek past what a slow source has sent plays within a few seconds',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final file = File(await _longMedia());
    final alice = await member('alice');
    final bob = _BareSource(server.boundPort, file);
    try {
      await bob.join();
      await bob.swap();
      await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.source.isNotEmpty ?? false, 'relay state');
      await bob.feed(1200 * 1024);
      await _poll(() => alice.playback.durationSecs > 59, 'alice opened it');
      alice.play();
      await _poll(() => alice.playback.playing && alice.playback.positionSecs > 2, 'playing');
      final took = <int>[];
      for (final to in [40.0, 52.0]) {
        final sw = Stopwatch()..start();
        alice.seekTo(to);
        await _poll(() => alice.playback.playing && alice.playback.positionSecs > to + 0.5, 'played at $to',
            every: const Duration(milliseconds: 20));
        took.add(sw.elapsedMilliseconds);
      }
      // ignore: avoid_print
      print('relay seek: seek to an unbuffered part until playing there: ${took.join(', ')} ms');
      for (final t in took) {
        expect(t, lessThan(5000), reason: "a seek into what the source has not sent yet (4 s of buffer at about 3x the bitrate)");
      }
    } finally {
      await bob.close();
    }
  });

  // D6, the viewer's side: the source goes, a seek lands past what
  // the server got from it, and the buffer runs dry.
  test('the source drops: what is buffered plays, a seek past it waits for the source, no seek loop, it resumes (D6)',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    final file = File(await _longMedia());
    final alice = await member('alice');
    final carol = await member('carol');
    final bob = _BareSource(server.boundPort, file);
    final errors = <String>[];
    final subs = <StreamSubscription<Object?>>[];
    try {
      await bob.join();
      await bob.swap();
      await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.source.isNotEmpty ?? false, 'relay state');
      // Just above the bitrate: the relay holds only a little ahead.
      await bob.feed(560 * 1024);
      await _poll(() => alice.playback.durationSecs > 59 && carol.playback.durationSecs > 59, 'both opened it');
      for (final x in [alice, carol]) {
        subs.add(x.playback.player.logs.listen((l) {
          if (l.text.contains('error running command')) errors.add(l.text);
        }));
        x.play();
      }
      await _poll(() => alice.playback.playing && alice.playback.positionSecs > 4, 'playing');

      await bob.drop();
      await _poll(() => stateMediaRelay(alice.serverState.peek()!)?.sourceGone ?? false, 'source gone');
      expect(alice.status.peek().line?.text, startsWith("bob's connection dropped"));
      final seeks = [alice.playback.seeksSent, carol.playback.seeksSent];
      // Carol skips to where the source never got to.
      carol.seekTo(50);
      await _poll(() => alice.serverState.peek()!.hold?.source ?? false, 'held for the source',
          timeout: const Duration(seconds: 60));
      expect(alice.status.peek().line?.text, 'Waiting for bob');
      expect(carol.status.peek().line?.text, 'Waiting for bob');
      // Held for a while: no seek loop into bytes nobody sends.
      await Future.delayed(const Duration(seconds: 12));
      final sent = [alice.playback.seeksSent - seeks[0], carol.playback.seeksSent - seeks[1]];
      expect(sent.every((n) => n <= 1), isTrue, reason: 'one try each, no loop: $sent');
      expect(alice.serverState.peek()!.transport, 'held');
      expect([alice.playerError.peek(), carol.playerError.peek()], everyElement(isEmpty), reason: 'not a broken player');
      // Someone joins meanwhile: it opens what the server has and waits too.
      final dave = await member('dave');
      subs.add(dave.playback.player.logs.listen((l) {
        if (l.text.contains('error running command')) errors.add(l.text);
      }));
      await _poll(() => dave.status.peek().line?.text == 'Waiting for bob', 'dave waits for bob');
      dave.play();

      await bob.back(4 * 1024 * 1024);
      await _poll(() {
        final relay = stateMediaRelay(alice.serverState.peek()!);
        return relay != null && relay.live && !relay.sourceGone;
      }, 'source back');
      await _poll(
          () =>
              alice.serverState.peek()!.transport == 'playing' &&
              alice.playback.playing &&
              alice.playback.positionSecs > 50.5 &&
              carol.playback.positionSecs > 50.5 &&
              dave.playback.positionSecs > 50.5,
          'all playing at 50 again',
          timeout: const Duration(seconds: 40));
      // ignore: avoid_print
      print('D6: seeks while the source was gone $sent, held back '
          '${alice.media.heldBackSeeks} + ${carol.media.heldBackSeeks}');
      expect(errors, isEmpty, reason: 'no command reached a player without its media');
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      await bob.close();
    }
  });
}
