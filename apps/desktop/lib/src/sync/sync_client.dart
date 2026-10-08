import 'dart:async';
import 'dart:convert';

import 'package:sync_relay_core/core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum SyncStatus { idle, connecting, open, kicked, closed, error }

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
  final StreamController<StateBroadcast> _states = StreamController.broadcast();
  final StreamController<FeedMessage> _feeds = StreamController.broadcast();
  final StreamController<String> _kicked = StreamController.broadcast();
  final StreamController<String> _errors = StreamController.broadcast();
  final StreamController<SyncStatus> _status = StreamController.broadcast();

  Stream<StateBroadcast> get states => _states.stream;
  Stream<FeedMessage> get feeds => _feeds.stream;
  Stream<String> get kicked => _kicked.stream;
  Stream<String> get errors => _errors.stream;
  Stream<SyncStatus> get status => _status.stream;

  /// The `/sync` URL last dialled; its host serves `/a/...` and the media.
  Uri? wsUri;
  String token = '';
  String memberId = '';
  String? mediaUrl;
  /// This member's `/j/...` URL from `welcome` (Jellyfin media the server
  /// relays); private like [token].
  String? relayUrl;
  StateBroadcast? lastState;
  Completer<WelcomeMessage>? _pendingWelcome;

  Future<WelcomeMessage> connect({
    required Uri wsUri,
    required String secret,
    required String name,
    String avatar = '',
    HelloMedia? media,
    String hostKey = '',
    String resume = '',
  }) async {
    await disconnect();
    clockSync.reset();
    this.wsUri = wsUri;
    _status.add(SyncStatus.connecting);
    final ch = WebSocketChannel.connect(wsUri);
    unawaited(ch.ready.then((_) {}, onError: (_) {}));
    _channel = ch;
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
        if (!welcomeCompleter.isCompleted) {
          welcomeCompleter.completeError(StateError('closed before welcome'));
        }
        _status.add(SyncStatus.closed);
      },
      cancelOnError: false,
    );
    final hello = HelloMessage(
      proto: RelayConstants.protoVersion,
      secret: secret,
      user: HelloUser(name: name, avatar: avatar),
      media: media ?? const HelloMedia(name: '', size: 0, duration: 0),
      hostKey: hostKey,
      resume: resume,
    );
    ch.sink.add(jsonEncode(hello.toJson()));
    _pendingWelcome = welcomeCompleter;
    try {
      final welcome = await welcomeCompleter.future.timeout(
        const Duration(seconds: 10),
      );
      _pendingWelcome = null;
      token = welcome.token;
      memberId = welcome.memberId;
      mediaUrl = welcome.mediaUrl;
      relayUrl = welcome.relayUrl;
      if (welcome.state != null) {
        try {
          lastState = StateBroadcast.fromJson(welcome.state!);
          _states.add(lastState!);
        } catch (_) {}
      }
      _status.add(SyncStatus.open);
      sendPing();
      return welcome;
    } catch (e) {
      _pendingWelcome = null;
      await disconnect();
      _status.add(SyncStatus.error);
      rethrow;
    }
  }

  void _onText(String raw, Completer<WelcomeMessage> welcomeCompleter) {
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
        welcomeCompleter.completeError(
          ProtocolException('${decoded['message'] ?? 'rejected'}'),
        );
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
          final f = FeedMessage.fromJson(decoded);
          // Server delivers every chat twice: a ChatMessage carrying the
          // text (converted to a feed entry in `case 'chat'` below) and a
          // textless feed entry. Keep only the former: one send, one row,
          // one toast, one sfx.
          if (f.action != 'chat') _feeds.add(f);
        } catch (_) {}
      case 'kicked':
        try {
          final msg = KickedMessage.fromJson(decoded);
          _kicked.add(msg.reason);
          _status.add(SyncStatus.kicked);
        } catch (_) {
          _kicked.add('');
        }
      case 'pong':
        try {
          final pong = PongMessage.fromJson(decoded);
          clockSync.add(
              sentMs: pong.clientMs,
              serverMs: pong.serverMs,
              receivedMs: _clock().millisecondsSinceEpoch);
        } catch (_) {}
      case 'err':
        _errors.add('${decoded['message'] ?? 'error'}');
      case 'chat':
        try {
          _feeds.add(
            FeedMessage(
              actor: '${decoded['from'] ?? '?'}',
              action: 'chat',
              reason: (decoded['text'] as String?) ?? '',
              at: DateTime.now().toUtc(),
            ),
          );
        } catch (_) {}
    }
  }

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

  /// One clock sample; the coordinator sends one per second.
  void sendPing() {
    _send(PingMessage(clientMs: _clock().millisecondsSinceEpoch).toJson());
  }

  void sendSwap(HelloMedia media) {
    _send(SwapIntent(media: media).toJson());
  }

  void sendReport({
    required double position,
    required double buffered,
    required int eventId,
    double duration = 0,
    int mediaId = 0,
    Map<String, bool>? jf,
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

  void sendKick(String target, {String reason = ''}) {
    _send(KickRequest(target: target, reason: reason).toJson());
  }

  Future<void> disconnect() async {
    final pending = _pendingWelcome;
    _pendingWelcome = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('cancelled'));
    }    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    token = '';
    memberId = '';
    mediaUrl = null;
    relayUrl = null;
    lastState = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _states.close();
    await _feeds.close();
    await _kicked.close();
    await _errors.close();
    await _status.close();
  }
}
