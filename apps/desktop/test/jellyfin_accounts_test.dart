import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/jellyfin/format.dart';
import 'package:starsync/src/jellyfin/sign_in.dart';
import 'package:starsync/src/screens/home/media_picker.dart';

/// Captured Jellyfin 10.11 answers shared with packages/core's client tests.
String jellyfinFixture(String name) =>
    File('../../packages/core/test/fixtures/jellyfin/$name.json').readAsStringSync();

const fixtureServerId = '2788af836cef7938ab4c41962afac55a';
const fixtureUserId = 'd4d07ff620068c41c4782dec38e0b17e';
const arifuretaId = '57d896451d17d2024129cf237759a491';
const season2Id = '8f3ccbf3807ed37c58f1432c496a9dec';

typedef FakeHandler = JellyfinHttpResponse Function(Uri uri, String? body);

/// Fake Jellyfin: routes by "METHOD /path" to fixtures, filters episode and
/// next-up lists by their query like the server does, records requests.
/// [approved] flips the Quick Connect state.
class FakeJellyfin implements JellyfinHttp {
  final requests = <({String method, Uri uri, Map<String, String> headers})>[];
  final routes = <String, FakeHandler>{};
  bool approved = false;
  bool offline = false;
  int meStatus = 200;

  /// Finished episodes (`/Items?filters=IsPlayed&sortBy=DatePlayed`): JoJo
  /// and Black Summoner watched on 2026-10-07, after Black Summoner's
  /// resume point (10-06), so its next-up episode is what continues.
  List<Object> recentlyPlayed = [
    {
      'Id': 'jojo-played', 'Name': 'Played', 'Type': 'Episode', 'SeriesId': '757534d5ccc39274aa0cc7f1d9a38d7d',
      'UserData': {'Played': true, 'LastPlayedDate': '2026-10-07T21:00:00Z'},
    },
    {
      'Id': 'bs-played', 'Name': 'Played', 'Type': 'Episode', 'SeriesId': 'c7974a65e1b7bd43f26858744a7d3c11',
      'UserData': {'Played': true, 'LastPlayedDate': '2026-10-07T20:00:00Z'},
    },
  ];

  FakeJellyfin() {
    fixture('GET', '/System/Info/Public', 'pub');
    on('GET', '/QuickConnect/Enabled', (_, _) => const JellyfinHttpResponse(200, 'true'));
    fixture('POST', '/QuickConnect/Initiate', 'quickconnect_initiate');
    on('GET', '/QuickConnect/Connect', (_, _) => JellyfinHttpResponse(
        200, jsonEncode({'Authenticated': approved, 'Secret': 's', 'Code': '437392'})));
    fixture('POST', '/Users/AuthenticateWithQuickConnect', 'auth_result');
    on('POST', '/Users/AuthenticateByName', (_, body) {
      final pw = (jsonDecode(body!) as Map)['Pw'];
      return pw == 'right'
          ? JellyfinHttpResponse(200, jellyfinFixture('auth_result'))
          : const JellyfinHttpResponse(401, '');
    });
    on('GET', '/Users/Me', (_, _) => JellyfinHttpResponse(
        meStatus, meStatus == 200 ? jellyfinFixture('me') : ''));
    on('POST', '/Sessions/Logout', (_, _) => const JellyfinHttpResponse(204, ''));
    fixture('GET', '/UserViews', 'views');
    on('GET', '/UserItems/Resume', (_, _) => JellyfinHttpResponse(200, jellyfinFixture('resume')));
    on('GET', '/Shows/NextUp', (uri, _) {
      final series = uri.queryParameters['seriesId'];
      if (series == null) return JellyfinHttpResponse(200, jellyfinFixture('nextup'));
      // Arifureta's next up: S2E4.
      final eps = _items('episodes').where((e) => e['SeriesId'] == series).toList();
      return _page(eps.isEmpty ? const [] : [eps[3]]);
    });
    fixture('GET', '/Items/Latest', 'latest_shows');
    on('GET', '/Items', (uri, _) {
      final q = uri.queryParameters;
      if (q['filters'] == 'IsPlayed' && q['sortBy'] == 'DatePlayed') return _page(recentlyPlayed);
      if ((q['searchTerm'] ?? '').isNotEmpty) {
        return q['searchTerm']!.toLowerCase().startsWith('ari')
            ? JellyfinHttpResponse(200, jellyfinFixture('search'))
            : _page(const []);
      }
      return JellyfinHttpResponse(
          200, jellyfinFixture(q['includeItemTypes'] == 'Movie' ? 'movies_page' : 'series_page'));
    });
    on('GET', '/Items/$arifuretaId', (_, _) => JellyfinHttpResponse(200, jellyfinFixture('series_detail')));
    on('GET', '/Items/1c67aa9143ebcdcea7953aada4db543a',
        (_, _) => JellyfinHttpResponse(200, jellyfinFixture('episode_detail')));
    on('GET', '/Shows/$arifuretaId/Seasons', (_, _) => JellyfinHttpResponse(200, jellyfinFixture('seasons')));
    on('GET', '/Shows/$arifuretaId/Episodes', (uri, _) {
      final season = uri.queryParameters['seasonId'];
      return _page(_items('episodes').where((e) => season == null || e['SeasonId'] == season).toList());
    });
  }

