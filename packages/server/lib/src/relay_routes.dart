import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';
import 'package:web_socket/web_socket.dart';

import 'media_endpoint.dart';
import 'piece_buffer.dart';
import 'relay_buffer.dart';
import 'relay_stats.dart';
import 'session.dart';

final _log = createLogger('relay');

/// Each track's (ahead, back) bytes when a media's [sizes] share one
/// buffer budget: by size (the tracks have one duration, so by bitrate),
/// never under [RelayConstants.relayTrackFloorBytes]. One track keeps the
/// whole budget.
List<(int, int)> relayBudgets(List<int> sizes,
    {int ahead = RelayConstants.relayAheadBytes, int back = RelayConstants.relayBackBytes}) {
  if (sizes.length <= 1) return [for (final _ in sizes) (ahead, back)];
  final total = sizes.fold(0, (a, n) => a + n);
  int share(int all, int n) => max(RelayConstants.relayTrackFloorBytes, (all * (n / total)).round());
  return [for (final n in sizes) (share(ahead, n), share(back, n))];
}

/// Bytes per second a pieces track is assumed to need before its first
/// pieces arrive (its share of the budget, its distances): 4 Mbit/s for
/// video, 160 kbit/s for audio.
double _piecesRate(String kind) => kind == 'audio' ? 20000 : 500000;

/// One track as the source (or the fetcher) described it: its kind, a
/// byte size or a piece list.
typedef _TrackInfo = ({String kind, int? size, RelayPieceList? pieces});

/// A relayed media on the server: one buffer per track and where the
/// bytes come from. The relay of the current media (one per relayed swap;
/// [dispose] on the next swap or server stop: the buffers are memory
/// only, so that is the whole cleanup), or the warm relay of Up next's
/// first item ([warm], keyed by [queueId]), which a swap of that item
/// [promote]s to the current one, buffer and all.
class ActiveRelay {
  /// The media it relays; -1 while it is warm.
  int mediaId;
  final String name;
  /// Token of the member whose machine serves the bytes; null when the
  /// server fetches the link itself, or (a warm Jellyfin item) until a
  /// member with an account dials in.
  String? sourceToken;
  /// That member's id (kept after it leaves); empty with [fetch].
  String sourceId;
  /// The server reads the link itself.
  final bool fetch;
  /// The Up next item it was started for (the warm relay); kept once
  /// promoted, so the `/r/.../<queueId>/...` URLs keep working.
  final String? queueId;
  bool _warm;
  final void Function() onLiveChanged;
  /// The server's own fetch could not read the link (with the reason).
  void Function(String reason)? onFail;
  bool failed = false;
  /// One per track, in track order ([RelayBuffer] for bytes, [PieceBuffer]
  /// for pieces); empty until the tracks are known (a fetched link read,
  /// a warm source's first `info`).
  List<TrackBuffer> buffers = const [];
  /// `media.relay.tracks`: empty for one file.
  List<RelayTrackSpec> tracks = const [];
  final _known = Completer<void>();
  var _ids = 0;
  RelayMedia? _media;
  var _local = const <LocalRelayFeed>[];
  RelicWebSocket? _channel;
  var _channelFeeds = const <ChannelRelayFeed>[];
  List<_TrackInfo>? _infos;
  /// Shared by the tracks: time any of them waits on the source.
  final clock = FeedClock();
  final _rate = SourceRate();

  ActiveRelay._(this.mediaId, this.name, this.sourceToken, this.onLiveChanged,
      {this.sourceId = '', this.fetch = false, this.queueId, bool warm = false})
      : _warm = warm;

  /// Up next's first item, before it goes up.
  bool get warm => _warm;

  /// Takes the bytes the source sent so far, for [rate]; the server calls
  /// it once a second.
  void sampleRate() => _rate.sample(buffers.fold(0, (a, b) => a + b.bytesFromFeed), clock.busy);

  /// Bytes per second the source delivers while the buffer asks for bytes
  /// (`media.relay.rate`); 0 until measured.
  int get rate => _rate.rate;

  /// Bytes the buffers hold now.
  int get cachedBytes => buffers.fold(0, (a, b) => a + b.cachedBytes);

