import 'dart:typed_data';

/// FNV-1a over a 15x15 grid of RGB(A) pixels in the central half of an
/// image. Used on a small capture of what the compositor shows: the
/// centre is video, the edges carry the (changing) control overlays.
int hashCenterPixels(ByteData rgba, int width, int height) {
  var x = 0x811c9dc5;
  if (width <= 0 || height <= 0) return x;
  for (var gy = 1; gy < 16; gy++) {
    for (var gx = 1; gx < 16; gx++) {
      final px = (width * (0.25 + 0.5 * gx / 16)).floor();
      final py = (height * (0.25 + 0.5 * gy / 16)).floor();
      final o = (py * width + px) * 4;
      if (o + 3 > rgba.lengthInBytes) continue;
      for (var c = 0; c < 3; c++) {
        x = ((x ^ rgba.getUint8(o + c)) * 0x01000193) & 0xffffffff;
      }
    }
  }
  return x;
}

/// FNV-1a over ~4k bytes spread evenly across a raw frame (mpv
/// `screenshot-raw`); dimension-agnostic, enough to tell frames apart.
int hashSpread(Uint8List bytes) {
  var x = 0x811c9dc5;
  if (bytes.isEmpty) return x;
  final step = bytes.length <= 4096 ? 1 : bytes.length ~/ 4096;
  for (var i = 0; i < bytes.length; i += step) {
    x = ((x ^ bytes[i]) * 0x01000193) & 0xffffffff;
  }
  return x;
}

/// One sample of player state, taken about once a second.
class FrameSample {
  final DateTime at;
  final double position;

  /// Fingerprint of the picture currently shown on screen; null when it
  /// cannot be captured (no view, hidden window, headless).
  final int? frames;

  /// Playing, not buffering, rate > 0, video track present, window
  /// visible. Anything else disarms the watchdog.
  final bool eligible;
  const FrameSample({
    required this.at,
    required this.position,
    required this.frames,
    required this.eligible,
  });
}

/// Detects a frozen picture: position advances normally but the shown
/// picture stands still for [stallAfter]. Seeks (position jumps), pauses,
/// buffering and missing captures all reset the stall clock. A hit is a
/// suspicion only — a still scene looks the same — so the caller confirms
/// it against the decoder and calls [dismiss] when it was a still scene.
/// Fires at most once until the picture is seen moving again for
/// [rearmAfter], so a player that stays (or soon gets) frozen after a
/// reload does not reload in a loop. [reset] keeps that latch.
class FrameWatchdog {
  static const stallAfter = Duration(seconds: 3);
  static const rearmAfter = Duration(seconds: 10);

  FrameSample? _last;
  DateTime? _stallSince;
  DateTime? _healthySince;
  bool _fired = false;

  void reset() {
    _last = null;
    _stallSince = null;
    _healthySince = null;
  }

  /// The last hit was a still scene: re-arm, but wait a full
  /// [stallAfter] before suspecting again.
  void dismiss() {
    _fired = false;
    _stallSince = null;
  }

  /// Returns true exactly when a freeze is suspected.
  bool feed(FrameSample s) {
    final last = _last;
    _last = s;
    if (!s.eligible || s.frames == null || last == null ||
        !last.eligible || last.frames == null) {
      _stallSince = null;
      _healthySince = null;
      return false;
    }
    if (s.frames != last.frames) {
      _stallSince = null;
      _healthySince ??= last.at;
      if (s.at.difference(_healthySince!) >= rearmAfter) _fired = false;
      return false;
    }
    _healthySince = null;
    final wall = s.at.difference(last.at).inMilliseconds / 1000.0;
    final moved = s.position - last.position;
    // Normal playback only: a jump (seek) or a standstill (stall, the
    // position itself stuck) is not a frozen picture.
    final normal = wall > 0 && moved > wall * 0.5 && moved < wall * 2 + 0.5;
    if (!normal) {
      _stallSince = null;
      return false;
    }
    _stallSince ??= last.at;
    if (_fired) return false;
    if (s.at.difference(_stallSince!) >= stallAfter) {
      _fired = true;
      _stallSince = null;
      return true;
    }
    return false;
  }
}
