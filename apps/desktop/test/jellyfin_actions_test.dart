import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/jellyfin/item_actions.dart';
import 'package:starsync/src/jellyfin/series_page.dart' show EpisodeTile;

import 'jellyfin_accounts_test.dart' show FakeJellyfin, arifuretaId, fixtureServerId, season2Id;
import 'jellyfin_browser_test.dart' show settle;
import 'library_tab_test.dart' show bsEpisode, pumpLibrary;

// One list of actions per Jellyfin item kind: the right-click menus of
// cards, tiles, rows and seasons and the details panel's buttons and ⋮
// are the same, and the watched marks reach Jellyfin and every row.

/// Black Summoner's resume point (its card shows the next-up episode).
const bsResume = 'd66e875e181f74d80e838bddc76c6f23';
const bsSeries = 'c7974a65e1b7bd43f26858744a7d3c11';

/// The actions of the open menu, in order.
List<JellyfinAction> menuActions() => [
      for (final e in find
          .byWidgetPredicate((w) =>
              w is InkWell && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('jf-action-'))
          .evaluate())
        JellyfinAction.values.byName((e.widget.key! as ValueKey<String>).value.substring('jf-action-'.length)),
    ];

Future<List<JellyfinAction>> rightClickMenu(WidgetTester tester, Finder f) async {
  await tester.tap(f, buttons: kSecondaryButton);
  await settle(tester, 4);
  final got = menuActions();
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await settle(tester, 4);
  return got;
}

Future<List<JellyfinAction>> panelMenu(WidgetTester tester, [String key = 'details-more']) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await settle(tester, 4);
  final got = menuActions();
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await settle(tester, 4);
  return got;
}

Future<void> pick(WidgetTester tester, JellyfinAction a) async {
  await tester.tap(find.byKey(ValueKey('jf-action-${a.name}')));
  await settle(tester, 10);
}

/// [fake] answers marks on [ids] (watched and unwatched).
void answerMarks(FakeJellyfin fake, List<String> ids) {
  for (final id in ids) {
    fake.on('POST', '/UserPlayedItems/$id', (_, _) => const JellyfinHttpResponse(200, '{"Played":true}'));
    fake.on('DELETE', '/UserPlayedItems/$id', (_, _) => const JellyfinHttpResponse(200, '{"Played":false}'));
  }
}

Finder card(String id) => find.byKey(ValueKey('card-$id')).first;

/// The watched badge on a card (not the selection's).
bool watchedBadge(WidgetTester tester, String id) =>
    find.descendant(of: card(id), matching: find.byIcon(Icons.check)).evaluate().isNotEmpty;

