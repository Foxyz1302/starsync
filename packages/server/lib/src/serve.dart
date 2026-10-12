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
/// `{'t':'log','level','logger','message'[,'error'][,'stack']}`. Sending
/// `{'t':'stop'}` to the `stop` port stops the server; the returned future
/// completes once it is down. `{'t':'file','path':p,'reply':SendPort}` makes
/// a file on this machine the hosted file (the hosting app's in-session file
/// swap; a following `swap` with its name and size puts it up) and answers
/// `{'ok':true,'name':n,'size':s}` or `{'ok':false}`. Without [events] a
/// start failure throws. `'loopbackOnly': true` in [config] (next to the
/// [AppConfig] keys) binds 127.0.0.1 only: the app's solo session.
Future<void> serve(Map<String, Object?> config, {SendPort? events}) async {
  StreamSubscription<pkg_logging.LogRecord>? logs;
  if (events != null) {
    logs = pkg_logging.Logger.root.onRecord.listen((r) => events.send({
          't': 'log',
          'level': r.level.name,
          'logger': r.loggerName,
          'message': r.message,
          if (r.error != null) 'error': '${r.error}',
          if (r.stackTrace != null) 'stack': '${r.stackTrace}',
        }));
  }
  final SyncServer server;
  try {
    server = SyncServer(AppConfig.fromMap(config), loopbackOnly: config['loopbackOnly'] == true);
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
    if (msg is! Map) continue;
    if (msg['t'] == 'stop') break;
    if (msg['t'] == 'file' && msg['path'] is String && msg['reply'] is SendPort) {
      final reply = msg['reply'] as SendPort;
      try {
        final ok = await server.setLocalFile(msg['path'] as String);
        final media = server.session.media;
        reply.send(ok && media != null
            ? {'ok': true, 'name': media.name, 'size': media.size}
            : {'ok': false});
      } catch (_) {
        reply.send({'ok': false});
      }
    }
  }
  control.close();
  await server.stop();
  await logs?.cancel();
}
