import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';

Future<void> _serverMain((Map<String, Object?>, SendPort) args) =>
    serve(args.$1, events: args.$2);

/// The hosted server, running [serve] on its own isolate. Its log lines
/// go to [onLog]; if the isolate dies without being asked to stop,
/// [onCrash] gets the cause once.
class ServerIsolate {
  final Isolate _isolate;
  final SendPort _stop;
  final int port;
  final ReceivePort _events;
  final ReceivePort _errors;
  final ReceivePort _exit;
  final Completer<void> _exited = Completer<void>();
  bool _stopping = false;
  String? _lastError;
  void Function(String error)? _onCrash;

  ServerIsolate._(this._isolate, this._stop, this.port, this._events,
      this._errors, this._exit);

  @visibleForTesting
  Isolate get isolate => _isolate;

  bool get isRunning => !_exited.isCompleted;

  /// Spawns the server and waits until it listens. Throws a
  /// [StateError] with the server's message if it cannot start.
  /// [loopbackOnly]: 127.0.0.1 only (the solo session).
  static Future<ServerIsolate> start(
    AppConfig config, {
    bool loopbackOnly = false,
    required void Function(String line) onLog,
    required void Function(String error) onCrash,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final events = ReceivePort('server events');
    final errors = ReceivePort('server errors');
    final exit = ReceivePort('server exit');
    final startup = Completer<(int, SendPort)>();
    String? lastError;
    var exited = false;
    ServerIsolate? self;

    void fail(String message) {
      if (!startup.isCompleted) startup.completeError(StateError(message));
    }

    events.listen((msg) {
      if (msg is! Map) return;
      switch (msg['t']) {
        case 'log':
          final err = msg['error'], stack = msg['stack'];
          onLog('${msg['level']} ${msg['logger']}: ${msg['message']}'
              '${err == null ? '' : ' ($err)'}${stack == null ? '' : '\n$stack'}');
        case 'ready':
          if (!startup.isCompleted) {
            startup.complete((msg['port'] as int, msg['stop'] as SendPort));
          }
        case 'error':
          fail('${msg['message']}');
      }
    });
    // errorsAreFatal is off: a stray async error is logged and the server
    // keeps going, as it did in-process. Only a dead isolate is a crash.
    errors.listen((msg) {
      final text = msg is List && msg.isNotEmpty ? '${msg.first}' : '$msg';
      lastError = text;
      self?._lastError = text;
      onLog('SEVERE uncaught: $text');
    });
    exit.listen((_) {
      exited = true;
      fail(lastError ?? 'server exited before it was ready');
      self?._onExit();
    });

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
          _serverMain, ({...config.toMap(), if (loopbackOnly) 'loopbackOnly': true}, events.sendPort),
          errorsAreFatal: false,
          onError: errors.sendPort,
          onExit: exit.sendPort,
          debugName: 'server');
    } catch (_) {
      events.close();
      errors.close();
      exit.close();
      rethrow;
    }
    final (int, SendPort) ready;
    try {
      ready = await startup.future.timeout(timeout);
    } catch (e) {
      if (!exited) isolate.kill(priority: Isolate.immediate);
      events.close();
      errors.close();
      exit.close();
      if (e is TimeoutException) {
        throw StateError('server did not start within ${timeout.inSeconds} s');
      }
      rethrow;
    }
    final s = ServerIsolate._(isolate, ready.$2, ready.$1, events, errors, exit)
      .._onCrash = onCrash
      .._lastError = lastError;
    self = s;
    if (exited) {
      // Died between ready and here: a failed start, not a crash.
      s._stopping = true;
      s._onExit();
      throw StateError(lastError ?? 'server exited right after starting');
    }
    return s;
  }

  void _onExit() {
    if (_exited.isCompleted) return;
    _exited.complete();
    _events.close();
    _errors.close();
    _exit.close();
    final crash = _onCrash;
    _onCrash = null;
    if (!_stopping) crash?.call(_lastError ?? 'the server stopped unexpectedly');
  }

  /// Makes [path] the hosted file (the in-session File swap). Returns its
  /// name and size for the `swap` that puts it up, or null when the file
  /// is missing or the server is gone.
  Future<({String name, int size})?> setFile(String path,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (_exited.isCompleted) return null;
    final reply = ReceivePort('server file');
    try {
      _stop.send({'t': 'file', 'path': path, 'reply': reply.sendPort});
      final msg = await reply.first.timeout(timeout);
      if (msg is Map && msg['ok'] == true) {
        return (name: msg['name'] as String, size: msg['size'] as int);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      reply.close();
    }
  }

  /// Asks the server to close its sockets and exit; kills the isolate if it
  /// has not exited within [timeout].
  Future<void> stop({Duration timeout = const Duration(seconds: 3)}) async {
    if (_exited.isCompleted) return;
    _stopping = true;
    _stop.send({'t': 'stop'});
    try {
      await _exited.future.timeout(timeout);
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
      await _exited.future.timeout(const Duration(seconds: 2),
          onTimeout: _onExit);
    }
  }
}
