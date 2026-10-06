import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';

import '../state/settings.dart';
import '../sync/state_diff.dart';
import '../sync/user_seek.dart';
import 'frame_watchdog.dart';

/// Owns one mpv [Player] (and its [VideoController]) per session: created
/// by [init] on join, released by [dispose] on leave, swapped by
/// [recreate] for "Reload video". Never reuse a player across sessions —
/// a GPU-side freeze sticks to the player, not to the widget.
class PlaybackController {
  /// Read-ahead target: about two minutes rides out short outages and
  /// makes skipping an intro instant.
  static const readAheadSecs = 150;
  /// Forward demuxer cache. Holds [readAheadSecs] up to ~14 Mbit/s (a
  /// 1.4 GB / 24 min file is ~8); higher bitrates get less time. In RAM:
  /// media_kit sets cache-on-disk but no cache-dir, so mpv falls back.
  static const maxBytes = 256 * 1024 * 1024;
  /// Back buffer (media_kit sets it to bufferSize too): enough for a short
  /// seek back without holding another 256 MiB.
  static const maxBackBytes = 64 * 1024 * 1024;

  SyncPlayer? _player;
  VideoController? _video;
  Timer? _watchTimer;
  bool _probing = false;
  final FrameWatchdog _watchdog = FrameWatchdog();

  /// Bumped for every new player; the video view keys itself on it so a
  /// recreated player gets a fresh `Video` widget.
  final generation = signal(0);

  /// True while a live player exists. The video view shows plain black
  /// otherwise, so no texture outlives its player.
  final alive = signal(false);

  /// Called once when the watchdog sees a frozen picture.
  void Function()? onFrozen;

  /// Fingerprint of the picture on screen, installed by the video view
  /// (`ShownFrameProbe.sample`). Without it the watchdog stays idle.
  Future<int?> Function()? shownFrame;

  Player get player => _player!;

  /// Seeks from the video controls (seek bar) go here instead of to mpv.
  void Function(Duration position)? onUserSeek;

  /// Pinned mpv properties whose read-back differs from what was set
  /// (mpv ignores invalid values silently), as `name: wanted -> got`.
  final List<String> pinMismatches = [];
  bool get _ready => _player != null;

  /// The [VideoController] of the current player. Created lazily by the
  /// video view (it needs a running Flutter binding; headless tests never
  /// touch it) and released with the player.
  VideoController get video {
    final existing = _video;
    if (existing != null) return existing;
    final hwdec = _hwdecOverride;
    // media_kit's video output sets hwdec itself on attach ('auto' unless
    // configured), which used to override SYNC_RELAY_HWDEC.
    return _video = VideoController(
      player,
      configuration: VideoControllerConfiguration(hwdec: hwdec),
    );
  }

  // SYNC_RELAY_HWDEC wins over the Settings choice; read per player, so a
  // changed setting applies on the next join or Reload video.
  static String? get _hwdecOverride {
    final hwdec = Platform.environment['SYNC_RELAY_HWDEC'];
    if (hwdec != null && hwdec.isNotEmpty) return hwdec;
    return AppSettings.instance.hwdec.peek();
  }

  Future<void> init() async {
    if (_player != null) return;
    _player = SyncPlayer(
        configuration: PlayerConfiguration(
      bufferSize: maxBytes,
      libass: true,
      vo: Platform.environment['SYNC_RELAY_VO'],
    ))
      ..onUserSeek = (d) => onUserSeek?.call(d);
    await _pinBufferProps();
    _watchdog.reset();
    _watchTimer = Timer.periodic(const Duration(seconds: 1), (_) => _watch());
    generation.value++;
    alive.value = true;
  }

  /// Dispose the current player and start a fresh one (no media loaded).
  /// Keeps volume. The caller reopens media and resyncs.
  Future<void> recreate() async {
    final volume = _player?.state.volume;
    await dispose();
    await init();
    if (volume != null) {
      try {
        await player.setVolume(volume);
      } catch (_) {}
    }
  }

  Future<void> _pin(String property, String value) async {
    try {
      final dynamic platform = player.platform;
      await platform?.setProperty(property, value);
      final got = '${await platform?.getProperty(property)}';
      if (!pinMatches(value, got)) {
        pinMismatches.add('$property: $value -> $got');
        debugPrint('pin $property=$value not applied, mpv has "$got"');
      }
    } catch (e, st) {
      pinMismatches.add('$property: $value -> error $e');
      debugPrint('pin $property=$value failed: $e\n$st');
    }
  }

  Future<void> _pinBufferProps() async {
    pinMismatches.clear();
    await _pin('demuxer-readahead-secs', '$readAheadSecs');
    await _pin('cache-secs', '$readAheadSecs');
    await _pin('demuxer-max-bytes', '$maxBytes');
    await _pin('demuxer-max-back-bytes', '$maxBackBytes');
    final hwdec = _hwdecOverride;
    if (hwdec != null) {
      await _pin('hwdec', hwdec);
    }
    await _pin('stream-lavf-o',
        'reconnect_streamed=1,reconnect_on_http_error=1,reconnect_delay_max=4');
  }

