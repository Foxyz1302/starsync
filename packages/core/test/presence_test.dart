import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

void main() {
  const policy = PresencePolicy();

  test('the table: what each presence counts for', () {
    String row(Presence p) => [
          for (final purpose in Purpose.values) policy.countsFor(p, purpose) ? 'y' : '-',
        ].join();
    // gate, readyCounter, tracking, preload, notifySocial (a joiner's gate
    // cell: held, just joined).
    expect(Purpose.values, [Purpose.gate, Purpose.readyCounter, Purpose.tracking, Purpose.preload, Purpose.notifySocial]);
    expect({for (final p in Presence.values) p.wire: row(p)}, {
      'joining': 'yy-yy',
      'in': 'yyyyy',
      'away': '-----',
      'gone': '-----',
    });
  });

  test('D2: a joiner never holds a playing gate, a held one at most joinerHold', () {
    expect(policy.countsFor(Presence.joining, Purpose.gate, playing: true), isFalse);
    expect(policy.countsFor(Presence.joining, Purpose.gate, joiningFor: const Duration(seconds: 14)), isTrue);
    expect(policy.countsFor(Presence.joining, Purpose.gate, joiningFor: const Duration(seconds: 15)), isFalse);
    const short = PresencePolicy(joinerHold: Duration(seconds: 2));
    expect(short.countsFor(Presence.joining, Purpose.gate, joiningFor: const Duration(seconds: 2)), isFalse);
    expect(policy.countsFor(Presence.watching, Purpose.gate, playing: true), isTrue);
  });

  test('wire names', () {
    expect([for (final p in Presence.values) p.wire], ['joining', 'in', 'away', 'gone']);
    for (final p in Presence.values) {
      expect(Presence.parse(p.wire), p);
    }
    expect(Presence.parse('watching'), isNull, reason: 'the wire says in');
    expect(PresenceReason.parse('minimised'), PresenceReason.minimised);
    expect(PresenceReason.parse('nonsense'), PresenceReason.manual);
  });

  test('alone: nobody else connected (gone is not company)', () {
    expect(isAlone(const []), isTrue);
    expect(isAlone(const [Presence.gone, Presence.gone]), isTrue);
    expect(isAlone(const [Presence.gone, Presence.away]), isFalse);
    expect(isAlone(const [Presence.joining]), isFalse);
    expect(isAlone(const [Presence.watching]), isFalse);
  });
}
