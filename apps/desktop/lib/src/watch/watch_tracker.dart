import 'dart:async';

import 'package:sync_relay_core/core.dart';

import 'watch_history.dart';

// Watch tracking (ARCHITECTURE.md "Watch tracking", D3): one watch per
// media of the server (its `mediaId`), fed every second by the session
// with what this app sees, judged by core's `WatchSession` when it ends.
// The verdict goes to the device history (files and links) and out on
// [WatchTracker.records] (the seam for AniList later); Jellyfin's
// played/resume reports read the same session.

final _log = createLogger('watch');

/// What the session hands the tracker each second.
class WatchSample {
  /// The server's media and its id.
  final int mediaId;
  final Map<String, Object?>? media;
  /// This app's own source of it: the file it put up, the link it put up.
  final String? ownFile;
  final String? ownLink;
  final double position;
  /// The media plays here: the server plays it and this player has it.
  final bool playing;
  /// This viewer is In (`in`): not away, joining or gone.
  final bool present;
  /// The player's duration (0 while unknown) and where the ending starts.
  final double duration;
  final double? endingStart;
  final DateTime at;
  const WatchSample({
    required this.mediaId,
    required this.media,
    required this.position,
    required this.playing,
    required this.present,
    required this.at,
    this.ownFile,
    this.ownLink,
    this.duration = 0,
    this.endingStart,
  });
}

class WatchTracker {
  final WatchHistory history;
  WatchTracker({WatchHistory? history}) : history = history ?? WatchHistory(persist: false);

  final _records = StreamController<WatchRecord>.broadcast();

  /// Every closed watch (peeks too): the device history takes files and
  /// links; AniList progress later listens here.
  Stream<WatchRecord> get records => _records.stream;

  int _mediaId = -1;
  WatchKey? _key;
  String _title = '';
  MediaRef? _ref;
  double _runtime = 0;
  double? _endingStart;
  WatchSession? _session;

  /// The watch of the media playing (null before the first sample).
  WatchSession? get session => _session;
  WatchKey? get key => _key;

  /// One second of the session. A new media closes the watch of the one
  /// before.
  void sample(WatchSample s) {
    if (s.mediaId != _mediaId) {
      close(at: s.at);
      if (s.media == null) return;
      _open(s);
    }
    final session = _session;
    if (session == null) return;
    // A file or link this app put up is known once its swap landed.
    final key = WatchKey.of(s.media, ownFile: s.ownFile, ownLink: s.ownLink);
    if (key != null && key != _key && !(_key?.isJellyfin ?? false)) _key = key;
    if (s.duration > 0) _runtime = s.duration;
    _endingStart = s.endingStart;
    session.sample(s.position, playing: s.playing, present: s.present, at: s.at);
  }

  void _open(WatchSample s) {
    final key = WatchKey.of(s.media, ownFile: s.ownFile, ownLink: s.ownLink);
    final before = key == null ? null : history.entry(key);
    _mediaId = s.mediaId;
    _key = key;
    _title = '${s.media?['name'] ?? ''}';
    try {
      _ref = MediaRef.fromJson(s.media?['ref']);
    } catch (_) {
      _ref = null;
    }
    final d = s.media?['duration'];
    _runtime = d is num && d > 0 ? d.toDouble() : 0;
    _endingStart = null;
    _session = WatchSession(playedBefore: before?.played ?? false, resumeBefore: before?.resumeAt ?? 0);
  }

  /// The same media goes on under another [mediaId] (a restarted server
  /// numbers it anew): the watch carries on.
  void renumber(int from, int to) {
    if (_mediaId == from) _mediaId = to;
  }

  /// What Jellyfin says about the item before this opening (its played
  /// state and resume point, read once it is open).
  void before({required bool played, double resumeAt = 0}) {
    final session = _session;
    if (session == null) return;
    session
      ..playedBefore = played
      ..resumeBefore = resumeAt;
  }

  /// The verdict so far (the runtime as last seen); null without a watch.
  WatchVerdict? get verdict => _session?.verdict(runtime: _runtime, endingStart: _endingStart);

  /// Records the watch as it stands (the end of the media; it may go on
  /// after a seek back and be recorded again).
  WatchRecord? checkpoint({DateTime? at}) {
    final session = _session, key = _key;
    if (session == null || key == null) return null;
    final v = session.verdict(runtime: _runtime, endingStart: _endingStart);
    final r = WatchRecord(
        key: key,
        title: _title,
        ref: _ref,
        verdict: v,
        timeIn: session.timeIn,
        runtime: _runtime,
        at: at ?? DateTime.now().toUtc());
    _log.info('$key: ${v.outcome.name} (${session.timeIn.round()} s In of ${_runtime.round()} s)');
    history.record(r);
    _records.add(r);
    return r;
  }

  /// The watch ends (another media, leaving): recorded and forgotten.
  WatchRecord? close({DateTime? at}) {
    final r = _session == null ? null : checkpoint(at: at);
    _mediaId = -1;
    _key = null;
    _session = null;
    _ref = null;
    _runtime = 0;
    _endingStart = null;
    return r;
  }

  /// The media the current watch is of (-1: none).
  int get mediaId => _mediaId;

  Future<void> dispose() => _records.close();
}
