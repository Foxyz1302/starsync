import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/jellyfin/session_media.dart';
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/platform/desktop/media_kit_host.dart';
import 'package:starsync/src/playback/yt_dlp_app.dart';
import 'package:starsync/src/queue/queue_controller.dart' show WarmState;
import 'package:starsync/src/screens/home/picked_media.dart';
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/session/switch_trace.dart';

// How long an Up next switch takes through the media pipeline, end to
// end, over real mpv and a real sync server: two Jellyfin account holders
// and a guest (through the server's /j login) watch an episode, then ⏭ puts
// up the next episode, then a direct link, then a link passed on "through"
// alice, then one the server fetches (both relayed: the guests prepare
// them from the server's warm relay of the item). Every client prepares
// the next item in a hidden player (`MediaPipeline.prepare`) and the swap
// promotes it. The fake Jellyfin and the link's host answer with a delay
// and a capped rate, like a server elsewhere. Prints each client's phases
// (SwitchTrace) and the wall time from ⏭ to the server playing.
//
// WT_SWITCH_PRELOAD=0 turns the preload off (the cold path, for comparison);
// WT_SWITCH_DELAY_MS and WT_SWITCH_RATE_KBS set the remote's delay and rate.

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;
const _sid = 'ab12ab12ab12ab12ab12ab12ab12ab12';
const _series = '5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e';
const _ep1 = 'e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1';
const _ep2 = 'e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2';

/// Per API request, and before a stream's first byte (WT_SWITCH_DELAY_MS).
final _delay = Duration(milliseconds: int.tryParse(Platform.environment['WT_SWITCH_DELAY_MS'] ?? '') ?? 120);
/// Per stream connection, default 24 Mbit/s (WT_SWITCH_RATE_KBS).
final _bytesPerSec = (int.tryParse(Platform.environment['WT_SWITCH_RATE_KBS'] ?? '') ?? 3072) * 1024;

