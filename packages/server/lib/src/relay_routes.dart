import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';
import 'package:web_socket/web_socket.dart';

import 'media_endpoint.dart';
import 'relay_buffer.dart';
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

/// The relay of the current media: one buffer per track and where the
/// bytes come from. One per relayed swap; [dispose] on the next swap or
/// server stop (the buffers are memory only, so that is the whole cleanup).
class ActiveRelay {
  final int mediaId;
  final String name;
  /// Token of the member whose machine serves the bytes; null when the
  /// server fetches the link itself.
  final String? sourceToken;
  final void Function() onLiveChanged;
  /// One per track, in track order; empty until the server has read a
  /// fetched link.
  List<RelayBuffer> buffers = const [];
  /// `media.relay.tracks`: the kinds when there are several tracks.
  List<String> kinds = const [];
  final _known = Completer<void>();
  var _ids = 0;
  RelayMedia? _media;
  var _local = const <LocalRelayFeed>[];
  RelicWebSocket? _channel;
  var _channelFeeds = const <ChannelRelayFeed>[];

  ActiveRelay._(this.mediaId, this.name, this.sourceToken, this.onLiveChanged);

  int _nextId() => ++_ids;

  void _setTracks(List<String> kinds) {
    this.kinds = kinds.length > 1 ? List.unmodifiable(kinds) : const [];
    buffers = [for (var i = 0; i < max(1, kinds.length); i++) RelayBuffer(nextId: _nextId)];
    if (!_known.isCompleted) _known.complete();
  }

  void _budget(List<int> sizes) {
    final b = relayBudgets(sizes);
    for (var i = 0; i < buffers.length; i++) {
      buffers[i]
        ..ahead = b[i].$1
        ..back = b[i].$2;
    }
  }

  /// Bytes from member [sourceToken] over its relay channel, as the
  /// [tracks] its swap named (empty: one file).
  factory ActiveRelay.fromMember(int mediaId, String name, String sourceToken,
          {List<String> tracks = const [], required void Function() onLiveChanged}) =>
      ActiveRelay._(mediaId, name, sourceToken, onLiveChanged).._setTracks(tracks);

  /// The server reads [url] itself: a media file as is, a web page
  /// through [ytDlp] (one file, or video + audio tracks). [onFail] gets
  /// the reason when it cannot.
  static ActiveRelay fetch(int mediaId, String name, Uri url,
      {YtDlp? ytDlp, required void Function() onLiveChanged, void Function(String reason)? onFail}) {
    final r = ActiveRelay._(mediaId, name, null, onLiveChanged);
    final media = r._media = LinkRelayMedia(url, ytDlp: ytDlp);
    unawaited(() async {
      try {
        final tracks = await media.open();
        final sizes = [for (final t in tracks) await t.bytes.size()];
        if (r._disposed) return;
        r._setTracks([for (final t in tracks) t.kind]);
        r._budget(sizes);
        r._local = [for (var i = 0; i < tracks.length; i++) LocalRelayFeed(tracks[i].bytes, r.buffers[i])];
        for (var i = 0; i < tracks.length; i++) {
          r.buffers[i].attach(r._local[i], sizes[i]);
        }
        onLiveChanged();
      } catch (e) {
        _log.warning('relay fetch: cannot read the link: $e');
        if (!r._disposed) onFail?.call('$e');
      }
    }());
    return r;
  }

  var _disposed = false;
  bool get live => buffers.isNotEmpty && buffers.every((b) => b.live);

  /// The tracks are known (a fetched link has been read).
  bool get known => _known.isCompleted && !_disposed;

  /// Waits until the tracks are known, up to [RelayConstants.relayWaitSecs].
  Future<bool> whenKnown() async {
    if (!_known.isCompleted) {
      await _known.future.timeout(const Duration(seconds: RelayConstants.relayWaitSecs), onTimeout: () {});
    }
    return known;
  }

