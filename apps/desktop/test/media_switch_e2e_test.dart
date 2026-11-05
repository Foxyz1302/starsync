import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/playback/yt_dlp_app.dart';
import 'package:starsync/src/screens/home/picked_media.dart';
import 'package:starsync/src/session/session_coordinator.dart';

// Commands that come while a media is switching (no player yet, or its
// media not loaded) wait and go to the new player once, so mpv never gets a
// seek it cannot run ("error running command seek", "event:5").

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

Future<String> _media() async {
  final path = '$_tmp/media_switch_60s.mp4';
  if (await File(path).exists()) return path;
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-t', '60', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-movflags', '+faststart', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

Future<void> _poll(FutureOr<bool> Function() cond, String what,
    {Duration timeout = const Duration(seconds: 30), Duration every = const Duration(milliseconds: 100)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(every);
  }
  fail('timed out waiting for $what');
}

void main() {
  test('commands during a switch wait and apply once to the new player, without mpv errors',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    final file = await _media();
    // A host that answers a media request only after 2 s (a slow CDN):
    // the new player has nothing loaded for that long.
    final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    slow.listen((req) async {
      final size = await File(file).length();
      final r = resolveMediaRequest(rangeHeader: req.headers.value('range'), size: size, filename: 'v.mp4');
      if (r.status == 206 || r.status == 200) await Future.delayed(const Duration(seconds: 2));
      req.response.statusCode = r.status;
      r.headers.forEach(req.response.headers.set);
      try {
        if (r.status == 200 || r.status == 206) {
          await req.response.addStream(File(file).openRead(r.start, (r.end ?? size - 1) + 1));
        }
        await req.response.close();
      } catch (_) {}
    });
    final server = SyncServer(const AppConfig(port: 0, secret: 'p15', name: 'p15'));
    await server.start();
    final acc = JellyfinAccounts(store: MemoryJellyfinStore());
    await acc.ensureLoaded(validate: false);
    final c = SessionCoordinator(
        jellyfin: acc,
        trackPrefs: TrackPrefs(store: MemoryJellyfinStore()),
        ytDlp: AppYtDlp(YtDlp('$_tmp/media_switch_no_ytdlp', enabled: false)));
    final errors = <String>[];
    try {
      await c.connect(ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: 'p15', name: 'solo'));
      await c.playback.setVolume(0);
      final before = c.serverState.peek()?.mediaId ?? 0;
      expect(await c.swapPicked(LinkMedia('http://127.0.0.1:${slow.port}/clip.mp4')), isNull);
      // The switch: the state names the new media, the new player waits on
      // the slow host.
      await _poll(() => (c.serverState.peek()?.mediaId ?? 0) > before && c.media.openUrl != null, 'switching');
      final p = c.playback.player;
      final sub = p.logs.listen((l) {
        if (l.text.contains('error running command') || l.text.contains('event:5')) errors.add(l.text);
      });
      expect(c.playback.switching, isTrue, reason: 'its media is not loaded yet');
      final seeks = c.playback.seeksSent;
      // The user skips ahead twice, changes the volume and readies, all
      // while the media is still on its way.
      c.seekTo(12);
      c.seekTo(20);
      await c.playback.setVolume(30);
      c.play();
      expect(c.playback.seeksSent, seeks, reason: 'nothing reached mpv yet');
      await _poll(() => !c.playback.switching, 'loaded', timeout: const Duration(seconds: 20));
      await _poll(() => c.playback.playing && c.playback.positionSecs > 20, 'playing from 20 s');
      expect(c.playback.positionSecs, lessThan(23), reason: 'the latest seek, applied once it loaded');
      expect(c.playback.seeksSent - seeks, 1, reason: 'the queued seeks went out as one');
      expect(c.playback.player.state.volume, 30, reason: 'the volume went to the new player');
      await sub.cancel();
      expect(errors, isEmpty, reason: 'no command reached a player without its media');
    } finally {
      await c.dispose();
      await server.stop();
      await slow.close(force: true);
    }
  });
}
