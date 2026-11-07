import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/danmaku/danmaku.dart';
import 'package:starsync/src/session/app_events.dart' show ChatPosted, MemberJoined;
import 'package:starsync/src/shell/avatar.dart';
import 'package:starsync/src/shell/chat_panel.dart' show ActivityRow;
import 'package:starsync/src/shell/party_strip.dart' show MembersCard;
import 'package:starsync/src/shell/person_card.dart';
import 'package:starsync/src/shell/toasts.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The people card: the same card for a person wherever they show (the
// strip's avatars, the members card's rows, chat lines, toasts, danmaku
// lines), on hover and pinned by a click, with what the state says.

/// A 1×1 PNG: a picture to look at full size.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

MemberView member(String id, String name,
        {bool host = false, String app = '', Presence presence = Presence.watching, String error = ''}) =>
    MemberView(
        id: id,
        name: name,
        buffered: 30,
        host: host,
        app: app,
        presence: presence,
        error: error);

void main() {
  final coord = _graph.coordinator;

  /// Alex hosts and passes the video on; Bob is BRB; Cleo is out.
  void party({bool relay = true}) => coord.serverState.value = StateBroadcast(
        eventId: 1,
        transport: 'held',
        position: 0,
        serverTime: DateTime.now().toUtc(),
        mediaId: 1,
        media: {
          'name': 'Frieren.mkv',
          'size': 1,
          'duration': 0,
          if (relay) 'relay': {'source': 'a', 'live': true, 'rate': 4100000, 'need': 2300000},
        },
        members: [
          member('a', 'Alex', host: true, app: '1.4.0'),
          member('b', 'Bob', app: '1.3.0', presence: Presence.brb),
          member('c', 'Cleo', presence: Presence.out),
        ],
      );

  tearDown(() {
    coord.serverState.value = null;
    _graph.notifier.clear();
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(scoped(_graph, MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child))));
    await tester.pump();
  }

  Future<TestGesture> mouse(WidgetTester tester) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: const Offset(1, 1));
    addTearDown(g.removePointer);
    return g;
  }

  final card = find.byKey(const ValueKey('person-card'));
  Finder inCard(Finder f) => find.descendant(of: card, matching: f);

  group('what it says', () {
    test('member actions: the members card\'s, by state', () {
      List<MemberAction> of(AvatarInfo i) => [for (final a in memberActions(i)) a.action];
      List<String> labels(AvatarInfo i) => [for (final a in memberActions(i)) a.label];
      expect(of(const AvatarInfo(name: 'Bob Smith', color: Colors.teal)),
          [MemberAction.waitFor, MemberAction.nudge, MemberAction.out]);
      expect(labels(const AvatarInfo(name: 'Bob Smith', color: Colors.teal)), ['Wait for Bob', 'Nudge', 'Out']);
      expect(labels(const AvatarInfo(name: 'Bob', color: Colors.teal, presence: Presence.brb)),
          ["Don't wait for Bob", 'Nudge', 'Out']);
      expect(of(const AvatarInfo(name: 'B', color: Colors.teal, activity: AvatarActivity.loading)),
          [MemberAction.dontWaitFor, MemberAction.nudge, MemberAction.out], reason: 'the group waits for their video');
      expect(of(const AvatarInfo(name: 'B', color: Colors.teal, presence: Presence.out)), [MemberAction.nudge]);
      expect(of(const AvatarInfo(name: 'Me', color: Colors.teal, self: true, presence: Presence.afk)),
          [MemberAction.join]);
      expect(of(const AvatarInfo(name: 'Me', color: Colors.teal, self: true)), [MemberAction.out]);
    });

    test('the standing in words', () {
      AvatarInfo at(Presence p, {DateTime? since, AvatarActivity activity = AvatarActivity.none}) =>
          AvatarInfo(name: 'B', color: Colors.teal, presence: p, since: since, goneSince: since, activity: activity);
      final since = DateTime.utc(2026, 1, 1, 12);
      final later = since.add(const Duration(minutes: 4));
      expect(presenceText(at(Presence.watching)).$1, 'Watching');
      expect(presenceText(at(Presence.watching, activity: AvatarActivity.loading)).$1, 'Loading…');
      expect(presenceText(at(Presence.brb, since: since), now: later).$1, 'BRB · 4 min');
      expect(presenceText(at(Presence.afk, since: since), now: later).$1, 'AFK · 4 min');
      expect(presenceText(at(Presence.out)).$1, 'Out');
      expect(
          presenceText(at(Presence.brb, since: since, activity: AvatarActivity.reconnecting),
                  now: since.add(const Duration(minutes: 2)))
              .$1,
          'Reconnecting (2 min) · BRB');
    });
  });

  testWidgets('from the strip: hover shows it, leaving hides it, a click pins it', (tester) async {
    party();
    var everyone = 0;
    await pump(
        tester,
        Align(
          alignment: Alignment.topRight,
          child: PartyWatch(
            builder: (context) =>
                AvatarStack(key: const ValueKey('party-avatars'), members: partyAvatars(coord), onTap: () => everyone++),
          ),
        ));
    final alex = find.byKey(const ValueKey('stack-a-Alex'));
    final g = await mouse(tester);
    await g.moveTo(tester.getCenter(alex));
    await tester.pump(const Duration(milliseconds: 200));
    expect(card, findsNothing, reason: 'not on a passing mouse');
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsOneWidget);
    // Name, standing, what Alex passes on, the version, host.
    expect(inCard(find.text('Alex')), findsOneWidget);
    expect(inCard(find.text('Watching')), findsOneWidget);
    expect(inCard(find.text('host')), findsOneWidget);
    expect(inCard(find.text('passing the video on')), findsOneWidget);
    expect(inCard(find.textContaining('Passing on Frieren')), findsOneWidget);
    expect(inCard(find.textContaining('4.1 MB/s')), findsOneWidget);
    expect(inCard(find.text('1.4.0')), findsOneWidget);
    expect(inCard(find.byKey(const ValueKey('person-action-waitFor'))), findsOneWidget);
    expect(inCard(find.byKey(const ValueKey('person-action-nudge'))), findsOneWidget);
    // The card sits under the strip's avatar.
    expect(tester.getTopLeft(card).dy, greaterThan(tester.getBottomLeft(alex).dy));

    // Into the card keeps it; out of both hides it.
    await g.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsOneWidget);
    await g.moveTo(const Offset(20, 700));
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsNothing);

    // A click pins it: it stays with the mouse away, Esc closes it.
    final bob = find.byKey(const ValueKey('stack-b-Bob'));
    await g.moveTo(tester.getCenter(bob));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(bob);
    await tester.pumpAndSettle();
    await g.moveTo(const Offset(20, 700));
    await tester.pump(const Duration(seconds: 1));
    expect(card, findsOneWidget);
    expect(inCard(find.text('BRB')), findsOneWidget);
    expect(inCard(find.text('1.3.0')), findsOneWidget);
    expect(inCard(find.byKey(const ValueKey('person-action-dontWaitFor'))), findsOneWidget);
    expect(inCard(find.textContaining('Passing on')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(card, findsNothing);

    // Pinned again, "Everyone in the server" closes it and opens the
    // members card (the stack's own click).
    await tester.tap(bob);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('person-everyone')));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(everyone, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the picture opens full size', (tester) async {
    party(relay: false);
    final pic = MemoryImage(_png);
    await pump(
        tester,
        Center(
          child: PersonHover(
            person: PersonRef(id: 'a', name: 'Alex', info: AvatarInfo(id: 'a', name: 'Alex', color: Colors.teal, image: pic)),
            child: const SizedBox(width: 40, height: 40),
          ),
        ));
    await tester.tap(find.byType(PersonHover));
    await tester.pumpAndSettle();
    // Alex is in the state with no picture of his own there: the line's.
    expect(find.byKey(const ValueKey('person-picture')), findsNothing,
        reason: 'the live member has none (no hash): nothing to open');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Someone who left: the picture the line had.
    coord.serverState.value = null;
    await tester.tap(find.byType(PersonHover));
    await tester.pumpAndSettle();
    expect(inCard(find.text('Not in the server')), findsOneWidget);
    expect(inCard(find.byKey(const ValueKey('person-action-nudge'))), findsNothing);
    await tester.tap(find.byKey(const ValueKey('person-picture')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('person-picture-view')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('person-picture-view')), matching: find.text('Alex')),
        findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('person-picture-view')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('from a chat line: the picture and the name', (tester) async {
    party();
    await pump(
        tester,
        ActivityRow(
            item: FeedMessage(actor: 'Bob', actorId: 'b', action: 'chat', reason: 'hi all', at: DateTime.now().toUtc())));
    final hovers = find.byType(PersonHover);
    expect(hovers, findsNWidgets(2));
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    expect(inCard(find.text('Bob')), findsOneWidget);
    expect(inCard(find.text('BRB')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final g = await mouse(tester);
    await g.moveTo(tester.getCenter(hovers.first));
    await tester.pump(const Duration(milliseconds: 600));
    expect(inCard(find.text('Bob')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('from a toast: its picture, also on a toast that lets clicks through', (tester) async {
    party();
    await pump(tester, const Align(alignment: Alignment.bottomLeft, child: PartyToasts()));
    coord.notify(MemberJoined(FeedMessage(actor: 'Bob', actorId: 'b', action: 'joined', at: DateTime.now().toUtc())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ToastCard), findsOneWidget);
    final pic = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('toast-person-'));
    expect(pic, findsOneWidget);
    final g = await mouse(tester);
    await g.moveTo(tester.getCenter(pic));
    await tester.pump(const Duration(milliseconds: 600));
    expect(inCard(find.text('Bob')), findsOneWidget);
    // Above the toast: it sits at the bottom.
    expect(tester.getBottomLeft(card).dy, lessThan(tester.getTopLeft(pic).dy));
    await g.moveTo(const Offset(1100, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsNothing);
    await tester.pump(_graph.notifier.toastLife);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat toasts: the picture is the person, the rest opens the chat', (tester) async {
    party();
    var opened = 0;
    await pump(tester, Align(alignment: Alignment.bottomLeft, child: PartyToasts(onOpenChat: () => opened++)));
    coord.notify(ChatPosted(FeedMessage(actor: 'Bob', actorId: 'b', action: 'chat', reason: 'hey', at: DateTime.now().toUtc())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final pic = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('toast-person-'));
    await tester.tap(pic);
    await tester.pumpAndSettle();
    expect(inCard(find.text('Bob')), findsOneWidget);
    expect(opened, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('hey'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    await tester.pump(_graph.notifier.toastLife);
    await tester.pumpAndSettle();
  });

  testWidgets('from the members card: each row, without a link back to it', (tester) async {
    party();
    await pump(tester, const Center(child: MembersCard()));
    final bobRow = find.byKey(const ValueKey('member-b'));
    await tester.tap(find.descendant(of: bobRow, matching: find.byType(StatusAvatar)));
    await tester.pumpAndSettle();
    expect(inCard(find.text('Bob')), findsOneWidget);
    expect(inCard(find.byKey(const ValueKey('person-everyone'))), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // The row's ⋮ has the card's actions, same names.
    await tester.tap(find.descendant(of: bobRow, matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    for (final label in ["Don't wait for Bob", 'Nudge', 'Out']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets("a member's picked colour shows for everyone; without one, the name's", (tester) async {
    coord.serverState.value = StateBroadcast(
      eventId: 1,
      transport: 'held',
      position: 0,
      serverTime: DateTime.now().toUtc(),
      mediaId: 1,
      members: const [
        MemberView(id: 'p', name: 'pol', color: '#7e57c2'),
        MemberView(id: 'b', name: 'Bob'),
      ],
    );
    const purple = Color(0xFF7E57C2);
    Color colorIn(Finder row) =>
        tester.widget<StatusAvatar>(find.descendant(of: row, matching: find.byType(StatusAvatar))).info.color;
    await pump(tester, const Center(child: MembersCard()));
    expect(colorIn(find.byKey(const ValueKey('member-p'))), purple);
    expect(colorIn(find.byKey(const ValueKey('member-b'))), colorForName('Bob'));
    // A chat line by the same member, and the lookup toasts and danmaku
    // lines use: their colour too.
    await pump(
        tester,
        ActivityRow(
            item: FeedMessage(actor: 'pol', actorId: 'p', action: 'chat', reason: 'hi', at: DateTime.now().toUtc())));
    expect(tester.widget<StatusAvatar>(find.byType(StatusAvatar)).info.color, purple);
    expect(avatarForName('pol', coord, 'p').color, purple);
    expect(avatarForName('Bob', coord, 'b').color, colorForName('Bob'));
    expect(tester.takeException(), isNull);
  });

  testWidgets("from a danmaku line: a click on its sender, the controls still get it", (tester) async {
    party();
    final lines = DanmakuController();
    addTearDown(lines.dispose);
    final tapped = <(DanmakuItem, Rect)>[];
    var controls = 0;
    await pump(
        tester,
        Stack(fit: StackFit.expand, children: [
          DanmakuLayer(controller: lines, accent: Colors.teal),
          DanmakuPersonTaps(
            lines: lines,
            onTap: (item, rect) => tapped.add((item, rect)),
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTapDown: (_) => controls++),
          ),
        ]));
    lines.add(DanmakuItem(
        kind: DanmakuKind.chat,
        sender: 'Bob',
        text: 'what a fight',
        avatar: avatarForName('Bob', coord, 'b')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final at = tester.getCenter(find.byType(LineAvatar));
    expect(lines.senderAt(at), isNotNull);
    await tester.tapAt(at);
    expect(tapped.single.$1.sender, 'Bob');
    expect(tapped.single.$2.contains(at), isTrue);
    expect(controls, 1, reason: 'the controls under it hear the click too');
    // The message itself is not the sender.
    final text = tester.getRect(find.textContaining('what a fight').first);
    expect(lines.senderAt(Offset(text.right - 4, text.center.dy)), isNull);
    expect(lines.senderAt(const Offset(5, 790)), isNull);
    // What it opens: Bob's card at the line.
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(builder: (context) {
        return Center(
          child: TextButton(
            onPressed: () => showPersonCard(context, PersonRef.of(tapped.single.$1.avatar!), tapped.single.$2),
            child: const Text('open'),
          ),
        );
      }),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(inCard(find.text('Bob')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
