import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:test/test.dart';

void main() {
  test('server has zero flutter imports', () async {
    final libDir = Directory('lib');
    final binDir = Directory('bin');
    final offenders = <String>[];
    for (final dir in [libDir, binDir]) {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final content = await entity.readAsString();
        if (content.contains('package:flutter/') || content.contains('dart:ui')) {
          offenders.add(entity.path);
        }
      }
    }
    expect(offenders, isEmpty, reason: 'Flutter imports in server: $offenders');
  });

  test('server starts, answers /health, stops cleanly', () async {
    final server = RoomServer(const AppConfig(port: 0, secret: 't', name: 'test'));
    await server.start();
    expect(server.isRunning, isTrue);
    final port = server.boundPort;
    expect(port, greaterThan(0));

    final client = HttpClient();
    try {
      final req = await client.get('127.0.0.1', port, '/health');
      final resp = await req.close();
      expect(resp.statusCode, 200);
      final body = await resp.transform(const SystemEncoding().decoder).join();
      expect(body, contains('test'));
    } finally {
      client.close();
    }

    await server.stop();
    expect(server.isRunning, isFalse);
  });

  test('unknown path returns 404', () async {
    final server = RoomServer(const AppConfig(port: 0, secret: 't', name: 'test'));
    await server.start();
    final client = HttpClient();
    try {
      final req = await client.get('127.0.0.1', server.boundPort, '/nope');
      final resp = await req.close();
      expect(resp.statusCode, 404);
      await resp.drain();
    } finally {
      client.close();
    }
    await server.stop();
  });
}
