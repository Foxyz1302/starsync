import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/library/library_store.dart';
import 'package:starsync/src/library/show_matcher.dart';
import 'package:starsync/src/schedule/anilist.dart';
import 'package:starsync/src/schedule/animeflow.dart' show AniListRun;
import 'package:sync_relay_core/core.dart';

// L2: local shows (L1 over the Binux names) matched against a fake
// AniList: synonyms and season hints, numbering along split entries,
// pins and offsets that win, the cache answering offline, spaced requests.

const root = '/lib/Binux';
const b2 = '$root/[Judas] Bleach 056-111 [BD 1080p][HEVC x265 10bit]';
const b3 = '$root/[Judas] Bleach 112-139 [BD 1080p][HEVC x265 10bit][Dual-Audio][Eng-Subs]';
const sao = '$root/[Judas] Sword Art Online (Season 3 - Alicization) [BD 1080p][HEVC x265 10bit][Eng-Subs]';

const reS1 = 'Re:Zero kara Hajimeru Isekai Seikatsu';
const reEn = 'Re:ZERO -Starting Life in Another World-';

final entries = <AniListEntry>[
  const AniListEntry(id: 269, romaji: 'BLEACH', english: 'Bleach', format: 'TV', episodes: 366, year: 2004),
  const AniListEntry(
      id: 41467, romaji: 'BLEACH: Sennen Kessen-hen', english: 'Bleach: Thousand-Year Blood War', format: 'TV', episodes: 13),
  const AniListEntry(
      id: 21355, romaji: reS1, english: reEn, synonyms: ['Re:Zero', 'ReZero'], format: 'TV', episodes: 25, sequel: 108632),
  const AniListEntry(
      id: 108632, romaji: '$reS1 2nd Season', english: '$reEn Season 2', format: 'TV', episodes: 13, sequel: 119661),
  const AniListEntry(
      id: 119661, romaji: '$reS1 2nd Season Part 2', english: '$reEn Season 2 Part 2', format: 'TV', episodes: 12, sequel: 163134),
  const AniListEntry(
      id: 163134, romaji: '$reS1 3rd Season', english: '$reEn Season 3', format: 'TV', episodes: 16, sequel: 189046),
  const AniListEntry(id: 189046, romaji: '$reS1 4th Season', english: '$reEn Season 4', format: 'TV'),
  const AniListEntry(id: 11757, romaji: 'Sword Art Online', format: 'TV', episodes: 25, sequel: 20594),
  const AniListEntry(id: 20594, romaji: 'Sword Art Online II', format: 'TV', episodes: 24),
  const AniListEntry(
      id: 100182,
      romaji: 'Sword Art Online: Alicization',
      format: 'TV',
      episodes: 24,
      sequel: 108759,
      episodeTitles: {1: 'Underworld'}),
  const AniListEntry(
      id: 108759, romaji: 'Sword Art Online: Alicization - War of Underworld', format: 'TV', episodes: 12, sequel: 114308),
  const AniListEntry(
      id: 114308, romaji: 'Sword Art Online: Alicization - War of Underworld 2nd Season', format: 'TV', episodes: 11),
  const AniListEntry(
      id: 177937,
      romaji: 'Kimetsu no Yaiba: Mugen Jou-hen',
      english: 'Demon Slayer: Kimetsu no Yaiba Infinity Castle',
      format: 'MOVIE',
      episodes: 1),
  const AniListEntry(id: 101922, romaji: 'Kimetsu no Yaiba', english: 'Demon Slayer: Kimetsu no Yaiba', format: 'TV', episodes: 26),
];

/// Answers searches by shared words (AniList's own order roughly), and
/// ids from [entries]; counts the requests.
class FakeAniList implements AniListLookup {
  final searches = <String>[];
  final lookups = <int>[];
  bool offline = false;

  static Set<String> _words(String s) =>
      normalizeSeries(s).split(' ').where((w) => w.length > 1 && int.tryParse(w) == null && w != 'season').toSet();

  @override
  Future<List<AniListEntry>> searchAnime(String query) async {
    if (offline) throw const AniListException('AniList unreachable');
    searches.add(query);
    final q = _words(query);
    final scored = [
      for (final e in entries)
        (e, e.names.map((n) => _words(n).intersection(q).length).reduce((a, b) => a > b ? a : b)),
    ].where((p) => p.$2 > 0).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final p in scored.take(8)) p.$1];
  }

  @override
  Future<AniListEntry?> anime(int id) async {
    if (offline) throw const AniListException('AniList unreachable');
    lookups.add(id);
    return entries.where((e) => e.id == id).firstOrNull;
  }
}

class FakeFlow implements FlowLookup {
  final Map<int, FlowShow> shows;
  FakeFlow(this.shows);
  @override
  Future<FlowShow?> forAniList(int anilistId) async => shows[anilistId];
}

String three(int n) => n.toString().padLeft(3, '0');

