import 'dart:io';

import 'package:flutter/foundation.dart';

/// Timings of one media change on this client, from the `state` naming
/// the new media to the server playing it (see ARCHITECTURE.md "Getting
/// ready"). Printed when [enabled] (env `SYNC_RELAY_TRACE_SWITCH=1`);
/// marks are always kept for the last few media, tests read them.
class SwitchTrace {
  /// Phases, in the order they usually happen.
  static const state = 'state';
  static const resolved = 'resolved';
  static const open = 'open';
  static const opened = 'opened';
  static const preloaded = 'preloaded';
  static const buffered = 'buffered';
  static const playing = 'playing';

  static bool enabled = (Platform.environment['SYNC_RELAY_TRACE_SWITCH'] ?? '').isNotEmpty;

  final String who;
  SwitchTrace([this.who = '']);

  final Map<int, Map<String, int>> _marks = {};
  final Map<int, Stopwatch> _clocks = {};

  /// Milliseconds from [state] to each phase of media [mediaId].
  Map<String, int> of(int mediaId) => Map.unmodifiable(_marks[mediaId] ?? const {});

  /// Starts the clock for [mediaId] (its first `state`).
  void start(int mediaId) {
    if (_clocks.containsKey(mediaId)) return;
    _clocks[mediaId] = Stopwatch()..start();
    _marks[mediaId] = {state: 0};
    while (_clocks.length > 4) {
      final oldest = _clocks.keys.first;
      _clocks.remove(oldest);
      _marks.remove(oldest);
    }
  }

  /// Records [phase] once for [mediaId]; [playing] ends the trace.
  void mark(int mediaId, String phase) {
    final clock = _clocks[mediaId];
    final marks = _marks[mediaId];
    if (clock == null || marks == null || marks.containsKey(phase)) return;
    marks[phase] = clock.elapsedMilliseconds;
    if (phase == playing && enabled) {
      debugPrint('switch${who.isEmpty ? '' : ' $who'} m$mediaId: '
          '${[for (final e in marks.entries) '${e.key} +${e.value} ms'].join(', ')}');
    }
  }
}
