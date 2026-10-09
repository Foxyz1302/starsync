import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'relay.dart';

// Pieces tracks: a segmented stream (an HLS media playlist, or yt-dlp's
// DASH fragments) relayed piece by piece. A piece is one upstream GET
// served whole: a segment, an init section (`EXT-X-MAP`) or an AES-128
// key. The fetcher (the source member, or the server for a link it reads
// itself) parses the upstream playlist into a [RelayPieceList] (no URLs);
// the server turns that into the VOD media playlist viewers open, whose
// entries are its own `p/<i>` piece URLs (see [RelayPieceList.playlist]).

/// Why a segmented stream cannot be relayed.
class RelayPiecesException implements Exception {
  final String message;
  const RelayPiecesException(this.message);
  @override
  String toString() => message;
}

/// The text for DRM-protected media.
const drmText = "This video is DRM-protected; it can't be relayed.";

/// The text for a live stream.
const liveStreamText = "Live streams can't be passed on. Choose 'Everyone fetches it' instead.";

enum RelayPieceRole { segment, init, key }

/// One piece of a [RelayPieceList]. A segment has its duration [d], the
/// init piece [map] and AES-128 key piece [key] (with an explicit [iv])
/// that apply to it, and [disc] when an `EXT-X-DISCONTINUITY` precedes it.
class RelayPiece {
  final RelayPieceRole role;
  final double d;
  final int? map, key;
  final String? iv;
  final bool disc;
  const RelayPiece.segment(this.d, {this.map, this.key, this.iv, this.disc = false})
      : role = RelayPieceRole.segment;
  const RelayPiece.init()
      : role = RelayPieceRole.init,
        d = 0,
        map = null,
        key = null,
        iv = null,
        disc = false;
  const RelayPiece.key()
      : role = RelayPieceRole.key,
        d = 0,
        map = null,
        key = null,
        iv = null,
        disc = false;

  bool get isSegment => role == RelayPieceRole.segment;

  Map<String, Object?> toJson() => switch (role) {
        RelayPieceRole.init => {'init': true},
        RelayPieceRole.key => {'key': true},
        RelayPieceRole.segment => {
            'd': d,
            if (map != null) 'map': map,
            if (key != null) 'key': key,
            if (iv != null) 'iv': iv,
            if (disc) 'disc': true,
          },
      };
}

final _ivRe = RegExp(r'^0[xX][0-9a-fA-F]{1,32}$');

/// The shape of a pieces track: what the server needs to serve it (no
/// upstream URLs). Sent in the relay channel's `info` (see PROTOCOL.md).
class RelayPieceList {
  final List<RelayPiece> pieces;
  /// `EXT-X-MEDIA-SEQUENCE` of the first segment (AES-128 without an
  /// explicit IV uses the segment's sequence number).
  final int seq;
  const RelayPieceList(this.pieces, {this.seq = 0});

  static const maxPieces = 200000;

  int get length => pieces.length;
  double get duration => pieces.fold(0.0, (a, p) => a + p.d);

  /// Same piece count and roles (a re-resolve or a reconnect of the same
  /// media).
  bool sameShape(RelayPieceList o) {
    if (o.length != length) return false;
    for (var i = 0; i < length; i++) {
      if (o.pieces[i].role != pieces[i].role) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
        if (seq != 0) 'seq': seq,
        'pieces': [for (final p in pieces) p.toJson()],
      };

  /// Parses and checks a track entry's `seq` / `pieces`; null when
  /// malformed (an index out of range or of the wrong role, a bad IV).
  static RelayPieceList? fromJson(Map j) {
    final raw = j['pieces'];
    final seq = j['seq'] ?? 0;
    if (raw is! List || raw.isEmpty || raw.length > maxPieces || seq is! int || seq < 0) return null;
    final roles = <RelayPieceRole>[];
    for (final e in raw) {
      if (e is! Map) return null;
      roles.add(e['init'] == true
          ? RelayPieceRole.init
          : e['key'] == true
              ? RelayPieceRole.key
              : RelayPieceRole.segment);
    }
    int? ref(Object? v, RelayPieceRole want) {
      if (v == null) return null;
      if (v is! int || v < 0 || v >= roles.length || roles[v] != want) throw const FormatException();
      return v;
    }

    final out = <RelayPiece>[];
    try {
      for (var i = 0; i < raw.length; i++) {
        final e = raw[i] as Map;
        switch (roles[i]) {
          case RelayPieceRole.init:
            out.add(const RelayPiece.init());
          case RelayPieceRole.key:
            out.add(const RelayPiece.key());
          case RelayPieceRole.segment:
            final d = e['d'], iv = e['iv'];
            if (d is! num || !d.isFinite || d < 0 || d > 3600) return null;
            if (iv != null && (iv is! String || !_ivRe.hasMatch(iv))) return null;
            out.add(RelayPiece.segment(d.toDouble(),
                map: ref(e['map'], RelayPieceRole.init),
                key: ref(e['key'], RelayPieceRole.key),
                iv: iv as String?,
                disc: e['disc'] == true));
        }
      }
    } on FormatException {
      return null;
    }
    if (!out.any((p) => p.isSegment)) return null;
    return RelayPieceList(List.unmodifiable(out), seq: seq);
  }

  /// The VOD media playlist viewers open: every entry is `p/<i>`
  /// (relative to the playlist's URL), init and key pieces included.
  String playlist() {
    final segs = pieces.where((p) => p.isSegment);
    final target = max(1, segs.map((p) => p.d).fold(0.0, max).ceil());
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:6')
      ..writeln('#EXT-X-TARGETDURATION:$target')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:$seq')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');
    int? map, key;
    String? iv;
    for (var i = 0; i < pieces.length; i++) {
      final p = pieces[i];
      if (!p.isSegment) continue;
      if (p.disc) b.writeln('#EXT-X-DISCONTINUITY');
      if (p.map != null && p.map != map) b.writeln('#EXT-X-MAP:URI="p/${p.map}"');
      if (p.key != key || p.iv != iv) {
        b.writeln(p.key == null
            ? '#EXT-X-KEY:METHOD=NONE'
            : '#EXT-X-KEY:METHOD=AES-128,URI="p/${p.key}"${p.iv == null ? '' : ',IV=${p.iv}'}');
      }
      map = p.map;
      key = p.key;
      iv = p.iv;
      b
        ..writeln('#EXTINF:${p.d.toStringAsFixed(6)},')
        ..writeln('p/$i');
    }
    b.writeln('#EXT-X-ENDLIST');
    return b.toString();
  }
}

