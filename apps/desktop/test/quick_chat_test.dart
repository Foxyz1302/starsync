import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' show VideoState;
import 'package:starsync/src/controls/frame.dart';
import 'package:starsync/src/session/navigation.dart' show Place;
import 'package:starsync/src/shell/quick_chat.dart';
import 'package:starsync/src/shell/session_player.dart';
import 'package:starsync/src/state/settings.dart';
import 'package:starsync/src/widgets/app_keys.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The quick chat box over the full player: Enter opens it whatever plays,
// keys go to it (not to the player), the cursor and the controls stay as
// the mouse left them, a send clears the draft and closes the box (your line comes back as your own chat toast or danmaku line, like everyone's), Esc
// and the idle time close it with the draft kept, the draft is the chat
// panel's. The picture is a black box with the session's controls on it
// (never a media_kit `Video`).

void main() {
  final coord = _graph.coordinator;
  final s = coord.settings;

  setUpAll(() async {
    MediaKit.ensureInitialized();
    await coord.media.start();
    _graph.navigation.place.value = Place.yours;
  });

  late TextEditingController draft;
  late QuickChat quick;
  var fullscreenToggles = 0;
  var readyToggles = 0;

  setUp(() {
    draft = TextEditingController();
    quick = QuickChat(draft: draft);
    fullscreenToggles = 0;
    readyToggles = 0;
  });

  tearDown(() {
    s.notifyStyle.value = NotifyStyle.toasts;
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(scoped(
      _graph,
      MaterialApp(
        theme: ThemeData.dark(),
        home: AppKeys(
          onToggleReady: () => readyToggles++,
          child: Scaffold(
            body: SessionPlayer(
              mode: PlayerMode.full,
              fullscreen: false,
              onExpand: () {},
              onCollapse: () {},
              onClose: () {},
              onToggleFullscreen: () => fullscreenToggles++,
              onToggleChat: () {},
              onChangeVideo: () {},
              onOpenAccounts: () {},
              onLeave: () {},
              windowControls: false,
              quickChat: quick,
              videoBuilder: (context, controls) => Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Colors.black),
                if (controls != null) controls(VideoState()),
              ]),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(scoped(_graph, const SizedBox()));
    await tester.pump(const Duration(seconds: 5));
    quick.dispose();
    draft.dispose();
  }

  ControlsFrameState frame(WidgetTester tester) => tester.state<ControlsFrameState>(find.byType(ControlsFrame));
  MouseCursor frameCursor(WidgetTester tester) => tester
      .widget<MouseRegion>(find.descendant(of: find.byType(ControlsFrame), matching: find.byType(MouseRegion)).first)
      .cursor;
  final field = find.byKey(const ValueKey('quick-chat-field'));
  bool fieldFocused() => quick.focus.hasFocus;

  Future<void> hideControls(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('Enter opens the box; keys go to it; the cursor and controls stay hidden', (tester) async {
    await mount(tester);
    // A still mouse over the bottom centre, where the box comes up.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(640, 690));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await hideControls(tester);
    expect(frame(tester).visible, isFalse);
    expect(frameCursor(tester), SystemMouseCursors.none);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(quick.open.value, isTrue);
    expect(fieldFocused(), isTrue, reason: 'the box has the keyboard at once');
    await tester.pump(const Duration(milliseconds: 400));
    expect(frame(tester).visible, isFalse, reason: 'typing is not mouse activity');
    expect(frameCursor(tester), SystemMouseCursors.none);
    final fieldWidget = tester.widget<TextField>(field);
    expect(fieldWidget.mouseCursor, SystemMouseCursors.none, reason: 'no I-beam over a still mouse');

    // Space and F reach the box, not ready or fullscreen.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(readyToggles, 0);
    expect(fullscreenToggles, 0);

    // Esc closes; the draft stays; the controls do not come back.
    await tester.enterText(field, 'half a thought');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 400));
    expect(quick.open.value, isFalse);
    expect(draft.text, 'half a thought');
    expect(frame(tester).visible, isFalse, reason: 'the box going is not mouse movement');
    expect(frameCursor(tester), SystemMouseCursors.none);

    // The player's keys are back.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(readyToggles, 1);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(fullscreenToggles, 1);

    // Enter brings the draft back.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(quick.open.value, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, 'half a thought');
    await unmount(tester);
  });

  testWidgets('a send goes to the chat, clears the draft and closes the box; the controls stay hidden', (tester) async {
    await mount(tester);
    await hideControls(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.enterText(field, 'hello there');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(quick.open.value, isFalse);
    expect(draft.text, isEmpty, reason: 'sent: the shared draft is cleared');
    await tester.pump(const Duration(milliseconds: 400));
    expect(frame(tester).visible, isFalse);
    // Empty Enter just closes.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 400));
    expect(quick.open.value, isFalse);
    await unmount(tester);
  });

  testWidgets('the box hides by itself after a while without typing; the draft stays', (tester) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.enterText(field, 'later');
    await tester.pump(QuickChat.idleClose - const Duration(seconds: 1));
    expect(quick.open.value, isTrue);
    await tester.enterText(field, 'later, maybe');
    await tester.pump(QuickChat.idleClose - const Duration(seconds: 1));
    expect(quick.open.value, isTrue, reason: 'typing restarts the wait');
    await tester.pump(const Duration(seconds: 2));
    expect(quick.open.value, isFalse);
    expect(draft.text, 'later, maybe');
    await unmount(tester);
  });
}
