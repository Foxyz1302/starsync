import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'constants.dart';
import 'logging.dart';
import 'protocol.dart';
import 'relay_pieces.dart';

// The relay channel: a member's machine (the source) serves the current
// media's bytes to the server, which buffers them for every viewer (`/r/...`).
// The source dials out (works behind NAT/CGNAT) on its own WebSocket, so
// video bytes never queue behind `/sync` messages. A media is one track (a
// file) or several (a page's separate video and audio); a track is a
// byte stream or pieces (a segmented playlist, see relay_pieces.dart).
//
//   source -> server  {"t":"info","size":N}               first frame, one track
//                     {"t":"info","tracks":[{"kind":"video","size":N},...]}
//                     {"t":"info","tracks":[{"kind":"video","as":"pieces",
//                                            "pieces":[{"init":true},{"d":6.0,"map":0},...]}]}
//                     binary [u32 BE pull id][bytes]      in order per pull
//                     {"t":"end","id":1}                  pull complete
//                     {"t":"fail","id":1,"reason":"..."}  cannot read
//   server -> source  {"t":"pull","id":1,"track":0,"start":0,"end":N}
//                                                         bytes start..end
//                     {"t":"pull","id":2,"track":0,"piece":17}  one piece, whole
//                     {"t":"ack","id":1,"n":65536}         n bytes arrived
//                     {"t":"cancel","id":1}               stop this pull
//
// Pull ids are unique across tracks. Flow control is on the source: one
// adaptive in-flight budget per connection (see [RelayWindow]), shared by
// the tracks; a cancelled pull's unacked bytes are written off.

final _log = createLogger('relay');
final _upstreamThrottle = LogThrottle(burst: 3);
final _readThrottle = LogThrottle(burst: 3);

/// The `<name>` segment of a `/r/` URL: the media name URL-encoded, its
/// slashes made `_` first (a page title can hold a URL, and an encoded
/// slash still splits the path). The server ignores the segment.
String relayUrlName(String name) => Uri.encodeComponent(name.replaceAll(RegExp(r'[/\\]'), '_'));

/// What a viewer opens for relayed media at [base]
/// (`http://<host>/r/<sid>/<token>/<mediaId>`): `<base>/<name>` for one
/// file; with [tracks], each track's URL (`<base>/<i>/<name>`, a pieces
/// track's playlist `<base>/<i>/<name>.m3u8`), several played together as
/// an mpv EDL (see [mpvEdl]).
String relayViewerUrl(String base, String name, {List<RelayTrackSpec> tracks = const []}) {
  final n = relayUrlName(name);
  if (tracks.isEmpty) return '$base/$n';
  final urls = [for (var i = 0; i < tracks.length; i++) '$base/$i/$n${tracks[i].pieces ? '.m3u8' : ''}'];
  return urls.length == 1 ? urls.single : mpvEdl(urls);
}

/// An mpv `edl://` URL playing [urls] as the streams of one file (a video
/// track and its audio track), each `%<byte length>%`-framed so `;` and
/// `,` inside a URL are safe.
String mpvEdl(List<String> urls) =>
    'edl://${urls.map((u) => '!no_clip;%${utf8.encode(u).length}%$u').join(';!new_stream;')}';

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

/// Logs an upstream answer that is not the media (status, what was
/// asked, the names of the headers sent), a few per host and status at a
/// time.
void logUpstreamRefusal(int status, Uri url, String what, Iterable<String> headerNames) {
  final pass = _upstreamThrottle.allow('${url.host} $status');
  if (pass == null) return;
  _log.warning('${pass}upstream $status for $what of ${logUrl(url)} (sent headers: ${headerNames.join(', ')})');
}