  /// The buffer of [track]; null (the single-file URL) only for a media of
  /// one track. Null when there is no such track.
  RelayBuffer? bufferAt(int? track) {
    if (track == null) return buffers.length == 1 ? buffers.single : null;
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

  /// Source member gone for good (kicked): stop its channel.
  void dropChannel() {
    final ch = _channel;
    _channel = null;
    if (ch != null) unawaited(_closeNotSource(ch));
  }

  void _attachChannel(RelicWebSocket ws, List<int> sizes) {
    final old = _channel;
    if (old != null && !identical(old, ws)) unawaited(old.tryClose());
    _channel = ws;
    final multi = buffers.length > 1;
    final feeds = _channelFeeds = [
      for (var i = 0; i < buffers.length; i++) ChannelRelayFeed((t) => ws.trySendText(t), track: multi ? i : null),
    ];
    _budget(sizes);
    for (var i = 0; i < buffers.length; i++) {
      buffers[i].attach(feeds[i], sizes[i]);
    }
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

/// The track sizes of a channel's `info` frame (`size`, or `tracks[].size`),
/// or null when malformed.
List<int>? _infoSizes(Map j) {
  final size = j['size'], tracks = j['tracks'];
  if (size is int) return size > 0 ? [size] : null;
  if (tracks is! List || tracks.isEmpty) return null;
  final out = <int>[];
  for (final t in tracks) {
    final n = t is Map ? t['size'] : null;
    if (n is! int || n <= 0) return null;
    out.add(n);
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
/// channel. `GET /r/<sid>/<token>/<mediaId>/<name>`: a viewer reads the
/// relayed file, Range as for `/m`; `.../<mediaId>/<track>/<name>` one
/// track of a media relayed as several. [relay] gives the current relay.
void mountRelayRoutes(
  RelicApp app,
  SessionMap sessions,
  ActiveRelay? Function() relay, {
  void Function(String token, MediaLog log)? onLog,
}) {
  app.get('/r/:sid/:token/source', (final req) {
    final sid = req.pathParameters.raw[#sid] ?? '';
    final token = req.pathParameters.raw[#token] ?? '';
    final session = sessions.get(sid);
    final r = relay();
    final ok = session != null &&
        session.gate(token) == MediaGate.ok &&
        r != null &&
        r.sourceToken == token;
    return WebSocketUpgrade((final ws) async {
      if (!ok) {
        await _closeNotSource(ws);
        return;
      }
      final r = relay()!;
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
                final sizes = _infoSizes(j);
                if (sizes == null || sizes.length != r.buffers.length) {
                  // Not the media this swap named: the source stops.
                  _log.warning('relay channel: info does not match the media (${r.name})');
                  await _closeNotSource(ws);
                  return;
                }
                attached = true;
                _log.info('relay channel up (${r.name}, ${sizes.join(' + ')} bytes)');
                r._attachChannel(ws, sizes);
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

  Future<Response> viewer(Request req, {required bool tracked}) async {
    final stopwatch = Stopwatch()..start();
    final sid = req.pathParameters.raw[#sid] ?? '';
    final token = req.pathParameters.raw[#token] ?? '';
    final mediaId = int.tryParse(req.pathParameters.raw[#mediaId] ?? '');
    final track = tracked ? int.tryParse(req.pathParameters.raw[#seg] ?? '') ?? -1 : null;
    final session = sessions.get(sid);
    if (session == null) return _plain(410);
    switch (session.gate(token)) {
      case MediaGate.ok:
        break;
      case MediaGate.forbidden:
        return _plain(403);
      default:
        return _plain(401);
    }
    final r = relay();
    // A player still on an older media must not get the new one's bytes.
    if (r == null || r.mediaId != mediaId) return _plain(404);
    final notConnected = Response(503,
        body: Body.fromString('relay source not connected'),
        headers: Headers.build((h) => h['retry-after'] = ['2']));
    if (!await r.whenKnown()) return notConnected;
    final buffer = r.bufferAt(track);
    if (buffer == null) return _plain(404);
    if (!await buffer.ready()) return notConnected;
    final size = buffer.size;
    final typed = req.headers.range;
    String? rangeHeader;
    if (typed != null && typed.ranges.isNotEmpty) {
      final x = typed.ranges.first;
      rangeHeader = '${typed.unit}=${x.start?.toString() ?? ''}-${x.end?.toString() ?? ''}';
    }
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
          path: '/r/$sid/$shortToken/$mediaId/${track == null ? '' : '$track/'}${r.name}',
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
}

Response _plain(int status) => Response(status, body: Body.fromString('status $status'));
