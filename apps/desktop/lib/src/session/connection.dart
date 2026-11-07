import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:signals/signals_core.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/ui.dart' show appName, displayVersion;
import '../state/settings.dart';
import '../sync/sync_client.dart';
import 'app_events.dart';
import 'identity.dart' show ClientIdentity;

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
  /// The profile colour as `#rrggbb` (`hello.user.color`); '' for none.
  final String color;
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
    this.color = '',
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
        color: color,
        mediaPath: mediaPath,
        linkUrl: media == null ? linkUrl : '',
        hostKey: hostKey,
        media: media,
      );

  ConnectParams withProfile({String? name, String? avatar, String? color}) => ConnectParams(
        host: host,
        port: port,
        secret: secret,
        name: name ?? this.name,
        avatar: avatar ?? this.avatar,
        color: color ?? this.color,
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

  /// A welcomed socket is up ([ConnOnline] or [ConnUnstable]): what the
  /// server says is current.
  bool get online => false;
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

/// Welcome received; frames arrive.
final class ConnOnline extends ConnState {
  const ConnOnline();
  @override
  bool get online => true;
  @override
  String toString() => 'online';
}

/// Still the same socket, but nothing came for [Connection.unstableAfter]
/// (the server sends a state every second): the link may be dying. Back
/// to [ConnOnline] with the next frame, [ConnLost] at
/// [Connection.silenceLimit].
final class ConnUnstable extends ConnState {
  const ConnUnstable();
  @override
  bool get online => true;
  @override
  String toString() => 'unstable';
}

/// Dropped (the socket closed, or nothing came for
/// [Connection.silenceLimit]); the next attempt is scheduled. The session
/// keeps what it had (the last state, the player, a relay it serves).
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

/// The server refused this app; nothing retries. [code]: `version` or
/// `secret` when the server said so, `closed` when the host stopped
/// sharing (close 4016), else empty (offline, timeout,
/// anything else on the first dial); [message]: in plain words
/// ([connectErrorText]).
final class ConnRefused extends ConnState {
  final String code;
  final String message;
  const ConnRefused(this.code, this.message);
  @override
  String toString() => 'refused($code: $message)';
}

/// Another connection of this install holds the member (`err` `replaced`,
/// close 4013, or this hello was `stale`): Starsync was opened in another
/// window. Nothing retries ("Retry" takes the member back).
final class ConnReplaced extends ConnState {
  const ConnReplaced();
  String get message => replacedText;
  @override
  String toString() => 'replaced';
}

/// [ConnReplaced] in plain words.
const replacedText = 'Starsync was opened in another window';

/// `ConnRefused('closed')`: the host closed their server to friends
/// (close 4016).
const stoppedSharingText = 'the host stopped sharing their server';

/// A version refusal in plain words: [err] is the server's `err`
/// `version` (its range in `min`/`max`), or a proto 15 server's codeless
/// `proto mismatch`, which is always an older host.
String versionText(ErrorFrame? err) {
  final max = err?.max, min = err?.min;
  if (err?.code == null || (max != null && max < RelayConstants.protoMin)) {
    return 'the host runs an older Starsync — they need to update';
  }
  if (min != null && min > RelayConstants.protoMax) return 'the host runs a newer Starsync — update the app';
  return 'the host runs a different Starsync version — update both apps';
}

/// A failed dial in plain words.
String connectErrorText(Object e) {
  if (e is HelloRefused) {
    final err = e.error;
    if (err != null && err.code == null && err.message.contains('proto mismatch')) return versionText(err);
    return switch (e.code) {
      ErrCode.version => versionText(err),
      ErrCode.secret => 'wrong server password (401)',
      ErrCode.replaced || ErrCode.stale => replacedText,
      _ => 'refused: ${err?.message ?? 'closed (${e.closeCode})'}',
    };
  }
  final msg = '$e';
  if (msg.contains('SocketException') || msg.contains('Connection refused')) {
    return 'host offline — check address and port';
  }
  return 'connect failed: $e';
}

/// The terminal state a failed dial leaves, or null when another attempt
/// may work.
ConnState? _terminalFor(Object e, {required bool first}) {
  if (e is HelloRefused) {
    final err = e.error;
    if (err != null && err.code == null && err.message.contains('proto mismatch')) {
      return ConnRefused('version', versionText(err));
    }
    switch (e.code) {
      case ErrCode.replaced:
      case ErrCode.stale:
        return const ConnReplaced();
      case ErrCode.version:
        return ConnRefused('version', connectErrorText(e));
      case ErrCode.secret:
        return ConnRefused('secret', connectErrorText(e));
      default:
        break;
    }
  }
  return first ? ConnRefused('', connectErrorText(e)) : null;
}

/// What a hello says about this install besides the connect form.
typedef HelloIdentity = ({String client, int seq, ClientCaps caps, int? feedAfter});

/// Builds the `hello` for [params]. Injectable so later protocol versions
/// add fields without changing [Connection].
typedef HelloBuilder = HelloMessage Function(ConnectParams params, HelloIdentity id);

/// Protocol 16's hello: this build's version range, the install's client
/// id and connection count, the app version, platform and what it can do;
/// `feedAfter` on a reconnect to the same server.
HelloMessage defaultHello(ConnectParams params, HelloIdentity id) => HelloMessage(
      proto: RelayConstants.protoMax,
      protoMin: RelayConstants.protoMin,
      secret: params.secret,
      user: HelloUser(name: params.name, avatar: params.avatar, color: params.color),
      hostKey: params.hostKey,
      client: id.client,
      seq: id.seq,
      app: appVersion,
      platform: Platform.operatingSystem,
      caps: id.caps,
      feedAfter: id.feedAfter,
    );

/// How a welcome relates to the member this app held before.
typedef Rejoin = ({
  /// A reconnect of the running session (not its first dial).
  bool reconnect,
  /// `welcome.resumed`: the same member, everything kept.
  bool resumed,
  /// The same server boot as the last welcome (`welcome.instance`).
  bool sameServer,
  /// The token the session held before this welcome ('' on the first).
  String oldToken,
});

/// The session's part of a welcome, called before its state goes out
/// (see [Connection.onWelcome]).
typedef WelcomeHandler = void Function(WelcomeMessage welcome, Rejoin rejoin);

/// The link to the server: the [SyncClient] socket, the first connect,
/// reconnects (backoff with jitter between attempts, epochs that make a
/// cancelled attempt stale), the silence policy ("unstable" after
/// [unstableAfter] without a frame, lost at [silenceLimit]), the 1 s
/// heartbeat (clock ping, which also keeps this member under the
/// server's silence limit, and diagnostics), the connection lost/back
/// events and [state]. The install's identity rides in every hello
/// ([identity]); what a welcome means to the session is its [onWelcome].
class Connection {
  final SyncClient client;
  /// Where [ConnectionLost] / [ConnectionBack] go (the Notifier).
  final void Function(AppEvent event) _notify;
  /// Builds each dial's hello.
  final HelloBuilder hello;
  /// `hello.client` / `hello.seq` (the stored one in the app; a fresh
  /// in-memory one by default, so every test connection is its own
  /// install).
  final ClientIdentity identity;
  /// `hello.caps` at each dial (the session sets it).
  ClientCaps Function() caps;
  /// Wait before the first reconnect attempt; it doubles per failed
  /// attempt up to [maxReconnectDelay], each with ±20 % jitter.
  final Duration reconnectDelay;
  final Duration maxReconnectDelay;
  /// No frame for this long: [ConnUnstable].
  final Duration unstableAfter;
  /// No frame for this long means the connection is lost.
  final Duration silenceLimit;
  /// The lost sound plays only once a drop lasted this long (a quick
  /// reconnect says nothing, and no lost/back pair per flap).
  final Duration lostSoundAfter;
  /// The clock the silence and the lost sound are measured on (UTC; a
  /// test passes a fake one). The heartbeat that checks it stays a real
  /// 1 s timer.
  final DateTime Function() now;
  final Random _random;

  Connection(
      {void Function(AppEvent event)? notify,
      SyncClient? client,
      this.hello = defaultHello,
      ClientIdentity? identity,
      ClientCaps Function()? caps,
      this.reconnectDelay = const Duration(seconds: 1),
      this.maxReconnectDelay = const Duration(seconds: 15),
      this.unstableAfter = const Duration(seconds: 3),
      this.silenceLimit = const Duration(seconds: 9),
      this.lostSoundAfter = const Duration(seconds: 4),
      DateTime Function()? now,
      Random? random})
      : _notify = notify ?? ((_) {}),
        now = now ?? _utcNow,
        identity = identity ?? ClientIdentity.ephemeral(),
        caps = caps ?? (() => const ClientCaps(source: true)),
        _random = random ?? Random(),
        client = client ?? SyncClient() {
    this.client.onFrame = () => _lastFrameAt = this.now();
    _subs = [
      this.client.status.listen(_onStatus),
      this.client.errors.listen(_onError),
    ];
  }

  late final List<StreamSubscription> _subs;

  static DateTime _utcNow() => DateTime.now().toUtc();

  final _state = signal<ConnState>(const ConnClosed());
  /// Every change is notified, a repeat too.
  ReadonlySignal<ConnState> get state => _state;

  /// Set by the session (see [WelcomeHandler]).
  WelcomeHandler? onWelcome;

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

  ConnectParams? _params;
  /// The last connect's parameters (with [updateProfile]'s changes); a
  /// reconnect dials with them.
  ConnectParams? get params => _params;

  // Bumped by every connect/leave/cancel/retry: stale attempts no-op.
  int _epoch = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeat;
  // Set by close/cancel/a terminal refusal: no reconnect, no lost detection.
  bool _closed = false;
  bool _everOnline = false;
  /// The connection-lost sound played; the reconnected one answers it once.
  bool _lostSounded = false;
  DateTime? _lastFrameAt;
  /// When the current drop began (the last frame for a silent link).
  DateTime? _droppedAt;
  int _attempt = 0;
  /// Non-terminal `err` frames, in plain words.
  final _errorTexts = StreamController<String>.broadcast();

  // The socket and what the server said, read through.
  Stream<StateBroadcast> get states => client.states;
  /// Feed entries, chat included; replayed ones after a reconnect.
  Stream<FeedMessage> get feeds => client.feeds;
  Stream<NudgeNotice> get nudges => client.nudges;
  /// `err` frames after the welcome (a `replaced` one ends the connection
  /// instead).
  Stream<String> get errors => _errorTexts.stream;
  String get token => client.token;
  String get memberId => client.memberId;
  /// This member's `/j/...` URL from `welcome`.
  String? get relayUrl => client.relayUrl;
  StateBroadcast? get lastState => client.lastState;
  /// Now on the server's clock (the ping/pong clock offset).
  DateTime serverNow() => client.serverNow();

  void sendTransport(bool play) => client.sendTransport(play);
  void sendContinue({String target = ''}) => client.sendContinue(target: target);
  void sendSeek(double position, {int seq = 0}) => client.sendSeek(position, seq: seq);
  void sendSwap(HelloMedia media, {String? queueId, SwapRestore? restore}) =>
      client.sendSwap(media, queueId: queueId, restore: restore);
  void sendQueue(QueueIntent intent) => client.sendQueue(intent);
  void sendReport({
    required double position,
    required double buffered,
    required int eventId,
    double duration = 0,
    int mediaId = 0,
    Map<String, bool>? jf,
    String error = '',
    double edge = 0,
    double from = 0,
  }) =>
      client.sendReport(
          position: position,
          buffered: buffered,
          eventId: eventId,
          duration: duration,
          mediaId: mediaId,
          jf: jf,
          error: error,
          edge: edge,
          from: from);
  void sendChat(String text) => client.sendChat(text);
  void sendArt(int mediaId, {String? poster, String? banner}) =>
      client.sendArt(mediaId, poster: poster, banner: banner);
  void sendPresence(PresenceIntent intent) => client.sendPresence(intent);
  void sendNudge(String target) => client.sendNudge(target);

  /// Name, picture and/or colour change for everyone now; reconnects send
  /// them too.
  void updateProfile({String? name, String? avatar, String? color}) {
    _params = _params?.withProfile(name: name, avatar: avatar, color: color);
    client.sendProfile(name: name, avatar: avatar, color: color);
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

  /// A new session with [params]: forgets the last one's server and
  /// starts the diagnostics. [dial] connects.
  void begin(ConnectParams params) {
    _params = params;
    _closed = false;
    _everOnline = false;
    _lostSounded = false;
    _droppedAt = null;
    _attempt = 0;
    diag
      ..share = AppSettings.instance.shareDiagnostics.peek()
      ..start();
  }

  /// The first dial of the session [begin] started. Throws
  /// [ConnectCancelled] when [epoch] went stale meanwhile (whoever bumped
  /// it also closed the socket); any other failure leaves [state] refused
  /// (or replaced).
  Future<WelcomeMessage> dial(int epoch) async {
    final params = _params!;
    _set(const ConnConnecting());
    try {
      final welcome = await _connect(params, reconnect: false);
      if (epoch != _epoch) throw const ConnectCancelled();
      _online();
      return welcome;
    } catch (e) {
      if (epoch != _epoch) throw const ConnectCancelled();
      debugPrint('connect failed: $e');
      _set(_terminalFor(e, first: true)!);
      rethrow;
    }
  }

  Future<WelcomeMessage> _connect(ConnectParams params, {required bool reconnect}) {
    final oldToken = client.token;
    final before = client.instance;
    final id = (
      client: identity.clientId,
      seq: identity.nextSeq(),
      caps: caps(),
      feedAfter: reconnect && before.isNotEmpty && client.lastFeedSeq > 0 ? client.lastFeedSeq : null,
    );
    return client.connectWith(
      wsUri: _wsUri(params),
      hello: hello(params, id),
      onWelcome: (w) {
        _lastFrameAt = now();
        onWelcome?.call(w, (
          reconnect: reconnect,
          resumed: w.resumed,
          sameServer: before.isNotEmpty && before == w.instance,
          oldToken: oldToken,
        ));
      },
    );
  }

  static Uri _wsUri(ConnectParams p) => Uri.parse('ws://${p.host}:${p.port}/sync');

  void _online() {
    _attempt = 0;
    _everOnline = true;
    _droppedAt = null;
    if (_lostSounded) {
      _lostSounded = false;
      _notify(const ConnectionBack());
    }
    _lastFrameAt = now();
    _set(const ConnOnline());
    _heartbeat ??= Timer.periodic(const Duration(seconds: 1), (_) => _beat());
  }

  void _set(ConnState s) => _state.set(s, force: true);

  void _onStatus(SyncStatus s) {
    // Before the first welcome a close is just the dial failing; during a
    // reconnect attempt the attempt reports it. A socket error (a reset
    // link) may come without a close.
    if (s != SyncStatus.closed && s != SyncStatus.error) return;
    if (_closed || !_everOnline || !_state.peek().online) return;
    switch (s == SyncStatus.closed ? client.closeCode : null) {
      case CloseCodes.replaced:
      case CloseCodes.stale:
        _end(const ConnReplaced());
      case CloseCodes.version:
        _end(ConnRefused('version', versionText(null)));
      case CloseCodes.secret:
        _end(const ConnRefused('secret', 'wrong server password (401)'));
      case CloseCodes.closed:
        _end(const ConnRefused('closed', stoppedSharingText));
      default:
        _dropped(now());
    }
  }

  void _onError(ErrorFrame e) {
    if (e.code == ErrCode.replaced) {
      _end(const ConnReplaced());
      return;
    }
    if (!_errorTexts.isClosed) _errorTexts.add(e.message);
  }

  /// A terminal state: no more attempts, the socket goes.
  void _end(ConnState s) {
    debugPrint('connection ended: $s');
    _halt(s);
    unawaited(client.drop());
  }

  /// Lost since [since]: the socket goes, a reconnect is scheduled (unless
  /// one already is or dials).
  void _dropped(DateTime since) {
    if (_closed || _state.peek().retrying) return;
    _droppedAt = since;
    unawaited(client.drop());
    scheduleReconnect();
  }

  /// Every second once online: a ping (a clock sample; it also keeps this
  /// member under the server's silence limit while nothing else is sent),
  /// the diagnostics, the silence check and the delayed lost sound.
  void _beat() {
    final t = now();
    final s = _state.peek();
    if (s.online) client.sendPing();
    diag
      ..share = AppSettings.instance.shareDiagnostics.peek()
      ..tick();
    if (_closed) return;
    final last = _lastFrameAt;
    if (s.online && last != null) {
      final quiet = t.difference(last);
      if (quiet >= silenceLimit) {
        debugPrint('connection: nothing for ${quiet.inSeconds} s; reconnecting');
        _dropped(last);
      } else if (quiet >= unstableAfter) {
        if (s is ConnOnline) _set(const ConnUnstable());
      } else if (s is ConnUnstable) {
        _set(const ConnOnline());
      }
    }
    final since = _droppedAt;
    if (_state.peek().retrying && since != null && !_lostSounded && t.difference(since) >= lostSoundAfter) {
      _lostSounded = true;
      _notify(const ConnectionLost());
    }
  }

  /// Reconnect after the backoff ([state] lost), unless closed, never
  /// online (unless [manual]) or already retrying.
  void scheduleReconnect({bool manual = false}) {
    if (_closed || _params == null) return;
    if (!manual && !_everOnline) return;
    if (_state.peek().retrying) return;
    _droppedAt ??= now();
    _set(const ConnLost());
    _armReconnect();
  }

  /// The wait before attempt [attempt] (1 = the first after a drop).
  Duration delayFor(int attempt) {
    final base = reconnectDelay.inMilliseconds * pow(2, max(0, attempt - 1));
    final capped = min(base.toDouble(), maxReconnectDelay.inMilliseconds.toDouble());
    return Duration(milliseconds: (capped * (0.8 + 0.4 * _random.nextDouble())).round());
  }

  void _armReconnect() {
    final epoch = _epoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delayFor(_attempt + 1), () => _reconnect(epoch));
  }

  /// One reconnect attempt. An attempt from an older epoch must not touch
  /// state (it would kill the newer connection).
  Future<void> _reconnect(int epoch) async {
    _reconnectTimer = null;
    bool stale() => epoch != _epoch;
    final params = _params;
    if (stale() || params == null || _closed) return;
    try {
      _set(ConnReconnecting(++_attempt));
      await _connect(params, reconnect: true);
      // Whoever bumped the epoch also closed (or replaced) the socket.
      if (stale()) return;
      _online();
    } catch (e) {
      if (stale()) return;
      debugPrint('reconnect failed: $e');
      final end = _terminalFor(e, first: false);
      if (end != null) {
        _end(end);
      } else {
        _retryAfterFailure(e);
      }
    }
  }

  void _retryAfterFailure(Object e) {
    if (_closed) {
      _set(const ConnClosed());
    } else if (!_everOnline) {
      // Only a manual retry before any welcome gets here.
      _set(_terminalFor(e, first: true)!);
    } else {
      if (!_state.peek().retrying) _set(const ConnLost());
      _armReconnect();
    }
  }

  /// "Stop reconnecting": no more attempts; one dialling is aborted.
  void cancelReconnect() {
    _halt(const ConnClosed());
    unawaited(client.drop());
  }

  /// Cancel during setup: aborts the dial.
  Future<void> cancelConnect() async {
    _halt(const ConnClosed());
    try {
      await client.drop();
    } catch (_) {}
  }

  void _halt(ConnState s) {
    _closed = true;
    invalidate();
    _heartbeat?.cancel();
    _heartbeat = null;
    _set(s);
  }

  /// "Retry": a reconnect after the first backoff whatever the state
  /// (after [ConnReplaced] it takes the member back from the other
  /// window). False without a session to retry.
  bool retry() {
    if (_params == null) return false;
    invalidate();
    _closed = false;
    _attempt = 0;
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

  /// [stop], the last diagnostics (before the token goes), with [bye] the
  /// member's `bye` (flushed: the server's close is awaited briefly), then
  /// the socket.
  Future<void> close({bool bye = false}) async {
    stop();
    await diag.stop();
    // A welcomed socket still open (a dead one costs the short wait).
    if (bye && client.isOpen && client.token.isNotEmpty) await client.sendBye();
    try {
      await client.disconnect();
    } catch (_) {}
  }

  Future<void> dispose() async {
    stop();
    for (final s in _subs) {
      await s.cancel();
    }
    await _errorTexts.close();
    await client.dispose();
  }
}
