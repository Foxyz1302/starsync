import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

Future<void> _run((Map<String, Object?>, SendPort) args) =>
    serve(args.$1, events: args.$2);

void main() {
  test('serve in a real isolate: ready, /health, stop, clean exit', () async {
    final events = ReceivePort();
    final exit = ReceivePort();
    final errors = ReceivePort();
    final config = const AppConfig(port: 0, secret: '', name: 'iso', hostKey: 'hk').toMap();
    await Isolate.spawn(_run, (config, events.sendPort),
        onExit: exit.sendPort, onError: errors.sendPort);
    final crashes = <Object?>[];
    errors.listen(crashes.add);
    final logs = <Map>[];
    final ready = Completer<Map>();
    events.listen((m) {
      if (m is! Map) return;
      if (m['t'] == 'log') logs.add(m);
      if (m['t'] == 'ready' && !ready.isCompleted) ready.complete(m);
      if (m['t'] == 'error' && !ready.isCompleted) ready.completeError('${m['message']}');
    });
    final r = await ready.future.timeout(const Duration(seconds: 10));
    final port = r['port'] as int;
    expect(port, greaterThan(0));

    final http = HttpClient();
    final resp = await (await http.get('127.0.0.1', port, '/health')).close();
    final body = jsonDecode(await resp.transform(utf8.decoder).join()) as Map;
    http.close();
    expect(body['ok'], isTrue);
    expect(body['name'], 'iso');
    expect(body['proto'], RelayConstants.protoVersion);
    expect(logs.any((l) => '${l['message']}'.contains('listening on $port')), isTrue);

    (r['stop'] as SendPort).send({'t': 'stop'});
    await exit.first.timeout(const Duration(seconds: 10));
    expect(crashes, isEmpty);
    // The port is free again.
    final again = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await again.close();
    events.close();
    errors.close();
  });

  test('serve: the file control message makes a local file the hosted one', () async {
    final events = ReceivePort();
    final exit = ReceivePort();
    final dir = Directory.systemTemp.createTempSync('serve_file_');
    final file = File('${dir.path}/ep 2.mkv')..writeAsBytesSync(List.filled(1000, 1));
    await Isolate.spawn(_run, (const AppConfig(port: 0, secret: '', name: 'f').toMap(), events.sendPort),
        onExit: exit.sendPort);
    final ready = await events.firstWhere((m) => m is Map && m['t'] == 'ready') as Map;
    final stop = ready['stop'] as SendPort;
    Future<Object?> ask(String path) async {
      final reply = ReceivePort();
      stop.send({'t': 'file', 'path': path, 'reply': reply.sendPort});
      final r = await reply.first.timeout(const Duration(seconds: 5));
      reply.close();
      return r;
    }

    expect(await ask(file.path), {'ok': true, 'name': 'ep 2.mkv', 'size': 1000});
    expect(await ask('${dir.path}/missing.mkv'), {'ok': false});
    stop.send({'t': 'stop'});
    await exit.first.timeout(const Duration(seconds: 10));
    events.close();
    dir.deleteSync(recursive: true);
  });

  test('serve reports a bind failure as an error event', () async {
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final events = ReceivePort();
    final exit = ReceivePort();
    await Isolate.spawn(
        _run,
        (AppConfig(port: blocker.port, secret: '', name: 'x').toMap(),
            events.sendPort),
        onExit: exit.sendPort);
    final first = await events
        .firstWhere((m) => m is Map && m['t'] != 'log')
        .timeout(const Duration(seconds: 10)) as Map;
    expect(first['t'], 'error');
    await exit.first.timeout(const Duration(seconds: 10));
    await blocker.close();
  });
}
