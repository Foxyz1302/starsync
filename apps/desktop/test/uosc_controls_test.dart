import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;
import 'package:watch_together/src/controls/uosc/buttons.dart';
import 'package:watch_together/src/controls/uosc/controls.dart';
import 'package:watch_together/src/controls/uosc/menu.dart';
import 'package:watch_together/src/controls/uosc/style.dart';
import 'package:watch_together/src/controls/uosc/timeline.dart';
import 'package:watch_together/src/controls/volume.dart' show VolumeWheel;
import 'package:watch_together/src/jellyfin/track_prefs.dart';
import 'package:watch_together/src/playback/media_marks.dart';
import 'package:watch_together/src/playback/playback_controller.dart' show RenderMode;
import 'package:watch_together/src/screens/session/player_controls.dart' show TrackPick;
import 'package:watch_together/src/shaders/shader_presets.dart';
import 'package:watch_together/src/shell/settings_tab.dart';
import 'package:watch_together/src/state/settings.dart';
import 'package:watch_together/src/update/update_controller.dart';
import 'package:watch_together/src/widgets/app_menu.dart';

// The experimental mpv-style (uosc) controls, piece by piece (never the
// session screen or a media_kit `Video`).

Duration m(int min, [int sec = 0]) => Duration(minutes: min, seconds: sec);

final chapters = chaptersFromStarts([
  ('Prologue', Duration.zero),
  ('Opening', m(0, 30)),
  ('Part A', m(2)),
  ('Ending', m(20)),
  ('Part B', m(21, 30)),
], m(24));

Widget host(Widget child, {double width = 960}) => MaterialApp(
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

String boxText(WidgetTester tester, String key) => tester
    .widget<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))
    .data!;

UoscTimelinePainter painter(WidgetTester tester) => tester
    .widget<CustomPaint>(find.descendant(
        of: find.byKey(const ValueKey('uosc-timeline')), matching: find.byType(CustomPaint)))
    .painter! as UoscTimelinePainter;

Future<TestGesture> mouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  addTearDown(mouse.removePointer);
  return mouse;
}

const tracks = [
  MpvTrack(id: 1, type: JellyfinStreamType.audio, language: 'jpn', codec: 'eac3', channels: 2, selected: true),
  MpvTrack(id: 2, type: JellyfinStreamType.audio, language: 'eng', codec: 'aac', channels: 6, title: 'Dub'),
  MpvTrack(id: 1, type: JellyfinStreamType.subtitle, language: 'eng', codec: 'ass', title: 'Full'),
  MpvTrack(id: 2, type: JellyfinStreamType.subtitle, language: 'eng', codec: 'ass', title: 'Signs'),
];

