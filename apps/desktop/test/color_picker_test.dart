import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/session/identity.dart';
import 'package:starsync/src/shell/avatar.dart';
import 'package:starsync/src/shell/color_picker.dart';
import 'package:starsync/src/shell/profile_edit.dart';
import 'package:starsync/src/widgets/contrast.dart';

import 'test_graph.dart';

/// This file's composition root (see test_graph.dart).
final _graph = testGraph();
Profile get _p => _graph.profile;

// Any colour for everyone: the swatches and "Custom…" (a hue/saturation
// area, a brightness bar and the hex code), and each use keeping it
// readable without changing what was picked.

void main() {
  group('readable anywhere', () {
    const page = Color(0xFF1D1B20);

    test('initials: white while it reads, dark on light colours', () {
      expect(textOn(Colors.deepPurple), Colors.white);
      expect(textOn(Colors.teal), Colors.white);
      expect(textOn(const Color(0xFF101010)), Colors.white);
      expect(textOn(Colors.amber), initialsDark);
      expect(textOn(const Color(0xFFFFF59D)), initialsDark);
      expect(textOn(Colors.white), initialsDark);
    });

    test('a name too dark for the page is lifted, hue kept; a readable one stays', () {
      const ink = Color(0xFF1A0A40);
      final lifted = readableOn(ink, page);
      expect(contrastRatio(lifted, page), greaterThanOrEqualTo(4.5));
      expect(HSLColor.fromColor(lifted).lightness, greaterThan(HSLColor.fromColor(ink).lightness));
      expect(HSLColor.fromColor(lifted).hue, closeTo(HSLColor.fromColor(ink).hue, 2));
      expect(readableOn(const Color(0xFFB39DDB), page), const Color(0xFFB39DDB));
      expect(readableOn(Colors.white, page), Colors.white);
      // On a light background it goes darker instead.
      expect(contrastRatio(readableOn(Colors.yellow, Colors.white), Colors.white), greaterThanOrEqualTo(4.5));
      // Black on black still ends readable.
      expect(contrastRatio(readableOn(Colors.black, Colors.black, min: 3), Colors.black), greaterThanOrEqualTo(3));
    });

    testWidgets("a letter avatar's initial picks its colour by contrast", (tester) async {
      Color initial() => tester.widget<Text>(find.text('P')).style!.color!;
      Future<void> pump(Color c) => tester.pumpWidget(scoped(_graph, MaterialApp(
            home: Center(child: StatusAvatar(info: AvatarInfo(name: 'pol', color: c), size: 64)),
          )));
      await pump(Colors.deepPurple);
      expect(initial(), Colors.white);
      await pump(const Color(0xFFFFEB3B));
      await tester.pumpAndSettle();
      expect(initial(), initialsDark);
    });
  });

  test('hex codes as typed', () {
    expect(colorFromHex('#7e57c2'), const Color(0xFF7E57C2));
    expect(colorFromHex('7E57C2'), const Color(0xFF7E57C2));
    expect(colorFromHex('#fa0'), const Color(0xFFFFAA00));
    expect(colorFromHex('#7e57c'), isNull);
    expect(colorFromHex('zz57c2'), isNull);
  });

  group('Custom…', () {
    late Color before;
    late ProfilePush push;
    final pushed = <String>[];

    setUp(() {
      before = _p.color.peek();
      push = _p.push;
      pushed.clear();
      _p.push = ({String? name, String? avatar, String? color}) {
        if (color != null) pushed.add(color);
      };
      _p.color.value = profileColors.first;
    });

    tearDown(() {
      _p.push = push;
      _p.color.value = before;
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(scoped(_graph, MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: Center(child: SizedBox(width: 300, child: ProfileColors(profile: _p)))),
      )));
    }

    testWidgets('a typed code round-trips: picked, shown as yours, sent once as #rrggbb', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('color-picker')), findsNothing, reason: 'closed until asked');
      expect(find.byKey(const ValueKey('color-own')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('color-custom')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('color-picker')), findsOneWidget, reason: 'opens in place');
      expect(find.text(colorToWire(profileColors.first).substring(1)), findsOneWidget, reason: 'the code of the colour now');

      await tester.enterText(find.byKey(const ValueKey('color-hex')), '7e57c2');
      await tester.pump();
      const purple = Color(0xFF7E57C2);
      expect(_p.color.value, purple, reason: 'live on the card');
      expect(pushed, isEmpty, reason: 'sent once it settles');
      await tester.pump(Profile.colorSettle + const Duration(milliseconds: 50));
      expect(pushed, ['#7e57c2']);
      expect(colorFromWire(pushed.single), purple, reason: 'what others get is exactly what was picked');
      // None of the swatches: it shows as your own, picked.
      expect(find.byKey(const ValueKey('color-own')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dragging through the area sends one change; a swatch moves the picker along', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('color-custom')));
      await tester.pumpAndSettle();
      final area = find.byKey(const ValueKey('color-area'));
      final box = tester.getRect(area);
      // Near full saturation at the top, ending 0.4 of the way along: green.
      final g = await tester.startGesture(box.topLeft + Offset(box.width / 3, 2));
      for (var i = 1; i <= 5; i++) {
        await g.moveTo(box.topLeft + Offset(box.width / 3 + i * 4, 2 + i * 3));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      final picked = _p.color.value;
      final hsv = HSVColor.fromColor(picked);
      expect(hsv.hue, closeTo(144, 3));
      expect(hsv.saturation, greaterThan(0.75));
      await tester.pump(Profile.colorSettle + const Duration(milliseconds: 50));
      expect(pushed, [colorToWire(picked)], reason: 'one change for the whole drag');

      // Darker on the brightness bar.
      final bar = tester.getRect(find.byKey(const ValueKey('color-value')));
      await tester.tapAt(bar.centerLeft + Offset(bar.width * 0.3, 0));
      await tester.pump();
      expect(HSVColor.fromColor(_p.color.value).value, closeTo(0.3, 0.05));
      expect(HSVColor.fromColor(_p.color.value).hue, closeTo(hsv.hue, 2), reason: 'the hue stays');

      // A swatch: the picker and its code follow.
      await tester.tap(find.byWidgetPredicate((w) =>
          w is AnimatedContainer &&
          (w.decoration as BoxDecoration?)?.color?.toARGB32() == profileColors[2].toARGB32()));
      await tester.pump();
      expect(_p.color.value.toARGB32(), profileColors[2].toARGB32());
      expect(find.text(colorToWire(profileColors[2]).substring(1)), findsOneWidget);
      // Closed again.
      await tester.tap(find.byKey(const ValueKey('color-custom')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('color-picker')), findsNothing);
      await tester.pump(Profile.colorSettle);
      expect(tester.takeException(), isNull);
    });
  });
}
