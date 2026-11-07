import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/jellyfin/accounts.dart';
import 'package:starsync/src/jellyfin/accounts_panel.dart';
import 'package:starsync/src/jellyfin/browser.dart';
import 'package:starsync/src/jellyfin/browse_scope.dart';
import 'package:starsync/src/jellyfin/picker_source.dart';
import 'package:starsync/src/state/settings.dart';

import 'test_graph.dart';

import 'jellyfin_accounts_test.dart'
    show FakeJellyfin, lanternfallId, fixtureServerId, linkedAccounts, season2Id;

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

Future<void> setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget app(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
    );

/// Lets fake requests, debounces and image errors settle without waiting
/// on the progress spinners (pumpAndSettle would never return).
Future<void> settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pinned "now" for the Continue row (the fixtures were captured in
/// October 2026).
final fixtureNow = DateTime.utc(2026, 10, 8, 12);

/// What the browser reported: selections and put-ups.
class Picks {
  final selected = <JellyfinSelection>[];
  final putUp = <JellyfinSelection>[];
}

/// The browser on one linked fake server; clicks select, double-clicks put
/// up (both recorded), like the Library tab wires it.
Future<(Picks, JellyfinAccounts, FakeJellyfin, BrowseController)> pumpBrowser(
    WidgetTester tester, Size size) async {
  await setSize(tester, size);
  // Memory store + fake transport: no real IO, so no runAsync (futures
  // made there would resume outside the test's fake clock).
  final (accounts, fake) = await linkedAccounts();
  final controller = BrowseController(accounts, now: () => fixtureNow);
  addTearDown(controller.dispose);
  final picks = Picks();
  await tester.pumpWidget(scoped(_graph, app(StatefulBuilder(
    builder: (context, setState) => JellyfinBrowser(
      accounts: accounts,
      controller: controller,
      selected: picks.selected.lastOrNull,
      onSelect: (s) => setState(() => picks.selected.add(s)),
      onPutUp: picks.putUp.add,
    ),
  ))));
  await settle(tester);
  return (picks, accounts, fake, controller);
}

Future<void> openLanternfall(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('jf-search')), 'lanternfall');
  await settle(tester, 10);
  expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
  // Series cards select; the series page opens from the details panel or
  // a season card, here straight through the controller.
  await tester.tap(find.byKey(const ValueKey('card-$lanternfallId')));
  await settle(tester);
}