  /// The media's average bytes per second for a [duration] in seconds
  /// (`media.relay.need`): byte tracks by size, pieces tracks from the
  /// pieces in so far; 0 while any track is unknown.
  int need(double duration) {
    if (buffers.isEmpty) return 0;
    var total = 0.0;
    for (final b in buffers) {
      if (b is RelayBuffer) {
        if (b.size <= 0 || duration <= 0) return 0;
        total += b.size / duration;
      } else if (b is PieceBuffer) {
        final r = b.bytesPerSec;
        if (r == null) return 0;
        total += r;
      }
    }
    return roundRate(total);
  }

  int _nextId() => ++_ids;

  void _setTracks(List<RelayTrackSpec> tracks) {
    this.tracks = MediaRelay.validTracks(tracks) ? List.unmodifiable(tracks) : const [];
    buffers = this.tracks.isEmpty
        ? [RelayBuffer(nextId: _nextId)]
        : [
            for (final t in this.tracks)
              t.pieces ? PieceBuffer(nextId: _nextId, rate: _piecesRate(t.kind)) : RelayBuffer(nextId: _nextId),
          ];
    for (final b in buffers) {
      b.clock = clock;
    }
    if (!_known.isCompleted) _known.complete();
  }

  /// The tracks a warm source described in its first `info`.
  static List<RelayTrackSpec> _specsOf(List<_TrackInfo> infos) =>
      infos.length == 1 && infos.single.pieces == null
          ? const []
          : [for (final t in infos) RelayTrackSpec(t.kind.isEmpty ? 'video' : t.kind, pieces: t.pieces != null)];

  /// The info of every track matches [tracks] (bytes for a byte track,
  /// pieces for a pieces one).
  bool _matches(List<_TrackInfo> infos) {
    if (infos.length != buffers.length) return false;
    for (var i = 0; i < infos.length; i++) {
      if ((infos[i].pieces != null) != (buffers[i] is PieceBuffer)) return false;
    }
    return true;
  }

  /// Attaches every buffer to its feed.
  void _attachAll(List<RelayFeed> feeds, List<_TrackInfo> infos) {
    _infos = infos;
    _budget();
    for (var i = 0; i < buffers.length; i++) {
      final b = buffers[i];
      if (b is PieceBuffer) {
        b.attach(feeds[i], infos[i].pieces!);
      } else if (b is RelayBuffer) {
        b.attach(feeds[i], infos[i].size!);
      }
    }
  }

  /// The tracks share the budget by size: a warm relay's small one
  /// ([RelayConstants.relayWarmAheadBytes]), else the full one.
  void _budget() {
    final infos = _infos;
    if (infos == null) return;
    final sizes = [
      for (var i = 0; i < infos.length; i++)
        infos[i].size ?? (_piecesRate(infos[i].kind) * infos[i].pieces!.duration).round(),
    ];
    final b = _warm
        ? relayBudgets(sizes, ahead: RelayConstants.relayWarmAheadBytes, back: RelayConstants.relayWarmBackBytes)
        : relayBudgets(sizes);
    for (var i = 0; i < buffers.length; i++) {
      buffers[i]
        ..ahead = b[i].$1
        ..back = b[i].$2;
    }
  }

  /// Bytes from member [sourceToken] over its relay channel, as the
  /// [tracks] its swap named (empty: one file).
  factory ActiveRelay.fromMember(int mediaId, String name, String sourceToken,
          {List<RelayTrackSpec> tracks = const [], String sourceId = '', required void Function() onLiveChanged}) =>
      ActiveRelay._(mediaId, name, sourceToken, onLiveChanged, sourceId: sourceId).._setTracks(tracks);

  /// The warm relay of Up next's item [queueId] fed by member
  /// [sourceToken] (null: the first qualified member to dial in); its
  /// tracks are what the source's first `info` says.
  factory ActiveRelay.warmFromMember(String queueId, String name, String? sourceToken,
          {String sourceId = '', required void Function() onLiveChanged}) =>
      ActiveRelay._(-1, name, sourceToken, onLiveChanged, sourceId: sourceId, queueId: queueId, warm: true);