void main() {
  test('uosc clock: mm:ss, hh:mm:ss from an hour', () {
    expect(formatUoscTime(Duration.zero), '00:00');
    expect(formatUoscTime(m(1, 51)), '01:51');
    expect(formatUoscTime(m(1, 51), withHours: true), '00:01:51');
    expect(formatUoscTime(const Duration(hours: 1, minutes: 2, seconds: 3)), '01:02:03');
    expect(formatUoscTime(const Duration(seconds: -4)), '00:00');
  });

  group('timeline math (uosc)', () {
    test('uosc clock: trimmed by the duration, minus kept', () {
      expect(uoscClock(m(4, 22), const Duration(hours: 1, minutes: 52)), '00:04:22');
      expect(uoscClock(-const Duration(hours: 1, minutes: 47, seconds: 30), const Duration(hours: 1, minutes: 52)),
          '-01:47:30');
      expect(uoscClock(m(6), m(24)), '06:00');
      expect(uoscClock(-m(18), m(24)), '-18:00');
      expect(uoscClock(const Duration(seconds: 7), const Duration(seconds: 40)), '07');
      expect(uoscClock(Duration.zero, m(24)), '00:00');
    });

    test('uncached part: from the cache end (or the position) to the end', () {
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

    test('geometry: times map around the position line', () {
      const g = UoscTimelineGeometry(width: 1000, size: 40, progress: 0.5);
      expect(g.lineLeft, 499);
      expect(g.lineRight, 501);
      expect(g.x(0), 0.5);
      expect(g.x(1), 1000 - 0.5);
      expect(g.x(0.75), greaterThan(g.lineRight), reason: 'past the line');
      expect(g.fractionAt(500), 0.5, reason: 'on the line: the position');
      expect(g.fractionAt(0), 0);
      expect(g.fractionAt(1000), 1);
      expect(g.fractionAt(g.x(0.25)), moreOrLessEquals(0.25, epsilon: 0.001));
      expect(g.fractionAt(g.x(0.75)), moreOrLessEquals(0.75, epsilon: 0.001));
      // Collapsing: the line widens to 20 px over the last eighth.
      expect(UoscTimelineGeometry.sizeAt(1), 40);
      expect(UoscTimelineGeometry.sizeAt(0), 2);
      expect(UoscTimelineGeometry.lineWidthAt(40), 2);
      expect(UoscTimelineGeometry.lineWidthAt(2), 20);
    });
  });

  group('timeline', () {
    testWidgets('position line, elapsed left, remaining right, cache label', (tester) async {
      await tester.pumpWidget(host(UoscTimeline(
          position: m(6), duration: m(24), buffered: m(6, 30), chapters: chapters, onSeek: (_) {})));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      expect(bar.width, 800, reason: 'the whole width (the test window)');
      expect(bar.height, UoscTimeline.height);
      final p = painter(tester);
      expect(p.played, 0.25);
      expect(p.geometry.lineRight - p.geometry.lineLeft, UoscTimelineSpec.lineWidth, reason: 'a line, no fill');
      expect(p.visibility, 1);
      expect(p.uncached, 6.5 / 24);
      expect(p.elapsed, '06:00');
      expect(p.remaining, '-18:00');
      expect(p.cache, '30s');
      expect(p.textOpacity, 1);
    });

    testWidgets('a diamond on the top edge at each chapter start', (tester) async {
      await tester.pumpWidget(host(UoscTimeline(
          position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {})));
      expect(painter(tester).chapters, [for (final c in chapters) c.start.inSeconds / m(24).inSeconds]);
    });

    testWidgets('hover: chapter title over the hover time, above the bar', (tester) async {
      await tester.pumpWidget(host(UoscTimeline(
          position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {})));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      final mouse = await mouseAt(tester, Offset.zero);
      final g = painter(tester).geometry;
      // 01:51 of 24:00: inside "Opening".
      await mouse.moveTo(Offset(bar.left + g.x(111 / (24 * 60)) + 0.2, bar.center.dy));
      await tester.pump();
      expect(boxText(tester, 'uosc-hover-chapter'), 'Opening');
      expect(boxText(tester, 'uosc-hover-time'), '01:51');
      final title = tester.getRect(find.byKey(const ValueKey('uosc-hover-chapter')));
      final time = tester.getRect(find.byKey(const ValueKey('uosc-hover-time')));
      expect(title.bottom, lessThanOrEqualTo(time.top), reason: 'two boxes, title above');
      expect(time.bottom, lessThan(bar.top - 4), reason: 'clear of the diamonds');
      expect(painter(tester).hoverX, isNotNull);
      await mouse.moveTo(Offset(bar.left + bar.width * (10 / 24), bar.center.dy));
      await tester.pump();
      expect(boxText(tester, 'uosc-hover-chapter'), 'Part A');
      await mouse.moveTo(Offset(bar.left, bar.top - 200));
      await tester.pump();
      expect(find.byKey(const ValueKey('uosc-hover-time')), findsNothing);
    });

    testWidgets('a press on a hovered diamond jumps to its chapter', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(host(UoscTimeline(
          position: m(1), duration: m(24), chapters: chapters, onSeek: seeks.add)));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      final at = Offset(bar.left + painter(tester).geometry.x(2 / 24) + 3, bar.top + 2);
      final mouse = await mouseAt(tester, at);
      await mouse.moveTo(at);
      await tester.pump();
      expect(painter(tester).hoveredChapter, 2);
      expect(boxText(tester, 'uosc-hover-time'), '02:00');
      await mouse.down(at);
      await mouse.up();
      await tester.pump();
      expect(seeks, [m(2)]);
    });

    testWidgets('hidden controls: the progress line, no text, no input', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(host(UoscTimeline(
          position: m(12), duration: m(24), buffered: m(14), chapters: chapters, expanded: false, onSeek: seeks.add)));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      expect(bar.height, UoscTimeline.collapsedHeight);
      final p = painter(tester);
      expect(p.played, 0.5);
      expect(p.visibility, 0);
      expect(p.geometry.lineWidth, UoscTimelineSpec.progressLineWidth);
      expect(p.textOpacity, 0);
      final mouse = await mouseAt(tester, Offset.zero);
      await mouse.moveTo(bar.center);
      await tester.pump();
      expect(find.byKey(const ValueKey('uosc-hover-time')), findsNothing);
      await tester.tapAt(bar.center);
      expect(seeks, isEmpty);
    });

    testWidgets('press seeks, every drag move seeks, release holds the target', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(host(UoscTimeline(
          position: m(1), duration: m(24), chapters: chapters, onSeek: seeks.add)));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      final g = painter(tester).geometry;
      final g0 = await tester.startGesture(Offset(bar.left + g.x(0.25), bar.center.dy), kind: PointerDeviceKind.mouse);
      expect(seeks, hasLength(1), reason: 'the press seeks');
      expect(seeks.single.inSeconds, closeTo(6 * 60, 2));
      await g0.moveTo(Offset(bar.left + bar.width / 2, bar.center.dy));
      await tester.pump();
      expect(painter(tester).elapsed, uoscClock(seeks.last, m(24)), reason: 'follows the drag');
      await g0.moveTo(Offset(bar.left + bar.width * 3 / 4, bar.center.dy));
      await g0.up();
      await tester.pump();
      expect(seeks, hasLength(3), reason: 'release at the last move: no repeat');
      expect(painter(tester).played, moreOrLessEquals(seeks.last.inMilliseconds / m(24).inMilliseconds, epsilon: 0.01),
          reason: 'shows the target until the position catches up');
      await tester.pump(const Duration(seconds: 3));
      expect(painter(tester).played, 1 / 24, reason: 'never confirmed: back to the position');
    });
  });

  group('controls frame', () {
    Widget frame({List<Widget> left = const [], Duration hideAfter = const Duration(seconds: 3)}) => MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: UoscControls(
              hideAfter: hideAfter,
              left: left,
              right: const [UoscButton(key: ValueKey('right'), icon: Icons.fullscreen, tooltip: 'Fullscreen', onPressed: null)],
              timeline: (context, expanded) => UoscTimeline(
                  position: m(6), duration: m(24), chapters: chapters, expanded: expanded, onSeek: (_) {}),
            ),
          ),
        );

    double buttonsOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(find.descendant(
            of: find.byKey(const ValueKey('uosc-buttons')), matching: find.byType(AnimatedOpacity)).first)
        .opacity;

    testWidgets('buttons above a full-width timeline; hide after the delay, mouse brings them back',
        (tester) async {
      await tester.pumpWidget(frame());
      final screen = tester.getSize(find.byType(UoscControls));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      expect(bar.width, screen.width);
      expect(bar.bottom, screen.height);
      expect(tester.getRect(find.byKey(const ValueKey('right'))).bottom, lessThanOrEqualTo(bar.top));
      expect(buttonsOpacity(tester), 1);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(buttonsOpacity(tester), 0);
      expect(tester.getRect(find.byKey(const ValueKey('uosc-timeline'))).height, UoscTimeline.collapsedHeight,
          reason: 'still visible as a thin line');
      final mouse = await mouseAt(tester, const Offset(400, 200));
      await mouse.moveTo(const Offset(420, 220));
      await tester.pump();
      expect(buttonsOpacity(tester), 1);
      await tester.pump(UoscTimeline.animation);
      expect(tester.getRect(find.byKey(const ValueKey('uosc-timeline'))).height, UoscTimeline.height,
          reason: 'grown back (animated)');
    });

    testWidgets('a long drag keeps the controls up', (tester) async {
      await tester.pumpWidget(frame());
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      final g = await tester.startGesture(Offset(bar.left + 100, bar.center.dy), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await g.moveTo(Offset(bar.left + 300, bar.center.dy));
      await tester.pump(const Duration(seconds: 5));
      expect(buttonsOpacity(tester), 1, reason: 'held while dragging');
      expect(tester.getRect(find.byKey(const ValueKey('uosc-timeline'))).height, UoscTimeline.height);
      await g.up();
      await g.removePointer();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(buttonsOpacity(tester), 0, reason: 'hides again after release');
    });

    testWidgets('an open menu keeps the controls up', (tester) async {
      await tester.pumpWidget(frame(left: [
        UoscTracksButton(type: JellyfinStreamType.audio, tracks: tracks, onPick: (_) {}),
      ]));
      await tester.tap(find.byKey(const ValueKey('uosc-audio')));
      await tester.pump();
      expect(find.byType(UoscMenuPanel<TrackPick>), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(buttonsOpacity(tester), 1);
      await tester.tapAt(const Offset(5, 5)); // outside: dismiss
      await tester.pump();
      expect(find.byType(UoscMenuPanel<TrackPick>), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(buttonsOpacity(tester), 0);
    });
  });

  group('buttons', () {
    testWidgets('track buttons carry the count; dark tooltip on hover', (tester) async {
      await tester.pumpWidget(host(Row(children: [
        UoscTracksButton(type: JellyfinStreamType.subtitle, tracks: tracks, onPick: (_) {}),
        UoscTracksButton(type: JellyfinStreamType.audio, tracks: tracks.take(1).toList(), onPick: (_) {}),
        const UoscButton(key: ValueKey('plain'), icon: Icons.menu, tooltip: 'Menu', onPressed: null),
      ])));
      String badge(String key) => tester
          .widget<Text>(find.descendant(
              of: find.descendant(of: find.byKey(ValueKey(key)), matching: find.byKey(const ValueKey('uosc-badge'))),
              matching: find.byType(Text)))
          .data!;
      expect(badge('uosc-subtitles'), '2');
      expect(badge('uosc-audio'), '1');
      expect(find.descendant(of: find.byKey(const ValueKey('plain')), matching: find.byKey(const ValueKey('uosc-badge'))),
          findsNothing);
      final mouse = await mouseAt(tester, Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('uosc-subtitles'))));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Subtitles'), findsOneWidget);
      final tip = tester.widget<Tooltip>(find.descendant(of: find.byKey(const ValueKey('uosc-subtitles')), matching: find.byType(Tooltip)).first);
      expect((tip.decoration as BoxDecoration).color, UoscStyle.panel);
    });

    testWidgets('shader badge shows the preset, dimmed "4K" when off', (tester) async {
      final s = AppSettings.instance;
      s.shaderPreset.value = ShaderPreset.off;
      await tester.pumpWidget(host(Row(children: [
        UoscShaderButton(renderMode: signal(RenderMode.gpu), onPick: (_, _) {}),
      ])));
      expect(find.text('4K'), findsOneWidget);
      expect(tester.widget<UoscBadgeButton>(find.byType(UoscBadgeButton)).active, isFalse);
      s.shaderPreset.value = ShaderPreset.ca;
      s.shaderQuality.value = ShaderQuality.fast;
      await tester.pump();
      expect(find.text('C+A Fast'), findsOneWidget);
      expect(tester.widget<UoscBadgeButton>(find.byType(UoscBadgeButton)).active, isTrue);
      s.shaderPreset.value = ShaderPreset.off;
      s.shaderQuality.value = ShaderQuality.hq;
    });

    testWidgets('volume: click mutes and restores, wheel steps 5', (tester) async {
      final got = <double>[];
      var volume = 80.0;
      await tester.pumpWidget(host(StatefulBuilder(
        builder: (context, setState) => Row(children: [
          UoscVolumeButton(volume: volume, onChanged: (v) => setState(() => got.add(volume = v))),
        ]),
      )));
      await tester.tap(find.byKey(const ValueKey('uosc-volume')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('uosc-volume')));
      await tester.pump();
      await tester.sendEventToBinding(PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(find.byKey(const ValueKey('uosc-volume'))),
          scrollDelta: const Offset(0, -60)));
      await tester.pump();
      expect(got, [0, 80, 85], reason: 'a notch is one step');
      for (var i = 0; i < 3; i++) {
        await tester.sendEventToBinding(PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: tester.getCenter(find.byKey(const ValueKey('uosc-volume'))),
            scrollDelta: const Offset(0, 20)));
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
      await tester.pumpWidget(MaterialApp(
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
      ));
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

  group('menus', () {
    Color rowColor(WidgetTester tester, String title) => (tester
            .widget<Container>(find.descendant(
                of: find.byKey(ValueKey('uosc-menu-item-$title')), matching: find.byType(Container)).first)
            .decoration! as BoxDecoration)
        .color!;

    testWidgets('audio: flat dark list, current highlighted, pick selects', (tester) async {
      TrackPick? got;
      await tester.pumpWidget(host(Row(children: [
        UoscTracksButton(type: JellyfinStreamType.audio, tracks: tracks, onPick: (p) => got = p),
      ])));
      await tester.tap(find.byKey(const ValueKey('uosc-audio')));
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('uosc-menu'));
      expect(tester.widget<Material>(menu).color, UoscStyle.panel);
      expect(tester.getRect(menu).bottom, lessThan(tester.getRect(find.byKey(const ValueKey('uosc-audio'))).top),
          reason: 'opens above the button');
      expect(find.text('Audio'), findsOneWidget, reason: 'title row');
      expect(rowColor(tester, 'Japanese · E-AC3 2.0'), UoscStyle.fill);
      expect(rowColor(tester, 'English · AAC 5.1 · Dub'), isNot(UoscStyle.fill));
      await tester.tap(find.byKey(const ValueKey('uosc-menu-item-English · AAC 5.1 · Dub')));
      await tester.pumpAndSettle();
      expect(got, (aid: 2, sid: null, subtitlesOff: false));
      expect(menu, findsNothing);
    });

    testWidgets('subtitles start with Off, active when none is selected', (tester) async {
      TrackPick? got;
      await tester.pumpWidget(host(Row(children: [
        UoscTracksButton(type: JellyfinStreamType.subtitle, tracks: tracks, onPick: (p) => got = p),
      ])));
      await tester.tap(find.byKey(const ValueKey('uosc-subtitles')));
      await tester.pumpAndSettle();
      expect(rowColor(tester, 'Off'), UoscStyle.fill);
      await tester.tap(find.byKey(const ValueKey('uosc-menu-item-Off')));
      await tester.pumpAndSettle();
      expect(got, (aid: null, sid: null, subtitlesOff: true));
    });

    testWidgets('chapters: titles with start times, the playing one highlighted', (tester) async {
      MediaChapter? got;
      await tester.pumpWidget(host(Row(children: [
        UoscChaptersButton(chapters: chapters, current: 2, duration: m(24), onPick: (c) => got = c),
      ])));
      await tester.tap(find.byKey(const ValueKey('uosc-chapters')));
      await tester.pumpAndSettle();
      for (final c in chapters) {
        expect(find.descendant(of: find.byKey(ValueKey('uosc-menu-item-${c.title}')), matching: find.text(formatUoscTime(c.start))),
            findsOneWidget);
      }
      expect(rowColor(tester, 'Part A'), UoscStyle.fill);
      expect(rowColor(tester, 'Opening'), isNot(UoscStyle.fill));
      await tester.tap(find.byKey(const ValueKey('uosc-menu-item-Ending')));
      await tester.pumpAndSettle();
      expect(got, chapters[3]);
    });

    testWidgets('no chapters: no button', (tester) async {
      await tester.pumpWidget(host(Row(children: [
        UoscChaptersButton(chapters: const [], current: null, duration: m(24), onPick: (_) {}),
      ])));
      expect(find.byKey(const ValueKey('uosc-chapters')), findsNothing);
    });

    testWidgets('main menu runs the picked action', (tester) async {
      final ran = <String>[];
      await tester.pumpWidget(host(Row(children: [
        UoscMainMenuButton(actions: [
          (title: 'Change video', hint: null, run: () => ran.add('swap')),
          (title: 'Reload video', hint: 'Ctrl+R', run: () => ran.add('reload')),
        ]),
      ])));
      await tester.tap(find.byKey(const ValueKey('uosc-menu-button')));
      await tester.pumpAndSettle();
      expect(find.text('Ctrl+R'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('uosc-menu-item-Reload video')));
      await tester.pumpAndSettle();
      expect(ran, ['reload']);
    });
  });

  testWidgets('the setting picks the controls builder, live', (tester) async {
    final s = AppSettings.instance;
    s.mpvControls.value = false;
    await tester.pumpWidget(MaterialApp(
      home: SessionControlsSwitch(
        material: (_) => const Text('material'),
        mpv: (_) => const Text('mpv'),
      ),
    ));
    expect(find.text('material'), findsOneWidget);
    s.mpvControls.value = true;
    await tester.pump();
    expect(find.text('mpv'), findsOneWidget);
    expect(find.text('material'), findsNothing);
    s.mpvControls.value = false;
    await tester.pump();
    expect(find.text('material'), findsOneWidget);
  });

  testWidgets('Settings: "Player design", Standard by default', (tester) async {
    final s = AppSettings.instance;
    s.mpvControls.value = false;
    addTearDown(() => s.mpvControls.value = false);
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SettingsTab(
          section: SettingsSection.player,
          onSection: (_) {},
          updates: UpdateController(currentVersion: '0.0.0-dev'),
        ),
      ),
    ));
    final design = find.byKey(const ValueKey('player-design'));
    expect(find.text('Player design'), findsOneWidget);
    expect(tester.widget<AppSelect<bool>>(design).value, isFalse);
    await tester.tap(design);
    await tester.pumpAndSettle();
    await tester.tap(find.text('uosc').last);
    await tester.pumpAndSettle();
    expect(s.mpvControls.value, isTrue);
    expect(tester.widget<AppSelect<bool>>(design).value, isTrue);
  });
}
