import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/danmaku/danmaku.dart';
import 'package:starsync/src/danmaku/danmaku_notices.dart';
import 'package:starsync/src/session/notifier.dart' show NoticeCategory, ToastItem;
import 'package:starsync/src/shell/avatar.dart' show AvatarInfo;

// Danmaku lanes: free lanes only, no two lines in a lane ever touch, the
// density cap with a queue in arrival order, and the layer over a real
// widget clock.

const w = 1000.0;

/// Lines in one lane never overlap (gap kept) at any sampled time.
void expectNoOverlap(DanmakuLanes<int> lanes, double t, {double gap = 0}) {
  final byLane = <int, List<DanmakuFlight<int>>>{};
  for (final f in lanes.flights) {
    byLane.putIfAbsent(f.lane, () => []).add(f);
  }
  for (final fs in byLane.values) {
    fs.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < fs.length; i++) {
      final ahead = fs[i - 1], behind = fs[i];
      final tail = ahead.x(t, w) + ahead.width;
      // Only while both are on screen.
      if (tail <= 0 || behind.x(t, w) >= w) continue;
      expect(behind.x(t, w), greaterThanOrEqualTo(tail + gap - 1e-6),
          reason: 'lane ${behind.lane} at t=$t: #${behind.item} reaches #${ahead.item}');
    }
  }
}

List<DanmakuFlight<int>> tick(DanmakuLanes<int> lanes, double t, Map<int, double> widths,
        {int lanesN = 5, int cap = 100, double cross = 8}) =>
    lanes.tick(t, w: w, lanes: lanesN, cap: cap, crossSecs: cross, measure: (i) => widths[i]!);

