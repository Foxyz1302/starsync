import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/playback/frame_watchdog.dart';

final _t0 = DateTime.utc(2026, 1, 1);

/// Feeds one sample per second; [frames]/[pos] give the value at second i.
List<bool> _run(
  FrameWatchdog w,
  int seconds, {
  required int? Function(int i) frames,
  double Function(int i)? pos,
  bool Function(int i)? eligible,
  int start = 0,
}) {
  return [
    for (var i = start; i < start + seconds; i++)
      w.feed(FrameSample(
        at: _t0.add(Duration(seconds: i)),
        position: pos?.call(i) ?? i.toDouble(),
        frames: frames(i),
        eligible: eligible?.call(i) ?? true,
      )),
  ];
}

void main() {
  test('hashes tell frames apart and ignore the edges', () {
    final a = ByteData(100 * 60 * 4);
    final b = ByteData(100 * 60 * 4);
    expect(hashCenterPixels(a, 100, 60), hashCenterPixels(b, 100, 60));
    b.setUint8((2 * 100 + 2) * 4, 255); // corner: overlay area
    expect(hashCenterPixels(a, 100, 60), hashCenterPixels(b, 100, 60));
    b.setUint8((30 * 100 + 50) * 4, 255); // centre: video
    expect(hashCenterPixels(a, 100, 60), isNot(hashCenterPixels(b, 100, 60)));
    final raw = Uint8List(1 << 20);
    final h = hashSpread(raw);
    raw[raw.length ~/ 2 - (raw.length ~/ 2) % (raw.length ~/ 4096)] = 1;
    expect(hashSpread(raw), isNot(h));
  });

  test('frames advancing never fires', () {
    final w = FrameWatchdog();
    expect(_run(w, 30, frames: (i) => i * 30), everyElement(isFalse));
  });

  test('frames stuck while position advances fires once after ~3 s', () {
    final w = FrameWatchdog();
    final fired = _run(w, 20, frames: (i) => i < 5 ? i * 30 : 150);
    expect(fired.where((f) => f).length, 1);
    expect(fired.indexOf(true), 8, reason: 'stuck from t=5, 3 s later');
  });

  test('pause, buffering, missing data and seeks do not fire', () {
    final w = FrameWatchdog();
    // Paused / buffering: not eligible.
    expect(_run(w, 10, frames: (_) => 100, eligible: (_) => false),
        everyElement(isFalse));
    // No video output (headless / audio-only).
    expect(_run(w, 10, frames: (_) => null, start: 10), everyElement(isFalse));
    // Position stuck too (network stall): not a frozen picture.
    expect(_run(w, 10, frames: (_) => 100, pos: (_) => 50, start: 20),
        everyElement(isFalse));
    // Seeking every 2 s with frames stuck in between: jumps reset it.
    expect(
        _run(w, 12,
            frames: (_) => 100,
            pos: (i) => i.isEven ? i * 10.0 : i * 10.0 - 9,
            start: 30),
        everyElement(isFalse));
  });

  test('no reload loop: re-arms only after 10 s of healthy frames', () {
    final w = FrameWatchdog();
    expect(_run(w, 10, frames: (_) => 7).where((f) => f).length, 1);
    w.reset(); // new player
    // Brief healthy spell, then stuck again: must not fire.
    expect(
        _run(w, 15, frames: (i) => i < 13 ? i : 13, start: 10)
            .where((f) => f)
            .length,
        0);
    // Healthy for 10 s+, then stuck: fires again.
    w.reset();
    expect(
        _run(w, 25, frames: (i) => i < 42 ? i : 42, start: 30)
            .where((f) => f)
            .length,
        1);
  });

  test('still scene: dismiss re-arms after another full stall', () {
    final w = FrameWatchdog();
    final fired = <int>[];
    for (var i = 0; i < 20; i++) {
      if (w.feed(FrameSample(
          at: _t0.add(Duration(seconds: i)),
          position: i.toDouble(),
          frames: 5,
          eligible: true))) {
        fired.add(i);
        w.dismiss();
      }
    }
    expect(fired, [3, 6, 9, 12, 15, 18]);
  });
}
