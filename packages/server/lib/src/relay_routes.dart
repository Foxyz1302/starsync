import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';
import 'package:web_socket/web_socket.dart';

import 'media_endpoint.dart';
import 'relay_buffer.dart';
import 'session.dart';

final _log = createLogger('relay');

/// The relay of the current media: its buffer and where the bytes come
/// from. One per relayed swap; [dispose] on the next swap or server stop
/// (the buffer is memory only, so that is the whole cleanup).
class ActiveRelay {
  final int mediaId;
  final String name;
  /// Token of the member whose machine serves the bytes; null when the
  /// server fetches the link itself ([local]).
  final String? sourceToken;
  final RelayBuffer buffer;
  final LocalRelayFeed? local;
  final void Function() onLiveChanged;
  RelicWebSocket? _channel;
  ChannelRelayFeed? _channelFeed;

  ActiveRelay._(this.mediaId, this.name, this.sourceToken, this.buffer, this.local, this.onLiveChanged);

  /// Bytes from member [sourceToken] over its relay channel.
  factory ActiveRelay.fromMember(int mediaId, String name, String sourceToken,
          {RelayBuffer? buffer, required void Function() onLiveChanged}) =>
      ActiveRelay._(mediaId, name, sourceToken, buffer ?? RelayBuffer(), null, onLiveChanged);

  /// The server reads [url] itself.
  static ActiveRelay fetch(int mediaId, String name, Uri url,
      {RelayBuffer? buffer, required void Function() onLiveChanged}) {
    final b = buffer ?? RelayBuffer();
    final local = LocalRelayFeed(HttpRelayBytes(url), b);
    final r = ActiveRelay._(mediaId, name, null, b, local, onLiveChanged);
    unawaited(() async {
      try {
        final size = await local.bytes.size();
        if (r._disposed) return;
        b.attach(local, size);
        onLiveChanged();
      } catch (e) {
        _log.warning('relay fetch: cannot read the link: $e');
      }
    }());
    return r;
  }

  var _disposed = false;
  bool get live => buffer.live;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    buffer.dispose();
    unawaited(local?.close());
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

  void _attachChannel(RelicWebSocket ws, int size) {
    final old = _channel;
    if (old != null && !identical(old, ws)) unawaited(old.tryClose());
    _channel = ws;
    final feed = _channelFeed = ChannelRelayFeed((t) => ws.trySendText(t));
    buffer.attach(feed, size);
    onLiveChanged();
  }

  void _detachChannel(RelicWebSocket ws) {
    if (!identical(_channel, ws)) return;
    _channel = null;
    final feed = _channelFeed;
    _channelFeed = null;
    if (feed != null) buffer.detach(feed);
    onLiveChanged();
  }
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
/// relayed media, Range as for `/m`. [relay] gives the current relay.
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
                final size = j['size'];
                if (size is int && size > 0 && !attached) {
                  attached = true;
                  _log.info('relay channel up (${r.name}, $size bytes)');
                  r._attachChannel(ws, size);
                }
              case 'end':
                if (id is int) r.buffer.feedEnd(id);
              case 'fail':
                if (id is int) r.buffer.feedFail(id, '${j['reason']}');
            }
          } else if (e is BinaryDataReceived && attached) {
            try {
              final (id, payload) = decodeRelayFrame(e.data);
              r.buffer.feedBytes(id, payload);
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

  app.get('/r/:sid/:token/:mediaId/:name', (final req) async {
    final stopwatch = Stopwatch()..start();
    final sid = req.pathParameters.raw[#sid] ?? '';
    final token = req.pathParameters.raw[#token] ?? '';
    final mediaId = int.tryParse(req.pathParameters.raw[#mediaId] ?? '');
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
    if (!await r.buffer.ready()) {
      return Response(503,
          body: Body.fromString('relay source not connected'),
          headers: Headers.build((h) => h['retry-after'] = ['2']));
    }
    final size = r.buffer.size;
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
          path: '/r/$sid/$shortToken/$mediaId/${r.name}',
          rangeHeader: rangeHeader,
          status: res.status,
          bytesWritten: end - res.start + 1,
          durationMs: stopwatch.elapsedMilliseconds,
        ));
    final Stream<Uint8List> body =
        r.buffer.read(token, res.start, end, onSent: (n) => session.addBytes(token, n));
    MimeType mime;
    try {
      mime = MimeType.parse(res.headers['content-type'] ?? '');
    } catch (_) {
      mime = MimeType.octetStream;
    }
    return Response(res.status,
        body: Body.fromDataStream(body, mimeType: mime, contentLength: end - res.start + 1),
        headers: headers);
  });
}

Response _plain(int status) => Response(status, body: Body.fromString('status $status'));