void main() {
  group('DanmakuLanes', () {
    test('lines at the same moment take the lanes top down', () {
      final lanes = DanmakuLanes<int>();
      final widths = {for (var i = 0; i < 3; i++) i: 200.0};
      for (var i = 0; i < 3; i++) {
        lanes.add(i, 0);
      }
      final placed = tick(lanes, 0, widths);
      expect([for (final f in placed) f.lane], [0, 1, 2]);
    });

    test('a lane is reused once the line in it has fully entered', () {
      final lanes = DanmakuLanes<int>(gap: 20);
      final widths = {0: 200.0, 1: 200.0};
      lanes.add(0, 0);
      tick(lanes, 0, widths, lanesN: 1);
      lanes.add(1, 0.1);
      // 200 px + gap at 150 px/s: not yet in.
      expect(tick(lanes, 0.1, widths, lanesN: 1), isEmpty);
      expect(lanes.waiting, 1);
      // Same length, same speed: it may follow once 220 px have entered.
      final placed = tick(lanes, 1.6, widths, lanesN: 1);
      expect(placed.single.lane, 0);
    });

    test('a long (faster) line never catches a short one ahead in its lane', () {
      final lanes = DanmakuLanes<int>(gap: 20);
      final widths = {0: 60.0, 1: 900.0};
      lanes.add(0, 0);
      tick(lanes, 0, widths, lanesN: 1);
      lanes.add(1, 0.5);
      // The short one is in, but the long one would run into it: wait.
      for (var t = 0.5; t < 8; t += 0.1) {
        final placed = tick(lanes, t, widths, lanesN: 1);
        if (placed.isNotEmpty) {
          // Placed: from then on they never touch.
          for (var s = t; s < t + 8; s += 0.05) {
            expectNoOverlap(lanes, s, gap: 20);
          }
          return;
        }
      }
      fail('the long line never got the lane');
    });

    test('a random stream of mixed lengths never overlaps', () {
      final rng = math.Random(3);
      final lanes = DanmakuLanes<int>(gap: 24, maxWaitSecs: 1000, maxWaiting: 10000);
      final widths = <int, double>{};
      var n = 0;
      for (var t = 0.0; t < 120; t += 0.05) {
        if (rng.nextDouble() < 0.15) {
          widths[n] = 20 + rng.nextDouble() * 900;
          lanes.add(n++, t);
        }
        tick(lanes, t, widths, lanesN: 6, cap: 14, cross: 6 + rng.nextDouble() * 0.0);
        expectNoOverlap(lanes, t, gap: 24);
        expect(lanes.flights.length, lessThanOrEqualTo(14));
      }
      expect(n, greaterThan(300));
    });

    test('the density cap holds the rest in arrival order', () {
      final lanes = DanmakuLanes<int>();
      final widths = {for (var i = 0; i < 10; i++) i: 100.0};
      for (var i = 0; i < 10; i++) {
        lanes.add(i, 0);
      }
      final first = tick(lanes, 0, widths, lanesN: 20, cap: 4);
      expect([for (final f in first) f.item], [0, 1, 2, 3]);
      expect(lanes.waiting, 6);
      // Nothing leaves before the crossing time: still capped.
      expect(tick(lanes, 7.9, widths, lanesN: 20, cap: 4), isEmpty);
      final next = tick(lanes, 8, widths, lanesN: 20, cap: 4);
      expect([for (final f in next) f.item], [4, 5, 6, 7]);
    });

    test('a line that waited too long is dropped; the queue is bounded', () {
      final lanes = DanmakuLanes<int>(maxWaitSecs: 5, maxWaiting: 3);
      final widths = {for (var i = 0; i < 6; i++) i: 100.0};
      for (var i = 0; i < 5; i++) {
        lanes.add(i, 0);
      }
      expect(lanes.waiting, 3);
      expect(lanes.dropped, 2);
      tick(lanes, 6, widths, cap: 0);
      expect(lanes.waiting, 0);
      expect(lanes.dropped, 5);
    });
  });

  group('DanmakuStyle', () {
    test('lanes fill the band at the text size', () {
      const s = DanmakuStyle(bandTop: 0.1, bandBottom: 0.45);
      // 720 px: 30.24 px text, 45.36 px lanes in a 252 px band.
      expect(s.lanesFor(720), 5);
      expect(const DanmakuStyle(bandTop: 0.4, bandBottom: 0.41).lanesFor(720), 1);
    });
  });

  testWidgets('the layer flies lines under the cap and lets the rest wait', (tester) async {
    final c = DanmakuController();
    addTearDown(c.dispose);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 800,
        height: 450,
        child: DanmakuLayer(
          controller: c,
          accent: Colors.purple,
          style: const DanmakuStyle(maxOnScreen: 3, crossSecs: 4),
        ),
      ),
    ));
    for (var i = 0; i < 7; i++) {
      c.add(DanmakuItem(
          kind: DanmakuKind.chat,
          sender: 'Bob',
          text: 'line $i',
          own: i == 0,
          avatar: i.isEven ? const AvatarInfo(name: 'Bob', color: Colors.teal) : null));
    }
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.onScreen.value, 3);
    expect(c.waiting.value, 4);
    // After a crossing the next ones fly.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.onScreen.value, 3);
    expect(c.waiting.value, 1);
    c.clear();
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.onScreen.value, 0);
    expect(c.waiting.value, 0);
    await tester.pumpWidget(const SizedBox());
  });


  group('DanmakuStyle as a setting', () {
    test('round-trips through its map', () {
      const s = DanmakuStyle(
          crossSecs: 6, maxOnScreen: 5, bandTop: 0.2, bandBottom: 0.5, opacity: 0.7, size: 1.3, weight: 800,
          outline: 2, highlightOwn: false, avatars: false);
      expect(DanmakuStyle.fromJson(s.toJson()), s);
    });

    test('junk and out-of-range values: defaults and the nearest ends', () {
      expect(DanmakuStyle.fromJson(const {}), const DanmakuStyle());
      final s = DanmakuStyle.fromJson(const {
        'crossSecs': 99,
        'maxOnScreen': 0,
        'opacity': 'x',
        'weight': 1234,
        'bandTop': 0.6,
        'bandBottom': 0.61,
        'avatars': 1,
      });
      expect(s.crossSecs, 16);
      expect(s.maxOnScreen, 1);
      expect(s.opacity, const DanmakuStyle().opacity);
      expect(s.weight, 900);
      expect((s.bandTop, s.bandBottom), (0.10, 0.45), reason: 'a band too thin takes the default');
      expect(s.avatars, isTrue);
    });

    test('boldness: the text at its weight, the name a step bolder', () {
      expect(const DanmakuStyle(weight: 400).fontWeight, FontWeight.w400);
      expect(const DanmakuStyle(weight: 400).nameWeight, FontWeight.w500);
      expect(const DanmakuStyle(weight: 900).nameWeight, FontWeight.w900);
    });
  });

  group('notifications as danmaku', () {
    ToastItem toast(String text,
            {String? actor, NoticeCategory category = NoticeCategory.app, bool chat = false, bool own = false}) =>
        ToastItem(id: 1, text: text, at: DateTime(2026), actor: actor, chat: chat, own: own, category: category);

    test('chat and short notices fly; problems, nudges and the app stay toasts', () {
      expect(fliesAsDanmaku(toast('Bob: hi', actor: 'Bob', chat: true, category: NoticeCategory.chat)), isTrue);
      expect(fliesAsDanmaku(toast('Bob joined', actor: 'Bob', category: NoticeCategory.people)), isTrue);
      expect(fliesAsDanmaku(toast('Starting now', category: NoticeCategory.start)), isTrue);
      expect(fliesAsDanmaku(toast('Bob added X to Up next', actor: 'Bob', category: NoticeCategory.upNext)), isTrue);
      expect(fliesAsDanmaku(toast('Skipped X: gone', category: NoticeCategory.upNext)), isFalse);
      expect(fliesAsDanmaku(toast("Bob can't play this", actor: 'Bob', category: NoticeCategory.problem)), isFalse);
      expect(fliesAsDanmaku(toast('Bob nudged you', actor: 'Bob', category: NoticeCategory.nudge)), isFalse);
      expect(fliesAsDanmaku(toast('Link copied')), isFalse);
      expect(fliesAsDanmaku(toast('The server restarted', category: NoticeCategory.self)), isFalse);
    });

    test('lines: the sender before the message, own chat framed', () {
      final chat = danmakuForToast(toast('Me: hello', actor: 'Me', chat: true, own: true, category: NoticeCategory.chat))!;
      expect((chat.kind, chat.sender, chat.text, chat.own), (DanmakuKind.chat, 'Me', 'hello', true));
      final left = danmakuForToast(toast('Bob lost connection', actor: 'Bob', category: NoticeCategory.people))!;
      expect((left.kind, left.text), (DanmakuKind.leave, 'lost connection'));
      final start = danmakuForToast(toast('Starting now: Frieren', category: NoticeCategory.start))!;
      expect((start.kind, start.sender), (DanmakuKind.starting, null));
      expect(danmakuForToast(toast('Copied')), isNull);
    });
  });

  testWidgets('an idle layer asks for no frames', (tester) async {
    final c = DanmakuController();
    addTearDown(c.dispose);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(width: 800, height: 450, child: DanmakuLayer(controller: c, accent: Colors.purple)),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse);
    c.add(const DanmakuItem(kind: DanmakuKind.chat, sender: 'Bob', text: 'hi'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.onScreen.value, 1);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.onScreen.value, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
