import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/watch/watch_history.dart';
import 'package:starsync/src/watch/watch_tracker.dart';

// Watch tracking (D3): one watch per media of the server, time In from the
// presence the server reports, the device history for files and links,
// every closed watch out on `records` (the seam for AniList later).

final _t0 = DateTime.utc(2026, 1, 1);

void main() {
  late WatchTracker tracker;
  late List<WatchRecord> records;

  setUp(() {
    tracker = WatchTracker(history: WatchHistory(persist: false));
    records = [];
    tracker.records.listen(records.add);
  });

  tearDown(() => tracker.dispose());

  const episode = {'name': 'Bleach - 064.mkv', 'size': 100, 'duration': 1440, 'ref': {'kind': 'episode', 'title': 'Bleach', 'absolute': 64}};

  /// [secs] seconds of media [mediaId] from wall second [t], playing,
  /// with self [present] or not.
  int run(int mediaId, Map<String, Object?> media, int t, int secs,
      {bool present = true, bool playing = true, String? ownFile, double from = 0}) {
    for (var i = 0; i <= secs; i++) {
      tracker.sample(WatchSample(
        mediaId: mediaId,
        media: media,
        ownFile: ownFile,
        position: from + i,
        playing: playing,
        present: present,
        duration: 1440,
        at: _t0.add(Duration(seconds: t + i)),
      ));
    }
    return t + secs + 1;
  }

  test('a file watched through goes into the history as watched; the next media closes the watch', () async {
    const path = '/lib/Bleach/Bleach - 064.mkv';
    final t = run(2, episode, 0, 1200, ownFile: path);
    run(3, const {'name': 'next', 'size': 1}, t, 1);
    await Future<void>.delayed(Duration.zero);
    expect(records.first.key, WatchKey.file(path));
    expect(records.first.verdict.outcome, WatchOutcome.played);
    expect(records.first.ref?.absolute, 64);
    final e = tracker.history.entry(WatchKey.file(path))!;
    expect((e.played, e.resumeAt, e.title), (true, 0.0, 'Bleach - 064.mkv'));
    expect(tracker.mediaId, 3);
  });

  test('sat out for most of it: not watched (P7), a resume point instead', () async {
    const url = 'https://example.com/v.mp4';
    final media = {'name': 'v', 'size': 0, 'duration': 1440, 'url': url};
    var t = run(2, media, 0, 300);
    t = run(2, media, t, 1100, present: false, from: 300);
    tracker.close(at: _t0.add(Duration(seconds: t)));
    await Future<void>.delayed(Duration.zero);
    expect(records.single.verdict.outcome, WatchOutcome.partial);
    expect(records.single.timeIn, closeTo(300, 2));
    final e = tracker.history.entry(WatchKey.link(url))!;
    expect(e.played, isFalse);
    expect(e.resumeAt, closeTo(300, 1), reason: 'where this viewer was when it sat out');
  });

  test('a peek changes nothing; a played item stays played', () async {
    const path = '/lib/x.mkv';
    run(2, episode, 0, 1200, ownFile: path);
    tracker.close();
    expect(tracker.history.entry(WatchKey.file(path))!.played, isTrue);
    run(4, episode, 0, 20, ownFile: path);
    expect(tracker.session!.playedBefore, isTrue, reason: 'the history says it was watched');
    tracker.close();
    expect(tracker.history.entry(WatchKey.file(path))!.played, isTrue);
    final other = WatchKey.of(const {'name': 'peeked', 'size': 5})!;
    run(5, const {'name': 'peeked', 'size': 5, 'duration': 1440}, 0, 20);
    tracker.close();
    expect(tracker.history.entry(other), isNull);
  });

  test('Jellyfin: the watch is shared with its reports, not kept in the device history', () async {
    final media = {
      'name': 'ep',
      'size': 0,
      'duration': 1440,
      'jellyfin': {'serverId': 'S', 'itemId': 'i'},
    };
    run(2, media, 0, 10);
    tracker.before(played: true, resumeAt: 0);
    expect(tracker.verdict!.outcome, WatchOutcome.keepPlayed);
    tracker.close();
    await Future<void>.delayed(Duration.zero);
    expect(records.single.key.isJellyfin, isTrue);
    expect(tracker.history.entries, isEmpty);
  });

  test('keys: own file, Jellyfin, own or shared link, else name and size', () {
    expect(WatchKey.of(const {'name': 'a', 'size': 1}, ownFile: '/x.mkv'), WatchKey.file('/x.mkv'));
    expect(
        WatchKey.of(const {
          'name': 'a',
          'jellyfin': {'serverId': 'S', 'itemId': 'i'}
        }),
        WatchKey.jellyfin(const JellyfinRef(serverId: 'S', itemId: 'i')));
    expect(WatchKey.of(const {'name': 'a', 'relay': {}}, ownLink: 'https://x/y'), WatchKey.link('https://x/y'));
    expect(WatchKey.of(const {'name': 'a', 'url': 'https://x/z'}), WatchKey.link('https://x/z'));
    expect(WatchKey.of(const {'name': 'a', 'size': 3}), WatchKey.media('a', 3));
    expect(WatchKey.of(null), isNull);
  });
}
