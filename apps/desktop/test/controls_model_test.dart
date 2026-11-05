import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals/signals_flutter.dart';
import 'package:starsync/src/controls/controls_probe.dart';
import 'package:starsync/src/controls/model/controls_layout.dart';
import 'package:starsync/src/controls/model/controls_model.dart';
import 'package:starsync/src/controls/model/controls_prefs.dart';
import 'package:starsync/src/controls/session_controls.dart';
import 'package:starsync/src/playback/media_marks.dart';
import 'package:starsync/src/state/settings.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The controls model and its layout spec: which controls the bar has, in
// which order, what goes to ⚙; and both skins drawing the same order.

const none = <OptionalControl>{};

void main() {
  group('bar layout', () {
    test('play first, fullscreen last; no episode, no chapters: the base set', () {
      final bar = barControls(const ControlsSnapshot(), none);
      expect(bar.left, [BarControl.playPause, BarControl.volume, BarControl.time]);
      expect(bar.right, [BarControl.subtitles, BarControl.audio, BarControl.settings, BarControl.chat, BarControl.fullscreen]);
    });

    test('episodes and chapters slot in after play, in the spec order', () {
      final bar = barControls(
          const ControlsSnapshot(previousLabel: 'S1E6', nextLabel: 'S1E8', hasChapters: true, hasDuration: true), none);
      expect(bar.left, [
        BarControl.playPause,
        BarControl.previous,
        BarControl.next,
        BarControl.chapterPrevious,
        BarControl.chapterNext,
        BarControl.volume,
        BarControl.time,
      ]);
      expect(barControls(const ControlsSnapshot(nextLabel: 'Up'), none).left,
          [BarControl.playPause, BarControl.next, BarControl.volume, BarControl.time]);
    });

    test('hidden optional buttons leave the bar and show in ⋯', () {
      const s = ControlsSnapshot(hasChapters: true, hasDuration: true);
      final hidden = OptionalControl.values.toSet();
      final bar = barControls(s, hidden);
      expect(bar.left, [BarControl.playPause, BarControl.volume, BarControl.time]);
      expect(bar.right, [BarControl.settings, BarControl.fullscreen]);
      expect(menuActions(s, hidden), containsAllInOrder([ControlAction.subtitles, ControlAction.audio, ControlAction.chat]));
      final shown = menuActions(s, none);
      expect(shown, isNot(contains(ControlAction.subtitles)));
      expect(shown, isNot(contains(ControlAction.chat)));
    });

    test('⋯ menu: what plays and the server, in a fixed order; ⚙ is the panel', () {
      expect(menuActions(const ControlsSnapshot(), none), [
        ControlAction.changeVideo,
        ControlAction.screenshot,
        ControlAction.reload,
        ControlAction.markProblem,
        ControlAction.leave,
      ]);
      expect(menuActions(const ControlsSnapshot(hasChapters: true, hasDuration: true, hasLink: true), none), [
        ControlAction.changeVideo,
        ControlAction.copyLink,
        ControlAction.screenshot,
        ControlAction.reload,
        ControlAction.skipForward,
        ControlAction.chapters,
        ControlAction.markProblem,
        ControlAction.leave,
      ]);
      expect(controlTooltip(BarControl.settings, const ControlsSnapshot()), 'Player settings');
      expect(controlIcon(BarControl.settings, const ControlsSnapshot(panelOpen: true)), Icons.settings_rounded);
    });

    test('play / pause follows the session: playing, ready and waiting, not ready', () {
      expect(controlIcon(BarControl.playPause, const ControlsSnapshot(play: PlayState.playing)), Icons.pause_rounded);
      expect(controlIcon(BarControl.playPause, const ControlsSnapshot(play: PlayState.paused)), Icons.play_arrow_rounded);
      expect(controlIcon(BarControl.playPause, const ControlsSnapshot(play: PlayState.waiting)), Icons.check_rounded);
      expect(controlTooltip(BarControl.playPause, const ControlsSnapshot(play: PlayState.playing)),
          'Pause for everyone (Space)');
      expect(controlTooltip(BarControl.playPause, const ControlsSnapshot(alone: true)), 'Play (Space)');
    });

    test('episode buttons: the label and the keys', () {
      const s = ControlsSnapshot(previousLabel: 'S1E6 Before', nextLabel: 'S1E7 Battle with the Heroes');
      expect(controlTooltip(BarControl.next, s), 'Next: S1E7 Battle with the Heroes  (> or Shift+N)');
      expect(controlTooltip(BarControl.previous, s), 'Previous: S1E6 Before  (< or Shift+P)');
      expect(controlTooltip(BarControl.next, const ControlsSnapshot(nextLabel: 'Clip', nextIsUpNext: true)),
          'Up next: Clip  (> or Shift+N)');
      expect(controlEnabled(BarControl.chapterNext, const ControlsSnapshot(hasChapters: true)), isFalse,
          reason: 'no duration yet');
    });

    test('clock: elapsed / total, or the time left', () {
      const p = Duration(minutes: 6), d = Duration(minutes: 24);
      expect(clockText(p, d, TimeDisplay.elapsed), '6:00 / 24:00');
      expect(clockText(p, d, TimeDisplay.remaining), '-18:00');
      expect(clockText(p, Duration.zero, TimeDisplay.remaining), '6:00 / 0:00', reason: 'length unknown');
      expect(TimeDisplay.elapsed.toggled, TimeDisplay.remaining);
    });
  });

  group('both skins draw the model', () {
    final s = AppSettings.instance;
    final coord = _graph.coordinator;

    tearDown(() {
      s.controlsSkin.value = ControlsSkin.standard;
      s.hiddenControls.value = const {};
      s.progressLine.value = true;
      coord.playback.chapters.value = const [];
      coord.playback.duration.value = Duration.zero;
    });

    Future<PlayerControlsModel> pump(WidgetTester tester, ControlsSkin skin, {double width = 1280}) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      s.controlsSkin.value = skin;
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
      final shown = ValueNotifier(true);
      final hold = ControlsHold();
      addTearDown(() {
        model.dispose();
        shown.dispose();
        hold.dispose();
      });
      await tester.pumpWidget(scoped(_graph, MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SessionControls(model: model, shown: shown, hold: hold, onDoubleClick: () {}),
        ),
      )));
      await tester.pump();
      return model;
    }

    /// The bar's controls left to right, by their keys.
    List<BarControl> drawn(WidgetTester tester) {
      final found = <(double, BarControl)>[];
      for (final c in BarControl.values) {
        final f = find.byKey(ValueKey('control-${c.name}'));
        if (f.evaluate().isEmpty) continue;
        final r = tester.getRect(f);
        if (r.width > 0) found.add((r.left, c));
      }
      found.sort((a, b) => a.$1.compareTo(b.$1));
      return [for (final (_, c) in found) c];
    }

    for (final skin in ControlsSkin.values) {
      testWidgets('${skin.label}: the layout\'s order, play leftmost, fullscreen rightmost', (tester) async {
        coord.playback.duration.value = const Duration(minutes: 24);
        coord.playback.chapters.value = chaptersFromStarts([
          ('A', Duration.zero),
          ('B', const Duration(minutes: 2)),
        ], const Duration(minutes: 24));
        final model = await pump(tester, skin);
        final bar = model.bar.value;
        final want = [
          ...bar.left,
          ...bar.right,
        ].where((c) => skin == ControlsSkin.standard || c != BarControl.time).toList();
        expect(drawn(tester), want);
        expect(want.first, BarControl.playPause);
        expect(want.last, BarControl.fullscreen);
        expect(want, contains(BarControl.chapterNext));

        s.setControlShown(OptionalControl.chat, false);
        await tester.pump();
        expect(drawn(tester), isNot(contains(BarControl.chat)));
      });
    }

    for (final skin in ControlsSkin.values) {
      testWidgets('${skin.label}: the volume slider stays out in a wide bar, on hover in a narrow one', (tester) async {
        await pump(tester, skin);
        expect(find.byKey(const ValueKey('volume-bar')), findsOneWidget, reason: 'wide');
        // Room for every button, not for the slider too.
        await pump(tester, skin, width: skin == ControlsSkin.standard ? 612 : 400);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('volume-bar')), findsNothing, reason: 'narrow');
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('volume-control'))));
        addTearDown(mouse.removePointer);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('volume-bar')), findsOneWidget, reason: 'narrow, hovered');
      });
    }

    test('the video volume is kept for the next start', () {
      addTearDown(() => s.playerVolume.value = 100);
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
      addTearDown(model.dispose);
      model.setVolume(40);
      expect(s.playerVolume.value, 40);
      model.toggleMute();
      expect(s.playerVolume.value, 0);
      model.setVolume(400);
      expect(s.playerVolume.value, 150, reason: 'clamped to mpv\'s volume-max');
    });

    for (final skin in ControlsSkin.values) {
      testWidgets('${skin.label}: ⚙ opens and closes the panel, the top bar\'s ⋯ lists the rest', (tester) async {
        final model = await pump(tester, skin);
        await tester.tap(find.byKey(const ValueKey('control-settings')));
        await tester.pump();
        expect(model.panelOpen.value, isTrue);
        await tester.tap(find.byKey(const ValueKey('control-settings')));
        await tester.pump();
        expect(model.panelOpen.value, isFalse);
        expect(find.byKey(const ValueKey('controls-menu-reload')), findsNothing, reason: '⚙ opens no menu');
        await tester.tap(find.byKey(const ValueKey('controls-more')));
        await tester.pumpAndSettle();
        for (final a in [ControlAction.changeVideo, ControlAction.reload, ControlAction.markProblem, ControlAction.leave]) {
          expect(find.byKey(ValueKey('controls-menu-${a.name}')), findsOneWidget, reason: a.name);
        }
        expect(find.byKey(const ValueKey('controls-menu-chapters')), findsNothing, reason: 'no chapters');
        await tester.tapAt(const Offset(5, 300));
        await tester.pumpAndSettle();
      });
    }

    testWidgets('Minimal hidden: the timeline stays as a line unless switched off', (tester) async {
      await pump(tester, ControlsSkin.minimal);
      double opacity() => tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('minimal-timeline-wrap'))).opacity;
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(opacity(), 1, reason: 'hidden, line on');
      s.progressLine.value = false;
      await tester.pump();
      expect(opacity(), 0, reason: 'hidden, line off');
    });

    testWidgets('Standard hidden: a thin progress line unless switched off', (tester) async {
      await pump(tester, ControlsSkin.standard);
      expect(find.byKey(const ValueKey('progress-line-standard')), findsNothing, reason: 'controls up');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('progress-line-standard')), findsOneWidget);
      s.progressLine.value = false;
      await tester.pump();
      expect(find.byKey(const ValueKey('progress-line-standard')), findsNothing);
    });
  });
}
