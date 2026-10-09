import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'constants.dart';
import 'logging.dart';

// The relay channel: a member's machine (the source) serves the current
// media's bytes to the server, which buffers them for every viewer (`/r/...`).
// The source dials out (works behind NAT/CGNAT) on its own WebSocket, so
// video bytes never queue behind `/sync` messages.
//
//   source -> server  {"t":"info","size":N}               first frame
//                     binary [u32 BE pull id][bytes]      in order per pull
//                     {"t":"end","id":1}                  pull complete
//                     {"t":"fail","id":1,"reason":"..."}  cannot read
//   server -> source  {"t":"pull","id":1,"start":0,"end":N}  bytes start..end
//                     {"t":"ack","id":1,"n":65536}         n bytes arrived
//                     {"t":"cancel","id":1}               stop this pull
//
// Flow control is on the source: one adaptive in-flight budget per
// connection (see [RelayWindow]); a cancelled pull's unacked bytes are
// written off.

final _log = createLogger('relay');

/// The `<name>` segment of a `/r/` URL: the media name URL-encoded, its
/// slashes made `_` first (a page title can hold a URL, and an encoded
/// slash still splits the path). The server ignores the segment.
String relayUrlName(String name) => Uri.encodeComponent(name.replaceAll(RegExp(r'[/\\]'), '_'));

/// Binary relay frame: 4-byte big-endian pull id, then payload.
Uint8List encodeRelayFrame(int id, List<int> payload) {
  final out = Uint8List(4 + payload.length);
  ByteData.sublistView(out).setUint32(0, id);
  out.setRange(4, out.length, payload);
  return out;
}

(int id, Uint8List payload) decodeRelayFrame(Uint8List frame) {
  if (frame.length < 4) throw const FormatException('short relay frame');
  return (ByteData.sublistView(frame, 0, 4).getUint32(0), Uint8List.sublistView(frame, 4));
}

/// Where a source reads the media from.
abstract interface class RelayBytes {
  /// Total length in bytes.
  Future<int> size();

  /// Bytes [start]..[end] (inclusive), in order. Cancelling the
  /// subscription stops reading.
  Stream<List<int>> read(int start, int end);

  Future<void> close();
}

class FileRelayBytes implements RelayBytes {
  final File file;
  FileRelayBytes(this.file);

  @override
  Future<int> size() => file.length();

  @override
  Stream<List<int>> read(int start, int end) => file.openRead(start, end + 1);

  @override
  Future<void> close() async {}
}

/// A non-2xx answer from an [HttpRelayBytes] upstream.
class UpstreamHttpException extends HttpException {
  final int status;
  UpstreamHttpException(this.status, Uri url) : super('upstream HTTP $status', uri: url);
}

/// An HTTP(S) resource with Range support, e.g. a link or a Jellyfin
/// stream; [headers] (auth) never leave this machine.
class HttpRelayBytes implements RelayBytes {
  final Uri url;
  final Map<String, String> headers;
  final HttpClient _client;
  int? _size;
  HttpRelayBytes(this.url, {this.headers = const {}, HttpClient? client})
      : _client = client ?? HttpClient();

  Future<HttpClientResponse> _get(String range) async {
    final req = await _client.getUrl(url).timeout(const Duration(seconds: 20));
    headers.forEach(req.headers.set);
    req.headers
      ..set(HttpHeaders.rangeHeader, range)
      ..set(HttpHeaders.acceptEncodingHeader, 'identity');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200 && res.statusCode != 206) {
      await res.drain<void>().catchError((_) {});
      throw UpstreamHttpException(res.statusCode, url);
    }
    return res;
  }

  @override
  Future<int> size() async {
    if (_size != null) return _size!;
    final res = await _get('bytes=0-0');
    await res.drain<void>().catchError((_) {});
    // A web page (YouTube and co.) only a player can resolve, not a file.
    final type = res.headers.contentType?.mimeType ?? '';
    if (type.startsWith('text/')) throw HttpException('not a video file ($type)', uri: url);
    // `bytes 0-0/12345`; a server ignoring Range answers 200 with the length.
    final total = res.headers.value(HttpHeaders.contentRangeHeader)?.split('/').last;
    final n = int.tryParse(total ?? '') ?? (res.statusCode == 200 ? res.contentLength : -1);
    if (n <= 0) throw HttpException('upstream size unknown', uri: url);
    return _size = n;
  }

  @override
  Stream<List<int>> read(int start, int end) async* {
    final res = await _get('bytes=$start-$end');
    if (res.statusCode == 200 && start > 0) {
      throw HttpException('upstream ignores Range', uri: url);
    }
    yield* res;
  }

  @override
  Future<void> close() async => _client.close(force: true);
}