  /// Fingerprint of the decoder's current frame (mpv `screenshot-raw`,
  /// off-thread); null without video.
  Future<int?> _sourceFrame(Player p) async {
    try {
      final raw = await p.screenshot(format: null);
      return raw == null || raw.isEmpty ? null : hashSpread(raw);
    } catch (_) {
      return null;
    }
  }

  /// A suspected freeze is real only if mpv's own frames still move: a
  /// still scene looks frozen on screen too.
  Future<bool> _sourceMoving(Player p) async {
    final a = await _sourceFrame(p);
    await Future.delayed(const Duration(milliseconds: 500));
    if (!identical(p, _player) || !p.state.playing) return false;
    final b = await _sourceFrame(p);
    return a != null && b != null && a != b;
  }

  static bool get _windowVisible {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == null ||
          s == AppLifecycleState.resumed ||
          s == AppLifecycleState.inactive;
    } catch (_) {
      return false;
    }
  }

  Future<void> _watch() async {
    final p = _player;
    final probe = shownFrame;
    // Only meaningful once the video view is up.
    if (p == null || _video == null || probe == null || _probing) return;
    _probing = true;
    try {
      final frames = await probe();
      if (!identical(p, _player)) return;
      final s = p.state;
      final eligible = s.playing &&
          !s.buffering &&
          !s.completed &&
          s.rate > 0 &&
          (s.width ?? 0) > 0 &&
          _windowVisible;
      final fired = _watchdog.feed(FrameSample(
        at: DateTime.now(),
        position: positionSecs,
        frames: frames,
        eligible: eligible,
      ));
      if (fired) {
        if (await _sourceMoving(p) && identical(p, _player)) {
          debugPrint('video watchdog: picture stuck while mpv frames move');
          onFrozen?.call();
        } else {
          _watchdog.dismiss();
        }
      }
    } finally {
      _probing = false;
    }
  }

  Future<void> openUrl(String url) async {
    if (!_ready) return;
    try {
      await player.open(Media(url), play: false);
    } catch (e, st) {
      debugPrint('open $url failed: $e\n$st');
      rethrow;
    }
  }

  double get positionSecs {
    final p = _player;
    if (p == null) return 0;
    return p.state.position.inMilliseconds / 1000.0;
  }

  double get bufferedSecsAhead {
    final p = _player;
    if (p == null) return 0;
    final ahead = (p.state.buffer - p.state.position).inMilliseconds / 1000.0;
    if (ahead.isNaN || ahead < 0) return 0;
    return ahead;
  }

  double get durationSecs {
    final p = _player;
    if (p == null) return 0;
    return p.state.duration.inMilliseconds / 1000.0;
  }

  Future<void> apply(List<PlayerAction> actions) async {
    if (!_ready) return;
    for (final action in actions) {
      try {
        switch (action) {
          case SeekAction(:final position):
            if ((positionSecs - position).abs() < 0.5) break;
            await _player!
                .syncSeek(Duration(milliseconds: (position * 1000).round()));
          case TransportAction(:final playing):
            if (playing) {
              await player.play();
            } else {
              await player.pause();
            }
          case RateAction(:final rate):
            await player.setRate(rate);
        }
      } catch (e, st) {
        debugPrint('player action $action failed: $e\n$st');
      }
    }
  }

  /// Release the player. The view drops its texture first ([alive] goes
  /// false, one frame passes), then mpv is torn down.
  Future<void> dispose() async {
    final p = _player;
    if (p == null) return;
    _watchTimer?.cancel();
    _watchTimer = null;
    _player = null;
    _video = null;
    alive.value = false;
    await _settleUi();
    try {
      await p.dispose();
    } catch (_) {}
  }

  // Two frames: one may already be mid-build when [alive] flips. Then
  // the length of a route pop (the fullscreen route holds its own `Video`
  // and leaves animated). Bounded, since a hidden window renders no
  // frames; headless tests have no binding and skip it all.
  static Future<void> _settleUi() async {
    try {
      for (var i = 0; i < 2; i++) {
        await WidgetsBinding.instance.endOfFrame
            .timeout(const Duration(milliseconds: 300));
      }
      await Future.delayed(const Duration(milliseconds: 350));
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!_ready) return;
    try {
      await player.stop();
    } catch (e, st) {
      debugPrint('player stop failed: $e\n$st');
    }
  }
}

/// mpv echoes numbers in its own format (`150` reads back `150.000000`).
bool pinMatches(String wanted, String got) {
  if (wanted == got) return true;
  final a = double.tryParse(wanted), b = double.tryParse(got);
  return a != null && b != null && a == b;
}