LocalLibrary binux({List<String> extra = const []}) => groupLocal([
      for (final p in [
        for (final n in [56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 108, 109, 110, 111]) '$b2/[Judas] Bleach - ${three(n)}.mkv',
        for (var n = 112; n <= 139; n++) '$b3/[Judas] Bleach - ${three(n)}.mkv',
        for (var n = 1; n <= 24; n++) '$sao/[Judas] Sword Art Online S3 - ${n.toString().padLeft(2, '0')}.mkv',
        '$sao/[Judas] Sword Art Online S3 - Opening 1.mkv',
        '$root/[Judas] Re.Zero - S04E17.mkv',
        '$root/[Erai-raws] Kimetsu no Yaiba - Mugenjou Hen - Movie 01 [1080p CR WEBRip HEVC AAC][MultiSub][8E47462C].mkv',
        ...extra,
      ])
        LocalFile(p, 1 << 30, DateTime(2026)),
    ], roots: [root]);

void main() {
  late FakeAniList aniList;
  late MemoryLibraryStore store;
  late List<Duration> waits;

  ShowMatcher matcher({FlowLookup? flow, AniListLookup? api}) => ShowMatcher(
        store: store,
        aniList: api ?? aniList,
        flow: flow,
        delay: (d) async => waits.add(d),
      );

  Future<void> settle(ShowMatcher m) async {
    for (var i = 0; i < 200 && !m.idle; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
    expect(m.idle, isTrue);
  }

  Future<ShowMatcher> matched(LocalLibrary lib, {FlowLookup? flow}) async {
    final m = matcher(flow: flow)..remember(lib);
    for (final s in lib.shows) {
      m.want(s);
    }
    for (final mv in lib.movies) {
      m.wantMovie(mv);
    }
    await settle(m);
    return m;
  }

  LocalEpisode ep(LocalLibrary lib, String show, int n, {int? season}) =>
      lib.show(show)!.episodes.firstWhere((e) => e.episode == n && (season == null || e.season == season));

  setUp(() {
    aniList = FakeAniList();
    store = MemoryLibraryStore();
    waits = [];
  });

  test('each show and movie finds its AniList entry, names and numbers follow', () async {
    final lib = binux();
    final m = await matched(lib);

    // Bleach: one 366-episode entry, absolute numbers as is.
    final bleach = lib.show('bleach')!;
    expect(m.titleOf(bleach), 'Bleach');
    expect(m.refFor(ep(lib, 'bleach', 108)),
        const MediaRef(kind: 'episode', title: 'Bleach', anilistId: 269, anilistEp: 108, absolute: 108));

    // Re.Zero S04E17: the season hint finds the 4th season among the
    // synonyms and spellings ("Re.Zero" is "Re:ZERO -Starting Life…").
    final re = lib.show('re zero')!;
    expect(m.showMatch(re)!.entry.id, 189046);
    expect(m.titleOf(re), '$reEn Season 4');
    expect(m.refFor(re.episodes.single),
        MediaRef(kind: 'episode', title: '$reEn Season 4', anilistId: 189046, anilistEp: 17, season: 4, ep: 17));

    // SAO: the folder's "(Season 3 - Alicization)" names the entry; its
    // extras belong to it too; AniList's episode title shows.
    final s = lib.show('sword art online')!;
    expect(m.showMatch(s)!.entry.id, 100182);
    expect(m.target(ep(lib, 'sword art online', 13)), const EpisodeTarget(100182, 13));
    expect(m.episodeTitle(ep(lib, 'sword art online', 1)), 'Underworld');
    expect(m.refFor(s.extras.single), const MediaRef(kind: 'extra', title: 'Sword Art Online: Alicization', anilistId: 100182));

    // The movie is the movie entry, not the TV show.
    final movie = lib.movies.single;
    expect(m.seasonMatch(movie)!.entry.id, 177937);
    expect(m.refFor(movie).kind, 'movie');
  });

  test('past an entry\'s episodes the numbering goes on along its sequels (split cours)', () async {
    final lib = binux(extra: [
      '$sao/[Judas] Sword Art Online S3 - 25.mkv',
      '$sao/[Judas] Sword Art Online S3 - 38.mkv',
    ]);
    final m = await matched(lib);
    // 25 is War of Underworld 1 (before that entry is even fetched: its
    // id comes with Alicization), 38 its second part's 2.
    expect(m.target(ep(lib, 'sword art online', 25)), const EpisodeTarget(108759, 1));
    m.target(ep(lib, 'sword art online', 38));
    await settle(m);
    expect(m.target(ep(lib, 'sword art online', 38)), const EpisodeTarget(114308, 2));
    expect(aniList.lookups, containsAll([108759]));
  });

  test('AnimeFlow\'s anilist_map wins for numbered seasons and gives the TVDB id', () async {
    final lib = binux();
    final flow = FakeFlow({
      100182: const FlowShow([
        AniListRun(season: 3, anilistId: 100182, firstEpisode: 1, offset: 0),
        AniListRun(season: 3, anilistId: 108759, firstEpisode: 25, offset: 24),
      ], tvdbId: 259640),
    });
    final m = await matched(lib, flow: flow);
    await settle(m);
    final r = m.refFor(ep(lib, 'sword art online', 13));
    expect([r.anilistId, r.anilistEp, r.tvdbId, r.season, r.ep], [100182, 13, 259640, 3, 13]);
  });

  test('pins win over the match, per show and per folder, and survive a rescan', () async {
    final lib = binux();
    final m = await matched(lib);
    final tybw = entries.firstWhere((e) => e.id == 41467);
    final reZero = entries.firstWhere((e) => e.id == 21355);

    m.pinShow('bleach', tybw);
    expect(m.showMatch(lib.show('bleach')!)!.pinned, PinScope.show);
    expect(m.target(ep(lib, 'bleach', 60))!.anilistId, 41467);
    // A folder pin is more specific than the show's.
    m.pinFolder(b3, reZero);
    expect(m.target(ep(lib, 'bleach', 120))!.anilistId, isNot(41467));
    expect(m.seasonMatch(ep(lib, 'bleach', 120))!.pinned, PinScope.folder);
    expect(m.seasonMatch(ep(lib, 'bleach', 60))!.entry.id, 41467);

    // A rescan (a new library, a new run) over the same store: the pins
    // hold, with AniList out of reach.
    final again = binux();
    final m2 = matcher(api: FakeAniList()..offline = true)..remember(again);
    for (final s in again.shows) {
      m2.want(s);
    }
    await settle(m2);
    expect(m2.seasonMatch(ep(again, 'bleach', 60))!.entry.id, 41467);
    expect(m2.seasonMatch(ep(again, 'bleach', 120))!.entry.id, 21355);

    m2.unpinFolder(b3);
    m2.unpinShow('bleach');
    expect(m2.seasonMatch(ep(again, 'bleach', 120))!.entry.id, 269);
  });

  test('an episode offset: "these files are episodes N.."', () async {
    final lib = binux();
    final m = await matched(lib);
    // The Alicization files are really War of Underworld 1-24 here.
    m.setOffset('sword art online', 3, 24);
    final r = m.refFor(ep(lib, 'sword art online', 1));
    expect([r.ep, r.anilistId, r.anilistEp], [25, 108759, 1]);
    m.setOffset('sword art online', 3, 0);
    expect(m.refFor(ep(lib, 'sword art online', 1)).anilistEp, 1);
  });

  test('cached: one search per season, none again (offline too), requests spaced out', () async {
    final lib = binux();
    final m = await matched(lib);
    final asked = aniList.searches.length;
    expect(asked, greaterThanOrEqualTo(4));
    expect(waits.where((w) => w > Duration.zero), isNotEmpty, reason: 'spaced, not a burst');
    for (final s in lib.shows) {
      m.want(s);
    }
    await settle(m);
    expect(aniList.searches.length, asked);

    final offline = FakeAniList()..offline = true;
    final m2 = matcher(api: offline)..remember(lib);
    for (final s in lib.shows) {
      m2.want(s);
    }
    await settle(m2);
    expect(offline.searches, isEmpty);
    expect(m2.refFor(ep(lib, 'bleach', 108)), m.refFor(ep(lib, 'bleach', 108)));
    expect(m2.titleOf(lib.show('re zero')!), '$reEn Season 4');
  });

  test('before a match (or offline with nothing cached) a ref still says what L1 read', () async {
    final lib = binux();
    final m = matcher(api: FakeAniList()..offline = true)..remember(lib);
    m.want(lib.show('bleach')!);
    await settle(m);
    expect(m.refFor(ep(lib, 'bleach', 56)), const MediaRef(kind: 'episode', title: 'Bleach', absolute: 56));
    // A file never scanned: its name and folder alone.
    expect(m.refForPath('$sao/[Judas] Sword Art Online S3 - 07.mkv'),
        const MediaRef(kind: 'episode', title: 'Sword Art Online', season: 3, ep: 7));
  });

  test('the ref fits the wire: round-trips and stays under 2 KiB', () async {
    final long = 'A Very Long Light Novel Title ' * 12;
    final lib = groupLocal([LocalFile('$root/$long - 05.mkv', 1, DateTime(2026))], roots: [root]);
    final m = matcher(api: FakeAniList()..offline = true);
    final ref = m.refFor(lib.shows.single.episodes.single);
    final media = HelloMedia(name: 'x.mkv', size: 1, duration: 0, ref: ref);
    final json = jsonEncode(media.toJson());
    final back = HelloMedia.fromJson(jsonDecode(json) as Map<String, Object?>);
    expect(back.ref!.kind, 'episode');
    expect(back.ref!.absolute, 5);
    expect(utf8.encode(jsonEncode(ref.toJson())).length, lessThan(RelayConstants.maxMediaRefBytes));
    expect(back.ref!.title.length, lessThanOrEqualTo(200));
  });
}