/// The per-connection in-flight budget: 2 x (delivery rate x min RTT),
/// clamped to [RelayConstants.relayMinWindowBytes]..[RelayConstants.relayMaxWindowBytes].
/// The rate is the max of the last 2 s of samples, so a pause or a burst of
/// cancels does not collapse it (BBR's bandwidth max-filter); spike results
/// in docs/ARCHITECTURE.md ("Relay").
class RelayWindow {
  var window = RelayConstants.relayMinWindowBytes;
  var inflight = 0;
  var minRttUs = 1 << 40;
  var _sent = 0, _acked = 0, _writtenOff = 0;
  final _sw = Stopwatch()..start();
  final _sendTimes = Queue<(int, int)>(); // (cumulative sent, time us)
  final _acks = Queue<(int, int)>(); // (time us, cumulative acked)
  final _rates = Queue<(int, double)>(); // (time us, bytes/s)
  Completer<void>? _room;

  bool get full => inflight >= window;

  void sent(int n) {
    _sent += n;
    inflight += n;
    _sendTimes.add((_sent, _sw.elapsedMicroseconds));
  }

  void acked(int n) {
    inflight -= n;
    _acked += n;
    final now = _sw.elapsedMicroseconds;
    while (_sendTimes.isNotEmpty && _sendTimes.first.$1 <= _acked + _writtenOff) {
      minRttUs = min(minRttUs, now - _sendTimes.removeFirst().$2);
    }
    _acks.add((now, _acked));
    while (_acks.length > 2 && now - _acks.first.$1 > max(2 * minRttUs, 200000)) {
      _acks.removeFirst();
    }
    if (_acks.length >= 2 && minRttUs < (1 << 40)) {
      final dt = (now - _acks.first.$1) / 1e6;
      if (dt > 0.02) {
        _rates.add((now, (_acked - _acks.first.$2) / dt));
        while (now - _rates.first.$1 > 2000000) {
          _rates.removeFirst();
        }
        final rate = _rates.map((r) => r.$2).reduce(max);
        window = (2 * rate * minRttUs / 1e6)
            .clamp(RelayConstants.relayMinWindowBytes, RelayConstants.relayMaxWindowBytes)
            .toInt();
      }
    }
    _wake();
  }

  /// Bytes of a cancelled pull that will never be acked.
  void writeOff(int n) {
    inflight -= n;
    _writtenOff += n;
    _wake();
  }

  void _wake() {
    final r = _room;
    _room = null;
    r?.complete();
  }

  Future<void> room() async {
    while (full) {
      await (_room ??= Completer<void>()).future;
    }
  }
}

class _Pull {
  final int id;
  var sent = 0, acked = 0;
  var cancelled = false, finished = false;
  StreamIterator<List<int>>? it;
  _Pull(this.id);
  bool get settled => cancelled || (finished && acked >= sent);
}

/// Close code the server uses for "you are not (or no longer) the source of
/// the current media": the source stops instead of reconnecting.
const relayCloseNotSource = 4001;

/// Serves [bytes] on the relay channel at [url] (`ws://host/r/<sid>/<token>/source`)
/// until [close]. Reconnects with backoff when the channel drops; stops for
/// good when the server closes it with [relayCloseNotSource].
class RelaySource {
  final Uri url;
  final RelayBytes bytes;
  final Duration Function(int attempt) backoff;
  RelaySource(this.url, this.bytes, {Duration Function(int attempt)? backoff})
      : backoff = backoff ?? ((a) => Duration(milliseconds: min(8000, 500 * (1 << min(a, 4)))));

