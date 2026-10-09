import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/jellyfin/accounts.dart';
import 'package:watch_together/src/schedule/anilist.dart';
import 'package:watch_together/src/schedule/animeflow.dart';
import 'package:watch_together/src/schedule/schedule_model.dart';
import 'package:watch_together/src/schedule/ui/schedule_page.dart';
import 'package:watch_together/src/screens/home/picked_media.dart';

import 'schedule_fake_server.dart';

/// Serves [snap] without any network; [animeFlow] is a real client (over
/// the fake server) for the page's actions.
class FakeRepo extends ScheduleRepository {
  FakeRepo(this.snap, {super.animeFlow}) : super(aniList: AniListClient(cacheDir: () async => null));
  ScheduleSnapshot Function() snap;
  final forced = <bool>[];

  @override
  Future<ScheduleSnapshot> load({DateTime? from, DateTime? to, bool force = false}) async {
    forced.add(force);
    return snap();
  }
}

class FakeJf implements JellyfinHttp {
  final seen = <Uri>[];
  @override
  Future<JellyfinHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    seen.add(uri);
    if (uri.path.endsWith('/Shows/jf7/Episodes')) {
      return JellyfinHttpResponse(
        200,
        jsonEncode({
          'Items': [
            {
              'Id': 'ep2',
              'Name': 'Two',
              'Type': 'Episode',
              'SeriesName': 'Avail Show',
              'IndexNumber': 2,
              'ParentIndexNumber': 1,
            },
            {
              'Id': 'ep3',
              'Name': 'Three',
              'Type': 'Episode',
              'SeriesName': 'Avail Show',
              'IndexNumber': 3,
              'ParentIndexNumber': 1,
            },
          ],
          'TotalRecordCount': 2,
        }),
      );
    }
    return const JellyfinHttpResponse(404, '');
  }

  @override
  void close() {}
}

final now = DateTime.now();
DateTime day(int offset, [int hour = 12]) => DateTime(now.year, now.month, now.day + offset, hour).toUtc();

Airing airing(int id, String title, int ep, DateTime at, {int popularity = 50000}) => Airing(
  anilistId: id,
  title: title,
  titleRomaji: '$title romaji',
  episode: ep,
  airingAt: at,
  popularity: popularity,
);

List<ScheduleEntry> entries() => [
  ScheduleEntry(
    airing: airing(111, 'Avail Show', 3, day(0, 9)),
    status: ScheduleStatus.available,
    tracked: true,
    followed: true,
    seriesId: 7,
    season: 1,
    jellyfinSeriesId: 'jf7',
  ),
  ScheduleEntry(
    airing: airing(222, 'Missing Show', 5, day(0, 10)),
    status: ScheduleStatus.missing,
    tracked: true,
    seriesId: 8,
  ),
  ScheduleEntry(
    airing: airing(333, 'Failed Show', 2, day(0, 11)),
    status: ScheduleStatus.failed,
    reason: 'no seeders',
    tracked: true,
    seriesId: 9,
    season: 1,
  ),
  ScheduleEntry(airing: airing(444, 'Popular Untracked', 1, day(1, 8)), status: ScheduleStatus.notTracked),
  ScheduleEntry(
    airing: airing(555, 'Niche Untracked', 1, day(1, 9), popularity: 100),
    status: ScheduleStatus.notTracked,
  ),
  ScheduleEntry(
    airing: airing(666, 'Downloading Show', 4, day(1, 10)),
    status: ScheduleStatus.downloading,
    progress: 0.42,
    tracked: true,
    seriesId: 10,
    season: 1,
  ),
];

const owner = AnimeFlowMe(
  userId: 'u1',
  name: 'Foxy',
  scopes: {AnimeFlowScope.view, AnimeFlowScope.request, AnimeFlowScope.manage},
);
const viewer = AnimeFlowMe(userId: 'u2', name: 'Viewer', scopes: {AnimeFlowScope.view});

ScheduleSnapshot snapshot({
  AnimeFlowMe? me = owner,
  List<ScheduleEntry>? list,
  String? aniListError,
  DateTime? staleSince,
  String? animeFlowError,
}) {
  final w = ScheduleRepository.defaultWindow(now);
  return ScheduleSnapshot(
    from: w.from,
    to: w.to,
    entries: list ?? (aniListError != null ? const [] : entries()),
    aniListError: aniListError,
    aniListStaleSince: staleSince,
    animeFlowError: animeFlowError,
    me: me,
  );
}

Map<String, Object?> requestJson(int id, String status, {String kind = 'episode', String? user, String? reason}) => {
  'id': id,
  'kind': kind,
  'status': status,
  'title': 'Req $id',
  'series_id': 8,
  'season': 1,
  'episode': id,
  'user_name': ?user,
  'reason': ?reason,
};

