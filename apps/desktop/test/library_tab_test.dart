import 'dart:convert';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/jellyfin/browse_scope.dart';
import 'package:starsync/src/jellyfin/details_panel.dart';
import 'package:starsync/src/screens/home/media_picker.dart';
import 'package:starsync/src/shell/library_link.dart';
import 'package:starsync/src/shell/library_tab.dart';

import 'jellyfin_accounts_test.dart'
    show FakeJellyfin, lanternfallId, fixtureServerId, jellyfinFixture, linkedAccounts, season2Id;
import 'jellyfin_browser_test.dart' show fixtureNow, settle;

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

const bsSeries = '66d14ad0b34a4a6d92109a8f2f065259';
const bsEpisode = 'a43e1cfa5013da4ea9323c2ebdc22c3c';
const bsSeason = '5f495475ada7f05fecbfec2d30e34233';
const s2e2 = '7d41e9954ee66669fd5135b93095ec00';

JellyfinHttpResponse page(List<Object> items) =>
    JellyfinHttpResponse(200, jsonEncode({'Items': items, 'TotalRecordCount': items.length}));

/// The fake server, plus: Lanternfall in "Latest" (2 new), Copper Warden's
/// series, season and episode, and watched-state calls.
FakeJellyfin libraryFake() {
  final fake = FakeJellyfin();
  final lanternfall = jsonDecode(jellyfinFixture('series_detail')) as Map<String, dynamic>;
  // Added when it aired: not a re-release.
  fake.on('GET', '/Items/Latest', (_, _) => JellyfinHttpResponse(200, jsonEncode([
        {...lanternfall, 'ChildCount': 2, 'DateCreated': lanternfall['PremiereDate']},
      ])));
  final episode = jsonDecode(jellyfinFixture('episode_detail')) as Map<String, dynamic>;
  fake.on('GET', '/Items/$bsSeries',
      (_, _) => JellyfinHttpResponse(200, jsonEncode({'Id': bsSeries, 'Name': 'Copper Warden', 'Type': 'Series'})));
  fake.on('GET', '/Shows/$bsSeries/Seasons', (_, _) => page([
        {'Id': bsSeason, 'Name': 'Season 1', 'Type': 'Season', 'IndexNumber': 1, 'SeriesId': bsSeries},
      ]));
  fake.on('GET', '/Shows/$bsSeries/Episodes', (_, _) => page([episode]));
  // Lanternfall's episodes load on their own too (a pick restored by id).
  for (final e in (jsonDecode(jellyfinFixture('episodes')) as Map)['Items'] as List) {
    fake.on('GET', '/Items/${e['Id']}', (_, _) => JellyfinHttpResponse(200, jsonEncode(e)));
  }
  const ud = '{"Played":true,"PlaybackPositionTicks":0,"PlayCount":1}';
  fake.on('POST', '/UserPlayedItems/$bsEpisode', (_, _) => const JellyfinHttpResponse(200, ud));
  return fake;
}

class FilesStub extends StatelessWidget {
  final bool alone, relayed;
  final Future<String?> Function(String path) onPlay;
  const FilesStub({super.key, required this.alone, required this.relayed, required this.onPlay});

  @override
  Widget build(BuildContext context) => Column(children: [
        Text('files alone=$alone relayed=$relayed'),
        TextButton(
          key: const ValueKey('stub-play'),
          onPressed: () => onPlay('/v/a.mkv'),
          child: const Text('play'),
        ),
      ]);
}

class Harness {
  final MediaPickerController controller;
  final JellyfinAccounts accounts;
  final FakeJellyfin fake;
  final put = <PickedMedia>[];
  /// Up next adds (with [pumpLibrary]'s queue): the pick and whether next.
  final queued = <(PickedMedia, bool)>[];
  final recents = RecentLinks(read: () async => null, write: (_) async {});
  Harness(this.controller, this.accounts, this.fake);
}

