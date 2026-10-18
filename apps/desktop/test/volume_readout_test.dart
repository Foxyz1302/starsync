import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' show VideoState;
import 'package:starsync/src/controls/model/controls_prefs.dart';
import 'package:starsync/src/controls/frame.dart';
import 'package:starsync/src/shell/session_player.dart';
import 'package:starsync/src/state/settings.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The wheel anywhere on the full player flashes the volume readout, in
// both skins, windowed and fullscreen, with the controls up or hidden.
// The picture is a black box with the session's controls on it (never a
// media_kit `Video`).

void main() {
  final coord = _graph.coordinator;
  final s = AppSettings.instance;

  // A real player for the volume steps to go to. Never disposed: the
  // steps' mpv calls start in the test's fake time and never finish, so a
  // dispose would wait on them for ever; the test process ending ends it.
  setUpAll(() async {
    MediaKit.ensureInitialized();
    await coord.media.start();
  });

  testWidgets('wheel over the video: readout for about a second', (tester) async {
    addTearDown(() => s.controlsSkin.value = ControlsSkin.standard);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final readout = find.byKey(const ValueKey('volume-readout'));
    double opacity() => readout.evaluate().isEmpty
        ? 0
        : tester.widget<AnimatedOpacity>(find.ancestor(of: readout, matching: find.byType(AnimatedOpacity)).first).opacity;
    Future<void> wheel() async {
      await tester.sendEventToBinding(
          PointerScrollEvent(kind: PointerDeviceKind.mouse, position: const Offset(640, 300), scrollDelta: const Offset(0, -60)));
      await tester.pump();
    }

    for (final skin in ControlsSkin.values) {
      for (final fullscreen in [false, true]) {
        final what = '${skin.name}, ${fullscreen ? 'fullscreen' : 'windowed'}';
        s.controlsSkin.value = skin;
        await tester.pumpWidget(scoped(_graph, MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SessionPlayer(
              key: ValueKey(what),
              mode: PlayerMode.full,
              fullscreen: fullscreen,
              onExpand: () {},
              onCollapse: () {},
              onClose: () {},
              onToggleFullscreen: () {},
              onToggleChat: () {},
              onChangeVideo: () {},
              onOpenAccounts: () {},
              onLeave: () {},
              windowControls: false,
              videoBuilder: (context, controls) => Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Colors.black),
                if (controls != null) controls(VideoState()),
              ]),
            ),
          ),
        )));
        await tester.pump();
        expect(opacity(), 0, reason: '$what: nothing before a step');

        // Controls up.
        expect(tester.state<ControlsFrameState>(find.byType(ControlsFrame)).visible, isTrue, reason: what);
        await wheel();
        expect(opacity(), 1, reason: '$what, controls up: shown');
        await tester.pump(const Duration(milliseconds: 900));
        expect(opacity(), 1, reason: '$what: still up within the second');
        await tester.pump(const Duration(milliseconds: 300));
        expect(opacity(), 0, reason: '$what: gone after the second');

        // Controls hidden (no mouse movement past the hide delay).
        await tester.pump(const Duration(seconds: 4));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.state<ControlsFrameState>(find.byType(ControlsFrame)).visible, isFalse, reason: what);
        await wheel();
        expect(opacity(), 1, reason: '$what, controls hidden: shown');
        await tester.pump(const Duration(milliseconds: 1200));
        expect(opacity(), 0, reason: '$what: gone after the second');
      }
    }
    await tester.pumpWidget(scoped(_graph, const SizedBox()));
    await tester.pump(const Duration(seconds: 5));
  });
}