void main() {
  late FakeServer server;
  late AnimeFlowClient flow;
  var requestList = <Map<String, Object?>>[];
  Map<String, Object?>? postError;
  var searchHits = <Map<String, Object?>>[];

  // The test binding answers every HttpClient with 400; the clients here
  // talk to the localhost fake server for real.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    requestList = [];
    postError = null;
    searchHits = [];
    server = await FakeServer.start((req, res) async {
      final p = req.uri.path.replaceFirst('/api/app/v1', '');
      switch ((req.method, p)) {
        case ('GET', '/requests'):
          json(res, {'items': requestList});
        case ('POST', '/requests'):
          if (postError != null) return json(res, postError, status: 409);
          json(res, {'id': 50, 'kind': 'episode', 'status': 'approved', 'title': 'x'}, status: 201);
        case ('GET', '/series/8'):
          json(res, {
            'series_id': 8,
            'title': 'Missing Show',
            'episodes': [
              {'season': 2, 'episode': 1, 'absolute': 5, 'anilist_id': 222, 'status': 'missing'},
            ],
          });
        case ('GET', '/series/7'):
          json(res, {
            'series_id': 7,
            'title': 'Avail Show',
            'episodes': [
              {'season': 1, 'episode': 3, 'anilist_id': 111, 'status': 'available'},
            ],
          });
        case ('GET', '/search'):
          json(res, {'items': searchHits});
        case ('PUT' || 'DELETE', '/series/7/follow'):
          res.statusCode = 204;
        case ('POST', '/requests/1/approve' || '/requests/2/reject'):
          json(res, {});
        default:
          json(res, {'detail': 'nope', 'code': 'not_found'}, status: 404);
      }
    });
    flow = AnimeFlowClient(baseUrl: '${server.url}/api/app/v1', token: 't');
  });

  tearDown(() async {
    flow.close();
    await server.close();
  });

  final toasts = <String>[];
  final putUp = <JellyfinMedia>[];

  /// Lets real socket IO (the fake server) complete, pumping frames.
  Future<void> io(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump();
    }
  }

  Future<FakeRepo> pumpPage(
    WidgetTester tester, {
    Size size = const Size(2560, 1080),
    ScheduleSnapshot Function()? snap,
    bool solo = false,
    JellyfinAccounts? accounts,
  }) async {
    toasts.clear();
    putUp.clear();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeRepo(snap ?? snapshot, animeFlow: flow);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SchedulePage(
            solo: solo,
            repository: repo,
            accounts: accounts,
            onToast: toasts.add,
            onPutUp: (m) async {
              putUp.add(m);
              return null;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await io(tester, rounds: 4);
    return repo;
  }

  /// Unmounts the page and lets the HttpClient's idle keep-alive timers
  /// (made in the fake clock) run out.
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
  }

  Finder card(int id, int ep) => find.byKey(ValueKey('card-$id-$ep'));
  Finder action(int id, int ep) => find.byKey(ValueKey('action-$id-$ep'));
  T widgetOf<T extends Widget>(WidgetTester tester, Finder f) =>
      tester.widget<T>(find.descendant(of: f, matching: find.byWidgetPredicate((w) => w is T)).first);

  testWidgets('renders the columns, opens on today, shows tracked statuses', (tester) async {
    await pumpPage(tester);
    expect(find.text('Today'), findsWidgets);
    final today = DateTime(now.year, now.month, now.day);
    expect(find.byKey(ValueKey('day-${today.year}-${today.month}-${today.day}')), findsOneWidget);
    // Scrolled to today: last week's Monday is off screen.
    final w = ScheduleRepository.defaultWindow(now).from;
    expect(find.byKey(ValueKey('day-${w.year}-${w.month}-${w.day}')), findsNothing);
    expect(card(111, 3), findsOneWidget);
    expect(find.text('on Jellyfin'), findsOneWidget);
    expect(find.text('missing'), findsOneWidget);
    expect(find.text('failed · no seeders'), findsOneWidget);
    expect(find.text('downloading 42%'), findsOneWidget);
    expect(find.text('Put it up'), findsOneWidget);
    // On Jellyfin: untracked entries are hidden.
    expect(card(444, 1), findsNothing);
    expect(find.byKey(const ValueKey('schedule-animeflow')), findsOneWidget);
    expect(find.textContaining('AnimeFlow · Foxy · view, request, manage'), findsOneWidget);
    expect(find.text('Requests'), findsOneWidget);
    await done(tester);
  });

  testWidgets('filters: following, all airing, niche too, compact', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Following'));
    await tester.pump();
    expect(card(111, 3), findsOneWidget);
    expect(card(222, 5), findsNothing);

    await tester.tap(find.text('All airing'));
    await tester.pump();
    expect(card(444, 1), findsOneWidget);
    expect(card(555, 1), findsNothing);
    expect(find.text('Request series'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-niche')));
    await tester.pump();
    expect(card(555, 1), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('schedule-compact')));
    await tester.pump();
    expect(tester.getSize(card(111, 3)).height, lessThan(80));
    expect(find.text('Put it up'), findsNothing);
    expect(tester.takeException(), isNull);
    await done(tester);
  });

  testWidgets('request on a tracked episode sends AnimeFlow numbering', (tester) async {
    await pumpPage(tester);
    await tester.tap(action(222, 5));
    await io(tester);
    final post = server.seen.where((r) => r.method == 'POST' && r.uri.path.endsWith('/requests')).single;
    expect(jsonDecode(post.body), {'series_id': 8, 'season': 2, 'episode': 1});
    expect(toasts, ['Requested Missing Show, episode 5']);
    expect(find.descendant(of: card(222, 5), matching: find.text('Requested')), findsOneWidget);
    await done(tester);
  });

  testWidgets('request errors become friendly text', (tester) async {
    await pumpPage(tester);
    postError = {'detail': 'dup', 'code': 'already_requested'};
    await tester.tap(action(333, 2));
    await io(tester);
    expect(toasts, ['Already requested']);
    expect(find.descendant(of: card(333, 2), matching: find.text('Requested')), findsOneWidget);
    await done(tester);
  });

  testWidgets('request series finds the AniDB id by AniList id', (tester) async {
    await pumpPage(tester);
    searchHits = [
      {'anidb_id': 1, 'title': 'Other', 'anilist_id': 999},
      {'anidb_id': 4444, 'title': 'Popular Untracked', 'anilist_id': 444},
    ];
    await tester.tap(find.text('All airing'));
    await tester.pump();
    await tester.tap(action(444, 1));
    await io(tester);
    final search = server.seen.firstWhere((r) => r.uri.path.endsWith('/search'));
    expect(search.uri.queryParameters['q'], 'Popular Untracked');
    final post = server.seen.where((r) => r.method == 'POST' && r.uri.path.endsWith('/requests')).single;
    expect(jsonDecode(post.body), {'anidb_id': 4444});
    expect(toasts, ['Requested Popular Untracked']);
    await done(tester);
  });

  testWidgets('request series without a match lets the user choose', (tester) async {
    await pumpPage(tester);
    searchHits = [
      {'anidb_id': 77, 'title': 'Close Enough'},
    ];
    await tester.tap(find.text('All airing'));
    await tester.pump();
    await tester.tap(action(444, 1));
    await io(tester);
    expect(find.byKey(const ValueKey('anidb-choose')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anidb-77')));
    await io(tester);
    final post = server.seen.where((r) => r.method == 'POST' && r.uri.path.endsWith('/requests')).single;
    expect(jsonDecode(post.body), {'anidb_id': 77});

    // Nothing at all: "not found on AniDB", nothing sent.
    searchHits = [];
    await tester.tap(find.byKey(const ValueKey('schedule-niche')));
    await tester.pump();
    await tester.tap(action(555, 1));
    await io(tester);
    expect(find.text('Not found on AniDB'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await io(tester, rounds: 3);
    expect(server.seen.where((r) => r.method == 'POST' && r.uri.path.endsWith('/requests')), hasLength(1));
    await done(tester);
  });

  testWidgets('without the request scope the button is disabled with a hint', (tester) async {
    await pumpPage(tester, snap: () => snapshot(me: viewer));
    final b = widgetOf<OutlinedButton>(tester, action(222, 5));
    expect(b.onPressed, isNull);
    expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains('owner')), findsWidgets);
    expect(find.text('My requests'), findsOneWidget);
    await done(tester);
  });

  testWidgets('follow toggles through AnimeFlow', (tester) async {
    final repo = await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('follow-111-3')));
    await io(tester);
    expect(server.seen.where((r) => r.method == 'DELETE' && r.uri.path.endsWith('/series/7/follow')), hasLength(1));
    expect(repo.forced.length, greaterThanOrEqualTo(2)); // reloaded
    await done(tester);
  });

  testWidgets('put it up resolves the Jellyfin episode', (tester) async {
    final jf = FakeJf();
    final accounts = JellyfinAccounts(
      store: MemoryJellyfinStore({
        'accounts': jsonEncode([
          {
            'serverId': 'srv',
            'serverName': 'Home',
            'urls': ['http://jf.test'],
            'userId': 'uid',
            'userName': 'me',
            'token': 'tok',
          },
        ]),
      }),
      httpFactory: () => jf,
      deviceName: 'Test',
    );
    await pumpPage(tester, accounts: accounts);
    await tester.tap(find.text('Put it up'));
    await io(tester);
    expect(putUp, hasLength(1));
    expect(putUp.single.itemId, 'ep3');
    expect(putUp.single.serverId, 'srv');
    expect(toasts, isEmpty);
    await done(tester);
  });

  testWidgets('solo: the button says Play and works', (tester) async {
    await pumpPage(tester, solo: true);
    expect(find.text('Put it up'), findsNothing);
    final b = widgetOf<ButtonStyleButton>(tester, action(111, 3));
    expect(b.onPressed, isNotNull);
    expect(find.text('Play'), findsOneWidget);
    await done(tester);
  });

  testWidgets('owner sheet: retry approves, decline rejects', (tester) async {
    requestList = [
      requestJson(1, 'failed', user: 'Alice', reason: 'no release'),
      requestJson(2, 'searching', user: 'Bob'),
      requestJson(3, 'done', user: 'Carol'),
    ];
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('schedule-requests')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('no release'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('decline-1')), findsNothing);
    expect(find.byKey(const ValueKey('decline-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-3')), findsNothing);
    expect(find.byKey(const ValueKey('decline-3')), findsNothing);
    // The owner sees everyone's.
    expect(server.seen.any((r) => r.uri.path.endsWith('/requests') && r.uri.queryParameters['scope'] == 'all'), isTrue);

    await tester.tap(find.byKey(const ValueKey('retry-1')));
    await io(tester);
    await tester.tap(find.byKey(const ValueKey('decline-2')));
    await io(tester);
    expect(server.seen.where((r) => r.method == 'POST' && r.uri.path.endsWith('/requests/1/approve')), hasLength(1));
    expect(server.seen.where((r) => r.method == 'POST' && r.uri.path.endsWith('/requests/2/reject')), hasLength(1));
    expect(toasts, ['Retrying Req 1', 'Declined Req 2']);
    await done(tester);
  });

  testWidgets('a viewer\'s sheet has no owner buttons', (tester) async {
    requestList = [requestJson(1, 'failed')];
    await pumpPage(tester, snap: () => snapshot(me: viewer));
    await tester.tap(find.byKey(const ValueKey('schedule-requests')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Req 1 · S1E1'), findsOneWidget);
    expect(find.text('Viewer'), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-1')), findsNothing);
    expect(server.seen.any((r) => r.uri.queryParameters['scope'] == 'all'), isFalse);
    await done(tester);
  });

  testWidgets('stale AniList data shows its time', (tester) async {
    final at = DateTime(now.year, now.month, now.day, 7, 5);
    await pumpPage(tester, snap: () => snapshot(staleSince: at));
    expect(find.text('AniList busy · showing data from 07:05'), findsOneWidget);
    await done(tester);
  });

  testWidgets('AniList failure shows the error and retries', (tester) async {
    var fail = true;
    final repo = await pumpPage(
      tester,
      snap: () => fail ? snapshot(aniListError: 'AniList unreachable: boom') : snapshot(),
    );
    expect(find.byKey(const ValueKey('schedule-error')), findsOneWidget);
    expect(find.textContaining('AniList unreachable: boom'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Try again'));
    await io(tester, rounds: 3);
    expect(repo.forced.last, isTrue);
    expect(find.byKey(const ValueKey('schedule-error')), findsNothing);
    expect(card(111, 3), findsOneWidget);
    await done(tester);
  });

  testWidgets('AnimeFlow failure: error pill, all airing, no requests', (tester) async {
    await pumpPage(
      tester,
      snap: () => snapshot(
        me: null,
        animeFlowError: 'Link the Jellyfin server to see AnimeFlow statuses',
        list: [for (final e in entries()) untrackedEntry(e.airing, now)],
      ),
    );
    expect(find.text('Link the Jellyfin server to see AnimeFlow statuses'), findsOneWidget);
    expect(card(444, 1), findsOneWidget); // switched to All airing
    expect(find.text('Request series'), findsNothing);
    final b = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('schedule-requests')));
    expect(b.onPressed, isNull);
    await done(tester);
  });

  testWidgets('refreshes every minute and on the button', (tester) async {
    final repo = await pumpPage(tester);
    expect(repo.forced, [false]);
    await tester.pump(SchedulePage.refreshEvery);
    await io(tester, rounds: 3);
    expect(repo.forced, [false, false]);
    await tester.tap(find.byKey(const ValueKey('schedule-refresh')));
    await io(tester, rounds: 3);
    expect(repo.forced, [false, false, true]);
    await done(tester);
  });

  for (final size in const [Size(2560, 1080), Size(1100, 700), Size(900, 600)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      requestList = [requestJson(1, 'failed', user: 'Alice', reason: 'a long reason ' * 6)];
      await pumpPage(tester, size: size);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('All airing'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('schedule-requests')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('schedule-compact')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await done(tester);
    });
  }
}
