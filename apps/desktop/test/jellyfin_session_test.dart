import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/jellyfin/accounts.dart';
import 'package:watch_together/src/jellyfin/browse_scope.dart';
import 'package:watch_together/src/jellyfin/progress.dart';
import 'package:watch_together/src/jellyfin/session_media.dart';
import 'package:watch_together/src/jellyfin/track_prefs.dart';
import 'package:watch_together/src/screens/home/host_tab.dart' show hostJellyfinMedia;
import 'package:watch_together/src/screens/home/media_picker.dart';
import 'package:watch_together/src/screens/session/jellyfin_widgets.dart';
import 'package:watch_together/src/screens/session/swap_panel.dart';
import 'package:watch_together/src/screens/session_screen.dart' show viaHostOf;
import 'package:watch_together/src/session/session_coordinator.dart' show AutoAdvance;

import 'jellyfin_accounts_test.dart';
import 'jellyfin_browser_test.dart' show app, setSize, settle;

const episodeId = '1c67aa9143ebcdcea7953aada4db543a'; // Black Summoner S1E6
const nextEpisodeId = 'baf73898ff81e215aa025c43d7344020'; // S1E7
const seriesId = 'c7974a65e1b7bd43f26858744a7d3c11';
const seasonId = 'ec0e23df54682dfd02a65fc4578c7e65';
const playSessionId = '295aff86b56ea5abcb80ff2d784642b0';

const episodeRef = JellyfinRef(
    serverId: fixtureServerId, itemId: episodeId, title: 'Rice and Thieves and Heroes');

/// The fake plus playback: PlaybackInfo, the Black Summoner episodes and
/// the three Sessions reports (recorded with their bodies).
FakeJellyfin playbackFake() {
  final fake = FakeJellyfin();
  fake.fixture('POST', '/Items/$episodeId/PlaybackInfo', 'playback_info');
  fake.on('GET', '/Shows/$seriesId/Episodes',
      (_, _) => JellyfinHttpResponse(200, jellyfinFixture('bs_episodes')));
  for (final path in ['/Sessions/Playing', '/Sessions/Playing/Progress', '/Sessions/Playing/Stopped']) {
    fake.on('POST', path, (_, body) {
      reports.add((path: path, body: jsonDecode(body!) as Map<String, dynamic>));
      return const JellyfinHttpResponse(204, '');
    });
  }
  return fake;
}

final reports = <({String path, Map<String, dynamic> body})>[];

JellyfinMediaSource fixtureSource() => JellyfinPlaybackInfo.fromJson(
        jsonDecode(jellyfinFixture('playback_info')) as Map<String, dynamic>)
    .primarySource!;

MemberView member(String id, String name, {Map<String, bool> jf = const {}, bool stale = false}) =>
    MemberView(
        id: id, name: name, ready: true, inSet: true, buffered: 10, stale: stale, jf: jf);

