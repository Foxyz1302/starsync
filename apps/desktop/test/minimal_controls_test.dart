import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/controls/frame.dart';
import 'package:starsync/src/controls/minimal/style.dart';
import 'package:starsync/src/controls/minimal/timeline.dart';
import 'package:starsync/src/controls/model/controls_prefs.dart';
import 'package:starsync/src/controls/volume.dart';
import 'package:starsync/src/playback/media_marks.dart';
import 'package:starsync/src/shell/settings_tab.dart';
import 'package:starsync/src/state/settings.dart';
import 'package:starsync/src/update/update_controller.dart';
import 'package:starsync/src/widgets/app_menu.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The Minimal skin's pieces and the shared controls frame (never the
// session screen or a media_kit `Video`).

Duration m(int min, [int sec = 0]) => Duration(minutes: min, seconds: sec);

final chapters = chaptersFromStarts([
  ('Prologue', Duration.zero),
  ('Opening', m(0, 30)),
  ('Part A', m(2)),
  ('Ending', m(20)),
  ('Part B', m(21, 30)),
], m(24));

Widget host(Widget child, {double width = 800}) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 40),
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

String text(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

MinimalTimelinePainter painter(WidgetTester tester) => tester
    .widget<CustomPaint>(find.descendant(
        of: find.byKey(const ValueKey('minimal-timeline')), matching: find.byType(CustomPaint)))
    .painter! as MinimalTimelinePainter;

Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  addTearDown(mouse.removePointer);
  return mouse;
}