/// The Library tab on the fake server; [queue]: in a server (Up next
/// adds recorded in [Harness.queued]).
Future<Harness> pumpLibrary(
  WidgetTester tester,
  Size size, {
  bool alone = false,
  bool isHost = false,
  bool queue = false,
  MediaKind source = MediaKind.jellyfin,
  Harness? reuse,
  BrowseStart? start,
  JellyfinMedia? pick,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final Harness h;
  if (reuse != null) {
    h = reuse;
  } else {
    final (accounts, fake) = await linkedAccounts(http: libraryFake());
    final c = MediaPickerController(source: source, jellyfin: pick);
    if (pick != null) c.source = source;
    addTearDown(c.dispose);
    h = Harness(c, accounts, fake);
  }
  await tester.pumpWidget(scoped(_graph, MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: LibraryTab(
        // A new tab each time, like the shell after "Change video".
        key: UniqueKey(),
        controller: h.controller,
        accounts: h.accounts,
        alone: alone,
        isHost: isHost,
        jellyfinStart: start,
        recentLinks: h.recents,
        now: () => fixtureNow,
        probe: (url) async => url.endsWith('.mkv')
            ? LinkProbe.file(Uri.parse(url), 1)
            : url.contains('bilibili')
                ? LinkProbe.page(Uri.parse(url), ytDlpError: 'HTTP Error 412: Precondition Failed')
                : LinkProbe.page(Uri.parse(url), info: const YtDlpInfo(title: 'A video', uploader: 'Chan')),
        filesBuilder: (context, {required alone, required relayed, required onPlay, nowPlayingPath}) =>
            FilesStub(alone: alone, relayed: relayed, onPlay: onPlay),
        onPutUp: (m) async {
          h.put.add(m);
          return null;
        },
        onAddToQueue: queue
            ? (m, {next = false}) async {
                h.queued.add((m, next));
                return null;
              }
            : null,
      ),
    ),
  )));
  await settle(tester, 10);
  return h;
}

Finder lanternfallCard() => find.byKey(const ValueKey('card-$lanternfallId')).first;

Future<void> doubleTap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(f);
  await settle(tester, 10);
}

