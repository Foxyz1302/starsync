import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart' show createLogger;

import '../platform/ports/player_host.dart' show liveOpenSegments;

final _log = createLogger('live');

/// A live HLS playlist's window: [count] segments, [secs] long in all.
typedef HlsWindow = ({double secs, int count});

/// How far back a live stream lets this player rewind (ARCHITECTURE "Live
/// streams"): its playlist's window (read once per media, [read]) back
/// from its live edge. mpv never says where the edge is while it plays
/// behind (its cache ends where its read-ahead stops), so the edge is
/// taken from the cache while it reaches the edge, as the stream's time
/// against this machine's clock ([noteEdge]), and runs on with the clock.
class LiveWindow {
  /// A cache end this close to the position is the stream's edge (the
  /// read-ahead, 150 s, is not what stops it).
  static const nearEdge = 100.0;

  /// The window offered to the group leaves out its oldest [_safeSegments]
  /// (they leave the playlist while players open them); an open reaches
  /// one segment short of the window, so a point at the offered start
  /// opens a segment or two before it.
  static const _safeSegments = 3;

  HlsWindow? _playlist;
  String? _readFor;
  double? _edgeOffset;

  /// The playlist's window; null until read, or when the stream has none.
  HlsWindow? get playlist => _playlist;

  /// This machine's clock in seconds (the edge runs on with it).
  static double clock() => DateTime.now().microsecondsSinceEpoch / 1e6;

  /// The player at [own] holds the stream up to [edge] (stream time) at
  /// [at] ([clock]): close enough, that is the edge.
  void noteEdge({required double edge, required double own, required double at}) {
    if (edge <= 0 || edge - own > nearEdge) return;
    final offset = edge - at;
    // The cache end comes in segments, and after an open it climbs to the
    // edge: the furthest seen is the edge.
    final known = _edgeOffset;
    if (known == null || offset > known) _edgeOffset = offset;
  }

  /// The stream's edge at [at] (stream time); null before [noteEdge] saw it.
  double? edgeAt(double at) {
    final o = _edgeOffset;
    return o == null ? null : at + o;
  }

  /// The oldest moment this player can rewind to at [at] (stream time);
  /// null when it cannot (no window read, no edge seen).
  double? fromAt(double at) {
    final p = _playlist, edge = edgeAt(at);
    if (p == null || edge == null || p.count <= _safeSegments + liveOpenSegments) return null;
    return edge - p.secs + _safeSegments * p.secs / p.count;
  }

  /// The segments back from the edge ([liveStartOption]) that open the
  /// stream a little before [target] (stream time) at [at]; null when the
  /// window is unknown. Never further back than the window allows, never
  /// nearer than a fresh open.
  int? segmentsBack(double target, double at) {
    final p = _playlist, edge = edgeAt(at);
    if (p == null || edge == null) return null;
    final most = p.count - 1;
    if (most <= liveOpenSegments) return liveOpenSegments;
    final n = ((edge - target) / (p.secs / p.count)).ceil() + 2;
    return n.clamp(liveOpenSegments, most);
  }

  /// Reads the window of the playlist mpv opened ([url], an EDL's first
  /// part, with [headers]) once per URL; failures leave it unknown.
  Future<void> read(String url, Map<String, String> headers) async {
    if (_readFor == url) return;
    _readFor = url;
    try {
      final w = await fetchHlsWindow(playlistUrlOf(url), headers);
      if (_readFor != url) return;
      _playlist = w;
      _log.info(w == null
          ? 'live window: none'
          : 'live window: ${w.count} segments, ${w.secs.toStringAsFixed(0)} s');
    } catch (e) {
      _log.info('live window: unread ($e)');
    }
  }
}

/// The stream's playlist inside what mpv opens: an EDL's first part (the
/// app's `edl://` of a page's video and audio), else [url] itself.
String playlistUrlOf(String url) {
  if (!url.startsWith('edl://')) return url;
  final m = RegExp(r'%(\d+)%').firstMatch(url);
  if (m == null) return url;
  final len = int.parse(m.group(1)!);
  final bytes = utf8.encode(url.substring(m.end));
  return len <= bytes.length ? utf8.decode(bytes.sublist(0, len)) : url;
}

/// A live media playlist's window; null for a master playlist (see
/// [hlsVariantOf]), a playlist that ended (`#EXT-X-ENDLIST`) or anything
/// else.
HlsWindow? parseHlsWindow(String body) {
  if (!body.trimLeft().startsWith('#EXTM3U') || body.contains('#EXT-X-ENDLIST')) return null;
  var secs = 0.0;
  var count = 0;
  for (final line in const LineSplitter().convert(body)) {
    if (!line.startsWith('#EXTINF:')) continue;
    final d = double.tryParse(line.substring(8).split(',').first.trim());
    if (d == null || !d.isFinite || d <= 0) continue;
    secs += d;
    count++;
  }
  return count == 0 ? null : (secs: secs, count: count);
}

/// A master playlist's first variant, resolved against [base]; null for a
/// media playlist.
Uri? hlsVariantOf(String body, Uri base) {
  final lines = const LineSplitter().convert(body);
  for (var i = 0; i < lines.length - 1; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    final next = lines[i + 1].trim();
    if (next.isNotEmpty && !next.startsWith('#')) return base.resolve(next);
  }
  return null;
}

/// The window of the live playlist at [url] (a master playlist's first
/// variant); null when it is not one.
Future<HlsWindow?> fetchHlsWindow(String url, Map<String, String> headers) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    var uri = Uri.parse(url);
    if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
    for (var hop = 0; hop < 2; hop++) {
      final req = await client.getUrl(uri);
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
      final variant = hlsVariantOf(body, uri);
      if (variant == null) return parseHlsWindow(body);
      uri = variant;
    }
    return null;
  } finally {
    client.close(force: true);
  }
}
