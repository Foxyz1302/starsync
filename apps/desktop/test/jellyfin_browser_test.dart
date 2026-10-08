import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/jellyfin/accounts.dart';
import 'package:watch_together/src/jellyfin/accounts_panel.dart';
import 'package:watch_together/src/jellyfin/browser.dart';
import 'package:watch_together/src/screens/home/media_picker.dart';
import 'package:watch_together/src/shell/library_tab.dart';

import 'jellyfin_accounts_test.dart'
    show FakeJellyfin, arifuretaId, fixtureServerId, linkedAccounts, season2Id;

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

/// MediaPicker on the Jellyfin source with one linked fake server.
Future<(MediaPickerController, JellyfinAccounts, FakeJellyfin)> pumpPicker(
    WidgetTester tester, Size size) async {
  await setSize(tester, size);
  // Memory store + fake transport: no real IO, so no runAsync (futures
  // made there would resume outside the test's fake clock).
  final (accounts, fake) = await linkedAccounts();
  final c = MediaPickerController(source: MediaKind.jellyfin);
  addTearDown(c.dispose);
  await tester.pumpWidget(app(MediaPicker(controller: c, jellyfin: accounts)));
  await settle(tester);
  return (c, accounts, fake);
}

Future<void> openArifureta(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('jf-search')), 'arifureta');
  await settle(tester, 10);
  expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('card-$arifuretaId')));
  await settle(tester);
}

