// Pure session logic: auto sit-out on a fake clock, link names, the
// unready-on-swap rule.
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart' show Presence, PresenceReason;
import 'package:starsync/src/platform/ports/shell_port.dart' show WindowActivity;
import 'package:starsync/src/session/auto_sit_out.dart';
import 'package:starsync/src/session/session_coordinator.dart';

void main() {
  group('AutoSitOut', () {
    final t0 = DateTime.utc(2026, 1, 1, 12);
    const idle = AutoSitOutTimes.idle;
    const minimised = AutoSitOutTimes.minimised;

    /// Ticks once a second from [from] for [span]; the steps that were not
    /// [AutoStay], at their second.
    List<(int, String)> run(AutoSitOut a, DateTime from, Duration span,
        {Presence self = Presence.watching, bool playing = false, bool alone = false, bool enabled = true}) {
      final out = <(int, String)>[];
      for (var s = 0; s <= span.inSeconds; s++) {
        final step = a.tick(from.add(Duration(seconds: s)),
            self: self, playing: playing, alone: alone, enabled: enabled);
        switch (step) {
          case AutoAway(:final reason):
            out.add((s, 'away ${reason.name}'));
          case AutoBack():
            out.add((s, 'back'));
          case AutoStay():
            break;
        }
      }
      return out;
    }

    test('not playing: idle for the idle time sets you away (idle)', () {
      final a = AutoSitOut(t0);
      expect(run(a, t0, idle), [(idle.inSeconds, 'away idle')]);
    });

    test('never when alone, never when switched off', () {
      expect(run(AutoSitOut(t0), t0, const Duration(minutes: 30), alone: true), isEmpty);
      expect(run(AutoSitOut(t0), t0, const Duration(minutes: 30), enabled: false), isEmpty);
      final m = AutoSitOut(t0)..window(WindowActivity.minimised, t0);
      expect(run(m, t0, const Duration(minutes: 30), alone: true, playing: true), isEmpty);
    });

    test('while playing idle input does not count, minimised for a while does', () {
      final a = AutoSitOut(t0);
      expect(run(a, t0, const Duration(minutes: 30), playing: true), isEmpty, reason: 'watching is activity');
      final at = t0.add(const Duration(minutes: 30));
      a.window(WindowActivity.minimised, at);
      expect(run(a, at, minimised, playing: true), [(minimised.inSeconds, 'away minimised')]);
    });

    test('a pause after a long watch starts a fresh idle clock', () {
      final a = AutoSitOut(t0);
      run(a, t0, const Duration(minutes: 30), playing: true);
      final paused = t0.add(const Duration(minutes: 30, seconds: 1));
      expect(run(a, paused, idle - const Duration(seconds: 2)), isEmpty);
    });

    test('back on input or focus, only from an automatic away', () {
      final a = AutoSitOut(t0);
      expect(run(a, t0, idle), [(idle.inSeconds, 'away idle')]);
      final at = t0.add(idle);
      // The away shows in the next states; nothing until the user is back.
      expect(run(a, at, const Duration(minutes: 5), self: Presence.away), isEmpty);
      final later = at.add(const Duration(minutes: 5, seconds: 1));
      a.input(later);
      expect(run(a, later, const Duration(seconds: 1), self: Presence.away), [(0, 'back')]);

      // Minimised away: restoring is not enough, the focus brings it back.
      final b = AutoSitOut(t0)..window(WindowActivity.minimised, t0);
      expect(run(b, t0, minimised, playing: true), [(minimised.inSeconds, 'away minimised')]);
      final m = t0.add(minimised);
      b.window(WindowActivity.unfocused, m);
      expect(run(b, m, const Duration(seconds: 3), self: Presence.away), isEmpty);
      b.window(WindowActivity.focused, m);
      expect(run(b, m, const Duration(seconds: 1), self: Presence.away), [(0, 'back')]);
    });

    test('a manual away (own or someone else\'s) is never returned automatically', () {
      // Someone else sat you out: activity does not bring you back.
      final a = AutoSitOut(t0);
      a.input(t0);
      expect(run(a, t0, const Duration(minutes: 20), self: Presence.away), isEmpty);
      // Auto away, then the user sits out by hand: it stays.
      final b = AutoSitOut(t0);
      expect(run(b, t0, idle), [(idle.inSeconds, 'away idle')]);
      b.manual();
      final at = t0.add(idle);
      b.input(at);
      expect(run(b, at, const Duration(minutes: 1), self: Presence.away), isEmpty);
    });

    test('an away not yet echoed is not sent again', () {
      final a = AutoSitOut(t0);
      // The state still says `in` for a few seconds after the away went out.
      expect(run(a, t0, idle + const Duration(seconds: 8)), [(idle.inSeconds, 'away idle')]);
      expect(a.autoAway, isTrue);
    });

    test('the reasons on the wire', () {
      expect(PresenceReason.idle.name, 'idle');
      expect(PresenceReason.minimised.name, 'minimised');
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
