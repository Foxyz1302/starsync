// restructure: rewrite in step 1 (Connection + Identity + Presence):
// IdleTracker and unreadyForNewMedia give way to auto sit-out;
// linkDisplayName stays.
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/session/idle.dart';
import 'package:watch_together/src/session/session_coordinator.dart';

void main() {
  group('IdleTracker', () {
    final t0 = DateTime.utc(2026, 1, 1, 12);

    List<IdleEvent> run(IdleTracker idle, DateTime from, Duration span,
        {required bool playing, bool selfReady = true}) {
      final out = <IdleEvent>[];
      for (var s = 0; s <= span.inSeconds; s++) {
        final e = idle.tick(from.add(Duration(seconds: s)),
            playing: playing, selfReady: selfReady);
        if (e != IdleEvent.none) out.add(e);
      }
      return out;
    }

    test('long watch then pause: no instant warn+unready', () {
      final idle = IdleTracker(t0);
      // 15 min of playback without any input.
      expect(run(idle, t0, const Duration(minutes: 15), playing: true), isEmpty);
      final paused = t0.add(const Duration(minutes: 15));
      // First minute after the pause: nothing fires.
      expect(run(idle, paused, const Duration(minutes: 1), playing: false),
          isEmpty);
    });

    test('pause measures from when playback stopped', () {
      final idle = IdleTracker(t0);
      run(idle, t0, const Duration(minutes: 15), playing: true);
      // Last playing tick was at +15 min; count seconds from there.
      final paused = t0.add(const Duration(minutes: 15));
      final events = <(int, IdleEvent)>[];
      for (var s = 1; s <= 11 * 60; s++) {
        final e = idle.tick(paused.add(Duration(seconds: s)),
            playing: false, selfReady: true);
        if (e != IdleEvent.none) events.add((s, e));
      }
      expect(events, [(8 * 60, IdleEvent.warn), (10 * 60, IdleEvent.unready)]);
    });

    test('unready always trails the warning by 2 min', () {
      final idle = IdleTracker(t0);
      // Idle 20 min while unready (nothing to lose, nothing fires)...
      expect(
          run(idle, t0, const Duration(minutes: 20),
              playing: false, selfReady: false),
          isEmpty);
      // ...then someone force-readies us: warn now, unready 2 min later.
      final forced = t0.add(const Duration(minutes: 20, seconds: 1));
      expect(idle.tick(forced, playing: false, selfReady: true), IdleEvent.warn);
      expect(
          idle.tick(forced.add(const Duration(seconds: 1)),
              playing: false, selfReady: true),
          IdleEvent.none);
      expect(
          idle.tick(forced.add(const Duration(minutes: 2)),
              playing: false, selfReady: true),
          IdleEvent.unready);
    });

    test('input resets the clock and the warning', () {
      final idle = IdleTracker(t0);
      expect(idle.tick(t0.add(const Duration(minutes: 8)),
          playing: false, selfReady: true), IdleEvent.warn);
      idle.activity(t0.add(const Duration(minutes: 9)));
      expect(idle.tick(t0.add(const Duration(minutes: 11)),
          playing: false, selfReady: true), IdleEvent.none);
      expect(idle.tick(t0.add(const Duration(minutes: 17)),
          playing: false, selfReady: true), IdleEvent.warn);
    });
  });

  group('linkDisplayName', () {
    test('drops query (api_key) and fragment, decodes last segment', () {
      expect(
          linkDisplayName(
              'https://jf.example.com/Videos/abc/My%20Movie.mkv?static=true&api_key=SECRET#t=5'),
          'My Movie.mkv');
    });
    test('trailing slash and bare host', () {
      expect(linkDisplayName('http://host.lan/media/show/'), 'show');
      expect(linkDisplayName('http://host.lan/?api_key=SECRET'), 'host.lan');
    });
    test('never contains the key', () {
      final n = linkDisplayName(
          'https://jf.example.com/Items/1/Download?api_key=SECRET');
      expect(n, 'Download');
      expect(n.contains('SECRET'), isFalse);
    });
  });

  test('unreadyForNewMedia: only a real swap while ready, setting on', () {
    bool u({bool enabled = true, int last = 2, int id = 3, bool ready = true}) =>
        unreadyForNewMedia(enabled: enabled, lastMediaId: last, mediaId: id, ready: ready);
    expect(u(), isTrue);
    expect(u(enabled: false), isFalse);
    expect(u(ready: false), isFalse);
    expect(u(id: 2), isFalse, reason: 'same media');
    expect(u(last: -1), isFalse, reason: 'first state of a session is no swap');
  });
}
