import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart' show JellyfinItem;
import 'package:starsync/src/schedule/anilist.dart';
import 'package:starsync/src/schedule/jellyfin_match.dart';
import 'package:starsync/src/schedule/schedule_model.dart';

final now = DateTime.utc(2026, 11, 8, 12);

Airing airing(
  int id,
  int ep,
  DateTime at, {
  String title = 'Show',
  String romaji = '',
  String native = '',
  List<String> synonyms = const [],
  int? mal,
}) =>
    Airing(
      anilistId: id,
      title: title,
      titleRomaji: romaji,
      titleNative: native,
      synonyms: synonyms,
      idMal: mal,
      episode: ep,
      airingAt: at,
    );

JellyfinSeriesInfo series(String id, String name,
        {String? original, int? year, Map<String, String> ids = const {}, String server = 'srv'}) =>
    JellyfinSeriesInfo(serverId: server, id: id, name: name, originalTitle: original, year: year, providerIds: ids);

/// Midnight of a Japan calendar day, as servers send premiere dates.
DateTime jstDay(int month, int day) => DateTime.utc(2026, month, day).subtract(const Duration(hours: 9));

/// 23:30 JST on that Japan day.
DateTime jstLate(int month, int day) => DateTime.utc(2026, month, day, 14, 30);

