import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:watch_together/src/jellyfin/accounts.dart';
import 'package:watch_together/src/jellyfin/session_media.dart';
import 'package:watch_together/src/jellyfin/track_prefs.dart';
import 'package:watch_together/src/playback/media_marks.dart';
import 'package:watch_together/src/screens/home/picked_media.dart';
import 'package:watch_together/src/session/session_coordinator.dart';

// Two account holders and a guest watch Jellyfin episodes together over a
// real sync server, real mpv and a local fake Jellyfin (never a real one):
// account holders direct-play with their own token and report progress,
// the guest plays through the server's /j relay with the host credential.

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;
const _sid = 'f00dfeedf00dfeedf00dfeedf00dfeed';
const _series = '5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e';
const _ep1 = 'e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1';
const _ep2 = 'e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2';

/// 20 s, h264 + two audio tracks (Japanese first, English second).
Future<String> _media() async {
  final path = '$_tmp/jellyfin_e2e_20s.mkv';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000',
    '-map', '0:v', '-map', '1:a', '-map', '2:a',
    '-t', '20', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac',
    '-metadata:s:a:0', 'language=jpn', '-metadata:s:a:0', 'title=Japanese',
    '-metadata:s:a:1', 'language=eng', '-metadata:s:a:1', 'title=English',
    path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

class _Call {
  final String method;
  final String path;
  final String auth;
  final Map<String, dynamic>? body;
  _Call(this.method, this.path, this.auth, this.body);
}

/// Just enough Jellyfin: public info, users, PlaybackInfo, items, episodes,
/// the static stream with ranges, and the three Sessions reports. Every
/// request is recorded with its Authorization header.
class _FakeJellyfin {
  final String file;
  final tokens = {'ATOKEN': 'ua', 'CTOKEN': 'uc', 'HOSTTOKEN': 'uh'};
  final calls = <_Call>[];
  late HttpServer _server;
  _FakeJellyfin(this.file);

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  static Map<String, String> authFields(String header) => {
        for (final m in RegExp(r'(\w+)="([^"]*)"').allMatches(header))
          m.group(1)!: Uri.decodeComponent(m.group(2)!),
      };

  Map<String, Object?> _item(String id) => {
        'Id': id,
        'Name': id == _ep1 ? 'Pilot' : 'Second',
        'Type': 'Episode',
        'ServerId': _sid,
        'SeriesId': _series,
        'SeriesName': 'Fake Show',
        'SeasonId': 'seas1',
        'ParentIndexNumber': 1,
        'IndexNumber': id == _ep1 ? 1 : 2,
        'RunTimeTicks': 20 * jellyfinTicksPerSecond,
      };

  Future<void> _handle(HttpRequest req) async {
    final auth = req.headers.value('authorization') ?? '';
    final bodyText = await utf8.decoder.bind(req).join();
    Map<String, dynamic>? body;
    try {
      body = bodyText.isEmpty ? null : jsonDecode(bodyText) as Map<String, dynamic>;
    } catch (_) {}
    calls.add(_Call(req.method, req.uri.path, auth, body));
    final res = req.response;
    Future<void> json(Object v) async {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(v));
      await res.close();
    }

    final path = req.uri.path;
    if (path == '/System/Info/Public') {
      return json({'Id': _sid, 'ServerName': 'Fake Jellyfin', 'Version': '10.11.11'});
    }
    final token = authFields(auth)['Token'] ?? req.uri.queryParameters['api_key'];
    final user = tokens[token];
    if (user == null) {
      res.statusCode = 401;
      return res.close();
    }
    if (path == '/Users/Me') return json({'Id': user, 'Name': user, 'ServerId': _sid});
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
              {'Index': 1, 'Type': 'Audio', 'Language': 'jpn', 'Title': 'Japanese', 'Codec': 'aac'},
              {'Index': 2, 'Type': 'Audio', 'Language': 'eng', 'Title': 'English', 'Codec': 'aac'},
            ],
          }
        ],
      });
    }
    if (m != null) return json(_item(m.group(1)!));
    if (path == '/Shows/$_series/Episodes') {
      return json({'Items': [_item(_ep1), _item(_ep2)], 'TotalRecordCount': 2});
    }
    if (path == '/MediaSegments/$_ep1') {
      return json({
        'Items': [
          {'Id': 'seg1', 'ItemId': _ep1, 'Type': 'Intro', 'StartTicks': 20000000, 'EndTicks': 60000000},
        ],
        'TotalRecordCount': 1,
        'StartIndex': 0,
      });
    }
    if (path.startsWith('/Sessions/Playing')) {
      res.statusCode = 204;
      return res.close();
    }
    if (RegExp(r'^/Videos/\w+/stream$').hasMatch(path)) return _stream(req);
    res.statusCode = 404;
    await res.close();
  }

  Future<void> _stream(HttpRequest req) async {
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
    try {
      await res.addStream(f.openRead(start, end + 1));
      await res.close();
    } catch (_) {}
  }

  List<_Call> sessions({String? token}) => [
        for (final c in calls)
          if (c.path.startsWith('/Sessions/Playing') &&
              (token == null || authFields(c.auth)['Token'] == token))
            c
      ];

  List<_Call> streams(String token) => [
        for (final c in calls)
          if (c.path.startsWith('/Videos/') && authFields(c.auth)['Token'] == token) c
      ];
}

