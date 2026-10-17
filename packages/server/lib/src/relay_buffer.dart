import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';

import 'relay_stats.dart';

final _log = createLogger('relay');

/// A viewer's read ended because its relay went (a swap, server stop):
/// not a failure, the response just ends.
class RelayEnded implements Exception {
  const RelayEnded();
  @override
  String toString() => 'relay ended';
}

/// The wait before the next pull after [failures] failed ones in a row:
/// 250 ms doubling to [RelayConstants.relayRetryMaxMs] (a source whose
/// upstream keeps failing must not be asked again and again at once).
Duration relayRetryDelay(int failures) => failures <= 0
    ? Duration.zero
    : Duration(milliseconds: min(RelayConstants.relayRetryMaxMs, 250 * (1 << min(failures - 1, 10))));

/// One track's buffer on the server: a byte stream ([RelayBuffer]) or
/// pieces ([PieceBuffer]).
abstract interface class TrackBuffer {
  /// Budgets, set by the relay when a media's tracks share them.
  abstract int ahead, back;
  bool get live;
  int get cachedBytes;
  int get bytesFromFeed;
  int get bytesToViewers;
  /// Runs while this buffer has a pull in flight; the relay gives its
  /// tracks one, for the source's rate.
  abstract FeedClock clock;
  /// Waits for the feed's first connect, up to the wait limit.
  Future<bool> ready();
  void detach(RelayFeed feed);
  void dispose();
  void feedBytes(int id, Uint8List data);
  void feedEnd(int id);
  void feedFail(int id, String reason);
}

/// What feeds a [TrackBuffer]: a member's relay channel, or the server
/// itself fetching a link ([LocalRelayFeed]).
abstract class RelayFeed {
  /// Ask for bytes [start]..[end]; they arrive via [TrackBuffer.feedBytes]
  /// in order, then [TrackBuffer.feedEnd].
  void pull(int id, int start, int end);

  /// Ask for piece [index] of a pieces track, whole (arrives like [pull]).
  void pullPiece(int id, int index);
  void cancel(int id);

  /// Bytes of [id] reached the buffer (the remote feed acks them).
  void arrived(int id, int n) {}
}

/// Fetches [track] in this process (the "server fetches it" mode).
class LocalRelayFeed extends RelayFeed {
  final RelayTrack track;
  final TrackBuffer buffer;
  final _subs = <int, StreamSubscription<List<int>>>{};
  LocalRelayFeed(this.track, this.buffer);

  @override
  void pull(int id, int start, int end) => _listen(id, track.bytes!.read(start, end));

  @override
  void pullPiece(int id, int index) => _listen(id, track.pieces!.read(index));

  void _listen(int id, Stream<List<int>> data) {
    _subs[id] = data.listen(
          (c) => buffer.feedBytes(id, c is Uint8List ? c : Uint8List.fromList(c)),
          onError: (Object e) {
            unawaited(_subs.remove(id)?.cancel().catchError((_) {}));
            buffer.feedFail(id, '$e');
          },
          onDone: () {
            _subs.remove(id);
            buffer.feedEnd(id);
          },
          cancelOnError: true,
        );
  }

  /// A read cut off mid-request errors on cancel: moot.
  @override
  void cancel(int id) => unawaited(_subs.remove(id)?.cancel().catchError((_) {}));

  Future<void> close() async {
    for (final s in _subs.values) {
      await s.cancel().catchError((_) {});
    }
    _subs.clear();
    await track.bytes?.close();
    await track.pieces?.close();
  }
}

/// A relay channel (`/r/.../source`) as a feed: [track] of the source's
/// media (null: a single file, the pull names no track).
class ChannelRelayFeed extends RelayFeed {
  final void Function(String text) send;
  final int? track;
  ChannelRelayFeed(this.send, {this.track});

  @override
  void pull(int id, int start, int end) =>
      send(jsonEncode({'t': 'pull', 'id': id, if (track != null) 'track': track, 'start': start, 'end': end}));

  @override
  void pullPiece(int id, int index) =>
      send(jsonEncode({'t': 'pull', 'id': id, if (track != null) 'track': track, 'piece': index}));

  @override
  void cancel(int id) => send(jsonEncode({'t': 'cancel', 'id': id}));

  @override
  void arrived(int id, int n) => send(jsonEncode({'t': 'ack', 'id': id, 'n': n}));
}

