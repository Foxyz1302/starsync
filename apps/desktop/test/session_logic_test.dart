// Pure session logic: AFK and the Space gesture on a fake clock, link names.
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart' show MemberView, Presence;
import 'package:starsync/src/platform/ports/shell_port.dart' show WindowActivity;
import 'package:starsync/src/session/afk_watch.dart';
import 'package:starsync/src/session/session_coordinator.dart';
import 'package:starsync/src/session/space_gesture.dart';
import 'package:starsync/src/session/space_key.dart' show holdKeysFor, holdLineFor;

void main() {
  group('AfkWatch', () {
    final t0 = DateTime.utc(2026, 1, 1, 12);
    const idle = AfkTimes.idle;
    const minimised = AfkTimes.minimised;
    DateTime at(Duration d) => t0.add(d);
    AfkStep tick(AfkWatch w, Duration d, {Presence? self = Presence.watching, bool playing = false, bool alone = false}) =>
        w.tick(at(d), self: self, playing: playing, alone: alone);

    test('no input for 10 min while nothing plays: AFK; never while it plays, never when alone', () {
      final w = AfkWatch(t0);
      expect(tick(w, idle - const Duration(seconds: 1)), AfkStep.stay);
      expect(tick(w, idle), AfkStep.afk);
      final playing = AfkWatch(t0);
      expect(tick(playing, idle * 3, playing: true), AfkStep.stay, reason: 'watching is activity');
      final alone = AfkWatch(t0);
      expect(tick(alone, idle * 2, alone: true), AfkStep.stay);
    });

    test('never on a BRB member, nor someone already out', () {
      final w = AfkWatch(t0);
      expect(tick(w, idle * 2, self: Presence.brb), AfkStep.stay);
      expect(tick(w, idle * 2, self: Presence.out), AfkStep.stay);
      expect(tick(w, idle * 2, self: null), AfkStep.stay, reason: 'not in a state, or disconnected');
    });

    test('a pause after a long watch starts a fresh clock', () {
      final w = AfkWatch(t0);
      expect(tick(w, const Duration(minutes: 40), playing: true), AfkStep.stay);
      expect(tick(w, const Duration(minutes: 40) + idle - const Duration(seconds: 1)), AfkStep.stay);
      expect(tick(w, const Duration(minutes: 40) + idle), AfkStep.afk);
    });

    test('any input brings AFK back, but not within the first 1.2 s', () {
      final w = AfkWatch(t0);
      expect(tick(w, idle), AfkStep.afk);
      expect(tick(w, idle + const Duration(seconds: 1), self: Presence.afk), AfkStep.stay);
      // The input that happened to land with it.
      w.input(at(idle + const Duration(seconds: 1, milliseconds: 500)));
      expect(tick(w, idle + const Duration(seconds: 2), self: Presence.afk), AfkStep.stay);
      w.input(at(idle + const Duration(seconds: 3)));
      expect(tick(w, idle + const Duration(seconds: 4), self: Presence.afk), AfkStep.back);
      w.window(WindowActivity.focused, at(idle + const Duration(seconds: 5)));
      expect(tick(w, idle + const Duration(seconds: 6), self: Presence.afk), AfkStep.stay,
          reason: 'one back sent, waiting for its echo');
    });

    test('minimised 10 min while it plays: out; the window coming back does not undo it', () {
      final w = AfkWatch(t0);
      w.window(WindowActivity.minimised, t0);
      expect(tick(w, minimised - const Duration(seconds: 1), playing: true), AfkStep.stay);
      expect(tick(w, minimised, playing: true), AfkStep.outMinimised);
      w.window(WindowActivity.focused, at(minimised + const Duration(seconds: 20)));
      expect(tick(w, minimised + const Duration(seconds: 21), self: Presence.out, playing: true), AfkStep.stay,
          reason: 'Space or Join brings out back, not the window');
      final paused = AfkWatch(t0);
      paused.window(WindowActivity.hidden, t0);
      expect(tick(paused, minimised, playing: false, self: Presence.watching), AfkStep.afk,
          reason: 'not playing: idle is AFK');
    });
  });

  group('SpaceGesture', () {
    const t = SpaceTiming();
    Duration ms(int n) => Duration(milliseconds: n);

    test('a tap pauses on key-down while it plays, plays on key-up while paused', () {
      final g = SpaceGesture();
      expect(g.keyDown(self: Presence.watching, othersBrb: false, playing: true), [SpaceAction.pause]);
      expect(g.keyUp(ms(90)), isEmpty, reason: 'paused already');
      expect(g.keyDown(self: Presence.watching, othersBrb: false, playing: false), isEmpty);
      expect(g.keyUp(ms(90)), [SpaceAction.play]);
    });

    test('a hold of 0.6 s is BRB, keeping the wish it had at key-down', () {
      final g = SpaceGesture();
      g.keyDown(self: Presence.watching, othersBrb: false, playing: true);
      expect(g.tick(ms(599)), isEmpty);
      expect(g.hold()!.kind, HoldKind.brb);
      expect(g.tick(t.brbHold), [SpaceAction.brbKeepPlay]);
      expect(g.keyUp(ms(900)), isEmpty, reason: 'done already');
      g.keyDown(self: Presence.watching, othersBrb: false, playing: false);
      expect(g.keyUp(ms(700)), [SpaceAction.brbKeepPause], reason: 'a key-up past the hold finishes it');
    });

    test('while someone else is BRB: a tap toggles your own BRB, a 2 s hold continues without', () {
      final g = SpaceGesture();
      expect(g.keyDown(self: Presence.watching, othersBrb: true, playing: true), isEmpty, reason: 'no pause');
      expect(g.keyUp(ms(120)), [SpaceAction.brbToo]);
      g.keyDown(self: Presence.brb, othersBrb: true, playing: true);
      expect(g.keyUp(ms(120)), [SpaceAction.back]);
      g.keyDown(self: Presence.watching, othersBrb: true, playing: true);
      expect(g.hold()!.tapStill, isTrue);
      g.tick(ms(500));
      expect(g.hold()!.tapStill, isFalse);
      expect(g.keyUp(ms(1500)), isEmpty, reason: 'let go before 2 s: keep waiting');
      g.keyDown(self: Presence.watching, othersBrb: true, playing: true);
      expect(g.tick(t.continueHold), [SpaceAction.continueWithout]);
    });

    test('BRB alone, AFK or out: back on key-down', () {
      for (final p in [Presence.brb, Presence.afk, Presence.out]) {
        final g = SpaceGesture();
        expect(g.keyDown(self: p, othersBrb: false, playing: false), [SpaceAction.back]);
        expect(g.keyUp(ms(800)), isEmpty);
      }
    });

    test('a second key-down without an up is ignored; a lost key-up drops the press', () {
      final g = SpaceGesture();
      g.keyDown(self: Presence.watching, othersBrb: false, playing: true);
      expect(g.keyDown(self: Presence.watching, othersBrb: false, playing: false), isEmpty);
      g.cancel();
      expect(g.down, isFalse);
      expect(g.tick(ms(2000)), isEmpty, reason: 'never BRB in the background');
      expect(g.keyUp(ms(2000)), isEmpty);
    });

    test("the pill's words during a hold", () {
      const bob = MemberView(id: 'm2', name: 'Bob', presence: Presence.brb);
      const brb = HoldView(HoldKind.brb, 0.3, Duration(milliseconds: 200), wasPlaying: true);
      expect([holdLineFor(brb).text, holdLineFor(brb).detail], ['Keep holding: BRB', 'Let go: just pause']);
      const tap = HoldView(HoldKind.continueWithout, 0.1, Duration(milliseconds: 200), tapStill: true);
      expect([holdLineFor(tap, othersBrb: [bob]).text, holdLineFor(tap, othersBrb: [bob]).detail],
          ['Keep holding: continuing without Bob', 'Let go now: BRB too']);
      const long = HoldView(HoldKind.continueWithout, 0.5, Duration(seconds: 1));
      expect(holdLineFor(long, othersBrb: [bob]).detail, 'Let go: keep waiting');
      expect(holdKeysFor(long, [bob]).first, ('Keep holding', 'continue without Bob'));
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
}
