import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/app/app_graph.dart';
import 'package:starsync/src/screens/home/connect_flow.dart';
import 'package:starsync/src/session/connection.dart' show ConnectParams;
import 'package:starsync/src/session/identity.dart';
import 'package:starsync/src/session/navigation.dart';
import 'package:starsync/src/shell/app_shell.dart';
import 'package:starsync/src/shell/connect_cards.dart' show JoinCard;
import 'package:starsync/src/shell/profile_card.dart';
import 'package:starsync/src/update/update_controller.dart';

import 'test_graph.dart';

// Joining without a name: every way in (the Join card, a clicked
// starsync:// link, an invite on the clipboard) first asks "what do we
// call you?", and OK goes on with the same join.

/// Hosts whose `/health` was read (a join reads it first); none answer.
final _probed = <String>[];
final _graph = testGraph(healthGet: (uri) async {
  _probed.add(uri.host);
  throw StateError('nobody answers');
});

/// Records the join instead of dialling.
class _RecordingNav extends Navigation {
  _RecordingNav(AppGraph g) : super(coordinator: g.coordinator, yourServer: g.yourServer, forms: g.forms);
  ConnectParams? joined;

  @override
  Future<void> join(ConnectParams params) async => joined = params;
}

void main() {
  final p = Profile.instance;
  final offers = _graph.joinOffers;
  final nameCard = find.byKey(const ValueKey('name-card'));
  final nameField = find.byKey(const ValueKey('name-card-name'));

  void named(String name) {
    p.name.value = name;
    _graph.forms.form.name = name;
  }

  setUp(() {
    _probed.clear();
    named('');
  });

  tearDown(() {
    offers.offer.value = null;
    named('');
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(scoped(
        _graph,
        MaterialApp(
          theme: ThemeData.dark(),
          home: AppShell(
            updates: UpdateController(currentVersion: '0.0.0-dev'),
            autoUpdateCheck: false,
            windowControls: false,
            videoBuilder: (context, controls) => const ColoredBox(color: Colors.black),
          ),
        )));
    await tester.pumpAndSettle();
  }

  /// The name card is up with the suggestion selected; [name] typed, OK.
  Future<void> answer(WidgetTester tester, String name) async {
    expect(nameCard, findsOneWidget);
    expect(find.text('Wait, what do we call you?'), findsOneWidget);
    final field = tester.widget<TextField>(nameField);
    expect(field.controller!.text, suggestedName());
    expect(field.autofocus, isTrue);
    await tester.enterText(nameField, name);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('name-card-ok')));
    await tester.pumpAndSettle();
    expect(nameCard, findsNothing);
    expect(p.name.peek(), name);
    expect(_graph.forms.form.name, name);
    // Let the rename's debounce run out.
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> acceptOffer(WidgetTester tester) async {
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('join-offer')), findsOneWidget);
    _probed.clear(); // the prompt's own /health
    await tester.tap(find.byKey(const ValueKey('join-offer-join')));
    await tester.pumpAndSettle();
  }

  test('the suggestion is the computer\'s user name', () {
    expect(suggestedName({'USER': 'foxyz'}), 'Foxyz');
    expect(suggestedName({'USERNAME': 'ann'}), 'Ann');
    expect(suggestedName({'USER': 'root'}), '');
    expect(suggestedName({}), '');
  });

  testWidgets('the join goes on with the name given, in the hello', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(scoped(
        _graph,
        MaterialApp(home: Builder(builder: (c) {
          context = c;
          return const SizedBox.expand();
        }))));
    final nav = _RecordingNav(_graph);
    addTearDown(nav.dispose);
    final flow = ConnectFlow(navigation: nav, forms: _graph.forms, askName: (profile) => askYourName(context, profile));
    addTearDown(flow.dispose);
    unawaited(flow.submit((f) => f
      ..host = '203.0.113.5'
      ..port = '8080'));
    await tester.pumpAndSettle();
    expect(nav.joined, isNull, reason: 'waits for the name');
    await answer(tester, 'Neo');
    expect(nav.joined?.name, 'Neo');
    expect(nav.joined?.host, '203.0.113.5');
    expect(flow.error, isNull);
  });

  testWidgets('Join card: no name, the card asks, OK joins', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('strip-join')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('join-address')), '203.0.113.9');
    await tester.tap(find.descendant(of: find.byType(JoinCard), matching: find.widgetWithText(FilledButton, 'Join')));
    await tester.pumpAndSettle();
    expect(_probed, isEmpty, reason: 'nothing dialled before the name');
    await answer(tester, 'Neo');
    expect(_probed, contains('203.0.113.9'), reason: 'the same join went on');
    expect(find.text('Check the form'), findsNothing);
  });

  testWidgets('a clicked starsync:// link: no name, the card asks, OK joins', (tester) async {
    await pumpShell(tester);
    offers.fromArgs(['starsync://203.0.113.7:8080/?name=Bob']);
    await acceptOffer(tester);
    expect(_probed, isEmpty);
    await answer(tester, 'Neo');
    expect(_probed, contains('203.0.113.7'));
  });

  testWidgets('an invite on the clipboard: no name, the card asks, OK joins', (tester) async {
    await pumpShell(tester);
    offers.fromClipboard('come watch: starsync://203.0.113.8:8080');
    await acceptOffer(tester);
    await answer(tester, 'Neo');
    expect(_probed, contains('203.0.113.8'));
  });

  testWidgets('Cancel drops the join: nothing dialled, no name, no error', (tester) async {
    await pumpShell(tester);
    offers.fromArgs(['starsync://203.0.113.10:8080']);
    await acceptOffer(tester);
    expect(nameCard, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('name-card-cancel')));
    await tester.pumpAndSettle();
    expect(nameCard, findsNothing);
    expect(_probed, isEmpty);
    expect(p.name.peek(), '');
    expect(find.byType(JoinCard), findsNothing, reason: 'no error to show');
  });

  testWidgets('with a name: no card, the join goes straight on', (tester) async {
    named('Ann');
    await pumpShell(tester);
    offers.fromArgs(['starsync://203.0.113.11:8080']);
    await acceptOffer(tester);
    expect(nameCard, findsNothing);
    expect(_probed, contains('203.0.113.11'));
    // It failed (nobody answers): the Join card opens with the error.
    expect(find.byType(JoinCard), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('join-address')), '203.0.113.12');
    await tester.tap(find.descendant(of: find.byType(JoinCard), matching: find.widgetWithText(FilledButton, 'Join')));
    await tester.pumpAndSettle();
    expect(nameCard, findsNothing);
    expect(_probed, contains('203.0.113.12'));
    expect(p.name.peek(), 'Ann');
  });
}
