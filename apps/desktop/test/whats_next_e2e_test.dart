import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/files/scanner.dart' show scanFolder;
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/library/library_store.dart';
import 'package:starsync/src/library/local_next.dart';
import 'package:starsync/src/library/show_matcher.dart';
import 'package:starsync/src/screens/home/picked_media.dart';
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/watch/watch_history.dart';
import 'package:starsync/src/watch/watch_tracker.dart';

import 'show_matcher_test.dart' show FakeAniList;

// What's next with real coordinators, real mpv and a dedicated server: a
// file of a local show put up by a member is continued by the show's next
// episode (numbers skipped on the way said), the server's countdown runs
// on every screen, the member who has the file puts it up, a cancel is
// shared, and what was watched goes into the device's watch history.

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;
final _show = '$_tmp/whats_next_e2e/Show';

/// `Show - NN.mp4`, 6 s each, with audio (headless mpv needs it) and the
/// index first.
Future<String> _episode(int n) async {
  final path = '$_show/Show - ${n.toString().padLeft(2, '0')}.mp4';
  if (await File(path).exists()) return path;
  await Directory(_show).create(recursive: true);
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=${300 + 100 * n}:sample_rate=48000',
    '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '24', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-movflags', '+faststart', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
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

void main() {
  late SyncServer server;
  late List<SessionCoordinator> all;
  late List<Object> serverErrors;

  Future<SessionCoordinator> member(String name, {Future<LocalNext?> Function(String)? nextFile}) async {
    final acc = JellyfinAccounts(store: MemoryJellyfinStore());
    await acc.ensureLoaded(validate: false);
    final c = SessionCoordinator(
        jellyfin: acc,
        trackPrefs: TrackPrefs(store: MemoryJellyfinStore()),
        watch: WatchTracker(history: WatchHistory(persist: false)))
      ..nextFile = nextFile;
    all.add(c);
    await c.connect(ConnectParams(host: '127.0.0.1', port: server.boundPort, secret: 'pw', name: name));
    await c.playback.player.setVolume(0);
    return c;
  }

  setUp(() async {
    MediaKit.ensureInitialized();
    all = [];
    server = SyncServer(const AppConfig(port: 0, secret: 'pw', name: 'vps'));
    // A relay read cut short at a swap or the stop is reported to the
    // zone the server started in (DEVELOPMENT "Traps").
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

  test('a file of a show continues with its next episode; the countdown and a cancel are shared',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    final ep1 = await _episode(1);
    for (final n in [3, 4]) {
      await _episode(n);
    }
    final matcher = ShowMatcher(store: MemoryLibraryStore(), aniList: FakeAniList(), delay: (_) async {});
    final alice = await member('alice', nextFile: LocalNextFinder(matcher: matcher, scan: scanFolder).nextAfter);
    final bob = await member('bob');

    expect(await alice.swapPicked(FileMedia(ep1)), isNull);
    await _poll(() => bob.queue.continues.peek() != null, 'the continuation, for everyone');
    final next = bob.queue.continues.peek()!;
    expect((next.how, next.by, next.auto), (QueueHow.file, alice.connection.memberId, true));
    expect(next.media.name, 'Show - 03.mp4');
    expect(next.sub, contains('skips 2'));
    expect(bob.queue.items.peek(), isEmpty, reason: 'it is not an Up next item of its own');

    // Both ready: it plays to its end; the countdown is on both screens.
    await _poll(() => [alice, bob].every((x) => x.playback.durationSecs > 5), 'both opened episode 1');
    final first = alice.serverState.peek()!.mediaId;
    for (final x in [alice, bob]) {
      x.toggleReady();
    }
    await _poll(() => alice.serverState.peek()?.transport == 'finished', 'episode 1 ended');
    await _poll(() => [alice, bob].every((x) => (x.queue.countdown.peek()?.secondsLeft ?? 0) > 0), 'the countdown');
    expect(bob.queue.countdown.peek()!.item.id, next.id);
    await _poll(() => (bob.serverState.peek()?.mediaId ?? 0) > first, 'episode 3 up', timeout: const Duration(seconds: 20));
    expect(bob.serverState.peek()!.media!['name'], 'Show - 03.mp4');
    expect(bob.serverState.peek()!.media!['swapBy'], alice.connection.memberId, reason: 'who has the file put it up');

    // Watched through: in the device history of both (alice's by its path,
    // bob's by its name and size), recorded as the next one came up.
    await _poll(() => alice.watch.history.entry(WatchKey.file(ep1))?.played ?? false, "alice's history");
    await _poll(() => bob.watch.history.entries.any((e) => e.$2.played), "bob's history");

    // Episode 3 continues with 4; at its end bob cancels: for everyone.
    await _poll(() => alice.queue.continues.peek()?.media.name == 'Show - 04.mp4', 'episode 4 next');
    await _poll(() => [alice, bob].every((x) => x.playback.durationSecs > 5 && x.playback.player.state.playing),
        'both play episode 3', timeout: const Duration(seconds: 20));
    final third = alice.serverState.peek()!.mediaId;
    await _poll(() => (alice.queue.countdown.peek()?.secondsLeft ?? 0) > 0, 'the countdown again');
    bob.queue.cancelCountdown();
    await _poll(() => alice.queue.countdown.peek()?.secondsLeft == null && alice.queue.continues.peek() == null,
        'cancelled for alice too');
    await Future.delayed(const Duration(seconds: 12));
    expect(alice.serverState.peek()!.mediaId, third, reason: 'nothing came up');
    expect(alice.serverState.peek()!.transport, 'finished');
  });
}