  /// The server reads [url] itself: a media file as is, a web page
  /// through [ytDlp] (one file, video + audio tracks, or segmented
  /// playlists). [onFail] gets the reason when it cannot. With [queueId]
  /// it is that Up next item's warm relay.
  static ActiveRelay fetchLink(int mediaId, String name, Uri url,
      {YtDlp? ytDlp, String? queueId, required void Function() onLiveChanged, void Function(String reason)? onFail}) {
    final r = ActiveRelay._(mediaId, name, null, onLiveChanged, fetch: true, queueId: queueId, warm: queueId != null)
      ..onFail = onFail;
    final media = r._media = LinkRelayMedia(url, ytDlp: ytDlp);
    unawaited(() async {
      try {
        final tracks = await media.open();
        final infos = <_TrackInfo>[
          for (final t in tracks)
            t.pieces != null
                ? (kind: t.kind, size: null, pieces: await t.pieces!.list())
                : (kind: t.kind, size: await t.bytes!.size(), pieces: null),
        ];
        if (r._disposed) return;
        r._setTracks(relayTrackSpecs(tracks));
        r._local = [for (var i = 0; i < tracks.length; i++) LocalRelayFeed(tracks[i], r.buffers[i])];
        r._attachAll(r._local, infos);
        onLiveChanged();
      } catch (e) {
        _log.warning('relay fetch: cannot read the link: $e');
        if (!r._disposed) {
          r.failed = true;
          r.onFail?.call('$e');
        }
      }
    }());
    return r;
  }

  /// A member relay whose source has not described its tracks yet takes
  /// [tracks] from the swap that puts it up.
  void ensureTracks(List<RelayTrackSpec> tracks) {
    if (!fetch && !_known.isCompleted) _setTracks(tracks);
  }

  /// The warm relay becomes media [mediaId]'s: its buffer and feed carry
  /// on, with the full budget.
  void promote(int mediaId) {
    this.mediaId = mediaId;
    _warm = false;
    _budget();
  }

  var _disposed = false;
  bool get live => buffers.isNotEmpty && buffers.every((b) => b.live);

  /// The tracks are known (a fetched link has been read).
  bool get known => _known.isCompleted && !_disposed && buffers.isNotEmpty;

  /// Waits until the tracks are known, up to [RelayConstants.relayWaitSecs].
  Future<bool> whenKnown() async {
    if (!_known.isCompleted) {
      await _known.future.timeout(const Duration(seconds: RelayConstants.relayWaitSecs), onTimeout: () {});
    }
    return known;
  }

  /// The buffer of [track]; null (the single-file URL) only for one file.
  /// Null when there is no such track.
  TrackBuffer? bufferAt(int? track) {
    if (track == null) return tracks.isEmpty && buffers.length == 1 ? buffers.single : null;
    return track >= 0 && track < buffers.length ? buffers[track] : null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final b in buffers) {
      b.dispose();
    }
    if (!_known.isCompleted) _known.complete();
    final local = _local, media = _media;
    unawaited(() async {
      for (final f in local) {
        await f.close();
      }
      await media?.close();
    }());
    final ch = _channel;
    _channel = null;
    if (ch != null) unawaited(_closeNotSource(ch));
  }

  /// The source dialled in with its tracks: a warm relay learns them
  /// here; false when they are not this relay's.
  bool _channelInfo(List<_TrackInfo> infos) {
    if (!_known.isCompleted) _setTracks(_specsOf(infos));
    return _matches(infos);
  }

  void _attachChannel(RelicWebSocket ws, List<_TrackInfo> infos) {
    final old = _channel;
    if (old != null && !identical(old, ws)) unawaited(old.tryClose());
    _channel = ws;
    final named = tracks.isNotEmpty;
    final feeds = _channelFeeds = [
      for (var i = 0; i < buffers.length; i++) ChannelRelayFeed((t) => ws.trySendText(t), track: named ? i : null),
    ];
    _attachAll(feeds, infos);
    onLiveChanged();
  }

  void _detachChannel(RelicWebSocket ws) {
    if (!identical(_channel, ws)) return;
    _channel = null;
    final feeds = _channelFeeds;
    _channelFeeds = const [];
    for (var i = 0; i < feeds.length && i < buffers.length; i++) {
      buffers[i].detach(feeds[i]);
    }
    onLiveChanged();
  }
}

