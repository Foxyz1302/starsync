import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:watch_together/src/playback/media_marks.dart';
import 'package:watch_together/src/session/session_coordinator.dart';
import 'package:watch_together/src/sync/state_diff.dart';

final _tmp = Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

/// 23 min mkv with chapters OP 0:30-2:00, Part A, ED 20:00-21:30, Part B,
/// two audio tracks (jpn, eng "Dub") and an English srt subtitle.
Future<String> _media() async {
  final path = '$_tmp/chapters_23m.mkv';
  if (await File(path).exists()) return path;
  final meta = File('$_tmp/chapters_meta.txt');
  String chapter(int start, int end, String title) =>
      '[CHAPTER]\nTIMEBASE=1/1000\nSTART=${start * 1000}\nEND=${end * 1000}\ntitle=$title\n';
  await meta.writeAsString(';FFMETADATA1\n'
      '${chapter(30, 120, 'OP')}${chapter(120, 1200, 'Part A')}'
      '${chapter(1200, 1290, 'ED')}${chapter(1290, 1380, 'Part B')}');
  final srt = File('$_tmp/chapters_subs.srt');
  await srt.writeAsString('1\n00:00:01,000 --> 00:00:05,000\nHello\n');
  final r = await Process.run('ffmpeg', [
    '-y', '-v', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=160x120:rate=10',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
    '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000',
    '-i', srt.path, '-i', meta.path,
    '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:s',
    '-map_metadata', '4', '-map_chapters', '4',
    '-metadata:s:a:0', 'language=jpn',
    '-metadata:s:a:1', 'language=eng', '-metadata:s:a:1', 'title=Dub',
    '-metadata:s:s:0', 'language=eng',
    '-t', '1380', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '10',
    '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '32k', '-c:s', 'srt', path,
  ]);
  if (r.exitCode != 0) fail('ffmpeg failed: ${r.stderr}');
  return path;
}

Future<void> _poll(
  FutureOr<bool> Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for $what');
}

void main() {
  test(
    'chapters and tracks from mpv; Skip OP and PgDn go through the server',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      MediaKit.ensureInitialized();
      final media = await _media();
      final server = SyncServer(AppConfig(port: 0, secret: 'ch', name: 'ch', mediaPath: media));
      await server.start();
      final a = SessionCoordinator();
      final b = SessionCoordinator();
      try {
        for (final (c, name) in [(a, 'a'), (b, 'b')]) {
          await c.connect(ConnectParams(
              host: '127.0.0.1', port: server.boundPort, secret: 'ch', name: name));
          await c.playback.player.setVolume(0);
        }
        await _poll(() => a.serverState.peek()?.members.length == 2, 'both in');

        // chapters signal: titles, starts, ends (last = duration).
        await _poll(() => a.playback.chapters.peek().length == 4 && a.playback.duration.peek() > Duration.zero,
            'chapters');
        final ch = a.playback.chapters.peek();
        // ignore: avoid_print
        print('chapters: $ch');
        expect(ch.map((c) => c.title), ['OP', 'Part A', 'ED', 'Part B']);
        expect(ch.map((c) => c.start.inSeconds), [30, 120, 1200, 1290]);
        expect(ch[2].end, ch[3].start);
        expect(ch[3].end.inSeconds, closeTo(1380, 1));
        expect(a.playback.opening.peek(),
            SkipRange(const Duration(seconds: 30), ch[1].start, SkipSource.chapter, title: 'OP'));
        expect(a.playback.ending.peek()!.start, const Duration(minutes: 20));
        expect(a.playback.segments.peek(), isEmpty, reason: 'not a Jellyfin item');

        // buffered signal: mpv's demuxer cache (the timeline's hatching)
        // runs ahead of the position.
        await _poll(() => a.playback.buffered.peek() > a.playback.position.peek() + const Duration(seconds: 5),
            'cache ahead');
        expect(a.playback.buffered.peek(), lessThanOrEqualTo(a.playback.duration.peek()));

        // tracks signal: two audio, one subtitle; mpv's choice marked.
        await _poll(() => a.playback.tracks.peek().length == 3, 'tracks');
        final tracks = a.playback.tracks.peek();
        // ignore: avoid_print
        print('tracks: $tracks');
        final audio = tracks.where((t) => t.type == JellyfinStreamType.audio).toList();
        expect(audio.map((t) => t.label), ['Japanese · AAC 1.0', 'English · AAC 1.0 · Dub']);
        expect(audio.first.selected, isTrue);
        await a.selectTrack(aid: 2);
        expect(a.playback.tracks.peek().where((t) => t.selected && t.type == JellyfinStreamType.audio).single.id, 2);

        a.toggleReady();
        b.toggleReady();
        await _poll(() => a.playback.player.state.playing && b.playback.player.state.playing, 'both playing');

        // Into the OP: the pill offers Skip OP to its end.
        a.seekTo(40);
        await _poll(() {
          final r = a.serverState.peek();
          return r != null && r.seekBy == a.connection.memberId && (r.position - 40).abs() < 2;
        }, 'server at 0:40');
        await _poll(() => a.skipOffer.peek()?.kind == SkipKind.opening, 'Skip OP offered');
        expect(a.skipOffer.peek()!.target, const Duration(minutes: 2));
        int seeks(SessionCoordinator c) => c.feedLog.peek().where((f) => f.action == 'seek').length;
        await _poll(() => seeks(b) >= 1 && seeks(b) == seeks(a), 'b saw the seek to 0:40');
        final seeksBefore = seeks(b);
        a.skip(a.skipOffer.peek()!);
        await _poll(() {
          final r = a.serverState.peek();
          return r != null &&
              r.seekBy == a.connection.memberId &&
              serverPositionAt(r, a.connection.serverNow()) >= 120 &&
              serverPositionAt(r, a.connection.serverNow()) < 125;
        }, 'server at the OP end');
        await _poll(() => b.playback.positionSecs >= 119.5 && b.playback.positionSecs < 126, 'b follows');
        await _poll(() => seeks(b) == seeksBefore + 1, 'b saw the Skip OP seek');
        await Future.delayed(const Duration(seconds: 1));
        expect(seeks(b), seeksBefore + 1, reason: 'Skip OP is one seek');
        await _poll(() => a.skipOffer.peek() == null, 'pill gone after the OP');

        // PgDn: next chapter (ED at 20:00), for everyone.
        expect(a.stepChapter(1), isTrue);
        await _poll(() => b.playback.positionSecs >= 1199.5 && b.playback.positionSecs < 1206, 'b at the ED');
        await _poll(() => a.skipOffer.peek()?.kind == SkipKind.ending, 'Skip ED offered');
        expect(a.skipOffer.peek()!.target, const Duration(minutes: 21, seconds: 30));
      } finally {
        await a.dispose();
        await b.dispose();
        await server.stop();
      }
    },
  );
}
