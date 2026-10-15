import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:signals/signals_core.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/ui.dart' show appName, displayVersion;
import '../state/settings.dart';
import '../sync/sync_client.dart';
import 'app_events.dart';

/// Thrown when a connect is superseded by cancel/leave before it finished.
class ConnectCancelled implements Exception {
  const ConnectCancelled();
  @override
  String toString() => 'connection cancelled';
}

class ConnectParams {
  final String host;
  final int port;
  final String secret;
  final String name;
  final String avatar;
  final String mediaPath;
  final String linkUrl;
  /// Sent in hello by the hosting app's own client (see AppConfig.hostKey).
  final String hostKey;
  /// Put up with a `swap` right after joining (a Jellyfin ref or a link);
  /// wins over [linkUrl].
  final HelloMedia? media;
  const ConnectParams({
    required this.host,
    required this.port,
    required this.secret,
    required this.name,
    this.avatar = '',
    this.mediaPath = '',
    this.linkUrl = '',
    this.hostKey = '',
    this.media,
  });

  ConnectParams withMedia(HelloMedia? media) => ConnectParams(
        host: host,
        port: port,
        secret: secret,
        name: name,
        avatar: avatar,
        mediaPath: mediaPath,
        linkUrl: media == null ? linkUrl : '',
        hostKey: hostKey,
        media: media,
      );

  ConnectParams withProfile({String? name, String? avatar}) => ConnectParams(
        host: host,
        port: port,
        secret: secret,
        name: name ?? this.name,
        avatar: avatar ?? this.avatar,
        mediaPath: mediaPath,
        linkUrl: linkUrl,
        hostKey: hostKey,
        media: media,
      );
}

/// Where the [Connection] is. Each change is a new value (a repeat is
/// notified too).
sealed class ConnState {
  const ConnState();

  /// The reconnect loop runs ([ConnLost] or [ConnReconnecting]).
  bool get retrying => false;
}

/// Not connected and not trying: before the first connect, after leave,
/// cancel or "stop reconnecting".
final class ConnClosed extends ConnState {
  const ConnClosed();
  @override
  String toString() => 'closed';
}

/// The first dial of a session (hello sent, waiting for welcome).
final class ConnConnecting extends ConnState {
  const ConnConnecting();
  @override
  String toString() => 'connecting';
}

/// Welcome received.
final class ConnOnline extends ConnState {
  const ConnOnline();
  @override
  String toString() => 'online';
}

/// Dropped (the socket closed, or no state for [Connection.silenceLimit]);
/// the next attempt is scheduled.
final class ConnLost extends ConnState {
  const ConnLost();
  @override
  bool get retrying => true;
  @override
  String toString() => 'lost';
}

/// Reconnect attempt [attempt] (1 is the first after the drop) is
/// dialling; after it failed it stays until the next one, unless the
/// socket's close said [ConnLost] meanwhile.
final class ConnReconnecting extends ConnState {
  final int attempt;
  const ConnReconnecting(this.attempt);
  @override
  bool get retrying => true;
  @override
  String toString() => 'reconnecting($attempt)';
}

/// The first dial failed; nothing retries. [code]: `version` or `secret`
/// when the server said so, else empty (offline, timeout, anything else);
/// [message]: in plain words ([connectErrorText]).
final class ConnRefused extends ConnState {
  final String code;
  final String message;
  const ConnRefused(this.code, this.message);
  @override
  String toString() => 'refused($code: $message)';
}

/// Another socket took this member over. Not produced yet (protocol 16
/// adds the `replaced` refusal).
final class ConnReplaced extends ConnState {
  const ConnReplaced();
  @override
  String toString() => 'replaced';
}

/// A failed dial in plain words.
String connectErrorText(Object e) {
  final msg = '$e';
  if (msg.contains('proto mismatch')) return 'host runs a different version — update the app';
  if (msg.contains('wrong secret')) return 'wrong server password (401)';
  if (msg.contains('SocketException') || msg.contains('Connection refused')) {
    return 'host offline — check address and port';
  }
  return 'connect failed: $e';
}

ConnRefused _refused(Object e) {
  final msg = '$e';
  final code = msg.contains('proto mismatch')
      ? 'version'
      : msg.contains('wrong secret')
          ? 'secret'
          : '';
  return ConnRefused(code, connectErrorText(e));
}

