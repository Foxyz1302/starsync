import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sync_relay_core/core.dart';

/// What the player shows, sampled about once a second. [aid] / [sid] are
/// mpv track ids (null = none / subtitles off).
class PlayerSnapshot {
  final double position;
  final bool paused;
  final int? aid;
  final int? sid;
  const PlayerSnapshot({required this.position, required this.paused, this.aid, this.sid});

  @override
  String toString() => 'PlayerSnapshot($position, paused: $paused, aid: $aid, sid: $sid)';
}

/// Playing / Progress / Stopped for one item played with this viewer's own
/// account, so Jellyfin's watched state and Continue Watching follow what
/// this viewer saw. Fed a [PlayerSnapshot] every tick ([update]); sends
/// Progress every [interval] and at once on pause, resume, seek (a jump of
/// more than 3 s from where playback should be) or a track change. Reports
/// go out one after another; a failure is logged and handed to [onError]
/// (the session shows one quiet toast) and never touches playback. A 401
/// calls [onUnauthorized] and ends reporting.
class JellyfinProgressReporter {
  final JellyfinClient client;
  final String itemId;
  final JellyfinMediaSource source;
  final String playSessionId;
  final Duration interval;
  final DateTime Function() _clock;
  final void Function(Object error)? onError;
  final VoidCallback? onUnauthorized;

  JellyfinProgressReporter({
    required this.client,
    required this.itemId,
    required this.source,
    required this.playSessionId,
    this.interval = const Duration(seconds: 10),
    this.onError,
    this.onUnauthorized,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  Future<void> _chain = Future.value();
  bool _playing = false;
  bool _dead = false;
  PlayerSnapshot? _last;
  DateTime? _lastAt;
  DateTime? _lastSentAt;

  /// Between [start] and [stop].
  bool get active => _playing && !_dead;

  /// The report body for [s]: ticks, pause, and mpv's aid/sid mapped to
  /// Jellyfin stream indices (-1 = subtitles off).
  JellyfinPlaybackReport reportFor(PlayerSnapshot s) => JellyfinPlaybackReport(
        itemId: itemId,
        mediaSourceId: source.id,
        playSessionId: playSessionId,
        positionTicks: (s.position * jellyfinTicksPerSecond).round(),
        isPaused: s.paused,
        audioStreamIndex: s.aid == null
            ? null
            : source.jellyfinIndexForMpvTrack(JellyfinStreamType.audio, s.aid!),
        subtitleStreamIndex: s.sid == null
            ? -1
            : source.jellyfinIndexForMpvTrack(JellyfinStreamType.subtitle, s.sid!),
      );

  /// Playing: once the media is open. Again after [stop] (played to the
  /// end, then someone seeked back) starts reporting anew.
  void start(PlayerSnapshot s) {
    if (_playing || _dead) return;
    _playing = true;
    _mark(s);
    _send('Playing', () => client.reportPlaybackStart(reportFor(s)));
  }

  /// Progress when due (see the class doc).
  void update(PlayerSnapshot s, {bool force = false}) {
    if (!_playing || _dead) return;
    final last = _last, lastAt = _lastAt, sentAt = _lastSentAt;
    final now = _clock();
    var due = force || last == null || lastAt == null || sentAt == null;
    if (!due) {
      final elapsed = now.difference(lastAt).inMilliseconds / 1000;
      final expected = last.position + (last.paused ? 0 : elapsed);
      due = s.paused != last.paused ||
          s.aid != last.aid ||
          s.sid != last.sid ||
          (s.position - expected).abs() > 3 ||
          now.difference(sentAt) >= interval;
    }
    _last = s;
    _lastAt = now;
    if (!due) return;
    _lastSentAt = now;
    _send('Progress', () => client.reportPlaybackProgress(reportFor(s)));
  }

  /// Stopped (swap, leave, kick, window close, played to the end).
  /// Completes when it and everything before it went out.
  Future<void> stop(PlayerSnapshot s) {
    if (!_playing || _dead) return _chain;
    _playing = false;
    _send('Stopped', () => client.reportPlaybackStopped(reportFor(s)));
    return _chain;
  }

  void _mark(PlayerSnapshot s) {
    _last = s;
    _lastAt = _lastSentAt = _clock();
  }

  void _send(String what, Future<void> Function() call) {
    _chain = _chain.then((_) async {
      if (_dead) return;
      try {
        await call().timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('jellyfin $what report for $itemId failed: $e');
        if (e is JellyfinException && e.isUnauthorized) {
          _dead = true;
          onUnauthorized?.call();
        }
        onError?.call(e);
      }
    });
  }
}