class _Pull {
  final int id, start, end;
  int pos;
  // The slice being filled: its chunks so far (readers take them as they
  // come, see [RelayBuffer.read]).
  final parts = <Uint8List>[];
  int filled = 0;
  _Pull(this.id, this.start, this.end) : pos = start;

  /// Bytes of the slice being filled from [from] (offset in the slice).
  Uint8List? partFrom(int from) {
    if (from >= filled) return null;
    final out = BytesBuilder(copy: false);
    var at = 0;
    for (final p in parts) {
      final end = at + p.length;
      if (end > from) out.add(at >= from ? p : Uint8List.sublistView(p, from - at));
      at = end;
    }
    return out.takeBytes();
  }

  Uint8List takeSlice() {
    final out = BytesBuilder(copy: false);
    for (final p in parts) {
      out.add(p);
    }
    parts.clear();
    filled = 0;
    return out.takeBytes();
  }
}

class _Viewer {
  final String name;
  int pos = 0;
  int open = 0; // requests in flight
  int newest = 0; // sequence of its newest request
  (int slice, int req)? blocking; // where its newest request waits
  DateTime lastActive = DateTime.now();
  _Viewer(this.name);
}

/// The server side of the relay for one media: an in-memory buffer of
/// [RelayConstants.relaySliceBytes] slices filled from one [RelayFeed] with
/// one sequential pull at a time, served to any number of viewers.
///
/// - Viewers only ever talk HTTP to the server; the feed never sees their
///   request pattern (mpv leaves superseded requests open but unread, and
///   jumps to the file's end for the index).
/// - Kept: the file's first and last [pin] bytes, plus [back] behind the
///   slowest and [ahead] past the furthest viewer. Evicted by distance from
///   the viewers, never LRU.
/// - Filled only while someone watches: a viewer blocked on a slice comes
///   first (oldest wait first); then read-ahead. A blocked viewer reads the
///   slice being filled as its bytes arrive, not once it is whole.
/// - Only a viewer's newest request moves its position or asks the feed
///   for anything; older ones still get bytes once they are buffered, and
///   stop holding the feed once superseded (a seek elsewhere).
/// - [together]: two viewers kept within [ahead] of each other (see the
///   field).
/// - Read-ahead never fetches a slice that would be the next one evicted.
/// Everything lives in memory: dropping the buffer is the cleanup.
class RelayBuffer implements TrackBuffer {
  /// Set by the relay when a media's tracks share the budget.
  @override
  int ahead, back;
  final int pin;
  final Duration waitLimit;
  /// Pull ids; the tracks of one media share one sequence (one channel).
  final int Function() _newId;
  /// Two viewers that read one stream at about one position (the source's
  /// own player and its upload to the server, see [SharedSource]) and
  /// must not pull the feed two ways: while both have a request open, a
  /// read of the one more than [ahead] past the other waits without
  /// asking the feed for anything (and without the wait limit), and its
  /// position does not count for read-ahead or eviction. So one
  /// sequential feed serves both, from one window, instead of handing
  /// over at every slice boundary. Pinned slices are always read. Null:
  /// every viewer drives on its own (the server's viewers).
  final (String, String)? together;
  RelayBuffer({
    this.ahead = RelayConstants.relayAheadBytes,
    this.back = RelayConstants.relayBackBytes,
    this.pin = RelayConstants.relayPinBytes,
    this.waitLimit = const Duration(seconds: RelayConstants.relayWaitSecs),
    this.together,
    int Function()? nextId,
  }) : _newId = nextId ?? _counter();

  static int Function() _counter() {
    var n = 0;
    return () => ++n;
  }

  static const slice = RelayConstants.relaySliceBytes;

  RelayFeed? _feed;
  int size = 0;
  final _slices = <int, Uint8List>{};
  final _waiters = <int, List<Completer<void>>>{};
  final _blocked = <int, int>{}; // slice -> wait start (us)
  // The driving requests waiting on each blocked slice.
  final _blockedBy = <int, Set<int>>{};
  final _viewers = <String, _Viewer>{};
  // Reads held back by [together], woken when a position moves.
  var _moved = Completer<void>();
  @override
  FeedClock clock = FeedClock();
  _Pull? _pullNow;
  _Pull? get _pull => _pullNow;
  set _pull(_Pull? p) {
    if ((_pullNow == null) != (p == null)) p == null ? clock.stop() : clock.start();
    _pullNow = p;
  }

  var _reqSeq = 0;
  var _disposed = false;
  // Failed pulls in a row, and when the next pull may start (backoff).
  var _failures = 0;
  DateTime? _retryAt;
  Completer<void> _kick = Completer();
  final Completer<void> _ready = Completer();

