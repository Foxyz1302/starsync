import 'dart:async';
import 'dart:math' as math;

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
///
/// Watched or not is [WatchSession]'s rule, not Jellyfin's position
/// percentages (see ARCHITECTURE.md "Jellyfin in a session"): an item
/// played before ([playedBefore]) stays played (re-marked after Playing,
/// Progress without a position, Stopped without one, then marked played
/// again); otherwise Progress leaves the position out past
/// [_noPositionFrom] of the runtime so Jellyfin cannot mark it played on
/// its own, and Stopped carries what the rule says.
class JellyfinProgressReporter {
  final JellyfinClient client;
  final String itemId;
  final JellyfinMediaSource source;
  final String playSessionId;
  final Duration interval;
  final DateTime Function() _clock;
  final void Function(Object error)? onError;
  final VoidCallback? onUnauthorized;

  /// What this viewer watched of the item while it was open here.
  final WatchSession watch;

  JellyfinProgressReporter({
    required this.client,
    required this.itemId,
    required this.source,
    required this.playSessionId,
    bool playedBefore = false,
    int resumeTicksBefore = 0,
    this.interval = const Duration(seconds: 10),
    this.onError,
    this.onUnauthorized,
    this.onStopped,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _keepPlayed = playedBefore,
        _runtime = (source.runTimeTicks ?? 0) / jellyfinTicksPerSecond,
        watch = WatchSession(
            playedBefore: playedBefore, resumeBefore: resumeTicksBefore / jellyfinTicksPerSecond);

  /// Past this share of the runtime Progress carries no position: Jellyfin
  /// marks an item played past its "max resume" share (90 % by default).
  static const _noPositionFrom = 0.85;

  /// After Stopped (and a mark played) went out: the item's watched
  /// state on the server may differ from what lists show.
  final void Function()? onStopped;

  Future<void> _chain = Future.value();
  bool _playing = false;
  bool _dead = false;
  bool _keepPlayed;
  double _runtime;
  double? _endingStart;
  PlayerSnapshot? _last;
  DateTime? _lastAt;
  DateTime? _lastSentAt;

  /// Between [start] and [stop].
  bool get active => _playing && !_dead;

  /// The item counts as played here (before, or by the rule at a stop).
  bool get keepsPlayed => _keepPlayed;

  /// The player's duration (used when Jellyfin gave no runtime) and where
  /// the ending starts (Outro segment / ED chapter), seconds.
  void timeline({double duration = 0, double? endingStart}) {
    if ((source.runTimeTicks ?? 0) <= 0 && duration > 0) _runtime = duration;
    _endingStart = endingStart;
  }

  /// The report body for [s]: ticks, pause, and mpv's aid/sid mapped to
  /// Jellyfin stream indices (-1 = subtitles off).
  JellyfinPlaybackReport reportFor(PlayerSnapshot s, {bool withPosition = true}) => JellyfinPlaybackReport(
        itemId: itemId,
        mediaSourceId: source.id,
        playSessionId: playSessionId,
        positionTicks: withPosition ? _ticks(s.position) : null,
        isPaused: s.paused,
        audioStreamIndex: s.aid == null
            ? null
            : source.jellyfinIndexForMpvTrack(JellyfinStreamType.audio, s.aid!),
        subtitleStreamIndex: s.sid == null
            ? -1
            : source.jellyfinIndexForMpvTrack(JellyfinStreamType.subtitle, s.sid!),
      );

  static int _ticks(double secs) => (secs * jellyfinTicksPerSecond).round();

  /// Progress may carry the position: not for a played item, not without
  /// a runtime and not near the end (either would let Jellyfin decide).
  bool _progressPosition(double position) =>
      !_keepPlayed && _runtime > 0 && position < _noPositionFrom * _runtime;

  /// Playing: once the media is open. Again after [stop] (played to the
  /// end, then someone seeked back) starts reporting anew. A played item
  /// is marked played again right after (Jellyfin up to 10.11 clears it
  /// on Playing).
  void start(PlayerSnapshot s) {
    if (_playing || _dead) return;
    _playing = true;
    _mark(s);
    watch.sample(s.position, playing: !s.paused, at: _clock());
    _send('Playing', () => client.reportPlaybackStart(reportFor(s)));
    if (_keepPlayed) _send('played', () => client.markPlayed(itemId));
  }

  /// Progress when due (see the class doc).
  void update(PlayerSnapshot s, {bool force = false}) {
    if (!_playing || _dead) return;
    final last = _last, lastAt = _lastAt, sentAt = _lastSentAt;
    final now = _clock();
    watch.sample(s.position, playing: !s.paused, at: now);
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
    final report = reportFor(s, withPosition: _progressPosition(s.position));
    _send('Progress', () => client.reportPlaybackProgress(report));
  }

  /// Stopped (swap, leave, kick, window close, played to the end), as
  /// [WatchSession.verdict] says: played (or kept played) -> no position,
  /// then marked played; a peek -> the resume point from before; part way
  /// -> the position, held under [_noPositionFrom] of the runtime.
  /// Completes when it and everything before it went out.
  Future<void> stop(PlayerSnapshot s) {
    if (!_playing || _dead) return _chain;
    _playing = false;
    watch.sample(s.position, playing: !s.paused, at: _clock());
    final v = _keepPlayed
        ? const WatchVerdict(WatchOutcome.keepPlayed)
        : watch.verdict(runtime: _runtime, endingStart: _endingStart);
    debugPrint('jellyfin $itemId: $v (covered ${watch.covered.round()} s of ${_runtime.round()} s)');
    final int? ticks;
    switch (v.outcome) {
      case WatchOutcome.played || WatchOutcome.keepPlayed:
        _keepPlayed = true;
        ticks = null;
      case WatchOutcome.peek:
        ticks = _ticks(watch.resumeBefore);
      case WatchOutcome.partial:
        final at = v.resumeAt ?? s.position;
        ticks = _ticks(_runtime > 0 ? math.min(at, _noPositionFrom * _runtime) : at);
    }
    final report = JellyfinPlaybackReport(
        itemId: itemId, mediaSourceId: source.id, playSessionId: playSessionId, positionTicks: ticks);
    _send('Stopped', () => client.reportPlaybackStopped(report));
    if (ticks == null) {
      _send('played', () => client.markPlayed(itemId));
      // Marking played keeps a resume point Progress left (Continue would
      // still list it, "3 min left"): clear it.
      _send('resume cleared', () => client.clearResumePosition(itemId));
    }
    return _chain = _chain.then((_) => onStopped?.call());
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
