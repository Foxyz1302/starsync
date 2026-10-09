import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:sync_relay_core/core.dart';

import 'relay_buffer.dart';

final _log = createLogger('relay');

class _PiecePull {
  final int id, piece;
  final buf = BytesBuilder(copy: false);
  _PiecePull(this.id, this.piece);
}

class _Viewer {
  int pos = -1; // its newest requested segment
  int? waiting; // that segment, while it is missing
  int waitSince = 0;
  int open = 0;
  DateTime lastActive = DateTime.now();
}

/// The server side of a pieces track (see relay_pieces.dart): pieces by
/// index in memory, each filled by one whole pull, served whole (a Range
/// inside a piece is the route's job).
///
/// - Fill order: a viewer blocked on a piece (oldest wait first), the init
///   and key pieces the viewers' segments use, then segments ahead of each
///   viewer, slowest first, up to [ahead] bytes.
/// - A viewer's position is its newest requested segment; a superseded
///   request still gets its piece but no longer drives the feed, and a pull
///   nobody waits on gives way to a blocked viewer at once.
/// - Kept: every init and key piece, plus segments by distance from the
///   viewers ([ahead] + [back] bytes; behind a viewer costs 4x), never LRU.
///   Sizes before a piece arrives are estimated from the bytes per second
///   of the ones that did, else [rate].
class PieceBuffer implements TrackBuffer {
  @override
  int ahead, back;
  final Duration waitLimit;
  /// Bytes per second assumed before any segment has arrived.
  double rate;
  final int Function() _newId;
  PieceBuffer({
    this.ahead = RelayConstants.relayAheadBytes,
    this.back = RelayConstants.relayBackBytes,
    this.waitLimit = const Duration(seconds: RelayConstants.relayWaitSecs),
    this.rate = 500000,
    int Function()? nextId,
  }) : _newId = nextId ?? _counter();

  static int Function() _counter() {
    var n = 0;
    return () => ++n;
  }

  RelayFeed? _feed;
  /// The track's shape, once the feed has connected.
  RelayPieceList? list;
  String? _playlist;
  final _pieces = <int, Uint8List>{};
  final _sizes = <int, int>{}; // known sizes, kept after eviction
  var _knownSecs = 0.0;
  var _knownBytes = 0;
  final _waiters = <int, List<Completer<void>>>{};
  final _aux = <int, int>{}; // init/key piece a request waits on -> since (us)
  final _viewers = <String, _Viewer>{};
  _PiecePull? _pull;
  DateTime? _retryAt;
  var _disposed = false;
  Completer<void> _kick = Completer();
  final Completer<void> _ready = Completer();

  @override
  int bytesFromFeed = 0, bytesToViewers = 0;

  @override
  bool get live => _feed != null && list != null;

  @override
  int get cachedBytes => _pieces.values.fold(0, (a, p) => a + p.length);

  /// The media playlist viewers open (see [RelayPieceList.playlist]).
  String? get playlist => _playlist ??= list?.playlist();

