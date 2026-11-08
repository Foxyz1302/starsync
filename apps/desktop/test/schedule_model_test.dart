import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/schedule/anilist.dart';
import 'package:starsync/src/schedule/animeflow.dart';
import 'package:starsync/src/schedule/jellyfin_match.dart';
import 'package:starsync/src/schedule/schedule_model.dart';
import 'package:starsync/src/schedule/schedule_store.dart';

import 'schedule_fake_server.dart';

// Local times, so the "same local air day" rule is timezone-proof.
final now = DateTime(2026, 10, 8, 12);

Airing airing(int id, int ep, DateTime local) => Airing(
      anilistId: id,
      title: 'Show $id',
      titleRomaji: 'Show $id',
      episode: ep,
      airingAt: local.toUtc(),
    );

AnimeFlowScheduleItem item(int? anilistId, int ep, EpisodeStatus status,
        {int season = 1, int? absolute, DateTime? air, int seriesId = 7,
        double? progress, String? reason}) =>
    AnimeFlowScheduleItem(
      episode: AnimeFlowEpisode(
        season: season,
        episode: ep,
        absolute: absolute,
        airDate: air?.toUtc(),
        anilistId: anilistId,
        status: status,
        progress: progress,
        reason: reason,
      ),
      seriesId: seriesId,
      title: 'Show',
      jellyfinSeriesId: 'jf$seriesId',
    );