/// The tracks of a channel's `info` frame (`size`, or `tracks[]` each
/// with a `size` or, `"as":"pieces"`, a piece list), or null when
/// malformed.
List<_TrackInfo>? _infoTracks(Map j) {
  final size = j['size'], tracks = j['tracks'];
  if (size is int) return size > 0 ? [(kind: '', size: size, pieces: null)] : null;
  if (tracks is! List || tracks.isEmpty || tracks.length > MediaRelay.maxTracks) return null;
  final out = <_TrackInfo>[];
  for (final t in tracks) {
    if (t is! Map) return null;
    final kind = t['kind'];
    if (!MediaRelay.trackKinds.contains(kind)) return null;
    if (t['as'] == 'pieces') {
      final list = RelayPieceList.fromJson(t);
      if (list == null) return null;
      out.add((kind: kind as String, size: null, pieces: list));
    } else {
      final n = t['size'];
      if (n is! int || n <= 0) return null;
      out.add((kind: kind as String, size: n, pieces: null));
    }
  }
  return out;
}

Future<void> _closeNotSource(RelicWebSocket ws) async {
  try {
    await ws.close(relayCloseNotSource, 'not the source');
  } catch (_) {
    await ws.tryClose();
  }
}

/// `GET /r/<sid>/<token>/source` (WebSocket): the source member's relay
/// channel; `?q=<queueId>` for the warm relay of that Up next item.
/// `GET /r/<sid>/<token>/<key>/<name>`: a viewer reads the relayed file,
/// Range as for `/m`; `.../<key>/<track>/<name>` one track of a media
/// with tracks (a pieces track's media playlist), and
/// `.../<key>/<track>/p/<i>` piece `i` of a pieces track. `<key>` is the
/// media id, or the queue id of a warm (or promoted) relay. [relayAt]
/// finds the relay of a key, [sourceOf] the relay a token may feed.
void mountRelayRoutes(
  RelicApp app,
  SessionMap sessions, {
  required ActiveRelay? Function(String key) relayAt,
  required ActiveRelay? Function(String token, String? queueId) sourceOf,
  void Function(String token, MediaLog log)? onLog,
}) {
  app.get('/r/:sid/:token/source', (final req) {
    final sid = req.pathParameters.raw[#sid] ?? '';
    final token = req.pathParameters.raw[#token] ?? '';
    final queueId = req.url.queryParameters['q'];
    final session = sessions.get(sid);
    final found = session != null && session.gate(token) == MediaGate.ok ? sourceOf(token, queueId) : null;
    return WebSocketUpgrade((final ws) async {
      final r = found;
      if (r == null) {
        await _closeNotSource(ws);
        return;
      }
      ws.pingInterval = Duration(seconds: RelayConstants.pingIntervalSecs);
      var attached = false;
      try {
        await for (final e in ws.events) {
          if (r._disposed) break;
          if (e is TextDataReceived) {
            final Map j;
            try {
              j = jsonDecode(e.text) as Map;
            } catch (_) {
              continue;
            }
            final id = j['id'];
            switch (j['t']) {
              case 'info':
                if (attached) continue;
                final infos = _infoTracks(j);
                if (infos == null || !r._channelInfo(infos)) {
                  // Not the media this swap named: the source stops.
                  _log.warning('relay channel: info does not match the media (${r.name})');
                  await _closeNotSource(ws);
                  return;
                }
                attached = true;
                _log.info('relay channel up (${r.name}, '
                    '${infos.map((t) => t.size != null ? '${t.size} bytes' : '${t.pieces!.length} pieces').join(' + ')})');
                r._attachChannel(ws, infos);
              case 'end':
                if (id is int) {
                  for (final b in r.buffers) {
                    b.feedEnd(id);
                  }
                }
              case 'fail':
                if (id is int) {
                  for (final b in r.buffers) {
                    b.feedFail(id, '${j['reason']}');
                  }
                }
            }
          } else if (e is BinaryDataReceived && attached) {
            try {
              // Pull ids are unique across tracks: only the owner takes it.
              final (id, payload) = decodeRelayFrame(e.data);
              for (final b in r.buffers) {
                b.feedBytes(id, payload);
              }
            } catch (_) {}
          }
        }
      } catch (_) {
        // channel broke
      } finally {
        r._detachChannel(ws);
        _log.info('relay channel down (${r.name})');
      }
    });
  });

  Future<Response> viewer(Request req, {required bool tracked, bool piece = false}) async {
    final stopwatch = Stopwatch()..start();
    final sid = req.pathParameters.raw[#sid] ?? '';
    final token = req.pathParameters.raw[#token] ?? '';
    final key = req.pathParameters.raw[#mediaId] ?? '';
    final track = tracked ? int.tryParse(req.pathParameters.raw[#seg] ?? '') ?? -1 : null;
    final session = sessions.get(sid);
    if (session == null) return _plain(410);
    switch (session.gate(token)) {
      case MediaGate.ok:
        break;
      default:
        return _plain(401);
    }
    // A player still on an older media must not get the new one's bytes.
    final r = relayAt(key);
    if (r == null) return _plain(404);
    final notConnected = Response(503,
        body: Body.fromString('relay source not connected'),
        headers: Headers.build((h) => h['retry-after'] = ['2']));
    if (!await r.whenKnown()) return notConnected;
    final buffer = r.bufferAt(track);
    if (buffer == null || (piece && buffer is! PieceBuffer)) return _plain(404);
    if (!await buffer.ready()) return notConnected;
    final typed = req.headers.range;
    String? rangeHeader;
    if (typed != null && typed.ranges.isNotEmpty) {
      final x = typed.ranges.first;
      rangeHeader = '${typed.unit}=${x.start?.toString() ?? ''}-${x.end?.toString() ?? ''}';
    }
    if (buffer is PieceBuffer) {
      if (!piece) {
        buffer.opened(token);
        return Response(200,
            body: Body.fromString(buffer.playlist ?? '', mimeType: MimeType('application', 'vnd.apple.mpegurl')),
            headers: Headers.build((h) => h['cache-control'] = ['no-store']));
      }
      final index = int.tryParse(req.pathParameters.raw[#piece] ?? '');
      if (index == null || index < 0 || index >= buffer.list!.length) return _plain(404);
      final data = await buffer.piece(token, index);
      if (data == null) return notConnected;
      final res = resolveMediaRequest(rangeHeader: rangeHeader, size: data.length, filename: 'piece');
      final headers = Headers.build((h) => res.headers.forEach((k, v) => h[k] = [v]));
      if (res.status != 200 && res.status != 206) {
        return Response(res.status, body: Body.fromString('status ${res.status}'), headers: headers);
      }
      final end = res.end ?? data.length - 1;
      final n = end - res.start + 1;
      buffer.bytesToViewers += n;
      session.addBytes(token, n);
      return Response(res.status,
          body: Body.fromData(Uint8List.sublistView(data, res.start, end + 1), mimeType: MimeType.octetStream),
          headers: headers);
    }
    final size = (buffer as RelayBuffer).size;
    final res = resolveMediaRequest(rangeHeader: rangeHeader, size: size, filename: r.name);
    final headers = Headers.build((h) => res.headers.forEach((k, v) => h[k] = [v]));
    if (res.status != 200 && res.status != 206) {
      return Response(res.status, body: Body.fromString('status ${res.status}'), headers: headers);
    }
    final end = res.end ?? size - 1;
    final shortToken = token.length > 4 ? '…${token.substring(token.length - 4)}' : token;
    onLog?.call(
        token,
        MediaLog(
          method: req.method.name,
          path: '/r/$sid/$shortToken/$key/${track == null ? '' : '$track/'}${r.name}',
          rangeHeader: rangeHeader,
          status: res.status,
          bytesWritten: end - res.start + 1,
          durationMs: stopwatch.elapsedMilliseconds,
        ));
    final Stream<Uint8List> body =
        buffer.read(token, res.start, end, onSent: (n) => session.addBytes(token, n));
    MimeType mime;
    try {
      mime = MimeType.parse(res.headers['content-type'] ?? '');
    } catch (_) {
      mime = MimeType.octetStream;
    }
    return Response(res.status,
        body: Body.fromDataStream(body, mimeType: mime, contentLength: end - res.start + 1),
        headers: headers);
    }

  // `:seg` is the name of a single file, the track of several (the router
  // wants one parameter name per level).
  app.get('/r/:sid/:token/:mediaId/:seg', (final req) => viewer(req, tracked: false));
  app.get('/r/:sid/:token/:mediaId/:seg/:name', (final req) => viewer(req, tracked: true));
  app.get('/r/:sid/:token/:mediaId/:seg/p/:piece', (final req) => viewer(req, tracked: true, piece: true));
}

Response _plain(int status) => Response(status, body: Body.fromString('status $status'));
