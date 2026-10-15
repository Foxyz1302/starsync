import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/files/scanner.dart' show FolderScan;
import 'package:starsync/src/library/library_store.dart';
import 'package:starsync/src/library/local_next.dart';
import 'package:starsync/src/library/show_matcher.dart';
import 'package:starsync/src/queue/queue_logic.dart';

import 'show_matcher_test.dart' show FakeAniList;

// What's next on the app: an item's words, and what continues a file of
// a local show (who puts an item up and the countdown are core's and the
// server's: core `whats_next_test`, `queue_test`).

QueueItem item(QueueHow how, {String by = 'm2', String byName = 'Bob'}) => QueueItem(
      id: 'q1',
      media: const HelloMedia(name: 'x', size: 0, duration: 0, url: 'https://x/y'),
      how: how,
      title: 'x',
      by: by,
      byName: byName,
    );

void main() {
  test('labels', () {
    expect(queueHowLabel(item(QueueHow.through), selfId: 'm2'), 'through you');
    expect(queueHowLabel(item(QueueHow.through), selfId: 'm1'), 'through Bob');
    expect(queueHowLabel(item(QueueHow.file), selfId: 'm1'), "Bob's file");
    expect(queueHowLabel(item(QueueHow.file, byName: ''), selfId: 'm1'), "who added it's file");
    expect(queueClock(3725), '1:02:05');
    expect(queueClock(65), '1:05');
    expect(queueClock(0), '');
  });

  group('what continues a file of a local show', () {
    const dir = '/lib/Bleach';
    String ep(int n) => '$dir/[Judas] Bleach - ${n.toString().padLeft(3, '0')}.mkv';
    // 064 and 065 are there, 066..107 are not.
    final files = [for (final n in [63, 64, 65, 108, 109]) LocalFile(ep(n), 1 << 30, DateTime(2026))];
    late List<String> scanned;
    late LocalNextFinder finder;
    late ShowMatcher matcher;

    setUp(() {
      scanned = [];
      matcher = ShowMatcher(store: MemoryLibraryStore(), aniList: FakeAniList(), delay: (_) async {});
      finder = LocalNextFinder(
          matcher: matcher,
          scan: (d) async {
            scanned.add(d);
            return FolderScan(videos: files, hiddenCount: 0, hiddenExamples: const [], subtitles: const {}, truncated: false);
          });
    });

    test('from its own folder when the library has not seen it this run', () async {
      final next = await finder.nextAfter(ep(64));
      expect(next!.episode.path, ep(65));
      expect(next.skipped, isNull);
      expect(scanned, [dir]);
    });

    test('numbers skipped on the way are said', () async {
      final next = await finder.nextAfter(ep(65));
      expect(next!.episode.path, ep(108));
      expect(next.skipped!.label, '66–107');
    });

    test('the last one, or not an episode: nothing continues it', () async {
      expect(await finder.nextAfter(ep(109)), isNull);
      expect(await finder.nextAfter('$dir/notes.mkv'), isNull);
    });

    test('the library the Files page saw is used without a scan', () async {
      matcher.remember(groupLocal(files, roots: const ['/lib']));
      expect((await finder.nextAfter(ep(63)))!.episode.path, ep(64));
      expect(scanned, isEmpty);
    });
  });
}
