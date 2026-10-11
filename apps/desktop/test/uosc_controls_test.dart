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

  group('cache hatching math', () {
    test('cached range runs from the position to the cache end', () {
      const size = Size(1000, 30);
      final r = cacheRect(size, position: m(6), buffered: m(9), duration: m(24))!;
      expect(r.left, 250);
      expect(r.right, 375);
      expect(r.top, 0);
      expect(r.bottom, 30);
      expect(cacheRect(size, position: m(6), buffered: m(6), duration: m(24)), isNull);
      expect(cacheRect(size, position: m(6), buffered: m(5), duration: m(24)), isNull, reason: 'behind');
      expect(cacheRect(size, position: m(6), buffered: m(9), duration: Duration.zero), isNull);
      // Clamped to the bar.
      expect(cacheRect(size, position: m(20), buffered: m(40), duration: m(24))!.right, 1000);
    });

    test('45° strokes, evenly spaced, covering the whole range', () {
      const r = Rect.fromLTRB(100, 0, 160, 30);
      final lines = hatchLines(r, spacing: 6);
      for (final (a, b) in lines) {
        expect(a.dy, r.bottom);
        expect(b.dy, r.top);
        expect(b.dx - a.dx, r.height, reason: '45°');
        // Every stroke crosses the range.
        expect(b.dx, greaterThan(r.left));
        expect(a.dx, lessThan(r.right));
      }
      for (var i = 1; i < lines.length; i++) {
        expect(lines[i].$1.dx - lines[i - 1].$1.dx, 6);
      }
      // No gap at either edge: the first stroke starts left of the range's
      // bottom-left corner diagonal, the last one within a step of the end.
      expect(lines.first.$1.dx, lessThanOrEqualTo(r.left - r.height + 6));
      expect(lines.last.$1.dx, greaterThan(r.right - 6));
      expect(hatchLines(Rect.zero), isEmpty);
    });
  });

  group('timeline', () {
    testWidgets('elapsed part filled, time boxes inside the bar', (tester) async {
      await tester.pumpWidget(host(UoscTimeline(
          position: m(6), duration: m(24), buffered: m(8), chapters: chapters, onSeek: (_) {})));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      expect(bar.width, 800, reason: 'the whole width (the test window)');
      expect(bar.height, UoscTimeline.height);
      final p = painter(tester);
      expect(p.played, 0.25);
      expect(p.hatched, isTrue);
      expect(p.cache(bar.size), cacheRect(bar.size, position: m(6), buffered: m(8), duration: m(24)));
      expect(boxText(tester, 'uosc-time'), '06:00');
      expect(boxText(tester, 'uosc-duration'), '24:00');
      final time = tester.getRect(find.byKey(const ValueKey('uosc-time')));
      expect(time.left, greaterThanOrEqualTo(bar.left));
      expect(time.top, greaterThanOrEqualTo(bar.top));
      expect(time.bottom, lessThanOrEqualTo(bar.bottom));
      expect(time.center.dx, lessThan(bar.left + 80), reason: 'at the left');
    });

    testWidgets('a diamond on the top edge at each chapter start but the first', (tester) async {
      await tester.pumpWidget(host(UoscTimeline(
          position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {})));
      expect(find.byKey(const ValueKey('uosc-chapter-0')), findsNothing, reason: 'starts at 0');
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      for (final c in chapters.skip(1)) {
        final mark = tester.getCenter(find.byKey(ValueKey('uosc-chapter-${c.index}')));
        expect(mark.dx, moreOrLessEquals(bar.left + bar.width * c.start.inSeconds / m(24).inSeconds, epsilon: 0.5),
            reason: c.title);
        expect(mark.dy, moreOrLessEquals(bar.top, epsilon: 0.5), reason: 'on the top edge');
      }
    });

    testWidgets('hover: chapter title over the hover time, above the bar', (tester) async {
      await tester.pumpWidget(host(UoscTimeline(
          position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {})));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      final mouse = await mouseAt(tester, Offset.zero);
      // 01:51 of 24:00: inside "Opening".
      await mouse.moveTo(Offset(bar.left + bar.width * (111 / (24 * 60)), bar.center.dy));
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

    testWidgets('hidden controls: a thin line with chapter ticks, no boxes, no input', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(host(UoscTimeline(
          position: m(12), duration: m(24), buffered: m(14), chapters: chapters, expanded: false, onSeek: seeks.add)));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      expect(bar.height, UoscTimeline.collapsedHeight);
      expect(painter(tester).played, 0.5);
      expect(painter(tester).hatched, isFalse);
      expect(find.byKey(const ValueKey('uosc-chapter-1')), findsNothing);
      for (final c in chapters.skip(1)) {
        final tick = tester.getRect(find.byKey(ValueKey('uosc-chapter-tick-${c.index}')));
        expect(tick.center.dx, moreOrLessEquals(bar.left + bar.width * c.start.inSeconds / m(24).inSeconds, epsilon: 0.5));
        expect(tick.width, lessThanOrEqualTo(2));
      }
      expect(find.byKey(const ValueKey('uosc-time')), findsNothing);
      final mouse = await mouseAt(tester, Offset.zero);
      await mouse.moveTo(bar.center);
      await tester.pump();
      expect(find.byKey(const ValueKey('uosc-hover-time')), findsNothing);
      await tester.tapAt(bar.center);
      expect(seeks, isEmpty);
    });

    testWidgets('drag seeks on every move and on release', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(host(UoscTimeline(
          position: m(1), duration: m(24), chapters: chapters, onSeek: seeks.add)));
      final bar = tester.getRect(find.byKey(const ValueKey('uosc-timeline')));
      final g = await tester.startGesture(Offset(bar.left + bar.width / 4, bar.center.dy), kind: PointerDeviceKind.mouse);
      expect(seeks, isEmpty, reason: 'press alone does not seek');
      await g.moveTo(Offset(bar.left + bar.width / 2, bar.center.dy));
      await tester.pump();
      expect(boxText(tester, 'uosc-time'), '12:00', reason: 'follows the drag');
      await g.moveTo(Offset(bar.left + bar.width * 3 / 4, bar.center.dy));
      await g.up();
      expect(seeks, [m(12), m(18), m(18)]);
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
      expect(tester.getRect(find.byKey(const ValueKey('uosc-timeline'))).height, UoscTimeline.height);
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
          scrollDelta: const Offset(0, -20)));
      await tester.pump();
      expect(got, [0, 80, 85]);
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
