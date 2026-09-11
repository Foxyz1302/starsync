import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import '../sync/room_diff.dart';

class PlaybackController {
  late final Player player;
  bool _ready = false;

  Future<void> init() async {
    player = Player(
        configuration: PlayerConfiguration(
      bufferSize: 64 * 1024 * 1024,
      vo: Platform.environment['SYNC_RELAY_VO'],
    ));
    _ready = true;
    await _pinBufferProps();
  }

  Future<void> _pin(String property, String value) async {
    try {
      final dynamic platform = player.platform;
      await platform?.setProperty(property, value);
    } catch (e, st) {
      debugPrint('pin $property=$value failed: $e\n$st');
    }
  }

  Future<void> _pinBufferProps() async {
    await _pin('demuxer-readahead-secs', '10');
    await _pin('cache-secs', '10');
    final hwdec = Platform.environment['SYNC_RELAY_HWDEC'];
    if (hwdec != null && hwdec.isNotEmpty) {
      await _pin('hwdec', hwdec);
    }
    await _pin('stream-lavf-o',
        'reconnect_streamed=1,reconnect_on_http_error=1,reconnect_delay_max=4');
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

  double get positionSecs =>
      player.state.position.inMilliseconds / 1000.0;

  double get bufferedSecsAhead {
    final ahead =
        (player.state.buffer - player.state.position).inMilliseconds / 1000.0;
    if (ahead.isNaN || ahead < 0) return 0;
    return ahead;
  }

  double get durationSecs =>
      player.state.duration.inMilliseconds / 1000.0;

  Future<void> apply(List<PlayerAction> actions) async {
    for (final action in actions) {
      try {
        switch (action) {
          case SeekAction(:final position):
            if ((positionSecs - position).abs() < 0.5) break;
            await player.seek(Duration(milliseconds: (position * 1000).round()));
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

  Future<void> dispose() async {
    _ready = false;
    try {
      await player.dispose();
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
