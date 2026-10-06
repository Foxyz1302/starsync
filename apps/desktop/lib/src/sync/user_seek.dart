import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';

/// A [Player] whose public [seek] belongs to the user. media_kit's seek bar
/// (and anything else in the video controls) calls `player.seek`; with
/// [onUserSeek] set those calls become explicit events for the sync layer
/// instead of moving mpv behind its back. Sync-driven seeks use [syncSeek].
class SyncPlayer extends Player {
  SyncPlayer({super.configuration});

  void Function(Duration position)? onUserSeek;

  @override
  Future<void> seek(Duration duration) async {
    final hook = onUserSeek;
    if (hook == null) return super.seek(duration);
    hook(duration);
  }

  /// Seek mpv directly (preview while scrubbing, server corrections).
  Future<void> syncSeek(Duration duration) => super.seek(duration);
}

/// Turns a burst of user seeks (a seek bar drag fires one per pointer move,
/// arrow keys one per press) into one `seek` intent, and tells the
/// coordinator when server seeks must not touch the player:
///
/// - while the user is still seeking ([debounce] since the last request),
/// - while our sent seek has no echo yet ([echoTimeout] at most),
/// - for the echo of our own seek (`state.seekBy` is us): the player is
///   already there, re-seeking would only hitch or yank.
class UserSeekGate {
  final Duration debounce;
  final Duration echoTimeout;

  UserSeekGate({
    this.debounce = const Duration(milliseconds: RelayConstants.seekDebounceMs),
    this.echoTimeout = const Duration(seconds: 3),
  });

  double? _target;
  DateTime? _requestedAt;
  int _seq = 0;
  int _sentSeq = 0;
  DateTime? _sentAt;

  /// Latest requested position, while a request or its echo is pending.
  double? get target => _target;

  /// The user asked for [position] at [now].
  void request(double position, DateTime now) {
    _target = position;
    _requestedAt = now;
  }

  bool scrubbing(DateTime now) =>
      _requestedAt != null && now.difference(_requestedAt!) < debounce;

  /// The settled request to send, once [debounce] has passed since the last
  /// one; null otherwise. Returns its seq, which the server echoes.
  ({double position, int seq})? takeSettled(DateTime now) {
    final t = _target;
    if (t == null || _requestedAt == null || scrubbing(now)) return null;
    _requestedAt = null;
    _sentSeq = ++_seq;
    _sentAt = now;
    return (position: t, seq: _sentSeq);
  }

  bool get _awaitingEcho => _sentAt != null;

  /// Server seeks are ignored while this holds.
  bool holdsPlayer(DateTime now) {
    if (_requestedAt != null) return true; // not sent yet
    final sent = _sentAt;
    if (sent == null) return false;
    if (now.difference(sent) >= echoTimeout) {
      _sentAt = null;
      _target = null;
      return false;
    }
    return true;
  }

  /// The state's current event is a seek this client sent.
  bool isOwnEcho(StateBroadcast state, String memberId) {
    final seq = state.seekSeq;
    return memberId.isNotEmpty &&
        state.seekBy == memberId &&
        seq != null &&
        seq > 0 &&
        seq <= _seq;
  }

  /// Feed every state: the echo of the last sent seek ends the hold.
  void observe(StateBroadcast state, String memberId) {
    if (!_awaitingEcho || _requestedAt != null) return;
    if (isOwnEcho(state, memberId) && state.seekSeq! >= _sentSeq) {
      _sentAt = null;
      _target = null;
    }
  }

  void reset() {
    _target = null;
    _requestedAt = null;
    _sentAt = null;
  }
}
