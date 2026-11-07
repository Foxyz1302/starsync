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
      engine.applyReport(token, engine.positionAt(), secs, engine.eventId, mediaId: engine.mediaId);

  void play(String token) => engine.applyTransport(token, true);
  void pause(String token) => engine.applyTransport(token, false);
  void brb(String token, {String target = '', bool resume = false}) =>
      engine.applyPresence(token, target, Presence.brb, resume: resume);
  void back(String token) => engine.applyPresence(token, '', Presence.watching);
  EngineMember m(String token) => engine.members[token]!;
  List<String> actions() => [for (final f in engine.feed.drain()) f.action];

  const ep = HelloMedia(name: 'Ep01.mkv', size: 9, duration: 600);

  /// alice and bob watching [ep], playing, both buffered.
  void playing() {
    join('a', 'alice');
    join('b', 'bob');
    engine.applySwap('a', ep);
    play('a');
    buffer('a', 6);
    buffer('b', 6);
    expect(engine.transport, Transport.playing);
    engine.feed.drain();
  }

  group('non-finite guards', () {
    test('seek/report/swap reject Infinity and NaN, broadcast stays encodable', () {
      join('a', 'alice');
      engine.applySeek('a', double.infinity);
      engine.applySeek('a', double.nan);
      expect(engine.position, 0);
      engine.applyReport('a', double.infinity, 1, engine.eventId);
      engine.applyReport('a', 1, double.infinity, engine.eventId);
      expect(engine.members['a']!.buffered, 0);
      expect(engine.applySwap('a', const HelloMedia(name: 'x', size: 1, duration: double.infinity)), isFalse);
      expect(engine.mediaId, 1);
      jsonEncode(engine.broadcast().toJson());
    });
  });

  group('the wish: play and pause', () {
    test('nothing plays until someone plays; put-up keeps play or pause', () {
      join('a', 'alice');
      engine.applySwap('a', ep);
      buffer('a', 6);
      t = t.add(const Duration(minutes: 30));
      buffer('a', 6);
      engine.tick();
      expect(engine.transport, Transport.held, reason: 'nothing starts because time passed');
      expect(engine.broadcast().wantsPlay, isFalse);
      engine.feed.drain();
      play('a');
      expect(engine.transport, Transport.playing);
      expect(actions(), ['play'], reason: "the member's play says it; no extra resume");
      engine.applySwap('a', const HelloMedia(name: 'Ep02', size: 1, duration: 600));
      buffer('a', 6);
      expect(engine.transport, Transport.playing, reason: 'the next media keeps playing');
      pause('a');
      engine.applySwap('a', ep);
      buffer('a', 6);
      expect(engine.transport, Transport.held, reason: 'and keeps a pause');
    });

    test('a pause holds at once at the position, anyone plays; play waits for every video', () {
      playing();
      t = t.add(const Duration(seconds: 30));
      pause('b');
      expect((engine.transport, engine.positionAt()), (Transport.held, 30.0));
      final line = engine.feed.drain().single;
      expect([line.action, line.actorId], ['pause', 'm2']);
      t = t.add(const Duration(seconds: 30));
      expect(engine.positionAt(), 30.0);
      engine.applyReport('b', 30, 1, engine.eventId, mediaId: engine.mediaId);
      play('a');
      expect(engine.transport, Transport.held, reason: "bob's video is short");
      expect(engine.holdInfo()!.video, ['m2']);
      buffer('b', 6);
      expect(engine.transport, Transport.playing);
      expect(actions(), ['play', 'resume']);
    });

    test('while playing a watched video running dry holds the group, refilled it plays on', () {
      playing();
      engine.applyReport('b', engine.positionAt(), 0, engine.eventId, mediaId: engine.mediaId);
      expect(engine.transport, Transport.held);
      expect(engine.broadcast().wantsPlay, isTrue, reason: 'the wish stays: waiting, not paused');
      expect(engine.feed.drain().single.actorId, 'server');
      buffer('b', 6);
      expect(engine.transport, Transport.playing);
    });

    test('a drop never pauses; a gone member is never waited for', () {
      playing();
      engine.applyGone('b');
      expect(engine.transport, Transport.playing);
      pause('a');
      play('a');
      expect(engine.transport, Transport.playing);
    });
  });

  group('BRB', () {
    test('holds the group; the last one back plays when it wanted to (resume from the key-down pause)', () {
      playing();
      join('c', 'cara');
      buffer('c', 6);
      engine.feed.drain();
      // Space down paused, the hold then made it BRB.
      pause('a');
      brb('a', resume: true);
      expect(engine.broadcast().wantsPlay, isTrue);
      expect(engine.transport, Transport.held);
      brb('c');
      back('a');
      expect(engine.transport, Transport.held, reason: 'cara is still BRB');
      expect(engine.holdInfo()!.brb, ['m3']);
      back('c');
      expect(engine.transport, Transport.playing);
      expect(actions(), ['pause', 'brb', 'brb', 'back', 'back', 'resume']);
    });

    test('BRB from a pause stays paused when back; a pause during it too', () {
      playing();
      pause('a');
      brb('a');
      back('a');
      expect(engine.transport, Transport.held);
      play('b');
      brb('b', resume: true);
      expect(engine.broadcast().wantsPlay, isTrue);
      pause('a');
      back('b');
      expect(engine.transport, Transport.held, reason: 'a pause lasts until someone plays');
      expect(engine.holdInfo(), isNull, reason: 'a plain pause waits for nobody');
    });

    test('BRB while playing holds at once; the hold says who, whatever the wish', () {
      playing();
      brb('b');
      expect(engine.transport, Transport.held);
      expect(engine.broadcast().hold!.brb, ['m2']);
      pause('a');
      expect(engine.broadcast().hold!.brb, ['m2'], reason: '"Paused · waiting for bob"');
      expect(engine.broadcast().hold!.video, isEmpty, reason: 'videos matter only when it wants to play');
    });

    test('Wait for Bob: anyone sets someone BRB; only Bob comes back', () {
      playing();
      final bob = m('b').id;
      brb('a', target: bob);
      expect(m('b').presence, Presence.brb);
      final line = engine.feed.drain().single;
      expect([line.action, line.actorId, line.targetId], ['brb', 'm1', 'm2']);
      expect(engine.applyPresence('a', bob, Presence.watching), ErrCode.forbidden);
      expect(m('b').presence, Presence.brb);
      back('b');
      expect(engine.transport, Transport.playing, reason: 'it was playing');
    });

    test('BRB survives a drop and a swap; a gone BRB is still waited for', () {
      playing();
      brb('b');
      engine.applyGone('b');
      play('a');
      expect(engine.transport, Transport.held);
      expect(engine.holdInfo()!.brb, ['m2']);
      engine.applySwap('a', const HelloMedia(name: 'Ep02', size: 1, duration: 600));
      expect(m('b').presence, Presence.brb);
      engine.applyTakeover('b', seq: 1);
      expect(m('b').presence, Presence.brb);
      buffer('a', 6);
      expect(engine.transport, Transport.held);
    });

    test('the last BRB leaving for good leaves a plain pause, never a play', () {
      playing();
      brb('b');
      engine.applyLeave('b', reason: 'grace');
      expect(engine.transport, Transport.held);
      expect(engine.broadcast().wantsPlay, isFalse);
      expect(engine.holdInfo(), isNull);
    });
  });

  group('out and AFK', () {
    test('out is never waited for; anyone sets it; only oneself comes back, loading at the current moment', () {
      playing();
      final bob = m('b').id;
      engine.applyPresence('a', bob, Presence.out);
      expect(m('b').presence, Presence.out);
      engine.applyReport('b', 0, 0, engine.eventId, mediaId: engine.mediaId);
      expect(engine.transport, Transport.playing, reason: "an out member's video is not waited for");
      expect(engine.applyPresence('a', bob, Presence.watching), ErrCode.forbidden);
      engine.feed.drain();
      back('b');
      expect([m('b').presence, m('b').loading], [Presence.watching, true]);
      expect(engine.feed.drain().single.action, 'in');
      expect(engine.transport, Transport.playing, reason: 'coming in never pauses anyone');
      buffer('b', 6);
      expect(m('b').loading, isFalse);
    });

    test('AFK only oneself, never while playing nor on a BRB member; it counts as out', () {
      playing();
      expect(engine.applyPresence('a', m('b').id, Presence.afk), ErrCode.forbidden);
      engine.applyPresence('b', '', Presence.afk);
      expect(m('b').presence, Presence.watching, reason: 'never during playback');
      pause('a');
      brb('b');
      engine.applyPresence('b', '', Presence.afk);
      expect(m('b').presence, Presence.brb, reason: 'never on a BRB member');
      back('b');
      engine.applyPresence('b', '', Presence.afk);
      expect(m('b').presence, Presence.afk);
      expect(engine.broadcast().members.last.isOut, isTrue);
      engine.applyReport('b', 0, 0, engine.eventId, mediaId: engine.mediaId);
      play('a');
      expect(engine.transport, Transport.playing);
    });

    test('out survives a drop and a swap', () {
      playing();
      engine.applyPresence('b', '', Presence.out);
      engine.applyGone('b');
      engine.applyTakeover('b', seq: 2);
      expect(m('b').presence, Presence.out);
      engine.applySwap('a', ep);
      expect(m('b').presence, Presence.out);
    });
  });

  group('continue', () {
    test('without everyone: BRBs out, short videos catch up, the actor back, and it plays', () {
      playing();
      join('c', 'cara');
      join('d', 'dan');
      buffer('c', 6);
      buffer('d', 6);
      pause('a');
      brb('b');
      brb('a');
      engine.applyReport('c', engine.positionAt(), 1, engine.eventId, mediaId: engine.mediaId);
      engine.feed.drain();
      engine.applyContinue('a');
      expect([m('a').presence, m('b').presence, m('c').presence], [Presence.watching, Presence.out, Presence.watching]);
      expect([m('c').skipped, m('c').loading], [true, true]);
      expect(engine.transport, Transport.playing);
      expect(engine.feed.drain().first.action, 'continue');
      buffer('c', 6);
      expect([m('c').skipped, m('c').loading], [false, false], reason: 'caught up: waited for again');
    });

    test("without one: just them, the wish stays (Don't wait for Bob)", () {
      playing();
      pause('a');
      brb('b');
      engine.applyContinue('a', targetId: m('b').id);
      expect(m('b').presence, Presence.out);
      expect(engine.transport, Transport.held, reason: 'it was paused');
      final line = engine.feed.drain().last;
      expect([line.action, line.targetId], ['continue', 'm2']);
    });
  });

  group('back from a drop', () {
    /// bob drops for [away] while it [plays], then its app takes the member
    /// over again; the `return` line.
    FeedMessage dropAndReturn(Duration away, {bool plays = true}) {
      playing();
      if (!plays) pause('a');
      t = t.add(const Duration(seconds: 100));
      buffer('a', 6);
      buffer('b', 6);
      engine.applyGone('b');
      t = t.add(away);
      buffer('a', 6);
      engine.tick();
      engine.feed.drain();
      engine.applyTakeover('b', seq: 3);
      return engine.feed.drain().singleWhere((f) => f.action == 'return');
    }

    test('it says how much of the video was missed', () {
      final line = dropAndReturn(const Duration(seconds: 102));
      expect([line.actorId, line.missed], ['m2', 102]);
      expect(FeedMessage.fromJson(line.toJson()).missed, 102, reason: 'on the wire');
    });

    test('paused meanwhile: nothing missed', () {
      expect(dropAndReturn(const Duration(seconds: 60), plays: false).missed, 0);
    });

    test('a seek meanwhile: nothing to say', () {
      playing();
      t = t.add(const Duration(seconds: 100));
      buffer('a', 6);
      buffer('b', 6);
      engine.applyGone('b');
      engine.applySeek('a', 10);
      t = t.add(const Duration(seconds: 60));
      buffer('a', 6);
      engine.tick();
      engine.applyTakeover('b', seq: 3);
      expect(engine.feed.drain().singleWhere((f) => f.action == 'return').missed, 0);
    });

    test('out and back in is no drop: no return line, nothing missed', () {
      playing();
      t = t.add(const Duration(seconds: 100));
      buffer('a', 6);
      buffer('b', 6);
      engine.applyPresence('b', '', Presence.out);
      t = t.add(const Duration(seconds: 60));
      back('b');
      buffer('b', 6);
      expect(engine.feed.drain().map((f) => f.action), isNot(contains('return')));
      expect(engine.broadcast().toJson().containsKey('rewind'), isFalse);
    });
  });

  group('loading (joiners)', () {
    test('a joiner while playing never changes the transport', () {
      playing();
      final events = engine.eventId;
      join('c', 'cara');
      expect(m('c').loading, isTrue);
      engine.applyReport('c', 0, 0, engine.eventId, mediaId: engine.mediaId);
      expect([engine.transport, engine.eventId], [Transport.playing, events]);
      buffer('c', 6);
      expect(m('c').loading, isFalse);
    });

    test('held and wanting to play, the group waits for a joiner (no time bound)', () {
      join('a', 'alice');
      engine.applySwap('a', ep);
      play('a');
      buffer('a', 6);
      pause('a');
      play('a');
      join('b', 'bob');
      pause('a');
      play('a');
      expect(engine.transport, Transport.held);
      expect(engine.holdInfo()!.video, ['m2']);
      t = t.add(const Duration(minutes: 5));
      buffer('a', 6);
      engine.touch('b');
      engine.tick();
      expect(engine.transport, Transport.held);
      buffer('b', 6);
      expect(engine.transport, Transport.playing);
    });

    test('loading ends on a report error; an errored member is never waited for', () {
      join('a', 'alice');
      engine.applySwap('a', ep);
      join('b', 'bob');
      engine.applyReport('b', 0, 0, engine.eventId, mediaId: engine.mediaId, error: 'Not allowed (403)');
      expect([m('b').loading, m('b').error], [false, 'Not allowed (403)']);
      buffer('a', 6);
      play('a');
      expect(engine.transport, Transport.playing);
      pause('a');
      engine.applyReport('b', 0, 0, engine.eventId, mediaId: engine.mediaId);
      play('a');
      expect(engine.transport, Transport.held, reason: 'cleared: its video is waited for again');
      buffer('b', 6);
      expect(engine.transport, Transport.playing);
      engine.applySwap('a', ep);
      expect(m('b').error, isEmpty, reason: 'a swap clears it');
    });
  });

  group('clock ownership', () {
    test('clock advances only while playing', () {
      expect(engine.positionAt(), 0);
      t = t.add(const Duration(seconds: 10));
      expect(engine.positionAt(), 0);
      join('a', 'alice');
      play('a');
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 10));
      expect(engine.positionAt(), closeTo(10.0, 0.001));
    });

    test('lagging report cannot drag clock backward or forward', () {
      join('a', 'alice');
      play('a');
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
      play('a');
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
      play('a');
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 30));
      final before = engine.eventId;
      engine.applySeek('a', 600.0);
      expect(engine.transport, Transport.playing);
      expect(engine.positionAt(), closeTo(600.0, 0.01));
      expect(engine.eventId, greaterThan(before));
    });

    test('a play after a pause starts where it stopped', () {
      join('a', 'alice');
      join('b', 'bob');
      play('a');
      buffer('a', 4.0);
      buffer('b', 4.0);
      t = t.add(const Duration(seconds: 60));
      pause('b');
      expect(engine.positionAt(), closeTo(60.0, 0.01));
      t = t.add(const Duration(seconds: 30));
      expect(engine.positionAt(), closeTo(60.0, 0.01));
      play('b');
      expect(engine.transport, Transport.playing);
      expect(engine.positionAt(), closeTo(60.0, 0.01));
    });
  });

  group('swap', () {
    const ep2 = HelloMedia(name: 'Ep02.mkv', size: 9, duration: 90.0);

    test('a restore (after a restart) puts it back at its position, wanting to play when it played', () {
      join('a', 'alice');
      engine.applySwap('a', ep2, restore: const SwapRestore(position: 42.5, transport: 'playing'));
      expect((engine.positionAt(), engine.transport), (42.5, Transport.held));
      expect(engine.feed.drain().last.reason, 'restore');
      expect(engine.wantsPlay, isTrue);
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing, reason: 'it plays again once the video is there');
      engine.applySwap('a', ep2, restore: const SwapRestore(position: 90, transport: 'finished'));
      expect((engine.positionAt(), engine.transport), (90.0, Transport.finished));
      final rt = SwapIntent.fromJson(
          const SwapIntent(media: ep2, restore: SwapRestore(position: 3, transport: 'playing')).toJson());
      expect((rt.restore!.position, rt.restore!.transport), (3.0, 'playing'));
      expect(SwapIntent.fromJson(const SwapIntent(media: ep2).toJson()).restore, isNull);
    });

    test('swap bumps mediaId, holds, waits for every video again', () {
      playing();
      engine.applySwap('a', ep2);
      expect(engine.mediaId, 3);
      expect(engine.transport, Transport.held);
      expect(engine.positionAt(), 0);
      expect(m('a').buffered, 0);
      buffer('a', 4.0);
      expect(engine.transport, Transport.held);
      expect(engine.holdInfo()!.video, ['m2']);
      buffer('b', 4.0);
      expect(engine.transport, Transport.playing);
    });

    test("the previous media's buffer never starts the new one", () {
      join('a', 'alice');
      join('b', 'bob');
      play('a');
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

  group('flap stability', () {
    test('rapid pause/play converges to playing, one line each', () {
      join('a', 'alice');
      play('a');
      buffer('a', 4.0);
      expect(engine.transport, Transport.playing);
      engine.feed.drain();
      for (var i = 0; i < 10; i++) {
        pause('a');
        play('a');
      }
      play('a');
      expect(engine.transport, Transport.playing);
      final a = actions();
      expect([a.where((x) => x == 'pause').length, a.where((x) => x == 'play').length], [10, 10]);
    });
  });

  group('input sanitizing', () {
    test('NaN/negative seek ignored, edge + eventId untouched', () {
      join('a', 'alice');
      play('a');
      buffer('a', 4.0);
      t = t.add(const Duration(seconds: 20));
      final eid = engine.eventId;
      engine.applySeek('a', double.nan);
      engine.applySeek('a', -5.0);
      expect(engine.positionAt(), closeTo(20.0, 0.01));
      expect(engine.eventId, eid);
      expect(engine.feed.drain().where((f) => f.action == 'seek'), isEmpty);
    });

    test('NaN buffered counts as zero, the group waits', () {
      join('a', 'alice');
      play('a');
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
      final back = StateBroadcast.fromJson(Map<String, Object?>.from(state.toJson()));
      expect(back.transport, 'held');
      expect(back.members.single.name, 'alice');
      expect(back.members.single.id, 'm1');
      expect(back.wantsPlay, isFalse);
    });

    test('intent schemas round-trip', () {
      const s = SeekIntent(position: 42.5);
      expect(SeekIntent.fromJson(Map<String, Object?>.from(s.toJson())).position, 42.5);
      const c = ChatMessage(text: 'hi');
      expect(ChatMessage.fromJson(Map<String, Object?>.from(c.toJson())).text, 'hi');
      const rp = ReportMessage(position: 1, buffered: 2, eventId: 3);
      final rpBack = ReportMessage.fromJson(Map<String, Object?>.from(rp.toJson()));
      expect(rpBack.eventId, 3);
    });
  });

  group('return', () {
    test('a drop is not a leave: gone, kept with its standing; silent past the limit too', () {
      playing();
      for (var i = 0; i < 16; i++) {
        t = t.add(const Duration(seconds: 1));
        buffer('a', 6.0);
        engine.tick();
      }
      expect(m('b').gone, isTrue);
      expect(engine.broadcast().members.last.goneSince, isNotNull);
      expect(engine.transport, Transport.playing);
      engine.applyTakeover('b', seq: 1);
      expect([m('b').gone, m('b').loading], [false, true], reason: 'back, it loads at the current moment');
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

  group('feed', () {
    test('lines carry ids and a rising seq; a replay keeps the last lines after a seq', () {
      join('a', 'alice');
      final bob = join('b', 'bob');
      brb('a', target: bob);
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
      engine.feed.drain();
      t = t.add(const Duration(minutes: 5));
      engine.tick();
      expect(m('a').gone, isFalse, reason: 'not past the silence yet');
      t = t.add(const Duration(seconds: 1));
      engine.tick();
      expect(m('a').gone, isTrue);
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

    test('defaults: 15 s silence, 10 min grace, 10 s gone notice', () {
      final l = engine.liveness;
      expect([l.silence, l.grace, l.goneNotice, l.pingInterval], const [
        Duration(seconds: 15),
        Duration(minutes: 10),
        Duration(seconds: 10),
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
      play('a');
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
      // Finished never starts again by itself.
      t = t.add(const Duration(seconds: 5));
      buffer('a', 0);
      engine.tick();
      expect(engine.transport, Transport.finished);
    });

    test('seek back from finished plays again when it wants to', () {
      join('a', 'alice');
      play('a');
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
      play('a');
      buffer('a', 6.0);
      t = t.add(const Duration(seconds: 21));
      buffer('a', 6.0); // a frame a second keeps it present
      engine.tick();
      expect(engine.transport, Transport.finished);
      engine.applySwap('a', const HelloMedia(name: 'g', size: 1, duration: 0, url: 'http://x/g'));
      expect(engine.transport, Transport.held);
      expect(engine.media!.duration, 0);
    });

    test('duration learned from reports for the current media only', () {
      engine.media = const HelloMedia(name: 'f', size: 1, duration: 0);
      join('a', 'alice');
      engine.applyReport('a', 0, 1, engine.eventId, duration: 99, mediaId: engine.mediaId - 1);
      expect(engine.media!.duration, 0);
      engine.applyReport('a', 0, 1, engine.eventId, duration: 42.5, mediaId: engine.mediaId);
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
      final back = StateBroadcast.fromJson(Map<String, Object?>.from(jsonDecode(jsonEncode(s.toJson())) as Map));
      expect(back.seekBy, 'm1');
      expect(back.seekSeq, 7);
      // A later event (the gate) is not attributed to the seek.
      play('a');
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

  group('live streams', () {
    const stream = HelloMedia(name: 'Live', size: 0, duration: 0, url: 'https://x/live.m3u8', live: true);
    // A live report: the player at [pos] with its edge at [edge] (stream
    // time), or at the end ([ended]).
    void live(String token, double pos, double edge, {double ended = 0}) =>
        engine.applyReport(token, pos, 6, engine.eventId, mediaId: engine.mediaId, edge: edge, duration: ended);
    void step(double secs) => t = t.add(Duration(milliseconds: (secs * 1000).round()));

    test('the first report sets the live point; nobody waits, pause and BRB are local, no seek', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applySwap('a', stream);
      expect(engine.transport, Transport.held, reason: 'no live point before a player reports');
      expect(engine.broadcast().media!['live'], isTrue);
      expect(engine.broadcast().hold, isNull);
      // Opened twelve seconds behind its edge: the point is six behind,
      // plus the margin.
      live('a', 994, 1006);
      expect(engine.transport, Transport.playing, reason: 'a live stream goes on without a Play');
      expect(engine.position, 1000 - RelayConstants.liveMarginSecs);
      expect(engine.wantsPlay, isTrue, reason: 'what comes after it plays on');
      step(2);
      live('b', 990, 1007);
      expect(engine.positionAt(), closeTo(999, 1e-9), reason: 'a later report does not move it');
      expect(engine.media!.duration, 0, reason: 'a live stream has no length');
      pause('b');
      brb('a');
      engine.applySeek('b', 10);
      buffer('b', 0);
      expect(engine.transport, Transport.playing);
      expect(engine.positionAt(), closeTo(999, 1e-9));
      expect(engine.broadcast().hold, isNull);
      expect(actions(), isNot(contains('pause')));
      engine.tick();
      expect(engine.transport, Transport.playing);
    });

    test('a player far from its edge (a stitched ad) sets it behind the edge instead', () {
      join('a', 'alice');
      engine.applySwap('a', stream);
      live('a', 88, 43000);
      expect(engine.position, 43000 - RelayConstants.liveFallbackLagSecs - RelayConstants.liveMarginSecs);
    });

    test('set again when the stream stalls past every edge, or its clock jumps ahead', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applySwap('a', stream);
      live('a', 100, 106);
      live('b', 100, 108);
      // The point: 100.
      final first = engine.eventId;
      step(10);
      live('a', 106, 106);
      expect(engine.eventId, first, reason: 'within the latest edge plus the slack');
      step(2);
      live('a', 106, 106);
      expect(engine.eventId, greaterThan(first), reason: 'past every edge: the stream stalled');
      expect(engine.positionAt(), 106 - RelayConstants.liveMarginSecs);
      final second = engine.eventId;
      live('a', 4994, 5006);
      expect(engine.eventId, greaterThan(second), reason: "the stream's clock jumped ahead");
      expect(engine.positionAt(), 5000 - RelayConstants.liveMarginSecs);
    });

    test('ends when a player reached the end and nobody sees it go on; Up next goes up at once', () {
      join('a', 'alice');
      join('b', 'bob');
      engine.applySwap('a', stream);
      engine.applyQueueAdd('a', QueueItem(
          media: const HelloMedia(name: 'next', size: 0, duration: 0, url: 'https://x/next.mp4'),
          how: QueueHow.direct,
          title: 'next'));
      live('a', 100, 106);
      live('b', 100, 106);
      step(5);
      live('a', 0, 0, ended: 102);
      live('b', 102, 112);
      engine.tick();
      expect(engine.transport, Transport.playing, reason: "bob's stream goes on: alice's player only lost it");
      live('a', 102, 112);
      live('b', 103, 112, ended: 112);
      live('a', 0, 0, ended: 112);
      engine.tick();
      expect(engine.transport, Transport.finished);
      expect(engine.position, 112);
      expect(engine.queue.play, isNotNull, reason: 'what comes next is asked for without a countdown');
    });

    test('a player that finds a media live makes it live from then on', () {
      join('a', 'alice');
      engine.applySwap('a', const HelloMedia(name: 'x.m3u8', size: 0, duration: 0, url: 'https://x/x.m3u8'));
      engine.applyReport('a', 2, 6, engine.eventId, mediaId: engine.mediaId, duration: 14);
      expect(engine.media!.duration, 14);
      live('a', 494, 506);
      expect(engine.live, isTrue);
      expect(engine.media!.duration, 0);
      expect(engine.transport, Transport.playing);
      expect(engine.position, 500 - RelayConstants.liveMarginSecs);
      final r = ReportMessage.fromJson(
          jsonDecode(jsonEncode(const ReportMessage(position: 500, buffered: 6, eventId: 3, edge: 506).toJson())));
      expect(r.edge, 506);
      expect(const ReportMessage(position: 1, buffered: 1, eventId: 1).toJson().containsKey('edge'), isFalse);
      expect(HelloMedia.fromJson(stream.toJson()).live, isTrue);
      expect(const HelloMedia(name: 'x', size: 0, duration: 0).toJson().containsKey('live'), isFalse);
    });

    test('a joiner loads until its player reports the stream', () {
      join('a', 'alice');
      engine.applySwap('a', stream);
      live('a', 100, 106);
      join('b', 'bob');
      expect(m('b').loading, isTrue);
      live('b', 50, 106);
      expect(m('b').loading, isFalse);
    });
  });
}
