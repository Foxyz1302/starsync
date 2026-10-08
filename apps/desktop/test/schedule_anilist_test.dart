import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/schedule/anilist.dart';

import 'schedule_fake_server.dart';

Map<String, Object?> airing(int id, int ep, int at,
        {bool adult = false, String format = 'TV', String? english = 'Show', String? color = '#e4a15d'}) =>
    {
      'airingAt': at,
      'episode': ep,
      'media': {
        'id': id,
        'title': {'romaji': 'Romaji $id', 'english': english},
        'coverImage': {'large': 'https://img/$id.jpg', 'color': color},
        'bannerImage': null,
        'isAdult': adult,
        'popularity': id * 10,
        'format': format,
      },
    };

Map<String, Object?> page(List<Object?> rows, {bool next = false}) => {
      'data': {
        'Page': {
          'pageInfo': {'hasNextPage': next},
          'airingSchedules': rows,
        },
      },
    };

void main() {
  late FakeServer server;
  late Directory cache;
  var now = DateTime.utc(2026, 10, 8, 12);
  final delays = <Duration>[];
  final from = DateTime.utc(2026, 9, 28), to = DateTime.utc(2026, 10, 26);

  AniListClient client() => AniListClient(
        url: server.url,
        cacheDir: () async => cache,
        delay: (d) async => delays.add(d),
        now: () => now,
        userAgent: 'watch-together/test',
      );

  setUp(() async {
    now = DateTime.utc(2026, 10, 8, 12);
    delays.clear();
    cache = await Directory.systemTemp.createTemp('anilist-test');
    server = await FakeServer.start((req, res) async {
      final vars = (jsonDecode(req.body) as Map)['variables'] as Map;
      final p = vars['page'] as int;
      json(res, page([
        if (p == 1) ...[airing(1, 5, 1759900000), airing(2, 1, 1759910000, adult: true)],
        if (p == 2) ...[airing(3, 2, 1759920000, format: 'MUSIC'), airing(4, 12, 1759930000, english: null)],
      ], next: p == 1));
    });
  });

  tearDown(() async {
    await server.close();
    await cache.delete(recursive: true);
  });

  test('pages, filters adult and music, parses fields', () async {
    final c = client();
    final s = await c.schedule(from, to);
    expect(server.seen, hasLength(2));
    final first = jsonDecode(server.seen.first.body) as Map;
    expect(first['variables'], {'from': from.millisecondsSinceEpoch ~/ 1000 - 1, 'to': to.millisecondsSinceEpoch ~/ 1000, 'page': 1});
    expect(server.seen.first.headers.value(HttpHeaders.userAgentHeader), 'watch-together/test');
    expect(s.airings.map((a) => a.anilistId), [1, 4]);
    final a = s.airings.first;
    expect(a.title, 'Show');
    expect(a.titleRomaji, 'Romaji 1');
    expect(a.episode, 5);
    expect(a.airingAt, DateTime.fromMillisecondsSinceEpoch(1759900000000, isUtc: true));
    expect(a.airingAt.isUtc, isTrue);
    expect(a.cover, 'https://img/1.jpg');
    expect(a.color?.toARGB32(), 0xffe4a15d);
    expect(a.popularity, 10);
    expect(s.airings.last.title, 'Romaji 4'); // no English title
    expect(s.isStale, isFalse);
    c.close();
  });

  test('memory cache, then disk cache across clients, expiry refetches', () async {
    final c = client();
    await c.schedule(from, to);
    await c.schedule(from, to);
    expect(server.seen, hasLength(2));
    now = now.add(const Duration(minutes: 11)); // memory stale, disk fresh
    await c.schedule(from, to);
    expect(server.seen, hasLength(2));
    final c2 = client(); // restart
    await c2.schedule(from, to);
    expect(server.seen, hasLength(2));
    now = now.add(const Duration(hours: 1));
    await c2.schedule(from, to);
    expect(server.seen, hasLength(4));
    // Another range start is another key.
    await c2.schedule(from.add(const Duration(days: 7)), to);
    expect(server.seen, hasLength(6));
    c.close();
    c2.close();
  });

  test('429 waits Retry-After once, then succeeds', () async {
    var n = 0;
    final ok = server.handler;
    server.handler = (req, res) async {
      if (n++ == 0) {
        res.statusCode = 429;
        res.headers.set(HttpHeaders.retryAfterHeader, '7');
        res.write('{"errors":[{"message":"Too Many Requests."}]}');
        return;
      }
      await ok(req, res);
    };
    final s = await client().schedule(from, to);
    expect(delays, [const Duration(seconds: 7)]);
    expect(s.airings, hasLength(2));
  });

  test('429 twice fails', () async {
    server.handler = (req, res) async {
      res.statusCode = 429;
      res.headers.set(HttpHeaders.retryAfterHeader, '2');
    };
    await expectLater(
        client().schedule(from, to),
        throwsA(isA<AniListException>().having((e) => e.isRateLimited, 'rate limited', isTrue)));
    expect(delays, hasLength(1));
    expect(server.seen, hasLength(2));
  });

  test('failure returns stale cache with its fetch time', () async {
    final c = client();
    final fetched = now;
    await c.schedule(from, to);
    now = now.add(const Duration(hours: 2));
    server.handler = (req, res) async => json(res, {'errors': [{'message': 'down'}]}, status: 500);
    final s = await c.schedule(from, to);
    expect(s.isStale, isTrue);
    expect(s.staleSince, fetched);
    expect(s.airings, hasLength(2));
    // A fresh client (restart) falls back to the disk copy.
    final s2 = await client().schedule(from, to);
    expect(s2.staleSince!.isAtSameMomentAs(fetched), isTrue);
  });

  test('failure without cache throws', () async {
    server.handler = (req, res) async => json(res, {'errors': [{'message': 'Bad'}]}, status: 400);
    await expectLater(client().schedule(from, to),
        throwsA(isA<AniListException>().having((e) => e.message, 'message', contains('Bad'))));
  });

  test('unreachable is an AniListException', () async {
    await server.close();
    await expectLater(client().schedule(from, to), throwsA(isA<AniListException>()));
  });

  test('parseHexColor', () {
    expect(parseHexColor('#000000')?.toARGB32(), 0xff000000);
    expect(parseHexColor('e4a15d'), isNull);
    expect(parseHexColor(null), isNull);
  });
}