/// Where the fetcher reads piece `i`: one GET of [url], of [length] bytes
/// at [offset] when it is a byte range of a bigger file.
typedef PieceSource = ({Uri url, int? offset, int? length});

/// A parsed upstream stream: the shape plus where each piece lives.
typedef UpstreamPieces = ({RelayPieceList list, List<PieceSource> sources});

Map<String, String> _attrs(String s) {
  final out = <String, String>{};
  for (final m in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)').allMatches(s)) {
    var v = m.group(2)!;
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
    out[m.group(1)!] = v;
  }
  return out;
}

/// An HLS media playlist at [base] as pieces: every segment, `EXT-X-MAP`
/// and AES-128 `EXT-X-KEY` becomes a piece; `EXT-X-BYTERANGE` (and a MAP's
/// `BYTERANGE`) is folded into the piece (the offset defaults to the end
/// of the previous range of the same URI). Throws [RelayPiecesException]
/// for DRM (SAMPLE-AES, `skd:`, any non-identity key format), a live
/// playlist (no `EXT-X-ENDLIST`), a master playlist or no segments.
UpstreamPieces parseHlsPlaylist(String text, Uri base) {
  final lines = const LineSplitter().convert(text).map((l) => l.trim()).toList();
  if (lines.isEmpty || !lines.first.startsWith('#EXTM3U')) {
    throw const RelayPiecesException('not an HLS playlist');
  }
  final pieces = <RelayPiece>[];
  final sources = <PieceSource>[];
  final lastEnd = <String, int>{};
  final shared = <String, int>{}; // init/key piece by "url offset length"
  var seq = 0;
  var ended = false;
  double? extinf;
  int? brLen, brOff, map, key;
  String? iv;
  var disc = false;

  int add(RelayPiece p, Uri url, int? len, int? off) {
    if (len != null) {
      off ??= lastEnd['$url'] ?? 0;
      lastEnd['$url'] = off + len;
    }
    pieces.add(p);
    sources.add((url: url, offset: len == null ? null : off, length: len));
    return pieces.length - 1;
  }

  int sharedPiece(RelayPiece p, String uri, (int, int?)? range) {
    final url = base.resolve(uri);
    if (!url.isScheme('http') && !url.isScheme('https')) throw const RelayPiecesException(drmText);
    final k = '${p.role} $url ${range?.$2} ${range?.$1}';
    return shared[k] ??= add(p, url, range?.$1, range?.$2);
  }

  (int, int?) range(String v) {
    final parts = v.split('@');
    final len = int.tryParse(parts[0]);
    final off = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (len == null || len <= 0 || (parts.length > 1 && (off == null || off < 0))) {
      throw const RelayPiecesException('bad byte range in the playlist');
    }
    return (len, off);
  }

  for (final line in lines) {
    if (line.isEmpty) continue;
    if (!line.startsWith('#')) {
      final url = base.resolve(line);
      if (!url.isScheme('http') && !url.isScheme('https')) {
        throw const RelayPiecesException('the playlist has a segment that is not http(s)');
      }
      add(RelayPiece.segment(extinf ?? 0, map: map, key: key, iv: iv, disc: disc), url, brLen, brOff);
      extinf = null;
      brLen = brOff = null;
      disc = false;
      continue;
    }
    final colon = line.indexOf(':');
    final tag = colon < 0 ? line : line.substring(0, colon);
    final value = colon < 0 ? '' : line.substring(colon + 1);
    switch (tag) {
      case '#EXT-X-STREAM-INF':
        throw const RelayPiecesException('a master playlist, not a media playlist');
      case '#EXT-X-I-FRAMES-ONLY':
        throw const RelayPiecesException('an I-frame playlist');
      case '#EXT-X-SESSION-KEY':
        throw const RelayPiecesException(drmText);
      case '#EXT-X-MEDIA-SEQUENCE':
        seq = int.tryParse(value) ?? 0;
      case '#EXT-X-ENDLIST':
        ended = true;
      case '#EXT-X-DISCONTINUITY':
        disc = true;
      case '#EXTINF':
        extinf = double.tryParse(value.split(',').first.trim());
      case '#EXT-X-BYTERANGE':
        (brLen, brOff) = range(value);
      case '#EXT-X-MAP':
        final a = _attrs(value);
        final uri = a['URI'];
        if (uri == null) throw const RelayPiecesException('EXT-X-MAP without a URI');
        map = sharedPiece(const RelayPiece.init(), uri, a['BYTERANGE'] == null ? null : range(a['BYTERANGE']!));
      case '#EXT-X-KEY':
        final a = _attrs(value);
        final method = (a['METHOD'] ?? '').toUpperCase();
        if (method == 'NONE') {
          key = null;
          iv = null;
          continue;
        }
        final format = a['KEYFORMAT'];
        final uri = a['URI'] ?? '';
        if (method != 'AES-128' || (format != null && format != 'identity') || uri.isEmpty) {
          throw const RelayPiecesException(drmText);
        }
        final v = a['IV'];
        if (v != null && !_ivRe.hasMatch(v)) throw const RelayPiecesException('bad IV in the playlist');
        key = sharedPiece(const RelayPiece.key(), uri, null);
        iv = v;
    }
  }
  if (!ended) throw const RelayPiecesException(liveStreamText);
  if (!pieces.any((p) => p.isSegment)) throw const RelayPiecesException('the playlist has no segments');
  if (pieces.length > RelayPieceList.maxPieces) throw const RelayPiecesException('the playlist is too long');
  return (list: RelayPieceList(List.unmodifiable(pieces), seq: seq), sources: List.unmodifiable(sources));
}