void main() {
  testWidgets('source switch fades through; library chips sit in the header', (tester) async {
    final h = await pumpLibrary(tester, const Size(1600, 1000));
    expect(find.byKey(const ValueKey('library-8047582a00c2f6d3fedf63f4475bc929')), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    await tester.tap(find.text('Link'));
    await tester.pump(const Duration(milliseconds: 60));
    // Fade through: the new view waits until the old one is gone.
    final incoming = tester.widget<FadeTransition>(
        find.ancestor(of: find.text('Watch from a link'), matching: find.byType(FadeTransition)).first);
    expect(incoming.opacity.value, 0);
    await settle(tester, 10);
    expect(find.text('Continue'), findsNothing);
    expect(find.text('Watch from a link'), findsOneWidget);
    expect(h.controller.source, MediaKind.link);

    await tester.tap(find.text('Files'));
    await settle(tester, 10);
    expect(find.text('files alone=false relayed=true'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stub-play')));
    await settle(tester);
    expect(h.put, [const FileMedia('/v/a.mkv')]);

    await tester.tap(find.text('Jellyfin'));
    await settle(tester, 10);
    // A chip opens its library; again goes back home.
    await tester.tap(find.byKey(const ValueKey('library-8047582a00c2f6d3fedf63f4475bc929')));
    await settle(tester, 10);
    expect(find.text('218 items'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-8047582a00c2f6d3fedf63f4475bc929')));
    await settle(tester, 10);
    expect(find.text('Continue'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('select a card: the panel slides in; episodes pick what goes up', (tester) async {
    final h = await pumpLibrary(tester, const Size(1600, 1000));
    expect(find.byKey(const ValueKey('jf-details')), findsNothing);
    await tester.tap(lanternfallCard());
    await settle(tester, 10);
    final panel = find.byKey(const ValueKey('jf-details'));
    expect(panel, findsOneWidget);
    // Docked at the right, 400 px.
    expect(tester.getSize(panel).width, detailsPanelWidth);
    expect(tester.getTopLeft(panel).dx, 1600 - detailsPanelWidth);
    expect(h.controller.selected!.itemId, lanternfallId);
    // Next up is S2E4; the list is its season.
    expect(find.text('Put it up · S2E4'), findsOneWidget);
    expect(find.byKey(const ValueKey('details-episode-$s2e2')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('details-episode-$s2e2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('details-episode-$s2e2')));
    await settle(tester);
    expect(find.text('Put it up · S2E2'), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('details-list')), const Offset(0, 2000));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('details-put-up')));
    await settle(tester);
    final m = h.put.single as JellyfinMedia;
    expect((m.serverId, m.itemId, m.title), (fixtureServerId, s2e2, 'Ember Glow'));
    expect(m.subtitle, endsWith('S2E2'));

    // Another card: the panel's content cross-fades.
    await tester.tap(find.byKey(const ValueKey('card-$bsEpisode')));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text("Lanternfall: The Mapmaker's Long Road"), findsWidgets,
        reason: 'the old panel is still fading out');
    await settle(tester, 10);
    expect(find.text('Put it up · S2E2'), findsNothing);
    expect(find.text('Put it up · S1E6'), findsOneWidget);

    // Close: the panel slides away and the selection is gone.
    await tester.tap(find.byKey(const ValueKey('details-close')));
    await settle(tester, 10);
    expect(h.controller.selected, isNull);
    expect(tester.getSize(find.byType(ClipRect).first).width, isNot(detailsPanelWidth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('double-click a card puts it up (a series: its next episode)', (tester) async {
    final h = await pumpLibrary(tester, const Size(1600, 1000));
    await doubleTap(tester, lanternfallCard());
    final m = h.put.single as JellyfinMedia;
    expect(m.itemId, '69daedd572ac0d1075a25488be3b09bf'); // S2E4
    expect(h.controller.selected!.itemId, lanternfallId);
    await doubleTap(tester, find.byKey(const ValueKey('card-$bsEpisode')));
    expect((h.put.last as JellyfinMedia).itemId, bsEpisode);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mark watched and remove from Continue reload the rows', (tester) async {
    final h = await pumpLibrary(tester, const Size(1600, 1000));
    final row = find.byKey(const ValueKey('row-continue'));
    expect(find.descendant(of: row, matching: find.text('Copper Warden')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('card-$bsEpisode')));
    await settle(tester, 10);
    expect(find.text('Put it up · S1E6'), findsOneWidget);
    final resumes = h.fake.count('GET', '/UserItems/Resume');

    await tester.tap(find.byKey(const ValueKey('details-markWatched')));
    await settle(tester, 10);
    expect(h.fake.count('POST', '/UserPlayedItems/$bsEpisode'), 1);
    expect(h.fake.count('GET', '/UserItems/Resume'), greaterThan(resumes), reason: 'rows reload');

    expect(find.byKey(const ValueKey('details-removeFromContinue')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('details-removeFromContinue')));
    await settle(tester, 10);
    expect(h.accounts.continueDismissed(fixtureServerId), contains(bsSeries));
    expect(find.descendant(of: row, matching: find.text('Copper Warden')), findsNothing);
    expect(find.descendant(of: row, matching: find.text("Milo's Curious Voyage")), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nobody else in the server (D9): buttons say Play and put up; a link goes direct, no relay modes', (tester) async {
    final h = await pumpLibrary(tester, const Size(1600, 1000), alone: true);
    await tester.tap(lanternfallCard());
    await settle(tester, 10);
    final go = find.byKey(const ValueKey('details-put-up'));
    expect(find.descendant(of: go, matching: find.textContaining('Play')), findsOneWidget);
    await tester.tap(go);
    await settle(tester, 10);
    expect(h.put.single, isA<JellyfinMedia>());

    await tester.tap(find.text('Link'));
    await settle(tester, 10);
    h.controller.linkRelay = LinkRelay.me;
    await tester.enterText(find.byKey(const ValueKey('link-field')), 'https://cdn.example/a.mkv');
    await settle(tester, 10);
    expect(find.text('How the others get it'), findsNothing);
    expect(find.text(alonePlayHint), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('link-put-up')));
    await settle(tester, 10);
    expect(h.put.last, const LinkMedia('https://cdn.example/a.mkv'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('link: preview, how the others get it, put up, recent links', (tester) async {
    final h = await pumpLibrary(tester, const Size(1400, 1000), source: MediaKind.link);
    expect(find.text('How the others get it'), findsOneWidget);
    const url = 'https://www.youtube.com/watch?v=abc';
    await tester.enterText(find.byKey(const ValueKey('link-field')), url);
    await settle(tester, 10);
    expect(find.descendant(of: find.byKey(const ValueKey('link-preview')), matching: find.text('A video')),
        findsOneWidget);
    expect(find.text('youtube.com · Chan'), findsOneWidget);
    // Through me by default; the other two behind "Other ways".
    expect(h.controller.linkRelay, LinkRelay.me);
    expect(find.byKey(const ValueKey('link-mode-direct')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('link-other-ways')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('link-mode-server')));
    await settle(tester);
    expect(h.controller.linkRelay, LinkRelay.server);
    await tester.tap(find.byKey(const ValueKey('link-mode-me')));
    await settle(tester);
    expect(h.controller.linkRelay, LinkRelay.me);
    expect(find.byKey(const ValueKey('link-mode-direct')), findsOneWidget, reason: 'stays open until closed');
    expect(find.text(linkRelayHelp(LinkRelay.me)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('link-put-up')));
    await settle(tester, 10);
    expect(h.put, [const LinkMedia(url, relay: LinkRelay.me)]);
    expect(h.recents.links.value.single.title, 'A video');
    expect(find.byKey(const ValueKey('recent-link-$url')), findsOneWidget);

    // A recent link refills the field.
    await tester.enterText(find.byKey(const ValueKey('link-field')), '');
    await settle(tester, 10);
    await tester.tap(find.byKey(const ValueKey('recent-link-$url')));
    await settle(tester, 10);
    expect(h.controller.link.text, url);

    // A link the probe cannot open: the reason, not put up; "anyway" is.
    const bili = 'https://www.bilibili.com/video/BV1';
    await tester.enterText(find.byKey(const ValueKey('link-field')), bili);
    await settle(tester, 10);
    await tester.tap(find.byKey(const ValueKey('link-put-up')));
    await settle(tester, 10);
    expect(find.text(needsCookiesText), findsOneWidget);
    expect(h.put, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('link-put-up-anyway')));
    await settle(tester, 10);
    expect((h.put.last as LinkMedia).anyway, isTrue);

    expect(tester.takeException(), isNull);
  });

  testWidgets("link: the preview's right-click is the recent link's menu", (tester) async {
    final h = await pumpLibrary(tester, const Size(1400, 1000), source: MediaKind.link, queue: true);
    const url = 'https://www.youtube.com/watch?v=abc';
    await tester.enterText(find.byKey(const ValueKey('link-field')), url);
    await settle(tester, 10);
    List<String> rows() => [
          for (final e in find
              .descendant(of: find.byKey(const ValueKey('app-menu')), matching: find.byType(Text))
              .evaluate())
            (e.widget as Text).data ?? '',
        ];
    await tester.tap(find.byKey(const ValueKey('link-preview')), buttons: kSecondaryButton);
    await settle(tester, 4);
    final preview = rows();
    expect(preview, ['Put it up', 'Add to queue', 'Play next', 'Copy link', 'Copy title', 'Open in browser']);
    await tester.tap(find.text('Play next'));
    await settle(tester, 10);
    expect(h.queued.single.$2, isTrue);
    await tester.tap(find.byKey(const ValueKey('link-put-up')));
    await settle(tester, 10);
    await tester.tap(find.byKey(const ValueKey('recent-link-$url')), buttons: kSecondaryButton);
    await settle(tester, 4);
    expect(rows(), preview);
    expect(tester.takeException(), isNull);
  });

  testWidgets('your server: files stream from here; now-playing file passes through', (tester) async {
    await pumpLibrary(tester, const Size(1400, 900), source: MediaKind.file, isHost: true);
    expect(find.text('files alone=false relayed=false'), findsOneWidget);
  });

  testWidgets('the last pick comes back selected; "Change video" opens on its series', (tester) async {
    final (accounts, _) = await linkedAccounts(http: libraryFake());
    const pick = JellyfinMedia(
        serverId: fixtureServerId,
        baseUrl: 'https://example.invalid',
        itemId: bsEpisode,
        title: 'Bread and Bandits and Knights',
        subtitle: 'Copper Warden · S1E6');
    await accounts.rememberPick(pick);
    final c = MediaPickerController();
    addTearDown(c.dispose);
    await restoreLastPick(c, accounts, () => true);
    expect(c.selected!.itemId, bsEpisode);
    expect(c.source, MediaKind.jellyfin);
    final h = Harness(c, accounts, FakeJellyfin());
    await pumpLibrary(tester, const Size(1600, 1000), reuse: h, alone: true);
    expect(find.byKey(const ValueKey('jf-details')), findsOneWidget);
    expect(find.text('Copper Warden'), findsWidgets);

    // Change video: the series of the episode playing, its season chosen
    // and the episode highlighted.
    final eps = (jsonDecode(jellyfinFixture('episodes')) as Map)['Items'] as List;
    final ep = JellyfinItem.fromJson((eps.firstWhere((e) => e['SeasonId'] == season2Id) as Map)
        .cast<String, dynamic>());
    final h2 = await pumpLibrary(tester, const Size(1600, 1000),
        start: BrowseStart.seriesOf(fixtureServerId, ep),
        pick: JellyfinMedia(serverId: fixtureServerId, baseUrl: 'x', itemId: ep.id, title: ep.name));
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('season-$season2Id'))).selected, isTrue);
    final tile = tester.widget<Material>(find
        .ancestor(of: find.byKey(ValueKey('episode-${ep.id}')), matching: find.byType(Material))
        .first);
    expect((tile.shape as RoundedRectangleBorder).side.color, isNot(Colors.transparent));
    expect(find.text('Put it up · S2E1'), findsOneWidget);
    expect(h2.controller.selected!.itemId, ep.id);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(2560, 1080), Size(1100, 700), Size(900, 600)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}, panel open, every source',
        (tester) async {
      final h = await pumpLibrary(tester, size);
      expect(tester.takeException(), isNull);
      await tester.tap(lanternfallCard());
      await settle(tester, 10);
      expect(tester.takeException(), isNull);
      final panel = find.byKey(const ValueKey('jf-details'));
      expect(panel, findsOneWidget);
      // Under 1000 px the panel floats over the library at the right edge.
      expect(tester.getTopRight(panel).dx, size.width);
      h.controller.link.text = 'https://cdn.example/some/long/path/Movie.Name.2024.1080p.mkv';
      for (final s in [MediaKind.link, MediaKind.file, MediaKind.jellyfin]) {
        h.controller.source = s;
        await settle(tester, 10);
        expect(tester.takeException(), isNull, reason: '$s at $size');
      }
      h.controller.select(null);
      await settle(tester, 10);
      expect(tester.takeException(), isNull);
    });
  }
}
