import 'dart:convert';
import 'dart:io';

import '../errors.dart';

/// A failed Jellyfin request. [statusCode] is null for network errors.
class JellyfinException extends SyncRelayException {
  final int? statusCode;
  const JellyfinException(super.message, {this.statusCode});

  /// 401: the token is missing, expired or was revoked (sign in again).
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() =>
      'JellyfinException${statusCode == null ? '' : ' $statusCode'}: $message';
}

class JellyfinHttpResponse {
  final int statusCode;
  final String body;
  const JellyfinHttpResponse(this.statusCode, this.body);

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// The transport [JellyfinClient] talks through. Tests inject a fake; the
/// default is [IoJellyfinHttp].
abstract class JellyfinHttp {
  /// Sends one request. [body] is sent as-is (JSON when non-null). A POST
  /// always carries a Content-Length, even when empty: Jellyfin behind nginx
  /// answers 400 to a body-less POST without one (seen on
  /// /QuickConnect/Initiate).
  Future<JellyfinHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  });

  void close();
}

class IoJellyfinHttp implements JellyfinHttp {
  final HttpClient _client;
  final Duration timeout;

  IoJellyfinHttp({HttpClient? client, this.timeout = const Duration(seconds: 20)})
      : _client = client ?? HttpClient();

  @override
  Future<JellyfinHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    try {
      final req = await _client.openUrl(method, uri).timeout(timeout);
      headers.forEach(req.headers.set);
      final bytes = body == null ? const <int>[] : utf8.encode(body);
      if (body != null) {
        req.headers.contentType = ContentType.json;
      }
      if (method != 'GET' && method != 'HEAD') {
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      return JellyfinHttpResponse(res.statusCode, text);
    } on Object catch (e) {
      throw JellyfinException('$method ${uri.path}: $e');
    }
  }

  @override
  void close() => _client.close(force: true);
}
