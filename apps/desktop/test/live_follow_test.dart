import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/playback/media_marks.dart';
import 'package:starsync/src/sync/live_follow.dart';
import 'package:starsync/src/sync/state_diff.dart';

void main() {
  // The player holds 0..40 s of its own time; its 0 is stream time 1000.
  const cache = CachedRanges([(start: Duration.zero, end: Duration(seconds: 40))]);
  final t0 = DateTime.utc(2026, 1, 1);
  LiveStep step(LiveFollow f, double? group, double own, {DateTime? at}) =>
      f.step(group: group, own: own, start: 1000, cached: cache, now: at ?? t0);

  test('no live point yet: plays at its own rate', () {
    final f = LiveFollow();
    expect(step(f, null, 1010).actions, isEmpty);
  });

  test('near: the rate goes a little up or down, back to 1 once level', () {
    final f = LiveFollow();
    expect(step(f, 1020, 1020.03).actions, isEmpty, reason: 'within the dead band');
    final ahead = step(f, 1020, 1020.4).actions.single as RateAction;
    expect(ahead.rate, 1 - LiveFollow.rateStep);
    expect(step(f, 1020, 1020.3).actions, isEmpty, reason: 'already slowed');
    final behind = step(f, 1020, 1019.5).actions.single as RateAction;
    expect(behind.rate, 1 + LiveFollow.rateStep);
    expect((step(f, 1020, 1020.01).actions.single as RateAction).rate, 1.0);
  });

  test('far: a seek in its own time inside the cache, then time to land', () {
    final f = LiveFollow();
    final s = step(f, 1030, 1010).actions.whereType<SeekAction>().single;
    expect(s.position, 30);
    expect(step(f, 1030, 1010, at: t0.add(const Duration(seconds: 1))).actions, isEmpty, reason: 'landing');
    expect(step(f, 1030, 1010, at: t0.add(const Duration(seconds: 3))).actions.whereType<SeekAction>(), isNotEmpty);
  });

  test('a point past its cache: plays on, or opens afresh when far behind', () {
    final f = LiveFollow();
    final late = step(f, 1041, 1038);
    expect(late.actions.whereType<SeekAction>(), isEmpty, reason: 'a CDN edge a little late: as near as it can');
    expect(late.reload, isFalse);
    expect(step(f, 1080, 1040).reload, isTrue);
  });

  test('a point before its cache (a rewind): an open there when the stream can be rewound', () {
    final f = LiveFollow();
    final s = f.step(group: 900, own: 1010, start: 1000, cached: cache, now: t0);
    expect(s.reload, isFalse, reason: 'no window: plays on');
    expect(s.actions.whereType<SeekAction>(), isEmpty);
    expect(f.step(group: 900, own: 1010, start: 1000, cached: cache, now: t0, rewind: true).reload, isTrue);
    expect(f.step(group: 1005, own: 1010, start: 1000, cached: cache, now: t0, rewind: true).reload, isFalse,
        reason: 'in its cache: a seek');
  });

  test("the live seek bar: the window from its start, this player and its cache in it", () {
    final bar = LiveBar.of(from: 400, top: 1000, own: 950, start: 900, cached: cache);
    expect(bar.length, const Duration(seconds: 600));
    expect(bar.position, const Duration(seconds: 550));
    expect(bar.cached.ranges.single, (start: const Duration(seconds: 500), end: const Duration(seconds: 540)));
    expect(bar.streamTime(const Duration(seconds: 100)), 500);
  });

  test('a length that keeps growing is live; one corrected once or twice is not', () {
    expect(growsLikeLive([14, 16, 18, 20]), isTrue);
    expect(growsLikeLive([1440, 1441.2, 1441.2]), isFalse);
    expect(growsLikeLive([10, 10.1, 10.2, 10.3, 10.4]), isFalse);
  });
}