/// 60 s of 720p at about 4 Mbit/s with sound (headless mpv needs audio).
Future<String> _media() async {
  final path = '$_tmp/queue_switch_60s.mkv';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '60', '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '4M', '-g', '48', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

/// Serves [file] with ranges, after [_delay], at most [_bytesPerSec].
Future<void> _serveFile(HttpRequest req, String file) async {
  final f = File(file);
  final size = await f.length();
  final res = req.response;
  res.headers.set('Accept-Ranges', 'bytes');
  res.headers.contentType = ContentType('video', 'x-matroska');
  var start = 0, end = size - 1;
  final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(req.headers.value('range') ?? '');
  if (range != null) {
    start = int.tryParse(range.group(1)!) ?? 0;
    end = int.tryParse(range.group(2)!) ?? size - 1;
    if (end >= size) end = size - 1;
    res.statusCode = 206;
    res.headers.set('Content-Range', 'bytes $start-$end/$size');
  }
  res.contentLength = end - start + 1;
  await Future.delayed(_delay);
  try {
    final raf = await f.open();
    try {
      await raf.setPosition(start);
      var at = start;
      const chunk = 64 * 1024;
      final clock = Stopwatch()..start();
      var sent = 0;
      while (at <= end) {
        final n = (end - at + 1).clamp(0, chunk);
        res.add(await raf.read(n));
        await res.flush();
        at += n;
        sent += n;
        final due = Duration(microseconds: sent * 1000000 ~/ _bytesPerSec);
        if (due > clock.elapsed) await Future.delayed(due - clock.elapsed);
      }
    } finally {
      await raf.close();
    }
    await res.close();
  } catch (_) {}
}

class _FakeJellyfin {
  final String file;
  final tokens = {'ATOKEN': 'ua', 'CTOKEN': 'uc', 'HOSTTOKEN': 'uh'};
  late HttpServer _server;
  _FakeJellyfin(this.file);

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Map<String, Object?> _item(String id) => {
        'Id': id,
        'Name': id == _ep1 ? 'Pilot' : 'Second',
        'Type': 'Episode',
        'ServerId': _sid,
        'SeriesId': _series,
        'SeriesName': 'Fake Show',
        'ParentIndexNumber': 1,
        'IndexNumber': id == _ep1 ? 1 : 2,
        'RunTimeTicks': 60 * jellyfinTicksPerSecond,
      };

  Future<void> _handle(HttpRequest req) async {
    final auth = req.headers.value('authorization') ?? '';
    await req.drain<void>();
    final res = req.response;
    final path = req.uri.path;
    if (RegExp(r'^/Videos/\w+/stream$').hasMatch(path)) return _serveFile(req, file);
    await Future.delayed(_delay);
    Future<void> json(Object v) async {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(v));
      await res.close();
    }

    if (path == '/System/Info/Public') return json({'Id': _sid, 'ServerName': 'Fake', 'Version': '10.11.11'});
    final token = RegExp(r'Token="([^"]*)"').firstMatch(auth)?.group(1);
    final user = tokens[token];
    if (user == null) {
      res.statusCode = 401;
      return res.close();
    }
    final m = RegExp(r'^/Items/(\w+)(/PlaybackInfo)?$').firstMatch(path);
    if (m != null && m.group(2) != null) {
      return json({
        'PlaySessionId': 'ps-$user-${m.group(1)}',
        'MediaSources': [
          {
            'Id': m.group(1),
            'SupportsDirectPlay': true,
            'MediaStreams': [
              {'Index': 0, 'Type': 'Video', 'Codec': 'h264'},
              {'Index': 1, 'Type': 'Audio', 'Language': 'jpn', 'Codec': 'aac'},
            ],
          }
        ],
      });
    }
    if (m != null) return json(_item(m.group(1)!));
    if (path == '/Shows/$_series/Episodes') {
      return json({'Items': [_item(_ep1), _item(_ep2)], 'TotalRecordCount': 2});
    }
    if (path.startsWith('/Sessions/Playing')) {
      res.statusCode = 204;
      return res.close();
    }
    if (path.startsWith('/UserPlayedItems/') || path.startsWith('/UserItems/')) {
      return json({'Played': false, 'PlaybackPositionTicks': 0});
    }
    res.statusCode = 404;
    await res.close();
  }
}

Future<void> _poll(FutureOr<bool> Function() cond, String what,
    {Duration timeout = const Duration(seconds: 40), Duration every = const Duration(milliseconds: 200)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(every);
  }
  fail('timed out waiting for $what');
}

Future<JellyfinAccounts> _account(String base, String token, String userId, String device) async {
  final a = JellyfinAccounts(store: MemoryJellyfinStore(), deviceName: device);
  await a.ensureLoaded(validate: false);
  await a.link(
    baseUrl: base,
    server: const JellyfinServerInfo(id: _sid, name: 'Fake', version: '10.11.11'),
    auth: JellyfinAuthResult(accessToken: token, user: JellyfinUser(id: userId, name: userId), serverId: _sid),
  );
  return a;
}

