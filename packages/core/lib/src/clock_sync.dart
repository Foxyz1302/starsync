/// Estimates how far the server's clock is from ours (NTP style).
///
/// Each ping/pong round trip gives one sample: the client sent at `t0`, the
/// server stamped `s`, the reply arrived at `t3` (client clock). Assuming the
/// two legs take equally long, `offset = s - (t0 + t3) / 2` with an error of
/// at most `rtt / 2`. The sample with the smallest round trip among the last
/// [window] is the most trustworthy, so that one is used.
class ClockSync {
  final int window;
  final List<({int rttMs, double offsetMs})> _samples = [];

  ClockSync({this.window = 16});

  /// Server clock minus local clock, in ms; 0 until the first sample.
  double get offsetMs {
    if (_samples.isEmpty) return 0;
    var best = _samples.first;
    for (final s in _samples) {
      if (s.rttMs < best.rttMs) best = s;
    }
    return best.offsetMs;
  }

  /// Round trip of the sample in use, null without samples.
  int? get rttMs {
    if (_samples.isEmpty) return null;
    return _samples.map((s) => s.rttMs).reduce((a, b) => a < b ? a : b);
  }

  bool get hasSample => _samples.isNotEmpty;

  /// [sentMs] and [receivedMs] are local epoch ms, [serverMs] the server's.
  void add({required int sentMs, required int serverMs, required int receivedMs}) {
    final rtt = receivedMs - sentMs;
    if (rtt < 0) return;
    _samples.add((rttMs: rtt, offsetMs: serverMs - (sentMs + receivedMs) / 2));
    if (_samples.length > window) _samples.removeAt(0);
  }

  void reset() => _samples.clear();

  /// The server's clock now, given the local clock [local].
  DateTime serverNow(DateTime local) =>
      local.add(Duration(microseconds: (offsetMs * 1000).round()));
}