void main() {
  setUp(reports.clear);

  group('resolve a ref', () {
    test('own account: PlaybackInfo with its own user, static stream, token in the header',
        () async {
      final (accounts, fake) = await linkedAccounts(http: playbackFake());
      final plan = await resolveJellyfinRef(accounts, episodeRef,
          relay: true, relayUrl: 'http://h:1/j/default/t/$episodeId');
      expect(plan, isA<OwnPlay>());
      plan as OwnPlay;
      expect(plan.jfAccess, isTrue);
      expect(plan.info.playSessionId, playSessionId);
      expect(plan.source.id, episodeId);
      expect(plan.item?.seriesId, seriesId);
      final info = fake.requests.firstWhere((r) => r.uri.path.endsWith('/PlaybackInfo'));
      expect(info.uri.queryParameters['userId'], fixtureUserId);
      expect(info.headers['Authorization'], contains('Token="TEST_ACCESS_TOKEN"'));
      final url = Uri.parse(plan.url);
      expect(url.path, '/Videos/$episodeId/stream');
      expect(url.queryParameters['static'], 'true');
      expect(url.queryParameters.containsKey('api_key'), isFalse, reason: 'token in a header only');
      expect(plan.headers['Authorization'], accounts.clientInfo.authorizationHeader('TEST_ACCESS_TOKEN'));
    });

    test('no account: the relay URL when the server relays', () async {
      final accounts = JellyfinAccounts(store: MemoryJellyfinStore(), httpFactory: FakeJellyfin.new);
      final plan = await resolveJellyfinRef(accounts, episodeRef,
          relay: true, relayUrl: 'http://h:1/j/default/t/$episodeId');
      expect(plan, isA<RelayPlay>());
      expect((plan as RelayPlay).url, 'http://h:1/j/default/t/$episodeId');
      expect(plan.jfAccess, isFalse);
    });

    test('neither: blocked with a clear message, never a silent stall', () async {
      final accounts = JellyfinAccounts(store: MemoryJellyfinStore(), httpFactory: FakeJellyfin.new);
      final plan = await resolveJellyfinRef(accounts, episodeRef, relay: false, relayUrl: null);
      expect(plan, isA<BlockedPlay>());
      expect((plan as BlockedPlay).message,
          'No Jellyfin account here for that Jellyfin server, and nobody is passing it on');
      expect(plan.jfAccess, isNull);
    });

    test('a 401 marks the account expired and falls back to the relay', () async {
      final fake = playbackFake()
        ..on('POST', '/Items/$episodeId/PlaybackInfo', (_, _) => const JellyfinHttpResponse(401, ''));
      final (accounts, _) = await linkedAccounts(http: fake);
      final plan = await resolveJellyfinRef(accounts, episodeRef, relay: true, relayUrl: 'http://r');
      expect(plan, isA<RelayPlay>());
      expect(accounts.statusOf(fixtureServerId), JellyfinAccountStatus.expired);
      final blocked = await resolveJellyfinRef(accounts, episodeRef, relay: false, relayUrl: null);
      expect((blocked as BlockedPlay).message, contains('for Example Server'));
      expect(blocked.message, contains('sign-in expired'));
    });

    test('relay URL is built like the /m one', () {
      expect(relayUrlFor('10.0.0.2', 8080, 'tok', episodeId),
          'http://10.0.0.2:8080/j/default/tok/$episodeId');
    });
  });

  group('wire media', () {
    test('a pick goes up as a ref without URL or token', () async {
      final (accounts, _) = await linkedAccounts();
      const pick = JellyfinMedia(
          serverId: fixtureServerId,
          baseUrl: 'https://example.invalid',
          itemId: episodeId,
          title: 'Rice and Thieves and Heroes',
          subtitle: 'Black Summoner · S1E6',
          runtime: Duration(minutes: 23));
      final media = hostJellyfinMedia(accounts, pick);
      expect(media.url, isNull);
      expect(media.jellyfin!.itemId, episodeId);
      expect(media.jellyfin!.subtitle, 'Black Summoner · S1E6');
      expect(media.jellyfin!.runtimeSecs, 23 * 60);
      expect(jsonEncode(SwapIntent(media: media).toJson()), isNot(contains('TEST_ACCESS_TOKEN')));
      expect(() => hostJellyfinMedia(accounts, const JellyfinMedia(serverId: 'gone', baseUrl: 'x', itemId: 'i', title: 't')),
          throwsFormatException);
      accounts.markExpired(fixtureServerId);
      expect(() => hostJellyfinMedia(accounts, pick), throwsFormatException);
    });

    test('a pasted Jellyfin link becomes a ref (ServerId from /System/Info/Public, no api_key)',
        () async {
      final (accounts, fake) = await linkedAccounts();
      final media = await mediaForLink(accounts,
          'https://example.invalid/Videos/$episodeId/stream?static=true&api_key=SOMEONES_TOKEN');
      expect(media.url, isNull);
      expect(media.jellyfin!.serverId, fixtureServerId);
      expect(media.jellyfin!.itemId, episodeId);
      expect(media.jellyfin!.title, 'Rice and Thieves and Heroes', reason: 'title via own account');
      expect(media.name, 'Rice and Thieves and Heroes');
      expect(jsonEncode(media.toJson()), isNot(contains('SOMEONES_TOKEN')));
      expect(fake.count('GET', '/System/Info/Public'), 1);
      // Never sent with the pasted token.
      expect(fake.requests.every((r) => !'${r.uri}${r.headers}'.contains('SOMEONES_TOKEN')), isTrue);

      // A web UI link carries the ServerId: no lookup.
      final web = await mediaForLink(accounts,
          'https://example.invalid/web/#/details?id=$episodeId&serverId=$fixtureServerId');
      expect(web.jellyfin!.serverId, fixtureServerId);
      expect(fake.count('GET', '/System/Info/Public'), 1);
    });

    test('other links, or an unreachable Jellyfin, stay plain links', () async {
      final fake = FakeJellyfin()..offline = true;
      final accounts = JellyfinAccounts(store: MemoryJellyfinStore(), httpFactory: () => fake);
      const url = 'https://jelly.example/Items/$episodeId/Download?api_key=x';
      final media = await mediaForLink(accounts, url);
      expect(media.jellyfin, isNull);
      expect(media.url, url);
      expect(media.name, 'Download');
      final plain = await mediaForLink(accounts, 'https://cdn.example/movie.mkv');
      expect(plain.url, 'https://cdn.example/movie.mkv');
      expect(plain.name, 'movie.mkv');
    });

    test('relay credential: the account token with exactly its own device fields', () async {
      final (accounts, _) = await linkedAccounts();
      final cred = relayCredentialFor(accounts, serverId: fixtureServerId)!;
      final info = accounts.clientInfo;
      expect(cred.token, 'TEST_ACCESS_TOKEN');
      expect(cred.serverId, fixtureServerId);
      expect(cred.baseUrl, 'https://example.invalid');
      expect([cred.client, cred.device, cred.deviceId, cred.version],
          [info.client, info.device, info.deviceId, info.version]);
      expect(cred.device, 'Test PC');
      // Another server's item: the default account still relays its own.
      expect(relayCredentialFor(accounts, serverId: 'other')!.serverId, fixtureServerId);
      accounts.markExpired(fixtureServerId);
      expect(relayCredentialFor(accounts, serverId: fixtureServerId), isNull);
      final none = JellyfinAccounts(store: MemoryJellyfinStore());
      await none.ensureLoaded(validate: false);
      expect(relayCredentialFor(none), isNull);
    });
  });

  group('progress', () {
    late JellyfinAccounts accounts;
    late DateTime now;
    late JellyfinProgressReporter reporter;
    final errors = <Object>[];
    var unauthorized = 0;

    setUp(() async {
      (accounts, _) = await linkedAccounts(http: playbackFake());
      now = DateTime(2026, 1, 1, 20);
      errors.clear();
      unauthorized = 0;
      reporter = JellyfinProgressReporter(
        client: accounts.clientFor(fixtureServerId)!,
        itemId: episodeId,
        source: fixtureSource(),
        playSessionId: playSessionId,
        clock: () => now,
        onError: errors.add,
        onUnauthorized: () => unauthorized++,
      );
    });

    Future<void> idle() => reporter.stop(const PlayerSnapshot(position: 0, paused: true))
        .then((_) {});

    test('Playing, Progress every 10 s and on pause / seek / track change, Stopped', () async {
      // English audio (mpv aid 2 = Jellyfin index 2), English full subs (sid 1 = 3).
      reporter.start(const PlayerSnapshot(position: 0, paused: true, aid: 2, sid: 1));
      void at(int secs, double pos, {bool paused = false, int? aid = 2, int? sid = 1}) {
        now = DateTime(2026, 1, 1, 20).add(Duration(seconds: secs));
        reporter.update(PlayerSnapshot(position: pos, paused: paused, aid: aid, sid: sid));
      }

      at(1, 0); // resume -> Progress
      at(2, 1);
      at(5, 4); // nothing due
      at(11, 10); // 10 s since the last one
      at(12, 11, paused: true); // pause
      at(13, 11, paused: true);
      at(14, 300, paused: true); // seek
      at(15, 300, paused: true, sid: null); // subtitles off
      await reporter.stop(const PlayerSnapshot(position: 300.5, paused: true, aid: 2));

      expect(reports.map((r) => r.path.split('/').last), [
        'Playing',
        'Progress', // resumed
        'Progress', // 10 s
        'Progress', // paused
        'Progress', // seek
        'Progress', // track change
        'Stopped',
      ]);
      final playing = reports.first.body;
      expect(playing['ItemId'], episodeId);
      expect(playing['MediaSourceId'], episodeId);
      expect(playing['PlaySessionId'], playSessionId);
      expect(playing['PlayMethod'], 'DirectPlay');
      expect(playing['IsPaused'], isTrue);
      expect(playing['AudioStreamIndex'], 2);
      expect(playing['SubtitleStreamIndex'], 3);
      expect(reports[2].body['PositionTicks'], 10 * jellyfinTicksPerSecond);
      expect(reports[3].body['IsPaused'], isTrue);
      expect(reports[4].body['PositionTicks'], 300 * jellyfinTicksPerSecond);
      expect(reports[5].body['SubtitleStreamIndex'], -1);
      expect(reports.last.body, {
        'ItemId': episodeId,
        'MediaSourceId': episodeId,
        'PlaySessionId': playSessionId,
        'PositionTicks': 3005000000,
      });
      expect(errors, isEmpty);
    });

    test('played to the end, then seeked back: a fresh Playing', () async {
      reporter.start(const PlayerSnapshot(position: 0, paused: false));
      await reporter.stop(const PlayerSnapshot(position: 1440, paused: true));
      expect(reporter.active, isFalse);
      reporter.update(const PlayerSnapshot(position: 1440, paused: true));
      reporter.start(const PlayerSnapshot(position: 600, paused: false));
      await idle();
      expect(reports.map((r) => r.path.split('/').last), ['Playing', 'Stopped', 'Playing', 'Stopped']);
    });

    test('failures are handed on and never throw; a 401 ends reporting', () async {
      final fake = playbackFake()
        ..on('POST', '/Sessions/Playing/Progress', (_, _) => const JellyfinHttpResponse(500, ''));
      (accounts, _) = await linkedAccounts(http: fake);
      final r = JellyfinProgressReporter(
        client: accounts.clientFor(fixtureServerId)!,
        itemId: episodeId,
        source: fixtureSource(),
        playSessionId: playSessionId,
        clock: () => now,
        onError: errors.add,
        onUnauthorized: () => unauthorized++,
      );
      r.start(const PlayerSnapshot(position: 0, paused: false));
      r.update(const PlayerSnapshot(position: 0, paused: true));
      await r.stop(const PlayerSnapshot(position: 1, paused: true));
      expect(errors, hasLength(1));
      expect(unauthorized, 0);
      expect(reports.map((r) => r.path.split('/').last), ['Playing', 'Stopped']);

      fake.on('POST', '/Sessions/Playing', (_, _) => const JellyfinHttpResponse(401, ''));
      reports.clear();
      r.start(const PlayerSnapshot(position: 0, paused: false));
      r.update(const PlayerSnapshot(position: 0, paused: true));
      await r.stop(const PlayerSnapshot(position: 1, paused: true));
      expect(unauthorized, 1);
      expect(reports, isEmpty, reason: 'nothing after the 401');
      expect(r.active, isFalse);
    });
  });

  group('episodes', () {
    test('neighbours of an episode with the clicker\'s account', () async {
      final (accounts, _) = await linkedAccounts(http: playbackFake());
      final plan = await resolveJellyfinRef(accounts, episodeRef, relay: false, relayUrl: null)
          as OwnPlay;
      final around = await findAdjacentEpisodes(plan);
      expect(around.previous, isNull, reason: 'S1E6 is first in the fixture');
      expect(around.next!.item.id, nextEpisodeId);
      expect(around.next!.label, 'S1E7 Battle with the Heroes');
      final media = mediaForPick(around.next!.pick);
      expect(media.jellyfin!.itemId, nextEpisodeId);
      expect(media.jellyfin!.subtitle, 'Black Summoner · S1E7');
    });

    test('the floating prompt starts two minutes before the end', () {
      expect(nextPromptStart(null, const Duration(minutes: 24)), const Duration(minutes: 22));
      expect(nextPromptStart(null, const Duration(seconds: 90)), Duration.zero);
    });

    test('one auto-advance swapper: the lowest id among members with their own account', () {
      final members = [
        member('m10', 'Ann', jf: {fixtureServerId: true}),
        member('m2', 'Bob', jf: {fixtureServerId: true}),
        member('m1', 'Guest', jf: {fixtureServerId: false}),
        member('m0', 'Old', jf: {fixtureServerId: true}, stale: true),
        member('m3', 'Fresh'),
      ];
      expect(autoAdvanceSwapper(members, fixtureServerId), 'm2');
      expect(autoAdvanceSwapper(members.reversed.toList(), fixtureServerId), 'm2',
          reason: 'order does not matter: every client agrees');
      expect(autoAdvanceSwapper(members, 'other-server'), isNull);
      expect(compareMemberIds('m9', 'm10'), lessThan(0));
    });

    test('member badge: via host only for relay viewers of the current item', () {
      expect(viaHostOf(member('m1', 'G', jf: {fixtureServerId: false}), episodeRef), isTrue);
      expect(viaHostOf(member('m1', 'G', jf: {fixtureServerId: true}), episodeRef), isFalse);
      expect(viaHostOf(member('m1', 'G'), episodeRef), isFalse);
      expect(viaHostOf(member('m1', 'G', jf: {fixtureServerId: false}), null), isFalse);
    });
  });

  group('track carry-over', () {
    test('choice from Jellyfin streams carries to the next episode by traits', () {
      final source = fixtureSource();
      // mpv aid 2 / sid 2: English eac3 audio, "English (Signs)" subtitles.
      final choice = TrackChoice.of(aid: 2, sid: 2, source: source);
      expect(choice.audio!.language, 'eng');
      expect(choice.subtitle!.title, 'English (Signs) [Generated]');
      // Next file: same tracks in another order (English audio first).
      final next = JellyfinMediaSource(id: 'n', mediaStreams: [
        const JellyfinMediaStream(index: 0, type: JellyfinStreamType.video),
        const JellyfinMediaStream(
            index: 1, type: JellyfinStreamType.audio, language: 'eng', title: 'English', codec: 'eac3', channels: 2),
        const JellyfinMediaStream(
            index: 2, type: JellyfinStreamType.audio, language: 'jpn', title: 'Japanese', codec: 'eac3', channels: 2),
        const JellyfinMediaStream(
            index: 3, type: JellyfinStreamType.subtitle, language: 'eng', title: 'English (Full Subtitle)'),
        const JellyfinMediaStream(
            index: 4, type: JellyfinStreamType.subtitle, language: 'eng', title: 'English (Signs)'),
      ]);
      final pick = chooseTracks(choice, source: next);
      expect(pick.aid, 1, reason: 'English is mpv aid 1 there');
      expect(pick.sid, 2, reason: 'Signs, not Full');
      expect(pick.subtitlesOff, isFalse);
      final off = chooseTracks(TrackChoice.of(aid: 1, sid: null, source: source), source: next);
      expect(off.aid, 2, reason: 'Japanese');
      expect(off.subtitlesOff, isTrue);
    });

    test('relay viewers match on mpv\'s track list', () {
      const tracks = [
        MpvTrack(id: 1, type: JellyfinStreamType.audio, language: 'jpn', title: 'Japanese', codec: 'aac'),
        MpvTrack(id: 2, type: JellyfinStreamType.audio, language: 'eng', title: 'English', codec: 'aac'),
        MpvTrack(id: 1, type: JellyfinStreamType.subtitle, language: 'eng', title: 'Signs'),
        MpvTrack(id: 2, type: JellyfinStreamType.subtitle, language: 'eng', title: 'Full'),
      ];
      final choice = TrackChoice.of(aid: 2, sid: 2, tracks: tracks);
      expect(choice.audio!.title, 'English');
      final pick = chooseTracks(choice, tracks: const [
        MpvTrack(id: 1, type: JellyfinStreamType.audio, language: 'en', title: 'English'),
        MpvTrack(id: 2, type: JellyfinStreamType.audio, language: 'ja', title: 'Japanese'),
        MpvTrack(id: 1, type: JellyfinStreamType.subtitle, language: 'en', title: 'Full Subtitles'),
        MpvTrack(id: 2, type: JellyfinStreamType.subtitle, language: 'en', title: 'Signs & Songs'),
      ]);
      expect(pick.aid, 1);
      expect(pick.sid, 1);
    });

    test('kept per series with a global fallback', () async {
      final prefs = TrackPrefs(store: MemoryJellyfinStore());
      expect(await prefs.load(seriesId: 'a'), isNull);
      final eng = TrackChoice.of(aid: 2, sid: null, source: fixtureSource());
      await prefs.save(eng, seriesId: 'a');
      final jpn = TrackChoice.of(aid: 1, sid: 1, source: fixtureSource());
      await prefs.save(jpn, seriesId: 'b');
      expect((await prefs.load(seriesId: 'a'))!.audio!.language, 'eng');
      expect((await prefs.load(seriesId: 'a'))!.subtitlesOff, isTrue);
      expect((await prefs.load(seriesId: 'b'))!.audio!.language, 'jpn');
      expect((await prefs.load(seriesId: 'new'))!.audio!.language, 'jpn', reason: 'global = last');
      expect((await prefs.load())!.subtitle!.title, 'English (Full Subtitle)');
    });
  });

  group('browser location', () {
    test('route stacks round-trip and survive in the Jellyfin box', () async {
      final (accounts, _) = await linkedAccounts();
      final stack = [
        const HomeRoute(),
        const LibraryRoute(
            JellyfinItem(id: 'lib1', name: 'Shows', type: 'CollectionFolder', collectionType: 'tvshows')),
        SeriesRoute(const JellyfinItem(id: seriesId, name: 'Black Summoner', type: 'Series'),
            seasonId: seasonId),
      ];
      await accounts.saveBrowseLocation(fixtureServerId, encodeBrowseStack(stack));
      final back = decodeBrowseStack(accounts.browseLocation(fixtureServerId))!;
      expect(back.map((r) => r.key), stack.map((r) => r.key));
      expect((back[1] as LibraryRoute).folder.collectionType, 'tvshows');
      expect((back[2] as SeriesRoute).seasonId, seasonId);
      expect(decodeBrowseStack('junk'), isNull);
    });

    testWidgets('the browser reopens where it was, per server', (tester) async {
      await setSize(tester, const Size(1600, 1000));
      final (accounts, _) = await linkedAccounts();
      await accounts.saveBrowseLocation(fixtureServerId, encodeBrowseStack([
        const HomeRoute(),
        SeriesRoute(const JellyfinItem(id: arifuretaId, name: 'Arifureta', type: 'Series'),
            seasonId: season2Id),
      ]));
      final c = MediaPickerController(source: MediaKind.jellyfin);
      addTearDown(c.dispose);
      await tester.pumpWidget(app(MediaPicker(controller: c, jellyfin: accounts)));
      await settle(tester);
      final s2 = tester.widget<ChoiceChip>(find.byKey(const ValueKey('season-$season2Id')));
      expect(s2.selected, isTrue);
      // Back to Home is remembered too.
      await tester.tap(find.byTooltip('Back (Esc)'));
      await settle(tester);
      expect(decodeBrowseStack(accounts.browseLocation(fixtureServerId))!.map((r) => r.key), ['home']);
    });
  });

  group('session widgets', () {
    final next = EpisodeLink(
        const JellyfinItem(
            id: nextEpisodeId, name: 'Battle with the Heroes', type: 'Episode',
            parentIndexNumber: 1, indexNumber: 7),
        const JellyfinMedia(
            serverId: fixtureServerId, baseUrl: 'b', itemId: nextEpisodeId, title: 'Battle with the Heroes'));

    testWidgets('next / previous buttons: tooltip, hidden without an episode', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(app(Row(children: [
        EpisodeSkipButton(episode: null, next: false, onPressed: () {}),
        EpisodeSkipButton(episode: next, next: true, onPressed: () => pressed++),
      ])));
      expect(find.byKey(const ValueKey('episode-previous')), findsNothing);
      expect(find.byTooltip('Next: S1E7 Battle with the Heroes  (> or Shift+N)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('episode-next')));
      expect(pressed, 1);
    });

    testWidgets('end card: Next prompt, countdown with Cancel', (tester) async {
      var play = 0, cancel = 0;
      await tester.pumpWidget(app(EndOfEpisodeCard(
          next: next, countdown: null, onPlayNow: () => play++, onCancel: () => cancel++)));
      expect(find.text('Next: S1E7 Battle with the Heroes'), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-advance-cancel')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('play-next')));
      expect(play, 1);

      await tester.pumpWidget(app(EndOfEpisodeCard(
          next: next,
          countdown: AutoAdvance(mediaId: 3, secondsLeft: 7, next: next, swapper: false),
          onPlayNow: () => play++,
          onCancel: () => cancel++)));
      expect(find.text('Next episode in 7 s'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auto-advance-cancel')));
      expect(cancel, 1);
    });

    testWidgets('next-episode pill: faint at rest, lit on hover, click puts it up', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(app(Align(child: NextEpisodePill(episode: next, onPressed: () => pressed++))));
      double opacity() => tester.widget<AnimatedOpacity>(find.descendant(
          of: find.byType(NextEpisodePill), matching: find.byType(AnimatedOpacity))).opacity;
      expect(opacity(), lessThan(0.5));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('next-episode-pill'))));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      await tester.tap(find.byKey(const ValueKey('next-episode-pill')));
      expect(pressed, 1);
    });

    testWidgets('blocked card offers to link an account', (tester) async {
      var link = 0;
      await tester.pumpWidget(app(JellyfinBlockedCard(
          blocked: const BlockedPlay(serverId: fixtureServerId, serverName: 'Example Server'),
          onLinkAccount: () => link++,
          onRetry: () {})));
      expect(find.text('No Jellyfin account here for Example Server, and nobody is passing it on'),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('link-jellyfin-account')));
      expect(link, 1);
    });

    testWidgets('swap panel: the shared picker, File for everyone, link relay choice', (tester) async {
      await setSize(tester, const Size(1400, 900));
      final (accounts, _) = await linkedAccounts();
      final c = MediaPickerController(source: MediaKind.link);
      addTearDown(c.dispose);
      final swapped = <PickedMedia>[];
      var closed = 0;
      await tester.pumpWidget(app(SwapPanel(
        controller: c,
        accounts: accounts,
        isHost: false,
        onSwap: (m) async {
          swapped.add(m);
          return null;
        },
        onClose: () => closed++,
      )));
      await settle(tester);
      // A guest's file goes through the server's relay.
      expect(find.text('File'), findsOneWidget);
      expect(find.text('Jellyfin'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'https://cdn.example/movie.mkv');
      await tester.pump();
      await tester.tap(find.text('Through me'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('swap-go')));
      await settle(tester);
      expect(swapped, [const LinkMedia('https://cdn.example/movie.mkv', relay: LinkRelay.me)]);
      expect(closed, 1);

      // The Jellyfin source is the library browser; a pick goes up as is.
      await tester.tap(find.text('Jellyfin'));
      await settle(tester);
      expect(find.byKey(const ValueKey('media-jellyfin')), findsOneWidget);

      await tester.pumpWidget(app(SwapPanel(
          controller: c, accounts: accounts, isHost: true, onSwap: (_) async => 'x', onClose: () {})));
      await settle(tester);
      expect(find.text('File'), findsOneWidget);
      await tester.tap(find.text('File'));
      await settle(tester);
      expect(find.text('Friends stream it from your computer.'), findsOneWidget);
    });

    testWidgets('swap panel opens on the series of the episode playing, episode highlighted',
        (tester) async {
      await setSize(tester, const Size(1600, 1000));
      final (accounts, _) = await linkedAccounts();
      // Somewhere else remembered: the series start wins.
      await accounts.saveBrowseLocation(fixtureServerId, encodeBrowseStack([const HomeRoute()]));
      final eps = (jsonDecode(jellyfinFixture('episodes')) as Map)['Items'] as List;
      final ep = JellyfinItem.fromJson((eps.firstWhere((e) => e['SeasonId'] == season2Id) as Map)
          .cast<String, dynamic>());
      final pick = pickForRef(accounts,
          JellyfinRef(serverId: fixtureServerId, itemId: ep.id, title: ep.name))!;
      final c = MediaPickerController(jellyfin: pick, source: MediaKind.jellyfin);
      addTearDown(c.dispose);
      await tester.pumpWidget(app(SwapPanel(
        controller: c,
        accounts: accounts,
        isHost: false,
        jellyfinStart: BrowseStart.seriesOf(fixtureServerId, ep),
        onSwap: (_) async => null,
        onClose: () {},
      )));
      await settle(tester, 10);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('season-$season2Id'))).selected,
          isTrue);
      expect(find.text('Put up: ${pick.label}'), findsOneWidget);
      final row = tester.widget<Material>(find
          .ancestor(of: find.byKey(ValueKey('episode-${ep.id}')), matching: find.byType(Material))
          .first);
      expect((row.shape as RoundedRectangleBorder).side.color, isNot(Colors.transparent),
          reason: 'the episode playing is highlighted');
    });
  });
}
