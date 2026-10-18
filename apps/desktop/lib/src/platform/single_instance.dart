import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

/// What a second start hands to the running app: its arguments (a
/// clicked `starsync://` link) and the desktop's activation token for
/// bringing the window up (Linux: `XDG_ACTIVATION_TOKEN` /
/// `DESKTOP_STARTUP_ID`; '' when none).
typedef Handoff = ({List<String> args, String activation});

const _lockName = 'instance.lock';
const _infoName = 'instance.json';

/// Lock paths this process holds: a second claim from the same process
/// (tests) sees them held, as another process would.
final _heldHere = <String>{};

/// One app per profile folder at a time. The first start holds an
/// exclusive lock on `instance.lock` in [dir] (the OS drops it when the
/// process ends, a crash too) and listens on a loopback port written to
/// `instance.json` with a random token. A later start finds the lock
/// held, sends its [Handoff] there and ends; the running app comes to
/// the front and handles it ([handoffs]). Pure dart:io: the same on
/// Linux (Wayland and X11) and Windows.
class InstanceLock {
  InstanceLock._(this.dir, this._lock, this._server, this._token);

  /// The profile folder (each `STARSYNC_PROFILE` has its own, so each is
  /// its own instance).
  final String dir;
  final RandomAccessFile? _lock;
  final ServerSocket? _server;
  final String _token;
  final _handoffs = StreamController<Handoff>();
  bool _closing = false;
  bool _released = false;

  /// What later starts handed over, in order (buffered until listened to).
  Stream<Handoff> get handoffs => _handoffs.stream;

  /// False when the lock could not be had nor the running app reached
  /// (this app runs anyway, as before single instance).
  bool get held => _lock != null;

  /// Claims [dir] for this process, or hands [args] to the app that holds
  /// it: null when handed over (this start should end now). A holder
  /// that is closing (or not listening yet) is retried for [retryFor]
  /// ([closingWait] once it said it is closing, so a start during a close
  /// or an update's restart takes over after it). [beforeSend] gets the
  /// holder's process id first (Windows: allow it to take the
  /// foreground).
  static Future<InstanceLock?> claim(
    String dir, {
    List<String> args = const [],
    String activation = '',
    void Function(int pid)? beforeSend,
    Duration retryFor = const Duration(seconds: 5),
    Duration closingWait = const Duration(seconds: 20),
    Duration retryEvery = const Duration(milliseconds: 200),
  }) async {
    await Directory(dir).create(recursive: true);
    final started = DateTime.now();
    var closingSeen = false;
    while (true) {
      final lock = await _tryLock(dir);
      if (lock != null) return _listen(dir, lock);
      final answer = await _send(dir, (args: args, activation: activation), beforeSend);
      if (answer == _Answer.ok) return null;
      if (answer == _Answer.closing) closingSeen = true;
      final waited = DateTime.now().difference(started);
      if (waited > (closingSeen ? closingWait : retryFor)) {
        debugPrint('single instance: no lock and no answer after ${waited.inMilliseconds} ms; starting anyway');
        return InstanceLock._(dir, null, null, '');
      }
      await Future.delayed(retryEvery);
    }
  }

  static Future<RandomAccessFile?> _tryLock(String dir) async {
    final path = '$dir${Platform.pathSeparator}$_lockName';
    if (_heldHere.contains(path)) return null;
    RandomAccessFile? raf;
    try {
      raf = await File(path).open(mode: FileMode.append);
      await raf.lock(FileLock.exclusive);
      _heldHere.add(path);
      return raf;
    } catch (_) {
      if (raf != null) await _quiet(raf.close());
      return null;
    }
  }

  static Future<InstanceLock> _listen(String dir, RandomAccessFile lock) async {
    final token = base64Url.encode([for (var i = 0; i < 18; i++) Random.secure().nextInt(256)]);
    ServerSocket? server;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await File('$dir${Platform.pathSeparator}$_infoName')
          .writeAsString(jsonEncode({'port': server.port, 'token': token, 'pid': pid}), flush: true);
    } catch (e) {
      debugPrint('single instance: cannot listen for later starts: $e');
    }
    final self = InstanceLock._(dir, lock, server, token);
    server?.listen(self._serve, onError: (Object e) => debugPrint('single instance: $e'));
    return self;
  }

  Future<void> _serve(Socket socket) async {
    try {
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 3));
      if (line.length > 64 * 1024) throw const FormatException('too long');
      final j = jsonDecode(line);
      if (j is! Map || j['token'] != _token) {
        socket.writeln(jsonEncode({'ok': false}));
      } else if (_closing) {
        socket.writeln(jsonEncode({'closing': true}));
      } else {
        final args = j['args'];
        final activation = j['activation'];
        _handoffs.add((
          args: [if (args is List) for (final a in args) if (a is String) a],
          activation: activation is String ? activation : '',
        ));
        socket.writeln(jsonEncode({'ok': true}));
      }
      await socket.flush();
    } catch (e) {
      debugPrint('single instance: a later start sent nothing usable (${e.runtimeType})');
    } finally {
      await _quiet(socket.close());
    }
  }

  static Future<_Answer> _send(String dir, Handoff h, void Function(int pid)? beforeSend) async {
    Socket? socket;
    try {
      final info = jsonDecode(await File('$dir${Platform.pathSeparator}$_infoName').readAsString());
      final port = info is Map ? info['port'] : null;
      final token = info is Map ? info['token'] : null;
      final holder = info is Map ? info['pid'] : null;
      if (port is! int || token is! String) return _Answer.none;
      if (holder is int) beforeSend?.call(holder);
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 2));
      socket.writeln(jsonEncode({'token': token, 'args': h.args, 'activation': h.activation}));
      await socket.flush();
      final reply = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 3));
      final r = jsonDecode(reply);
      if (r is Map && r['ok'] == true) return _Answer.ok;
      if (r is Map && r['closing'] == true) return _Answer.closing;
      return _Answer.none;
    } catch (_) {
      // Not written yet, a stale one from a crash, or not listening yet.
      return _Answer.none;
    } finally {
      socket?.destroy();
    }
  }

  /// The app is closing: later starts are told so and wait for the lock
  /// instead of handing over to an app on its way out.
  void closing() => _closing = true;

  /// Gives the folder up before this process ends (Update and restart:
  /// the new binary claims it at once).
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _closing = true;
    await _server?.close();
    final lock = _lock;
    if (lock == null) return;
    try {
      await File('$dir${Platform.pathSeparator}$_infoName').delete();
    } catch (_) {}
    try {
      await lock.unlock();
    } catch (_) {}
    await _quiet(lock.close());
    _heldHere.remove('$dir${Platform.pathSeparator}$_lockName');
    unawaited(_handoffs.close());
  }

  @visibleForTesting
  int? get port => _server?.port;
}

enum _Answer { ok, closing, none }

Future<void> _quiet(Future<Object?> f) async {
  try {
    await f;
  } catch (_) {}
}
