import 'dart:convert';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  late DateTime t;
  late SyncEngine engine;
  DateTime clock() => t;

  setUp(() {
    t = DateTime.utc(2026, 1, 1);
    engine = SyncEngine(clock: clock);
  });

  String join(String token, String name) => engine.applyJoin(token, name, '');

  void buffer(String token, double secs) =>
      engine.applyReport(token, engine.positionAt(), secs, engine.eventId);

  group('non-finite guards', () {
    test('seek/report/swap reject Infinity and NaN, broadcast stays encodable', () {
      join('a', 'alice');
      engine.applySeek('a', double.infinity);
      engine.applySeek('a', double.nan);
      expect(engine.position, 0);
      engine.applyReport('a', double.infinity, 1, engine.eventId);
      engine.applyReport('a', 1, double.infinity, engine.eventId);
      expect(engine.members['a']!.buffered, 0);
      expect(
          engine.applySwap('a',
              const HelloMedia(name: 'x', size: 1, duration: double.infinity)),
          isFalse);
      expect(engine.mediaId, 1);
      jsonEncode(engine.broadcast().toJson());
    });
  });

  group('membership + gate', () {
    test('join lands out-of-set, playback stays held', () {
      join('a', 'alice');
      expect(engine.transport, Transport.held);
      expect(engine.members['a']!.inSet, isFalse);
      final state = engine.broadcast();
      expect(state.members.single.inSet, isFalse);
    });

    test('single ready + buffered auto-plays', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      expect(engine.members['a']!.inSet, isTrue);
      expect(engine.transport, Transport.held);
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
    });

    test('late joiner does not halt playback', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
      join('b', 'bob');
      expect(engine.transport, Transport.playing);
      expect(engine.members['b']!.inSet, isFalse);
    });

    test('single unready in playing set pauses, stays in set', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 4.0);
      buffer('b', 4.0);
      expect(engine.transport, Transport.playing);
      engine.applyReady('b', false);
      expect(engine.transport, Transport.held);
      expect(engine.members['b']!.inSet, isTrue);
    });

    test('disconnect removes from quorum, playback resumes', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 4.0);
      buffer('b', 4.0);
      expect(engine.transport, Transport.playing);
      engine.applyLeave('b');
      expect(engine.transport, Transport.playing);
      expect(engine.members.containsKey('b'), isFalse);
    });

    test('stale ghosts excluded from gate', () {      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 4.0);
      buffer('b', 4.0);
      expect(engine.transport, Transport.playing);
      t = t.add(const Duration(seconds: 60));
      engine.sweepStale();
      expect(engine.transport, Transport.playing);
      expect(engine.broadcast().members.firstWhere((m) => m.id == 'm2').stale, isTrue);
    });

    test('silent past drop window removed with leave feed', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 4.0);
      buffer('b', 4.0);
      expect(engine.transport, Transport.playing);
      t = t.add(const Duration(seconds: 30));
      expect(engine.sweepDropped(), isEmpty);
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 61));
      buffer('a', 4.0);
      final dropped = engine.sweepDropped();
      expect(dropped, ['b']);
      expect(engine.members.containsKey('b'), isFalse);
      expect(engine.transport, Transport.playing);
      final leaves = engine.feed.drain().where((f) => f.action == 'leave').toList();
      expect(leaves.single.actor, 'bob');
      expect(leaves.single.reason, 'silent too long');
    });
  });

  group('quorum gate', () {
    test('one ready of two fresh stays held', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      buffer('a', 6.0);
      expect(engine.transport, Transport.held);
      expect(engine.members['a']!.inSet, isTrue);
    });

    test('second ready opens the gate', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      buffer('a', 6.0);
      expect(engine.transport, Transport.held);
      engine.applyReady('b', true);
      buffer('b', 6.0);
      expect(engine.transport, Transport.playing);
    });

    test('stale other exempts the lone watcher', () {
      join('a', 'alice');
      join('b', 'bob');
      t = t.add(const Duration(seconds: 16));
      engine.applyReady('a', true);
      buffer('a', 6.0);
      expect(engine.transport, Transport.playing);
    });

    test('late joiner outside the set never blocks', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 6.0);
      buffer('b', 6.0);
      expect(engine.transport, Transport.playing);
      join('c', 'cara');
      expect(engine.transport, Transport.playing);
    });
  });

  group('clock ownership', () {
    test('clock advances only while playing', () {
      expect(engine.positionAt(), 0);
      t = t.add(const Duration(seconds: 10));
      expect(engine.positionAt(), 0);
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 10));
      expect(engine.positionAt(), closeTo(10.0, 0.001));
    });

    test('lagging report cannot drag clock backward or forward', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 100));
      expect(engine.positionAt(), closeTo(100.0, 0.01));
      engine.applyReport('a', 5.0, 4.0, engine.eventId);
      expect(engine.positionAt(), closeTo(100.0, 0.01));
      engine.applyReport('a', 5000.0, 4.0, engine.eventId);
      expect(engine.positionAt(), closeTo(100.0, 0.01));
    });

    test('stale eventId report position ignored, buffer kept', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 50));
      engine.applySeek('a', 200.0);
      final eid = engine.eventId;
      engine.applyReport('a', 9999.0, 7.0, eid - 1);
      expect(engine.positionAt(), closeTo(200.0, 0.01));
      expect(engine.members['a']!.buffered, 7.0);
    });

    test('free seek while playing keeps transport, jumps edge', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 30));
      final before = engine.eventId;
      engine.applySeek('a', 600.0);
      expect(engine.transport, Transport.playing);
      expect(engine.positionAt(), closeTo(600.0, 0.01));
      expect(engine.eventId, greaterThan(before));
      expect(engine.members['a']!.ready, isTrue);
    });

    test('unpause uses server clock, laggards seek forward', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 4.0);
      buffer('b', 4.0);
      t = t.add(const Duration(seconds: 60));
      engine.applyReady('b', false);
      final frozen = engine.positionAt();
      expect(frozen, closeTo(60.0, 0.01));
      t = t.add(const Duration(seconds: 30));
      expect(engine.positionAt(), closeTo(60.0, 0.01));
      engine.applyReady('b', true);
      buffer('a', 4.0);
      buffer('b', 4.0);
      expect(engine.transport, Transport.playing);
      expect(engine.positionAt(), closeTo(60.0, 0.01));
    });
  });

  group('starvation without flag churn', () {
    test('zero buffer pauses, refill resumes, flags untouched', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
      engine.feed.drain();
      engine.applyReport('a', engine.positionAt(), 0.0, engine.eventId);
      expect(engine.transport, Transport.held);
      expect(engine.members['a']!.ready, isTrue);
      final feeds = engine.feed.drain().map((f) => f.action).toList();
      expect(feeds, contains('pause'));
      expect(feeds, isNot(contains('unready')));
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
    });
  });

  group('swap resets everything', () {
    test('swap bumps mediaId, clears sets, holds', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
      engine.applySwap('a',
          const HelloMedia(name: 'Ep02.mkv', size: 9, duration: 9.0));
      expect(engine.mediaId, 2);
      expect(engine.transport, Transport.held);
      expect(engine.positionAt(), 0);
      expect(engine.members['a']!.inSet, isFalse);
      expect(engine.members['a']!.ready, isFalse);
    });
  });

  group('force with actor feed', () {
    test('force-play-all readies everyone, attributed', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.feed.drain();
      engine.applyForce('a', 'all', true);
      expect(engine.members['b']!.ready, isTrue);
      expect(engine.members['b']!.inSet, isTrue);
      final feeds = engine.feed.drain();
      expect(
          feeds.any((f) => f.action == 'force-play' && f.actor == 'alice'),
          isTrue);
    });

    test('force single by member id', () {
      join('a', 'alice');
      final idB = join('b', 'bob');
      engine.feed.drain();
      engine.applyForce('a', idB, true);
      expect(engine.members['b']!.ready, isTrue);
      final feeds = engine.feed.drain();
      expect(
          feeds.any((f) =>
              f.action == 'force-ready' &&
              f.actor == 'alice' &&
              f.target == 'bob'),
          isTrue);
    });

    test('force unknown id is a no-op', () {
      join('a', 'alice');
      engine.feed.drain();
      engine.applyForce('a', 'm99', true);
      expect(engine.feed.drain(), isEmpty);
    });
  });

  group('flap stability', () {
    test('rapid unready/ready converges to playing, pairs stay balanced', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
      engine.feed.drain();
      for (var i = 0; i < 10; i++) {
        engine.applyReady('a', false);
        engine.applyReady('a', true);
      }
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
      expect(engine.members['a']!.ready, isTrue);
      final actions = engine.feed.drain().map((f) => f.action).toList();
      expect(actions.where((a) => a == 'pause').length,
          actions.where((a) => a == 'resume').length);
    });
  });

  group('input sanitizing', () {
    test('NaN/negative seek ignored, edge + eventId untouched', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 20));
      final eid = engine.eventId;
      engine.applySeek('a', double.nan);
      engine.applySeek('a', -5.0);
      expect(engine.positionAt(), closeTo(20.0, 0.01));
      expect(engine.eventId, eid);
      expect(engine.feed.drain().where((f) => f.action == 'seek'), isEmpty);
    });

    test('NaN buffered counts as zero, gate holds', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      engine.applyReport('a', 0, double.nan, engine.eventId);
      expect(engine.members['a']!.buffered, 0);
      expect(engine.transport, Transport.held);
    });
  });

  group('tiered correction', () {
    test('big drift seeks either direction', () {
      expect(correctionFor(ownPosition: 100, serverPosition: 0), Correction.seek);
      expect(correctionFor(ownPosition: 0, serverPosition: 100), Correction.seek);
    });

    test('ahead beyond 1.5s slows to 0.95x', () {
      expect(correctionFor(ownPosition: 3, serverPosition: 0), Correction.slowDown);
      expect(correctionFor(ownPosition: 1.6, serverPosition: 0), Correction.slowDown);
    });

    test('deadzone does nothing', () {
      expect(correctionFor(ownPosition: 1.0, serverPosition: 0), Correction.none);
      expect(correctionFor(ownPosition: 0, serverPosition: 3.0), Correction.none);
      expect(correctionFor(ownPosition: 5.1, serverPosition: 0), Correction.seek);
      expect(correctionFor(ownPosition: 5.0, serverPosition: 0), Correction.slowDown);
    });
  });

  group('broadcast shape', () {
    test('state JSON round-trips with member views', () {
      join('a', 'alice');
      final state = engine.broadcast();
      final back =
          StateBroadcast.fromJson(Map<String, Object?>.from(state.toJson()));
      expect(back.transport, 'held');
      expect(back.members.single.name, 'alice');
      expect(back.members.single.id, 'm1');
    });

    test('intent schemas round-trip', () {
      const r = ReadyIntent(ready: true, source: 'auto');
      expect(
          ReadyIntent.fromJson(Map<String, Object?>.from(r.toJson())).source,
          'auto');
      const s = SeekIntent(position: 42.5);
      expect(
          SeekIntent.fromJson(Map<String, Object?>.from(s.toJson())).position,
          42.5);
      const c = ChatMessage(text: 'hi');
      expect(
          ChatMessage.fromJson(Map<String, Object?>.from(c.toJson())).text,
          'hi');
      const rp = ReportMessage(position: 1, buffered: 2, eventId: 3);
      final rpBack =
          ReportMessage.fromJson(Map<String, Object?>.from(rp.toJson()));
      expect(rpBack.eventId, 3);
    });
  });
}
