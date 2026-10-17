import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/platform/ports/player_host.dart' show RenderMode;
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

  test('dev tools: dev versions and debug runs only', () {
    expect(devToolsFor(version: '1.3.3-dev.2', debug: false), isTrue);
    expect(devToolsFor(version: '0.0.0-dev', debug: false), isTrue);
    expect(devToolsFor(version: '1.3.2', debug: true), isTrue);
    expect(devToolsFor(version: '1.3.2', debug: false), isFalse);
  });
}
