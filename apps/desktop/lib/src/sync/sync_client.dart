import 'dart:async';
import 'dart:convert';

import 'package:sync_relay_core/core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum SyncStatus { idle, connecting, open, closed, error }

/// The server refused the hello: its `err` ([error]; a proto 15 server's
/// has no code), or the socket closed before a welcome with [closeCode].
class HelloRefused implements Exception {
  final ErrorFrame? error;
  final int? closeCode;
  const HelloRefused({this.error, this.closeCode});

  /// The refusal's code: the frame's, else read from the close code.
  ErrCode? get code =>
      error?.code ??
      switch (closeCode) {
        CloseCodes.version => ErrCode.version,
        CloseCodes.secret => ErrCode.secret,
        CloseCodes.replaced => ErrCode.replaced,
        CloseCodes.stale => ErrCode.stale,
        _ => null,
      };

  @override
  String toString() => error?.message ?? 'closed before welcome ($closeCode)';
}

/// One `/sync` socket at a time: the hello and welcome, the frames as
/// streams, the sends. [token], [memberId] and [lastState] outlive a
/// dropped socket ([drop]); only [disconnect] forgets them.
class SyncClient {
  /// Local clock; injectable so tests can run a client whose clock is off.
  final DateTime Function() _clock;
  SyncClient({DateTime Function()? clock})
      : _clock = clock ?? (() => DateTime.now().toUtc());

  /// Offset to the server's clock, from ping/pong round trips.
  final ClockSync clockSync = ClockSync();

  /// Now on the server's clock: use this, not the local clock, against
  /// `serverTime` in a state.
  DateTime serverNow() => clockSync.serverNow(_clock());

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Completer<void>? _socketDone;
  final StreamController<StateBroadcast> _states = StreamController.broadcast();
  final StreamController<FeedMessage> _feeds = StreamController.broadcast();
  final StreamController<NudgeNotice> _nudges = StreamController.broadcast();
  final StreamController<ErrorFrame> _errors = StreamController.broadcast();
  final StreamController<SyncStatus> _status = StreamController.broadcast();

  Stream<StateBroadcast> get states => _states.stream;
  /// Feed lines (chat included, with its text), and after a welcome the
  /// lines it replayed (`replayed`).
  Stream<FeedMessage> get feeds => _feeds.stream;
  /// Someone poked this member (`nudge`).
  Stream<NudgeNotice> get nudges => _nudges.stream;
  /// `err` frames after the welcome.
  Stream<ErrorFrame> get errors => _errors.stream;
  Stream<SyncStatus> get status => _status.stream;

  /// Called on every frame from the server (the welcome included), before
  /// it is handled: the connection's silence clock.
  void Function()? onFrame;

  /// The `/sync` URL last dialled; its host serves `/a/...` and the media.
  Uri? wsUri;
  String token = '';
  String memberId = '';
  String? mediaUrl;
  /// This member's `/j/...` URL from `welcome` (Jellyfin media the server
  /// relays); private like [token].
  String? relayUrl;
  StateBroadcast? lastState;
  /// `welcome.instance` of the server last joined: a welcome of another
  /// one is a restarted (or another) server.
  String instance = '';
  /// The highest `feed.seq` seen from [instance] (`hello.feedAfter`).
  int lastFeedSeq = 0;
  /// The close code of the last socket that closed (null: none given).
  int? closeCode;
  Completer<WelcomeMessage>? _pendingWelcome;

  /// A plain hello (tools and tests): [client] / [seq] as given.
  Future<WelcomeMessage> connect({
    required Uri wsUri,
    required String secret,
    required String name,
    String avatar = '',
    String hostKey = '',
    String client = '',
    int seq = 0,
  }) =>
      connectWith(
        wsUri: wsUri,
        hello: HelloMessage(
          secret: secret,
          user: HelloUser(name: name, avatar: avatar),
          hostKey: hostKey,
          client: client,
          seq: seq,
        ),
      );