/// Builds the `hello` for [params]. Injectable so later protocol versions
/// add fields without changing [Connection].
typedef HelloBuilder = HelloMessage Function(ConnectParams params);

/// Today's hello.
HelloMessage defaultHello(ConnectParams params) => HelloMessage(
      proto: RelayConstants.protoVersion,
      secret: params.secret,
      user: HelloUser(name: params.name, avatar: params.avatar),
      media: const HelloMedia(name: '', size: 0, duration: 0),
      hostKey: params.hostKey,
    );

/// The session's part of a reconnect: called right before an attempt
/// dials (read what to restore then; the welcome's state replaces it). The
/// function it returns runs once that attempt is online; [stale] turns
/// true when a cancel, retry, leave or new connect superseded it. An error
/// there counts as a failed attempt.
typedef ReconnectHandler = Future<void> Function(WelcomeMessage welcome, bool Function() stale) Function();

/// The link to the server: the [SyncClient] socket, the first connect,
/// reconnects ([reconnectDelay] between attempts, the previous token
/// offered as `resume`, epochs that make a cancelled attempt stale), the
/// "no state for [silenceLimit] = lost" policy, the 1 s heartbeat (clock
/// ping, diagnostics), the connection lost/back events and [state]. What
/// a reconnect restores in the session is the [onReconnect] handler's.
class Connection {
  final SyncClient client;
  /// Where [ConnectionLost] / [ConnectionBack] go (the Notifier).
  final void Function(AppEvent event) _notify;
  /// Builds each dial's hello.
  final HelloBuilder hello;
  /// Wait before each reconnect attempt.
  final Duration reconnectDelay;
  /// No state broadcast for this long means the connection is lost.
  final Duration silenceLimit;
  /// The clock [silenceLimit] is measured on (UTC; a test passes a fake
  /// one). The heartbeat that checks it stays a real 1 s timer.
  final DateTime Function() now;

  Connection(
      {void Function(AppEvent event)? notify,
      SyncClient? client,
      this.hello = defaultHello,
      this.reconnectDelay = const Duration(milliseconds: 1500),
      this.silenceLimit = const Duration(seconds: 5),
      DateTime Function()? now})
      : _notify = notify ?? ((_) {}),
        now = now ?? _utcNow,
        client = client ?? SyncClient() {
    _subs = [
      this.client.status.listen(_onStatus),
      this.client.states.listen((_) => _lastStateAt = this.now()),
    ];
  }

  late final List<StreamSubscription> _subs;

  static DateTime _utcNow() => DateTime.now().toUtc();

  final _state = signal<ConnState>(const ConnClosed());
  /// Every change is notified, a repeat too.
  ReadonlySignal<ConnState> get state => _state;

  /// Set by the session (see [ReconnectHandler]).
  ReconnectHandler? onReconnect;

  /// This app's log lines to the server's session log (Settings: "Share
  /// diagnostics with the server"), and "Mark a problem". Runs from
  /// [begin] to [close].
  late final DiagUploader diag = DiagUploader(
      target: _diagTarget, version: '$appName ${displayVersion()} on ${Platform.operatingSystem}');

  DiagTarget? _diagTarget() {
    final uri = client.wsUri;
    if (client.token.isEmpty || uri == null || !client.clockSync.hasSample) return null;
    return (base: DiagUploader.baseOf(uri), token: client.token, offsetMs: client.clockSync.offsetMs);
  }

  /// No state broadcast for [silenceLimit] (checked every second while not
  /// closed): what the server said is stale. Synchronous, before [state]
  /// goes lost.
  Stream<void> get silence => _silence.stream;
  final _silence = StreamController<void>.broadcast(sync: true);

  ConnectParams? _params;
  /// The last connect's parameters (with [updateProfile]'s changes); a
  /// reconnect dials with them.
  ConnectParams? get params => _params;

  // Bumped by every connect/leave/cancel/retry: stale attempts no-op.
  int _epoch = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeat;
  // Set by close/cancel: no reconnect, no lost detection.
  bool _closed = false;
  bool _everOnline = false;
  /// The connection-lost sound played; the reconnected one answers it once.
  bool _lostSounded = false;
  // Token of the current connection, offered as `resume` on reconnect.
  String _resumeToken = '';
  DateTime? _lastStateAt;
  int _attempt = 0;

