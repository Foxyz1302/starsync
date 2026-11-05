import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

MemberView member(String id,
        {Presence presence = Presence.watching, bool gone = false, Map<String, bool> jf = const {}, String name = ''}) =>
    MemberView(id: id, name: name.isEmpty ? id : name, presence: presence, gone: gone, jf: jf);

QueueItem item(QueueHow how, {String by = 'm2', String byName = 'Bob'}) => QueueItem(
      id: 'q1',
      media: how == QueueHow.jellyfin
          ? const HelloMedia(name: 'ep', size: 0, duration: 0, jellyfin: JellyfinRef(serverId: 'S', itemId: 'i'))
          : const HelloMedia(name: 'x', size: 0, duration: 0, url: 'https://x/y'),
      how: how,
      title: 'x',
      by: by,
      byName: byName,
    );

void main() {
  group('queuePerformer: who puts an item up (the server and every app read it the same)', () {
    test('a link passed on or a file: only its adder; gone waits for it, left means skipped', () {
      for (final how in [QueueHow.through, QueueHow.file]) {
        expect(queuePerformer(item(how), [member('m1'), member('m2', presence: Presence.out)]).id, 'm2',
            reason: 'out, its app still puts its own item up');
        final waits = queuePerformer(item(how), [member('m1'), member('m2', gone: true)]);
        expect((waits.id, waits.why), (null, null), reason: 'a gone adder may come back within its grace');
        final left = queuePerformer(item(how), [member('m1'), member('m3')]);
        expect((left.id, left.why), (null, 'Bob left'));
      }
    });

    test('Jellyfin: the adder with access, else the lowest member with access, else skipped', () {
      final access = {'S': true};
      expect(queuePerformer(item(QueueHow.jellyfin), [member('m1', jf: access), member('m2', jf: access)]).id, 'm2');
      expect(
          queuePerformer(item(QueueHow.jellyfin), [member('m10', jf: access), member('m3', jf: access), member('m2')])
              .id,
          'm3');
      expect(
          queuePerformer(
                  item(QueueHow.jellyfin), [member('m3', jf: access, presence: Presence.afk), member('m2')])
              .why,
          'nobody here has that Jellyfin server');
    });

    test('a link everyone opens or the server fetches: the adder, else the lowest present member', () {
      for (final how in [QueueHow.direct, QueueHow.server]) {
        expect(queuePerformer(item(how), [member('m1'), member('m2')]).id, 'm2');
        expect(
            queuePerformer(item(how), [member('m4'), member('m2', gone: true), member('m3')]).id, 'm3');
        final nobody = queuePerformer(item(how), [member('m2', presence: Presence.out)]);
        expect((nobody.id, nobody.why), (null, null), reason: 'nobody around is not a skip');
      }
    });

    test('member ids order by number: m2 before m10', () {
      expect(compareMemberIds('m9', 'm10'), lessThan(0));
      expect(lowestMemberId([member('m10'), member('m9')]), 'm9');
      expect(lowestMemberId(const []), isNull);
    });
  });

  test('passed over for a play request: someone else who can, never the adder of its own file', () {
    final access = {'S': true};
    final members = [member('m1', jf: access), member('m2', jf: access), member('m3')];
    expect(queuePerformer(item(QueueHow.jellyfin), members, pass: ['m2']).id, 'm1');
    expect(queuePerformer(item(QueueHow.jellyfin), members, pass: ['m1', 'm2']).why, isNotNull);
    expect(queuePerformer(item(QueueHow.direct), members, pass: ['m2']).id, 'm1');
    expect(queuePerformer(item(QueueHow.file), members, pass: ['m2']).id, 'm2', reason: 'only its adder has the file');
  });

  test('the continuation: who put the media up, else the first member present', () {
    final members = [member('m1', presence: Presence.out), member('m2', presence: Presence.brb), member('m3')];
    expect(mayAddContinuation('m1', 'm1', members), isTrue, reason: 'the swapper itself');
    expect(mayAddContinuation('m2', 'm1', members), isTrue, reason: 'the swapper is out: the first present (BRB counts)');
    expect(mayAddContinuation('m3', 'm1', members), isFalse);
    expect(mayAddContinuation('m2', 'm3', members), isFalse, reason: 'the swapper is in');
    expect(mayAddContinuation('m2', null, members), isTrue, reason: 'the media the server started with');
    expect(mayAddContinuation('', 'm1', members), isFalse);
  });

  test('seconds left of a countdown, on the server clock', () {
    final at = DateTime.utc(2026, 1, 1);
    final a = QueueAdvance(id: 'q1', at: at, secs: 10);
    expect(advanceSecondsLeft(a, at), 10);
    expect(advanceSecondsLeft(a, at.add(const Duration(milliseconds: 100))), 10);
    expect(advanceSecondsLeft(a, at.add(const Duration(seconds: 9, milliseconds: 1))), 1);
    expect(advanceSecondsLeft(a, at.add(const Duration(seconds: 12))), 0);
  });
}
