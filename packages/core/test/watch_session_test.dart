// restructure: rewrite in step 5 (D3: the watched rule moves from position coverage to time present)
import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

/// Plays [from]..[to] at normal speed, one sample a second, starting at
/// wall second [t]; returns the wall second after.
int play(WatchSession w, int t, double from, double to) {
  var pos = from;
  w.sample(pos, playing: true, at: DateTime(2026, 1, 1).add(Duration(seconds: t)));
  while (pos < to) {
    t++;
    pos = pos + 1 > to ? to : pos + 1;
    w.sample(pos, playing: true, at: DateTime(2026, 1, 1).add(Duration(seconds: t)));
  }
  return t + 1;
}

void main() {
  const ep = 1440.0; // 24 min
  const ed = 1350.0; // the ending starts 1.5 min before the end

  test('normal playback counts; seeks, skips and pauses do not', () {
    final w = WatchSession();
    var t = play(w, 0, 0, 60);
    // A jump ahead between two samples: not watched.
    w.sample(600, playing: true, at: DateTime(2026, 1, 1).add(Duration(seconds: t)));
    t = play(w, t + 1, 600, 630);
    // Paused: the position does not move, nothing counts.
    w.sample(630, playing: false, at: DateTime(2026, 1, 1).add(Duration(seconds: t + 30)));
    expect(w.covered, closeTo(90, 1));
    expect(w.spans, hasLength(2));
    expect(w.firstPosition, 0);
    expect(w.lastPosition, 630);
    expect(w.furthest, 630);
  });

  test('rewatching a part counts once in coverage, twice in watched time', () {
    final w = WatchSession();
    var t = play(w, 0, 0, 300);
    t = play(w, t, 100, 200); // went back for a moment
    expect(w.covered, closeTo(300, 1));
    expect(w.watched, closeTo(400, 1));
  });

  test('played: 70 % covered, or the ending (or the last 15 %) reached after 40 %', () {
    final full = WatchSession();
    play(full, 0, 0, 1200); // 83 %
    expect(full.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.played);

    final skipped = WatchSession();
    final t = play(skipped, 0, 0, 800); // 56 %, then skipped to the ED
    play(skipped, t, ed, ed + 5);
    expect(skipped.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.played);
    // Without a known ending the last 15 % (at most 4 min) counts.
    expect(skipped.verdict(runtime: ep).outcome, WatchOutcome.played);

    // Watched with the opening skipped, stopped 3 min before the end.
    final early = WatchSession();
    final u = play(early, 0, 0, 90);
    play(early, u, 180, ep - 180);
    expect(early.verdict(runtime: ep).outcome, WatchOutcome.played);

    final jumped = WatchSession();
    play(jumped, 0, 0, 400); // 28 %, then jumped to the end
    jumped.sample(ep, playing: false, at: DateTime(2026, 1, 2));
    expect(jumped.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.partial);
  });

  test('played before: stays played however little was watched', () {
    final w = WatchSession(playedBefore: true);
    play(w, 0, 700, 730); // checking a moment
    expect(w.verdict(runtime: ep, endingStart: ed).outcome, WatchOutcome.keepPlayed);
  });

  test('a peek leaves nothing; part way resumes at the last position', () {
    final peek = WatchSession(resumeBefore: 300);
    play(peek, 0, 900, 990); // 90 s
    expect(peek.verdict(runtime: ep).outcome, WatchOutcome.peek);

    final movie = WatchSession();
    play(movie, 0, 0, 300); // 5 min of 2 h: under 5 %
    expect(movie.verdict(runtime: 7200).outcome, WatchOutcome.peek);

    final part = WatchSession();
    final t = play(part, 0, 0, 500);
    part.sample(450, playing: false, at: DateTime(2026, 1, 1).add(Duration(seconds: t)));
    final v = part.verdict(runtime: ep);
    expect(v.outcome, WatchOutcome.partial);
    expect(v.resumeAt, 450);

    // A 3 min clip: half of it is not a peek.
    final clip = WatchSession();
    play(clip, 0, 0, 90);
    expect(clip.verdict(runtime: 180).outcome, WatchOutcome.partial);
  });

  test('an unknown runtime never makes it played', () {
    final w = WatchSession();
    play(w, 0, 0, 1000);
    expect(w.verdict(runtime: 0).outcome, WatchOutcome.partial);
  });
}
