import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';

import 'relay_stats.dart';

final _log = createLogger('relay');

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
  final buf = BytesBuilder(copy: false);
  _Pull(this.id, this.start, this.end) : pos = start;
}

class _Viewer {
  int pos = 0;
  int open = 0; // requests in flight
  int newest = 0; // sequence of its newest request
  DateTime lastActive = DateTime.now();
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
///   first (oldest wait first); then read-ahead.
/// - Only a viewer's newest request moves its position or asks the feed
///   for anything; older ones still get bytes once they are buffered.
/// Everything lives in memory: dropping the buffer is the cleanup.
class RelayBuffer implements TrackBuffer {
  /// Set by the relay when a media's tracks share the budget.
  @override
  int ahead, back;
  final int pin;
  final Duration waitLimit;
  /// Pull ids; the tracks of one media share one sequence (one channel).
  final int Function() _newId;
  RelayBuffer({
    this.ahead = RelayConstants.relayAheadBytes,
    this.back = RelayConstants.relayBackBytes,
    this.pin = RelayConstants.relayPinBytes,
    this.waitLimit = const Duration(seconds: RelayConstants.relayWaitSecs),
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
  final _viewers = <String, _Viewer>{};
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
  }

  void _wake() {
    if (!_kick.isCompleted) _kick.complete();
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
      pl.buf.add(Uint8List.sublistView(data, off, off + take));
      off += take;
      pl.pos += take;
      if (pl.pos == _sliceEnd(s) + 1) {
        _slices[s] = pl.buf.takeBytes();
        for (final c in _waiters.remove(s) ?? const <Completer<void>>[]) {
          c.complete();
        }
        if (_shouldStop(pl, s)) {
          _endPull(pl);
          return;
        }
      }
    }
  }

  @override
  void feedEnd(int id) {
    final pl = _pull;
    if (pl != null && pl.id == id) {
      _pull = null;
      _wake();
    }
  }

  @override
  void feedFail(int id, String reason) {
    if (_pull?.id != id) return;
    _log.warning('relay pull $id failed: $reason');
    feedEnd(id);
  }

  // ------------------------------------------------------------- scheduling

  bool _shouldStop(_Pull pl, int done) {
    final next = done + 1;
    if (next >= _nSlices || next * slice > pl.end) return false; // ends naturally
    // Someone is blocked elsewhere: hand the feed over at this boundary.
    if (_blocked.keys.any((w) => w != next && w != next + 1 && !_slices.containsKey(w))) {
      return true;
    }
    if (_slices.containsKey(next)) return true;
    return !_wanted(next);
  }

  void _endPull(_Pull pl) {
    if (!identical(_pull, pl)) return;
    _pull = null;
    if (pl.pos <= pl.end) _feed?.cancel(pl.id);
    _wake();
  }

  Iterable<_Viewer> get _active {
    final now = DateTime.now();
    return _viewers.values
        .where((v) => v.open > 0 || now.difference(v.lastActive) < const Duration(seconds: 60));
  }

  bool _pinned(int s) => s * slice < pin || s * slice >= size - pin;

  bool _wanted(int s) {
    if (_pinned(s)) return true;
    final pos = _active.map((v) => v.pos).toList();
    if (pos.isEmpty) return false;
    final off = s * slice;
    return off >= pos.reduce(min) - back && off <= pos.reduce(max) + ahead;
  }

  int _distance(int s) {
    if (_pinned(s)) return -1;
    final off = s * slice;
    var d = 1 << 62;
    for (final v in _active) {
      // Behind a viewer costs more than ahead (it was already watched).
      d = min(d, off >= v.pos ? off - v.pos : (v.pos - off) * 4);
    }
    return d;
  }

  void _evict() {
    final limit = ahead + back + 2 * pin;
    var total = _slices.length * slice;
    if (total <= limit) return;
    final order = _slices.keys.toList()..sort((a, b) => _distance(b).compareTo(_distance(a)));
    for (final s in order) {
      if (total <= limit || _distance(s) < 0) break;
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
        if (!_slices.containsKey(s)) return s;
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

  Future<void> _sleep() async {
    _kick = Completer();
    // Also wake periodically: viewers age out of [_active].
    await _kick.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  Future<bool> _waitSlice(int s, bool drives) async {
    final deadline = DateTime.now().add(waitLimit);
    while (!_slices.containsKey(s)) {
      if (_disposed || DateTime.now().isAfter(deadline)) return false;
      if (drives) {
        _blocked.putIfAbsent(s, () => DateTime.now().microsecondsSinceEpoch);
        // A pull nobody waits on gives way at once; one serving another
        // blocked viewer hands over at its next slice boundary.
        final pl = _pull;
        final at = pl == null ? -1 : pl.pos ~/ slice;
        if (pl != null && at != s && !_blocked.containsKey(at)) _endPull(pl);
        _wake();
      }
      final c = Completer<void>();
      _waiters.putIfAbsent(s, () => []).add(c);
      await c.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    _blocked.remove(s);
    return true;
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
  /// error after [waitLimit].
  Stream<Uint8List> read(String viewer, int start, int end, {void Function(int n)? onSent}) async* {
    final v = _viewers.putIfAbsent(viewer, _Viewer.new);
    final tail = start >= size - pin;
    final me = ++_reqSeq;
    if (!tail) {
      v.newest = me;
      v.pos = start;
    }
    v.open++;
    v.lastActive = DateTime.now();
    _wake();
    try {
      var off = start;
      while (off <= end) {
        final s = off ~/ slice;
        if (!await _waitSlice(s, tail || v.newest == me)) {
          throw StateError('relay: bytes at $off did not arrive');
        }
        final data = _slices[s];
        if (data == null) continue; // evicted between wake and read
        final from = off - s * slice, to = min(data.length, end - s * slice + 1);
        yield Uint8List.sublistView(data, from, to);
        bytesToViewers += to - from;
        onSent?.call(to - from);
        off += to - from;
        v.lastActive = DateTime.now();
        if (!tail && v.newest == me) v.pos = off;
        _wake();
      }
    } finally {
      v.open--;
      v.lastActive = DateTime.now();
    }
  }
}