void main() {
  testWidgets('home: one Continue row (resume + next up per series), latest as series cards',
      (tester) async {
    final (_, _, fake, controller) = await pumpBrowser(tester, const Size(1600, 2400));
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Continue watching'), findsNothing);
    expect(find.text('Next up'), findsNothing);
    expect(find.text('Latest in Shows'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Movies'), findsOneWidget);
    final row = find.byKey(const ValueKey('row-continue'));
    // Milo and Copper Warden were watched yesterday; Copper Warden's
    // resume point is older than its last finished episode, so its next
    // up shows. Orchard Keeper (62 days) and the never-dated series drop out.
    expect(find.descendant(of: row, matching: find.text("Milo's Curious Voyage")), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Copper Warden')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('S1E6')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('The Quiet Orchard Keeper')),
        findsNothing);
    final milo = tester.getTopLeft(find.byKey(const ValueKey('card-3fd19bfe4ae0d540d0fc4f4f071d2cc4')));
    final bs = tester.getTopLeft(find.byKey(const ValueKey('card-a43e1cfa5013da4ea9323c2ebdc22c3c')));
    expect(milo.dx, lessThan(bs.dx));
    expect(controller.continueKeys, {'645ba801414bcb3e23e02cd6c3d73bfd', '66d14ad0b34a4a6d92109a8f2f065259'});
    // Latest asks for single items and groups them itself; grouped series
    // from the server say how many are new.
    final latest = fake.requests.lastWhere((r) => r.uri.path == '/Items/Latest').uri.queryParameters;
    expect(latest['groupItems'], 'false');
    expect(find.text('30 new'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards: click selects, double-click puts up; Show all opens newest first',
      (tester) async {
    final (picks, _, fake, controller) = await pumpBrowser(tester, const Size(1600, 1200));
    final card = find.byKey(const ValueKey('card-a43e1cfa5013da4ea9323c2ebdc22c3c'));
    await tester.tap(card);
    await tester.pump();
    expect(picks.selected.single.itemId, 'a43e1cfa5013da4ea9323c2ebdc22c3c');
    expect(picks.putUp, isEmpty);
    // Selected: outline and check.
    expect(find.descendant(of: card, matching: find.byIcon(Icons.check)), findsOneWidget);
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(card);
    await tester.pump();
    expect(picks.putUp.single.itemId, 'a43e1cfa5013da4ea9323c2ebdc22c3c');

    await tester.tap(find.byKey(const ValueKey('show-all-8047582a00c2f6d3fedf63f4475bc929')));
    await settle(tester);
    final q = fake.requests.lastWhere((r) => r.uri.path == '/Items').uri.queryParameters;
    expect(q['sortBy'], startsWith('DateCreated'));
    expect(q['sortOrder'], 'Descending');
    expect(find.widgetWithText(OutlinedButton, 'Date added'), findsOneWidget);
    expect((controller.stack.last as LibraryRoute).sort, 'added');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Latest: "Hide re-releases" hides items added long after airing', (tester) async {
    final fake = FakeJellyfin();
    fake.on('GET', '/Items/Latest', (_, _) => JellyfinHttpResponse(200, jsonEncode([
          {
            'Id': 'fresh', 'Name': 'Fresh', 'Type': 'Episode', 'SeriesId': 'sf', 'SeriesName': 'Fresh Show',
            'ParentIndexNumber': 1, 'IndexNumber': 1,
            'PremiereDate': '2026-10-01T00:00:00Z', 'DateCreated': '2026-10-02T00:00:00Z',
          },
          {
            'Id': 'old', 'Name': 'Old', 'Type': 'Episode', 'SeriesId': 'so', 'SeriesName': 'Old Show',
            'ParentIndexNumber': 1, 'IndexNumber': 4,
            'PremiereDate': '2012-10-01T00:00:00Z', 'DateCreated': '2026-10-02T00:00:00Z',
          },
        ])));
    await setSize(tester, const Size(1600, 1400));
    final (accounts, _) = await linkedAccounts(http: fake);
    final controller = BrowseController(accounts, now: () => fixtureNow);
    addTearDown(controller.dispose);
    AppSettings.instance.hideReReleases.value = true;
    addTearDown(() => AppSettings.instance.hideReReleases.value = true);
    await tester.pumpWidget(scoped(_graph, app(JellyfinBrowser(
        accounts: accounts, controller: controller, onSelect: (_) {}, onPutUp: (_) {}))));
    await settle(tester);
    expect(find.text('Fresh Show'), findsWidgets);
    expect(find.text('S1E1'), findsWidgets);
    expect(find.text('Old Show'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('latest-menu-8047582a00c2f6d3fedf63f4475bc929')));
    await settle(tester, 4);
    await tester.tap(find.byKey(const ValueKey('hide-rereleases')));
    await settle(tester, 4);
    expect(AppSettings.instance.hideReReleases.value, isFalse);
    expect(find.text('Old Show'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('series page: smart next button and episodes select, double-click puts up',
      (tester) async {
    final (picks, _, _, controller) = await pumpBrowser(tester, const Size(1600, 1000));
    await openLanternfall(tester);
    expect(picks.selected.last.itemId, lanternfallId);
    controller.open(SeriesRoute(const JellyfinItem(id: lanternfallId, name: 'Lanternfall', type: 'Series')));
    await settle(tester);
    // Opens on the season holding next up (S2E4).
    final s2 = tester.widget<ChoiceChip>(find.byKey(const ValueKey('season-$season2Id')));
    expect(s2.selected, isTrue);
    expect(find.text('1. Outlier'), findsOneWidget);
    expect(find.textContaining('Next up: S2E4'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Season 3'));
    await settle(tester);
    expect(find.text('1. Outlier'), findsNothing);
    expect(find.text('1. The Foxes Gather'), findsWidgets);

    await tester.tap(find.text('2. Drums of the Uprising').first);
    await tester.pump();
    final sel = picks.selected.last;
    expect(sel.serverId, fixtureServerId);
    expect(sel.item!.name, 'Drums of the Uprising');
    expect(picks.putUp, isEmpty);
    await tester.tap(find.text('2. Drums of the Uprising').first);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('2. Drums of the Uprising').first);
    await tester.pump();
    expect(picks.putUp.single.item!.name, 'Drums of the Uprising');

    // The smart button selects next up.
    await tester.tap(find.byKey(const ValueKey('series-next')));
    await tester.pump();
    expect(picks.selected.last.item!.episodeLabel, 'S2E4');
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard: / searches, Esc clears then goes back, arrows move', (tester) async {
    final (_, _, _, controller) = await pumpBrowser(tester, const Size(1600, 1000));
    final search = find.byKey(const ValueKey('jf-search'));

    // Focus a card, then arrow right moves to the next card.
    final first = find.byKey(const ValueKey('card-3fd19bfe4ae0d540d0fc4f4f071d2cc4'));
    Focus.of(tester.element(find.descendant(of: first, matching: find.byType(Column)).first))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final ink = FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<InkWell>()!;
    expect((ink.key as ValueKey<String>).value, 'card-a43e1cfa5013da4ea9323c2ebdc22c3c');

    // "/" jumps to search.
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
    await tester.pump();
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    await tester.enterText(search, 'lanternfall');
    await settle(tester, 10);
    expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('search-results')), findsNothing);
    expect(find.text('Continue'), findsOneWidget);

    // Into a series and back with Esc.
    controller.open(SeriesRoute(const JellyfinItem(id: lanternfallId, name: 'Lanternfall', type: 'Series')));
    await settle(tester);
    expect(find.byKey(const ValueKey('series-next')), findsOneWidget);
    expect(find.byKey(const ValueKey('crumb-0')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('series-next')), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library grid with sort and filters', (tester) async {
    final (_, _, fake, _) = await pumpBrowser(tester, const Size(1600, 1000));
    await tester.tap(find.widgetWithText(ActionChip, 'Shows'));
    await settle(tester);
    expect(find.text('218 items'), findsOneWidget);
    expect(find.text('Mira-chan Wants a Garden!'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('filter-unplayed')));
    await settle(tester);
    final q = fake.requests.lastWhere((r) => r.uri.path == '/Items').uri.queryParameters;
    expect(q['filters'], 'IsUnplayed');
    expect(q['includeItemTypes'], 'Series');
    expect(q['recursive'], 'true');
    await tester.tap(find.byKey(const ValueKey('library-sort')));
    await settle(tester, 2);
    await tester.tap(find.byKey(const ValueKey('sort-added')));
    await settle(tester);
    final q2 = fake.requests.lastWhere((r) => r.uri.path == '/Items').uri.queryParameters;
    expect(q2['sortBy'], startsWith('DateCreated'));
    expect(q2['sortOrder'], 'Descending');
    expect(tester.takeException(), isNull);
  });

  testWidgets('layouts: narrow and ultrawide fill rows with whole cards; rows scroll by drag',
      (tester) async {
    await pumpBrowser(tester, const Size(820, 700));
    expect(tester.takeException(), isNull);
    final narrowCard = tester.getSize(find.byKey(const ValueKey('card-3fd19bfe4ae0d540d0fc4f4f071d2cc4')));

    await pumpBrowser(tester, const Size(3440, 1440));
    expect(tester.takeException(), isNull);
    final wideCards = find.byWidgetPredicate((w) =>
        w is InkWell && w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('card-'));
    expect(wideCards.evaluate().length, greaterThan(10));
    expect(narrowCard.width, greaterThan(200));

    // A Latest row is an HScroll: a mouse drag moves it sideways.
    await setSize(tester, const Size(640, 1400));
    await settle(tester);
    final row = find.byKey(const ValueKey('latest-6ab4b24bc3b23421e6c86fe940a6a86f'));
    final list = find.descendant(of: row, matching: find.byType(Scrollable)).first;
    final before = tester.state<ScrollableState>(list).position.pixels;
    await tester.drag(list, const Offset(-300, 0), kind: PointerDeviceKind.mouse);
    await settle(tester, 4);
    expect(tester.state<ScrollableState>(list).position.pixels, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Integrations: Quick Connect shows the code, approve links, cancel stops',
      (tester) async {
    await setSize(tester, const Size(1200, 900));
    final fake = FakeJellyfin();
    final accounts = JellyfinAccounts(
        store: MemoryJellyfinStore(), httpFactory: () => fake, deviceName: 'Test');
    await accounts.ensureLoaded(validate: false);
    await tester.pumpWidget(scoped(_graph, app(SingleChildScrollView(
        child: JellyfinAccountsPanel(
            accounts: accounts, pollInterval: const Duration(milliseconds: 100))))));
    await tester.tap(find.byKey(const ValueKey('jf-add-server')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('jf-address')), 'example.invalid');
    await tester.tap(find.byKey(const ValueKey('jf-connect')));
    await settle(tester, 2);
    expect(find.text('Example Server'), findsOneWidget);
    expect(find.textContaining('Jellyfin 10.11.11'), findsOneWidget);

    // Cancel: the code goes away and polling stops.
    await tester.tap(find.byKey(const ValueKey('jf-quick-connect')));
    await settle(tester, 2);
    expect(find.text('437392'), findsOneWidget);
    expect(find.textContaining('Profile → Quick Connect'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('jf-qc-cancel')));
    await settle(tester, 4);
    final polls = fake.count('GET', '/QuickConnect/Connect');
    await settle(tester, 6);
    expect(fake.count('GET', '/QuickConnect/Connect'), polls);
    expect(find.text('437392'), findsNothing);

    // Again, and approve it.
    await tester.tap(find.byKey(const ValueKey('jf-quick-connect')));
    await settle(tester, 2);
    expect(find.text('437392'), findsOneWidget);
    fake.approved = true;
    await settle(tester, 6);
    expect(accounts.accounts.single.userName, 'testuser');
    expect(find.byKey(const ValueKey('jf-account-$fixtureServerId')), findsOneWidget);
    expect(find.text('testuser on Example Server'), findsOneWidget);
    expect(find.byKey(const ValueKey('jf-sign-in')), findsNothing);

    // Expired token: Reconnect shows, the account stays.
    accounts.markExpired(fixtureServerId);
    await tester.pump();
    expect(find.byKey(const ValueKey('jf-reconnect-$fixtureServerId')), findsOneWidget);

    // Sign out asks, revokes, unlinks.
    await tester.tap(find.byKey(const ValueKey('jf-sign-out-$fixtureServerId')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('jf-sign-out-confirm')));
    await settle(tester, 4);
    expect(fake.count('POST', '/Sessions/Logout'), 1);
    expect(accounts.isEmpty, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no linked server: the Jellyfin source offers sign-in inline', (tester) async {
    await setSize(tester, const Size(1200, 900));
    final accounts = JellyfinAccounts(store: MemoryJellyfinStore(), httpFactory: () => FakeJellyfin());
    await accounts.ensureLoaded(validate: false);
    await tester.pumpWidget(scoped(_graph, app(JellyfinPickerSource(
        accounts: accounts, onSelect: (_) {}, onPutUp: (_) {}, onOpenAccounts: () {}))));
    await tester.pump();
    expect(find.byKey(const ValueKey('jf-sign-in')), findsOneWidget);
    expect(find.text('Open Library & accounts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired account shows a reconnect banner in the browser', (tester) async {
    final (_, accounts, _, _) = await pumpBrowser(tester, const Size(1400, 900));
    accounts.markExpired(fixtureServerId);
    await tester.pump();
    expect(find.byKey(const ValueKey('jf-status-banner')), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.byType(JellyfinBrowser), findsOneWidget);
  });
}