void main() {
  test(
    'Up next: ⏭ to a Jellyfin episode, then to a direct link, timed per client',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      // mpv's warnings, as the host writes them to the app log.
      final mpvLines = <String>[];
      // (The root's records, the app's logging not being hierarchical.)
      final logSub = createLogger('mpv').onRecord.listen((r) {
        if (r.loggerName == 'mpv') mpvLines.add(r.message);
      });
      final preload = Platform.environment['WT_SWITCH_PRELOAD'] != '0';
      final file = await _media();
      final jelly = _FakeJellyfin(file);
      await jelly.start();
      final link = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      link.listen((req) => _serveFile(req, file));
      final linkUrl = 'http://127.0.0.1:${link.port}/clip.mkv';
      final server = SyncServer(ytDlp: YtDlp('$_tmp/queue_switch_server_ytdlp', enabled: false), AppConfig(
        port: 0,
        secret: 'q',
        name: 'q',
        jellyfin: JellyfinCredential(
            baseUrl: jelly.base,
            serverId: _sid,
            token: 'HOSTTOKEN',
            client: 'Watch Together',
            device: 'Host',
            deviceId: 'host-1',
            version: '9.9.9'),
      ));
      // Relic logs errors writing a response (a relay response cut short
      // when its relay is dropped at a swap or stop) as it does outside
      // tests; anything else fails the test.
      final serverErrors = <Object>[];
      await runZonedGuarded(server.start, (e, _) {
        if ('$e'.contains('Content size below specified contentLength') || '$e'.contains('did not arrive')) return;
        serverErrors.add(e);
      });
      final ytDlp = AppYtDlp(YtDlp('$_tmp/queue_switch_ytdlp', enabled: false));
      final accA = await _account(jelly.base, 'ATOKEN', 'ua', 'A-PC');
      final accC = await _account(jelly.base, 'CTOKEN', 'uc', 'C-PC');
      final accB = JellyfinAccounts(store: MemoryJellyfinStore());
      await accB.ensureLoaded(validate: false);
      final hosts = <SessionCoordinator, MediaKitHost>{};
      SessionCoordinator coord(JellyfinAccounts acc) {
        final host = MediaKitHost()..init();
        final c = SessionCoordinator(
            jellyfin: acc, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()), ytDlp: ytDlp, players: host)
          ..media.preloadEnabled = preload;
        hosts[c] = host;
        return c;
      }
      final a = coord(accA), b = coord(accB), c = coord(accC);
      final all = {'alice': a, 'guest': b, 'carol': c};
      ConnectParams params(String name, [HelloMedia? media]) =>
          ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: 'q', name: name, media: media);
      final report = <String>[];

      Future<void> switchOnce(String what) async {
        final before = a.serverState.peek()!.mediaId;
        // Time to get ready (Up next's first item, on every client).
        await Future.delayed(const Duration(seconds: 8));
        if (preload) {
          for (final x in all.values) {
            expect(x.queue.warm.peek()?.state, WarmState.ready, reason: 'ready on every client before ⏭');
            expect(x.media.preloadUrl, isNotNull, reason: 'preloaded on every client');
          }
        }
        final clock = Stopwatch()..start();
        a.queue.skip();
        await _poll(() {
          final r = a.serverState.peek();
          return r != null && r.mediaId > before && r.transport == 'playing';
        }, '$what playing', every: const Duration(milliseconds: 10));
        final total = clock.elapsedMilliseconds;
        final id = a.serverState.peek()!.mediaId;
        report.add('$what (${preload ? 'preload' : 'cold'}): ⏭ to server playing $total ms');
        for (final e in all.entries) {
          report.add('  ${e.key}: ${e.value.switchTrace.of(id)}');
        }
        await _poll(() => all.values.every((x) => x.playback.player.state.playing), 'all play $what');
        // The promoted player is the session player: marks, tracks and
        // the volume carried over, the clock moves; the old one retired.
        for (final x in all.values) {
          expect(x.playback.durationSecs, greaterThan(59));
          expect(x.playback.player.state.volume, 0, reason: 'volume kept');
          await _poll(() => x.playback.tracks.peek().isNotEmpty, 'tracks listed');
          final host = hosts[x]!;
          await host.retiring;
          expect(host.live, lessThanOrEqualTo(2), reason: 'the session player and at most the next prepared one');
        }
        final at = a.playback.positionSecs;
        await Future.delayed(const Duration(seconds: 1));
        expect(a.playback.positionSecs, greaterThan(at + 0.5));
      }

      try {
        await a.connect(params('alice', const HelloMedia(
            name: 'Pilot', size: 0, duration: 0, jellyfin: JellyfinRef(serverId: _sid, itemId: _ep1, title: 'Pilot'))));
        await b.connect(params('guest'));
        await c.connect(params('carol'));
        for (final x in all.values) {
          await x.playback.setVolume(0);
        }
        await _poll(() => all.values.every((x) => x.playback.durationSecs > 59), 'all opened episode 1');
        expect(await a.queue.add(pickForRef(accA, const JellyfinRef(serverId: _sid, itemId: _ep2, title: 'Second'))!),
            isNull);
        expect(await a.queue.add(LinkMedia(linkUrl, relay: LinkRelay.direct)), isNull);
        await _poll(() => (a.serverState.peek()?.queue.length ?? 0) == 2, 'two queued');
        for (final x in all.values) {
          x.toggleReady();
        }
        await _poll(() => all.values.every((x) => x.playback.player.state.playing), 'all playing episode 1');

        await switchOnce('episode 2');
        expect(refOfStateMedia(a.serverState.peek()!.media)?.itemId, _ep2);
        expect(b.jellyfinPlan.peek(), isA<RelayPlay>());
        if (preload) {
          for (final x in all.values) {
            expect(x.switchTrace.of(x.serverState.peek()!.mediaId), contains(SwitchTrace.preloaded));
          }
        }
        await switchOnce('direct link');
        expect(stateMediaUrl(a.serverState.peek()!), linkUrl);

        // Relayed items: alice passes the link on, then the server fetches
        // it. Each is fed into the server's warm relay while it waits, so
        // bob and carol (and for the fetched one alice) preload from it,
        // and the swap promotes that relay with its buffer.
        for (final (what, mode) in [('link through alice', LinkRelay.me), ('server-fetched link', LinkRelay.server)]) {
          expect(await a.queue.add(LinkMedia(linkUrl, relay: mode)), isNull);
          await _poll(() => a.serverState.peek()?.queue.isNotEmpty ?? false, '$what queued');
          final id = a.serverState.peek()!.queue.first.id;
          await _poll(() => a.serverState.peek()?.queue.firstOrNull?.media.relay?.live ?? false, '$what warm relay live');
          await switchOnce(what);
          final relay = stateMediaRelay(a.serverState.peek()!);
          expect(relay?.queueId, id, reason: 'the warm relay became the media\'s');
          expect(relay?.fetch, mode == LinkRelay.server);
          if (preload) {
            for (final x in all.values) {
              expect(x.switchTrace.of(x.serverState.peek()!.mediaId), contains(SwitchTrace.preloaded),
                  reason: '$what preloaded');
            }
          }
        }
        // ignore: avoid_print
        print(report.join('\n'));
        expect(serverErrors, isEmpty);
        // No command reached a player still opening, and the
        // cache is in RAM on every player (no "Failed to create file cache").
        expect(mpvLines.where((l) => l.contains('error running command') || l.contains('file cache')), isEmpty);

        // Nothing queued: no preload. Queued and taken off again: dropped.
        if (preload) {
          await _poll(() => all.values.every((x) => x.media.preloadUrl == null), 'nothing preloaded');
          expect(await a.queue.add(LinkMedia(linkUrl, relay: LinkRelay.direct)), isNull);
          await _poll(() => all.values.every((x) => x.media.preloadUrl == linkUrl), 'preloaded again');
          a.queue.remove(a.serverState.peek()!.queue.first.id);
          await _poll(() => all.values.every((x) => x.media.preloadUrl == null), 'dropped when taken off');
        }
        // Preloaded everywhere: every client starts from its preload.
        if (preload) {
          for (final x in all.values) {
            expect(x.switchTrace.of(x.serverState.peek()!.mediaId), contains(SwitchTrace.preloaded));
          }
        }
      } finally {
        await logSub.cancel();
        for (final x in all.values) {
          await x.dispose();
        }
        await server.stop();
        await jelly.stop();
        await link.close(force: true);
      }
    },
  );
}