  /// Totals, for logs and tests.
  @override
  int bytesFromFeed = 0, bytesToViewers = 0;

  @override
  bool get live => _feed != null && size > 0;
  @override
  int get cachedBytes => _slices.values.fold(0, (a, s) => a + s.length);
  int get _nSlices => (size + slice - 1) ~/ slice;
  int _sliceEnd(int s) => min((s + 1) * slice, size) - 1;

  /// Attaches a (re)connected feed for a file of [size] bytes. A different
  /// size means different content: the buffer starts over.
  void attach(RelayFeed feed, int size) {
    if (_disposed) return;
    if (this.size != 0 && this.size != size) {
      _log.info('relay source changed size ${this.size} -> $size, dropping buffer');
      _slices.clear();
    }
    _feed = feed;
    this.size = size;
    if (!_ready.isCompleted) _ready.complete();
    if (_fillerRunning) {
      _wake();
    } else {
      unawaited(_filler());
    }
  }

  /// The feed went away; buffered slices keep serving.
  @override
  void detach(RelayFeed feed) {
    if (!identical(_feed, feed)) return;
    _feed = null;
    _pull = null;
    _wake();
  }

  @override
  void dispose() {
    _disposed = true;
    _feed = null;
    _pull = null;
    _slices.clear();
    for (final list in _waiters.values) {
      for (final c in list) {
        if (!c.isCompleted) c.complete();
      }
    }
    _waiters.clear();
    if (!_ready.isCompleted) _ready.complete();
    _wake();
    _wakeHeld();
  }

  void _wake() {
    if (!_kick.isCompleted) _kick.complete();
  }

  void _wakeHeld() {
    if (together == null) return;
    final m = _moved;
    _moved = Completer<void>();
    m.complete();
  }

  /// [v] is one of [together] and more than [ahead] past the other while
  /// that one has a request open: it does not drive.
  bool _held(_Viewer v) {
    final t = together;
    if (t == null) return false;
    final other = v.name == t.$1 ? t.$2 : (v.name == t.$2 ? t.$1 : null);
    final o = other == null ? null : _viewers[other];
    return o != null && o.open > 0 && v.pos > o.pos + ahead;
  }

  // ------------------------------------------------------------ feed input

  @override
  void feedBytes(int id, Uint8List data) {
    final pl = _pull;
    if (pl == null || pl.id != id || _disposed) return;
    _feed?.arrived(id, data.length);
    bytesFromFeed += data.length;
    var off = 0;
    while (off < data.length) {
      final s = pl.pos ~/ slice;
      final take = min(_sliceEnd(s) + 1 - pl.pos, data.length - off);
      if (take <= 0) {
        // Past the end the feed claimed: protocol violation.
        _endPull(pl);
        return;
      }
      pl.parts.add(Uint8List.sublistView(data, off, off + take));
      pl.filled += take;
      off += take;
      pl.pos += take;
      final done = pl.pos == _sliceEnd(s) + 1;
      if (done) {
        _slices[s] = pl.takeSlice();
        // A whole slice came: the source works again.
        _failures = 0;
        // A long pull stays within the budget as it goes.
        _evict();
      }
      // Whole, or more of it: whoever waits on it reads on.
      for (final c in _waiters.remove(s) ?? const <Completer<void>>[]) {
        c.complete();
      }
      if (done && _shouldStop(pl, s)) {
        _endPull(pl);
        return;
      }
    }
  }

  @override
  void feedEnd(int id) {
    final pl = _pull;
    if (pl != null && pl.id == id) {
      _pull = null;
      _failures = 0;
      _wake();
    }
  }

  @override
  void feedFail(int id, String reason) {
    final pl = _pull;
    if (pl == null || pl.id != id) return;
    _pull = null;
    final delay = relayRetryDelay(++_failures);
    _retryAt = DateTime.now().add(delay);
    final pass = _pullFailThrottle.allow('${identityHashCode(this)}');
    if (pass != null) {
      _log.warning('${pass}relay pull $id failed ($_failures in a row, next in ${delay.inMilliseconds} ms): $reason');
    }
    _wake();
  }

  static final _pullFailThrottle = LogThrottle(burst: 3);

  // ------------------------------------------------------------- scheduling