/// yt-dlp's DASH `fragments` (`http_dash_segments`) as pieces: a first
/// fragment without a duration is the init section, every other one a
/// segment (so no MPD parser of our own).
UpstreamPieces dashPieces(List<({Uri url, double? duration})> fragments) {
  if (fragments.isEmpty) throw const RelayPiecesException('no fragments');
  final pieces = <RelayPiece>[];
  final sources = <PieceSource>[];
  int? map;
  for (var i = 0; i < fragments.length; i++) {
    final f = fragments[i];
    if (i == 0 && f.duration == null) {
      map = 0;
      pieces.add(const RelayPiece.init());
    } else {
      pieces.add(RelayPiece.segment(f.duration ?? 0, map: map));
    }
    sources.add((url: f.url, offset: null, length: null));
  }
  if (!pieces.any((p) => p.isSegment)) throw const RelayPiecesException('no fragments');
  return (list: RelayPieceList(List.unmodifiable(pieces)), sources: List.unmodifiable(sources));
}

/// Fetches an HLS media playlist with [headers] and parses it
/// ([parseHlsPlaylist]).
Future<UpstreamPieces> fetchHlsPlaylist(HttpClient client, Uri url, Map<String, String> headers) async {
  final req = await client.getUrl(url).timeout(const Duration(seconds: 20));
  headers.forEach(req.headers.set);
  final res = await req.close().timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) {
    await res.drain<void>().catchError((_) {});
    throw UpstreamHttpException(res.statusCode, url);
  }
  final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
  // Relative entries resolve against where the playlist ended up.
  final at = res.redirects.isEmpty ? url : url.resolveUri(res.redirects.last.location);
  return parseHlsPlaylist(text, at);
}

/// Reads one piece: a GET of its URL (with its byte range), whole.
Stream<List<int>> readPiece(HttpClient client, PieceSource s, Map<String, String> headers) async* {
  final req = await client.getUrl(s.url).timeout(const Duration(seconds: 20));
  headers.forEach(req.headers.set);
  req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  final off = s.offset, len = s.length;
  if (len != null) req.headers.set(HttpHeaders.rangeHeader, 'bytes=${off ?? 0}-${(off ?? 0) + len - 1}');
  final res = await req.close().timeout(const Duration(seconds: 20));
  if (res.statusCode != 200 && res.statusCode != 206) {
    await res.drain<void>().catchError((_) {});
    throw UpstreamHttpException(res.statusCode, s.url);
  }
  if (len == null) {
    yield* res;
    return;
  }
  // A server ignoring Range sends the whole file: cut the piece out.
  var skip = res.statusCode == 200 ? (off ?? 0) : 0;
  var left = len;
  await for (final c in res) {
    var from = 0;
    if (skip > 0) {
      from = min(skip, c.length);
      skip -= from;
    }
    final take = min(c.length - from, left);
    if (take > 0) yield from == 0 && take == c.length ? c : c.sublist(from, from + take);
    left -= take;
    if (left <= 0) return;
  }
  if (left > 0) throw HttpException('upstream ended early', uri: s.url);
}
