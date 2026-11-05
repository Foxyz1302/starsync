import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/platform/desktop/mpv_frame_grab.dart' show bgr0ToRgba;
import 'package:starsync/src/platform/ports/player_host.dart' show RawFrame;
import 'package:starsync/src/screenshot/screenshots.dart';
import 'package:starsync/src/screenshot/shot_crop.dart';
import 'package:starsync/src/screenshot/shot_files.dart';
import 'package:starsync/src/screenshot/shot_overlay.dart';
import 'package:starsync/src/session/navigation.dart' show Place;
import 'package:starsync/src/shell/app_shell.dart';
import 'package:starsync/src/update/update_controller.dart';
import 'package:starsync/src/widgets/app_keys.dart';
import 'package:starsync/src/widgets/text_focus.dart';

import 'test_graph.dart';

final _graph = testGraph(shell: FakeShell());

Future<ui.Image> _image(WidgetTester tester, int w, int h) async =>
    (await tester.runAsync(() => createTestImage(width: w, height: h, cache: false)))!;

void main() {
  group('file names', () {
    test('show, episode and time', () {
      expect(screenshotName(title: 'Frieren', episode: 'S1 E5 · The Hero', at: const Duration(minutes: 12, seconds: 34)),
          'Frieren S01E05 12m34s');
      expect(screenshotName(title: 'One Piece', episode: 'E1071', at: const Duration(hours: 1, minutes: 2, seconds: 3)),
          'One Piece E1071 1h02m03s');
      expect(screenshotName(title: 'Bocchi', episode: 'NCOP1', at: const Duration(seconds: 5)), 'Bocchi NCOP1 0m05s');
    });

    test('falls back to the title alone, then to the app', () {
      expect(screenshotName(title: 'Big Buck Bunny', at: const Duration(seconds: 61)), 'Big Buck Bunny 1m01s');
      expect(screenshotName(title: '  ', at: Duration.zero), 'Starsync 0m00s');
      expect(screenshotName(title: null, at: Duration.zero), 'Starsync 0m00s');
    });

    test('episode tags', () {
      expect(episodeTag('S2 E4'), 'S02E04');
      expect(episodeTag('S12 E104 · Name'), 'S12E104');
      expect(episodeTag('E7'), 'E07');
      expect(episodeTag('E12.5'), 'E12.5');
      expect(episodeTag('OVA 2'), 'OVA 2');
      expect(episodeTag(null), '');
      expect(episodeTag(''), '');
    });

    test('safe on Linux and Windows', () {
      expect(safeFileName('Re:Zero / Part 2? <Director\'s> "Cut" *|\\'), "Re Zero Part 2 Director's Cut");
      expect(safeFileName('tab\there\nnew'), 'tab here new');
      expect(safeFileName('  ..name..  '), 'name');
      expect(safeFileName('CON'), '_CON');
      expect(safeFileName('nul.png'), '_nul.png');
      expect(safeFileName('Console'), 'Console');
      expect(safeFileName('???'), 'Screenshot');
      expect(safeFileName('a' * 300).length, 150);
      expect(safeFileName('${'a' * 149} b'), 'a' * 149);
    });

    test('duplicates get a number', () {
      final taken = {'/p/Show 1m00s.png', '/p/Show 1m00s (2).png'};
      expect(uniquePath('/p', 'Show 1m00s', 'png', taken.contains), '/p/Show 1m00s (3).png');
      expect(uniquePath('/p/', 'Other', 'png', taken.contains), '/p/Other.png');
    }, skip: Platform.isWindows ? 'paths with /' : false);
  });

  group('Pictures folder (XDG)', () {
    const home = '/home/ann';
    test(r'$HOME expanded, quotes dropped', () {
      const dirs = '# comment\nXDG_DESKTOP_DIR="\$HOME/Desktop"\nXDG_PICTURES_DIR="\$HOME/Bilder"\n';
      expect(xdgPicturesDir(dirs, home), '/home/ann/Bilder');
      expect(xdgPicturesDir('XDG_PICTURES_DIR="/data/pics/"', home), '/data/pics');
      expect(xdgPicturesDir(r'XDG_PICTURES_DIR=${HOME}/Pics', home), '/home/ann/Pics');
    });
    test('missing, or the home folder itself (disabled): none', () {
      expect(xdgPicturesDir('XDG_MUSIC_DIR="\$HOME/Music"', home), isNull);
      expect(xdgPicturesDir('XDG_PICTURES_DIR="\$HOME/"', home), isNull);
      expect(xdgPicturesDir('XDG_PICTURES_DIR="relative"', home), isNull);
    });
  });

  group('crop with letterboxing', () {
    test('the picture sits centred: bars top and bottom, or left and right', () {
      // 16:9 in a 4:3 view: bars top and bottom.
      expect(pictureRect(const Size(800, 600), const Size(1920, 1080)), const Rect.fromLTWH(0, 75, 800, 450));
      // 4:3 in a 16:9 view: bars left and right.
      expect(pictureRect(const Size(1600, 900), const Size(640, 480)), const Rect.fromLTWH(200, 0, 1200, 900));
      // Same aspect: the whole view.
      expect(pictureRect(const Size(960, 540), const Size(1920, 1080)), const Rect.fromLTWH(0, 0, 960, 540));
    });

    test('a selection maps to the frame\'s own pixels', () {
      final picture = pictureRect(const Size(800, 600), const Size(1920, 1080)); // scale 2.4
      // The picture's top-left quarter.
      expect(cropFor(const Rect.fromLTRB(0, 75, 400, 300), picture, 1920, 1080), (x: 0, y: 0, width: 960, height: 540));
      // Fractions round outward: what was inside stays.
      expect(cropFor(const Rect.fromLTRB(10.2, 85.2, 110.1, 185.1), picture, 1920, 1080),
          (x: 24, y: 24, width: 241, height: 241));
    });

    test('the bars are cut off; a click or a tiny drag is the whole frame', () {
      final picture = pictureRect(const Size(1600, 900), const Size(640, 480)); // pillarbox, scale 1.875
      // Reaching into the left bar: starts at the picture's edge.
      expect(cropFor(const Rect.fromLTRB(0, 0, 575, 450), picture, 640, 480), (x: 0, y: 0, width: 200, height: 240));
      expect(cropFor(const Rect.fromLTRB(500, 300, 502, 400), picture, 640, 480), isNull);
      expect(cropFor(Rect.fromPoints(const Offset(700, 300), const Offset(700, 300)), picture, 640, 480), isNull);
      // All of the picture (or more): the whole frame.
      expect(cropFor(const Rect.fromLTRB(0, 0, 1600, 900), picture, 640, 480), isNull);
      // Only the bars: nothing of the picture, the whole frame.
      expect(cropFor(const Rect.fromLTRB(0, 0, 150, 900), picture, 640, 480), isNull);
    });

    test('a drag stays on the picture', () {
      const picture = Rect.fromLTWH(200, 0, 1200, 900);
      expect(clampToPicture(const Offset(50, 950), picture), const Offset(200, 900));
      expect(clampToPicture(const Offset(700, 300), picture), const Offset(700, 300));
    });
  });

  group('keys over the selection', () {
    KeyDownEvent down(LogicalKeyboardKey k) =>
        KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);
    test('Esc cancels, Enter picks, T switches the subtitles', () {
      expect(shotKeyFor(down(LogicalKeyboardKey.escape)), ShotKey.cancel);
      expect(shotKeyFor(down(LogicalKeyboardKey.enter)), ShotKey.pick);
      expect(shotKeyFor(down(LogicalKeyboardKey.numpadEnter)), ShotKey.pick);
      expect(shotKeyFor(down(LogicalKeyboardKey.keyT)), ShotKey.subtitles);
      expect(shotKeyFor(down(LogicalKeyboardKey.keyS)), isNull);
    });
    test('not with modifiers, nor on repeats or releases', () {
      expect(shotKeyFor(down(LogicalKeyboardKey.keyT), control: true), isNull);
      expect(shotKeyFor(down(LogicalKeyboardKey.keyT), alt: true), isNull);
      expect(
          shotKeyFor(const KeyRepeatEvent(
              physicalKey: PhysicalKeyboardKey.keyT, logicalKey: LogicalKeyboardKey.keyT, timeStamp: Duration.zero)),
          isNull);
      expect(
          shotKeyFor(const KeyUpEvent(
              physicalKey: PhysicalKeyboardKey.keyT, logicalKey: LogicalKeyboardKey.keyT, timeStamp: Duration.zero)),
          isNull);
    });
  });

  group('pixels', () {
    test("mpv's bgr0 rows (padded) become tight opaque RGBA", () {
      // 2x2, stride 12 (4 bytes of padding per row).
      final src = Uint8List.fromList([
        1, 2, 3, 0, 4, 5, 6, 0, 9, 9, 9, 9, //
        7, 8, 9, 0, 10, 11, 12, 0, 9, 9, 9, 9,
      ]);
      expect(bgr0ToRgba(src, 2, 2, 12), [3, 2, 1, 255, 6, 5, 4, 255, 9, 8, 7, 255, 12, 11, 10, 255]);
    });

    test('the PNG is the crop at full resolution, the toast gets a small copy', () {
      const w = 400, h = 200;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          rgba[i] = x % 256;
          rgba[i + 1] = y;
          rgba[i + 2] = 7;
          rgba[i + 3] = 255;
        }
      }
      final out = encodeShotSync(RawFrame(rgba, w, h), (x: 10, y: 20, width: 300, height: 150));
      final png = img.decodePng(out.png)!;
      expect((png.width, png.height), (300, 150));
      final p = png.getPixel(0, 0);
      expect((p.r, p.g, p.b), (10, 20, 7));
      final q = png.getPixel(299, 149);
      expect((q.r, q.g, q.b), (309 % 256, 169, 7));
      expect(img.decodePng(out.thumb)!.width, shotThumbWidth);
      final whole = img.decodePng(encodeShotSync(RawFrame(rgba, w, h), null).png)!;
      expect((whole.width, whole.height), (w, h));
    });
  });

  group('the live picture', () {
    const view = Size(1280, 720), pip = Size(320, 180);
    test('stays in its corner while clear, moves away from the selection and the pointer', () {
      expect(pipCorner(view, pip, Alignment.bottomRight), Alignment.bottomRight);
      // A selection reaching into the bottom right: the bottom left.
      expect(
          pipCorner(view, pip, Alignment.bottomRight, selection: const Rect.fromLTRB(700, 400, 1200, 700)),
          Alignment.bottomLeft);
      // The pointer on it, at the bottom right: the corner farthest away.
      expect(pipCorner(view, pip, Alignment.bottomRight, pointer: const Offset(1100, 600)), Alignment.topLeft);
      // Nowhere clear: it stays.
      expect(pipCorner(view, pip, Alignment.topLeft, selection: Offset.zero & view), Alignment.topLeft);
    });
  });

  group('the selection', () {
    Future<List<Object?>> pumpOverlay(WidgetTester tester, {bool subs = true}) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final clean = await _image(tester, 1920, 1080);
      final withSubs = subs ? await _image(tester, 1920, 1080) : null;
      final picks = <Object?>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShotOverlay(
            key: UniqueKey(),
            images: (clean: clean, subs: withSubs),
            subtitles: true,
            onPick: (s, crop) => picks.add((s, crop)),
            onCancel: () => picks.add('cancel'),
          ),
        ),
      ));
      await tester.pump();
      return picks;
    }

    testWidgets("a drag picks the crop at the frame's resolution, bars cut off", (tester) async {
      final picks = await pumpOverlay(tester);
      // 16:9 in 800x600: the picture is 800x450 at y 75 (scale 2.4).
      final g = await tester.startGesture(const Offset(0, 20)); // in the bar: from the picture's edge
      await g.moveTo(const Offset(200, 150));
      await tester.pump();
      expect(find.text('480 × 180'), findsOneWidget, reason: "the size in the frame's pixels");
      await g.moveTo(const Offset(400, 300));
      await g.up();
      await tester.pump();
      expect(picks, [(true, (x: 0, y: 0, width: 960, height: 540))]);
    });

    testWidgets('a click is the whole frame; T switches the subtitles first', (tester) async {
      final picks = await pumpOverlay(tester);
      expect(find.text('Subtitles on'), findsOneWidget);
      expect(textInputFocused(), isTrue, reason: "it has the keys: the player's stay off");
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pump();
      expect(find.text('Subtitles off'), findsOneWidget);
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(picks, [(false, null)]);
    });

    testWidgets('Esc and a right-click cancel; without subtitles the switch is off', (tester) async {
      var picks = await pumpOverlay(tester, subs: false);
      expect(find.text('No subtitles'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(picks, ['cancel']);
      picks = await pumpOverlay(tester);
      await tester.tapAt(const Offset(300, 300), buttons: kSecondaryMouseButton);
      await tester.pump();
      expect(picks, ['cancel']);
    });

    testWidgets('during a drag, Esc or a right-click drops it to draw again', (tester) async {
      final picks = await pumpOverlay(tester);
      // Esc while drawing: the release takes nothing, the overlay stays.
      var g = await tester.startGesture(const Offset(100, 150));
      await g.moveTo(const Offset(300, 300));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(picks, isEmpty);
      // A right-click while drawing (a move with both buttons) does the same.
      g = await tester.createGesture(pointer: 7, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      await g.down(const Offset(100, 150));
      await g.moveTo(const Offset(300, 300));
      await g.updateWithCustomEvent(const PointerMoveEvent(
          pointer: 7,
          kind: PointerDeviceKind.mouse,
          position: Offset(301, 300),
          buttons: kPrimaryMouseButton | kSecondaryMouseButton));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(picks, isEmpty);
      // Then a fresh drag picks.
      g = await tester.startGesture(const Offset(0, 20));
      await g.moveTo(const Offset(400, 300));
      await g.up();
      await tester.pump();
      expect(picks, [(true, (x: 0, y: 0, width: 960, height: 540))]);
    });
  });

  group('S in the player', () {
    tearDown(() {
      _graph.navigation.place.value = Place.none;
      _graph.coordinator.serverState.value = null;
      _graph.coordinator.playback.alive.value = false;
      _graph.notifier.clear();
    });

    Future<void> pumpPlayer(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final coord = _graph.coordinator;
      coord.playback.alive.value = true;
      await tester.pumpWidget(scoped(
          _graph,
          MaterialApp(
            theme: ThemeData.dark(),
            shortcuts: appShortcuts,
            home: AppKeys(
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
        mediaId: 1,
        media: const {'name': 'Movie.mkv', 'size': 1, 'duration': 0},
        members: [const MemberView(id: 'a', name: 'Alex')],
      );
      _graph.navigation.place.value = Place.friend;
      await tester.pumpAndSettle();
    }

    List<String> toasts() => [for (final t in _graph.notifier.toasts.value) t.text];

    testWidgets('S and Shift+S take a screenshot (here: no picture to take)', (tester) async {
      await pumpPlayer(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(toasts(), ['No picture to take a screenshot of']);
      _graph.notifier.clear();
      // Past the player's key debounce (on the wall clock).
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(toasts(), ['No picture to take a screenshot of']);
      _graph.notifier.clear();
      await tester.pumpAndSettle();
    });

    testWidgets('typed in the quick chat box, S is a letter', (tester) async {
      await pumpPlayer(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(textInputFocused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(toasts(), isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });
  });
}
