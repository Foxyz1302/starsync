import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/platform/ports/player_host.dart' show RenderMode, fitOutputSize;
import 'package:starsync/src/screens/home/ui.dart' show devToolsFor;
import 'package:starsync/src/shell/video_view.dart';

// The video view's asks of mpv: the output size ("Sharp video and
// subtitles") and the dev experiment's subtitle lift.

void main() {
  group('videoOutputSize', () {
    test('the view in physical pixels on the GPU', () {
      expect(videoOutputSize(const Size(1280, 720), 1.5, on: true, mode: RenderMode.gpu), (1920, 1080));
      expect(videoOutputSize(const Size(384, 216), 2, on: true, mode: RenderMode.gpu), (768, 432));
    });

    test("the video's own size when off, not on the GPU yet, or in software", () {
      expect(videoOutputSize(const Size(1280, 720), 1, on: false, mode: RenderMode.gpu), isNull);
      for (final m in [RenderMode.unknown, RenderMode.software, RenderMode.softwareGl]) {
        expect(videoOutputSize(const Size(1280, 720), 1, on: true, mode: m), isNull, reason: m.name);
      }
      expect(videoOutputSize(const Size(4, 4), 1, on: true, mode: RenderMode.gpu), isNull);
    });
  });

  group('fitOutputSize', () {
    test('the picture fitted in the view, no bars', () {
      expect(fitOutputSize((1920, 1080), (1280, 720)), (1920, 1080));
      // 16:9 on a 2560x1080 screen: pillarboxed, full height.
      expect(fitOutputSize((2560, 1080), (1280, 720)), (1920, 1080));
      // The chat panel narrows the view: letterboxed, full width.
      expect(fitOutputSize((880, 720), (1280, 720)), (880, 494));
      expect(fitOutputSize((1280, 720), null), (1280, 720));
      expect(fitOutputSize((1280, 720), (0, 0)), (1280, 720));
    });

    test('the bars split evenly: the picture sits on whole pixels', () {
      for (final (view, video) in [((881, 720), (1280, 720)), ((1000, 999), (1920, 800)), ((1366, 768), (720, 576))]) {
        final (w, h) = fitOutputSize(view, video);
        expect(w <= view.$1 && h <= view.$2, isTrue);
        expect((view.$1 - w).isEven && (view.$2 - h).isEven, isTrue, reason: '$view $video -> ($w, $h)');
        expect(w == view.$1 || h == view.$2, isTrue, reason: 'one side fills the view');
      }
    });
  });

  group('subtitleLiftPos', () {
    test('a picture filling the view lifts by the controls', () {
      // 108 px of controls + 8 px gap in a 1080 px picture: 10.74 %.
      final pos = subtitleLiftPos(view: const Size(1920, 1080), videoW: 1920, videoH: 1080, controls: 108);
      expect(pos, closeTo(100 - 116 / 1080 * 100, 1e-9));
    });

    test('a letterbox under the picture counts toward the room', () {
      // 2.39:1 in 16:9: 803 px picture, 138 px bar below it.
      final none = subtitleLiftPos(view: const Size(1920, 1080), videoW: 1920, videoH: 803, controls: 100);
      expect(none, 100);
      final some = subtitleLiftPos(view: const Size(1920, 1080), videoW: 1920, videoH: 803, controls: 200);
      expect(some, lessThan(100));
    });

    test('unknown video size: as if it filled the view; never past half', () {
      expect(subtitleLiftPos(view: const Size(800, 450), controls: 90), closeTo(100 - 98 / 450 * 100, 1e-9));
      expect(subtitleLiftPos(view: const Size(800, 100), controls: 500), 50);
      expect(subtitleLiftPos(view: Size.zero, controls: 90), 100);
    });
  });

  group('subtitle lift steps', () {
    test('a few large eased-out steps, the last exactly on target', () {
      final up = liftSteps(0, 100);
      expect(up, hasLength(liftStepCount));
      expect(up.last, 100);
      // Eased out: the first step moves most, each one less.
      for (var i = 1; i < up.length; i++) {
        expect(up[i], greaterThan(up[i - 1]));
        if (i > 1) expect(up[i] - up[i - 1], lessThan(up[i - 1] - (i > 1 ? up[i - 2] : 0)));
      }
      expect(up.first, greaterThan(30), reason: 'most of the way at once');
      final down = liftSteps(100, 0);
      expect(down.last, 0);
      expect(down.first, lessThan(70));
      expect(liftSteps(40, 40.2), isEmpty);
    });

    testWidgets('SubtitleLift steps toward the latest target, liftStepGap apart', (tester) async {
      final lift = SubtitleLift();
      addTearDown(lift.dispose);
      final seen = <double>[];
      lift.addListener(() => seen.add(lift.value));
      lift.animateTo(80);
      expect(seen, hasLength(1), reason: 'the first step at once');
      await tester.pump(liftStepGap * (liftStepCount - 1));
      expect(seen, liftSteps(0, 80));
      expect(lift.value, 80);
      await tester.pump(liftStepGap * 4);
      expect(seen, hasLength(liftStepCount), reason: 'nothing after the target');
      // A new target mid-way starts from where it is.
      seen.clear();
      lift.animateTo(0);
      await tester.pump(liftStepGap);
      final from = lift.value, n = seen.length;
      expect(from, inExclusiveRange(0, 80));
      lift.animateTo(80);
      await tester.pump(liftStepGap * liftStepCount);
      expect(seen.sublist(n), liftSteps(from, 80));
    });
  });

  test('dev tools: dev versions and debug runs only', () {
    expect(devToolsFor(version: '1.3.3-dev.2', debug: false), isTrue);
    expect(devToolsFor(version: '0.0.0-dev', debug: false), isTrue);
    expect(devToolsFor(version: '1.3.2', debug: true), isTrue);
    expect(devToolsFor(version: '1.3.2', debug: false), isFalse);
  });
}