  /// Attaches a (re)connected feed for a track of [list]'s shape. A
  /// different shape means different content: the buffer starts over.
  void attach(RelayFeed feed, RelayPieceList list) {
    if (_disposed) return;
    final old = this.list;
    if (old != null && !old.sameShape(list)) {
      _log.info('relay source changed pieces ${old.length} -> ${list.length}, dropping buffer');
      _pieces.clear();
      _sizes.clear();
      _knownSecs = 0;
      _knownBytes = 0;
      _viewers.clear();
      _aux.clear();
    }
    this.list = list;
    _playlist = null;
    _feed = feed;
    _pull = null;
    if (!_ready.isCompleted) _ready.complete();
    if (_fillerRunning) {
      _wake();
    } else {
      unawaited(_filler());
    }
  }

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
    _pieces.clear();
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
    pl.buf.add(data);
  }

  @override
  void feedEnd(int id) {
    final pl = _pull;
    if (pl == null || pl.id != id || _disposed) return;
    _pull = null;
    final data = pl.buf.takeBytes();
    final i = pl.piece;
    _pieces[i] = data;
    final p = list!.pieces[i];
    if (p.isSegment && !_sizes.containsKey(i)) {
      _knownSecs += p.d;
      _knownBytes += data.length;
    }
    _sizes[i] = data.length;
    for (final c in _waiters.remove(i) ?? const <Completer<void>>[]) {
      c.complete();
    }
    _wake();
  }

  @override
  void feedFail(int id, String reason) {
    if (_pull?.id != id) return;
    _log.warning('relay piece pull $id failed: $reason');
    _pull = null;
    _retryAt = DateTime.now().add(const Duration(seconds: 1));
    _wake();
  }

  // ------------------------------------------------------------- scheduling

  double _est(int i) {
    final known = _sizes[i];
    if (known != null) return known.toDouble();
    final p = list!.pieces[i];
    if (!p.isSegment) return 0;
    return (_knownSecs > 0 ? _knownBytes / _knownSecs : rate) * p.d;
  }

  Iterable<_Viewer> get _active {
    final now = DateTime.now();
    return _viewers.values.where(
        (v) => v.pos >= 0 && (v.open > 0 || now.difference(v.lastActive) < const Duration(seconds: 60)));
  }

  /// Estimated byte offset of every piece (prefix sums), for distances.
  List<double> _offsets() {
    final l = list!;
    final out = List<double>.filled(l.length + 1, 0);
    for (var i = 0; i < l.length; i++) {
      out[i + 1] = out[i] + _est(i);
    }
    return out;
  }

  double _distance(int i, List<double> off, List<_Viewer> active) {
    var d = double.infinity;
    for (final v in active) {
      d = min(d, i >= v.pos ? off[i] - off[v.pos] : (off[v.pos] - off[i]) * 4);
    }
    return d;
  }

  bool _waited(int i) => _aux.containsKey(i) || _viewers.values.any((v) => v.waiting == i);

  /// Cached segments past the budget, farthest first; returns the
  /// distance of the farthest segment kept (a fill farther than it would
  /// only be evicted again).
  double _evict(List<double> off, List<_Viewer> active) {
    final l = list!;
    final cached = [for (final i in _pieces.keys) if (l.pieces[i].isSegment) i];
    var total = cached.fold(0, (a, i) => a + _pieces[i]!.length);
    cached.sort((a, b) => _distance(b, off, active).compareTo(_distance(a, off, active)));
    final limit = ahead + back;
    var k = 0;
    for (; k < cached.length && total > limit; k++) {
      final i = cached[k];
      if (_waited(i)) continue;
      total -= _pieces.remove(i)!.length;
    }
    _cachedSegBytes = total;
    return k < cached.length ? _distance(cached[k], off, active) : double.infinity;
  }

  var _cachedSegBytes = 0;

  int? _nextMissing() {
    final l = list!;
    final active = _active.toList()..sort((a, b) => a.pos.compareTo(b.pos));
    final off = _offsets();
    final keep = _evict(off, active);
    final blocked = <(int, int)>[
      for (final v in _viewers.values)
        if (v.waiting != null && !_pieces.containsKey(v.waiting)) (v.waiting!, v.waitSince),
      for (final e in _aux.entries)
        if (!_pieces.containsKey(e.key)) (e.key, e.value),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (blocked.isNotEmpty) return blocked.first.$1;
    if (active.isEmpty) return null; // nobody watches: fetch nothing
    for (final v in active) {
      var budget = 0.0;
      for (var i = v.pos; i < l.length; i++) {
        final p = l.pieces[i];
        if (!p.isSegment) continue;
        for (final dep in [p.map, p.key]) {
          if (dep != null && !_pieces.containsKey(dep)) return dep;
        }
        if (!_pieces.containsKey(i)) {
          final room = _cachedSegBytes + _est(i) <= ahead + back;
          if (i == v.pos || room || _distance(i, off, active) < keep) return i;
          break;
        }
        budget += _est(i);
        if (budget > ahead) break;
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
        final retry = _retryAt;
        if (feed == null || _pull != null || list == null) {
          await _sleep();
          continue;
        }
        if (retry != null && DateTime.now().isBefore(retry)) {
          await _sleep(retry.difference(DateTime.now()));
          continue;
        }
        _retryAt = null;
        final i = _nextMissing();
        if (i == null) {
          await _sleep();
          continue;
        }
        final pl = _pull = _PiecePull(_newId(), i);
        feed.pullPiece(pl.id, i);
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

  // ---------------------------------------------------------------- viewers

  @override
  Future<bool> ready() async {
    if (list != null) return true;
    await _ready.future.timeout(waitLimit, onTimeout: () {});
    return list != null && !_disposed;
  }

  /// [viewer] opened the playlist: a new viewer starts at the first
  /// segment, so its first pieces are fetched before it asks.
  void opened(String viewer) {
    final l = list;
    if (l == null) return;
    final v = _viewers.putIfAbsent(viewer, _Viewer.new);
    if (v.pos < 0) v.pos = l.pieces.indexWhere((p) => p.isSegment);
    v.lastActive = DateTime.now();
    _wake();
  }

  /// Piece [index] for [viewer], once it is in; null when it does not
  /// arrive within [waitLimit] (or the buffer is gone).
  Future<Uint8List?> piece(String viewer, int index) async {
    final l = list;
    if (l == null || index < 0 || index >= l.length) return null;
    final v = _viewers.putIfAbsent(viewer, _Viewer.new);
    final segment = l.pieces[index].isSegment;
    final now = DateTime.now().microsecondsSinceEpoch;
    v.open++;
    v.lastActive = DateTime.now();
    if (segment) {
      v.pos = index;
      v.waiting = _pieces.containsKey(index) ? null : index;
      v.waitSince = now;
    } else if (!_pieces.containsKey(index)) {
      _aux.putIfAbsent(index, () => now);
    }
    // A pull nobody waits on gives way to this one at once.
    final pl = _pull;
    if (!_pieces.containsKey(index) && pl != null && pl.piece != index && !_waited(pl.piece)) {
      _pull = null;
      _feed?.cancel(pl.id);
    }
    _wake();
    try {
      final deadline = DateTime.now().add(waitLimit);
      while (!_pieces.containsKey(index)) {
        if (_disposed || DateTime.now().isAfter(deadline)) return null;
        final c = Completer<void>();
        _waiters.putIfAbsent(index, () => []).add(c);
        await c.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      }
      return _pieces[index];
    } finally {
      v.open--;
      v.lastActive = DateTime.now();
      if (segment && v.waiting == index) v.waiting = null;
      if (!segment) _aux.remove(index);
    }
  }
}
