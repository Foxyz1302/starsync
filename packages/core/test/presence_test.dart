import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  const policy = PresencePolicy();

  test('the table: what each standing counts for', () {
    String row(Presence p, {bool gone = false, bool loading = false}) => [
          for (final purpose in Purpose.values) policy.countsFor(p, purpose, gone: gone, loading: loading) ? 'y' : '-',
        ].join();
    expect(Purpose.values, [Purpose.tracking, Purpose.preload, Purpose.notifySocial]);
    expect({for (final p in Presence.values) p.wire: row(p)}, {
      'in': 'yyy',
      'brb': 'yyy',
      'afk': '---',
      'out': '---',
    });
    expect(row(Presence.watching, loading: true), '-yy', reason: 'loading: not watching yet');
    expect(row(Presence.watching, gone: true), '---', reason: 'gone counts for nothing');
    expect(row(Presence.brb, gone: true), '---');
  });

  test('wire names; AFK and Out are both out', () {
    expect([for (final p in Presence.values) p.wire], ['in', 'brb', 'afk', 'out']);
    for (final p in Presence.values) {
      expect(Presence.parse(p.wire), p);
    }
    expect(Presence.parse('watching'), isNull, reason: 'the wire says in');
    expect(Presence.parse('away'), isNull, reason: 'proto 16 is gone');
    expect([for (final p in Presence.values) p.isOut], [false, false, true, true]);
    expect(PresenceReason.parse('minimised'), PresenceReason.minimised);
    expect(PresenceReason.parse('continue'), PresenceReason.continued);
    expect(PresenceReason.continued.wire, 'continue');
    expect(PresenceReason.parse('nonsense'), PresenceReason.manual);
  });

  test('alone: nobody else connected (gone is not company, out is)', () {
    expect(isAlone(const []), isTrue);
    expect(isAlone(const [true, true]), isTrue);
    expect(isAlone(const [true, false]), isFalse);
  });
}