  bool _shouldStop(_Pull pl, int done) {
    final next = done + 1;
    if (next >= _nSlices || next * slice > pl.end) return false; // ends naturally
    // Someone is blocked elsewhere: hand the feed over at this boundary.
    if (_blocked.keys.any((w) => w != next && w != next + 1 && !_slices.containsKey(w))) {
      return true;
    }
    if (_slices.containsKey(next)) return true;
    if (!_wanted(next)) return true;
    // Read-ahead nobody waits on stops where the next slice would be the
    // next one evicted (else a full buffer fetches and drops it in turn).
    final s = next - 1;
    return !_blocked.containsKey(s) && !_blocked.containsKey(next) && !_roomFor(next);
  }

  /// Slice [s] can come in without being the next one evicted: the
  /// buffer has room, or holds a slice farther from the viewers.
  bool _roomFor(int s) {
    if ((_slices.length + 1) * slice <= ahead + back + 2 * pin) return true;
    final at = _positions();
    final d = _distance(s, at);
    if (d < 0) return true;
    for (final c in _slices.keys) {
      if (!_waiters.containsKey(c) && _distance(c, at) > d) return true;
    }
    return false;
  }

  void _endPull(_Pull pl) {
    if (!identical(_pull, pl)) return;
    _pull = null;
    if (pl.pos <= pl.end) _feed?.cancel(pl.id);
    _wake();
  }

  Iterable<_Viewer> get _active {
    final now = DateTime.now();
    return _viewers.values.where(
        (v) => (v.open > 0 || now.difference(v.lastActive) < const Duration(seconds: 60)) && !_held(v));
  }

  bool _pinned(int s) => s * slice < pin || s * slice >= size - pin;

  bool _wanted(int s) {
    if (_pinned(s)) return true;
    final pos = _active.map((v) => v.pos).toList();
    if (pos.isEmpty) return false;
    final off = s * slice;
    return off >= pos.reduce(min) - back && off <= pos.reduce(max) + ahead;
  }

  /// The active viewers' positions, for [_distance].
  List<int> _positions() => [for (final v in _active) v.pos];

  /// How far slice [s] is from the viewers at [positions]; -1 pinned.
  int _distance(int s, List<int> positions) {
    if (_pinned(s)) return -1;
    final off = s * slice;
    var d = 1 << 62;
    for (final p in positions) {
      // Behind a viewer costs more than ahead (it was already watched).
      d = min(d, off >= p ? off - p : (p - off) * 4);
    }
    return d;
  }

  void _evict() {
    final limit = ahead + back + 2 * pin;
    var total = _slices.length * slice;
    if (total <= limit) return;
    final at = _positions();
    final dist = {for (final s in _slices.keys) s: _distance(s, at)};
    final order = dist.keys.toList()..sort((a, b) => dist[b]!.compareTo(dist[a]!));
    for (final s in order) {
      if (total <= limit || dist[s]! < 0) break;
      if (_waiters.containsKey(s)) continue;
      _slices.remove(s);
      total -= slice;
    }
  }

  int? _nextMissing() {
    final blocked = _blocked.entries.where((e) => !_slices.containsKey(e.key)).toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (blocked.isNotEmpty) return blocked.first.key;
    final active = _active.toList();
    if (active.isEmpty) return null; // nobody watches: fetch nothing
    for (var s = 0; s * slice < pin && s < _nSlices; s++) {
      if (!_slices.containsKey(s)) return s;
    }
    for (var s = max(0, (size - pin) ~/ slice); s < _nSlices; s++) {
      if (!_slices.containsKey(s)) return s;
    }
    final starts = active.map((v) => v.pos).toList()..sort();
    for (final p in starts) {
      for (var s = p ~/ slice; s * slice <= p + ahead && s < _nSlices; s++) {
        if (!_slices.containsKey(s)) return _roomFor(s) ? s : null;
      }
    }
    return null;
  }

  var _fillerRunning = false;

  Future<void> _filler() async {
    _fillerRunning = true;
    try {
      while (!_disposed) {
        final feed = _feed;
        if (feed == null || _pull != null) {
          await _sleep();
          continue;
        }
        final retry = _retryAt;
        if (retry != null && DateTime.now().isBefore(retry)) {
          await _sleep(retry.difference(DateTime.now()));
          continue;
        }
        _retryAt = null;
        _evict();
        final s = _nextMissing();
        if (s == null) {
          await _sleep();
          continue;
        }
        var e = s;
        while (e + 1 < _nSlices && !_slices.containsKey(e + 1) && _wanted(e + 1)) {
          e++;
        }
        final pl = _Pull(_newId(), s * slice, _sliceEnd(e));
        _pull = pl;
        feed.pull(pl.id, pl.start, pl.end);
      }
    } finally {
      _fillerRunning = false;
    }
  }

