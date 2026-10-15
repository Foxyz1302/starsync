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

  group('away', () {
    test('an away member never blocks; ready, force, swap and reports leave it away', () {
      join('a', 'alice');
      final bob = join('b', 'bob');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      expect(engine.transport, Transport.held, reason: 'bob is in the set');
      expect(engine.applyPresence('a', bob, Presence.away), isNull);
      final b = engine.members['b']!;
      expect(b.presence, Presence.away);
      expect(engine.countsForGate(b), isFalse);
      expect(engine.transport, Transport.playing);
      final feed = engine.feed.drain().lastWhere((f) => f.action == 'away');
      expect([feed.actor, feed.actorId, feed.target, feed.targetId], ['alice', 'm1', 'bob', 'm2']);
      final view = engine.broadcast().members.last.toJson();
      expect([view['presence'], view['inSet']], ['away', false]);
      expect(engine.broadcast().members.first.toJson()['presence'], 'in');
      engine.applyReady('b', true);
      engine.applyForce('a', 'all', true);
      buffer('b', 9);
      engine.applySwap('a', const HelloMedia(name: 'n', size: 1, duration: 0, url: 'u'));
      expect(b.presence, Presence.away);
      expect(engine.countsForGate(b), isFalse);
      expect(engine.members['a']!.inSet, isTrue);
    });

    test('only oneself comes back in, through joining: no pause while playing', () {
      engine.media = const HelloMedia(name: 'f', size: 1, duration: 100);
      final alice = join('a', 'alice');
      final bob = join('b', 'bob');
      buffer('a', 4.0);
      buffer('b', 4.0);
      engine.applyPresence('b', bob, Presence.away, reason: PresenceReason.idle);
      final line = engine.feed.drain().last;
      expect([line.action, line.target, line.reason], ['away', null, 'idle'], reason: 'sat out by itself');
      engine.applyReady('a', true);
      expect(engine.transport, Transport.playing);
      expect(engine.applyPresence('a', bob, Presence.watching), ErrCode.forbidden);
      expect(engine.members['b']!.presence, Presence.away, reason: 'others cannot bring bob back');
      expect(engine.applyPresence('b', '', Presence.watching), isNull);
      final b = engine.members['b']!;
      expect(b.presence, Presence.joining);
      expect(engine.feed.drain().last.action, 'in');
      engine.applyReady('b', true);
      t = t.add(const Duration(seconds: 1));
      expect(engine.transport, Transport.playing, reason: 'a joiner never holds a playing gate (D2)');
      buffer('b', 4.0);
      expect(b.presence, Presence.watching);
      expect(engine.transport, Transport.playing, reason: 'it came in already in sync');
      // The host can be set away like anyone.
      engine.members['a']!.host = true;
      engine.applyPresence('b', alice, Presence.away);
      expect(engine.members['a']!.presence, Presence.away);
    });
  });

  group('player errors', () {
    void fail(String token, String error, {int? mediaId}) => engine.applyReport(
        token, engine.positionAt(), 0, engine.eventId,
        mediaId: mediaId ?? engine.mediaId, error: error);

    test('an errored member leaves the gate; clearing puts it back', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 4.0);
      expect(engine.transport, Transport.held, reason: 'bob has no buffer');
      fail('b', "Not allowed (403)");
      final b = engine.members['b']!;
      expect([b.error, b.inSet], ['Not allowed (403)', false]);
      expect(engine.transport, Transport.playing, reason: 'alice plays alone');
      final view = engine.broadcast().members;
      expect(view.last.toJson()['error'], 'Not allowed (403)');
      expect(view.first.toJson().containsKey('error'), isFalse);
      engine.applyReady('b', true);
      expect(b.inSet, isFalse, reason: 'ready does not bring it back while errored');
      // A report of another media does not set it; a clean one clears it.
      fail('b', 'x', mediaId: engine.mediaId - 1);
      expect(b.error, isEmpty);
      expect(b.inSet, isTrue, reason: 'ready and playing: back like a stale return');
      expect(engine.transport, Transport.held, reason: 'bob is buffering');
    });

    test('a swap clears it; held, clearing puts it in the set', () {
      join('a', 'alice');
      join('b', 'bob');
      fail('b', 'Not found (404)');
      engine.applySwap('a', const HelloMedia(name: 'n', size: 1, duration: 0, url: 'u'));
      final b = engine.members['b']!;
      expect([b.error, b.inSet], ['', true]);
      fail('b', 'Not found (404)');
      expect(b.inSet, isFalse);
      buffer('b', 4.0);
      expect([b.error, b.inSet], ['', true]);
      expect(ReportMessage.fromJson({
        't': 'report', 'position': 0, 'buffered': 0, 'eventId': 0,
        'error': '  a\nb  ${'x' * 200}'}).error.length,
          RelayConstants.maxMemberErrorLength);
    });
  });

  group('membership + gate', () {
    test('join while held lands in the set, playback stays held', () {
      join('a', 'alice');
      expect(engine.transport, Transport.held);
      expect(engine.members['a']!.inSet, isTrue);
      final state = engine.broadcast();
      expect(state.members.single.inSet, isTrue);
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

    test('a drop is not a leave: gone, out of the gate, kept with its ready flag', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 4.0);
      buffer('b', 4.0);
      expect(engine.transport, Transport.playing);
      engine.applyGone('b');
      expect(engine.transport, Transport.playing);
      final b = engine.members['b']!;
      expect([b.presence, b.ready, b.goneSince], [Presence.gone, true, t]);
      final view = engine.broadcast().members.last.toJson();
      expect([view['presence'], view['goneSince'], view['inSet']], ['gone', t.toIso8601String(), false]);
      engine.applyLeave('b', reason: 'bye');
      expect(engine.members.containsKey('b'), isFalse);
      expect(engine.feed.drain().last.reason, 'bye');
    });

    test('silent past the limit goes gone (not a leave)', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 4.0);
      buffer('b', 4.0);
      expect(engine.transport, Transport.playing);
      t = t.add(const Duration(seconds: 15));
      buffer('a', 4.0);
      expect(engine.sweepSilent(), isEmpty, reason: 'exactly the limit is not past it');
      t = t.add(const Duration(seconds: 1));
      buffer('a', 4.0);
      expect(engine.sweepSilent(), ['b']);
      expect(engine.members['b']!.presence, Presence.gone);
      expect(engine.transport, Transport.playing);
      expect(engine.feed.drain().where((f) => f.action == 'leave'), isEmpty);
    });

    test('a gone member leaves after the grace (feed leave, reason grace)', () {
      final left = <String>[];
      engine.onLeft = (m) => left.add(m.id);
      join('a', 'alice');
      join('b', 'bob');
      engine.applyGone('b');
      t = t.add(const Duration(minutes: 9, seconds: 59));
      buffer('a', 0);
      engine.tick();
      expect(engine.members.containsKey('b'), isTrue);
      t = t.add(const Duration(seconds: 1));
      buffer('a', 0);
      engine.tick();
      expect(engine.members.containsKey('b'), isFalse);
      expect(left, ['m2']);
      final leaves = engine.feed.drain().where((f) => f.action == 'leave').toList();
      expect([leaves.single.actor, leaves.single.actorId, leaves.single.reason], ['bob', 'm2', 'grace']);
    });
  });

  group('presence gate', () {
    test('initial media: three join while held, two ready stays held', () {
      engine.media = const HelloMedia(name: 'f', size: 1, duration: 0);
      join('a', 'alice');
      join('b', 'bob');
      join('c', 'cara');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 6.0);
      buffer('b', 6.0);
      buffer('c', 6.0);
      expect(engine.transport, Transport.held);
      engine.applyReady('c', true);
      expect(engine.transport, Transport.playing);
    });

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

    test('a silent other (gone) exempts the lone watcher', () {
      join('a', 'alice');
      join('b', 'bob');
      t = t.add(const Duration(seconds: 16));
      engine.applyReady('a', true);
      buffer('a', 6.0);
      engine.tick();
      expect(engine.members['b']!.presence, Presence.gone);
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

  group('swap', () {
    const ep2 = HelloMedia(name: 'Ep02.mkv', size: 9, duration: 90.0);

    test('swap bumps mediaId, holds, keeps ready, fresh members in set', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
      engine.applySwap('a', ep2);
      expect(engine.mediaId, 2);
      expect(engine.transport, Transport.held);
      expect(engine.positionAt(), 0);
      expect(engine.members['a']!.inSet, isTrue);
      expect(engine.members['a']!.ready, isTrue);
      expect(engine.members['a']!.buffered, 0);
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
    });

    test('a member present at the swap blocks until ready', () {
      join('a', 'alice');
      join('b', 'bob');
      join('c', 'cara');
      engine.applySwap('a', ep2);
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 6.0);
      buffer('b', 6.0);
      buffer('c', 6.0);
      expect(engine.transport, Transport.held);
      expect(engine.members['c']!.inSet, isTrue);
      engine.applyReady('c', true);
      expect(engine.transport, Transport.playing);
    });

    test('a joiner while playing never holds anyone back', () {
      join('a', 'alice');
      engine.applySwap('a', ep2);
      engine.applyReady('a', true);
      buffer('a', 6.0);
      expect(engine.transport, Transport.playing);
      join('b', 'bob');
      buffer('b', 0);
      expect(engine.members['b']!.inSet, isFalse);
      expect(engine.transport, Transport.playing);
    });

    test('a gone member stays out of the gate; back, it comes in through joining', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('b', true);
      engine.applyGone('b');
      engine.applyReady('a', true);
      engine.applySwap('a', ep2);
      expect(engine.countsForGate(engine.members['b']!), isFalse);
      buffer('a', 6.0);
      expect(engine.transport, Transport.playing);
      expect(engine.applyTakeover('b', seq: 1), isTrue);
      final b = engine.members['b']!;
      expect([b.presence, b.ready], [Presence.joining, true]);
      buffer('b', 0);
      expect(engine.transport, Transport.playing, reason: 'returning never pauses a playing gate (D2)');
      buffer('b', 6.0);
      expect(b.presence, Presence.watching);
      expect(engine.countsForGate(b), isTrue);
      expect(engine.transport, Transport.playing);
    });

    test("the previous media's buffer never starts the new one", () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      engine.applySwap('a', ep2);
      final oldEvent = engine.eventId - 1;
      // Sent before the swap reached the clients, landing after it.
      engine.applyReport('a', 30, 20.0, oldEvent, mediaId: 1);
      engine.applyReport('b', 30, 20.0, oldEvent, mediaId: 1);
      expect(engine.members['a']!.buffered, 0);
      engine.tick();
      expect(engine.transport, Transport.held);
      engine.applyReport('a', 0, 6.0, engine.eventId, mediaId: 2);
      engine.applyReport('b', 0, 6.0, engine.eventId, mediaId: 2);
      expect(engine.transport, Transport.playing);
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

  group('return', () {
    test('a ready member back from gone is in the set again once in sync', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReady('a', true);
      engine.applyReady('b', true);
      buffer('a', 6.0);
      buffer('b', 6.0);
      expect(engine.transport, Transport.playing);
      // bob goes silent past the limit; alice keeps reporting.
      for (var i = 0; i < 16; i++) {
        t = t.add(const Duration(seconds: 1));
        buffer('a', 6.0);
        engine.tick();
      }
      expect(engine.members['b']!.presence, Presence.gone);
      expect(engine.members['b']!.ready, isTrue);
      // No media up: nothing to load, bob is `in` at once and gated again
      // without pressing Space.
      engine.applyTakeover('b', seq: 1);
      expect(engine.members['b']!.presence, Presence.watching);
      expect(engine.broadcast().members.firstWhere((m) => m.id == 'm2').inSet, isTrue);
    });

    test('unready late joiner does not join on reports', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 6.0);
      join('b', 'bob');
      buffer('b', 6.0);
      expect(engine.members['b']!.inSet, isFalse);
    });

    test('away survives a drop: back away, not joining', () {
      join('a', 'alice');
      final bob = join('b', 'bob');
      engine.applyPresence('b', bob, Presence.away);
      engine.applyGone('b');
      expect(engine.members['b']!.presence, Presence.gone);
      engine.applyTakeover('b', seq: 2);
      expect(engine.members['b']!.presence, Presence.away);
    });

    test('the gone line waits; a quick return says nothing, a late one says return', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.feed.drain();
      engine.applyGone('b');
      t = t.add(const Duration(seconds: 9));
      buffer('a', 0);
      engine.tick();
      expect(engine.feed.drain().where((f) => f.action == 'gone'), isEmpty);
      engine.applyTakeover('b', seq: 1);
      expect(engine.feed.drain().map((f) => f.action).where((a) => a != 'pause' && a != 'resume'), isEmpty,
          reason: 'a quick return is silent');
      engine.applyGone('b');
      t = t.add(const Duration(seconds: 10));
      buffer('a', 0);
      engine.tick();
      final gone = engine.feed.drain().where((f) => f.action == 'gone').toList();
      expect([gone.single.actor, gone.single.actorId], ['bob', 'm2']);
      engine.applyTakeover('b', seq: 2);
      expect(engine.feed.drain().map((f) => f.action), contains('return'));
    });
  });

  group('D2: joiners', () {
    const ep = HelloMedia(name: 'Ep01.mkv', size: 9, duration: 600);

    test('a joiner while playing never changes the transport, even ready', () {
      engine.media = ep;
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 6.0);
      expect(engine.transport, Transport.playing);
      final events = engine.eventId;
      join('b', 'bob');
      final b = engine.members['b']!;
      expect(b.presence, Presence.joining);
      engine.applyReady('b', true);
      buffer('b', 0);
      t = t.add(const Duration(seconds: 10));
      engine.applyReport('b', 0, 30, engine.eventId);
      expect(b.presence, Presence.joining, reason: 'its buffer is at 0, not at the server position');
      buffer('a', 6.0);
      expect([engine.transport, engine.eventId], [Transport.playing, events]);
      buffer('b', 6.0);
      expect(b.presence, Presence.watching);
      expect([engine.transport, engine.eventId], [Transport.playing, events], reason: 'in, already in sync');
      expect(engine.feed.drain().map((f) => f.action), isNot(contains('pause')));
    });

    test('while held a joiner holds at most joinerHold, then the others start', () {
      engine.media = ep;
      join('a', 'alice');
      buffer('a', 6.0);
      engine.applyReady('a', true);
      expect(engine.transport, Transport.playing);
      engine.applyReady('a', false);
      expect(engine.transport, Transport.held);
      join('b', 'bob');
      engine.applyReady('a', true);
      expect(engine.transport, Transport.held, reason: 'bob joined while held: he is waited for');
      final hold = engine.holdInfo()!;
      expect([hold.reason, hold.members, hold.until], [HoldReason.joining, ['m2'], t.add(const Duration(seconds: 15))]);
      t = t.add(const Duration(seconds: 14));
      buffer('a', 6.0);
      engine.tick();
      expect(engine.transport, Transport.held);
      t = t.add(const Duration(seconds: 1));
      buffer('a', 6.0);
      engine.tick();
      expect(engine.transport, Transport.playing, reason: 'bounded hold (D2)');
      expect(engine.members['b']!.presence, Presence.joining);
    });

    test('joining ends on a report error or the timeout', () {
      engine.media = ep;
      join('a', 'alice');
      join('b', 'bob');
      engine.applyReport('a', 0, 0, engine.eventId, mediaId: engine.mediaId, error: 'Not found (404)');
      expect(engine.members['a']!.presence, Presence.watching);
      expect(engine.countsForGate(engine.members['a']!), isFalse, reason: 'the error keeps it out');
      for (var i = 0; i < 59; i++) {
        t = t.add(const Duration(seconds: 1));
        buffer('b', 0); // still loading
        engine.tick();
      }
      expect(engine.members['b']!.presence, Presence.joining);
      t = t.add(const Duration(seconds: 1));
      buffer('b', 0);
      engine.tick();
      expect(engine.members['b']!.presence, Presence.watching);
    });

    test('hold reasons: ready, buffer, source, start', () {
      engine.media = ep;
      join('a', 'alice');
      buffer('a', 6.0);
      expect(engine.holdInfo()!.reason, HoldReason.ready);
      engine.applyReady('a', true);
      engine.applySwap('a', ep);
      expect([engine.holdInfo()!.reason, engine.holdInfo()!.members], [HoldReason.buffer, ['m1']]);
      expect(engine.holdInfo(sourceGone: true)!.reason, HoldReason.source);
      engine.applyPresence('a', '', Presence.away);
      expect(engine.holdInfo()!.reason, HoldReason.start);
      expect(engine.broadcast().toJson()['hold'], {'reason': 'start', 'members': <String>[]});
    });
  });

  group('feed', () {
    test('lines carry ids and a rising seq; a replay keeps the last lines after a seq', () {
      join('a', 'alice');
      final bob = join('b', 'bob');
      engine.applyForce('a', bob, true);
      final lines = engine.feed.drain();
      expect([for (final f in lines) f.seq], [1, 2, 3]);
      expect([lines.last.actorId, lines.last.targetId, lines.last.target], ['m1', 'm2', 'bob']);
      for (var i = 0; i < 60; i++) {
        engine.applySeek('a', i.toDouble());
      }
      engine.feed.drain();
      expect(engine.feed.after(2), hasLength(RelayConstants.feedReplayLines), reason: 'bounded');
      final replay = engine.feed.after(60);
      expect([for (final f in replay) f.seq], [61, 62, 63]);
      expect(replay.every((f) => f.replayed), isTrue);
      final json = replay.first.toJson();
      expect([json['seq'], json['actorId'], json['replayed']], [61, 'm1', true]);
      expect(FeedMessage.fromJson(json).replayed, isTrue);
    });
  });

  group('liveness on the engine clock', () {
    test('silence, gone notice, grace follow Liveness and the fake clock, not wall time', () {
      engine = SyncEngine(
          clock: clock,
          liveness: const Liveness(
              silence: Duration(minutes: 5), goneNotice: Duration(minutes: 1), grace: Duration(minutes: 10)));
      join('a', 'alice');
      engine.applyReady('a', true);
      engine.feed.drain();
      t = t.add(const Duration(minutes: 5));
      engine.tick();
      expect(engine.members['a']!.presence, Presence.watching, reason: 'not past the silence yet');
      t = t.add(const Duration(seconds: 1));
      engine.tick();
      expect(engine.members['a']!.presence, Presence.gone);
      expect(engine.feed.drain(), isEmpty);
      t = t.add(const Duration(minutes: 1));
      engine.tick();
      expect(engine.feed.drain().map((f) => f.action), ['gone']);
      t = t.add(const Duration(minutes: 8, seconds: 59));
      engine.tick();
      expect(engine.members, isNotEmpty);
      t = t.add(const Duration(seconds: 1));
      engine.tick();
      expect(engine.members, isEmpty);
      expect(engine.feed.drain().map((f) => f.action), ['leave']);
    });

    test('defaults: 15 s silence, 10 min grace, 10 s gone notice, 15 s joiner hold', () {
      final l = engine.liveness;
      expect([l.silence, l.grace, l.goneNotice, l.joinerHold, l.joiningTimeout, l.pingInterval], const [
        Duration(seconds: 15),
        Duration(minutes: 10),
        Duration(seconds: 10),
        Duration(seconds: 15),
        Duration(seconds: 60),
        Duration(seconds: 5),
      ]);
    });
  });

  group('end of file', () {
    setUp(() {
      engine.media = const HelloMedia(name: 'f', size: 1, duration: 20);
    });

    void playTo(double secs, {required double Function(double pos) buffered}) {
      while (engine.positionAt() < secs) {
        t = t.add(const Duration(milliseconds: 500));
        final pos = engine.positionAt();
        engine.applyReport('a', pos, buffered(pos), engine.eventId);
        engine.tick();
      }
    }

    test('last seconds play out with less than 4 s left, then finished', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 6.0);
      expect(engine.transport, Transport.playing);
      // mpv's read-ahead cannot exceed what is left of the file.
      double left(double pos) => (20 - pos).clamp(0, 6).toDouble();
      playTo(19.5, buffered: left);
      expect(engine.transport, Transport.playing);
      t = t.add(const Duration(seconds: 1));
      engine.tick();
      expect(engine.transport, Transport.finished);
      expect(engine.positionAt(), 20);
      expect(engine.broadcast().transport, 'finished');
      // Finished never auto-resumes, however ready everyone is.
      t = t.add(const Duration(seconds: 5));
      buffer('a', 0);
      engine.tick();
      expect(engine.transport, Transport.finished);
    });

    test('seek back from finished resumes for ready members', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 6.0);
      t = t.add(const Duration(seconds: 21));
      buffer('a', 6.0); // a frame a second keeps it present
      engine.tick();
      expect(engine.transport, Transport.finished);
      engine.applySeek('a', 5);
      buffer('a', 6.0);
      expect(engine.transport, Transport.playing);
      expect(engine.positionAt(), 5);
    });

    test('swap after finished resets to held', () {
      join('a', 'alice');
      engine.applyReady('a', true);
      buffer('a', 6.0);
      t = t.add(const Duration(seconds: 21));
      buffer('a', 6.0); // a frame a second keeps it present
      engine.tick();
      expect(engine.transport, Transport.finished);
      engine.applySwap(
          'a', const HelloMedia(name: 'g', size: 1, duration: 0, url: 'http://x/g'));
      expect(engine.transport, Transport.held);
      expect(engine.media!.duration, 0);
    });

    test('duration learned from reports for the current media only', () {
      engine.media = const HelloMedia(name: 'f', size: 1, duration: 0);
      join('a', 'alice');
      engine.applyReport('a', 0, 1, engine.eventId,
          duration: 99, mediaId: engine.mediaId - 1);
      expect(engine.media!.duration, 0);
      engine.applyReport('a', 0, 1, engine.eventId,
          duration: 42.5, mediaId: engine.mediaId);
      expect(engine.media!.duration, 42.5);
      expect(engine.broadcast().media!['duration'], 42.5);
    });

    test('requirement is min(4 s, remaining) with slack', () {
      join('a', 'alice');
      engine.applySeek('a', 18);
      expect(engine.requiredBufferSecs(), lessThan(RelayConstants.minBufferSecs));
      engine.applySeek('a', 5);
      expect(engine.requiredBufferSecs(), RelayConstants.minBufferSecs);
      engine.media = const HelloMedia(name: 'f', size: 1, duration: 0);
      expect(engine.requiredBufferSecs(), RelayConstants.minBufferSecs);
    });
  });

  group('seek attribution', () {
    test('state carries who sent the seek and its seq, only for that event', () {
      join('a', 'alice');
      engine.applySeek('a', 10, seq: 7);
      var s = engine.broadcast();
      expect(s.seekBy, 'm1');
      expect(s.seekSeq, 7);
      final back = StateBroadcast.fromJson(Map<String, Object?>.from(
          jsonDecode(jsonEncode(s.toJson())) as Map));
      expect(back.seekBy, 'm1');
      expect(back.seekSeq, 7);
      // A later event (gate) is not attributed to the seek.
      engine.applyReady('a', true);
      buffer('a', 6.0);
      s = engine.broadcast();
      expect(s.transport, 'playing');
      expect(s.seekBy, isNull);
    });
  });

  test('host flag: only the marked member, on the wire as host:true', () {
    join('a', 'alice');
    join('b', 'bob');
    engine.members['a']!.host = true;
    final members = {for (final m in engine.broadcast().members) m.name: m};
    expect(members['alice']!.host, isTrue);
    expect(members['bob']!.host, isFalse);
    final json = engine.broadcast().toJson()['members'] as List;
    expect((json.first as Map)['host'], isTrue);
    expect((json.last as Map).containsKey('host'), isFalse);
    final back = StateBroadcast.fromJson(
        Map<String, Object?>.from(jsonDecode(jsonEncode(engine.broadcast().toJson())) as Map));
    expect([for (final m in back.members) m.host], [true, false]);
  });

  group('profile + avatars', () {
    // Real magic bytes: anything that is not PNG/JPEG/WebP/GIF is dropped.
    final png = base64Encode([0x89, 0x50, 0x4E, 0x47, ...List<int>.generate(60, (i) => i)]);
    final other = base64Encode([0xFF, 0xD8, 0xFF, ...List<int>.generate(61, (i) => 255 - i)]);

    test('join keeps bytes, state carries only the hash', () {
      engine.applyJoin('a', 'alice', png);
      final hash = engine.members['a']!.avatarHash;
      expect(hash, hasLength(16));
      expect(engine.avatarFor(hash), base64Decode(png));
      final view = engine.broadcast().members.single;
      expect(view.avatarHash, hash);
      expect(jsonEncode(engine.broadcast().toJson()), isNot(contains(png)));
      join('b', 'bob');
      expect(engine.members['b']!.avatarHash, isEmpty);
      engine.applyLeave('a');
      expect(engine.avatarFor(hash), isNull, reason: 'dropped with the member');
    });

    test('a picture that is not an image is dropped', () {
      final e = SyncEngine();
      e.applyJoin('x', 'x', base64Encode(List<int>.generate(64, (i) => i)));
      expect(e.members['x']!.avatarHash, isEmpty);
      expect(avatarImageType([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]), ('image', 'webp'));
    });

    test('rename feeds rename (actor new, target old); picture only feeds avatar', () {
      engine.applyJoin('a', 'alice', png);
      engine.feed.drain();
      engine.applyProfile('a', name: 'bob');
      var feed = engine.feed.drain().single;
      expect(feed.action, 'rename');
      expect(feed.actor, 'bob');
      expect(feed.target, 'alice');

      engine.applyProfile('a', avatar: other);
      feed = engine.feed.drain().single;
      expect(feed.action, 'avatar');
      expect(feed.actor, 'bob');
      expect(engine.members['a']!.avatarHash, avatarHashOf(base64Decode(other)));

      engine.applyProfile('a', name: 'carol', avatar: '');
      feed = engine.feed.drain().single;
      expect(feed.action, 'rename');
      expect(engine.members['a']!.avatarHash, isEmpty);
      expect(engine.members['a']!.avatarBytes, isNull);

      engine.applyProfile('a', name: 'carol', avatar: '');
      expect(engine.feed.drain(), isEmpty, reason: 'nothing changed');
      engine.applyProfile('a', avatar: 'not base64!');
      expect(engine.members['a']!.avatarHash, isEmpty);
    });
  });

  group('media art', () {
    final jpeg = base64Encode([0xFF, 0xD8, 0xFF, ...List<int>.generate(61, (i) => i)]);
    final png = base64Encode([0x89, 0x50, 0x4E, 0x47, ...List<int>.generate(60, (i) => 255 - i)]);
    const media = HelloMedia(name: 'Show - 01.mkv', size: 1, duration: 0, url: 'http://x/a.mkv');
    Map<String, Object?>? art() => engine.broadcast().media?['art'] as Map<String, Object?>?;

    test('swapper sends art for the current media; state carries hashes only', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applySwap('a', media);
      expect(art(), isNull, reason: 'omitted when empty');
      expect(engine.broadcast().media?['swapBy'], 'm1');
      expect(engine.applyArt('a', engine.mediaId, poster: jpeg, banner: png), isTrue);
      final hashes = art()!;
      expect(hashes['poster'], avatarHashOf(base64Decode(jpeg)));
      expect(hashes['banner'], avatarHashOf(base64Decode(png)));
      expect(engine.artFor(hashes['poster'] as String), base64Decode(jpeg));
      expect(engine.artFor('0123456789abcdef'), isNull);
      expect(jsonEncode(engine.broadcast().toJson()), isNot(contains(jpeg)));
      // A later art replaces it; a field left out is none.
      expect(engine.applyArt('a', engine.mediaId, poster: png), isTrue);
      expect(art(), {'poster': avatarHashOf(base64Decode(png))});
    });

    test('rejects other members, stale mediaId; host may send', () {
      join('a', 'alice');
      join('b', 'bob');
      join('h', 'host');
      engine.members['h']!.host = true;
      expect(engine.applyArt('a', engine.mediaId, poster: jpeg), isFalse, reason: 'no media yet');
      engine.applySwap('a', media);
      final id = engine.mediaId;
      expect(engine.applyArt('b', id, poster: jpeg), isFalse);
      expect(engine.applyArt('a', id - 1, poster: jpeg), isFalse);
      expect(art(), isNull);
      expect(engine.applyArt('h', id, poster: jpeg), isTrue);
      expect(art(), contains('poster'));
    });

    test('bad bytes and oversize fields are dropped; any swap clears', () {
      join('a', 'alice');
      engine.applySwap('a', media);
      final big = base64Encode([0xFF, 0xD8, 0xFF, ...List<int>.filled(RelayConstants.maxPosterBytes, 1)]);
      engine.applyArt('a', engine.mediaId,
          poster: big, banner: base64Encode(List<int>.generate(64, (i) => i)));
      expect(art(), isNull);
      engine.applyArt('a', engine.mediaId, poster: 'not base64!', banner: big);
      expect(art(), {'banner': avatarHashOf(base64Decode(big))}, reason: 'banner cap is larger');
      join('b', 'bob');
      engine.applySwap('b', media);
      expect(art(), isNull);
      expect(engine.artFor(avatarHashOf(base64Decode(big))), isNull);
    });

    test('ArtMessage round trip', () {
      final m = ArtMessage.fromJson(Map<String, Object?>.from(
          jsonDecode(jsonEncode(ArtMessage(mediaId: 3, poster: jpeg).toJson())) as Map));
      expect(m.mediaId, 3);
      expect(m.poster, jpeg);
      expect(m.banner, isNull);
      expect(const ArtMessage(mediaId: 1).toJson(), {'t': 'art', 'mediaId': 1});
    });
  });
}
