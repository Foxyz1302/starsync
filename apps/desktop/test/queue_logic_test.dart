// restructure: rewrite in step 6 (What's next): who performs an item and
// the janitor become server state.
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/queue/queue_logic.dart';

MemberView member(String id,
        {bool stale = false, bool out = false, Map<String, bool> jf = const {}, String name = ''}) =>
    MemberView(
        id: id, name: name.isEmpty ? id : name, ready: false, inSet: true, buffered: 0, stale: stale, out: out, jf: jf);

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
  group('queuePerformer', () {
    test('a link passed on or a file: only its adder; gone means skipped', () {
      for (final how in [QueueHow.through, QueueHow.file]) {
        expect(queuePerformer(item(how), [member('m1'), member('m2', out: true)]).id, 'm2');
        final gone = queuePerformer(item(how), [member('m1'), member('m3')]);
        expect(gone.id, isNull);
        expect(gone.why, 'Bob left');
      }
    });

    test('Jellyfin: the adder with access, else the lowest member with access, else skipped', () {
      final access = {'S': true};
      expect(queuePerformer(item(QueueHow.jellyfin), [member('m1', jf: access), member('m2', jf: access)]).id, 'm2');
      expect(
          queuePerformer(item(QueueHow.jellyfin), [member('m10', jf: access), member('m3', jf: access), member('m2')])
              .id,
          'm3');
      expect(queuePerformer(item(QueueHow.jellyfin), [member('m3', jf: access, out: true), member('m2')]).why,
          isNotNull);
    });

    test('a link everyone opens or the server fetches: the adder, else the lowest active member', () {
      for (final how in [QueueHow.direct, QueueHow.server]) {
        expect(queuePerformer(item(how), [member('m1'), member('m2')]).id, 'm2');
        expect(queuePerformer(item(how), [member('m4'), member('m2', stale: true), member('m3')]).id, 'm3');
        final nobody = queuePerformer(item(how), [member('m2', out: true)]);
        expect((nobody.id, nobody.why), (null, null), reason: 'nobody around is not a skip');
      }
    });
  });

  test('the janitor is the lowest member that is not stale', () {
    expect(queueJanitor([member('m9'), member('m1', stale: true), member('m2')]), 'm2');
  });

  test('labels', () {
    expect(queueHowLabel(item(QueueHow.through), selfId: 'm2'), 'through you');
    expect(queueHowLabel(item(QueueHow.through), selfId: 'm1'), 'through Bob');
    expect(queueHowLabel(item(QueueHow.file), selfId: 'm1'), "Bob's file");
    expect(queueClock(3725), '1:02:05');
    expect(queueClock(65), '1:05');
    expect(queueClock(0), '');
  });
}