  Future<void> _sleep([Duration limit = const Duration(seconds: 5)]) async {
    _kick = Completer();
    // Also wake periodically: viewers age out of [_active].
    await _kick.future.timeout(limit, onTimeout: () {});
  }

  /// The bytes of slice [s] from [from] (offset in the slice) as soon as
  /// there are any: the whole slice's rest, or what the pull filling it has
  /// so far. Null when they did not come within [waitLimit]. [drives]: the
  /// request is its viewer's newest ([driving] says while it still is), so
  /// it may move the feed.
  Future<Uint8List?> _waitBytes(_Viewer v, int s, int from, int req, bool Function() driving) async {
    var deadline = DateTime.now().add(waitLimit);
    try {
      while (true) {
        final whole = _slices[s];
        if (whole != null) return from == 0 ? whole : Uint8List.sublistView(whole, from);
        final pl = _pull;
        if (pl != null && pl.pos ~/ slice == s && pl.start <= s * slice) {
          final part = pl.partFrom(from);
          if (part != null) return part;
        }
        if (_disposed || DateTime.now().isAfter(deadline)) return null;
        if (!_pinned(s) && driving() && _held(v)) {
          // Too far past its partner: waits for it, asking nothing.
          _unblock(s, req);
          deadline = DateTime.now().add(waitLimit);
          await _moved.future.timeout(const Duration(seconds: 2), onTimeout: () {});
          continue;
        }
        if (driving()) {
          _blocked.putIfAbsent(s, () => DateTime.now().microsecondsSinceEpoch);
          _blockedBy.putIfAbsent(s, () => {}).add(req);
          v.blocking = (s, req);
          // A pull nobody waits on gives way at once; one serving another
          // blocked viewer hands over at its next slice boundary.
          final at = pl == null ? -1 : pl.pos ~/ slice;
          if (pl != null && at != s && !_blocked.containsKey(at)) _endPull(pl);
          _wake();
        } else {
          _unblock(s, req);
        }
        final c = Completer<void>();
        _waiters.putIfAbsent(s, () => []).add(c);
        await c.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      }
    } finally {
      _unblock(s, req);
    }
  }

  // [req] no longer waits on slice [s]; the slice stops counting as
  // blocked once nobody driving does.
  void _unblock(int s, int req) {
    final by = _blockedBy[s];
    if (by == null || !by.remove(req)) return;
    if (by.isEmpty) {
      _blockedBy.remove(s);
      _blocked.remove(s);
      _wake();
    }
  }

  // ---------------------------------------------------------------- viewers

  /// Waits for the size (the feed's first connect), up to [waitLimit].
  @override
  Future<bool> ready() async {
    if (size > 0) return true;
    await _ready.future.timeout(waitLimit, onTimeout: () {});
    return size > 0 && !_disposed;
  }

  /// Streams [start]..[end] to [viewer]. Cancelling the subscription (the
  /// viewer went away) ends it; a slice that never arrives ends it with an
  /// error after [waitLimit]; the buffer's [dispose] with [RelayEnded].
  Stream<Uint8List> read(String viewer, int start, int end, {void Function(int n)? onSent}) async* {
    final v = _viewers.putIfAbsent(viewer, () => _Viewer(viewer));
    final tail = start >= size - pin;
    final me = ++_reqSeq;
    if (!tail) {
      // A seek: the request it supersedes stops holding the feed at once.
      final was = v.blocking;
      if (was != null) _unblock(was.$1, was.$2);
      v.blocking = null;
      v.newest = me;
      v.pos = start;
    }
    v.open++;
    v.lastActive = DateTime.now();
    _wake();
    _wakeHeld();
    try {
      var off = start;
      while (off <= end) {
        final s = off ~/ slice;
        final data = await _waitBytes(v, s, off - s * slice, me, () => tail || v.newest == me);
        if (_disposed) throw const RelayEnded();
        if (data == null) throw StateError('relay: bytes at $off did not arrive');
        final n = min(data.length, end - off + 1);
        if (n <= 0) continue;
        yield n == data.length ? data : Uint8List.sublistView(data, 0, n);
        bytesToViewers += n;
        onSent?.call(n);
        off += n;
        v.lastActive = DateTime.now();
        if (!tail && v.newest == me) v.pos = off;
        _wake();
        _wakeHeld();
      }
    } finally {
      v.open--;
      v.lastActive = DateTime.now();
      _wakeHeld();
    }
  }
}
