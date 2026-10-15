import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/shell/app_shell.dart';
import 'package:starsync/src/state/session_state.dart';
import 'package:starsync/src/update/update_controller.dart';
import 'package:starsync/src/widgets/app_keys.dart';
import 'package:starsync/src/widgets/text_focus.dart';

void main() {
  final session = SessionState.instance;
  final coord = session.coordinator;

  tearDown(() {
    session.route.value = AppRoute.home;
    coord.serverState.value = null;
  });

  // Regression: Tab moved focus (out of the chat field onto a button) and
  // Space, the ready key, then pressed that button.
  testWidgets('Tab opens and closes chat without moving focus; Space is ready', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var readies = 0;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      shortcuts: appShortcuts,
      home: AppKeys(
        onToggleReady: () => readies++,
        child: AppShell(
          updates: UpdateController(currentVersion: '0.0.0-dev'),
          autoUpdateCheck: false,
          windowControls: false,
          videoBuilder: (context, controls) => const SizedBox(),
        ),
      ),
    ));
    coord.serverState.value = StateBroadcast(
      eventId: 1,
      transport: 'held',
      position: 0,
      serverTime: DateTime.now().toUtc(),
      mediaId: 0,
      members: [MemberView(id: 'a', name: 'Alex', ready: false, inSet: false, buffered: 0, stale: false)],
    );
    session.route.value = AppRoute.session;
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
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      shortcuts: appShortcuts,
      home: const AppKeys(child: Scaffold(body: SizedBox())),
    ));
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
