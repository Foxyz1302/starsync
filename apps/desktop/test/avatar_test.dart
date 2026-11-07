// How a person's picture is drawn (`StatusAvatar`), read back as pixels,
// and what its loading edge shows.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/shell/avatar.dart';

/// A square PNG of one colour.
Uint8List _solid(int r, int g, int b, {int size = 64}) =>
    img.encodePng(img.Image(width: size, height: size)..clear(img.ColorRgb8(r, g, b)));

/// [info] drawn at 48 px off the pixel grid on [page], as RGBA pixels.
Future<(ByteData, int)> _render(WidgetTester tester, AvatarInfo info, {Color page = Colors.white}) async {
  tester.view.physicalSize = const Size(200, 200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      home: ColoredBox(
        color: page,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: Padding(
              // Off the pixel grid, as a row of avatars often is.
              padding: const EdgeInsets.fromLTRB(4.5, 4.3, 4, 4),
              child: StatusAvatar(info: info, size: 48),
            ),
          ),
        ),
      ),
    ));
    if (info.image case final i?) await precacheImage(i, tester.element(find.byType(StatusAvatar)));
  });
  await tester.pump();
  late ByteData bytes;
  late int count;
  await tester.runAsync(() async {
    final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage();
    count = image.width * image.height;
    bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
  });
  return (bytes, count);
}

void main() {
  testWidgets('a picture fills its shape: no colour of the person round its edge', (tester) async {
    final (bytes, count) = await _render(
        tester, AvatarInfo(name: 'Bob', color: const Color(0xFFFF0000), image: MemoryImage(_solid(0, 0, 0))));
    // Every pixel is a mix of the black picture and the white page: never
    // the person's red (equal channels, give or take rounding).
    var worst = 0;
    var dark = 0;
    for (var i = 0; i < count; i++) {
      final r = bytes.getUint8(i * 4), g = bytes.getUint8(i * 4 + 1), b = bytes.getUint8(i * 4 + 2);
      final red = r - (g + b) ~/ 2;
      if (red > worst) worst = red;
      if (r < 40) dark++;
    }
    expect(dark, greaterThan(40 * 40), reason: 'the picture is drawn');
    expect(worst, lessThan(6), reason: 'the colour behind the picture shows round its edge');
  });

  group('loading edge', () {
    /// How many pixels of the white run there are, on a black picture.
    Future<int> white(WidgetTester tester, double? progress) async {
      final (bytes, count) = await _render(
          tester,
          AvatarInfo(
            name: 'Bob',
            color: Colors.black,
            image: MemoryImage(_solid(0, 0, 0)),
            activity: AvatarActivity.loading,
            progress: progress,
          ),
          page: Colors.black);
      var n = 0;
      for (var i = 0; i < count; i++) {
        if (bytes.getUint8(i * 4) > 200 && bytes.getUint8(i * 4 + 1) > 200) n++;
      }
      return n;
    }

    testWidgets('the run is as long as the buffer is along', (tester) async {
      final quarter = await white(tester, 0.25);
      final most = await white(tester, 0.75);
      expect(quarter, greaterThan(20));
      expect(most / quarter, closeTo(3, 0.6), reason: 'three times the buffer, three times the run');
    });

    testWidgets('unknown: a short arc (it goes round, never a run that starts over)', (tester) async {
      final arc = await white(tester, null);
      final full = await white(tester, 1);
      expect(arc, greaterThan(20));
      expect(arc / full, closeTo(0.22, 0.08));
    });

    test('the share: buffer against what the group needs, only while loading', () {
      MemberView m({double buffered = 3, bool loading = true}) =>
          MemberView(id: 'b', name: 'Bob', buffered: buffered, loading: loading);
      StateBroadcast r(MemberView b) => StateBroadcast(
            eventId: 1,
            transport: 'held',
            position: 0,
            serverTime: DateTime.now().toUtc(),
            mediaId: 1,
            media: const {'name': 'a.mkv', 'size': 1, 'duration': 0},
            members: [b],
            wantsPlay: true,
          );
      final b = m();
      expect(loadProgressOf(b, r(b)), closeTo(3 / RelayConstants.minBufferSecs, 1e-9));
      final full = m(buffered: 99);
      expect(loadProgressOf(full, r(full)), 1);
      final idle = m(loading: false);
      expect(loadProgressOf(idle, r(idle)), isNull, reason: 'not loading');
      expect(loadProgressOf(b, null), isNull);
    });
  });
}
