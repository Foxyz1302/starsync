import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';
import 'package:starsync/src/sync/state_diff.dart';
import 'package:starsync/src/sync/sync_client.dart';

Future<void> _poll(FutureOr<bool> Function() cond, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  fail('timed out waiting for $what');
}

void main() {
  test('a client whose clock is 3 s off still extrapolates the server position',
      () async {
    final server = SyncServer(const AppConfig(port: 0, secret: '', name: 'clk'));
    await server.start();
    const skew = Duration(seconds: 3);
    final client = SyncClient(clock: () => DateTime.now().toUtc().add(skew));
    try {
      await client.connect(
          wsUri: Uri.parse('ws://127.0.0.1:${server.boundPort}/sync'),
          secret: '',
          name: 'skewed');
      client.sendReady(true);
      client.sendReport(position: 0, buffered: 10, eventId: 0);
      await _poll(() => client.lastState?.transport == 'playing', 'playing');
      for (var i = 0; i < 5; i++) {
        client.sendPing();
        await Future.delayed(const Duration(milliseconds: 50));
      }
      await _poll(() => client.clockSync.hasSample, 'a pong');
      expect(client.clockSync.offsetMs, closeTo(-skew.inMilliseconds, 50));
      final st = client.lastState!;
      final truth = server.hub.engine.positionAt();
      // The bug: extrapolating with the local clock is off by the skew.
      final naive = serverPositionAt(st, DateTime.now().toUtc().add(skew));
      expect(naive - truth, closeTo(3, 0.1));
      // The fix: extrapolate on the server's clock.
      final corrected = serverPositionAt(st, client.serverNow());
      expect(corrected, closeTo(truth, 0.1));
    } finally {
      await client.dispose();
      await server.stop();
    }
  });
}
