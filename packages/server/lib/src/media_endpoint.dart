import 'dart:io';
import 'dart:typed_data';

import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';

import 'session.dart';

class MediaLog {
  final String method;
  final String path;
  final String? rangeHeader;
  final int status;
  final int bytesWritten;
  final int durationMs;
  const MediaLog({
    required this.method,
    required this.path,
    required this.rangeHeader,
    required this.status,
    required this.bytesWritten,
    required this.durationMs,
  });

  @override
  String toString() =>
      '$method $path range=${rangeHeader ?? '-'} -> $status bytes=$bytesWritten ${durationMs}ms';
}

class MediaResolution {
  final int status;
  final Map<String, String> headers;
  final int start;
  final int? end;
  const MediaResolution({
    required this.status,
    required this.headers,
    required this.start,
    required this.end,
  });

  int contentLength(int size) => (end ?? (size - 1)) - start + 1;
}

MediaResolution resolveMediaRequest({
  required String? rangeHeader,
  required int size,
  required String filename,
  MediaGate gate = MediaGate.ok,
}) {
  Map<String, String> base(String contentType) => {
        'accept-ranges': 'bytes',
        'content-type': contentType,
      };
  final contentType = contentTypeForFile(filename);
  switch (gate) {
    case MediaGate.gone:
      return MediaResolution(status: 410, headers: base(contentType), start: 0, end: 0);
    case MediaGate.unauthorized:
      return MediaResolution(status: 401, headers: base(contentType), start: 0, end: 0);
    case MediaGate.forbidden:
      return MediaResolution(status: 403, headers: base(contentType), start: 0, end: 0);
    case MediaGate.offline:
      return MediaResolution(
          status: 503,
          headers: {...base(contentType), 'retry-after': '2'},
          start: 0,
          end: 0);
    case MediaGate.ok:
      break;
  }
  if (rangeHeader == null || rangeHeader.trim().isEmpty) {
    return MediaResolution(
      status: 200,
      headers: {...base(contentType), 'content-length': '$size'},
      start: 0,
      end: null,
    );
  }
  final parsed = RangeRequest.parse(rangeHeader, size);
  if (parsed == null) {
    return MediaResolution(
      status: 416,
      headers: {...base(contentType), 'content-range': 'bytes */$size'},
      start: 0,
      end: 0,
    );
  }
  final end = parsed.end ?? size - 1;
  return MediaResolution(
    status: 206,
    headers: {
      ...base(contentType),
      'content-range': 'bytes ${parsed.start}-$end/$size',
      'content-length': '${end - parsed.start + 1}',
    },
    start: parsed.start,
    end: parsed.end,
  );
}

void mountMediaRoute(RelicApp app, File file,
    {String route = '/m/file', void Function(MediaLog log)? onLog}) {
  app.get(route, (final req) async {
    final stopwatch = Stopwatch()..start();
    final size = await file.length();
    final name = file.path.split(Platform.pathSeparator).last;
    final typed = req.headers.range;
    String? rangeHeader;
    if (typed != null && typed.ranges.isNotEmpty) {
      final r = typed.ranges.first;
      rangeHeader = '${typed.unit}=${r.start?.toString() ?? ''}-${r.end?.toString() ?? ''}';
    }
    final res = resolveMediaRequest(rangeHeader: rangeHeader, size: size, filename: name);
    void log(int bytes) => onLog?.call(MediaLog(
          method: req.method.name,
          path: route,
          rangeHeader: rangeHeader,
          status: res.status,
          bytesWritten: bytes,
          durationMs: stopwatch.elapsedMilliseconds,
        ));
    if (res.status != 200 && res.status != 206) {
      log(0);
      return Response(
        res.status,
        body: Body.fromString('status ${res.status}'),
        headers: Headers.build((h) {
          res.headers.forEach((k, v) => h[k] = [v]);
        }),
      );
    }
    final end = res.end ?? size - 1;
    final byteCount = end - res.start + 1;
    final stream = file.openRead(res.start, end + 1).map((c) => Uint8List.fromList(c));
    log(byteCount);
    return Response(
      res.status,
      body: Body.fromDataStream(stream, contentLength: byteCount),
      headers: Headers.build((h) {
        res.headers.forEach((k, v) => h[k] = [v]);
      }),
    );
  });
}

Response _gatedResponse(MediaResolution res) => Response(
      res.status,
      body: Body.fromString('status ${res.status}'),
      headers: Headers.build((h) {
        res.headers.forEach((k, v) => h[k] = [v]);
      }),
    );

void mountSessionMediaRoute(
  RelicApp app,
  SessionMap sessions, {
  String pattern = '/m/:sid/:token/:name',
  void Function(String token, MediaLog log)? onLog,
}) {
  app.get(pattern, (final req) async {
    final stopwatch = Stopwatch()..start();
    final sid = req.pathParameters.raw[#sid] ?? '';
    final token = req.pathParameters.raw[#token] ?? '';
    final session = sessions.get(sid);
    if (session == null) {
      return _gatedResponse(resolveMediaRequest(
          rangeHeader: null, size: 1, filename: 'x', gate: MediaGate.gone));
    }
    final gate = session.gate(token);
    if (gate != MediaGate.ok) {
      return _gatedResponse(
          resolveMediaRequest(rangeHeader: null, size: 1, filename: 'x', gate: gate));
    }
    final media = session.media;
    final file = media?.file;
    if (media == null || file == null) {
      return _gatedResponse(resolveMediaRequest(
          rangeHeader: null, size: 1, filename: 'x', gate: MediaGate.offline));
    }
    final size = media.size;
    final typed = req.headers.range;
    String? rangeHeader;
    if (typed != null && typed.ranges.isNotEmpty) {
      final r = typed.ranges.first;
      rangeHeader = '${typed.unit}=${r.start?.toString() ?? ''}-${r.end?.toString() ?? ''}';
    }
    final res = resolveMediaRequest(rangeHeader: rangeHeader, size: size, filename: media.name);
    if (res.status != 200 && res.status != 206) {
      return _gatedResponse(res);
    }
    final end = res.end ?? size - 1;
    final byteCount = end - res.start + 1;
    final shortToken = token.length > 4 ? '…${token.substring(token.length - 4)}' : token;
    onLog?.call(token, MediaLog(
      method: req.method.name,
      path: '/m/$sid/$shortToken/${media.name}',
      rangeHeader: rangeHeader,
      status: res.status,
      bytesWritten: byteCount,
      durationMs: stopwatch.elapsedMilliseconds,
    ));
    // Count bytes as they are actually sent: mpv often asks for `bytes=N-`
    // and drops the connection early, so the requested range overcounts.
    final stream = file.openRead(res.start, end + 1).map((c) {
      session.addBytes(token, c.length);
      return Uint8List.fromList(c);
    });
    return Response(
      res.status,
      body: Body.fromDataStream(stream, contentLength: byteCount),
      headers: Headers.build((h) {
        res.headers.forEach((k, v) => h[k] = [v]);
      }),
    );
  });
}