  // The socket and what the server said, read through.
  Stream<StateBroadcast> get states => client.states;
  /// Feed entries, chat included.
  Stream<FeedMessage> get feeds => client.feeds;
  Stream<NudgeNotice> get nudges => client.nudges;
  /// `err` frames after the welcome.
  Stream<String> get errors => client.errors;
  String get token => client.token;
  String get memberId => client.memberId;
  /// This member's `/j/...` URL from `welcome`.
  String? get relayUrl => client.relayUrl;
  StateBroadcast? get lastState => client.lastState;
  /// Now on the server's clock (the ping/pong clock offset).
  DateTime serverNow() => client.serverNow();

  void sendReady(bool ready, {String source = 'manual'}) => client.sendReady(ready, source: source);
  void sendForce(String target, bool ready) => client.sendForce(target, ready);
  void sendSeek(double position, {int seq = 0}) => client.sendSeek(position, seq: seq);
  void sendSwap(HelloMedia media, {String? queueId}) => client.sendSwap(media, queueId: queueId);
  void sendQueue(QueueIntent intent) => client.sendQueue(intent);
  void sendReport({
    required double position,
    required double buffered,
    required int eventId,
    double duration = 0,
    int mediaId = 0,
    Map<String, bool>? jf,
    String error = '',
  }) =>
      client.sendReport(
          position: position,
          buffered: buffered,
          eventId: eventId,
          duration: duration,
          mediaId: mediaId,
          jf: jf,
          error: error);
  void sendChat(String text) => client.sendChat(text);
  void sendArt(int mediaId, {String? poster, String? banner}) =>
      client.sendArt(mediaId, poster: poster, banner: banner);
  void sendOut(String target, bool out) => client.sendOut(target, out);
  void sendNudge(String target) => client.sendNudge(target);

  /// Name and/or picture change for everyone now; reconnects send them too.
  void updateProfile({String? name, String? avatar}) {
    _params = _params?.withProfile(name: name, avatar: avatar);
    client.sendProfile(name: name, avatar: avatar);
  }

  /// A new epoch: attempts in flight become stale, a scheduled reconnect
  /// is dropped. Returns it.
  int invalidate() {
    _epoch++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    return _epoch;
  }

  /// False once a cancel, retry, leave or new connect followed [epoch].
  bool isCurrent(int epoch) => epoch == _epoch;

  /// A new session with [params]: forgets the last one's resume token and
  /// starts the diagnostics. [dial] connects.
  void begin(ConnectParams params) {
    _params = params;
    _closed = false;
    _everOnline = false;
    _lostSounded = false;
    _resumeToken = '';
    _attempt = 0;
    diag
      ..share = AppSettings.instance.shareDiagnostics.peek()
      ..start();
  }

  /// The first dial of the session [begin] started. Throws
  /// [ConnectCancelled] when [epoch] went stale meanwhile (whoever bumped
  /// it also closed the socket); any other failure leaves [state] refused.
  Future<WelcomeMessage> dial(int epoch) async {
    final params = _params!;
    _set(const ConnConnecting());
    try {
      final welcome = await client.connectWith(wsUri: _wsUri(params), hello: hello(params));
      if (epoch != _epoch) throw const ConnectCancelled();
      _online();
      return welcome;
    } catch (e) {
      if (epoch != _epoch) throw const ConnectCancelled();
      debugPrint('connect failed: $e');
      _set(_refused(e));
      rethrow;
    }
  }

  static Uri _wsUri(ConnectParams p) => Uri.parse('ws://${p.host}:${p.port}/sync');

  /// [hello] offering the previous connection's token.
  HelloMessage _resumeHello(ConnectParams params) {
    final h = hello(params);
    return HelloMessage(
        proto: h.proto, secret: h.secret, user: h.user, media: h.media, hostKey: h.hostKey, resume: _resumeToken);
  }

  void _online() {
    _attempt = 0;
    _everOnline = true;
    if (_lostSounded) {
      _lostSounded = false;
      _notify(const ConnectionBack());
    }
    _resumeToken = client.token;
    _lastStateAt = now();
    _set(const ConnOnline());
    _startHeartbeat();
  }

