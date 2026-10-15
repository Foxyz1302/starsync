import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

final _t0 = DateTime(2026, 1, 1);

/// One sample a second for [secs] seconds from wall second [t], the
/// position moving with the wall clock from [from] while [playing];
/// returns the wall second after.
int run(WatchSession w, int t, double from, int secs, {bool playing = true, bool present = true}) {
  for (var i = 0; i <= secs; i++) {
    w.sample(from + (playing ? i : 0), playing: playing, present: present, at: _t0.add(Duration(seconds: t + i)));
  }
  return t + secs + 1;
}

void main() {
  const ep = 1440.0; // 24 min
  const ed = 1350.0; // the ending starts 1.5 min before the end

  group('time In', () {
    test('counts the time it played while In; pauses, holds and jumps add nothing', () {
      final w = WatchSession();
      var t = run(w, 0, 0, 60);
      // Held (the server waits for someone): the clock runs, nothing counts.
      t = run(w, t, 60, 30, playing: false);
      // A jump ahead: only the time actually played after it.
      t = run(w, t, 600, 30);
      expect(w.timeIn, closeTo(90, 2));
      expect(w.furthest, 630);
      expect(w.firstPosition, 0);
    });

    test('sat out (Away) or joining: not counted, though the media plays on (P7)', () {
      final w = WatchSession();
      var t = run(w, 0, 0, 120); // in for two minutes
      t = run(w, t, 120, 1200, present: false); // sat out for the rest
      expect(w.timeIn, closeTo(120, 2));
      expect(w.verdict(runtime: ep).outcome, WatchOutcome.partial);
      expect(w.furthest, closeTo(120, 1), reason: 'positions while away are not this viewer\'s');
    });

    test('a stall longer than the gap adds nothing', () {
      final w = WatchSession();
      w.sample(0, playing: true, present: true, at: _t0);
      w.sample(30, playing: true, present: true, at: _t0.add(const Duration(seconds: 30)));
      expect(w.timeIn, 0);
    });

    test('drift corrections and small seeks while watching do not cost watched time (P9)', () {
      final w = WatchSession();
      var pos = 0.0;
      for (var i = 0; i <= 1200; i++) {
        // Every 7 s the player is corrected half a second back or ahead.
        if (i % 7 == 0) pos += i % 14 == 0 ? 0.5 : -0.5;
        w.sample(pos, playing: true, present: true, at: _t0.add(Duration(seconds: i)));
        pos += 1;
      }
      expect(w.timeIn, closeTo(1200, 1));
      expect(w.verdict(runtime: ep).outcome, WatchOutcome.played);
    });
  });

  group('verdict (D3)', () {
    test('played: 70 % of the runtime In, or the ending (or the last 15 %) reached after 40 %', () {
      final full = WatchSession();
      run(full, 0, 0, 1200); // 83 %
      expect(full.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.played);

      // The opening and the ending skipped, stopped at the ED: Jellyfin's
      // own rule (past 90 %) would count it too.
      final skipped = WatchSession();
      var t = run(skipped, 0, 0, 90);
      t = run(skipped, t, 180, 1170); // to the ED start
      expect(skipped.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.played);
      expect(skipped.verdict(runtime: ep).outcome, WatchOutcome.played);

      final half = WatchSession();
      t = run(half, 0, 0, 800); // 56 %, then a skip to the ED
      run(half, t, ed, 5);
      expect(half.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.played);
    });

    test('skipping around or a screenshot visit never counts', () {
      // Through the whole episode in 30 s jumps, 2 s at each stop.
      final hops = WatchSession();
      var t = 0;
      for (var p = 0.0; p < ep; p += 30) {
        t = run(hops, t, p, 2);
      }
      expect(hops.furthest, greaterThan(ed));
      expect(hops.verdict(runtime: ep, endingStart: ed).watched, isFalse);

      final shot = WatchSession();
      run(shot, 0, 700, 20);
      expect(shot.verdict(runtime: ep).outcome, WatchOutcome.peek);

      // A quarter watched, then a jump to the end: part way, not played.
      final jumped = WatchSession();
      t = run(jumped, 0, 0, 400);
      run(jumped, t, ep - 5, 5);
      expect(jumped.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.partial);
    });

    test('played before: stays played however little was watched', () {
      final w = WatchSession(playedBefore: true);
      run(w, 0, 700, 30);
      expect(w.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.keepPlayed);
      expect(w.verdict(runtime: ep).watched, isTrue);
    });

    test('a resume continues the earlier watch', () {
      final resumed = WatchSession(resumeBefore: 600);
      run(resumed, 0, 590, 800); // from the resume point to the end
      expect(resumed.credited, closeTo(1400, 2));
      expect(resumed.verdict(runtime: ep).outcome, WatchOutcome.played);

      // Played from the start again: the earlier part is not counted twice.
      final again = WatchSession(resumeBefore: 600);
      run(again, 0, 0, 300);
      expect(again.credited, closeTo(300, 2));
    });

    test('a peek leaves nothing; part way resumes at the last position', () {
      final peek = WatchSession(resumeBefore: 300);
      run(peek, 0, 900, 90);
      expect(peek.verdict(runtime: ep).outcome, WatchOutcome.peek);

      final movie = WatchSession();
      run(movie, 0, 0, 300); // 5 min of 2 h: under 5 %
      expect(movie.verdict(runtime: 7200).outcome, WatchOutcome.peek);

      final part = WatchSession();
      final t = run(part, 0, 0, 500);
      part.sample(450, playing: false, present: true, at: _t0.add(Duration(seconds: t)));
      final v = part.verdict(runtime: ep);
      expect(v.outcome, WatchOutcome.partial);
      expect(v.resumeAt, 450);

      // A 3 min clip: half of it is not a peek.
      final clip = WatchSession();
      run(clip, 0, 0, 90);
      expect(clip.verdict(runtime: 180).outcome, WatchOutcome.partial);
    });

    test('an unknown runtime never makes it played', () {
      final w = WatchSession();
      run(w, 0, 0, 1000);
      expect(w.verdict(runtime: 0).outcome, WatchOutcome.partial);
    });
  });
}