  /// Dials [wsUri], sends [hello] and waits for the welcome (10 s). A
  /// socket still open is dropped first. [onWelcome] runs once the welcome
  /// is read, before its state and replayed feed go out on the streams.
  /// Throws [HelloRefused] when the server refuses.
  Future<WelcomeMessage> connectWith(
      {required Uri wsUri, required HelloMessage hello, void Function(WelcomeMessage welcome)? onWelcome}) async {
    await drop();
    clockSync.reset();
    closeCode = null;
    this.wsUri = wsUri;
    _status.add(SyncStatus.connecting);
    final ch = WebSocketChannel.connect(wsUri);
    unawaited(ch.ready.then((_) {}, onError: (_) {}));
    _channel = ch;
    final done = _socketDone = Completer<void>();
    final welcomeCompleter = Completer<WelcomeMessage>();
    _sub = ch.stream.listen(
      (raw) => _onText('$raw', welcomeCompleter),
      onError: (Object e, StackTrace st) {
        if (!welcomeCompleter.isCompleted) {
          welcomeCompleter.completeError(e, st);
        }
        _status.add(SyncStatus.error);
      },
      onDone: () {
        closeCode = ch.closeCode;
        if (!done.isCompleted) done.complete();
        if (!welcomeCompleter.isCompleted) {
          welcomeCompleter.completeError(ch.closeCode == null
              ? StateError('closed before welcome')
              : HelloRefused(closeCode: ch.closeCode));
        }
        _status.add(SyncStatus.closed);
      },
      cancelOnError: false,
    );
    ch.sink.add(jsonEncode(hello.toJson()));
    _pendingWelcome = welcomeCompleter;
    try {
      final welcome = await welcomeCompleter.future.timeout(
        const Duration(seconds: 10),
      );
      _pendingWelcome = null;
      final sameServer = instance.isNotEmpty && welcome.instance == instance;
      token = welcome.token;
      memberId = welcome.memberId;
      mediaUrl = welcome.mediaUrl;
      relayUrl = welcome.relayUrl;
      instance = welcome.instance;
      // Another server's lines count from 1 again: its replay is not ours.
      if (!sameServer) lastFeedSeq = 0;
      onWelcome?.call(welcome);
      if (welcome.state != null) {
        try {
          lastState = StateBroadcast.fromJson(welcome.state!);
          _states.add(lastState!);
        } catch (_) {}
      }
      if (sameServer) {
        for (final f in welcome.feed) {
          _addFeed(f.copyWith(replayed: true));
        }
      }
      _status.add(SyncStatus.open);
      sendPing();
      return welcome;
    } catch (e) {
      _pendingWelcome = null;
      await drop();
      _status.add(SyncStatus.error);
      rethrow;
    }
  }

  void _addFeed(FeedMessage f) {
    if (f.seq > lastFeedSeq) lastFeedSeq = f.seq;
    // The server delivers every chat twice: a `chat` frame carrying the
    // text (turned into a feed line below) and a textless feed line. Keep
    // only the former: one send, one row, one toast, one sound.
    if (f.action != 'chat') _feeds.add(f);
  }