  static List<Map<String, dynamic>> _items(String fixture) =>
      ((jsonDecode(jellyfinFixture(fixture)) as Map)['Items'] as List).cast<Map<String, dynamic>>();

  static JellyfinHttpResponse _page(List<Object> items) =>
      JellyfinHttpResponse(200, jsonEncode({'Items': items, 'TotalRecordCount': items.length}));

  void on(String method, String path, FakeHandler h) => routes['$method $path'] = h;
  void fixture(String method, String path, String name) =>
      on(method, path, (_, _) => JellyfinHttpResponse(200, jellyfinFixture(name)));

  int count(String method, String path) =>
      requests.where((r) => r.method == method && r.uri.path == path).length;

  @override
  Future<JellyfinHttpResponse> send(String method, Uri uri,
      {Map<String, String> headers = const {}, String? body}) async {
    requests.add((method: method, uri: uri, headers: headers));
    if (offline) throw JellyfinException('$method ${uri.path}: connection refused');
    final h = routes['$method ${uri.path}'];
    return h == null ? const JellyfinHttpResponse(404, '') : h(uri, body);
  }

  @override
  void close() {}
}

JellyfinAuthResult fixtureAuth() =>
    JellyfinAuthResult.fromJson(jsonDecode(jellyfinFixture('auth_result')) as Map<String, dynamic>);

JellyfinServerInfo fixtureServer() =>
    JellyfinServerInfo.fromJson(jsonDecode(jellyfinFixture('pub')) as Map<String, dynamic>);

/// Accounts on a fake server with one linked account (no validation run).
Future<(JellyfinAccounts, FakeJellyfin)> linkedAccounts({FakeJellyfin? http}) async {
  final fake = http ?? FakeJellyfin();
  final accounts = JellyfinAccounts(
      store: MemoryJellyfinStore(), httpFactory: () => fake, deviceName: 'Test PC');
  await accounts.ensureLoaded(validate: false);
  await accounts.link(
      baseUrl: 'https://example.invalid', server: fixtureServer(), auth: fixtureAuth());
  return (accounts, fake);
}

