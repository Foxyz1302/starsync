import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/schedule/anilist.dart';
import 'package:watch_together/src/schedule/animeflow.dart';
import 'package:watch_together/src/schedule/schedule_model.dart';

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
        {int season = 1, int? absolute, DateTime? air, int seriesId = 7, bool followed = false,
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
      followed: followed,
    );

void main() {
  group('matchSchedule', () {
    test('by AniList id + episode, per season ids', () {
      // One AnimeFlow series (7) spans two AniList entries: S1 = 100, S2 = 200.
      final out = matchSchedule(
        [airing(100, 3, DateTime(2026, 10, 1, 20)), airing(200, 3, DateTime(2026, 10, 9, 20))],
        schedule: [
          item(100, 3, EpisodeStatus.available, season: 1),
          item(200, 3, EpisodeStatus.downloading, season: 2, progress: 0.4, followed: true),
        ],
        series: [const AnimeFlowSeries(seriesId: 7, title: 'Show', anilistId: 100, jellyfinSeriesId: 'jf7')],
        now: now,
      );
      expect(out.map((e) => e.status), [ScheduleStatus.available, ScheduleStatus.downloading]);
      expect(out.map((e) => e.season), [1, 2]);
      expect(out[1].progress, 0.4);
      expect(out[1].followed, isTrue);
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

    test('absolute number, then same local air day', () {
      final out = matchSchedule(
        [
          airing(300, 1100, DateTime(2026, 10, 5, 9)), // AniList counts absolute
          airing(400, 13, DateTime(2026, 10, 6, 23, 30)), // numbering differs
        ],
        schedule: [
          item(300, 5, EpisodeStatus.available, season: 22, absolute: 1100),
          item(400, 1, EpisodeStatus.failed, season: 2, air: DateTime(2026, 10, 6, 0, 15), reason: 'No release'),
        ],
        now: now,
      );
      expect(out[0].status, ScheduleStatus.available);
      expect(out[0].season, 22);
      expect(out[1].status, ScheduleStatus.failed);
      expect(out[1].reason, 'No release');
    });

    test('a different local day does not match', () {
      final out = matchSchedule(
        [airing(400, 13, DateTime(2026, 10, 7, 0, 30))],
        schedule: [item(400, 1, EpisodeStatus.available, air: DateTime(2026, 10, 6, 23, 50))],
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
        series: [const AnimeFlowSeries(seriesId: 9, title: 'S', anilistId: 500, followed: true)],
        now: now,
      );
      expect(out.map((e) => e.status), [ScheduleStatus.missing, ScheduleStatus.upcoming]);
      expect(out.every((e) => e.followed && e.seriesId == 9), isTrue);
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
          return json(res, {'detail': 'Jellyfin is down', 'code': 'jellyfin_unreachable'}, status: flowStatus);
        }
        switch (req.uri.path) {
          case '/flow/me':
            return json(res, {'user_id': 'u', 'name': 'Me', 'scopes': ['view']});
          case '/flow/schedule':
            return json(res, {
              'items': [
                {'season': 1, 'episode': 3, 'anilist_id': 100, 'status': 'available', 'series_id': 7,
                  'title': 'Show', 'followed': false},
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
        (100, ScheduleStatus.notTracked, false),
        (901, ScheduleStatus.notTracked, false),
        (900, ScheduleStatus.upcoming, false),
      ]);
    });

    test('AnimeFlow not configured', () async {
      final s = await repo(flow: false).load();
      expect(s.animeFlowError, isNotNull);
      expect(s.entries, hasLength(3));
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
  });
}
