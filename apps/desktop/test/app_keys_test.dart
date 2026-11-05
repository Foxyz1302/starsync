import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/shell/app_shell.dart';
import 'package:starsync/src/shell/party_strip.dart';
import 'package:starsync/src/shell/session_player.dart' show PlayerMode;
import 'package:starsync/src/update/update_controller.dart';
import 'package:starsync/src/widgets/app_keys.dart';
import 'package:starsync/src/widgets/text_focus.dart';
import 'package:starsync/src/widgets/window_buttons.dart';

import 'package:starsync/src/session/navigation.dart' show Place;

import 'test_graph.dart';

/// The window, standing in for window_manager: what the window buttons
/// were asked to do.
final _window = FakeShell();

/// This file's composition root (see test_graph.dart).
final _graph = testGraph(shell: _window);

void main() {
  final session = _graph;
  final coord = session.coordinator;

  tearDown(() {
    session.navigation.place.value = Place.none;
    coord.serverState.value = null;
    coord.playback.alive.value = false;
    _window.calls.clear();
  });

  /// Whether [node] sits in the strip (or is a window button anywhere).
  bool inTopBar(FocusNode? node) {
    final c = node?.context;
    if (c == null) return false;
    return c.findAncestorWidgetOfExactType<PartyStrip>() != null ||
        c.findAncestorWidgetOfExactType<WindowButtons>() != null;
  }

  Future<void> pumpWindow(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      shortcuts: appShortcuts,
      home: AppKeys(
        onSpace: () {},
        child: AppShell(
          updates: UpdateController(currentVersion: '0.0.0-dev'),
          autoUpdateCheck: false,
          videoBuilder: (context, controls) => const SizedBox(),
        ),
      ),
    )));
    await tester.pumpAndSettle();
  }

  const arrows = [
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
  ];

  // Regression (P38): the arrow keys moved focus onto the strip's buttons
  // and Enter on a focused window × closed the app.
  testWidgets('arrows then Enter in the player: player keys, never a window or strip button', (tester) async {
    coord.playback.alive.value = true;
    await pumpWindow(tester);
    coord.serverState.value = StateBroadcast(
      eventId: 1,
      transport: 'held',
      position: 0,
      serverTime: DateTime.now().toUtc(),
      mediaId: 1,
      media: const {'name': 'Movie.mkv', 'size': 1, 'duration': 0},
      members: [MemberView(id: 'a', name: 'Alex', buffered: 0)],
    );
    session.navigation.place.value = Place.friend;
    await tester.pumpAndSettle();
    expect(tester.state<AppShellState>(find.byType(AppShell)).mode, PlayerMode.full);
    expect(find.byType(WindowButtons), findsOneWidget, reason: 'the strip shows the window buttons');

    for (final key in arrows) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(inTopBar(FocusManager.instance.primaryFocus), isFalse, reason: '$key moved focus to the top bar');
    }
    // Held down: the repeats stay the player's too.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(inTopBar(FocusManager.instance.primaryFocus), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_window.calls, isEmpty, reason: 'Enter pressed a window button');
    expect(textInputFocused(), isTrue, reason: 'Enter is the quick chat box');
    expect(tester.state<AppShellState>(find.byType(AppShell)).mode, PlayerMode.full);
  });

  testWidgets('the window buttons never take focus; arrows in the library stay off the strip', (tester) async {
    await pumpWindow(tester);
    expect(find.byType(WindowButtons), findsOneWidget);
    final buttons = [
      for (final n in FocusManager.instance.rootScope.descendants)
        if (n.context?.findAncestorWidgetOfExactType<WindowButtons>() != null) n,
    ];
    expect(buttons, isNotEmpty);
    expect(buttons.where((n) => n.canRequestFocus), isEmpty);
    for (final key in arrows) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(inTopBar(FocusManager.instance.primaryFocus), isFalse, reason: '$key moved focus to the top bar');
    }
    expect(_window.calls, isEmpty);
  });

  // Regression: Tab moved focus (out of the chat field onto a button) and
  // Space, the ready key, then pressed that button.
  testWidgets('Tab opens and closes chat without moving focus; Space is ready', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var readies = 0;
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      shortcuts: appShortcuts,
      home: AppKeys(
        onSpace: () => readies++,
        child: AppShell(
          updates: UpdateController(currentVersion: '0.0.0-dev'),
          autoUpdateCheck: false,
          windowControls: false,
          videoBuilder: (context, controls) => const SizedBox(),
        ),
      ),
    )));
    coord.serverState.value = StateBroadcast(
      eventId: 1,
      transport: 'held',
      position: 0,
      serverTime: DateTime.now().toUtc(),
      mediaId: 0,
      members: [MemberView(id: 'a', name: 'Alex', buffered: 0)],
    );
    session.navigation.place.value = Place.friend;
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('chat-panel'));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(textInputFocused(), isTrue, reason: 'opening the chat focuses its field');

    // From the field: closes the chat, focus goes back, not to a button.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(textInputFocused(), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(readies, 1);
    expect(panel, findsNothing, reason: 'Space pressed a focused chat button');
  });

  testWidgets('Ctrl+Shift+B opens Mark a problem; Esc closes it unmarked', (tester) async {
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      shortcuts: appShortcuts,
      home: const AppKeys(child: Scaffold(body: SizedBox())),
    )));
    final card = find.byKey(const ValueKey('mark-problem-card'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    expect(textInputFocused(), isTrue, reason: 'the note field takes the keys');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
  });
}
