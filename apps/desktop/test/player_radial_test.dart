// The player's radial (right button on the video) and the status pill's
// keys, as widgets on a stand-in picture (never a media_kit `Video`).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/controls/controls_probe.dart' show ControlsHold;
import 'package:starsync/src/controls/model/controls_model.dart';
import 'package:starsync/src/session/navigation.dart' show Place;
import 'package:starsync/src/shell/player_radial.dart';
import 'package:starsync/src/shell/player_status.dart';
import 'package:starsync/src/widgets/app_keys.dart';
import 'package:starsync/src/shell/radial_menu.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

void main() {
  final coord = _graph.coordinator;

  setUp(() => coord.connection.client.memberId = 'me');
  tearDown(() {
    coord.serverState.value = null;
    coord.connection.client.memberId = '';
  });

  void state(Presence self) => coord.serverState.value = StateBroadcast(
        eventId: 1,
        transport: 'playing',
        position: 0,
        serverTime: DateTime.now().toUtc(),
        mediaId: 1,
        media: const {'name': 'Ep.mkv', 'size': 1, 'duration': 0},
        members: [MemberView(id: 'me', name: 'Me', presence: self), const MemberView(id: 'b', name: 'Bob')],
        wantsPlay: true,
      );

  Future<RadialController> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final model = PlayerControlsModel(
      coord: coord,
      fullscreen: signal(false),
      chatOpen: signal(false),
      unread: signal(0),
      onToggleFullscreen: () {},
      onToggleChat: () {},
      onChangeVideo: () {},
      onCollapse: () {},
      onLeave: () {},
    );
    final hold = ControlsHold();
    final radial = RadialController(model, hold);
    addTearDown(() {
      radial.dispose();
      hold.dispose();
      model.dispose();
    });
    await tester.pumpWidget(scoped(
        _graph,
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Stack(fit: StackFit.expand, children: [
              RadialListener(controller: radial, child: const ColoredBox(color: Colors.black)),
              RadialLayer(controller: radial),
            ]),
          ),
        )));
    await tester.pump();
    return radial;
  }

  Future<TestGesture> rightDown(WidgetTester tester, Offset at) =>
      tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);

  final menu = find.byType(RadialMenuView);

  testWidgets('a press, a drag and letting go picks; the four places stay put', (tester) async {
    state(Presence.watching);
    final radial = await pump(tester);
    const at = Offset(640, 360);
    final g = await rightDown(tester, at);
    await tester.pump(const Duration(milliseconds: 200));
    expect(menu, findsOneWidget);
    expect(radial.isOpen, isTrue);
    final view = tester.widget<RadialMenuView>(menu);
    expect([for (final i in view.items) i.blank ? '' : i.label], ['BRB', 'Skip 1:30', 'Out', ''],
        reason: '↑ BRB, → skip ahead, ↓ Out, ← empty');
    expect(view.items[1].enabled, isFalse, reason: 'no duration yet: greyed in place');
    // Up to BRB and let go: picked, closed.
    await g.moveTo(at - const Offset(0, 90));
    await tester.pump();
    expect(tester.widget<RadialMenuView>(menu).hot, 0);
    await g.up();
    await tester.pumpAndSettle();
    expect(radial.isOpen, isFalse);
    expect(menu, findsNothing);
  });

  testWidgets('hold only: a plain right-click shows nothing; letting go anywhere closes it', (tester) async {
    state(Presence.watching);
    final radial = await pump(tester);
    // A quick right-click: nothing shows, nothing is picked.
    var g = await rightDown(tester, const Offset(640, 360));
    await tester.pump(const Duration(milliseconds: 60));
    expect(menu, findsNothing);
    await g.up();
    await tester.pumpAndSettle();
    expect((radial.isOpen, menu.evaluate().isEmpty), (false, true), reason: 'a tap does nothing special');
    expect(coord.selfMember.value?.presence, Presence.watching);
    // Held in the centre: it shows, and letting go there closes it.
    g = await rightDown(tester, const Offset(640, 360));
    await tester.pump(const Duration(milliseconds: 200));
    expect(menu, findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
    expect(radial.isOpen, isFalse, reason: 'no click mode');
    expect(menu, findsNothing);
    // Dragged out and back to the centre: letting go cancels.
    g = await rightDown(tester, const Offset(640, 360));
    await g.moveTo(const Offset(640, 270));
    await tester.pump();
    expect(menu, findsOneWidget, reason: 'leaving the centre shows it at once');
    await g.moveTo(const Offset(640, 360));
    await g.up();
    await tester.pumpAndSettle();
    expect(radial.isOpen, isFalse);
    // A quick flick onto a slot: shown at once, and letting go closes it.
    g = await rightDown(tester, const Offset(640, 360));
    await g.moveTo(const Offset(640, 450));
    await tester.pump();
    expect(tester.widget<RadialMenuView>(menu).hot, 2, reason: 'Out, below');
    await g.up();
    await tester.pumpAndSettle();
    expect(radial.isOpen, isFalse);
  });

  testWidgets("out: Join below, BRB greyed with why; BRB: I'm back above", (tester) async {
    state(Presence.out);
    await pump(tester);
    final g = await rightDown(tester, const Offset(640, 360));
    await tester.pump(const Duration(milliseconds: 200));
    var items = tester.widget<RadialMenuView>(menu).items;
    expect([items[0].label, items[0].enabled, items[0].why, items[2].label], ['BRB', false, "you're out", 'Join']);
    state(Presence.brb);
    await tester.pump();
    items = tester.widget<RadialMenuView>(menu).items;
    expect(items[0].label, "I'm back");
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Space held: the pill fills and, from 150 ms, says what keeping on does; a lost key-up drops it',
      (tester) async {
    state(Presence.watching);
    _graph.navigation.place.value = Place.friend;
    addTearDown(() => _graph.navigation.place.value = Place.none);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(scoped(
        _graph,
        MaterialApp(
          theme: ThemeData.dark(),
          home: const AppKeys(child: Scaffold(body: Center(child: PlayerStatus()))),
        )));
    await tester.pump();
    expect(find.text('Keep holding: BRB'), findsNothing, reason: 'it plays: nothing to say');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));
    expect(coord.space.hold.value?.progress, greaterThan(0), reason: 'the fill follows the hold');
    expect(find.text('Keep holding: BRB'), findsNothing, reason: 'a tap shows no words');
    // The ticker counts from its first frame.
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 16));
    expect(coord.space.down, isTrue, reason: 'not yet BRB');
    expect(find.text('Keep holding: BRB'), findsOneWidget);
    expect(find.text('Let go: just pause'), findsOneWidget);
    // Key repeats change nothing.
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    expect(coord.space.down, isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(coord.space.down, isFalse);
    expect(coord.space.hold.value, isNull);
    // The window loses the keys mid-press: the press is dropped.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 700));
    expect(coord.space.down, isFalse, reason: 'never BRB in the background');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
