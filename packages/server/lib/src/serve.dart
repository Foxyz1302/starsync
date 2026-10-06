import 'dart:async';
import 'dart:isolate';

import 'package:logging/logging.dart' as pkg_logging;
import 'package:sync_relay_core/core.dart';

import 'sync_server.dart';

/// The one server entrypoint: the dedicated binary and the app's hosting
/// isolate both run this. [config] holds primitives only (an
/// [AppConfig.toMap]) so it can cross an isolate boundary.
///
/// On [events] it reports `{'t':'ready','port':p,'stop':SendPort}` or
/// `{'t':'error','message':m}`, and forwards log records as
/// `{'t':'log','level','logger','message'[,'error']}`. Sending
/// `{'t':'stop'}` to the `stop` port stops the server; the returned future
/// completes once it is down. Without [events] a start failure throws.
Future<void> serve(Map<String, Object?> config, {SendPort? events}) async {
  StreamSubscription<pkg_logging.LogRecord>? logs;
  if (events != null) {
    logs = pkg_logging.Logger.root.onRecord.listen((r) => events.send({
          't': 'log',
          'level': r.level.name,
          'logger': r.loggerName,
          'message': r.message,
          if (r.error != null) 'error': '${r.error}',
        }));
  }
  final SyncServer server;
  try {
    server = SyncServer(AppConfig.fromMap(config));
    await server.start();
  } catch (e) {
    await logs?.cancel();
    if (events == null) rethrow;
    events.send({'t': 'error', 'message': '$e'});
    return;
  }
  final control = ReceivePort('serve control');
  events?.send({'t': 'ready', 'port': server.boundPort, 'stop': control.sendPort});
  await for (final msg in control) {
    if (msg is Map && msg['t'] == 'stop') break;
  }
  control.close();
  await server.stop();
  await logs?.cancel();
}