void main() {
  group('matchSchedule', () {
    test('shows on Jellyfin but not in AnimeFlow come from /library', () {
      final out = matchSchedule(
        [
          airing(172192, 1, DateTime(2026, 10, 6, 18)), // aired
          airing(172192, 2, DateTime(2026, 10, 13, 18)), // upcoming
          airing(999, 1, DateTime(2026, 10, 6, 18)), // nowhere
        ],
        schedule: const [],
        library: const [
          AnimeFlowLibraryItem(jellyfinSeriesId: 'jfR', name: 'Returner', anilistIds: {1: 163142, 2: 172192}),
        ],
        now: now,
      );
      expect(out.map((e) => e.status),
          [ScheduleStatus.inLibrary, ScheduleStatus.upcoming, ScheduleStatus.notTracked]);
      expect(out[0].jellyfinSeriesId, 'jfR');
      expect(out[0].season, 2, reason: 'the TVDB season of that AniList entry');
      expect(out[0].tracked, isFalse);
      expect(out[1].onJellyfin, isTrue);
      expect(out[2].onJellyfin, isFalse);
    });

    test('anilist_map: a season split into two AniList entries is on Jellyfin', () {
      final item = AnimeFlowLibraryItem.fromJson({
        'jellyfin_series_id': 'jfJ',
        'name': 'JoJo',
        'anilist_ids': {'6': 190327},
        'anilist_map': [
          {'season': 6, 'anilist_id': 190327, 'first_episode': 1, 'offset': 0},
          {'season': 6, 'anilist_id': 210482, 'first_episode': 2, 'offset': 1},
        ],
      });
      final out = matchSchedule([airing(210482, 3, DateTime(2026, 10, 6, 18))],
          schedule: const [], library: [item], now: now);
      expect(out.single.status, ScheduleStatus.inLibrary);
      expect(out.single.jellyfinSeriesId, 'jfJ');
      expect(out.single.season, 6);
    });

    test('confirmOnJellyfin: the episode (with the run offset) must be on Jellyfin', () {
      final lib = AnimeFlowLibraryItem.fromJson({
        'jellyfin_series_id': 'jfJ',
        'name': 'JoJo',
        'anilist_map': [
          {'season': 6, 'anilist_id': 210482, 'first_episode': 13, 'offset': 12},
        ],
      });
      final matched = matchSchedule(
        [
          airing(210482, 1, DateTime(2026, 10, 1, 18)), // S6E13: there
          airing(210482, 2, DateTime(2026, 10, 8, 11)), // S6E14: not yet
          airing(172192, 3, DateTime(2026, 10, 6, 18)), // series not looked up
        ],
        schedule: const [],
        library: [
          lib,
          const AnimeFlowLibraryItem(jellyfinSeriesId: 'jfR', name: 'Returner', anilistIds: {2: 172192}),
        ],
        now: now,
      );
      expect(matched.map((e) => e.jellyfinEpisode), [13, 14, 3]);
      final out = confirmOnJellyfin(matched, {
        'jfJ': const [
          JellyfinEpisodeRef(6, 12),
          JellyfinEpisodeRef(6, 13, watch: EpisodeWatch(progress: 0.4)),
          JellyfinEpisodeRef(1, 14),
        ],
      });
      expect(out.map((e) => e.status),
          [ScheduleStatus.inLibrary, ScheduleStatus.notOnJellyfin, ScheduleStatus.aired]);
      expect(out[1].jellyfinSeriesId, 'jfJ');
      expect(out.map((e) => e.watch), [const EpisodeWatch(progress: 0.4), null, null]);
    });

    test("confirmOnJellyfin: AnimeFlow's available episodes get this user's watched state", () {
      final matched = matchSchedule(
        [
          airing(100, 3, DateTime(2026, 10, 1, 18)), // S1E3 by number
          airing(100, 4, DateTime.utc(2026, 10, 7, 14)), // numbering misses: premiere day
          airing(200, 1, DateTime(2026, 10, 1, 18)), // series not looked up
        ],
        schedule: [
          item(100, 3, EpisodeStatus.available),
          item(100, 40, EpisodeStatus.available, absolute: 4),
          item(200, 1, EpisodeStatus.available),
        ],
        now: now,
      );
      expect(matched.map((e) => e.jellyfinEpisode), [3, 40, 1]);
      final out = confirmOnJellyfin(matched, {
        'jf7': [
          const JellyfinEpisodeRef(1, 3, watch: EpisodeWatch(played: true)),
          // Midnight JST of Oct 7.
          JellyfinEpisodeRef(1, 4, premiere: DateTime.utc(2026, 10, 6, 15), watch: const EpisodeWatch(progress: 0.5)),
        ],
      });
      expect(out.map((e) => e.status), everyElement(ScheduleStatus.available));
      expect(out.map((e) => e.watch),
          [const EpisodeWatch(played: true), const EpisodeWatch(progress: 0.5), null]);
    });

    test("AnimeFlow's anilist_episode wins over TVDB numbering (split cour)", () {
      // S2E13 in TVDB is part 2 (AniList 300) episode 1.
      final out = matchSchedule(
        [airing(300, 1, DateTime(2026, 10, 7, 20))],
        schedule: [
          AnimeFlowScheduleItem(
            episode: const AnimeFlowEpisode(
                season: 2, episode: 13, anilistId: 300, anilistEpisode: 1, status: EpisodeStatus.available),
            seriesId: 7,
            title: 'Show',
            jellyfinSeriesId: 'jf7',
          ),
        ],
        now: now,
      );
      expect(out.single.status, ScheduleStatus.available);
      expect(out.single.season, 2);
    });

    test('a TVDB number never claims another AniList episode (JoJo S6E4 = 2nd STAGE ep 3)', () {
      AnimeFlowScheduleItem row(int tvdbEp, int aniEp, EpisodeStatus st) => AnimeFlowScheduleItem(
            episode: AnimeFlowEpisode(season: 6, episode: tvdbEp, anilistId: 210482, anilistEpisode: aniEp, status: st),
            seriesId: 40,
            title: 'JoJo',
            jellyfinSeriesId: 'jfJ',
          );
      final out = matchSchedule(
        [airing(210482, 3, DateTime(2026, 10, 9, 11)), airing(210482, 4, DateTime(2026, 10, 16, 11))],
        schedule: [row(4, 3, EpisodeStatus.available), row(5, 4, EpisodeStatus.upcoming)],
        now: now,
      );
      expect(out.map((e) => e.status), [ScheduleStatus.available, ScheduleStatus.upcoming]);
    });

    test('by AniList id + episode, per season ids', () {
      // One AnimeFlow series (7) spans two AniList entries: S1 = 100, S2 = 200.
      final out = matchSchedule(
        [airing(100, 3, DateTime(2026, 10, 1, 20)), airing(200, 3, DateTime(2026, 10, 9, 20))],
        schedule: [
          item(100, 3, EpisodeStatus.available, season: 1),
          item(200, 3, EpisodeStatus.downloading, season: 2, progress: 0.4),
        ],
        series: [const AnimeFlowSeries(seriesId: 7, title: 'Show', anilistId: 100, jellyfinSeriesId: 'jf7')],
        now: now,
      );
      expect(out.map((e) => e.status), [ScheduleStatus.available, ScheduleStatus.downloading]);
      expect(out.map((e) => e.season), [1, 2]);
      expect(out[1].progress, 0.4);
      expect(out.every((e) => e.tracked && e.seriesId == 7 && e.jellyfinSeriesId == 'jf7'), isTrue);
    });

    test('episode numbers do not cross AniList ids', () {
      final out = matchSchedule(
        [airing(200, 1, DateTime(2026, 10, 2, 20))],
        schedule: [item(100, 1, EpisodeStatus.available)],
        now: now,
      );
      expect(out.single.status, ScheduleStatus.notTracked);
      expect(out.single.tracked, isFalse);
    });

    test('absolute number, then the same Japan air day', () {
      final out = matchSchedule(
        [
          airing(300, 1100, DateTime(2026, 10, 5, 9)), // AniList counts absolute
          // Numbering differs; Oct 6 23:30 JST, the evening before in
          // Europe and America.
          airing(400, 13, DateTime.utc(2026, 10, 6, 14, 30)),
          // Oct 8 01:30 JST, a late-night slot listed on Oct 7.
          airing(401, 13, DateTime.utc(2026, 10, 7, 16, 30)),
        ],
        schedule: [
          item(300, 5, EpisodeStatus.available, season: 22, absolute: 1100),
          // Air dates are midnight JST (Oct 6, 15:00 UTC the day before)...
          item(400, 1, EpisodeStatus.failed, season: 2, air: DateTime.utc(2026, 10, 5, 15), reason: 'No release'),
          // ... or midnight UTC from older servers.
          item(401, 1, EpisodeStatus.available, air: DateTime.utc(2026, 10, 7)),
        ],
        now: now,
      );
      expect(out[0].status, ScheduleStatus.available);
      expect(out[0].season, 22);
      expect(out[1].status, ScheduleStatus.failed);
      expect(out[1].reason, 'No release');
      expect(out[2].status, ScheduleStatus.available);
    });

    test('a different Japan day does not match', () {
      final out = matchSchedule(
        // Oct 7 20:00 JST; the air date is Oct 6 (midnight JST).
        [airing(400, 13, DateTime.utc(2026, 10, 7, 11))],
        schedule: [item(400, 1, EpisodeStatus.available, air: DateTime.utc(2026, 10, 5, 15))],
        now: now,
      );
      // Tracked (the id is in the schedule) but unmatched and aired.
      expect(out.single.status, ScheduleStatus.missing);
      expect(out.single.tracked, isTrue);
    });

    test('tracked but unmatched: missing once aired, upcoming before', () {
      final out = matchSchedule(
        [airing(500, 2, DateTime(2026, 10, 7, 20)), airing(500, 3, DateTime(2026, 10, 14, 20))],
        schedule: const [],
        series: [const AnimeFlowSeries(seriesId: 9, title: 'S', anilistId: 500)],
        now: now,
      );
      expect(out.map((e) => e.status), [ScheduleStatus.missing, ScheduleStatus.upcoming]);
      expect(out.every((e) => e.seriesId == 9), isTrue);
    });

    group("the app's own match (no AnimeFlow needed)", () {
      DirectMatch on(String id, {RunPlacement? at, SeriesMatchKind kind = SeriesMatchKind.title}) => DirectMatch(
          JellyfinSeriesMatch(JellyfinSeriesInfo(serverId: 'mine', id: id, name: 'S'), kind), at);

      test('without AnimeFlow: on Jellyfin, not there yet, watched; the rest just aired', () {
        final matched = matchSchedule(
          [
            airing(10, 5, DateTime(2026, 10, 1, 18)), // S2E17: there, watched
            airing(10, 6, DateTime(2026, 10, 8, 11)), // S2E18: not yet
            airing(10, 7, DateTime(2026, 10, 15, 11)), // upcoming
            airing(20, 1, DateTime(2026, 10, 6, 18)), // series known, not placed
            airing(30, 1, DateTime(2026, 10, 6, 18)), // on no Jellyfin
            airing(30, 2, DateTime(2026, 10, 13, 18)),
          ],
          schedule: const [],
          direct: {10: on('jfA', at: const RunPlacement(2, 12, anchored: true)), 20: on('jfB')},
          animeFlow: false,
          now: now,
        );
        expect(matched.map((e) => e.status), [
          ScheduleStatus.inLibrary,
          ScheduleStatus.inLibrary,
          ScheduleStatus.upcoming,
          ScheduleStatus.inLibrary,
          ScheduleStatus.aired,
          ScheduleStatus.upcoming,
        ]);
        expect(matched.map((e) => e.jellyfinEpisode), [17, 18, 19, null, null, null]);
        expect(matched.first.season, 2);
        expect(matched.first.jellyfinServerId, 'mine');
        expect(matched.first.jellyfinKey, 'mine|jfA');
        expect(matched.take(4).every((e) => e.onJellyfin && !e.tracked), isTrue);
        final out = confirmOnJellyfin(matched, {
          'mine|jfA': const [JellyfinEpisodeRef(2, 17, watch: EpisodeWatch(played: true))],
          'mine|jfB': const [JellyfinEpisodeRef(1, 1)],
        });
        expect(out.map((e) => e.status), [
          ScheduleStatus.inLibrary,
          ScheduleStatus.notOnJellyfin,
          ScheduleStatus.upcoming,
          ScheduleStatus.notOnJellyfin, // not placed: not known to be there
          ScheduleStatus.aired,
          ScheduleStatus.upcoming,
        ]);
        expect(out.first.watch, const EpisodeWatch(played: true));
      });

      test('a guessed number premiered weeks away is another episode', () {
        final matched = matchSchedule(
          [airing(10, 3, DateTime.utc(2026, 10, 1, 14, 30)), airing(11, 3, DateTime.utc(2026, 10, 1, 14, 30))],
          schedule: const [],
          direct: {10: on('jfA', at: const RunPlacement(1, 0)), 11: on('jfB', at: const RunPlacement(1, 0))},
          animeFlow: false,
          now: now,
        );
        expect(matched.every((e) => e.numberGuessed), isTrue);
        final out = confirmOnJellyfin(matched, {
          // Last season's S1E3, months ago.
          'mine|jfA': [JellyfinEpisodeRef(1, 3, premiere: DateTime.utc(2026, 4, 15))],
          // A day off (listings disagree): it.
          'mine|jfB': [JellyfinEpisodeRef(1, 3, premiere: DateTime.utc(2026, 10, 2, 15))],
        });
        expect(out.map((e) => e.status), [ScheduleStatus.notOnJellyfin, ScheduleStatus.inLibrary]);
        // Unknown (1970): it.
        final unknown = confirmOnJellyfin(matched, {
          'mine|jfA': [JellyfinEpisodeRef(1, 3, premiere: DateTime.utc(1970))],
        });
        expect(unknown.first.status, ScheduleStatus.inLibrary);
      });

      test("with AnimeFlow: one status per episode, AnimeFlow's when it has one", () {
        final out = matchSchedule(
          [
            airing(100, 3, DateTime(2026, 10, 1, 18)), // AnimeFlow row
            airing(200, 1, DateTime(2026, 10, 1, 18)), // AnimeFlow's /library
            airing(300, 1, DateTime(2026, 10, 1, 18)), // tracked, no Jellyfin id: ours fills it
            airing(400, 1, DateTime(2026, 10, 1, 18)), // only ours
            airing(500, 1, DateTime(2026, 10, 1, 18)), // nowhere: AnimeFlow does not track it
          ],
          schedule: [item(100, 3, EpisodeStatus.downloading, progress: 0.5)],
          series: [const AnimeFlowSeries(seriesId: 3, title: 'T', anilistId: 300)],
          library: const [AnimeFlowLibraryItem(jellyfinSeriesId: 'jfLib', name: 'L', anilistIds: {4: 200})],
          direct: {
            100: on('jfOurs100'),
            200: on('jfOurs200', at: const RunPlacement(1, 0, anchored: true)),
            300: on('jfOurs300'),
            400: on('jfOurs400', at: const RunPlacement(1, 0, anchored: true)),
          },
          now: now,
        );
        expect(out, hasLength(5));
        expect(out.map((e) => e.status), [
          ScheduleStatus.downloading,
          ScheduleStatus.inLibrary,
          ScheduleStatus.missing,
          ScheduleStatus.inLibrary,
          ScheduleStatus.notTracked,
        ]);
        expect(out.map((e) => e.jellyfinSeriesId), ['jf7', 'jfLib', 'jfOurs300', 'jfOurs400', null]);
        expect(out.map((e) => e.jellyfinServerId), [null, null, 'mine', 'mine', null]);
        expect(out[1].season, 4, reason: "AnimeFlow's run, not ours");
      });
    });

    test('progress only while downloading, reason only when failed', () {
      final out = matchSchedule(
        [airing(600, 1, DateTime(2026, 10, 1, 20))],
        schedule: [item(600, 1, EpisodeStatus.available, progress: 1, reason: 'x')],
        now: now,
      );
      expect(out.single.progress, isNull);
      expect(out.single.reason, isNull);
    });
  });

  test('defaultWindow: last week Monday, 28 days', () {
    final w = ScheduleRepository.defaultWindow(DateTime(2026, 10, 8, 15)); // Thursday
    expect(w.from, DateTime(2026, 9, 28));
    expect(w.to, DateTime(2026, 10, 26));
    final mon = ScheduleRepository.defaultWindow(DateTime(2026, 10, 5, 1));
    expect(mon.from, DateTime(2026, 9, 28));
  });

  group('ScheduleRepository', () {
    late FakeServer server;
    late Directory cache;
    var aniDown = false;
    var flowStatus = 200;
    final at = DateTime(2026, 10, 1, 20).toUtc();

    setUp(() async {
      aniDown = false;
      flowStatus = 200;
      cache = await Directory.systemTemp.createTemp('schedule-repo-test');
      server = await FakeServer.start((req, res) async {
        if (req.uri.path == '/anilist') {
          if (aniDown) return json(res, {'errors': [{'message': 'down'}]}, status: 500);
          return json(res, {
            'data': {
              'Page': {
                'pageInfo': {'hasNextPage': false},
                'airingSchedules': [
                  for (final (id, ep, t) in [(100, 3, at), (900, 1, at.add(const Duration(days: 20))), (901, 1, at)])
                    {
                      'airingAt': t.millisecondsSinceEpoch ~/ 1000,
                      'episode': ep,
                      'media': {'id': id, 'title': {'romaji': 'R$id'}, 'isAdult': false, 'format': 'TV'},
                    },
                ],
              },
            },
          });
        }
        if (flowStatus != 200) {
          if (flowStatus == 401) return json(res, {'detail': 'Invalid token', 'code': 'bad_token'}, status: 401);
          return json(res, {'detail': 'Jellyfin is down', 'code': 'jellyfin_unreachable'}, status: flowStatus);
        }
        switch (req.uri.path) {
          case '/flow/me':
            return json(res, {'user_id': 'u', 'name': 'Me', 'scopes': ['view']});
          case '/flow/schedule':
            return json(res, {
              'items': [
                {'season': 1, 'episode': 3, 'anilist_id': 100, 'status': 'available', 'series_id': 7,
                  'title': 'Show'},
              ],
            });
          case '/flow/series':
            return json(res, {'items': []});
        }
      });
    });

    tearDown(() async {
      await server.close();
      await cache.delete(recursive: true);
    });

    ScheduleRepository repo({bool flow = true}) => ScheduleRepository(
          aniList: AniListClient(url: '${server.url}/anilist', cacheDir: () async => cache, now: () => now),
          animeFlow: flow ? AnimeFlowClient(baseUrl: '${server.url}/flow', token: 'tok', now: () => now) : null,
          now: () => now,
        );

    test('both ok: merged, sorted', () async {
      final s = await repo().load();
      expect(s.aniListError, isNull);
      expect(s.animeFlowError, isNull);
      expect(s.me?.name, 'Me');
      expect(s.entries.map((e) => (e.airing.anilistId, e.status)), [
        (100, ScheduleStatus.available),
        (901, ScheduleStatus.notTracked),
        (900, ScheduleStatus.notTracked),
      ]);
      final aniReq = server.seen.firstWhere((r) => r.uri.path == '/anilist');
      final vars = (jsonDecode(aniReq.body) as Map)['variables'] as Map;
      expect(vars['from'], DateTime(2026, 9, 28).millisecondsSinceEpoch ~/ 1000 - 1);
      final sched = server.seen.firstWhere((r) => r.uri.path == '/flow/schedule');
      expect(sched.uri.queryParameters['from'], animeFlowTime(DateTime(2026, 9, 28)));
    });

    test('AnimeFlow failing: AniList-only statuses and an error', () async {
      flowStatus = 503;
      final s = await repo().load();
      expect(s.animeFlowException?.code, AnimeFlowErrorCode.jellyfinUnreachable);
      expect(s.animeFlowError, contains('Jellyfin is down'));
      expect(s.me, isNull);
      expect(s.entries.map((e) => (e.airing.anilistId, e.status, e.tracked)), [
        (100, ScheduleStatus.aired, false),
        (901, ScheduleStatus.aired, false),
        (900, ScheduleStatus.upcoming, false),
      ]);
    });

    test('no account AnimeFlow takes (none linked, or only another Jellyfin): nothing said, kept', () async {
      flowStatus = 401;
      for (final c in [
        AnimeFlowClient(baseUrl: '${server.url}/flow', now: () => now),
        AnimeFlowClient(
          baseUrl: '${server.url}/flow',
          tokenCandidates: () async => ['their-own-jellyfin'],
          homeAccount: () async => false,
          now: () => now,
        ),
      ]) {
        final r = ScheduleRepository(
          aniList: AniListClient(url: '${server.url}/anilist', cacheDir: () async => cache, now: () => now),
          animeFlow: c,
          store: ScheduleStore(dir: () async => Directory('${cache.path}/kept')),
          key: () async => 'k',
          now: () => now,
        );
        final s = await r.load();
        expect(s.animeFlowError, isNull);
        expect(s.animeFlowException, isNull);
        expect(s.entries.first.status, ScheduleStatus.aired, reason: 'not "not in AnimeFlow"');
        expect(await r.kept(), isNotNull);
      }
      // AnimeFlow's own Jellyfin refuses: worth saying.
      final home = ScheduleRepository(
        aniList: AniListClient(url: '${server.url}/anilist', cacheDir: () async => cache, now: () => now),
        animeFlow: AnimeFlowClient(
          baseUrl: '${server.url}/flow',
          tokenCandidates: () async => ['expired'],
          homeAccount: () async => true,
          now: () => now,
        ),
        now: () => now,
      );
      expect((await home.load()).animeFlowError, 'AnimeFlow: sign in to Jellyfin again');
    });

    test('without AnimeFlow, the linked Jellyfin: one walk, matched, placed, confirmed', () async {
      var walks = 0;
      final asked = <String>[];
      final index = SeriesIndexCache(
        servers: () async => ['mine'],
        walk: (id) async {
          walks++;
          return [
            const JellyfinSeriesInfo(serverId: 'mine', id: 'jf100', name: 'R100'),
            const JellyfinSeriesInfo(serverId: 'mine', id: 'jf900', name: 'Other', providerIds: {'AniList': '900'}),
          ];
        },
        now: () => now,
      );
      final r = ScheduleRepository(
        aniList: AniListClient(url: '${server.url}/anilist', cacheDir: () async => cache, now: () => now),
        jellyfinSeries: index.series,
        jellyfinEpisodes: (serverId, id) async {
          asked.add('$serverId|$id');
          return id == 'jf100' ? [JellyfinEpisodeRef(1, 3, premiere: at, watch: const EpisodeWatch(played: true))] : null;
        },
        now: () => now,
      );
      final s = await r.load();
      expect(s.animeFlowError, isNull);
      expect(s.entries.map((e) => (e.airing.anilistId, e.status, e.jellyfinSeriesId)), [
        (100, ScheduleStatus.inLibrary, 'jf100'),
        (901, ScheduleStatus.aired, null),
        (900, ScheduleStatus.upcoming, 'jf900'),
      ]);
      expect(s.entries.first.watch, const EpisodeWatch(played: true));
      expect(s.entries.first.jellyfinServerId, 'mine');
      expect(asked.toSet(), {'mine|jf100'}, reason: 'nothing aired of 900 yet');
      await r.load();
      expect(walks, 1, reason: 'the index is kept');
    });

    test('no AnimeFlow (none, or no address yet): AniList only, nothing to say', () async {
      for (final r in [
        repo(flow: false),
        ScheduleRepository(
          aniList: AniListClient(url: '${server.url}/anilist', cacheDir: () async => cache, now: () => now),
          animeFlow: AnimeFlowClient(address: () => '', token: 'tok', now: () => now),
          now: () => now,
        ),
      ]) {
        final s = await r.load();
        expect(s.animeFlowError, isNull);
        expect(s.me, isNull);
        expect(s.entries, hasLength(3));
      }
    });

    test('AniList failing: stale cache, else an error', () async {
      final r = repo();
      aniDown = true;
      final fail = await r.load();
      expect(fail.entries, isEmpty);
      expect(fail.aniListError, contains('500'));
      aniDown = false;
      await r.load();
      aniDown = true;
      final stale = await r.load(force: true);
      expect(stale.aniListStaleSince, isNotNull);
      expect(stale.entries, hasLength(3));
      expect(stale.entries.first.status, ScheduleStatus.available);
    });

    test('the last whole schedule is kept per account, on disk too', () async {
      final kept = Directory('${cache.path}/kept');
      ScheduleRepository keeping({String key = 'a'}) => ScheduleRepository(
            aniList: AniListClient(url: '${server.url}/anilist', cacheDir: () async => cache, now: () => now),
            animeFlow: AnimeFlowClient(baseUrl: '${server.url}/flow', token: 'tok', now: () => now),
            store: ScheduleStore(dir: () async => kept),
            key: () async => key,
            now: () => now,
          );
      final r = keeping();
      expect(await r.kept(), isNull);
      await r.load();
      await r.saved;
      expect((await r.kept())!.savedAt, now);
      // A new run: from disk, for that account only.
      final again = await keeping().kept();
      expect(again!.snapshot.entries.map((e) => (e.airing.anilistId, e.status)), [
        (100, ScheduleStatus.available),
        (901, ScheduleStatus.notTracked),
        (900, ScheduleStatus.notTracked),
      ]);
      expect(again.snapshot.me?.name, 'Me');
      expect(await keeping(key: 'b').kept(), isNull);
      // AnimeFlow failing, or AniList's stale fallback: what is kept stays.
      flowStatus = 503;
      await r.load(force: true);
      expect((await r.kept())!.snapshot.me?.name, 'Me');
      flowStatus = 200;
      aniDown = true;
      await r.load(force: true);
      expect((await r.kept())!.snapshot.entries.first.status, ScheduleStatus.available);
    });
  });
}
