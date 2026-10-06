import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:test/test.dart';

/// Records requests and answers from captured fixtures (test/fixtures/jellyfin,
/// captured from a Jellyfin 10.11.11 server, personal data stripped).
class FakeHttp implements JellyfinHttp {
  final requests = <({String method, Uri uri, Map<String, String> headers, String? body})>[];
  final routes = <String, JellyfinHttpResponse>{};

  void on(String method, String path, {String? fixture, String body = '', int status = 200}) {
    routes['$method $path'] =
        JellyfinHttpResponse(status, fixture == null ? body : _fixture(fixture));
  }

  @override
  Future<JellyfinHttpResponse> send(String method, Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    requests.add((method: method, uri: uri, headers: headers, body: body));
    return routes['$method ${uri.path}'] ?? const JellyfinHttpResponse(404, '');
  }

  @override
  void close() {}

  ({String method, Uri uri, Map<String, String> headers, String? body}) get last => requests.last;
}

String _fixture(String name) => File('test/fixtures/jellyfin/$name.json').readAsStringSync();

const info = JellyfinClientInfo(
    client: 'Watch Together', device: 'Test PC', deviceId: 'dev-1', version: '1.2.3');
const uid = 'd4d07ff620068c41c4782dec38e0b17e';

void main() {
  late FakeHttp http;
  late JellyfinClient client;

  setUp(() {
    http = FakeHttp();
    client = JellyfinClient(
        baseUrl: 'https://example.invalid/', clientInfo: info, accessToken: 'TOK', userId: uid, http: http);
  });

  group('auth header', () {
    test('has all four client fields, token only when given, values encoded', () {
      expect(info.authorizationHeader(),
          'MediaBrowser Client="Watch%20Together", Device="Test%20PC", DeviceId="dev-1", Version="1.2.3"');
      expect(info.authorizationHeader('abc'), endsWith(', Token="abc"'));
    });
  });

  group('server + auth', () {
    test('publicInfo', () async {
      http.on('GET', '/System/Info/Public', fixture: 'pub');
      final s = await client.publicInfo();
      expect(s.id, '2788af836cef7938ab4c41962afac55a');
      expect(s.version, '10.11.11');
      expect(s.name, 'Example Server');
      expect(http.last.headers['Authorization'], isNot(contains('Token=')));
    });

    test('Quick Connect: initiate is a POST without token, then sign-in stores the token', () async {
      final anon = JellyfinClient(baseUrl: 'https://example.invalid', clientInfo: info, http: http);
      http.on('POST', '/QuickConnect/Initiate', fixture: 'quickconnect_initiate');
      final qc = await anon.quickConnectInitiate();
      expect(qc.code, '437392');
      expect(qc.secret, hasLength(64));
      expect(http.last.method, 'POST');
      expect(http.last.headers['Authorization'], info.authorizationHeader());

      var polls = 0;
      http.on('GET', '/QuickConnect/Connect', body: jsonEncode({'Authenticated': false, 'Secret': qc.secret, 'Code': qc.code}));
      http.on('POST', '/Users/AuthenticateWithQuickConnect', fixture: 'auth_result');
      final result = await anon.waitForQuickConnect(qc, interval: Duration.zero, isCancelled: () {
        if (++polls == 3) {
          http.on('GET', '/QuickConnect/Connect',
              body: jsonEncode({'Authenticated': true, 'Secret': qc.secret, 'Code': qc.code}));
        }
        return false;
      });
      expect(http.requests.where((r) => r.uri.path == '/QuickConnect/Connect').first.uri.queryParameters['secret'],
          qc.secret);
      expect(jsonDecode(http.last.body!), {'Secret': qc.secret});
      expect(result!.accessToken, 'TEST_ACCESS_TOKEN');
      expect(result.user.name, 'testuser');
      expect(result.serverId, '2788af836cef7938ab4c41962afac55a');
      expect(anon.accessToken, 'TEST_ACCESS_TOKEN');
      expect(anon.userId, uid);
    });

    test('Quick Connect wait can be cancelled', () async {
      http.on('GET', '/QuickConnect/Connect', body: jsonEncode({'Authenticated': false}));
      final r = await client.waitForQuickConnect(
          const QuickConnectSession(code: '1', secret: 's'),
          interval: Duration.zero,
          isCancelled: () => http.requests.length >= 2);
      expect(r, isNull);
    });

    test('password sign-in', () async {
      final anon = JellyfinClient(baseUrl: 'https://example.invalid', clientInfo: info, http: http);
      http.on('POST', '/Users/AuthenticateByName', fixture: 'auth_result');
      await anon.authenticateByName('testuser', 'pw "x"');
      expect(jsonDecode(http.last.body!), {'Username': 'testuser', 'Pw': 'pw "x"'});
      expect(anon.isAuthenticated, isTrue);
    });

    test('validateToken: user on 200, null on 401, throws otherwise', () async {
      http.on('GET', '/Users/Me', fixture: 'me');
      expect((await client.validateToken())!.name, 'testuser');
      expect(http.last.headers['Authorization'], contains('Token="TOK"'));
      http.on('GET', '/Users/Me', status: 401);
      expect(await client.validateToken(), isNull);
      http.on('GET', '/Users/Me', status: 502);
      expect(client.validateToken(), throwsA(isA<JellyfinException>()));
    });

    test('logout posts and forgets the token', () async {
      http.on('POST', '/Sessions/Logout', status: 204);
      await client.logout();
      expect(http.last.uri.path, '/Sessions/Logout');
      expect(client.accessToken, isNull);
      expect(client.isAuthenticated, isFalse);
    });
  });

  group('browsing', () {
    test('user views', () async {
      http.on('GET', '/UserViews', fixture: 'views');
      final views = await client.userViews();
      expect(views.map((v) => v.collectionType), ['homevideos', 'movies', 'tvshows']);
      expect(views[2].kind, JellyfinItemKind.collectionFolder);
      expect(http.last.uri.queryParameters['userId'], uid);
    });

    test('resume: episodes with position and parent art fallbacks', () async {
      http.on('GET', '/UserItems/Resume', fixture: 'resume');
      final items = await client.resume(limit: 3);
      final e = items.first;
      expect(http.last.uri.queryParameters, containsPair('mediaTypes', 'Video'));
      expect(e.kind, JellyfinItemKind.episode);
      expect(e.seriesName, 'Black Summoner');
      expect(e.userData.isResumable, isTrue);
      expect(e.userData.position, ticksToDuration(12080340000));
      expect(e.episodeLabel, 'S1E3');
      // Own primary (episode still); backdrop/logo/thumb come from the series.
      expect(e.image(JellyfinImageType.primary)!.itemId, e.id);
      expect(e.image(JellyfinImageType.backdrop)!.itemId, e.seriesId);
      expect(e.image(JellyfinImageType.logo)!.tag, '12601cf2099bd582789b5b305a6dacc9');
      expect(e.image(JellyfinImageType.thumb)!.itemId, e.seriesId);
    });

    test('next up and latest', () async {
      http.on('GET', '/Shows/NextUp', fixture: 'nextup');
      http.on('GET', '/Items/Latest', fixture: 'latest_shows');
      expect((await client.nextUp()).first.kind, JellyfinItemKind.episode);
      expect(http.last.uri.queryParameters['enableResumable'], 'false');
      final latest = await client.latest('df39dd8262146d0ff7d3c04498a4a6a5', limit: 4);
      expect(latest, hasLength(4));
      expect(latest.every((i) => i.kind == JellyfinItemKind.series), isTrue);
      expect(http.last.uri.queryParameters['parentId'], 'df39dd8262146d0ff7d3c04498a4a6a5');
    });

    test('library page: query params and paging', () async {
      http.on('GET', '/Items', fixture: 'series_page');
      const q = JellyfinItemQuery(
        parentId: 'df39dd8262146d0ff7d3c04498a4a6a5',
        includeItemTypes: [JellyfinItemType.series],
        recursive: true,
        filters: [JellyfinFilter.isUnplayed],
      );
      final page = await client.items(q.page(0, 5));
      final qp = http.last.uri.queryParameters;
      expect(qp['includeItemTypes'], 'Series');
      expect(qp['recursive'], 'true');
      expect(qp['sortBy'], 'SortName');
      expect(qp['sortOrder'], 'Ascending');
      expect(qp['filters'], 'IsUnplayed');
      expect(qp['startIndex'], '0');
      expect(qp['limit'], '5');
      expect(page.totalRecordCount, 218);
      expect(page.items, hasLength(5));
      expect(page.hasMore, isTrue);
      final s = page.items.first;
      expect(s.kind, JellyfinItemKind.series);
      expect(s.userData.unplayedItemCount, 12);
      expect(s.image(JellyfinImageType.backdrop)!.itemId, s.id);
    });

    test('search', () async {
      http.on('GET', '/Items', fixture: 'search');
      final r = await client.search('arifureta');
      expect(http.last.uri.queryParameters['searchTerm'], 'arifureta');
      expect(http.last.uri.queryParameters['includeItemTypes'], 'Movie,Series,Episode');
      expect(r.single.name, startsWith('Arifureta'));
    });

    test('item detail: media source and streams', () async {
      http.on('GET', '/Items/1c67aa9143ebcdcea7953aada4db543a', fixture: 'episode_detail');
      final e = await client.item('1c67aa9143ebcdcea7953aada4db543a');
      expect(e.runTime, const Duration(seconds: 1420, microseconds: 112000));
      final src = e.mediaSources.single;
      expect(src.supportsDirectPlay, isTrue);
      expect(src.size, 1525319390);
      expect(src.streamsOf(JellyfinStreamType.audio).map((s) => s.language), ['jpn', 'eng']);
      expect(src.streamsOf(JellyfinStreamType.subtitle), hasLength(17));
      expect(e.mediaStreams, hasLength(20));
    });

    test('seasons and episodes with user data', () async {
      http.on('GET', '/Shows/57d896451d17d2024129cf237759a491/Seasons', fixture: 'seasons');
      http.on('GET', '/Shows/57d896451d17d2024129cf237759a491/Episodes', fixture: 'episodes');
      final seasons = await client.seasons('57d896451d17d2024129cf237759a491');
      expect(seasons.map((s) => s.indexNumber), [2, 3]);
      expect(seasons.first.userData.unplayedItemCount, 12);
      final eps = await client.episodes('57d896451d17d2024129cf237759a491');
      expect(http.last.uri.queryParameters['isMissing'], 'false');
      expect(eps, hasLength(41));
      expect(eps.every((e) => !e.userData.played && e.userData.playbackPositionTicks == 0), isTrue);
    });

    test('nextEpisode crosses seasons and skips other copies of the same episode', () async {
      http.on('GET', '/Shows/57d896451d17d2024129cf237759a491/Episodes', fixture: 'episodes');
      final eps = await client.episodes('57d896451d17d2024129cf237759a491');
      final s2e12 = eps.firstWhere((e) => e.episodeLabel == 'S2E12');
      final next = await client.nextEpisode(s2e12);
      expect(next!.episodeLabel, 'S3E1');
      expect(next.id, 'eff01892797332814d4eece601b0353b');
      // S3E1 exists twice (two files); the successor of either is S3E2.
      expect(episodeAfter(eps, 'eff01892797332814d4eece601b0353b')!.episodeLabel, 'S3E2');
      expect(episodeAfter(eps, 'b7d8f70f090f80fe783703b3a8e1fa38')!.episodeLabel, 'S3E2');
      expect(episodeAfter(eps, eps.last.id), isNull);
      expect(episodeAfter(eps, 'nope'), isNull);
    });

    test('adjacentEpisodes: previous mirrors next across seasons and copies', () async {
      http.on('GET', '/Shows/57d896451d17d2024129cf237759a491/Episodes', fixture: 'episodes');
      final eps = await client.episodes('57d896451d17d2024129cf237759a491');
      final s3e2 = eps.firstWhere((e) => e.episodeLabel == 'S3E2');
      final around = await client.adjacentEpisodes(s3e2);
      // S3E1 exists twice: the predecessor is the copy right before S3E2.
      expect(around.previous!.episodeLabel, 'S3E1');
      expect(around.next!.episodeLabel, 'S3E3');
      final s3e1 = eps.lastWhere((e) => e.episodeLabel == 'S3E1');
      expect(episodeBefore(eps, s3e1.id)!.episodeLabel, 'S2E12');
      expect(episodeBefore(eps, eps.first.id), isNull);
      expect(episodeBefore(eps, 'nope'), isNull);
      expect((await client.adjacentEpisodes(const JellyfinItem(id: 'x', name: 'm', type: 'Movie'))).next,
          isNull);
    });
  });

  group('images', () {
    test('url with tag and maxWidth, no token', () {
      final url = client.imageUrl(
          const JellyfinImageRef('abc', JellyfinImageType.primary, 'tag1'), maxWidth: 300);
      expect(url.toString(),
          'https://example.invalid/Items/abc/Images/Primary?tag=tag1&maxWidth=300&quality=90');
      final bd = client.imageUrl(
          const JellyfinImageRef('abc', JellyfinImageType.backdrop, 't', index: 1));
      expect(bd.path, '/Items/abc/Images/Backdrop/1');
    });

    test('base path is kept', () {
      final c = JellyfinClient(baseUrl: 'https://example.invalid/jf/web/', clientInfo: info, http: http);
      expect(c.baseUrl, 'https://example.invalid/jf');
      expect(c.imageUrl(const JellyfinImageRef('a', JellyfinImageType.logo, 't')).path,
          '/jf/Items/a/Images/Logo');
    });
  });

  group('media segments', () {
    // Shape from Jellyfin's MediaSegmentDto (the live 10.11 server answers
    // 200 with an empty list: no segment provider installed).
    test('parses and sorts the ranges by start', () async {
      http.on('GET', '/MediaSegments/1c67aa9143ebcdcea7953aada4db543a', fixture: 'media_segments');
      final s = await client.mediaSegments('1c67aa9143ebcdcea7953aada4db543a');
      expect(http.last.method, 'GET');
      expect(s.map((e) => e.type), [
        JellyfinSegmentType.intro,
        JellyfinSegmentType.outro,
        JellyfinSegmentType.preview,
      ]);
      expect((s.first.start, s.first.end), (const Duration(seconds: 30), const Duration(minutes: 2)));
      expect(s[1].start, const Duration(minutes: 21, seconds: 30));
      expect(s.first.itemId, '1c67aa9143ebcdcea7953aada4db543a');
    });

    test('empty list, and none on servers without the endpoint', () async {
      http.on('GET', '/MediaSegments/a', body: '{"Items":[],"TotalRecordCount":0,"StartIndex":0}');
      expect(await client.mediaSegments('a'), isEmpty);
      expect(await client.mediaSegments('missing'), isEmpty); // 404
      http.on('GET', '/MediaSegments/x', status: 401);
      await expectLater(client.mediaSegments('x'),
          throwsA(isA<JellyfinException>().having((e) => e.isUnauthorized, 'unauthorized', true)));
    });

    test('unknown types stay unknown', () {
      expect(JellyfinSegmentType.parse('Something'), JellyfinSegmentType.unknown);
      expect(JellyfinSegmentType.parse(null), JellyfinSegmentType.unknown);
    });
  });

  group('playback', () {
    test('playbackInfo asks for direct play and parses the session', () async {
      http.on('POST', '/Items/1c67aa9143ebcdcea7953aada4db543a/PlaybackInfo', fixture: 'playback_info');
      final pi = await client.playbackInfo('1c67aa9143ebcdcea7953aada4db543a');
      expect(jsonDecode(http.last.body!), {
        'UserId': uid,
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
        'EnableTranscoding': false,
      });
      expect(pi.playSessionId, isNotEmpty);
      final src = pi.primarySource!;
      expect(src.id, '1c67aa9143ebcdcea7953aada4db543a');
      expect(src.defaultAudioStreamIndex, 1);
      final eng = src.streamAt(3)!;
      expect(eng.type, JellyfinStreamType.subtitle);
      expect(eng.title, 'English (Full Subtitle)');
      expect(eng.codec, 'ass');
      expect(eng.isExternal, isFalse);
      final jpn = src.streamAt(1)!;
      expect((jpn.language, jpn.codec, jpn.channels, jpn.isDefault), ('jpn', 'eac3', 2, true));
      // mpv ids are per type, 1-based.
      expect(src.mpvTrackId(1), 1);
      expect(src.mpvTrackId(2), 2);
      expect(src.mpvTrackId(3), 1);
      expect(src.mpvTrackId(5), 3);
      expect(src.jellyfinIndexForMpvTrack(JellyfinStreamType.subtitle, 3), 5);
    });

    test('stream URLs: with token for mpv, without for sharing', () {
      final shared = client.shareableStreamUrl('item1', mediaSourceId: 'src1');
      expect(shared.toString(),
          'https://example.invalid/Videos/item1/stream?static=true&mediaSourceId=src1');
      expect(client.streamUrl('item1', mediaSourceId: 'src1').queryParameters,
          {'static': 'true', 'mediaSourceId': 'src1', 'api_key': 'TOK'});
      expect(client.streamUrl('item1').queryParameters['mediaSourceId'], 'item1');
      final other = JellyfinClient(
          baseUrl: 'https://example.invalid', clientInfo: info, accessToken: 'OTHER', http: http);
      expect(other.authorizeUrl(client.streamUrl('item1')).queryParameters['api_key'], 'OTHER');
      expect(client.authHeaders['Authorization'], contains('Token="TOK"'));
    });
  });

  group('progress', () {
    const r = JellyfinPlaybackReport(
      itemId: 'i',
      mediaSourceId: 'm',
      playSessionId: 'p',
      positionTicks: 30 * jellyfinTicksPerSecond,
      audioStreamIndex: 1,
      subtitleStreamIndex: 3,
    );

    test('playing / progress / stopped bodies', () async {
      for (final p in ['/Sessions/Playing', '/Sessions/Playing/Progress', '/Sessions/Playing/Stopped']) {
        http.on('POST', p, status: 204);
      }
      await client.reportPlaybackStart(r);
      expect(http.last.uri.path, '/Sessions/Playing');
      expect(jsonDecode(http.last.body!), {
        'ItemId': 'i',
        'MediaSourceId': 'm',
        'PlaySessionId': 'p',
        'PositionTicks': 300000000,
        'IsPaused': false,
        'CanSeek': true,
        'PlayMethod': 'DirectPlay',
        'AudioStreamIndex': 1,
        'SubtitleStreamIndex': 3,
      });
      await client.reportPlaybackProgress(r.copyWith(isPaused: true, subtitleStreamIndex: -1));
      expect(http.last.uri.path, '/Sessions/Playing/Progress');
      final body = jsonDecode(http.last.body!) as Map;
      expect((body['IsPaused'], body['SubtitleStreamIndex']), (true, -1));
      await client.reportPlaybackStopped(r);
      expect(jsonDecode(http.last.body!),
          {'ItemId': 'i', 'MediaSourceId': 'm', 'PlaySessionId': 'p', 'PositionTicks': 300000000});
    });

    test('played / unplayed / resume position', () async {
      const ud = '{"Played":false,"PlaybackPositionTicks":0,"PlayCount":0}';
      http.on('POST', '/UserPlayedItems/x', body: '{"Played":true,"PlayCount":1}');
      http.on('DELETE', '/UserPlayedItems/x', body: ud);
      http.on('POST', '/UserItems/x/UserData', body: ud);
      expect((await client.markPlayed('x')).played, isTrue);
      expect(http.last.uri.queryParameters['userId'], uid);
      expect((await client.markUnplayed('x')).played, isFalse);
      expect(http.last.method, 'DELETE');
      await client.setResumePosition('x', 42);
      expect(jsonDecode(http.last.body!), {'PlaybackPositionTicks': 42});
      await client.clearResumePosition('x');
      expect(jsonDecode(http.last.body!), {'PlaybackPositionTicks': 0});
    });

    test('ticks conversion', () {
      expect(durationToTicks(const Duration(seconds: 1)), jellyfinTicksPerSecond);
      expect(ticksToDuration(14201120000), const Duration(milliseconds: 1420112));
    });
  });

  test('errors carry the status code', () async {
    http.on('GET', '/Items/zzz', status: 404, body: 'Not found');
    await expectLater(
        client.item('zzz'),
        throwsA(isA<JellyfinException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.isUnauthorized, 'isUnauthorized', isFalse)));
  });

  test('user-scoped calls need a user id', () {
    final anon = JellyfinClient(baseUrl: 'https://example.invalid', clientInfo: info, http: http);
    expect(() => anon.userViews(), throwsA(isA<JellyfinException>()));
    expect(() => anon.streamUrl('x'), throwsA(isA<JellyfinException>()));
  });
}
