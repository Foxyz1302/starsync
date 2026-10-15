import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/jellyfin/home_rows.dart';
import 'package:starsync/src/screens/home/media_picker.dart';
import 'package:starsync/src/shell/library_link.dart';
import 'package:starsync/src/shell/library_tab.dart';

final now = DateTime.utc(2026, 10, 8, 12);
DateTime daysAgo(num d) => now.subtract(Duration(minutes: (d * 24 * 60).round()));

JellyfinItem ep(String id, String series,
        {DateTime? played, int position = 0, int? season, int? number, bool done = false}) =>
    JellyfinItem(
      id: id,
      name: id,
      type: 'Episode',
      seriesId: series,
      seriesName: 'Series $series',
      parentIndexNumber: season,
      indexNumber: number,
      userData: JellyfinUserData(played: done, playbackPositionTicks: position, lastPlayedDate: played),
    );

JellyfinItem movie(String id, {DateTime? played, int position = 0}) => JellyfinItem(
      id: id,
      name: id,
      type: 'Movie',
      userData: JellyfinUserData(playbackPositionTicks: position, lastPlayedDate: played),
    );

List<String> ids(List<JellyfinItem> l) => [for (final i in l) i.id];

void main() {
  group('Continue row', () {
    test('one card per series: resume point and next up merged', () {
      final out = mergeContinue(
        resume: [ep('a3', 'A', played: daysAgo(1), position: 5)],
        nextUp: [ep('a4', 'A'), ep('b2', 'B')],
        recentlyPlayed: [ep('b1', 'B', played: daysAgo(2), done: true)],
        now: now,
      );
      expect(ids(out), ['a3', 'b2']);
    });

    test('the resume item only when it is the latest activity in its series', () {
      // Resumed E3 three days ago, then finished E4 yesterday: next up wins.
      final out = mergeContinue(
        resume: [ep('a3', 'A', played: daysAgo(3), position: 5)],
        nextUp: [ep('a5', 'A')],
        recentlyPlayed: [ep('a4', 'A', played: daysAgo(1), done: true)],
        now: now,
      );
      expect(ids(out), ['a5']);
      // No next up (last episode): the resume point stays.
      expect(
          ids(mergeContinue(
            resume: [ep('a3', 'A', played: daysAgo(3), position: 5)],
            nextUp: const [],
            recentlyPlayed: [ep('a4', 'A', played: daysAgo(1), done: true)],
            now: now,
          )),
          ['a3']);
    });

    test('ordered by when the series was last played; newest resume point of a series', () {
      final out = mergeContinue(
        resume: [
          ep('a1', 'A', played: daysAgo(5), position: 5),
          movie('m', played: daysAgo(0.5), position: 5),
          ep('a2', 'A', played: daysAgo(4), position: 5),
        ],
        nextUp: [ep('c1', 'C'), ep('b1', 'B')],
        recentlyPlayed: [
          ep('b0', 'B', played: daysAgo(2), done: true),
          ep('c0', 'C', played: daysAgo(3), done: true),
        ],
        now: now,
      );
      expect(ids(out), ['m', 'b1', 'c1', 'a2']);
    });

    test('series untouched for over 60 days drop out, unless nothing else is left', () {
      final stale = ep('old', 'O', played: daysAgo(90), position: 5);
      final unknown = ep('u1', 'U'); // next up with no play date known
      expect(
          ids(mergeContinue(
              resume: [stale, ep('a1', 'A', played: daysAgo(10), position: 5)],
              nextUp: [unknown],
              now: now)),
          ['a1']);
      expect(ids(mergeContinue(resume: [stale], nextUp: [unknown], now: now)), ['old', 'u1']);
      expect(mergeContinue(resume: const [], nextUp: const [], now: now), isEmpty);
    });

    test('a dismissed series stays out until it is played again', () {
      List<String> run(DateTime playedAt) => ids(mergeContinue(
            resume: [ep('a1', 'A', played: playedAt, position: 5), ep('b1', 'B', played: daysAgo(1), position: 5)],
            nextUp: const [],
            dismissed: {'A': daysAgo(2)},
            now: now,
          ));
      expect(run(daysAgo(3)), ['b1']);
      expect(run(daysAgo(0.5)), ['a1', 'b1']);
    });

    test('continueKey: the series, else the item', () {
      expect(continueKey(ep('e', 'S')), 'S');
      expect(continueKey(movie('m')), 'm');
    });
  });

  group('Latest row', () {
    JellyfinItem added(String id, {String? series, String type = 'Episode', DateTime? aired, DateTime? at, int? n}) =>
        JellyfinItem(
          id: id,
          name: id,
          type: type,
          seriesId: series,
          seriesName: series == null ? null : 'Show $series',
          seriesPrimaryImageTag: series == null ? null : 'tag-$series',
          parentIndexNumber: series == null ? null : 1,
          indexNumber: n,
          premiereDate: aired,
          dateCreated: at,
        );

    test('re-releases: added more than 30 days after airing', () {
      expect(isReRelease(added('x', aired: daysAgo(400), at: daysAgo(1))), isTrue);
      expect(isReRelease(added('x', aired: daysAgo(20), at: daysAgo(1))), isFalse);
      expect(isReRelease(added('x', aired: null, at: daysAgo(1))), isFalse);
      expect(isReRelease(added('x', aired: daysAgo(400), at: null)), isFalse);
      // Added before it aired (pre-release): not a re-release.
      expect(isReRelease(added('x', aired: daysAgo(1), at: daysAgo(400))), isFalse);
    });

    test('episodes become series cards: one new shows S1E1, more show "N new"', () {
      final cards = latestCards([
        added('a2', series: 'A', n: 2, aired: daysAgo(1), at: daysAgo(0)),
        added('m', type: 'Movie', aired: daysAgo(3), at: daysAgo(1)),
        added('a1', series: 'A', n: 1, aired: daysAgo(8), at: daysAgo(1)),
        added('b1', series: 'B', n: 1, aired: daysAgo(2), at: daysAgo(2)),
      ]);
      expect([for (final c in cards) c.display.name], ['Show A', 'm', 'Show B']);
      expect([for (final c in cards) c.subtitle], ['2 new', anything, 'S1E1']);
      // Two new: the card is the series; one new: selecting it is the episode.
      expect(cards[0].item.id, 'A');
      expect(cards[0].item.kind, JellyfinItemKind.series);
      expect(cards[2].item.id, 'b1');
      expect(cards[2].display.image(JellyfinImageType.primary)!.itemId, 'B');
      expect(cards[2].display.image(JellyfinImageType.primary)!.tag, 'tag-B');
    });

    test('re-releases are left out when hidden, kept otherwise', () {
      final items = [
        added('new', series: 'A', n: 5, aired: daysAgo(1), at: daysAgo(0)),
        added('old1', series: 'R', n: 1, aired: daysAgo(3000), at: daysAgo(0)),
        added('old2', series: 'R', n: 2, aired: daysAgo(3000), at: daysAgo(0)),
      ];
      expect([for (final c in latestCards(items)) c.display.name], ['Show A']);
      expect([for (final c in latestCards(items, hideReReleases: false)) c.display.name], ['Show A', 'Show R']);
    });

    test('grouped series from the server keep their "N new"', () {
      const s = JellyfinItem(id: 's', name: 'Grouped', type: 'Series', isFolder: true, childCount: 4);
      expect(latestCards([s]).single.subtitle, '4 new');
    });
  });

  group('Link source', () {
    RecentLink link(String url, [int day = 1]) =>
        RecentLink(url: url, title: url, at: DateTime.utc(2026, 1, day));

    test('recent links: newest first, deduped, at most 12, round-trip', () {
      var list = <RecentLink>[];
      for (var i = 0; i < 15; i++) {
        list = pushRecentLink(list, link('https://x/$i'));
      }
      expect(list, hasLength(maxRecentLinks));
      expect(list.first.url, 'https://x/14');
      list = pushRecentLink(list, link('https://x/10', 9));
      expect(list.first.url, 'https://x/10');
      expect(list.where((l) => l.url == 'https://x/10'), hasLength(1));
      final back = decodeRecentLinks(encodeRecentLinks(list));
      expect([for (final l in back) l.url], [for (final l in list) l.url]);
      expect(back.first.at.isAtSameMomentAs(DateTime.utc(2026, 1, 9)), isTrue);
      expect(decodeRecentLinks('nope'), isEmpty);
      expect(decodeRecentLinks(jsonEncode([{'url': ''}, {'url': 'https://a/b.mkv'}])).single.title, 'b.mkv');
    });

    test('kept previews: playable ones only, display text, survive a reload', () async {
      String? disk;
      LinkPreviewStore store() => LinkPreviewStore(read: () async => disk, write: (v) async => disk = v);
      final a = store();
      await a.put('https://a', const LinkPreview(title: 'A', subtitle: 'a · Chan · 3:07', thumbnail: 'https://i/a.jpg'),
          at: DateTime.utc(2026, 1, 2));
      await a.put('https://b', const LinkPreview(title: 'B', subtitle: 'b', problem: 'Not found (404)'));
      expect(a.lookup('https://b'), isNull);
      final b = store();
      await b.ensureLoaded();
      final kept = b.lookup('https://a')!;
      expect((kept.preview.title, kept.preview.subtitle, kept.preview.thumbnail),
          ('A', 'a · Chan · 3:07', 'https://i/a.jpg'));
      expect(kept.at.isAtSameMomentAs(DateTime.utc(2026, 1, 2)), isTrue);
      // A problem later forgets it.
      await b.put('https://a', const LinkPreview(title: 'A', subtitle: 'a', problem: 'Not allowed (403)'));
      expect(b.lookup('https://a'), isNull);
    });

    test('preview: a page by yt-dlp, a file by its name, else why not', () async {
      final yt = await previewLink('https://www.youtube.com/watch?v=abc',
          probe: (url) async => LinkProbe.page(Uri.parse(url),
              info: const YtDlpInfo(
                  title: 'A video', uploader: 'Chan', duration: 187, thumbnail: 'https://i.ytimg/x.jpg')));
      expect((yt!.title, yt.subtitle, yt.thumbnail), ('A video', 'youtube.com · Chan · 3:07', 'https://i.ytimg/x.jpg'));

      final file = await previewLink('https://cdn.example/dir/My%20Movie.mkv?sig=1',
          probe: (url) async => LinkProbe.file(Uri.parse(url), 10));
      expect((file!.title, file.subtitle, file.thumbnail), ('My Movie.mkv', 'cdn.example', null));

      final page = await previewLink('https://example.com/a',
          probe: (url) async => LinkProbe.page(Uri.parse(url), pageTitle: 'Example', ytDlpError: 'Unsupported URL'));
      expect((page!.title, page.subtitle, page.problem),
          ('Example', 'example.com · Not a video page yt-dlp knows', 'Not a video page yt-dlp knows'));
      final refused = await previewLink('https://cdn.example/b.mp4',
          probe: (url) async => LinkProbe.page(Uri.parse(url), ytDlpError: 'odd', status: 403));
      expect((refused!.title, refused.problem), ('b.mp4', 'Not allowed (403)'));
      expect(await previewLink('not a link', probe: (url) async => throw StateError('no probe')), isNull);
    });

    test('ago text', () {
      final t = DateTime.utc(2026, 10, 8);
      expect(agoText(t.subtract(const Duration(hours: 3)), t), 'today');
      expect(agoText(t.subtract(const Duration(days: 1)), t), 'yesterday');
      expect(agoText(t.subtract(const Duration(days: 3)), t), '3 days ago');
      expect(agoText(t.subtract(const Duration(days: 9)), t), 'last week');
      expect(agoText(t.subtract(const Duration(days: 40)), t), '5 weeks ago');
    });
  });

  test('now playing file: only a plain file named like the last one put up', () {
    expect(nowPlayingFile({'name': 'b.mkv', 'size': 1}, '/v/b.mkv'), '/v/b.mkv');
    expect(nowPlayingFile({'name': 'b.mkv', 'url': 'http://x/b.mkv'}, '/v/b.mkv'), isNull);
    expect(nowPlayingFile({'name': 'b.mkv', 'jellyfin': {}}, '/v/b.mkv'), isNull);
    expect(nowPlayingFile({'name': 'c.mkv'}, '/v/b.mkv'), isNull);
    expect(nowPlayingFile(null, '/v/b.mkv'), isNull);
    expect(nowPlayingFile({'name': 'b.mkv'}, r'C:\v\b.mkv'), r'C:\v\b.mkv');
  });

  test('controller: a Jellyfin pick selects its card', () {
    final c = MediaPickerController();
    addTearDown(c.dispose);
    const m = JellyfinMedia(serverId: 's', baseUrl: 'b', itemId: 'i', title: 't');
    c.pickJellyfin(m);
    expect(c.source, MediaKind.jellyfin);
    expect(c.selected!.itemId, 'i');
    c.select(null);
    expect(c.selected, isNull);
    expect(c.jellyfin, m);
  });
}