void main() {
  group('timeline math', () {
    test('missing part: from the cache end (or the position) to the end', () {
      expect(uncachedFrom(position: m(6), buffered: m(9), duration: m(24)), 9 / 24);
      expect(uncachedFrom(position: m(6), buffered: m(5), duration: m(24)), 6 / 24, reason: 'stale cache end');
      expect(uncachedFrom(position: m(6), buffered: Duration.zero, duration: m(24)), isNull, reason: 'unknown');
      expect(uncachedFrom(position: m(6), buffered: m(24), duration: m(24)), isNull, reason: 'cached to the end');
      expect(uncachedFrom(position: m(6), buffered: m(9), duration: Duration.zero), isNull);
    });

    test('cache label: seconds ahead, under 60 s, not when cached to the end', () {
      expect(cacheLabel(position: m(6), buffered: m(6, 30), duration: m(24)), '30s');
      expect(cacheLabel(position: m(6), buffered: m(6), duration: m(24)), '0s');
      expect(cacheLabel(position: m(6), buffered: m(5), duration: m(24)), '0s');
      expect(cacheLabel(position: m(6), buffered: m(7), duration: m(24)), isNull, reason: 'a minute or more');
      expect(cacheLabel(position: m(23, 40), buffered: m(24), duration: m(24)), isNull, reason: 'eof cached');
      expect(cacheLabel(position: m(6), buffered: Duration.zero, duration: m(24)), isNull);
    });

    test('band size: the full band shown, the line hidden, scaled', () {
      expect(minimalBandSize(1, 1), MinimalTimelineSpec.size);
      expect(minimalBandSize(0, 1), MinimalTimelineSpec.lineSize);
      expect(minimalBandSize(1, 1.25), MinimalTimelineSpec.size * 1.25);
    });
  });

  group('timeline', () {
    testWidgets('played part, elapsed left, remaining right, cache label', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(MinimalTimeline(
          position: m(6), duration: m(24), buffered: m(6, 30), chapters: chapters, onSeek: (_) {}))));
      final bar = tester.getRect(find.byKey(const ValueKey('minimal-timeline')));
      expect(bar.width, 800);
      expect(bar.height, MinimalTimelineSpec.size);
      final p = painter(tester);
      expect(p.progress, 0.25);
      expect(p.lineX(800), 200);
      expect(p.visibility, 1);
      expect(p.uncached, 6.5 / 24);
      expect(p.elapsed, '6:00');
      expect(p.right, '-18:00');
      expect(p.cache, '30s');
      expect(p.textOpacity, 1);
    });

    testWidgets('the total instead of the time left', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(MinimalTimeline(
          position: m(6), duration: m(24), remaining: false, onSeek: (_) {}))));
      expect(painter(tester).right, '24:00');
    });

    testWidgets('a press on the right-hand time switches it, no seek', (tester) async {
      final seeks = <Duration>[];
      var toggled = 0;
      await tester.pumpWidget(scoped(_graph, host(MinimalTimeline(
          position: m(6), duration: m(24), onSeek: seeks.add, onToggleTime: () => toggled++))));
      final bar = tester.getRect(find.byKey(const ValueKey('minimal-timeline')));
      await tester.tapAt(Offset(bar.right - 20, bar.center.dy));
      expect(toggled, 1);
      expect(seeks, isEmpty);
    });

    testWidgets('a mark at each chapter start', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(MinimalTimeline(position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {}))));
      expect(painter(tester).chapters, [for (final c in chapters) c.start.inSeconds / m(24).inSeconds]);
    });

    testWidgets('hover: chapter title over the time, above the band', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(MinimalTimeline(position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {}))));
      final bar = tester.getRect(find.byKey(const ValueKey('minimal-timeline')));
      final mouse = await mouseAt(tester, Offset.zero);
      // 1:51 of 24:00: inside "Opening".
      await mouse.moveTo(Offset(bar.left + bar.width * 111 / (24 * 60) + 0.2, bar.center.dy));
      await tester.pump();
      expect(text(tester, 'minimal-hover-chapter'), 'Opening');
      expect(text(tester, 'minimal-hover-time'), '1:51');
      final title = tester.getRect(find.byKey(const ValueKey('minimal-hover-chapter')));
      final time = tester.getRect(find.byKey(const ValueKey('minimal-hover-time')));
      expect(title.bottom, lessThanOrEqualTo(time.top), reason: 'title above');
      expect(time.bottom, lessThan(bar.top), reason: 'above the band');
      expect(painter(tester).hoverX, isNotNull);
      await mouse.moveTo(Offset(bar.left + bar.width * (10 / 24), bar.center.dy));
      await tester.pump();
      expect(text(tester, 'minimal-hover-chapter'), 'Part A');
      await mouse.moveTo(Offset(bar.left, bar.top - 200));
      await tester.pump();
      expect(find.byKey(const ValueKey('minimal-hover-time')), findsNothing);
    });

    testWidgets('a press on a hovered chapter mark jumps to its chapter', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(scoped(_graph, host(MinimalTimeline(position: m(1), duration: m(24), chapters: chapters, onSeek: seeks.add))));
      final bar = tester.getRect(find.byKey(const ValueKey('minimal-timeline')));
      final at = Offset(bar.left + bar.width * 2 / 24 + 3, bar.top + 2);
      final mouse = await mouseAt(tester, at);
      await mouse.moveTo(at);
      await tester.pump();
      expect(painter(tester).hoveredChapter, 2);
      expect(text(tester, 'minimal-hover-time'), '2:00');
      await mouse.down(at);
      await mouse.up();
      await tester.pump();
      expect(seeks, [m(2)]);
    });

    testWidgets('hidden controls: the progress line, no text, no input', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(scoped(_graph, host(MinimalTimeline(
          position: m(12), duration: m(24), buffered: m(14), chapters: chapters, expanded: false, onSeek: seeks.add))));
      final bar = tester.getRect(find.byKey(const ValueKey('minimal-timeline')));
      expect(bar.height, MinimalTimeline.collapsedHeight);
      final p = painter(tester);
      expect(p.progress, 0.5);
      expect(p.visibility, 0);
      expect(p.textOpacity, 0);
      final mouse = await mouseAt(tester, Offset.zero);
      await mouse.moveTo(bar.center);
      await tester.pump();
      expect(find.byKey(const ValueKey('minimal-hover-time')), findsNothing);
      await tester.tapAt(bar.center);
      expect(seeks, isEmpty);
    });

    testWidgets('press seeks, every drag move seeks, release holds the target', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(scoped(_graph, host(MinimalTimeline(position: m(1), duration: m(24), chapters: chapters, onSeek: seeks.add))));
      final bar = tester.getRect(find.byKey(const ValueKey('minimal-timeline')));
      final g0 = await tester.startGesture(Offset(bar.left + bar.width / 4, bar.center.dy), kind: PointerDeviceKind.mouse);
      expect(seeks, [m(6)], reason: 'the press seeks');
      await g0.moveTo(Offset(bar.left + bar.width / 2, bar.center.dy));
      await tester.pump();
      expect(painter(tester).elapsed, formatClock(seeks.last), reason: 'follows the drag');
      await g0.moveTo(Offset(bar.left + bar.width * 3 / 4, bar.center.dy));
      await g0.up();
      await tester.pump();
      expect(seeks, hasLength(3), reason: 'release at the last move: no repeat');
      expect(painter(tester).progress, 0.75, reason: 'shows the target until the position catches up');
      await tester.pump(const Duration(seconds: 3));
      expect(painter(tester).progress, 1 / 24, reason: 'never confirmed: back to the position');
    });
  });

  group('controls frame', () {
    Widget frame({Duration hideAfter = const Duration(seconds: 3), Widget? child}) => MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: ControlsFrame(
              hideAfter: hideAfter,
              builder: (context, visible) => Stack(children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Opacity(opacity: visible ? 1 : 0, child: child ?? const SizedBox(height: 40)),
                    MinimalTimeline(
                        position: m(6), duration: m(24), chapters: chapters, expanded: visible, onSeek: (_) {}),
                  ]),
                ),
              ]),
            ),
          ),
        );

    bool up(WidgetTester tester) => tester.state<ControlsFrameState>(find.byType(ControlsFrame)).visible;

    testWidgets('hide after the delay, mouse brings them back', (tester) async {
      await tester.pumpWidget(scoped(_graph, frame()));
      expect(up(tester), isTrue);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(up(tester), isFalse);
      expect(tester.getRect(find.byKey(const ValueKey('minimal-timeline'))).height, MinimalTimeline.collapsedHeight,
          reason: 'still visible as a thin line');
      final mouse = await mouseAt(tester, const Offset(400, 200));
      await mouse.moveTo(const Offset(420, 220));
      await tester.pump();
      expect(up(tester), isTrue);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(tester.getRect(find.byKey(const ValueKey('minimal-timeline'))).height, MinimalTimelineSpec.size,
          reason: 'grown back (animated)');
    });

    testWidgets('a long drag on the timeline keeps the controls up', (tester) async {
      await tester.pumpWidget(scoped(_graph, frame()));
      final bar = tester.getRect(find.byKey(const ValueKey('minimal-timeline')));
      final g = await tester.startGesture(Offset(bar.left + 100, bar.center.dy), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await g.moveTo(Offset(bar.left + 300, bar.center.dy));
      await tester.pump(const Duration(seconds: 5));
      expect(up(tester), isTrue, reason: 'held while dragging');
      await g.up();
      await g.removePointer();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(up(tester), isFalse, reason: 'hides again after release');
    });

    testWidgets('an open app menu keeps the controls up', (tester) async {
      await tester.pumpWidget(scoped(_graph, frame(
        child: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open'),
            onPressed: () => showAppMenu<int>(context, items: const [AppMenuItem(value: 1, label: 'One')]),
            child: const Text('open'),
          ),
        ),
      )));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.text('One'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(up(tester), isTrue);
      await tester.tapAt(const Offset(5, 5)); // outside: dismiss
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(up(tester), isFalse);
    });

    testWidgets('double-click on the picture, not on the bars', (tester) async {
      var doubles = 0;
      await tester.pumpWidget(scoped(_graph, MaterialApp(
        home: ControlsFrame(
          onDoubleClick: () => doubles++,
          barBottom: 100,
          builder: (context, visible) => const SizedBox.expand(),
        ),
      )));
      Future<void> twice(Offset at) async {
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(at, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 500));
      }

      await twice(const Offset(400, 200));
      expect(doubles, 1);
      await twice(const Offset(400, 580));
      expect(doubles, 1, reason: 'on the bottom bar');
    });
  });

  group('buttons', () {
    testWidgets('count badge in the accent; tooltip on the app glass', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(const Row(children: [
        MinimalButton(key: ValueKey('subs'), icon: Icons.subtitles_outlined, tooltip: 'Subtitles', badge: 2, onPressed: null),
        MinimalButton(key: ValueKey('plain'), icon: Icons.menu, tooltip: 'Menu', onPressed: null),
      ]))));
      expect(
          find.descendant(of: find.byKey(const ValueKey('subs')), matching: find.byKey(const ValueKey('minimal-badge'))),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('subs')), matching: find.text('2')), findsOneWidget);
      expect(
          find.descendant(of: find.byKey(const ValueKey('plain')), matching: find.byKey(const ValueKey('minimal-badge'))),
          findsNothing);
      final tip = tester.widget<Tooltip>(
          find.descendant(of: find.byKey(const ValueKey('subs')), matching: find.byType(Tooltip)).first);
      expect((tip.decoration as BoxDecoration).color, MinimalStyle.tip);
    });

    testWidgets('volume: click mutes and restores, wheel steps 5', (tester) async {
      final got = <double>[];
      var volume = 80.0;
      var before = 80.0;
      await tester.pumpWidget(scoped(_graph, host(StatefulBuilder(
        builder: (context, setState) => Row(children: [
          VolumeControl(
            volume: volume,
            onChanged: (v) => setState(() => got.add(volume = v)),
            onToggleMute: () => setState(() {
              if (volume > 0) {
                before = volume;
                got.add(volume = 0);
              } else {
                got.add(volume = before);
              }
            }),
            button: (context, icon, color, tip, onPressed) =>
                MinimalButton(key: const ValueKey('speaker'), icon: icon, tooltip: tip, onPressed: onPressed),
          ),
        ]),
      ))));
      await tester.tap(find.byKey(const ValueKey('speaker')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('speaker')));
      await tester.pump();
      final at = tester.getCenter(find.byKey(const ValueKey('speaker')));
      await tester.sendEventToBinding(
          PointerScrollEvent(kind: PointerDeviceKind.mouse, position: at, scrollDelta: const Offset(0, -60)));
      await tester.pump();
      expect(got, [0, 80, 85], reason: 'a notch is one step');
      for (var i = 0; i < 3; i++) {
        await tester.sendEventToBinding(
            PointerScrollEvent(kind: PointerDeviceKind.mouse, position: at, scrollDelta: const Offset(0, 20)));
      }
      await tester.pump();
      expect(got, [0, 80, 85, 80], reason: 'smooth deltas add up to a step');
    });
  });

  group('volume wheel', () {
    testWidgets('anywhere: vertical steps; lists scroll instead; sideways is nothing', (tester) async {
      final steps = <int>[];
      final list = ScrollController();
      addTearDown(list.dispose);
      await tester.pumpWidget(scoped(_graph, MaterialApp(
        home: VolumeWheel(
          onStep: steps.add,
          child: Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            Positioned(
              right: 0,
              top: 0,
              width: 200,
              height: 200,
              child: ListView(controller: list, children: [for (var i = 0; i < 50; i++) Text('row $i')]),
            ),
          ]),
        ),
      )));
      Future<void> wheel(Offset at, Offset delta) =>
          tester.sendEventToBinding(PointerScrollEvent(kind: PointerDeviceKind.mouse, position: at, scrollDelta: delta));
      await wheel(const Offset(100, 400), const Offset(0, -60));
      await wheel(const Offset(100, 400), const Offset(0, 60));
      expect(steps, [1, -1], reason: 'up louder, down quieter');
      await wheel(const Offset(100, 400), const Offset(60, 0));
      await wheel(const Offset(100, 400), const Offset(60, -10));
      expect(steps, [1, -1], reason: 'sideways');
      await wheel(const Offset(700, 100), const Offset(0, 60));
      await tester.pump();
      expect(steps, [1, -1], reason: 'the list took it');
      expect(list.offset, greaterThan(0));
    });
  });

  test('the old uosc choice becomes Minimal', () {
    expect(ControlsSkin.fromStored(null), ControlsSkin.standard);
    expect(ControlsSkin.fromStored(null, legacyMpvControls: true), ControlsSkin.minimal);
    expect(ControlsSkin.fromStored(null, legacyMpvControls: false), ControlsSkin.standard);
    expect(ControlsSkin.fromStored('standard', legacyMpvControls: true), ControlsSkin.standard,
        reason: 'a saved skin wins');
    expect(ControlsSkin.fromStored('minimal'), ControlsSkin.minimal);
  });

  testWidgets('Settings: "Player design", Standard by default, Minimal picked live', (tester) async {
    final s = AppSettings.instance;
    s.controlsSkin.value = ControlsSkin.standard;
    addTearDown(() => s.controlsSkin.value = ControlsSkin.standard);
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(scoped(_graph, MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SettingsTab(
          section: SettingsSection.player,
          onSection: (_) {},
          updates: UpdateController(currentVersion: '0.0.0-dev'),
        ),
      ),
    )));
    final design = find.byKey(const ValueKey('player-design'));
    expect(find.text('Player design'), findsOneWidget);
    expect(tester.widget<AppSelect<ControlsSkin>>(design).value, ControlsSkin.standard);
    await tester.tap(design);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Minimal').last);
    await tester.pumpAndSettle();
    expect(s.controlsSkin.value, ControlsSkin.minimal);
    expect(tester.widget<AppSelect<ControlsSkin>>(design).value, ControlsSkin.minimal);
  });
}
