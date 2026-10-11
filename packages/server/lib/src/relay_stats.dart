/// How fast bytes move through the server, coarse enough for `state`
/// (sent every second): the relay source's delivery rate and each
/// member's read rate.
library;

/// [bytesPerSec] kept to two significant digits (under 10 kB/s: 0), so
/// the state does not change with every byte.
int roundRate(double bytesPerSec) {
  if (!bytesPerSec.isFinite || bytesPerSec < 10000) return 0;
  var unit = 1;
  while (bytesPerSec / unit >= 100) {
    unit *= 10;
  }
  return (bytesPerSec / unit).round() * unit;
}

/// Time a relay's feed had at least one pull in flight. The tracks of a
/// media share one (they share the source's uplink), so its time counts
/// once however many tracks pull at the same moment.
class FeedClock {
  final Stopwatch _watch;
  var _open = 0;
  FeedClock([Stopwatch? watch]) : _watch = watch ?? Stopwatch();

  void start() {
    if (_open++ == 0) _watch.start();
  }

  void stop() {
    if (_open == 0) return;
    if (--_open == 0) _watch.stop();
  }

  Duration get busy => _watch.elapsed;
}

/// The source's delivery rate: bytes over the time a pull was in flight,
/// so a buffer that is full (the source idles) does not read as a slow
/// source. Smoothed over about [window] of busy time; null until
/// [settle] of busy time has been measured.
class SourceRate {
  final Duration window;
  final Duration settle;
  SourceRate({this.window = const Duration(seconds: 4), this.settle = const Duration(seconds: 2)});

  int _bytes = 0;
  Duration _busy = Duration.zero;
  Duration _measured = Duration.zero;
  double? _rate;

  /// Takes the feed's totals now: all bytes so far, all busy time so far.
  /// Gaps under a quarter second of busy time wait for the next sample
  /// (a pull's first-byte wait would dominate them).
  void sample(int bytes, Duration busy) {
    final db = bytes - _bytes;
    final dt = busy - _busy;
    if (db < 0 || dt < Duration.zero) {
      // Totals went back (a new feed): start over.
      _bytes = bytes;
      _busy = busy;
      return;
    }
    if (dt < const Duration(milliseconds: 250)) return;
    _bytes = bytes;
    _busy = busy;
    final secs = dt.inMicroseconds / 1e6;
    final now = db / secs;
    final r = _rate;
    final w = (secs / (window.inMicroseconds / 1e6)).clamp(0.0, 1.0);
    _rate = r == null ? now : r + (now - r) * w;
    _measured += dt;
  }

  /// Bytes per second, rounded ([roundRate]); 0 while not settled.
  int get rate => _measured < settle || _rate == null ? 0 : roundRate(_rate!);
}

/// Each member's read rate from the server: the change of its
/// `bytesServed` over the last [window].
class ReadRates {
  final Duration window;
  ReadRates({this.window = const Duration(seconds: 5)});

  final _seen = <String, List<(DateTime, int)>>{};

  /// Records [served] totals by token at [now]; returns each token's rate
  /// (rounded). Tokens not in [served] are forgotten.
  Map<String, int> sample(DateTime now, Map<String, int> served) {
    _seen.removeWhere((t, _) => !served.containsKey(t));
    final out = <String, int>{};
    for (final e in served.entries) {
      final list = _seen.putIfAbsent(e.key, () => []);
      list.add((now, e.value));
      while (list.length > 1 && now.difference(list[1].$1) >= window) {
        list.removeAt(0);
      }
      final first = list.first;
      final secs = now.difference(first.$1).inMicroseconds / 1e6;
      out[e.key] = secs <= 0 ? 0 : roundRate((e.value - first.$2) / secs);
    }
    return out;
  }
}
