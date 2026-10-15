import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';

import 'media_endpoint.dart';
import 'session.dart';

final _relayLog = createLogger('jellyfin_relay');

/// Upstream request for one relayed range: the original file
/// (`/Videos/{id}/stream?static=true`) with the server's credential in the
/// `Authorization` header (never in the URL, so nothing to leak in logs).
Uri jellyfinStaticStreamUri(JellyfinCredential cred, JellyfinRef ref) {
  final base = normalizeServerUrl(cred.baseUrl) ?? cred.baseUrl;
  return Uri.parse('$base/Videos/${Uri.encodeComponent(ref.itemId)}/stream').replace(
      queryParameters: {'static': 'true', 'mediaSourceId': ref.mediaSourceId ?? ref.itemId});
}

bool _sameItemId(String a, String b) => (normalizeItemId(a) ?? a) == (normalizeItemId(b) ?? b);

Response _plain(int status) => Response(status, body: Body.fromString('status $status'));

/// `GET /j/<sid>/<token>/<itemId>`: relays byte ranges of the current
/// Jellyfin media from its Jellyfin server to a viewer, with the server's
/// login there ([credentialFor] the ref's `serverId`), for guests without
/// their own access. Only the active ref's item, or Up next's first one
/// ([next], so viewers can get it ready), on a server with a login, only
/// for a valid viewer token: no open proxy. Range goes up as sent;
/// status, Content-Range, Content-Length, Content-Type and Accept-Ranges
/// come back as Jellyfin sent them (a 401/403 from Jellyfin is the server's
/// credential failing, so the viewer gets 502). Bytes stream through without
/// buffering, are counted as sent, and a viewer disconnect aborts upstream.
///
/// [client] gives the HTTP client for upstream requests (the caller owns
/// and closes it).
void mountJellyfinRelayRoute(
  RelicApp app,
  SessionMap sessions,
  JellyfinCredential? Function(String serverId) credentialFor,
  HttpClient Function() client, {
  JellyfinRef? Function()? next,
  String pattern = '/j/:sid/:token/:itemId',
  void Function(String token, MediaLog log)? onLog,
  Duration timeout = const Duration(seconds: 20),
}) {
  app.get(pattern, (final req) async {
    final stopwatch = Stopwatch()..start();
    final sid = req.pathParameters.raw[#sid] ?? '';
    final token = req.pathParameters.raw[#token] ?? '';
    final itemId = req.pathParameters.raw[#itemId] ?? '';
    final session = sessions.get(sid);
    if (session == null) return _plain(410);
    switch (session.gate(token)) {
      case MediaGate.ok:
        break;
      default:
        return _plain(401);
    }
    JellyfinRef? onLogin(JellyfinRef? r) => r != null && credentialFor(r.serverId) != null ? r : null;
    final current = onLogin(session.media?.jellyfin);
    final upNext = onLogin(next?.call());
    if (current == null && upNext == null) return _plain(404);
    final ref = [current, upNext].firstWhere((r) => r != null && _sameItemId(itemId, r.itemId), orElse: () => null);
    if (ref == null) return _plain(403);
    final cred = credentialFor(ref.serverId)!;

    final range = req.headers['range']?.join(',');
    final HttpClientRequest upReq;
    final HttpClientResponse upRes;
    try {
      upReq = await client().getUrl(jellyfinStaticStreamUri(cred, ref)).timeout(timeout);
      upReq.followRedirects = false;
      upReq.headers
        ..set(HttpHeaders.authorizationHeader, cred.clientInfo.authorizationHeader(cred.token))
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null && range.isNotEmpty) upReq.headers.set(HttpHeaders.rangeHeader, range);
      upRes = await upReq.close().timeout(timeout);
    } catch (e) {
      _relayLog.warning('upstream ${ref.itemId}: $e');
      onLog?.call(token, MediaLog(method: req.method.name, path: '/j/$sid/$itemId', rangeHeader: range,
          status: 502, bytesWritten: 0, durationMs: stopwatch.elapsedMilliseconds));
      return _plain(502);
    }

    void log(int status, int bytes) => onLog?.call(
        token,
        MediaLog(
          method: req.method.name,
          path: '/j/$sid/$itemId',
          rangeHeader: range,
          status: status,
          bytesWritten: bytes,
          durationMs: stopwatch.elapsedMilliseconds,
        ));

    if (upRes.statusCode == 401 || upRes.statusCode == 403) {
      _relayLog.warning('upstream ${ref.itemId}: ${upRes.statusCode} (server credential rejected)');
      await upRes.listen(null).cancel();
      log(502, 0);
      return _plain(502);
    }

    final headers = Headers.build((h) {
      for (final name in const ['content-range', 'accept-ranges']) {
        final v = upRes.headers.value(name);
        if (v != null) h[name] = [v];
      }
    });
    MimeType mime;
    try {
      mime = MimeType.parse(upRes.headers.value(HttpHeaders.contentTypeHeader) ?? '');
    } catch (_) {
      mime = MimeType.octetStream;
    }
    var sent = 0;
    late final StreamController<Uint8List> body;
    StreamSubscription<List<int>>? sub;
    body = StreamController<Uint8List>(
      onListen: () {
        sub = upRes.listen(
          (chunk) {
            session.addBytes(token, chunk.length);
            sent += chunk.length;
            body.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
          },
          onError: (Object e) {
            _relayLog.warning('upstream ${ref.itemId} broke: $e');
            sub = null;
            log(upRes.statusCode, sent);
            body.addError(e);
            unawaited(body.close());
          },
          onDone: () {
            sub = null;
            log(upRes.statusCode, sent);
            unawaited(body.close());
          },
          cancelOnError: true,
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () async {
        // Viewer went away (mpv drops `bytes=N-` on every seek): cancelling
        // an unfinished HttpClientResponse closes its connection, so the
        // upstream transfer stops instead of draining the rest of the file.
        final s = sub;
        sub = null;
        await s?.cancel();
        if (s != null) log(upRes.statusCode, sent);
      },
    );
    return Response(
      upRes.statusCode,
      body: Body.fromDataStream(body.stream,
          mimeType: mime, contentLength: upRes.contentLength >= 0 ? upRes.contentLength : null),
      headers: headers,
    );
  });
}
