import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;
import 'package:starsync/src/controls/control_menus.dart';
import 'package:starsync/src/controls/live_badge.dart';
import 'package:starsync/src/controls/standard/seek_bar.dart';
import 'package:starsync/src/jellyfin/track_prefs.dart';
import 'package:starsync/src/playback/media_marks.dart';
import 'package:starsync/src/screens/session/player_controls.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();

// The control-bar pieces alone (never the session screen or a `Video`):
// the Standard seek bar, the skip pill and the shared track / chapter
// lists.

Duration m(int min, [int sec = 0]) => Duration(minutes: min, seconds: sec);

final chapters = chaptersFromStarts([
  ('Prologue', Duration.zero),
  ('OP', m(0, 30)),
  ('Part A', m(2)),
  ('ED', m(20)),
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

void main() {
  group('seek bar', () {
    testWidgets('a mark at each chapter start but the first, placed by time', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(ChapterSeekBar(
          position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {}))));
      expect(find.byKey(const ValueKey('chapter-mark-0')), findsNothing, reason: 'starts at 0');
      final bar = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      for (final c in chapters.skip(1)) {
        final mark = tester.getCenter(find.byKey(ValueKey('chapter-mark-${c.index}')));
        final x = bar.left + bar.width * c.start.inSeconds / m(24).inSeconds;
        expect(mark.dx, moreOrLessEquals(x, epsilon: 0.5), reason: c.title);
        expect(mark.dy, moreOrLessEquals(bar.center.dy, epsilon: 0.5));
      }
    });

    testWidgets('no marks without a duration or chapters', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(ChapterSeekBar(
          position: Duration.zero, duration: Duration.zero, chapters: chapters, onSeek: (_) {}))));
      expect(find.byKey(const ValueKey('chapter-mark-1')), findsNothing);
      await tester.pumpWidget(scoped(_graph, host(ChapterSeekBar(position: Duration.zero, duration: m(24), onSeek: (_) {}))));
      expect(find.byKey(const ValueKey('chapter-mark-1')), findsNothing);
    });

    testWidgets('hover shows the chapter title above the time', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(ChapterSeekBar(
          position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {}))));
      final bar = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      // 20:45 of 24:00: inside "ED".
      await mouse.moveTo(Offset(bar.left + bar.width * (20.75 / 24), bar.center.dy));
      await tester.pump();
      final title = find.byKey(const ValueKey('seek-hover-chapter'));
      final time = find.byKey(const ValueKey('seek-hover-time'));
      expect(tester.widget<Text>(title).data, 'ED');
      expect(tester.widget<Text>(time).data, '20:45');
      expect(tester.getCenter(title).dy, lessThan(tester.getCenter(time).dy));
      expect(tester.getRect(time).bottom, lessThanOrEqualTo(bar.top + 2), reason: 'above the bar');
      // 10:00: Part A.
      await mouse.moveTo(Offset(bar.left + bar.width * (10 / 24), bar.center.dy));
      await tester.pump();
      expect(tester.widget<Text>(title).data, 'Part A');
      await mouse.moveTo(Offset(bar.left, bar.top - 200));
      await tester.pump();
      expect(time, findsNothing);
    });

    testWidgets('no chapters: the hover shows only the time', (tester) async {
      await tester.pumpWidget(scoped(_graph, host(ChapterSeekBar(position: m(1), duration: m(24), onSeek: (_) {}))));
      final bar = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(Offset(bar.left + bar.width / 2, bar.center.dy));
      await tester.pump();
      expect(find.byKey(const ValueKey('seek-hover-chapter')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('seek-hover-time'))).data, '12:00');
    });

    testWidgets('drag seeks on every move and on release', (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(scoped(_graph, host(ChapterSeekBar(
          position: m(1), duration: m(24), chapters: chapters, onSeek: seeks.add))));
      final bar = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final g = await tester.startGesture(Offset(bar.left + bar.width / 4, bar.center.dy),
          kind: PointerDeviceKind.mouse);
      expect(seeks, isEmpty, reason: 'press alone does not seek');
      await g.moveTo(Offset(bar.left + bar.width / 2, bar.center.dy));
      await g.moveTo(Offset(bar.left + bar.width * 3 / 4, bar.center.dy));
      await g.up();
      expect(seeks.length, 3);
      expect(seeks[0], m(12));
      expect(seeks.last, m(18));
    });
  });

  group('skip pill', () {
    testWidgets('labels per kind; faint, lit on hover; click skips', (tester) async {
      var pressed = 0;
      for (final (kind, label) in [
        (SkipKind.opening, 'Skip OP'),
        (SkipKind.ending, 'Skip ED'),
        (SkipKind.fixed, 'Skip 1:30'),
      ]) {
        await tester.pumpWidget(scoped(_graph, host(Align(child: SkipPill(offer: SkipOffer(kind, m(2)), onPressed: () => pressed++)))));
        expect(find.text(label), findsOneWidget);
      }
      double opacity() => tester.widget<AnimatedOpacity>(
          find.descendant(of: find.byType(SkipPill), matching: find.byType(AnimatedOpacity))).opacity;
      expect(opacity(), lessThan(0.5));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('skip-pill'))));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      await tester.tap(find.byKey(const ValueKey('skip-pill')));
      expect(pressed, 1);
    });
  });

  group('menus', () {
    const tracks = [
      MpvTrack(id: 1, type: JellyfinStreamType.audio, language: 'jpn', codec: 'eac3', channels: 2, selected: true),
      MpvTrack(id: 2, type: JellyfinStreamType.audio, language: 'eng', codec: 'aac', channels: 6, title: 'Dub'),
      MpvTrack(id: 1, type: JellyfinStreamType.subtitle, language: 'eng', codec: 'ass', title: 'Full'),
    ];

    test('audio list: counts, labels, mpv\'s selection checked', () {
      expect(trackCount(tracks, JellyfinStreamType.audio), 2);
      expect(trackCount(tracks, JellyfinStreamType.subtitle), 1);
      final items = trackMenuItems(JellyfinStreamType.audio, tracks);
      expect(items.map((i) => i.label), ['Japanese · E-AC3 2.0', 'English · AAC 5.1 · Dub']);
      expect(items.map((i) => i.checked), [true, false]);
      expect(items[1].value, (aid: 2, sid: null, subtitlesOff: false));
      expect(trackMenuItems(JellyfinStreamType.audio, const []).single.enabled, isFalse, reason: 'None');
    });

    test('subtitle list starts with Off, checked when none is selected', () {
      final items = trackMenuItems(JellyfinStreamType.subtitle, tracks);
      expect(items.map((i) => i.label), ['Off', 'English · ASS · Full']);
      expect(items.map((i) => i.checked), [true, false]);
      expect(items.first.value, (aid: null, sid: null, subtitlesOff: true));
      expect(items.last.value, (aid: null, sid: 1, subtitlesOff: false));
    });

    test('chapter list: start times, the current one checked', () {
      final items = chapterMenuItems(chapters, 2);
      expect(items.map((i) => i.checked), [false, false, true, false, false]);
      expect(items[3].label, 'ED');
      expect(items[3].hint, '20:00');
      expect(items[3].value.start, m(20));
    });
  });

  testWidgets('the live badge: LIVE at live; behind it how far, and Go live', (tester) async {
    var goLive = 0;
    Widget badge(double behind) => MaterialApp(
        home: Scaffold(
            body: LiveBadge(
                paused: false, behind: behind, scale: 1, onBackToLive: () {}, onGoLive: () => goLive++)));
    await tester.pumpWidget(badge(0.4));
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('Go live'), findsNothing);
    await tester.pumpWidget(badge(150));
    expect(find.text('LIVE'), findsNothing);
    expect(find.text('−2:30'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('go-live')));
    expect(goLive, 1);
  });
}
