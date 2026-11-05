import 'dart:convert';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  late DateTime t;
  late SyncEngine engine;

  setUp(() {
    t = DateTime.utc(2026, 1, 1);
    engine = SyncEngine(clock: () => t);
    engine.applyJoin('a', 'alice', '');
    engine.applyJoin('b', 'bob', '');
  });

  QueueItem link(String title) => QueueItem(
      media: HelloMedia(name: title, size: 0, duration: 0, url: 'https://example.com/$title'),
      how: QueueHow.direct,
      title: title);

  List<String> titles() => [for (final q in engine.queue.items) q.title];
  String idOf(String title) => engine.queue.items.firstWhere((q) => q.title == title).id;

  test('add at the end or next, with who added it, a feed line and stable ids', () {
    engine.applyQueueAdd('a', link('one'));
    engine.applyQueueAdd('b', link('two'));
    engine.applyQueueAdd('b', link('first'), next: true);
    expect(titles(), ['first', 'one', 'two']);
    final one = engine.queue.items[1];
    expect((one.by, one.byName), ('m1', 'alice'));
    final ids = {for (final q in engine.queue.items) q.id};
    expect(ids.length, 3);
    final feed = engine.feed.drain().where((f) => f.action == 'queue-add').toList();
    expect([for (final f in feed) '${f.actor}:${f.target}'], ['alice:one', 'bob:two', 'bob:first']);
  });

  test('move and remove by id; unknown ids change nothing', () {
    for (final s in ['a1', 'a2', 'a3']) {
      engine.applyQueueAdd('a', link(s));
    }
    expect(engine.applyQueueMove('b', idOf('a3'), 0), isTrue);
    expect(titles(), ['a3', 'a1', 'a2']);
    expect(engine.applyQueueMove('b', idOf('a3'), 99), isTrue);
    expect(titles(), ['a1', 'a2', 'a3']);
    expect(engine.applyQueueMove('b', 'q99', 0), isFalse);
    expect(engine.applyQueueRemove('b', idOf('a2')), isTrue);
    expect(engine.applyQueueRemove('b', 'q99'), isFalse);
    expect(titles(), ['a1', 'a3']);
    final skip = engine.applyQueueRemove('a', idOf('a1'), why: 'bob left');
    expect(skip, isTrue);
    final lines = engine.feed.drain().where((f) => f.action.startsWith('queue-r') || f.action == 'queue-skip');
    expect([for (final f in lines) '${f.action}:${f.target}:${f.reason}'],
        ['queue-remove:a2:', 'queue-skip:a1:bob left']);
  });

  test('a swap naming an item takes it out; any swap ends a play request', () {
    engine.applyQueueAdd('a', link('one'));
    engine.applyQueueAdd('a', link('two'));
    expect(engine.applyQueuePlay('b', idOf('two')), isTrue);
    expect(titles(), ['two', 'one']);
    expect(engine.broadcast().queuePlay, idOf('two'));
    engine.applySwap('a', const HelloMedia(name: 'manual', size: 0, duration: 0, url: 'https://x/y'));
    expect(engine.queue.play, isNull);
    expect(titles(), ['two', 'one'], reason: 'a manual swap leaves the queue alone');
    engine.applySwap('a', const HelloMedia(name: 'two', size: 0, duration: 0, url: 'https://x/two'),
        queueId: idOf('two'));
    expect(titles(), ['one']);
  });

  test('skip asks for the first item; a request nobody acts on is asked again, then skipped', () {
    engine.applySwap('a', const HelloMedia(name: 'up', size: 0, duration: 0, url: 'https://x/up'));
    expect(engine.applyQueuePlay('a', ''), isFalse, reason: 'nothing queued');
    engine.applyQueueAdd('a', link('one'));
    expect(engine.applyQueuePlay('a', ''), isTrue);
    expect(engine.queue.play, idOf('one'));
    void late() {
      t = t.add(const Duration(seconds: RelayConstants.queuePlayTimeoutSecs + 1));
      engine
        ..touch('a')
        ..touch('b')
        ..tick();
    }

    late();
    expect(engine.queue.play, idOf('one'), reason: 'asked again');
    expect(engine.broadcast().queuePass, ['m1'], reason: 'alice did not put it up: bob is asked');
    expect(queuePerformer(engine.queue.items.first, engine.broadcast().members, pass: engine.queuePass).id, 'm2');
    late();
    expect(engine.queuePass, ['m1']);
    late();
    expect(engine.queue.play, isNull);
    expect(titles(), isEmpty, reason: "bob didn't either, twice: skipped");
    expect(engine.feed.drain().lastWhere((f) => f.action == 'queue-skip').reason, "bob didn't put it up");
  });

  test('full at the cap', () {
    for (var i = 0; i < RelayConstants.maxQueueItems; i++) {
      expect(engine.applyQueueAdd('a', link('$i')), isNull);
    }
    final refused = engine.applyQueueAdd('a', link('over'))!;
    expect([refused.code, refused.message], [ErrCode.full, contains('full')]);
    expect(engine.queue.length, RelayConstants.maxQueueItems);
  });

  test('thumbnails are served by hash while queued', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    engine.applyQueueAdd('a', link('one'), thumb: png);
    final hash = engine.queue.items.single.thumb;
    expect(hash, isNotEmpty);
    expect(engine.artFor(hash), png);
    engine.applyQueueRemove('a', engine.queue.items.single.id);
    expect(engine.artFor(hash), isNull);
  });

  test('state round trip keeps the queue and the play request', () {
    engine.applyQueueAdd('a', link('one'));
    engine.applyQueueAdd('b', QueueItem(
        media: const HelloMedia(name: 'f', size: 3, duration: 0),
        how: QueueHow.file,
        title: 'f',
        sub: 'S1E2',
        duration: 1440,
        key: 'abcdefgh12'));
    engine.applyQueuePlay('a', idOf('f'));
    final back = StateBroadcast.fromJson(
        Map<String, Object?>.from(jsonDecode(jsonEncode(engine.broadcast().toJson())) as Map));
    expect([for (final q in back.queue) q.title], ['f', 'one']);
    final f = back.queue.first;
    expect((f.how, f.sub, f.duration, f.key, f.byName), (QueueHow.file, 'S1E2', 1440.0, 'abcdefgh12', 'bob'));
    expect(back.queuePlay, f.id);
    final intent = QueueIntent.fromJson(Map<String, Object?>.from(
        jsonDecode(jsonEncode(QueueIntent.add(link('x'), next: true).toJson())) as Map));
    expect((intent.op, intent.next, intent.item!.title), ('add', true, 'x'));
    expect(() => QueueIntent.fromJson(const {'t': 'queue', 'op': 'nope'}), throwsA(isA<ProtocolException>()));
  });

  group('auto (the continuation)', () {
    QueueItem next(String title) => link(title).copyWith(auto: true, forMedia: engine.mediaId);

    setUp(() {
      engine.applySwap('a', const HelloMedia(name: 'Ep01', size: 0, duration: 0, url: 'https://example.com/1'));
    });

    test('only the swapper (or, without it, the first in) adds it, for the current media', () {
      expect(engine.applyQueueAdd('b', next('Ep02'))!.code, ErrCode.forbidden);
      expect(engine.applyQueueAdd('a', link('Ep02').copyWith(auto: true, forMedia: 99))!.code, ErrCode.bad);
      expect(engine.applyQueueAdd('a', next('Ep02')), isNull);
      engine.applyPresence('a', '', Presence.out);
      expect(engine.applyQueueAdd('b', next('Ep02b')), isNull, reason: 'the swapper is out: bob is the first present');
      expect(titles(), ['Ep02b'], reason: 'a newer one replaces it');
    });

    test('it stays after the others; a swap of something else and cancel drop it', () {
      engine.applyQueueAdd('a', next('Ep02'));
      engine.applyQueueAdd('b', link('x'));
      engine.applyQueueAdd('b', link('y'), next: true);
      expect(titles(), ['y', 'x', 'Ep02']);
      expect(engine.queue.move(idOf('y'), 99), isTrue);
      expect(engine.queue.move(idOf('Ep02'), 0), isFalse);
      expect(titles(), ['x', 'y', 'Ep02'], reason: 'nothing moves past it');
      final json = engine.broadcast().toJson();
      final last = ((json['queue'] as List).last as Map);
      expect([last['auto'], last['for']], [true, engine.mediaId]);
      expect(QueueItem.fromJson(jsonDecode(jsonEncode(last)))!.forMedia, engine.mediaId);
      engine.applySwap('b', const HelloMedia(name: 'other', size: 0, duration: 0, url: 'https://example.com/o'),
          queueId: idOf('y'));
      expect(titles(), ['x'], reason: 'a swap to something else drops it');
      engine.applyQueueAdd('b', link('z'));
      expect(engine.applyQueueAdd('b', next('Ep03')), isNull);
      engine.feed.drain();
      expect(engine.applyQueueCancel('a'), isTrue);
      expect(titles(), ['x', 'z']);
      final line = engine.feed.drain().single;
      expect([line.action, line.actorId, line.target], ['advance-cancel', 'm1', 'Ep03']);
      expect(engine.applyQueueCancel('a'), isFalse);
      expect(QueueIntent.fromJson(const QueueIntent.cancel().toJson()).op, 'cancel');
    });

    test('a swap that puts it up keeps the queue going', () {
      engine.applyQueueAdd('a', next('Ep02'));
      final id = idOf('Ep02');
      engine.applySwap('a', const HelloMedia(name: 'Ep02', size: 0, duration: 0, url: 'https://example.com/2'),
          queueId: id);
      expect(engine.queue.isEmpty, isTrue);
      expect(engine.media!.name, 'Ep02');
    });
  });

  group("what's next (the server's countdown)", () {
    QueueItem file(String title, {String key = 'abcdefgh12'}) => QueueItem(
        media: HelloMedia(name: title, size: 3, duration: 0), how: QueueHow.file, title: title, key: key);

    // Both keep talking (pings), so nobody goes silent.
    void after(int secs) {
      t = t.add(Duration(seconds: secs));
      engine
        ..touch('a')
        ..touch('b')
        ..tick();
    }

    /// Ep01 (20 s) up by alice, played, both buffered, second by second
    /// to [secs].
    void play() {
      engine.applySwap('a', const HelloMedia(name: 'Ep01', size: 0, duration: 20, url: 'https://example.com/1'));
      engine.applyTransport('a', true);
      for (final tok in ['a', 'b']) {
        engine.applyReport(tok, 0, 100, engine.eventId, mediaId: engine.mediaId);
      }
      expect(engine.transport, Transport.playing);
    }

    void playTo(int secs) {
      for (var i = 0; i < secs; i++) {
        after(1);
      }
    }

    /// [play], then to its end.
    void finish() {
      play();
      playTo(21);
      expect(engine.transport, Transport.finished);
    }

    test('over the last 10 s, ending at the end: the next item is asked for the moment it ends', () {
      engine.applyQueueAdd('b', link('two'));
      play();
      playTo(9);
      expect(engine.advance, isNull, reason: '11 s left');
      after(1);
      final a = engine.advance!;
      expect([a.id, a.secs], [idOf('two'), RelayConstants.advanceSecs]);
      expect(a.at.add(Duration(seconds: a.secs)), DateTime.utc(2026, 1, 1, 0, 0, 20), reason: 'ends at the end');
      playTo(10);
      expect(engine.transport, Transport.finished);
      expect(engine.queue.play, idOf('two'), reason: 'at once, no countdown after the end');
    });

    test('a pause during the countdown stops it at the end; one before it does not', () {
      engine.applyQueueAdd('b', link('two'));
      play();
      playTo(5);
      engine.applyTransport('b', false);
      engine.applyTransport('b', true);
      playTo(7);
      expect(engine.advance, isNotNull, reason: 'a pause before the countdown changes nothing');
      engine.applyTransport('b', false);
      expect(engine.advance, isNull);
      engine.applyTransport('b', true);
      playTo(12);
      expect(engine.transport, Transport.finished);
      expect((engine.advance, engine.queue.play), (null, null), reason: 'stopped at the end');
    });


    test('nothing up: the first item is asked for at once', () {
      engine.applyQueueAdd('b', link('one'));
      expect(engine.queue.play, idOf('one'));
      expect(engine.advance, isNull);
    });

    test('at the end with an item first: 10 s for everyone, then queuePlay', () {
      finish();
      expect(engine.advance, isNull, reason: 'nothing queued, nothing counts down');
      engine.applyQueueAdd('b', link('two'));
      final a = engine.advance!;
      expect([a.id, a.secs], [idOf('two'), RelayConstants.advanceSecs]);
      expect(a.at, t);
      expect(engine.broadcast().advance!.id, a.id, reason: 'in every state');
      expect(advanceSecondsLeft(a, t.add(const Duration(milliseconds: 2500))), 8);
      after(5);
      expect(engine.queue.play, isNull);
      // A new first item takes the countdown over, its end unchanged.
      engine.applyQueueAdd('a', link('first'), next: true);
      expect([engine.advance!.id, engine.advance!.at], [idOf('first'), a.at]);
      after(5);
      expect(engine.queue.play, idOf('first'));
      expect(engine.advance, isNull, reason: 'over once it asked');
      after(1);
      expect(engine.advance, isNull, reason: 'not counted down again while the request waits');
    });

    test('a seek stops it; cancel stops it for this media and drops the continuation', () {
      finish();
      engine.applyQueueAdd('b', link('two'));
      expect(engine.advance, isNotNull);
      engine.applySeek('b', 5);
      expect(engine.advance, isNull);
      expect(engine.transport, isNot(Transport.finished));
      // Playing towards the end again: a fresh countdown.
      playTo(6);
      expect(engine.advance, isNotNull);
      expect(engine.transport, Transport.playing);
      engine.applyQueueAdd('a', link('Ep02').copyWith(auto: true, forMedia: engine.mediaId));
      engine.feed.drain();
      expect(engine.applyQueueCancel('b'), isTrue);
      expect(engine.advance, isNull);
      expect(titles(), ['two']);
      expect(engine.feed.drain().single.action, 'advance-cancel');
      playTo(30);
      expect(engine.transport, Transport.finished);
      expect((engine.advance, engine.queue.play), (null, null), reason: 'cancelled for this media');
    });

    test("holds while its performer is gone, plays once they're back", () {
      finish();
      engine.applyQueueAdd('b', file('bobs'));
      engine.applyGone('b');
      after(12);
      expect(engine.queue.play, isNull, reason: 'held: only bob has the file');
      expect(engine.advance, isNotNull);
      engine.applyTakeover('b', seq: 1);
      after(1);
      expect(engine.queue.play, idOf('bobs'));
    });

    test("holds while the item's relay source is gone", () {
      var sourceGone = true;
      engine.itemSourceGone = (_) => sourceGone;
      finish();
      engine.applyQueueAdd('b', link('two'));
      after(12);
      expect(engine.queue.play, isNull);
      sourceGone = false;
      after(1);
      expect(engine.queue.play, idOf('two'));
    });

    test('what nobody here can put up is skipped by the server', () {
      finish();
      engine.applyQueueAdd('b', file('bobs'));
      engine.applyQueueAdd('a', link('next'));
      engine.applyLeave('b', reason: 'bye');
      engine.feed.drain();
      after(11);
      expect(titles(), ['next']);
      final skip = engine.feed.drain().firstWhere((f) => f.action == 'queue-skip');
      expect([skip.actorId, skip.target, skip.reason], ['server', 'bobs', 'bob left']);
      expect(engine.advance!.id, idOf('next'), reason: 'the countdown goes on with the next one');
      after(1);
      expect(engine.queue.play, idOf('next'));
      // A play request for a Jellyfin item nobody here can open: skipped too.
      engine.applyQueueAdd('a', QueueItem(
          media: const HelloMedia(name: 'ep', size: 0, duration: 0, jellyfin: JellyfinRef(serverId: 'S', itemId: 'i')),
          how: QueueHow.jellyfin,
          title: 'ep'));
      engine.applyQueuePlay('a', idOf('ep'));
      expect(titles().contains('ep'), isFalse);
    });

    test('the continuation adds no feed line', () {
      engine.applySwap('a', const HelloMedia(name: 'Ep01', size: 0, duration: 0, url: 'https://example.com/1'));
      engine.feed.drain();
      engine.applyQueueAdd('a', link('Ep02').copyWith(auto: true, forMedia: engine.mediaId));
      expect(engine.feed.drain().where((f) => f.action == 'queue-add'), isEmpty);
    });
  });
}