Future<void> _poll(FutureOr<bool> Function() cond, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out waiting for $what');
}

Future<JellyfinAccounts> _account(String base, String token, String userId, String device) async {
  final a = JellyfinAccounts(store: MemoryJellyfinStore(), deviceName: device);
  await a.ensureLoaded(validate: false);
  await a.link(
    baseUrl: base,
    server: const JellyfinServerInfo(id: _sid, name: 'Fake Jellyfin', version: '10.11.11'),
    auth: JellyfinAuthResult(
        accessToken: token, user: JellyfinUser(id: userId, name: userId), serverId: _sid),
  );
  return a;
}

String _kind(_Call c) => c.path.split('/').last;

void main() {
  test(
    'account holders direct-play and report, the guest plays through the relay, all in sync',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      MediaKit.ensureInitialized();
      final jelly = _FakeJellyfin(await _media());
      await jelly.start();
      const relayCred = (client: 'Watch Together', device: 'HostBox', deviceId: 'host-dev-1', version: '9.9.9');
      final server = SyncServer(AppConfig(
        port: 0,
        secret: 'jf',
        name: 'jf',
        jellyfin: JellyfinCredential(
          baseUrl: jelly.base,
          serverId: _sid,
          token: 'HOSTTOKEN',
          client: relayCred.client,
          device: relayCred.device,
          deviceId: relayCred.deviceId,
          version: relayCred.version,
        ),
      ));
      await server.start();
      final accA = await _account(jelly.base, 'ATOKEN', 'ua', 'A-PC');
      final accC = await _account(jelly.base, 'CTOKEN', 'uc', 'C-PC');
      final accB = JellyfinAccounts(store: MemoryJellyfinStore());
      await accB.ensureLoaded(validate: false);
      final a = SessionCoordinator(jellyfin: accA, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      final b = SessionCoordinator(jellyfin: accB, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      final c = SessionCoordinator(jellyfin: accC, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      final all = [a, b, c];
      ConnectParams params(String name, [HelloMedia? media]) => ConnectParams(
          host: '127.0.0.1', port: server.boundPort, secret: 'jf', name: name, media: media);
      try {
        // A hosts the episode as a ref: no URL or token on the wire.
        await a.connect(params('alice', const HelloMedia(
            name: 'Pilot',
            size: 0,
            duration: 0,
            jellyfin: JellyfinRef(serverId: _sid, itemId: _ep1, title: 'Pilot', subtitle: 'Fake Show · S1E1'))));
        await _poll(() => a.serverState.peek()?.media?['jellyfin'] != null, 'ref on the server');
        expect(a.serverState.peek()!.media!.containsKey('url'), isFalse);
        expect(a.serverState.peek()!.relay, isTrue);
        await b.connect(params('guest'));
        await c.connect(params('carol'));
        for (final x in all) {
          await x.playback.player.setVolume(0);
        }
        await _poll(() => all.every((x) => x.playback.durationSecs > 19), 'all three opened the item');
        expect(a.jellyfinPlan.peek(), isA<OwnPlay>());
        await _poll(() {
          final members = a.serverState.peek()?.members ?? const [];
          final jf = {for (final m in members) m.name: m.jf[_sid]};
          return jf['alice'] == true && jf['carol'] == true && jf['guest'] == false;
        }, 'jf access in the member list');
        expect(a.nextEpisode.peek()?.item.id, _ep2);
        expect(b.nextEpisode.peek(), isNull, reason: 'guests cannot resolve the next one');
        // MediaSegments with an account; the guest (relay) has none.
        await _poll(() => a.playback.segments.peek().isNotEmpty, 'segments');
        expect(a.playback.opening.peek()?.source, SkipSource.segment);
        expect(a.playback.opening.peek()?.end, const Duration(seconds: 6));
        expect(b.playback.segments.peek(), isEmpty);
        expect(jelly.calls.where((c) => c.path.startsWith('/MediaSegments') && _FakeJellyfin.authFields(c.auth)['Token'] == 'CTOKEN'),
            isNotEmpty);

        for (final x in all) {
          x.toggleReady();
        }
        await _poll(() => all.every((x) => x.playback.player.state.playing), 'all playing');
        await Future.delayed(const Duration(seconds: 4));
        final pos = [for (final x in all) x.playback.positionSecs];
        // ignore: avoid_print
        print('positions after 4 s: $pos');
        for (final p in pos) {
          expect((p - pos.first).abs(), lessThan(1.0), reason: 'in sync: $pos');
        }

        // Pause (A unreadies): an immediate Progress with IsPaused.
        a.toggleReady();
        await _poll(() => !a.playback.player.state.playing, 'held');
        await _poll(
            () => jelly.sessions(token: 'ATOKEN').any((s) =>
                _kind(s) == 'Progress' && s.body?['IsPaused'] == true),
            'paused progress');
        a.toggleReady();
        await _poll(() => all.every((x) => x.playback.player.state.playing), 'playing again');

        // Account holders see the "Next episode" prompt (this item is
        // shorter than its 2 min lead); the guest cannot put it up.
        await _poll(() => a.nextPromptVisible.peek(), 'next prompt');
        expect(b.nextPromptVisible.peek(), isFalse);

        // Alice and the guest pick English; it carries to the next episode.
        await a.selectTrack(aid: 2);
        await b.selectTrack(aid: 2);
        await _poll(
            () => jelly.sessions(token: 'ATOKEN').any((s) =>
                _kind(s) == 'Progress' && s.body?['AudioStreamIndex'] == 2),
            'track change reported');

        // Near the end: finished -> Stopped, then one auto-advance swap.
        a.seekTo(16);
        await _poll(() => a.serverState.peek()?.transport == 'finished', 'finished',
            timeout: const Duration(seconds: 20));
        final finishedId = a.serverState.peek()!.mediaId;
        await _poll(() => a.autoAdvance.peek() != null && c.autoAdvance.peek() != null,
            'both account holders count down');
        expect(b.autoAdvance.peek(), isNull);
        final swappers = [a.autoAdvance.peek()!.swapper, c.autoAdvance.peek()!.swapper];
        expect(swappers.where((s) => s), hasLength(1),
            reason: 'exactly one designated swapper: the lowest member id (alice, m1)');
        expect(a.autoAdvance.peek()!.swapper, isTrue);
        await _poll(() => (a.serverState.peek()?.mediaId ?? 0) > finishedId, 'advanced',
            timeout: const Duration(seconds: 20));
        await Future.delayed(const Duration(seconds: 3));
        expect(a.serverState.peek()!.mediaId, finishedId + 1, reason: 'no double swap');
        expect(refOfStateMedia(a.serverState.peek()!.media)!.itemId, _ep2);
        await _poll(() => all.every((x) => x.playback.durationSecs > 19 && x.jellyfinPlan.peek() != null),
            'all opened the next episode');
        expect(b.jellyfinPlan.peek(), isA<RelayPlay>());
        expect((b.jellyfinPlan.peek() as RelayPlay).url, endsWith('/$_ep2'));
        await _poll(() async => (await a.playback.currentTrackIds()).aid == 2, 'alice keeps English');
        await _poll(() async => (await b.playback.currentTrackIds()).aid == 2, 'guest keeps English');
        expect((await c.playback.currentTrackIds()).aid, 1, reason: 'carol never chose');
        expect(a.previousEpisode.peek()?.item.id, _ep1);
        expect(a.nextEpisode.peek(), isNull);

        await a.leave();
        await c.leave();
        await Future.delayed(const Duration(milliseconds: 300));

        // Progress only from account holders, exactly their own device.
        final infoA = accA.clientInfo, infoC = accC.clientInfo;
        void ownHeader(_Call call, JellyfinClientInfo info, String token) {
          final f = _FakeJellyfin.authFields(call.auth);
          expect(f, {
            'Client': info.client,
            'Device': info.device,
            'DeviceId': info.deviceId,
            'Version': info.version,
            'Token': token,
          }, reason: '${call.method} ${call.path}');
        }

        final sessions = jelly.sessions();
        expect(sessions, isNotEmpty);
        expect(sessions.every((s) => ['ATOKEN', 'CTOKEN'].contains(_FakeJellyfin.authFields(s.auth)['Token'])),
            isTrue, reason: 'no reports from the guest or the relay credential');
        final aCalls = jelly.sessions(token: 'ATOKEN');
        for (final s in aCalls) {
          ownHeader(s, infoA, 'ATOKEN');
        }
        for (final s in jelly.sessions(token: 'CTOKEN')) {
          ownHeader(s, infoC, 'CTOKEN');
        }
        final ep1 = [for (final s in aCalls) if (s.body?['ItemId'] == _ep1) _kind(s)];
        final ep2 = [for (final s in aCalls) if (s.body?['ItemId'] == _ep2) _kind(s)];
        // ignore: avoid_print
        print('alice reports: ep1 $ep1, ep2 $ep2');
        expect(ep1.first, 'Playing');
        expect(ep1, contains('Progress'));
        expect(ep1.last, 'Stopped');
        expect(ep1.where((k) => k == 'Stopped'), hasLength(1));
        final stopped1 = aCalls.lastWhere((s) => s.body?['ItemId'] == _ep1);
        expect(stopped1.body!['PositionTicks'], greaterThan(19 * jellyfinTicksPerSecond),
            reason: 'played to the end');
        expect(stopped1.body!['PlaySessionId'], 'ps-ua-$_ep1');
        expect(ep2.first, 'Playing');
        expect(ep2.last, 'Stopped', reason: 'leaving reports Stopped');
        final playing = aCalls.firstWhere((s) => _kind(s) == 'Playing');
        expect(playing.body!['AudioStreamIndex'], 1, reason: 'mpv aid 1 = Jellyfin index 1');
        expect(playing.body!['SubtitleStreamIndex'], -1);
        final stopped2 = aCalls.lastWhere((s) => s.body?['ItemId'] == _ep2);
        expect(stopped2.body!['PlaySessionId'], 'ps-ua-$_ep2');
        expect(aCalls.lastWhere((s) => _kind(s) != 'Stopped' && s.body?['ItemId'] == _ep2)
            .body!['AudioStreamIndex'], 2, reason: 'English carried over and reported');

        // Streams: own token with own fields; the relay with exactly the
        // configured credential.
        expect(jelly.streams('ATOKEN'), isNotEmpty);
        for (final s in jelly.streams('ATOKEN')) {
          ownHeader(s, infoA, 'ATOKEN');
        }
        final relayed = jelly.streams('HOSTTOKEN');
        expect(relayed, isNotEmpty, reason: 'the guest played through the relay');
        for (final s in relayed) {
          expect(_FakeJellyfin.authFields(s.auth), {
            'Client': relayCred.client,
            'Device': relayCred.device,
            'DeviceId': relayCred.deviceId,
            'Version': relayCred.version,
            'Token': 'HOSTTOKEN',
          });
        }
        expect(jelly.calls.any((c) => c.path.startsWith('/Videos/') && c.auth.isEmpty), isFalse,
            reason: 'no token-less (api_key) stream requests');
      } finally {
        for (final x in all) {
          await x.dispose();
        }
        await server.stop();
        await jelly.stop();
      }
    },
  );

  test(
    'a guest with no account and no relay sees the blocked state, then plays after linking',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      MediaKit.ensureInitialized();
      final jelly = _FakeJellyfin(await _media());
      await jelly.start();
      final server = SyncServer(const AppConfig(port: 0, secret: '', name: 'nr'));
      await server.start();
      final accA = await _account(jelly.base, 'ATOKEN', 'ua', 'A-PC');
      final accB = JellyfinAccounts(store: MemoryJellyfinStore());
      await accB.ensureLoaded(validate: false);
      final a = SessionCoordinator(jellyfin: accA, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      final b = SessionCoordinator(jellyfin: accB, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      try {
        await a.connect(ConnectParams(
            host: '127.0.0.1',
            port: server.boundPort,
            secret: '',
            name: 'alice',
            media: const HelloMedia(
                name: 'Pilot', size: 0, duration: 0, jellyfin: JellyfinRef(serverId: _sid, itemId: _ep1))));
        await b.connect(ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: '', name: 'bob'));
        await _poll(() => b.jellyfinBlocked.peek() != null, 'blocked');
        expect(b.serverState.peek()!.relay, isFalse);
        expect(b.jellyfinBlocked.peek()!.message, contains('nobody is passing it on'));
        // Linking an account (Integrations) retries by itself.
        await accB.link(
            baseUrl: jelly.base,
            server: const JellyfinServerInfo(id: _sid, name: 'Fake Jellyfin', version: '10.11.11'),
            auth: const JellyfinAuthResult(
                accessToken: 'CTOKEN', user: JellyfinUser(id: 'uc', name: 'uc'), serverId: _sid));
        await _poll(() => b.jellyfinPlan.peek() is OwnPlay && b.playback.durationSecs > 19,
            'plays with the new account');
        expect(b.jellyfinBlocked.peek(), isNull);
      } finally {
        await a.dispose();
        await b.dispose();
        await server.stop();
        await jelly.stop();
      }
    },
  );

  // The VPS case: a dedicated server with no Jellyfin login. Whoever puts
  // the item up passes it on to guests without an account.
  test(
    'dedicated server without a login: the guest plays through the member who put it up',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      MediaKit.ensureInitialized();
      final jelly = _FakeJellyfin(await _media());
      await jelly.start();
      final server = SyncServer(const AppConfig(port: 0, secret: '', name: 'vps'));
      await server.start();
      final accA = await _account(jelly.base, 'ATOKEN', 'ua', 'A-PC');
      Future<JellyfinAccounts> none() async {
        final x = JellyfinAccounts(store: MemoryJellyfinStore());
        await x.ensureLoaded(validate: false);
        return x;
      }

      final a = SessionCoordinator(jellyfin: accA, trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      final b = SessionCoordinator(jellyfin: await none(), trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      final d = SessionCoordinator(jellyfin: await none(), trackPrefs: TrackPrefs(store: MemoryJellyfinStore()));
      ConnectParams params(String name) =>
          ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: '', name: name);
      try {
        await a.connect(params('alice'));
        await b.connect(params('guest'));
        await d.connect(params('dave'));
        for (final x in [a, b, d]) {
          await x.playback.player.setVolume(0);
        }
        // Alice picks from her browser: a ref plus a relay she sources.
        await a.swapPicked(JellyfinMedia(serverId: _sid, baseUrl: jelly.base, itemId: _ep1, title: 'Pilot'));
        await _poll(() => b.jellyfinPlan.peek() is RelayPlay && b.playback.durationSecs > 19, 'guest plays');
        expect((b.jellyfinPlan.peek() as RelayPlay).url, contains('/r/default/'));
        expect(a.jellyfinPlan.peek(), isA<OwnPlay>());
        expect(a.relaying.peek(), isTrue);
        expect(b.jellyfinBlocked.peek(), isNull);
        // Everyone present counts for the gate, Dave too.
        for (final x in [a, b, d]) {
          x.toggleReady();
        }
        await _poll(() => a.playback.player.state.playing && b.playback.player.state.playing, 'playing');
        await Future.delayed(const Duration(seconds: 3));
        expect((a.playback.positionSecs - b.playback.positionSecs).abs(), lessThan(1.0));
        // Every stream request carried alice's token, from her machine.
        expect(jelly.streams('ATOKEN'), isNotEmpty);
        expect(jelly.calls.where((c) => c.path.startsWith('/Videos/')).every((c) =>
            _FakeJellyfin.authFields(c.auth)['Token'] == 'ATOKEN'), isTrue);
        for (final x in [a, b, d]) {
          x.toggleReady();
        }

        // Dave has no account but a link with a key: he passes it on, the
        // key never leaves his machine.
        final link = '${jelly.base}/Videos/$_ep2/stream?static=true&api_key=ATOKEN';
        expect(await d.swapPicked(LinkMedia(link)), isNull);
        await _poll(() => (b.serverState.peek()?.media?['jellyfin'] as Map?)?['itemId'] == _ep2, 'ep2 up');
        expect(b.serverState.peek()!.toJson().toString(), isNot(contains('api_key')));
        await _poll(() => d.relaying.peek() && d.playback.durationSecs > 19, 'dave plays his link');
        await _poll(() => b.jellyfinPlan.peek() is RelayPlay && b.playback.durationSecs > 19, 'guest plays ep2');
        expect((b.jellyfinPlan.peek() as RelayPlay).url, contains('/r/default/'));
      } finally {
        for (final x in [a, b, d]) {
          await x.dispose();
        }
        await server.stop();
        await jelly.stop();
      }
    },
  );
}