void main() {
  group('JellyfinSeriesMatcher', () {
    test('provider ids first: AniList, then MyAnimeList (any case)', () {
      final m = JellyfinSeriesMatcher([
        series('a', 'Something Else', ids: {'AniList': '161645'}),
        series('b', 'Another', ids: {'MyAnimeList': '54492'}),
        series('c', 'The Apothecary Diaries'),
      ]);
      final byAni = m.match(airing(161645, 1, now, title: 'The Apothecary Diaries'))!;
      expect((byAni.series.id, byAni.kind), ('a', SeriesMatchKind.providerId));
      final byMal = m.match(airing(1, 1, now, title: 'The Apothecary Diaries', mal: 54492))!;
      expect((byMal.series.id, byMal.kind), ('b', SeriesMatchKind.providerId));
      expect(JellyfinSeriesMatcher([series('d', 'X', ids: {'mal': '7'})]).match(airing(2, 1, now, mal: 7))?.series.id,
          'd');
    });

    test('the same name: any of English, romaji, native or a synonym', () {
      final m = JellyfinSeriesMatcher([
        series('a', 'Nia Liston: The Merciless Maiden'),
        series('b', 'Overgeared', original: 'テムパル～アイテムの力～'),
        series('c', 'Totally Different', original: 'Sousou no Frieren'),
      ]);
      expect(m.match(airing(1, 1, now, title: 'Nia Liston - The Merciless Maiden'))?.series.id, 'a',
          reason: 'punctuation does not count');
      expect(m.match(airing(2, 1, now, title: 'X', native: 'テムパル～アイテムの力～'))?.series.id, 'b');
      expect(m.match(airing(3, 1, now, title: 'X', synonyms: ['Sousou no Frieren']))?.series.id, 'c');
      expect(m.match(airing(4, 1, now, title: 'Nothing here')), isNull);
    });

    test('a series that started after the airing is not it', () {
      final m = JellyfinSeriesMatcher([series('later', 'Rayearth', year: 2027), series('old', 'Rayearth', year: 1994)]);
      expect(m.match(airing(1, 1, now, title: 'Rayearth'))?.series.id, 'old');
    });

    test('a season of the show: its name starts the entry\'s, before a season word or in two names', () {
      final m = JellyfinSeriesMatcher([
        series('apo', 'The Apothecary Diaries', original: '薬屋のひとりごと'),
        series('sword', 'Reincarnated as a Sword', original: '転生したら剣でした'),
        series('yoza', 'Mission: Yozakura Family'),
        series('jojo', "JoJo's Bizarre Adventure"),
      ]);
      // Two names agree.
      final apo = m.match(airing(1, 5, now,
          title: 'The Apothecary Diaries Season 3', romaji: 'Kusuriya no Hitorigoto 3rd Season', native: '薬屋のひとりごと 第3期'))!;
      expect((apo.series.id, apo.kind), ('apo', SeriesMatchKind.title));
      // One name, a season word after it.
      expect(m.match(airing(2, 5, now, title: 'Reincarnated as a Sword Season 2'))?.kind, SeriesMatchKind.title);
      expect(m.match(airing(3, 4, now, title: 'Mission: Yozakura Family Season 2 Part 2'))?.kind,
          SeriesMatchKind.title);
      // One name and anything else: weak (an air day must confirm it).
      final jojo = m.match(airing(4, 6, now, title: "STEEL BALL RUN JoJo's Bizarre Adventure",
          romaji: "JoJo's Bizarre Adventure: Steel Ball Run 2nd & 3rd Stage"))!;
      expect((jojo.series.id, jojo.kind), ('jojo', SeriesMatchKind.weakTitle));
    });

    test('a synonym never starts a prefix match; a word inside a name is no match', () {
      final m = JellyfinSeriesMatcher([series('m', 'Monster')]);
      expect(m.match(airing(1, 1, now, title: 'Doctor of Monsters', synonyms: ['Monster Doctor Season 2'])), isNull);
      expect(m.match(airing(2, 1, now, title: 'My Monster Season 2')), isNull);
    });

    test('a surer match beats a closer weak one; the preferred account wins a tie', () {
      final m = JellyfinSeriesMatcher([
        series('mine', 'Black Clover', server: 'mine'),
        series('friend', 'Black Clover', server: 'friend'),
      ]);
      expect(m.match(airing(1, 1, now, title: 'Black Clover'))?.series.serverId, 'mine');
    });

    test('from a Jellyfin item', () {
      final s = JellyfinSeriesInfo.fromItem(
          'srv',
          JellyfinItem.fromJson({
            'Id': 'x',
            'Name': 'Frieren',
            'OriginalTitle': '葬送のフリーレン',
            'ProductionYear': 2023,
            'Type': 'Series',
            'ProviderIds': {'Tvdb': '424536'},
          }));
      expect((s.serverId, s.id, s.name, s.originalTitle, s.year), ('srv', 'x', 'Frieren', '葬送のフリーレン', 2023));
      expect(s.providerIds, {'Tvdb': '424536'});
    });
  });

  test('seasonHintOf: the season word of any main name', () {
    expect(seasonHintOf(airing(1, 1, now, title: 'The Apothecary Diaries Season 3')), 3);
    expect(seasonHintOf(airing(1, 1, now, title: 'X', romaji: 'Sousou no Frieren 2nd Season')), 2);
    expect(seasonHintOf(airing(1, 1, now, title: 'X', native: '転生したら剣でした 第2期')), 2);
    expect(seasonHintOf(airing(1, 1, now, title: 'Overgeared')), isNull);
  });

  group('placeRun', () {
    test("an episode premiered on the airing's Japan day anchors season and offset (split cour)", () {
      // Part 2 of a cour AniList splits: its episode 1 is TVDB S2E13.
      final p = placeRun(
        [airing(1, 1, jstLate(10, 30)), airing(1, 2, jstLate(11, 6)), airing(1, 3, jstLate(11, 13))],
        [
          JellyfinEpisodeRef(2, 12, premiere: jstDay(10, 23)),
          JellyfinEpisodeRef(2, 13, premiere: jstDay(10, 30)),
          JellyfinEpisodeRef(2, 14, premiere: jstDay(11, 6)),
        ],
        now: now,
      );
      expect(p, const RunPlacement(2, 12, anchored: true));
    });

    test('a late-night slot matches the day before; midnight UTC dates match too', () {
      // 01:30 JST on Nov 7, listed on Nov 6.
      final p = placeRun(
        [airing(1, 5, DateTime.utc(2026, 11, 6, 16, 30))],
        [JellyfinEpisodeRef(1, 4, premiere: DateTime.utc(2026, 11, 6))],
        now: now,
      );
      expect(p, const RunPlacement(1, -1, anchored: true));
    });

    test('unknown dates (none, 1970): the season word, else the latest season, offset 0', () {
      final have = [
        JellyfinEpisodeRef(1, 5, premiere: DateTime.utc(1970)),
        const JellyfinEpisodeRef(2, 5),
        const JellyfinEpisodeRef(0, 1),
      ];
      final aired = [airing(1, 5, jstLate(11, 1))];
      expect(placeRun(aired, have, now: now), const RunPlacement(2, 0));
      expect(placeRun(aired, have, now: now, seasonHint: 3), const RunPlacement(3, 0));
      expect(placeRun(aired, const [], now: now), const RunPlacement(1, 0));
    });

    test('two episodes the same day decide nothing; upcoming airings never vote', () {
      final p = placeRun(
        [airing(1, 1, jstLate(11, 1)), airing(1, 2, jstLate(11, 15))],
        [
          JellyfinEpisodeRef(1, 1, premiere: jstDay(11, 1)),
          JellyfinEpisodeRef(1, 2, premiere: jstDay(11, 1)),
          JellyfinEpisodeRef(3, 9, premiere: jstDay(11, 15)),
        ],
        now: now,
      );
      expect(p.anchored, isFalse);
    });
  });

  group('matchDirect', () {
    final m = JellyfinSeriesMatcher([
      series('sum', "I'm Dating a Dark Summoner"),
      series('jojo', "JoJo's Bizarre Adventure"),
      series('cat', 'Chainsmoker Cat'),
      series('new', 'Brand New Show'),
    ]);
    final eps = {
      'sum': [JellyfinEpisodeRef(1, 5, premiere: jstDay(11, 2))],
      'jojo': [JellyfinEpisodeRef(6, 7, premiere: jstDay(11, 3))],
      'cat': [JellyfinEpisodeRef(1, 9, premiere: jstDay(10, 1))],
    };
    final asked = <String>[];
    Future<List<JellyfinEpisodeRef>?> lookup(String? server, String id) async {
      asked.add('$server|$id');
      return eps[id];
    }

    test('places sure matches, keeps a weak one only once an air day anchors it', () async {
      asked.clear();
      final out = await matchDirect(
        [
          airing(10, 5, jstLate(11, 2), title: "I'm Dating a Dark Summoner"),
          // The show's shorts, aired the same day: weak, and on its episode.
          airing(11, 5, jstLate(11, 2), title: "I'm Dating a Dark Summoner Omake Shorts"),
          // Weak, anchored: STEEL BALL RUN ep 6 is TVDB S6E7.
          airing(20, 6, jstLate(11, 3), title: "JoJo's Bizarre Adventure: Steel Ball Run"),
          // Weak, no air day: dropped.
          airing(30, 2, jstLate(11, 4), title: 'Chainsmoker Cat Minis'),
          // Sure, nothing aired yet: matched, not placed, not looked up.
          airing(40, 1, now.add(const Duration(days: 2)), title: 'Brand New Show'),
          airing(50, 1, jstLate(11, 4), title: 'Unknown'),
        ],
        m,
        episodes: lookup,
        now: now,
      );
      expect(out.keys, unorderedEquals([10, 20, 40]));
      expect(out[10]!.placement, const RunPlacement(1, 0, anchored: true));
      expect(out[20]!.placement, const RunPlacement(6, 1, anchored: true));
      expect(out[40]!.placement, isNull);
      expect(asked, unorderedEquals(['srv|sum', 'srv|jojo', 'srv|cat']));
    });

    test('a failed lookup: a sure match stays unplaced, a weak one goes', () async {
      final out = await matchDirect(
        [
          airing(10, 5, jstLate(11, 2), title: "I'm Dating a Dark Summoner"),
          airing(20, 6, jstLate(11, 3), title: "JoJo's Bizarre Adventure: Steel Ball Run"),
        ],
        m,
        episodes: (server, id) async => throw Exception('down'),
        now: now,
      );
      expect(out.keys, [10]);
      expect(out[10]!.placement, isNull);
    });
  });

  group('SeriesIndexCache', () {
    test('one walk per account, kept for its ttl, the last kept when a walk fails', () async {
      var t = now;
      final walks = <String>[];
      var fail = false;
      final cache = SeriesIndexCache(
        servers: () async => ['a', 'b'],
        walk: (id) async {
          walks.add(id);
          if (fail) throw Exception('down');
          return [series('$id-1', 'Show $id', server: id)];
        },
        now: () => t,
      );
      final first = await cache.series();
      expect(first.map((s) => s.id), ['a-1', 'b-1']);
      expect(walks, ['a', 'b']);
      expect(identical(await cache.series(), first), isTrue, reason: 'kept, the same list');
      expect(walks, hasLength(2));
      // Past the ttl: the kept one at once, walked again behind it.
      t = t.add(const Duration(minutes: 31));
      fail = true;
      expect((await cache.series()).map((s) => s.id), ['a-1', 'b-1'], reason: 'the last one stays');
      expect(walks, hasLength(4));
      await pumpEventQueue();
      await cache.series();
      expect(walks, hasLength(4), reason: 'a failed walk waits before trying again');
      fail = false;
      t = t.add(const Duration(minutes: 6));
      await cache.series();
      expect(walks, hasLength(6));
      await pumpEventQueue();
      await cache.series(force: true);
      expect(walks, hasLength(8));
    });
  });
}
