import 'dart:convert';
import 'dart:io';

/// One request the fake server saw.
class SeenRequest {
  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final String body;
  SeenRequest(this.method, this.uri, this.headers, this.body);
}

typedef FakeRoute = Future<void> Function(SeenRequest req, HttpResponse res);

/// A localhost HTTP server for the Schedule clients: [handler] answers,
/// [seen] records every request.
class FakeServer {
  FakeServer._(this._server) : url = 'http://${_server.address.host}:${_server.port}';
  final HttpServer _server;
  /// Kept after [close], so clients can try an address nobody answers.
  final String url;
  final seen = <SeenRequest>[];
  late FakeRoute handler;

  static Future<FakeServer> start(FakeRoute handler) async {
    final s = FakeServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0))..handler = handler;
    s._server.listen((req) async {
      final body = await utf8.decodeStream(req);
      final r = SeenRequest(req.method, req.uri, req.headers, body);
      s.seen.add(r);
      try {
        await s.handler(r, req.response);
      } catch (e, st) {
        // ignore: avoid_print
        print('fake server handler failed: $e\n$st');
        req.response.statusCode = 599;
      }
      await req.response.close();
    });
    return s;
  }

  Future<void> close() => _server.close(force: true);
}

void json(HttpResponse res, Object? body, {int status = 200, String? etag}) {
  res.statusCode = status;
  res.headers.contentType = ContentType.json;
  if (etag != null) res.headers.set(HttpHeaders.etagHeader, etag);
  res.write(jsonEncode(body));
}