  final window = RelayWindow();
  final _pulls = <int, _Pull>{};
  WebSocket? _ws;
  var _closed = false;
  final _done = Completer<void>();

  /// Completes when the source stopped for good (closed or refused).
  Future<void> get done => _done.future;

  /// Bytes sent to the server, for stats.
  int bytesSent = 0;

  Future<void> start() async {
    final size = await bytes.size();
    unawaited(_loop(size));
  }

  Future<void> _loop(int size) async {
    var attempt = 0;
    while (!_closed) {
      try {
        final ws = await WebSocket.connect(url.toString()).timeout(const Duration(seconds: 15));
        if (_closed) {
          await ws.close();
          break;
        }
        _ws = ws;
        attempt = 0;
        ws.add(jsonEncode({'t': 'info', 'size': size}));
        await for (final m in ws) {
          if (m is String) _onText(ws, m);
        }
        if (ws.closeCode == relayCloseNotSource) {
          _log.info('relay channel: not the source any more, stopping');
          _closed = true;
        }
      } catch (e) {
        _log.fine('relay channel: $e');
      }
      _ws = null;
      _abandonAll();
      if (_closed) break;
      await Future<void>.delayed(backoff(attempt++));
    }
    _abandonAll();
    await bytes.close();
    if (!_done.isCompleted) _done.complete();
  }

  void _onText(WebSocket ws, String text) {
    final Map j;
    try {
      j = jsonDecode(text) as Map;
    } catch (_) {
      return;
    }
    final id = j['id'];
    if (id is! int) return;
    switch (j['t']) {
      case 'pull':
        final start = j['start'], end = j['end'];
        if (start is! int || end is! int || start < 0 || end < start) return;
        final p = _Pull(id);
        _pulls[id] = p;
        unawaited(_serve(ws, p, start, end));
      case 'ack':
        final p = _pulls[id];
        final n = j['n'];
        if (p == null || p.cancelled || n is! int) return;
        p.acked += n;
        window.acked(n);
        if (p.settled) _pulls.remove(id);
      case 'cancel':
        final p = _pulls.remove(id);
        if (p == null) return;
        _cancel(p);
    }
  }

  void _cancel(_Pull p) {
    if (p.cancelled) return;
    p.cancelled = true;
    window.writeOff(p.sent - p.acked);
    p.acked = p.sent;
    unawaited(p.it?.cancel());
  }

  void _abandonAll() {
    for (final p in _pulls.values.toList()) {
      _cancel(p);
    }
    _pulls.clear();
  }

  Future<void> _serve(WebSocket ws, _Pull p, int start, int end) async {
    final it = p.it = StreamIterator(bytes.read(start, end));
    final pending = BytesBuilder(copy: false);
    const frame = RelayConstants.relayFrameBytes;
    try {
      var more = true;
      while (!p.cancelled) {
        while (more && pending.length < frame) {
          more = await it.moveNext();
          if (more) pending.add(it.current);
        }
        if (pending.isEmpty) break;
        await window.room();
        // Check and send in one synchronous step: a cancel that lands
        // during an await must not be followed by a sent frame.
        if (p.cancelled) break;
        final all = pending.takeBytes();
        final n = min(frame, all.length);
        ws.add(encodeRelayFrame(p.id, Uint8List.sublistView(all, 0, n)));
        if (n < all.length) pending.add(Uint8List.sublistView(all, n));
        p.sent += n;
        bytesSent += n;
        window.sent(n);
      }
      if (!p.cancelled) ws.add(jsonEncode({'t': 'end', 'id': p.id}));
    } catch (e) {
      if (!p.cancelled) {
        _log.warning('relay read ${p.id} failed: $e');
        try {
          ws.add(jsonEncode({'t': 'fail', 'id': p.id, 'reason': '$e'}));
        } catch (_) {}
      }
    } finally {
      p.finished = true;
      if (p.settled) _pulls.remove(p.id);
      await it.cancel();
    }
  }

  /// Stops serving; [done] completes once the loop has wound down (a
  /// pending reconnect delay runs out first).
  Future<void> close() async {
    _closed = true;
    await _ws?.close();
  }
}