void main() {
  testWidgets('home rows: continue watching with time left, next up, latest', (tester) async {
    await pumpPicker(tester, const Size(1600, 2400));
    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Next up'), findsOneWidget);
    expect(find.text('Latest in Shows'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Movies'), findsOneWidget);
    // Continue watching: series name on top, "S1E10 · N min left · title" below.
    expect(find.text('From Old Country Bumpkin to Master Swordsman'), findsWidgets);
    expect(find.textContaining(RegExp(r'^S1E10 · \d+ min left')), findsOneWidget);
    expect(find.text('Black Summoner'), findsWidgets);
    expect(find.text('Monogatari'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('series page: smart next button, season switching, pick an episode',
      (tester) async {
    final (c, _, _) = await pumpPicker(tester, const Size(1600, 1000));
    await openArifureta(tester);
    // Opens on the season holding next up (S2E4).
    expect(find.byKey(const ValueKey('season-$season2Id')), findsOneWidget);
    final s2 = tester.widget<ChoiceChip>(find.byKey(const ValueKey('season-$season2Id')));
    expect(s2.selected, isTrue);
    expect(find.text('1. Irregular'), findsOneWidget);
    expect(find.textContaining('Next up: S2E4'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Season 3'));
    await settle(tester);
    expect(find.text('1. Irregular'), findsNothing);
    expect(find.text('1. Haulias Assemble'), findsWidgets);

    // Picking an episode fills the controller.
    await tester.tap(find.text('2. Roar of Revolution').first);
    await tester.pump();
    final sel = c.selection;
    expect(sel, isA<JellyfinMedia>());
    sel as JellyfinMedia;
    expect(sel.serverId, fixtureServerId);
    expect(sel.title, 'Roar of Revolution');
    expect(sel.subtitle, "Arifureta: From Commonplace to World's Strongest · S3E2");
    expect(sel.baseUrl, 'https://example.invalid');

    // The smart button picks next up.
    await tester.tap(find.byKey(const ValueKey('series-next')));
    await tester.pump();
    expect((c.selection as JellyfinMedia).subtitle, endsWith('S2E4'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard: / searches, Esc clears then goes back, arrows move', (tester) async {
    await pumpPicker(tester, const Size(1600, 1000));
    final search = find.byKey(const ValueKey('jf-search'));

    // Focus a card, then arrow right moves to the next card.
    final first = find.byKey(const ValueKey('card-d66e875e181f74d80e838bddc76c6f23'));
    Focus.of(tester.element(find.descendant(of: first, matching: find.byType(Column)).first))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final ink = FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<InkWell>()!;
    expect((ink.key as ValueKey<String>).value, 'card-7c108a1cf6f062b4e3607a9be6d5ba0a');

    // "/" jumps to search.
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
    await tester.pump();
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
    await tester.enterText(search, 'arifureta');
    await settle(tester, 10);
    expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('search-results')), findsNothing);
    expect(find.text('Continue watching'), findsOneWidget);

    // Into the series and back with Esc.
    await openArifureta(tester);
    expect(find.byKey(const ValueKey('series-next')), findsOneWidget);
    expect(find.byKey(const ValueKey('crumb-0')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('series-next')), findsNothing);
    expect(find.text('Continue watching'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library grid with sort and filters', (tester) async {
    final (_, _, fake) = await pumpPicker(tester, const Size(1600, 1000));
    await tester.tap(find.widgetWithText(ActionChip, 'Shows'));
    await settle(tester);
    expect(find.text('218 items'), findsOneWidget);
    expect(find.text('Alma-chan Wants to Be a Family!'), findsWidgets);
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

  testWidgets('layouts: narrow has no inspector, ultrawide adds it and fits more columns',
      (tester) async {
    await pumpPicker(tester, const Size(820, 700));
    expect(find.byKey(const ValueKey('jf-inspector')), findsNothing);
    expect(tester.takeException(), isNull);
    final narrowCard = tester.getSize(find.byKey(const ValueKey('card-d66e875e181f74d80e838bddc76c6f23')));

    await pumpPicker(tester, const Size(3440, 1440));
    expect(find.byKey(const ValueKey('jf-inspector')), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Rows fill the width with whole cards.
    final wideCards = find.byWidgetPredicate((w) =>
        w is InkWell && w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('card-'));
    expect(wideCards.evaluate().length, greaterThan(10));
    expect(narrowCard.width, greaterThan(200));

    // Hover feeds the inspector.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('card-1c67aa9143ebcdcea7953aada4db543a')).first));
    await tester.pump();
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('jf-inspector')),
            matching: find.textContaining('Rice and Thieves and Heroes')),
        findsOneWidget);
  });

  testWidgets('Integrations: Quick Connect shows the code, approve links, cancel stops',
      (tester) async {
    await setSize(tester, const Size(1200, 900));
    final fake = FakeJellyfin();
    final accounts = JellyfinAccounts(
        store: MemoryJellyfinStore(), httpFactory: () => fake, deviceName: 'Test');
    await accounts.ensureLoaded(validate: false);
    await tester.pumpWidget(app(SingleChildScrollView(
        child: JellyfinAccountsPanel(
            accounts: accounts, pollInterval: const Duration(milliseconds: 100)))));
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

  testWidgets('no linked server: the picker offers sign-in inline', (tester) async {
    await setSize(tester, const Size(1200, 900));
    final accounts = JellyfinAccounts(store: MemoryJellyfinStore(), httpFactory: () => FakeJellyfin());
    await accounts.ensureLoaded(validate: false);
    final c = MediaPickerController(source: MediaKind.jellyfin);
    addTearDown(c.dispose);
    await tester.pumpWidget(app(SingleChildScrollView(
        child: MediaPicker(controller: c, jellyfin: accounts, onOpenIntegrations: () {}))));
    await tester.pump();
    expect(find.byKey(const ValueKey('jf-sign-in')), findsOneWidget);
    expect(find.text('Open Integrations'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired account shows a reconnect banner in the browser', (tester) async {
    final (_, accounts, _) = await pumpPicker(tester, const Size(1400, 900));
    accounts.markExpired(fixtureServerId);
    await tester.pump();
    expect(find.byKey(const ValueKey('jf-status-banner')), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.byType(JellyfinBrowser), findsOneWidget);
  });

  testWidgets('Library tab: the last pick comes back; offline it only browses',
      (tester) async {
    await setSize(tester, const Size(1800, 1000));
    final (accounts, _) = await linkedAccounts();
    const pick = JellyfinMedia(
        serverId: fixtureServerId,
        baseUrl: 'https://example.invalid',
        itemId: '1c67aa9143ebcdcea7953aada4db543a',
        title: 'Rice and Thieves and Heroes',
        subtitle: 'Black Summoner · S1E6');
    await accounts.rememberPick(pick);
    final c = MediaPickerController();
    addTearDown(c.dispose);
    await restoreLastPick(c, accounts, () => true);
    final put = <PickedMedia>[];
    Future<void> pump({required bool online}) => tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: LibraryTab(
            controller: c,
            accounts: accounts,
            online: online,
            isHost: false,
            onPutUp: (m) async {
              put.add(m);
              return null;
            },
          ),
        )));
    await pump(online: false);
    await settle(tester);
    // The saved pick comes back on the Jellyfin source.
    expect(c.selection, pick);
    expect(find.byType(JellyfinBrowser), findsOneWidget);
    expect(find.text('Join or host to watch together'), findsOneWidget);
    final go = find.byKey(const ValueKey('swap-go'));
    expect(tester.widget<ButtonStyleButton>(go).onPressed, isNull);

    await pump(online: true);
    await settle(tester);
    expect(find.text('Put up: Rice and Thieves and Heroes — Black Summoner · S1E6'), findsOneWidget);
    await tester.tap(go);
    await settle(tester);
    expect(put, [pick]);
    tester.view.physicalSize = const Size(800, 900);
    await settle(tester, 2);
    expect(find.byType(JellyfinBrowser), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