void main() {
  group('accounts', () {
    test('persist in their Hive box with a stable device id', () async {
      final dir = Directory.systemTemp.createTempSync('jf_accounts_');
      addTearDown(() => dir.deleteSync(recursive: true));
      Hive.init(dir.path);
      final fake = FakeJellyfin();

      final a = JellyfinAccounts(httpFactory: () => fake, deviceName: 'PC');
      await a.ensureLoaded(validate: false);
      final deviceId = a.deviceId;
      expect(deviceId, hasLength(32));
      await a.link(baseUrl: 'https://example.invalid', server: fixtureServer(), auth: fixtureAuth());
      await a.rememberPick(const JellyfinMedia(
          serverId: fixtureServerId, baseUrl: 'https://example.invalid', itemId: 'abc', title: 'Ep'));
      await Hive.close();

      final b = JellyfinAccounts(httpFactory: () => fake, deviceName: 'PC');
      await b.ensureLoaded(validate: false);
      expect(b.deviceId, deviceId);
      final acc = b.accounts.single;
      expect(acc.serverId, fixtureServerId);
      expect(acc.serverName, 'Example Server');
      expect(acc.userName, 'testuser');
      expect(acc.token, 'TEST_ACCESS_TOKEN');
      expect(b.defaultServerId, fixtureServerId);
      expect(b.lastPick?.itemId, 'abc');
      // The header names this app and install.
      expect(b.clientInfo.client, 'Watch Together');
      expect(b.clientInfo.deviceId, deviceId);
      await Hive.close();
    });

    test('token check: online, expired stays linked, offline is not a sign-out', () async {
      final (accounts, fake) = await linkedAccounts();
      expect(await accounts.validate(fixtureServerId), JellyfinAccountStatus.online);
      expect(fake.requests.last.headers['Authorization'], contains('Token="TEST_ACCESS_TOKEN"'));

      fake.meStatus = 401;
      expect(await accounts.validate(fixtureServerId), JellyfinAccountStatus.expired);
      expect(accounts.accounts, hasLength(1));

      fake.offline = true;
      expect(await accounts.validate(fixtureServerId), JellyfinAccountStatus.offline);
      expect(accounts.errorOf(fixtureServerId), contains('connection refused'));
      expect(accounts.accounts, hasLength(1));
    });

    test('ensureLoaded validates in the background', () async {
      final fake = FakeJellyfin()..meStatus = 401;
      final store = MemoryJellyfinStore();
      final first = JellyfinAccounts(store: store, httpFactory: () => fake);
      await first.ensureLoaded(validate: false);
      await first.link(baseUrl: 'https://example.invalid', server: fixtureServer(), auth: fixtureAuth());
      final again = JellyfinAccounts(store: store, httpFactory: () => fake);
      await again.ensureLoaded();
      await pumpEventQueue();
      expect(again.statusOf(fixtureServerId), JellyfinAccountStatus.expired);
    });

    test('sign out revokes the token and unlinks; default moves on', () async {
      final (accounts, fake) = await linkedAccounts();
      final otherAuth = JellyfinAuthResult(
          accessToken: 'T2',
          user: const JellyfinUser(id: 'u2', name: 'other'),
          serverId: 'other-server');
      await accounts.link(
          baseUrl: 'https://two.invalid',
          server: const JellyfinServerInfo(id: 'other-server', name: 'Two', version: '10.11'),
          auth: otherAuth);
      expect(accounts.defaultServerId, fixtureServerId);
      await accounts.setDefault('other-server');
      expect(accounts.defaultServerId, 'other-server');

      await accounts.signOut('other-server');
      expect(fake.count('POST', '/Sessions/Logout'), 1);
      expect(fake.requests.last.headers['Authorization'], contains('Token="T2"'));
      expect(accounts.accounts.map((a) => a.serverId), [fixtureServerId]);
      expect(accounts.defaultServerId, fixtureServerId);
    });

    test('signing in again replaces the account and revokes the old token', () async {
      final (accounts, fake) = await linkedAccounts();
      final fresh = JellyfinAuthResult(
          accessToken: 'NEW', user: fixtureAuth().user, serverId: fixtureServerId);
      await accounts.link(baseUrl: 'https://alt.invalid', server: fixtureServer(), auth: fresh);
      await pumpEventQueue();
      expect(accounts.accounts.single.token, 'NEW');
      expect(accounts.accounts.single.urls, ['https://alt.invalid', 'https://example.invalid']);
      expect(fake.count('POST', '/Sessions/Logout'), 1);
    });
  });

  group('sign-in flow', () {
    late FakeJellyfin fake;
    late JellyfinAccounts accounts;
    setUp(() async {
      fake = FakeJellyfin();
      accounts = JellyfinAccounts(store: MemoryJellyfinStore(), httpFactory: () => fake);
      await accounts.ensureLoaded(validate: false);
    });

    test('bad address and non-Jellyfin servers stay on the address step', () async {
      final flow = JellyfinSignIn(accounts, pollInterval: Duration.zero);
      await flow.probe('   ');
      expect(flow.step, JellyfinSignInStep.address);
      expect(flow.error, isNotNull);
      fake.offline = true;
      await flow.probe('jelly.example');
      expect(flow.step, JellyfinSignInStep.address);
      expect(flow.error, contains('No Jellyfin server'));
    });

    test('Quick Connect: code, poll until approved, linked', () async {
      final flow = JellyfinSignIn(accounts, pollInterval: const Duration(milliseconds: 1));
      await flow.probe('example.invalid');
      expect(flow.step, JellyfinSignInStep.method);
      expect(flow.server?.name, 'Example Server');
      expect(flow.quickConnectAvailable, isTrue);
      final done = flow.startQuickConnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(flow.code, '437392');
      expect(flow.step, JellyfinSignInStep.quickConnect);
      fake.approved = true;
      await done;
      expect(flow.step, JellyfinSignInStep.done);
      expect(accounts.accounts.single.userName, 'testuser');
      expect(accounts.accounts.single.urls, ['https://example.invalid']);
    });

    test('Quick Connect cancel stops polling', () async {
      final flow = JellyfinSignIn(accounts, pollInterval: const Duration(milliseconds: 1));
      await flow.probe('https://example.invalid');
      final done = flow.startQuickConnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      flow.cancel();
      await done;
      final polls = fake.count('GET', '/QuickConnect/Connect');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.count('GET', '/QuickConnect/Connect'), polls);
      expect(flow.step, JellyfinSignInStep.method);
      expect(accounts.isEmpty, isTrue);
    });

    test('password: wrong then right', () async {
      final flow = JellyfinSignIn(accounts);
      await flow.probe('https://example.invalid');
      flow.usePassword();
      await flow.signIn('testuser', 'wrong');
      expect(flow.step, JellyfinSignInStep.password);
      expect(flow.error, 'Wrong username or password');
      await flow.signIn('testuser', 'right');
      expect(flow.step, JellyfinSignInStep.done);
      expect(accounts.accounts.single.token, 'TEST_ACCESS_TOKEN');
    });

    test('reconnect refuses a different server', () async {
      final (linked, _) = await linkedAccounts();
      final other = JellyfinAccount(
          serverId: 'someone-else', serverName: 'X', urls: const ['https://example.invalid'],
          userId: 'u', userName: 'n', token: 't');
      final flow = JellyfinSignIn(linked, reconnect: other);
      await flow.probe(other.baseUrl);
      expect(flow.step, JellyfinSignInStep.address);
      expect(flow.error, contains('different Jellyfin server'));
    });
  });

  group('picked media', () {
    test('controller selection is a PickedMedia per source', () {
      final c = MediaPickerController();
      expect(c.selection, isNull);
      c.pasteText('https://example.com/a.mkv');
      expect(c.selection, const LinkMedia('https://example.com/a.mkv', relay: LinkRelay.me));
      c.pasteText('/home/me/b.mkv');
      expect(c.selection, const FileMedia('/home/me/b.mkv'));
      c.source = MediaKind.jellyfin;
      expect(c.selection, isNull);
      const m = JellyfinMedia(
          serverId: 's', baseUrl: 'https://j.example', itemId: 'i', title: 'Ep', subtitle: 'Show · S1E6');
      c.pickJellyfin(m);
      expect(c.selection, m);
      c.source = MediaKind.file;
      expect(c.selection, const FileMedia('/home/me/b.mkv'));
      expect(c.jellyfin, m, reason: 'kept while another source shows');
      c.dispose();
    });

    test('the library starts on Jellyfin unless told otherwise; a saved pick is selected', () {
      const m = JellyfinMedia(serverId: 's', baseUrl: 'b', itemId: 'i', title: 't');
      expect(MediaPickerController(jellyfin: m).source, MediaKind.jellyfin);
      expect(MediaPickerController(jellyfin: m).selected!.itemId, 'i');
      expect(MediaPickerController(mediaPath: '/x.mkv', linkUrl: 'https://a/b').source, MediaKind.jellyfin);
      expect(MediaPickerController(source: MediaKind.link).source, MediaKind.link);
    });

    test('JellyfinMedia round-trips and labels', () {
      const m = JellyfinMedia(
          serverId: 's',
          baseUrl: 'https://j.example',
          itemId: 'i',
          mediaSourceId: 'src',
          title: 'Rice and Thieves and Heroes',
          subtitle: 'Black Summoner · S1E6',
          runtime: Duration(minutes: 23));
      final back = JellyfinMedia.fromJson(jsonDecode(jsonEncode(m.toJson())))!;
      expect(back, m);
      expect(back.runtime, const Duration(minutes: 23));
      expect(back.subtitle, 'Black Summoner · S1E6');
      expect(m.label, 'Rice and Thieves and Heroes — Black Summoner · S1E6');
      expect(const FileMedia('/a/b/movie.mkv').label, 'movie.mkv');
      expect(JellyfinMedia.fromJson({'serverId': 1}), isNull);
    });

    test('pickFor labels an episode "Series · S1E6"', () async {
      final (accounts, _) = await linkedAccounts();
      final ep = JellyfinItem.fromJson(jsonDecode(jellyfinFixture('episode_detail')) as Map<String, dynamic>);
      final m = pickFor(accounts.accounts.single, ep);
      expect(m.serverId, fixtureServerId);
      expect(m.itemId, '1c67aa9143ebcdcea7953aada4db543a');
      expect(m.subtitle, 'Black Summoner · S1E6');
      expect(m.runtime, isNotNull);
    });
  });

  group('format', () {
    test('time left and subtitles', () {
      final resume = JellyfinItemPage.fromJson(jsonDecode(jellyfinFixture('resume')) as Map<String, dynamic>).items;
      final ep = resume[1];
      expect(timeLeft(ep), endsWith('min left'));
      expect(cardSubtitle(ep), startsWith('S1E10 · '));
      expect(progressOf(ep), greaterThan(0));
      expect(formatRuntime(const Duration(minutes: 102)), '1 h 42 min');
      expect(formatRuntime(const Duration(minutes: 24)), '24 min');
    });
  });
}