  void _onText(String raw, Completer<WelcomeMessage> welcomeCompleter) {
    onFrame?.call();
    Map<String, Object?> decoded;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return;
      decoded = Map<String, Object?>.from(parsed);
    } catch (_) {
      return;
    }
    final t = decoded['t'];
    if (!welcomeCompleter.isCompleted) {
      if (t == 'welcome') {
        try {
          welcomeCompleter.complete(WelcomeMessage.fromJson(decoded));
        } catch (e) {
          welcomeCompleter.completeError(e);
        }
      } else if (t == 'err') {
        ErrorFrame frame;
        try {
          frame = ErrorFrame.fromJson(decoded);
        } catch (_) {
          frame = const ErrorFrame(code: null, message: 'rejected');
        }
        welcomeCompleter.completeError(HelloRefused(error: frame));
      }
      return;
    }
    switch (t) {
      case 'state':
        try {
          final state = StateBroadcast.fromJson(decoded);
          lastState = state;
          _states.add(state);
        } catch (_) {}
      case 'feed':
        try {
          _addFeed(FeedMessage.fromJson(decoded));
        } catch (_) {}
      case 'nudge':
        try {
          _nudges.add(NudgeNotice.fromJson(decoded));
        } catch (_) {}
      case 'pong':
        try {
          final pong = PongMessage.fromJson(decoded);
          clockSync.add(
              sentMs: pong.clientMs,
              serverMs: pong.serverMs,
              receivedMs: _clock().millisecondsSinceEpoch);
        } catch (_) {}
      case 'err':
        try {
          _errors.add(ErrorFrame.fromJson(decoded));
        } catch (_) {}
      case 'chat':
        _feeds.add(
          FeedMessage(
            actor: '${decoded['from'] ?? '?'}',
            actorId: decoded['fromId'] is String ? decoded['fromId'] as String : '',
            action: 'chat',
            reason: (decoded['text'] as String?) ?? '',
            at: DateTime.now().toUtc(),
          ),
        );
    }
  }

  /// A socket is open (it may be half-open: the connection's silence
  /// check tells).
  bool get isOpen => _channel != null;

  void _send(Map<String, Object?> json) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(json));
    } catch (_) {}
  }

  void sendReady(bool ready, {String source = 'manual'}) {
    _send(ReadyIntent(ready: ready, source: source).toJson());
  }

  void sendForce(String target, bool ready) {
    _send(ForceIntent(target: target, ready: ready).toJson());
  }

  void sendSeek(double position, {int seq = 0}) {
    if (position.isNaN || position < 0) return;
    _send(SeekIntent(position: position, seq: seq).toJson());
  }

  /// One clock sample; the connection sends one per second (it also keeps
  /// this member under the server's silence limit).
  void sendPing() {
    _send(PingMessage(clientMs: _clock().millisecondsSinceEpoch).toJson());
  }

  void sendSwap(HelloMedia media, {String? queueId}) {
    _send(SwapIntent(media: media, queueId: queueId).toJson());
  }

  /// One change to Up next (see [QueueIntent]).
  void sendQueue(QueueIntent intent) {
    _send(intent.toJson());
  }

  void sendReport({
    required double position,
    required double buffered,
    required int eventId,
    double duration = 0,
    int mediaId = 0,
    Map<String, bool>? jf,
    String error = '',
  }) {
    final safeBuffered = buffered.isNaN || buffered < 0 ? 0.0 : buffered;
    _send(
      ReportMessage(
        position: position,
        buffered: safeBuffered,
        eventId: eventId,
        duration: duration.isFinite && duration > 0 ? duration : 0,
        mediaId: mediaId,
        jf: jf,
        error: error,
      ).toJson(),
    );
  }

  void sendChat(String text) {
    final clean = text.length > RelayConstants.maxChatLength
        ? text.substring(0, RelayConstants.maxChatLength)
        : text;
    _send(ChatMessage(text: clean).toJson());
  }

  /// Mid-session name/picture change; null leaves it, an empty [avatar]
  /// (base64 PNG) removes the picture.
  void sendProfile({String? name, String? avatar}) {
    if (name == null && avatar == null) return;
    _send(ProfileIntent(name: name, avatar: avatar).toJson());
  }

  /// Art for media [mediaId] (base64 picture bytes; null = none).
  void sendArt(int mediaId, {String? poster, String? banner}) {
    _send(ArtMessage(mediaId: mediaId, poster: poster, banner: banner).toJson());
  }

  /// Sits someone out, or brings this member back in (see [PresenceIntent]).
  void sendPresence(PresenceIntent intent) {
    _send(intent.toJson());
  }

  void sendNudge(String target) {
    _send(NudgeIntent(target: target).toJson());
  }

  /// `bye`: this member leaves now. Waits (at most [wait]) for the server
  /// to close the socket, so the frame went out before ours closes.
  Future<void> sendBye({Duration wait = const Duration(milliseconds: 600)}) async {
    final done = _socketDone;
    if (_channel == null || done == null) return;
    _send(const ByeMessage().toJson());
    try {
      await done.future.timeout(wait);
    } catch (_) {}
  }

  /// Closes the socket (no [SyncStatus] for it) and keeps who this member
  /// is ([token], [memberId], [lastState], [instance]): a reconnect takes
  /// it over. The close is not waited for (a half-open link never
  /// answers it).
  Future<void> drop() async {
    final pending = _pendingWelcome;
    _pendingWelcome = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('cancelled'));
    }
    final sub = _sub;
    _sub = null;
    final ch = _channel;
    _channel = null;
    _socketDone = null;
    try {
      await sub?.cancel().timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    if (ch != null) unawaited(ch.sink.close().timeout(const Duration(seconds: 2), onTimeout: () {}).catchError((_) {}));
  }

  /// [drop], then forgets the member and the server: the next connect is
  /// a new session.
  Future<void> disconnect() async {
    await drop();
    token = '';
    memberId = '';
    mediaUrl = null;
    relayUrl = null;
    lastState = null;
    instance = '';
    lastFeedSeq = 0;
  }

  Future<void> dispose() async {
    await disconnect();
    await _states.close();
    await _feeds.close();
    await _nudges.close();
    await _errors.close();
    await _status.close();
  }
}
