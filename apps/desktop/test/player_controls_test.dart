import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;
import 'package:watch_together/src/jellyfin/track_prefs.dart';
import 'package:watch_together/src/playback/media_marks.dart';
import 'package:watch_together/src/screens/session/player_controls.dart';

// The control-bar pieces alone (never the session screen or a `Video`).

Duration m(int min, [int sec = 0]) => Duration(minutes: min, seconds: sec);

final chapters = chaptersFromStarts([
  ('Prologue', Duration.zero),
  ('OP', m(0, 30)),
  ('Part A', m(2)),
  ('ED', m(20)),
  ('Part B', m(21, 30)),
], m(24));

Finder item<T>(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(CheckedPopupMenuItem<T>));

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
      await tester.pumpWidget(host(ChapterSeekBar(
          position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {})));
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
      await tester.pumpWidget(host(ChapterSeekBar(
          position: Duration.zero, duration: Duration.zero, chapters: chapters, onSeek: (_) {})));
      expect(find.byKey(const ValueKey('chapter-mark-1')), findsNothing);
      await tester.pumpWidget(host(ChapterSeekBar(position: Duration.zero, duration: m(24), onSeek: (_) {})));
      expect(find.byKey(const ValueKey('chapter-mark-1')), findsNothing);
    });

    testWidgets('hover shows the chapter title above the time', (tester) async {
      await tester.pumpWidget(host(ChapterSeekBar(
          position: m(1), duration: m(24), chapters: chapters, onSeek: (_) {})));
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
      await tester.pumpWidget(host(ChapterSeekBar(position: m(1), duration: m(24), onSeek: (_) {})));
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
      await tester.pumpWidget(host(ChapterSeekBar(
          position: m(1), duration: m(24), chapters: chapters, onSeek: seeks.add)));
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
        await tester.pumpWidget(host(Align(child: SkipPill(offer: SkipOffer(kind, m(2)), onPressed: () => pressed++))));
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

    testWidgets('audio menu: count badge, labels, current checked, pick', (tester) async {
      TrackPick? got;
      await tester.pumpWidget(host(Row(children: [
        TrackMenuButton(type: JellyfinStreamType.audio, tracks: tracks, onPick: (p) => got = p),
        TrackMenuButton(type: JellyfinStreamType.subtitle, tracks: tracks, onPick: (p) => got = p),
      ])));
      expect(find.descendant(of: find.byKey(const ValueKey('audio-button')), matching: find.text('2')),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('subtitles-button')), matching: find.text('1')),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('audio-button')));
      await tester.pumpAndSettle();
      final items = tester.widgetList<CheckedPopupMenuItem<TrackPick>>(find.byType(CheckedPopupMenuItem<TrackPick>));
      expect(items.map((i) => i.checked), [true, false]);
      expect(find.text('Japanese · E-AC3 2.0'), findsOneWidget);
      await tester.tap(item<TrackPick>('English · AAC 5.1 · Dub'));
      await tester.pumpAndSettle();
      expect(got, (aid: 2, sid: null, subtitlesOff: false));
    });

    testWidgets('subtitle menu has Off, checked when none is selected', (tester) async {
      TrackPick? got;
      await tester.pumpWidget(host(TrackMenuButton(
          type: JellyfinStreamType.subtitle, tracks: tracks, onPick: (p) => got = p)));
      await tester.tap(find.byKey(const ValueKey('subtitles-button')));
      await tester.pumpAndSettle();
      final items = tester.widgetList<CheckedPopupMenuItem<TrackPick>>(find.byType(CheckedPopupMenuItem<TrackPick>));
      expect(items.map((i) => i.checked), [true, false]);
      await tester.tap(item<TrackPick>('Off'));
      await tester.pumpAndSettle();
      expect(got, (aid: null, sid: null, subtitlesOff: true));
    });

    testWidgets('chapter menu: current checked, a pick seeks to its start', (tester) async {
      MediaChapter? got;
      await tester.pumpWidget(host(ChaptersControlButton(chapters: chapters, current: 2, onPick: (c) => got = c)));
      await tester.tap(find.byKey(const ValueKey('chapters-button')));
      await tester.pumpAndSettle();
      final items = tester.widgetList<CheckedPopupMenuItem<MediaChapter>>(
          find.byType(CheckedPopupMenuItem<MediaChapter>));
      expect(items.map((i) => i.checked), [false, false, true, false, false]);
      expect(find.text('20:00'), findsOneWidget);
      await tester.tap(item<MediaChapter>('ED'));
      await tester.pumpAndSettle();
      expect(got!.start, m(20));
    });

    testWidgets('no chapters, no chapter button', (tester) async {
      await tester.pumpWidget(host(ChaptersControlButton(chapters: const [], current: null, onPick: (_) {})));
      expect(find.byKey(const ValueKey('chapters-button')), findsNothing);
    });
  });
}