  void _set(ConnState s) => _state.set(s, force: true);

  void _onStatus(SyncStatus s) {
    // Before the first welcome a close is just the dial failing.
    if (s != SyncStatus.closed || _closed || !_everOnline) return;
    _dropped();
  }

  /// Lost (said again while already retrying), the lost sound once per
  /// drop, and a reconnect unless one is already scheduled or dialling.
  void _dropped() {
    if (_state.peek().retrying) {
      _set(const ConnLost());
    } else {
      scheduleReconnect();
    }
    _soundLost();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) => _beat());
  }

  /// Every second while connected: a clock sample, the diagnostics, and
  /// the silence check.
  void _beat() {
    final t = now();
    if (client.token.isNotEmpty) client.sendPing();
    diag
      ..share = AppSettings.instance.shareDiagnostics.peek()
      ..tick();
    final last = _lastStateAt;
    if (!_closed && last != null && t.difference(last) >= silenceLimit) {
      _silence.add(null);
      if (!_state.peek().retrying) _dropped();
    }
  }

  void _soundLost() {
    if (!_everOnline || _lostSounded) return;
    _lostSounded = true;
    _notify(const ConnectionLost());
  }

  /// Reconnect after [reconnectDelay] ([state] lost), unless closed,
  /// never online (unless [manual]) or already retrying.
  void scheduleReconnect({bool manual = false}) {
    if (_closed || _params == null) return;
    if (!manual && !_everOnline) return;
    if (_state.peek().retrying) return;
    _set(const ConnLost());
    _armReconnect();
  }

  void _armReconnect() {
    final epoch = _epoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () => _reconnect(epoch));
  }

  /// One reconnect attempt. An attempt from an older epoch must not touch
  /// state (it would kill the newer connection and leave a ghost member).
  Future<void> _reconnect(int epoch) async {
    _reconnectTimer = null;
    bool stale() => epoch != _epoch;
    final params = _params;
    if (stale() || params == null || _closed) return;
    final after = onReconnect?.call();
    try {
      _set(ConnReconnecting(++_attempt));
      final welcome = await client.connectWith(wsUri: _wsUri(params), hello: _resumeHello(params));
      // Whoever bumped the epoch also closed (or replaced) the socket.
      if (stale()) return;
      _online();
      if (after != null) await after(welcome, stale);
    } catch (e) {
      if (stale()) return;
      debugPrint('reconnect failed: $e');
      _retryAfterFailure(e);
    }
  }

  void _retryAfterFailure(Object e) {
    if (_closed) {
      _set(const ConnClosed());
    } else if (!_everOnline) {
      // Only a manual retry before any welcome gets here.
      _set(_refused(e));
    } else {
      if (!_state.peek().retrying) _set(const ConnLost());
      _armReconnect();
    }
  }

  /// "Stop reconnecting": no more attempts; one dialling is aborted.
  void cancelReconnect() {
    _halt();
    unawaited(client.disconnect().catchError((_) {}));
  }

  /// Cancel during setup: aborts the dial.
  Future<void> cancelConnect() async {
    _halt();
    try {
      await client.disconnect();
    } catch (_) {}
  }

  void _halt() {
    _closed = true;
    invalidate();
    _heartbeat?.cancel();
    _heartbeat = null;
    _set(const ConnClosed());
  }

  /// "Retry": a reconnect after [reconnectDelay] whatever the state.
  /// False without a session to retry.
  bool retry() {
    if (_params == null) return false;
    invalidate();
    _closed = false;
    _set(const ConnClosed());
    scheduleReconnect(manual: true);
    return true;
  }

  /// No more reconnects or silence checks, [state] closed; the socket
  /// stays until [close] (the session's last words still go out).
  void stop() {
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _set(const ConnClosed());
  }

  /// [stop], the last diagnostics (before the token goes), the socket.
  Future<void> close() async {
    stop();
    await diag.stop();
    try {
      await client.disconnect();
    } catch (_) {}
  }

  Future<void> dispose() async {
    stop();
    for (final s in _subs) {
      await s.cancel();
    }
    await _silence.close();
    await client.dispose();
  }
}
