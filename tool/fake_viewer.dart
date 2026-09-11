import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:sync_relay_core/core.dart';

int _failures = 0;

void check(String name, bool ok, [String detail = '']) {
  // ignore: avoid_print
  print('${ok ? 'PASS' : 'FAIL'} $name${detail.isEmpty ? '' : ' ($detail)'}');
  if (!ok) _failures++;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> main(List<String> args) async {
  var server = 'http://127.0.0.1:8080';
  var secret = 'change-me';
  var name = 'viewer';
  String? expectFile;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--server':
        server = args[++i];
      case '--secret':
        secret = args[++i];
      case '--name':
        name = args[++i];
      case '--file':
        expectFile = args[++i];
    }
  }
  final base = Uri.parse(server);
  final wsUri = base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/sync');

  final ch = WebSocketChannel.connect(wsUri);
  final firstCompleter = Completer<String>();
  final sub = ch.stream.listen(
    (m) {
      if (!firstCompleter.isCompleted) firstCompleter.complete('$m');
    },
    onError: (Object e) {
      if (!firstCompleter.isCompleted) firstCompleter.completeError(e);
    },
  );
  ch.sink.add(jsonEncode({
    't': 'hello',
    'proto': RelayConstants.protoVersion,
    'secret': secret,
    'user': {'name': name},
    'media': {'name': '', 'size': 0, 'duration': 0.0},
  }));
  late Map<String, Object?> welcome;
  try {
    final raw = await firstCompleter.future.timeout(const Duration(seconds: 10));
    welcome = Map<String, Object?>.from(jsonDecode(raw) as Map);
  } catch (e) {
    check('hello -> welcome', false, '$e');
    exitCode = 1;
    return;
  }
  check('hello -> welcome', welcome['t'] == 'welcome', '${welcome['t']}');
  final token = '${welcome['token']}';
  check('token issued', token.length == 32, 'len=${token.length}');
  final mediaUrl = welcome['mediaUrl'] as String?;
  check('mediaUrl present', mediaUrl != null && mediaUrl.contains(token));
  if (mediaUrl == null) {
    exitCode = 1;
    return;
  }
  final mediaUri = Uri.parse(mediaUrl);

  Uint8List? expected;
  if (expectFile != null) expected = await File(expectFile).readAsBytes();
  final client = HttpClient();
  try {
    Future<(HttpClientResponse, List<int>)> get({String? range}) async {
      final req = await client.getUrl(mediaUri);
      if (range != null) req.headers.set('range', range);
      final resp = await req.close();
      final body = <int>[];
      await for (final c in resp) {
        body.addAll(c);
      }
      return (resp, body);
    }

    var (resp, body) = await get();
    check('no-range -> 200', resp.statusCode == 200, '${resp.statusCode}');
    check('accept-ranges', resp.headers.value('accept-ranges') == 'bytes');
    if (expected != null) {
      check('full body byte-exact', _bytesEqual(body, expected),
          'got=${body.length} want=${expected.length}');
    }
    final size = expected?.length ?? int.parse(resp.headers.value('content-length') ?? '0');
    check('size known', size > 0, 'size=$size');

    (resp, body) = await get(range: 'bytes=0-99');
    check('closed range -> 206', resp.statusCode == 206, '${resp.statusCode}');
    check('content-range', resp.headers.value('content-range') == 'bytes 0-99/$size');
    if (expected != null) check('closed bytes exact', _bytesEqual(body, expected.sublist(0, 100)));

    (resp, body) = await get(range: 'bytes=${size - 1000}-');
    check('open-ended -> 206', resp.statusCode == 206, '${resp.statusCode}');
    if (expected != null) {
      check('open-ended bytes exact', _bytesEqual(body, expected.sublist(size - 1000)));
    }

    (resp, body) = await get(range: 'bytes=-256');
    check('suffix tail -> 206', resp.statusCode == 206, '${resp.statusCode}');
    if (expected != null) {
      check('suffix bytes exact', _bytesEqual(body, expected.sublist(size - 256)));
    }

    (resp, body) = await get(range: 'bytes=${size + 100}-${size + 200}');
    check('out-of-range -> 416', resp.statusCode == 416, '${resp.statusCode}');

    final badUri = mediaUri.replace(
        pathSegments: [...mediaUri.pathSegments.take(2), '0' * 32, ...mediaUri.pathSegments.skip(3)]);
    final badReq = await client.getUrl(badUri);
    final badResp = await badReq.close();
    await badResp.drain();
    check('bad token -> 401', badResp.statusCode == 401, '${badResp.statusCode}');
  } finally {
    client.close();
    try {
      await sub.cancel();
    } catch (_) {}
    try {
      await ch.sink.close();
    } catch (_) {}
  }
  // ignore: avoid_print
  print(_failures == 0 ? 'ALL PASS' : '$_failures FAILURES');
  exitCode = _failures == 0 ? 0 : 1;
}