void main() {
  group('the list per kind', () {
    const episode = JellyfinItem(id: 'e', name: 'Ep', type: 'Episode', seriesId: 's', seasonId: 'x');
    const movie = JellyfinItem(id: 'm', name: 'Film', type: 'Movie');
    const series = JellyfinItem(id: 's', name: 'Show', type: 'Series', isFolder: true);
    const season = JellyfinItem(id: 'x', name: 'Season 1', type: 'Season', seriesId: 's', isFolder: true);
    const folder = JellyfinItem(id: 'f', name: 'Stuff', type: 'Folder', isFolder: true);
    List<JellyfinAction> of(JellyfinItem i, {bool queue = true, bool inContinue = false, bool onShowPage = false}) =>
        [for (final v in jellyfinActions(i, queue: queue, inContinue: inContinue, onShowPage: onShowPage)) v.action];
    const a = JellyfinAction.values;

    test('episodes, movies, shows, seasons, folders', () {
      expect(of(episode, inContinue: true), [for (final x in a) if (x != JellyfinAction.markUnwatched) x]);
      expect(of(movie), [
        JellyfinAction.putUp, JellyfinAction.addToQueue, JellyfinAction.playNext, JellyfinAction.markWatched,
        JellyfinAction.copyTitle, JellyfinAction.openInJellyfin,
      ]);
      expect(of(series), [
        JellyfinAction.putUp, JellyfinAction.addToQueue, JellyfinAction.playNext, JellyfinAction.markWatched,
        JellyfinAction.openShow, JellyfinAction.copyTitle, JellyfinAction.openInJellyfin,
      ]);
      expect(of(season), [JellyfinAction.markWatched, JellyfinAction.openShow, JellyfinAction.copyTitle, JellyfinAction.openInJellyfin]);
      expect(of(folder), [JellyfinAction.copyTitle, JellyfinAction.openInJellyfin]);
      // No server: no queue; on the show's page: no link to it.
      expect(of(episode, queue: false, onShowPage: true),
          [JellyfinAction.putUp, JellyfinAction.markWatched, JellyfinAction.copyTitle, JellyfinAction.openInJellyfin]);
    });

    test('the marks toggle by state and name what they mark', () {
      String mark(JellyfinItem i) => jellyfinActions(i).firstWhere((v) => v.label.startsWith('Mark')).label;
      expect(mark(episode), 'Mark watched');
      expect(mark(series), 'Mark show watched');
      expect(mark(season), 'Mark season watched');
      final watched = episode.withUserData(const JellyfinUserData(played: true));
      expect(of(watched), contains(JellyfinAction.markUnwatched));
      expect(of(watched), isNot(contains(JellyfinAction.markWatched)));
      expect(mark(watched), 'Mark unwatched');
      expect(jellyfinActions(movie, alone: true).first.label, 'Play');
    });
  });

  testWidgets('right-click and the details panel offer the same, for an episode and a show', (tester) async {
    await pumpLibrary(tester, const Size(1600, 1000), queue: true);
    // An episode in Continue.
    final menu = await rightClickMenu(tester, card(bsEpisode));
    expect(menu, [for (final a in JellyfinAction.values) if (a != JellyfinAction.markUnwatched) a],
        reason: 'every action, Remove from Continue included');
    await tester.tap(card(bsEpisode));
    await settle(tester, 10);
    expect(await panelMenu(tester), menu);
    for (final b in ['addToQueue', 'markWatched', 'removeFromContinue', 'openShow']) {
      expect(find.byKey(ValueKey('details-$b')), findsOneWidget, reason: b);
    }
    // The panel's button and the menu say the same.
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('details-markWatched'))).tooltip, 'Mark watched');

    // A show in Latest: its marks are the whole show's.
    final show = await rightClickMenu(tester, card(arifuretaId));
    expect(show, [
      JellyfinAction.putUp, JellyfinAction.addToQueue, JellyfinAction.playNext, JellyfinAction.markWatched,
      JellyfinAction.openShow, JellyfinAction.copyTitle, JellyfinAction.openInJellyfin,
    ]);
    await tester.tap(card(arifuretaId));
    await settle(tester, 10);
    expect(await panelMenu(tester), show);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('details-markWatched'))).tooltip, 'Mark show watched');
    // An episode row in the panel: the episode's list.
    const s2e1 = '5cf1c471';
    final row = find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('details-episode-$s2e1'));
    await tester.ensureVisible(row);
    await settle(tester, 2);
    final ep = await rightClickMenu(tester, row);
    expect(ep, [
      JellyfinAction.putUp, JellyfinAction.addToQueue, JellyfinAction.playNext, JellyfinAction.markWatched,
      JellyfinAction.openShow, JellyfinAction.copyTitle, JellyfinAction.openInJellyfin,
    ]);
    // The season's own, beside its picker.
    expect(await panelMenu(tester, 'details-season-more'),
        [JellyfinAction.markWatched, JellyfinAction.openShow, JellyfinAction.copyTitle, JellyfinAction.openInJellyfin]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mark watched from the right-click: Jellyfin hears it, every row shows it at once', (tester) async {
    final h = await pumpLibrary(tester, const Size(1600, 1000), queue: true);
    answerMarks(h.fake, [bsEpisode]);
    expect(watchedBadge(tester, bsEpisode), isFalse);
    final resumes = h.fake.count('GET', '/UserItems/Resume');

    await tester.tap(card(bsEpisode), buttons: kSecondaryButton);
    await settle(tester, 4);
    expect(find.text('Mark watched'), findsOneWidget);
    await pick(tester, JellyfinAction.markWatched);
    expect(h.fake.count('POST', '/UserPlayedItems/$bsEpisode'), 1);
    expect(h.fake.requests.last.uri.queryParameters['userId'], isNotEmpty);
    expect(h.fake.count('GET', '/UserItems/Resume'), greaterThan(resumes), reason: 'the rows load again');
    expect(watchedBadge(tester, bsEpisode), isTrue, reason: 'the badge before the server says so');

    // Its panel agrees, and so does the menu the next time.
    await tester.tap(card(bsEpisode));
    await settle(tester, 10);
    expect(find.byKey(const ValueKey('details-markUnwatched')), findsOneWidget);
    await tester.tap(card(bsEpisode), buttons: kSecondaryButton);
    await settle(tester, 4);
    expect(menuActions(), contains(JellyfinAction.markUnwatched));
    await pick(tester, JellyfinAction.markUnwatched);
    expect(h.fake.count('DELETE', '/UserPlayedItems/$bsEpisode'), 1);
    expect(find.byKey(const ValueKey('details-markWatched')), findsOneWidget);
    // Closed, the card shows its own badge again (the selection's is gone).
    await tester.tap(find.byKey(const ValueKey('details-close')));
    await settle(tester, 10);
    expect(watchedBadge(tester, bsEpisode), isFalse);
    expect(find.byKey(const ValueKey('jf-confirm-mark')), findsNothing, reason: 'one episode: no question');
    expect(tester.takeException(), isNull);
  });

  testWidgets('remove from Continue from the right-click', (tester) async {
    final h = await pumpLibrary(tester, const Size(1600, 1000));
    h.fake.on('POST', '/UserItems/$bsResume/UserData', (_, _) => const JellyfinHttpResponse(204, ''));
    final row = find.byKey(const ValueKey('row-continue'));
    expect(find.descendant(of: row, matching: find.text('Black Summoner')), findsOneWidget);
    await tester.tap(card(bsEpisode), buttons: kSecondaryButton);
    await settle(tester, 4);
    await pick(tester, JellyfinAction.removeFromContinue);
    expect(h.accounts.continueDismissed(fixtureServerId), contains(bsSeries));
    expect(h.fake.count('POST', '/UserItems/$bsResume/UserData'), 1, reason: "the show's resume point goes");
    expect(find.descendant(of: row, matching: find.text('Black Summoner')), findsNothing);
    expect(find.descendant(of: row, matching: find.text("JoJo's Bizarre Adventure")), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a whole show from its page asks first; a season from its chip does not', (tester) async {
    final h = await pumpLibrary(tester, const Size(1600, 1100));
    answerMarks(h.fake, [arifuretaId, season2Id]);
    await tester.tap(card(arifuretaId));
    await settle(tester, 10);
    await tester.tap(find.byKey(const ValueKey('details-openShow')));
    await settle(tester, 10);
    expect(find.byKey(const ValueKey('series-next')), findsOneWidget);
    // On its page: the page links to itself nowhere.
    expect(find.byKey(const ValueKey('details-openShow')), findsNothing);

    Iterable<Element> tiles() => find.byType(EpisodeTile).evaluate();
    bool allWatched() => tiles().every((t) =>
        find.descendant(of: find.byWidget(t.widget), matching: find.byIcon(Icons.check)).evaluate().isNotEmpty);
    expect(tiles(), isNotEmpty);
    expect(allWatched(), isFalse);

    await tester.tap(find.byKey(const ValueKey('series-markWatched')));
    await settle(tester, 4);
    expect(find.byKey(const ValueKey('jf-confirm-mark')), findsOneWidget);
    expect(find.textContaining('all 41 episodes'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester, 4);
    expect(h.fake.count('POST', '/UserPlayedItems/$arifuretaId'), 0);

    await tester.tap(find.byKey(const ValueKey('series-markWatched')));
    await settle(tester, 4);
    await tester.tap(find.byKey(const ValueKey('jf-confirm-mark-ok')));
    await settle(tester, 10);
    expect(h.fake.count('POST', '/UserPlayedItems/$arifuretaId'), 1);
    expect(allWatched(), isTrue, reason: 'every episode of the show at once');
    expect(find.byKey(const ValueKey('series-markUnwatched')), findsOneWidget);
    expect(find.byKey(const ValueKey('details-markUnwatched')), findsOneWidget, reason: 'the panel too');

    // Unwatched asks too (it clears where you stopped).
    await tester.tap(find.byKey(const ValueKey('series-markUnwatched')));
    await settle(tester, 4);
    await tester.tap(find.byKey(const ValueKey('jf-confirm-mark-ok')));
    await settle(tester, 10);
    expect(h.fake.count('DELETE', '/UserPlayedItems/$arifuretaId'), 1);
    expect(allWatched(), isFalse);

    // A season: its chip's right-click, no question.
    final chip = find.byKey(const ValueKey('season-$season2Id'));
    await tester.tap(chip);
    await settle(tester, 10);
    final menu = await rightClickMenu(tester, chip);
    expect(menu, [JellyfinAction.markWatched, JellyfinAction.copyTitle, JellyfinAction.openInJellyfin]);
    await tester.tap(chip, buttons: kSecondaryButton);
    await settle(tester, 4);
    expect(find.text('Mark season watched'), findsOneWidget);
    await pick(tester, JellyfinAction.markWatched);
    expect(find.byKey(const ValueKey('jf-confirm-mark')), findsNothing);
    expect(h.fake.count('POST', '/UserPlayedItems/$season2Id'), 1);
    expect(allWatched(), isTrue, reason: 'the season shown is Season 2');
    expect(find.descendant(of: chip, matching: find.byIcon(Icons.check)), findsOneWidget);
    // The season's own button beside the chips now unmarks it.
    expect(find.byKey(const ValueKey('season-markUnwatched')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
