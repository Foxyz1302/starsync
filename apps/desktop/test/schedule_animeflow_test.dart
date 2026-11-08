import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/schedule/animeflow.dart';

import 'schedule_fake_server.dart';

const token = 'test-token';

final episodeJson = {
  'season': 2,
  'episode': 3,
  'absolute': 15,
  'episode_title': 'Three',
  'air_date': '2026-10-08T19:36:32Z',
  'anilist_id': 222,
  'status': 'downloading',
  'progress': 0.5,
};

final seriesJson = {
  'series_id': 7,
  'title': 'Show',
  'anidb_id': 70,
  'tvdb_id': 700,
  'anilist_id': 111,
  'jellyfin_series_id': 'jf7',
  'state': 'released',
  'monitored': true,
  'episodes_total': 24,
  'episodes_available': 20,
  'next_air_date': null,
};

final requestJson = {
  'id': 9,
  'kind': 'season',
  'title': 'Show S2',
  'series_id': 7,
  'season': 2,
  'status': 'searching',
  'created_at': '2026-10-01T10:00:00Z',
  'updated_at': '2026-10-02T10:00:00Z',
};

void main() {
  late FakeServer server;
  final delays = <Duration>[];
  var now = DateTime.utc(2026, 10, 8);

  AnimeFlowClient client({String? tok = token}) => AnimeFlowClient(
        baseUrl: '${server.url}/api/app/v1',
        token: tok,
        delay: (d) async => delays.add(d),
        now: () => now,
      );

  /// Routes "METHOD /path" (below the base) to a handler.
  Future<void> serve(Map<String, FakeRoute> routes) async {
    server.handler = (req, res) async {
      final path = req.uri.path.replaceFirst('/api/app/v1', '');
      final h = routes['${req.method} $path'];
      if (h == null) return json(res, {'detail': 'Not found', 'code': 'not_found'}, status: 404);
      await h(req, res);
    };
  }

  setUp(() async {
    delays.clear();
    now = DateTime.utc(2026, 10, 8);
    server = await FakeServer.start((req, res) async {});
  });

  tearDown(() => server.close());

  test('/me: token header, scopes, cached for a minute', () async {
    await serve({
      'GET /me': (req, res) async =>
          json(res, {'user_id': 'u1', 'name': 'Foxyz', 'scopes': ['view', 'request', 'bogus']}),
    });
    final c = client();
    final me = await c.me();
    expect(server.seen.single.headers.value('x-emby-token'), token);
    expect(server.seen.single.headers.value(HttpHeaders.userAgentHeader), startsWith('Starsync/'));
    expect(me.userId, 'u1');
    expect(me.name, 'Foxyz');
    expect(me.scopes, {AnimeFlowScope.view, AnimeFlowScope.request});
    expect(me.can(AnimeFlowScope.manage), isFalse);
    await c.me();
    expect(server.seen, hasLength(1));
    now = now.add(const Duration(seconds: 61));
    await c.me();
    expect(server.seen, hasLength(2));
  });

  test('/schedule: query in UTC ISO, items parsed, ETag/304 returns cached body', () async {
    var etagHits = 0;
    await serve({
      'GET /schedule': (req, res) async {
        if (req.headers.value(HttpHeaders.ifNoneMatchHeader) == 'W/"s1"') {
          etagHits++;
          res.statusCode = 304;
          return;
        }
        json(res, {
          'from': req.uri.queryParameters['from'],
          'to': req.uri.queryParameters['to'],
          'items': [
            {...episodeJson, 'series_id': 7, 'title': 'Show', 'anidb_id': 70, 'tvdb_id': 700,
              'jellyfin_series_id': 'jf7'},
          ],
        }, etag: 'W/"s1"');
      },
    });
    final c = client();
    final from = DateTime.utc(2026, 9, 28), to = DateTime.utc(2026, 10, 26);
    final w = await c.schedule(from, to);
    expect(server.seen.first.uri.queryParameters, {'from': '2026-09-28T00:00:00Z', 'to': '2026-10-26T00:00:00Z'});
    expect(w.from, from);
    final it = w.items.single;
    expect(it.seriesId, 7);
    expect(it.title, 'Show');
    expect(it.anidbId, 70);
    expect(it.tvdbId, 700);
    expect(it.jellyfinSeriesId, 'jf7');
    final e = it.episode;
    expect((e.season, e.episode, e.absolute, e.title, e.anilistId), (2, 3, 15, 'Three', 222));
    expect(e.airDate, DateTime.utc(2026, 10, 8, 19, 36, 32));
    expect(e.status, EpisodeStatus.downloading);
    expect(e.progress, 0.5);
    final again = await c.schedule(from, to);
    expect(etagHits, 1);
    expect(again.items.single.episode.anilistId, 222);
  });

  test('/schedule range checked locally', () async {
    final c = client();
    final from = DateTime.utc(2026, 10, 1);
    await expectLater(c.schedule(from, from),
        throwsA(isA<AnimeFlowException>().having((e) => e.code, 'code', AnimeFlowErrorCode.invalidRange)));
    await expectLater(c.schedule(from, from.add(const Duration(days: 46))), throwsA(isA<AnimeFlowException>()));
    expect(server.seen, isEmpty);
  });

  test('/series, /series/{id} with episodes', () async {
    await serve({
      'GET /series': (req, res) async => json(res, {'items': [seriesJson]}, etag: 'W/"a"'),
      'GET /series/7': (req, res) async => json(res, {
            ...seriesJson,
            'episodes': [
              {'season': 0, 'episode': 1, 'status': 'available'},
              {'season': 1, 'episode': 1, 'status': 'failed', 'reason': 'No release'},
            ],
          }),
    });
    final c = client();
    final s = (await c.series()).single;
    expect(s.seriesId, 7);
    expect(s.anilistId, 111);
    expect(s.state, SeriesState.released);
    expect(s.monitored, isTrue);
    expect((s.episodesTotal, s.episodesAvailable, s.nextAirDate), (24, 20, null));
    final d = await c.seriesDetail(7);
    expect(d.episodes.map((e) => e.season), [0, 1]);
    expect(d.episodes.last.status, EpisodeStatus.failed);
    expect(d.episodes.last.reason, 'No release');
  });

  test('/search and the three request bodies', () async {
    await serve({
      'GET /search': (req, res) async => json(res, {
            'items': [
              {'anidb_id': 70, 'title': 'Show', 'anilist_id': 111, 'series_id': 7},
              {'anidb_id': 71, 'title': 'Other'},
            ],
          }),
      'POST /requests': (req, res) async => json(res, {...requestJson, ...jsonDecode(req.body) as Map}, status: 202),
    });
    final c = client();
    final hits = await c.search('show');
    expect(server.seen.single.uri.queryParameters['q'], 'show');
    expect(hits.map((h) => (h.anidbId, h.title, h.anilistId, h.seriesId)), [(70, 'Show', 111, 7), (71, 'Other', null, null)]);
    final r = await c.requestSeries(70);
    expect(r.id, 9);
    expect(r.status, RequestStatus.searching);
    await c.requestSeason(7, 2);
    await c.requestEpisode(7, 2, 3);
    expect(server.seen.skip(1).map((r) => jsonDecode(r.body)), [
      {'anidb_id': 70},
      {'series_id': 7, 'season': 2},
      {'series_id': 7, 'season': 2, 'episode': 3},
    ]);
    expect(server.seen.last.headers.contentType?.mimeType, 'application/json');
  });

  test('/requests own and all, approve, reject', () async {
    await serve({
      'GET /requests': (req, res) async => json(res, {
            'items': [
              if (req.uri.queryParameters['scope'] == 'all') {...requestJson, 'user_id': 'u2', 'user_name': 'Bob'}
              else requestJson,
            ],
          }),
      'POST /requests/9/approve': (req, res) async => json(res, {...requestJson, 'status': 'approved'}),
      'POST /requests/9/reject': (req, res) async => res.statusCode = 204,
    });
    final c = client();
    final own = (await c.requests()).single;
    expect(own.kind, RequestKind.season);
    expect((own.seriesId, own.season, own.episode, own.userName), (7, 2, null, null));
    expect(own.createdAt, DateTime.utc(2026, 10, 1, 10));
    final all = (await c.requests(all: true)).single;
    expect(all.userName, 'Bob');
    expect((await c.approve(9))?.status, RequestStatus.approved);
    expect(await c.reject(9, reason: 'nope'), isNull);
    expect(jsonDecode(server.seen.last.body), {'reason': 'nope'});
    await c.reject(9);
    expect(jsonDecode(server.seen.last.body), <String, Object?>{});
  });

  test('/users and scopes', () async {
    await serve({
      'GET /users': (req, res) async => json(res, {
            'items': [
              {'user_id': 'u2', 'name': 'Bob', 'scopes': ['view'], 'revoked': true, 'last_seen_at': '2026-10-07T08:00:00Z'},
            ],
          }),
      'PUT /users/u2/scopes': (req, res) async => res.statusCode = 204,
    });
    final c = client();
    final u = (await c.users()).single;
    expect((u.userId, u.name, u.revoked), ('u2', 'Bob', true));
    expect(u.scopes, {AnimeFlowScope.view});
    expect(u.lastSeenAt, DateTime.utc(2026, 10, 7, 8));
    await c.setScopes('u2', {AnimeFlowScope.request, AnimeFlowScope.view}, revoked: false);
    expect(jsonDecode(server.seen.last.body), {'scopes': ['view', 'request'], 'revoked': false});
  });

  test('error codes map to typed exceptions', () async {
    const cases = {
      'missing_token': (401, AnimeFlowErrorCode.missingToken),
      'bad_token': (401, AnimeFlowErrorCode.badToken),
      'revoked': (403, AnimeFlowErrorCode.revoked),
      'missing_scope': (403, AnimeFlowErrorCode.missingScope),
      'own_account': (403, AnimeFlowErrorCode.ownAccount),
      'jellyfin_unreachable': (503, AnimeFlowErrorCode.jellyfinUnreachable),
      'search_unavailable': (503, AnimeFlowErrorCode.searchUnavailable),
      'invalid_request': (400, AnimeFlowErrorCode.invalidRequest),
      'invalid_time': (400, AnimeFlowErrorCode.invalidTime),
      'invalid_range': (400, AnimeFlowErrorCode.invalidRange),
      'not_found': (404, AnimeFlowErrorCode.notFound),
      'series_not_found': (404, AnimeFlowErrorCode.seriesNotFound),
      'episode_not_found': (404, AnimeFlowErrorCode.episodeNotFound),
      'request_not_found': (404, AnimeFlowErrorCode.requestNotFound),
      'user_not_found': (404, AnimeFlowErrorCode.userNotFound),
      'already_tracked': (409, AnimeFlowErrorCode.alreadyTracked),
      'already_available': (409, AnimeFlowErrorCode.alreadyAvailable),
      'already_requested': (409, AnimeFlowErrorCode.alreadyRequested),
      'invalid_state': (409, AnimeFlowErrorCode.invalidState),
      'something_new': (409, AnimeFlowErrorCode.invalidState), // falls back by status
    };
    final c = client();
    for (final MapEntry(key: wire, value: (status, code)) in cases.entries) {
      server.handler = (req, res) async => json(res, {'detail': 'because $wire', 'code': wire}, status: status);
      try {
        await c.series();
        fail('no throw for $wire');
      } on AnimeFlowException catch (e) {
        expect((e.statusCode, e.code, e.detail), (status, code, 'because $wire'), reason: wire);
      }
    }
    expect(delays, isEmpty);
  });

  test('nginx HTML 429 backs off, then succeeds or gives up', () async {
    var n = 0;
    server.handler = (req, res) async {
      if (n++ < 2) {
        res.statusCode = 429;
        res.headers.contentType = ContentType.html;
        res.write('<html><body><h1>429 Too Many Requests</h1></body></html>');
        return;
      }
      json(res, {'items': []});
    };
    final c = client();
    expect(await c.series(), isEmpty);
    expect(delays, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    n = -10;
    delays.clear();
    await expectLater(
        c.series(),
        throwsA(isA<AnimeFlowException>()
            .having((e) => e.isRateLimited, 'rate limited', isTrue)
            .having((e) => e.statusCode, 'status', 429)));
    expect(delays, hasLength(AnimeFlowClient.rateLimitRetries));
  });

  test('no token: missing_token without a request; oversized body refused', () async {
    await expectLater(client(tok: null).series(),
        throwsA(isA<AnimeFlowException>().having((e) => e.code, 'code', AnimeFlowErrorCode.missingToken)));
    await expectLater(client().reject(1, reason: 'x' * 17000),
        throwsA(isA<AnimeFlowException>().having((e) => e.code, 'code', AnimeFlowErrorCode.invalidRequest)));
    expect(server.seen, isEmpty);
  });

  test('unreachable is a network error', () async {
    await server.close();
    await expectLater(client().me(),
        throwsA(isA<AnimeFlowException>().having((e) => e.code, 'code', AnimeFlowErrorCode.network)));
  });

  test('a refused account token: the next linked account is tried, the working one kept', () async {
    await serve({
      'GET /me': (req, res) async => req.headers.value('x-emby-token') == 'good'
          ? json(res, {'user_id': 'u1', 'name': 'Foxyz', 'scopes': ['view']})
          : json(res, {'detail': 'Invalid token', 'code': 'invalid_token'}, status: 401),
    });
    final c = AnimeFlowClient(
      baseUrl: '${server.url}/api/app/v1',
      tokenCandidates: () async => ['other-jellyfin', 'good'],
      delay: (d) async => delays.add(d),
      now: () => now,
    );
    final me = await c.me();
    expect(me.name, 'Foxyz');
    expect(c.currentToken, 'good');
    expect(server.seen.map((r) => r.headers.value('x-emby-token')), ['other-jellyfin', 'good']);
    now = now.add(const Duration(seconds: 61));
    await c.me();
    expect(server.seen.last.headers.value('x-emby-token'), 'good', reason: 'the refused one is not tried again');
  });

  test('tokensFor: the same domain first, then every other linked account', () {
    JellyfinAccount acc(String id, String url) =>
        JellyfinAccount(serverId: id, serverName: id, urls: [url], userId: 'u', userName: 'n', token: 'tok-$id');
    final accounts = [acc('a', 'https://jelly.example.net'), acc('b', 'https://media.example.org')];
    expect(AnimeFlowClient.tokensFor(accounts, 'https://anime.example.org/api'), ['tok-b', 'tok-a']);
    expect(AnimeFlowClient.tokensFor([acc('a', 'https://jelly.example.net')], 'https://anime.example.org/api'),
        ['tok-a'], reason: 'pol\'s case: Jellyfin on another domain than AnimeFlow');
  });

  test('tokenFor picks the account under the same registrable domain', () {
    const base = 'https://anime.example.org/api/app/v1';
    JellyfinAccount acc(String id, String url) =>
        JellyfinAccount(serverId: id, serverName: id, urls: [url], userId: 'u', userName: 'n', token: 'tok-$id');
    final accounts = [
      acc('a', 'https://jellyfin.other.org'),
      acc('b', 'https://media.example.org:8920'),
    ];
    expect(AnimeFlowClient.tokenFor(accounts, base), 'tok-b');
    expect(AnimeFlowClient.tokenFor([acc('c', 'https://example.org')], base), 'tok-c');
    expect(AnimeFlowClient.tokenFor([acc('d', 'https://notexample.org')], base), isNull);
    // Deeper names on either side are the same server.
    expect(AnimeFlowClient.tokenFor([acc('e', 'https://jf.home.example.org')], base), 'tok-e');
    expect(AnimeFlowClient.tokenFor([acc('f', 'https://media.example.org')], 'https://api.anime.example.org/v1'),
        'tok-f');
    expect(AnimeFlowClient.tokenFor(accounts, 'https://anime.example.net/api'), isNull);
    expect(AnimeFlowClient.tokenFor(accounts, ''), isNull);
  });

  test('registrableDomain', () {
    expect(registrableDomain('anime.example.org'), 'example.org');
    expect(registrableDomain('a.b.Example.org'), 'example.org');
    expect(registrableDomain('example.org'), 'example.org');
    expect(registrableDomain('anime.example.co.uk'), 'example.co.uk');
    expect(registrableDomain('flow.example.de'), 'example.de');
    expect(registrableDomain('192.168.1.5'), '192.168.1.5');
    expect(registrableDomain('localhost'), 'localhost');
  });

  test('no address: not_configured without a request; the address is read on every call', () async {
    var at = '';
    final c = AnimeFlowClient(address: () => at, token: token, delay: (d) async {}, now: () => now);
    expect(c.configured, isFalse);
    await expectLater(c.me(),
        throwsA(isA<AnimeFlowException>().having((e) => e.code, 'code', AnimeFlowErrorCode.notConfigured)));
    expect(server.seen, isEmpty);
    await serve({'GET /me': (req, res) async => json(res, {'user_id': 'u1', 'name': 'Ann', 'scopes': ['view']})});
    at = '${server.url}/api/app/v1/';
    expect(c.baseUrl, '${server.url}/api/app/v1');
    expect((await c.me()).name, 'Ann');
    c.close();
  });
}