/// An HTTP(S) resource with Range support, e.g. a link or a Jellyfin
/// stream; [headers] (auth) never leave this machine. A read is one GET
/// per [chunkSize] bytes, back to back (see
/// [RelayConstants.relayUpstreamChunkBytes]).
class HttpRelayBytes implements RelayBytes {
  final Uri url;
  final Map<String, String> headers;
  final int chunkSize;
  final HttpClient _client;
  int? _size;
  HttpRelayBytes(this.url,
      {this.headers = const {}, this.chunkSize = RelayConstants.relayUpstreamChunkBytes, HttpClient? client})
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
      logUpstreamRefusal(res.statusCode, url, range, headers.keys);
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
    _log.info('upstream ${logUrl(url)}: ${res.statusCode} $type, $n bytes (headers: ${headers.keys.join(', ')})');
    return _size = n;
  }

  @override
  Stream<List<int>> read(int start, int end) async* {
    var pos = start;
    while (pos <= end) {
      final last = chunkSize > 0 ? min(end, pos + chunkSize - 1) : end;
      final res = await _get('bytes=$pos-$last');
      if (res.statusCode == 200) {
        if (pos > 0) {
          await res.drain<void>().catchError((_) {});
          throw HttpException('upstream ignores Range', uri: url);
        }
        // The whole file from 0: take what was asked in this one answer.
        await for (final c in res) {
          final take = min(c.length, end - pos + 1);
          yield take == c.length ? c : c.sublist(0, take);
          pos += take;
          if (pos > end) return;
        }
        if (pos <= end) throw HttpException('upstream ended early', uri: url);
        return;
      }
      await for (final c in res) {
        final take = min(c.length, last - pos + 1);
        if (take <= 0) break;
        yield take == c.length ? c : c.sublist(0, take);
        pos += take;
      }
      if (pos <= last) throw HttpException('upstream ended early', uri: url);
    }
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

/// Where a source reads a pieces track from (see relay_pieces.dart).
abstract interface class RelayPieces {
  /// The track's shape; a playlist is fetched on the first call. Throws
  /// [RelayPiecesException] when it cannot be relayed (DRM, live).
  Future<RelayPieceList> list();

  /// Piece [index], whole, in order. Cancelling stops reading.
  Stream<List<int>> read(int index);

  Future<void> close();
}

/// One track of a relayed media: [kind] is `video` or `audio` when a
/// media has several (or is pieces), empty for a single file. Read as
/// [bytes] (a Range-readable stream) or as [pieces].
class RelayTrack {
  final String kind;
  final RelayBytes? bytes;
  final RelayPieces? pieces;
  const RelayTrack(this.kind, RelayBytes this.bytes) : pieces = null;
  const RelayTrack.pieces(this.kind, RelayPieces this.pieces) : bytes = null;

  RelayTrackSpec get spec => RelayTrackSpec(kind.isEmpty ? 'video' : kind, pieces: pieces != null);
}

/// The wire's `relay.tracks` for [tracks]: empty for one file.
List<RelayTrackSpec> relayTrackSpecs(List<RelayTrack> tracks) =>
    tracks.length == 1 && tracks.single.pieces == null ? const [] : [for (final t in tracks) t.spec];

/// A track's `info` entry: its kind and size, or its pieces.
Future<Map<String, Object?>> relayTrackInfo(RelayTrack t) async => t.pieces != null
    ? {...t.spec.toJson(), ...(await t.pieces!.list()).toJson()}
    : {'kind': t.kind, 'size': await t.bytes!.size()};

/// What a relay serves: one track, or several played together (a page's
/// separate video and audio).
abstract interface class RelayMedia {
  /// The tracks, in order; a link is resolved on the first call. Throws
  /// with the reason when it cannot be relayed.
  Future<List<RelayTrack>> open();

  Future<void> close();

  /// One file.
  factory RelayMedia.single(RelayBytes bytes) = _SingleRelayMedia;
}

class _SingleRelayMedia implements RelayMedia {
  final RelayBytes bytes;
  _SingleRelayMedia(this.bytes);

  @override
  Future<List<RelayTrack>> open() async => [RelayTrack('', bytes)];

  @override
  Future<void> close() => bytes.close();
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
const relayCloseNotSource = CloseCodes.relayNotSource;

/// Close codes after which a source stops for good: not the source
/// (4001), another media than the relay's (4002), replaced by a newer
/// channel (4003).
const relayStopCodes = {CloseCodes.relayNotSource, CloseCodes.relayOtherMedia, CloseCodes.relayReplaced};

/// Serves [media] on the relay channel at [url] (`ws://host/r/<sid>/<token>/source`)
/// until [close]. Reconnects with backoff when the channel drops (the
/// server keeps the relay through the source's grace and pulls what it
/// still lacks); stops for good on [relayStopCodes]. [name] and
/// [duration] (seconds, 0 unknown) go in its `info`, so a re-dial is
/// recognised as the same media.
class RelaySource {
  final Uri url;
  final RelayMedia media;
  final String name;
  final double duration;
  final Duration Function(int attempt) backoff;
  RelaySource(this.url, this.media, {this.name = '', this.duration = 0, Duration Function(int attempt)? backoff})
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

  var _tracks = const <RelayTrack>[];

  /// The media's tracks once [start] has opened it (empty before).
  List<RelayTrack> get tracks => _tracks;

  /// Opens the media (a page is resolved) and starts serving; throws
  /// when it cannot be read.
  Future<void> start() async {
    final sw = Stopwatch()..start();
    final List<RelayTrack> tracks;
    final List<Map<String, Object?>> infos;
    try {
      tracks = await media.open();
      // The tracks' first upstream reads at once: viewers wait on them.
      infos = await Future.wait([for (final t in tracks) relayTrackInfo(t)]);
    } catch (e) {
      _log.warning('relay source ${logUrl(url)}: cannot open the media after ${sw.elapsedMilliseconds} ms: $e');
      rethrow;
    }
    _log.info('relay source ${logUrl(url)}: media opened in ${sw.elapsedMilliseconds} ms '
        '(${infos.map((i) => i['size'] != null ? '${i['kind'] == '' ? 'file' : i['kind']} ${i['size']} bytes' : '${i['kind']} ${(i['pieces'] as List?)?.length} pieces').join(' + ')})');
    _tracks = tracks;
    unawaited(_loop({
      't': 'info',
      if (relayTrackSpecs(tracks).isEmpty) 'size': infos.single['size'] else 'tracks': infos,
      if (name.isNotEmpty) 'name': name,
      if (duration > 0 && duration.isFinite) 'duration': duration,
    }));
  }

  Future<void> _loop(Map<String, Object?> info) async {
    var attempt = 0;
    final where = logUrl(url);
    while (!_closed) {
      try {
        final ws = await WebSocket.connect(url.toString()).timeout(const Duration(seconds: 15));
        if (_closed) {
          await ws.close();
          break;
        }
        _ws = ws;
        // A half-open channel (a dead link without a FIN) is noticed by
        // its missing pong, closed, and dialled again.
        ws.pingInterval = const Duration(seconds: RelayConstants.pingIntervalSecs);
        _log.info('relay channel up: $where${attempt > 0 ? ' (after $attempt retries)' : ''}');
        attempt = 0;
        ws.add(jsonEncode(info));
        await for (final m in ws) {
          if (m is String) _onText(ws, m);
        }
        if (relayStopCodes.contains(ws.closeCode)) {
          _log.info('relay channel: ${ws.closeCode == CloseCodes.relayNotSource ? 'not the source any more' : ws.closeCode == CloseCodes.relayOtherMedia ? 'another media than the relay\'s' : 'replaced by a newer channel'}, stopping ($where, sent $bytesSent bytes)');
          _closed = true;
        } else if (!_closed) {
          _log.warning('relay channel down: $where, code ${ws.closeCode} ${ws.closeReason ?? ''}; reconnecting');
        }
      } catch (e) {
        final pass = attempt < 3 || attempt % 10 == 0 ? '' : null;
        if (pass != null) _log.warning('relay channel: cannot reach $where (attempt ${attempt + 1}): $e');
      }
      _ws = null;
      _abandonAll();
      if (_closed) break;
      await Future<void>.delayed(backoff(attempt++));
    }
    _abandonAll();
    await media.close();
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
        final start = j['start'], end = j['end'], track = j['track'] ?? 0, piece = j['piece'];
        if (track is! int || track < 0 || track >= _tracks.length) return;
        final t = _tracks[track];
        final Stream<List<int>> Function() read;
        if (piece is int) {
          if (t.pieces == null || piece < 0) return;
          read = () => t.pieces!.read(piece);
        } else {
          if (start is! int || end is! int || start < 0 || end < start || t.bytes == null) return;
          read = () => t.bytes!.read(start, end);
        }
        final p = _Pull(id);
        _pulls[id] = p;
        unawaited(_serve(ws, p, read));
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
    // A read cut off mid-request (the client closing) errors here: moot.
    unawaited(p.it?.cancel().catchError((_) {}));
  }

  void _abandonAll() {
    for (final p in _pulls.values.toList()) {
      _cancel(p);
    }
    _pulls.clear();
  }

  Future<void> _serve(WebSocket ws, _Pull p, Stream<List<int>> Function() read) async {
    final it = p.it = StreamIterator(read());
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
        final pass = _readThrottle.allow('$e');
        if (pass != null) _log.warning('${pass}relay read ${p.id} failed: $e');
        try {
          ws.add(jsonEncode({'t': 'fail', 'id': p.id, 'reason': '$e'}));
        } catch (_) {}
      }
    } finally {
      p.finished = true;
      if (p.settled) _pulls.remove(p.id);
      await it.cancel().catchError((_) {});
    }
  }

  /// Stops serving; [done] completes once the loop has wound down (a
  /// pending reconnect delay runs out first).
  Future<void> close() async {
    _closed = true;
    await _ws?.close();
  }
}
