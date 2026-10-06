import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../playback/playback_controller.dart';
import '../sfx/sfx.dart';
import '../sync/state_diff.dart';
import '../sync/sync_client.dart';
import '../sync/user_seek.dart';
import 'health.dart';
import 'idle.dart';

/// Thrown when a connect is superseded by cancel/leave before it finished.
class ConnectCancelled implements Exception {
  const ConnectCancelled();
  @override
  String toString() => 'connection cancelled';
}

/// Display name for a link: last path segment, decoded, never the query
/// (Jellyfin-style links carry api_key there and names are broadcast).
String linkDisplayName(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return 'link';
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isNotEmpty) {
    try {
      return Uri.decodeComponent(segs.last);
    } catch (_) {
      return segs.last;
    }
  }
  return uri.host.isNotEmpty ? uri.host : 'link';
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
  const ConnectParams({
    required this.host,
    required this.port,
    required this.secret,
    required this.name,
    this.avatar = '',
    this.mediaPath = '',
    this.linkUrl = '',
    this.hostKey = '',
  });
}

class ToastItem {
  final int id;
  final String text;
  final DateTime at;
  const ToastItem({required this.id, required this.text, required this.at});
}

const _toastActions = {'join', 'leave', 'kick', 'swap', 'chat'};

String? stateMediaUrl(StateBroadcast state) {
  final media = state.media;
  if (media == null) return null;
  final url = media['url'];
  if (url is String && url.isNotEmpty) return url;
  return null;
}

class SessionCoordinator {
  final SfxService sfx;
  final SyncClient sync = SyncClient();
  final PlaybackController playback = PlaybackController();
  final StateDiff diff = StateDiff();

  final health =
      signal(const HealthStatus(HealthSeverity.info, 'idle'));
  final serverState = signal<StateBroadcast?>(null);
  final feedLog = signal<List<FeedMessage>>([]);
  final toasts = signal<List<ToastItem>>([]);
  final reconnecting = signal(false);
  final kickReason = signal<String?>(null);
  final starving = signal<String?>(null);

  late final Computed<MemberView?> selfMember = computed(() {
    final r = serverState.value;
    if (r == null || sync.memberId.isEmpty) return null;
    for (final m in r.members) {
      if (m.id == sync.memberId) return m;
    }
    return null;
  });

  Timer? _ticker;
  StreamSubscription? _stateSub;
  StreamSubscription? _feedSub;
  StreamSubscription? _kickSub;
  StreamSubscription? _errSub;
  StreamSubscription? _statusSub;

  bool _manualClose = false;
  bool _playerReady = false;
  bool _wasPlayAllowed = false;
  // Last ready flag the server reported for self; restored after a
  // reconnect (the server forgets dropped members).
  bool _lastReady = false;
  // Set after a reconnect until the server echoes the restored ready, so
  // the fresh member's ready=false doesn't overwrite [_lastReady].
  bool _restoringReady = false;
  // Bumped by every connect/leave/cancel/retry: stale attempts no-op.
  int _epoch = 0;
  Timer? _reconnectTimer;
  int _mediaId = -1;
  String? _openUrl;
  String _wsHost = '';
  int _wsPort = 0;
  // Server seek applied to the player (event id and when), checked once it
  // should have landed.
  int? _pendingSeekEvent;
  DateTime? _pendingSeekAt;
  int _seekRetries = 0;
  int _lastEventId = -1;
  final UserSeekGate _seekGate = UserSeekGate();
  Timer? _seekTimer;
  // True while a media open is in flight: the player's duration may still
  // belong to the previous media then.
  bool _opening = false;
  // Token of the current connection, offered as `resume` on reconnect.
  String _resumeToken = '';
  DateTime? _lastStateAt;
  final IdleTracker _idle = IdleTracker(DateTime.now().toUtc());
  int _toastId = 0;
  ConnectParams? _params;
  bool _everConnected = false;

  SessionCoordinator({this.sfx = const NoopSfxService()});

  /// Player lifetime = one session: created here on connect, disposed by
  /// [leave]. Never reused across sessions (a GPU-side video freeze sticks
  /// to the player).
  Future<void> initPlayer() async {
    if (_playerReady) return;
    try {
      playback.onFrozen = () => unawaited(reloadVideo(auto: true));
      playback.onUserSeek = (d) => _userSeek(d.inMicroseconds / 1e6);
      await playback.init();
      _playerReady = true;
    } catch (e, st) {
      debugPrint('player init failed: $e\n$st');
      health.value =
          HealthStatus(HealthSeverity.error, 'player failed to start: $e');
      rethrow;
    }
  }

  bool _reloadingVideo = false;

  /// "Reload video" (button, Ctrl+R, frozen-picture watchdog): fresh
  /// player + video output, current media reopened. While it runs the
  /// player counts as not ready, so reports/seek detection pause and the
  /// next broadcast resyncs position and play/pause (diff reset + play
  /// edge). The ready flag is never touched.
  Future<void> reloadVideo({bool auto = false}) async {
    // Also allowed after a failed reload (player gone, session still on).
    if (_params == null || _reloadingVideo) return;
    _reloadingVideo = true;
    _playerReady = false;
    try {
      await playback.recreate();
      final url = _openUrl;
      _openUrl = null;
      _clearPendingSeek();
      if (url != null) await _openMedia(url);
    } catch (e, st) {
      debugPrint('video reload failed: $e\n$st');
      health.value =
          HealthStatus(HealthSeverity.error, 'video reload failed: $e');
    } finally {
      _playerReady = playback.alive.peek();
      _reloadingVideo = false;
    }
    if (auto) {
      _toastId++;
      toasts.value = [
        ...toasts.peek(),
        ToastItem(
            id: _toastId,
            text: 'Video froze — reloaded',
            at: DateTime.now().toUtc())
      ];
    }
  }

  void markInput() => _idle.activity(DateTime.now().toUtc());

  Future<void> connect(ConnectParams params) async {
    // Own epoch first: a cancel during any await below makes this stale.
    final epoch = ++_epoch;
    await _teardown(silent: true);
    if (epoch != _epoch) throw const ConnectCancelled();
    _params = params;
    _manualClose = false;
    kickReason.value = null;
    _wsHost = params.host;
    _wsPort = params.port;
    diff.reset();
    _mediaId = -1;
    _openUrl = null;
    _lastReady = false;
    _restoringReady = false;
    _wasPlayAllowed = false;
    _everConnected = false;
    _resumeToken = '';
    _seekGate.reset();
    _clearPendingSeek();
    _lastEventId = -1;
    markInput();
    _subscribe();
    feedLog.value = [];
    toasts.value = [];
    await initPlayer();
    if (epoch != _epoch) throw const ConnectCancelled();
    health.value =
        const HealthStatus(HealthSeverity.info, 'connecting…');
    final wsUri = Uri.parse('ws://${params.host}:${params.port}/sync');
    try {
      final welcome = await sync.connect(
        wsUri: wsUri,
        secret: params.secret,
        name: params.name,
        avatar: params.avatar,
        hostKey: params.hostKey,
      );
      // Whoever bumped the epoch (cancel/leave) also closed the socket.
      if (epoch != _epoch) throw const ConnectCancelled();
      reconnecting.value = false;
      _everConnected = true;
      _resumeToken = sync.token;
      health.value = const HealthStatus(HealthSeverity.ok, 'connected');
      _lastStateAt = DateTime.now().toUtc();
      final url = welcome.mediaUrl;
      if (url != null && url.isNotEmpty) {
        await _openMedia(url);
      } else {
        health.value = const HealthStatus(
            HealthSeverity.info, 'connected — waiting for host media…');
      }
      if (params.linkUrl.isNotEmpty) {
        sync.sendSwap(HelloMedia(
            name: linkDisplayName(params.linkUrl),
            size: 0,
            duration: 0,
            url: params.linkUrl));
      }
      _startTicker();
    } catch (e) {
      if (epoch != _epoch) throw const ConnectCancelled();
      debugPrint('connect failed: $e');
      health.value =
          HealthStatus(HealthSeverity.error, _friendlyError(e));
      _scheduleReconnect();
      rethrow;
    }
  }

  void _subscribe() {
    _stateSub ??= sync.states.listen(_onState);
    _feedSub ??= sync.feeds.listen(_onFeed);
    _kickSub ??= sync.kicked.listen(_onKicked);
    _errSub ??= sync.errors.listen((msg) {
      health.value = HealthStatus(HealthSeverity.warn, msg);
    });
    _statusSub ??= sync.status.listen((s) {
      if (s == SyncStatus.closed && !_manualClose && kickReason.peek() == null) {
        health.value = const HealthStatus(
            HealthSeverity.warn, 'connection lost — retrying…');
        _scheduleReconnect();
      }
    });
  }

  Future<void> _openMedia(String url) async {
    if (url == _openUrl) return;
    _openUrl = url;
    diff.reset();
    _opening = true;
    try {
      await playback.openUrl(url);
      health.value =
          const HealthStatus(HealthSeverity.ok, 'connected');
    } catch (e) {
      debugPrint('open media failed: $e');
      health.value =
          HealthStatus(HealthSeverity.error, 'cannot open media: $e');
    } finally {
      _opening = false;
    }
  }

  String _fileUrlFor(String name) {
    return 'http://$_wsHost:$_wsPort/m/default/${sync.token}/${Uri.encodeComponent(name)}';
  }

  Future<void> _onState(StateBroadcast r) async {
    _lastStateAt = DateTime.now().toUtc();
    serverState.value = r;
    _trackSelfReady(r);
    _seekGate.observe(r, sync.memberId);
    final newEvent = r.eventId != _lastEventId;
    _lastEventId = r.eventId;
    if (r.mediaId != _mediaId) {
      _mediaId = r.mediaId;
      var url = stateMediaUrl(r);
      if ((url == null || url.isEmpty) && sync.token.isNotEmpty) {
        final name = (r.media?['name'] as String?) ?? '';
        if (name.isNotEmpty) url = _fileUrlFor(name);
      }
      if (url != null && url.isNotEmpty) {
        await _openMedia(url);
      } else {
        _openUrl = null;
      }
      _seekGate.reset();
      _clearPendingSeek();
    }
    if (!_playerReady || _openUrl == null) {
      _wasPlayAllowed = false;
      _updateStarving(r, 0);
      return;
    }
    // Server clock: serverTime in the state is the server's.
    final now = sync.serverNow();
    final allowed = localPlayAllowed(r, sync.memberId);
    var actions = diff.diff(r, playback.positionSecs, now);
    if (r.transport == 'playing' && !allowed) {
      actions = [
        for (final a in actions) if (a is! TransportAction) a,
        const TransportAction(false),
      ];
    }
    if (allowed && !_wasPlayAllowed && r.transport == 'playing') {
      final edge = serverPositionAt(r, now);
      actions = [
        for (final a in actions) if (a is! TransportAction) a,
        SeekAction(edge),
        const TransportAction(true),
      ];
    }
    _wasPlayAllowed = allowed;
    // The user is seeking (or our seek has not echoed yet), or this is the
    // echo of our own seek arriving: the player is where the user put it.
    // Later drift corrections within that event still apply.
    if (_seekGate.holdsPlayer(DateTime.now().toUtc()) ||
        (newEvent && _seekGate.isOwnEcho(r, sync.memberId))) {
      actions = [for (final a in actions) if (a is! SeekAction) a];
    }
    if (actions.any((a) => a is SeekAction)) {
      _pendingSeekEvent = r.eventId;
      _pendingSeekAt = DateTime.now().toUtc();
      _seekRetries = 0;
    }
    await playback.apply(actions);
    _updateStarving(r, playback.bufferedSecsAhead);
  }

  /// Mirrors the server's ready flag for self into [_lastReady] (force
  /// by others included). After a stale spell the server puts a ready
  /// member back in the set by itself.
  void _trackSelfReady(StateBroadcast r) {
    final self = selfMember.peek();
    if (self == null) return;
    if (r.mediaId != _mediaId) _restoringReady = false;
    if (_restoringReady) {
      if (self.ready) _restoringReady = false;
    } else {
      _lastReady = self.ready;
    }
  }

  void _updateStarving(StateBroadcast r, double bufferedAhead) {
    if (r.transport == 'playing') {
      starving.value = null;
      return;
    }
    if (r.transport == 'finished') {
      starving.value = 'finished — seek back or change media';
      return;
    }
    for (final m in r.members) {
      if (m.inSet && m.buffered < RelayConstants.minBufferSecs) {
        starving.value =
            'waiting for ${m.name} — ${m.buffered.toStringAsFixed(1)} s buffered';
        return;
      }
    }
    final self = selfMember.peek();
    if (self != null && self.ready) {
      final waiters = r.members
          .where((m) => m.id != self.id && !m.stale && !(m.inSet && m.ready))
          .map((m) => m.name)
          .toList();
      if (waiters.isNotEmpty) {
        final readyCount = r.members.where((m) => m.ready).length;
        starving.value =
            'waiting for ${waiters.join(', ')} ($readyCount/${r.members.length} ready)';
        return;
      }
    }
    if (self != null && !self.ready) {
      starving.value = 'press Space when ready';
      return;
    }
    if (r.members.any((m) => m.inSet)) {
      starving.value = 'held — waiting for readiness';
      return;
    }
    starving.value = 'held — press Space when ready';
  }

  void _onFeed(FeedMessage f) {
    feedLog.value = [...feedLog.peek(), f].length > 100
        ? [...feedLog.peek(), f].sublist(feedLog.peek().length - 99)
        : [...feedLog.peek(), f];
    if (_toastActions.contains(f.action)) {
      final text = f.action == 'chat'
          ? '${f.actor}: ${f.reason}'
          : _feedText(f);
      _toastId++;
      toasts.value = [
        ...toasts.peek(),
        ToastItem(id: _toastId, text: text, at: DateTime.now().toUtc())
      ];
    }
    final kind = sfxForFeedAction(f.action);
    if (kind != null) {
      var readyIndex = 0;
      if (f.action == 'ready') {
        readyIndex = serverState.peek()?.members.where((m) => m.ready).length ?? 0;
      }
      unawaited(sfx.play(SfxCue(kind, readyIndex: readyIndex)));
    }
  }

  String _feedText(FeedMessage f) {
    switch (f.action) {
      case 'join':
        return '${f.actor} joined';
      case 'leave':
        return '${f.actor} left';
      case 'kick':
        return '${f.actor} kicked ${f.target ?? ''}';
      case 'swap':
        return '${f.actor} changed media';
      default:
        return '${f.actor} ${f.action}';
    }
  }

  Future<void> _onKicked(String reason) async {
    kickReason.value = reason;
    _manualClose = true;
    _epoch++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    reconnecting.value = false;
    _ticker?.cancel();
    _ticker = null;
    // Stop, not pause: a paused player keeps filling its cache from the
    // host's media URL.
    _openUrl = null;
    try {
      await playback.stop();
    } catch (_) {}
    await sync.disconnect();
    health.value = HealthStatus(
        HealthSeverity.error,
        reason.isEmpty ? 'kicked from server' : 'kicked: $reason');
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _tick() async {
    final now = DateTime.now().toUtc();
    toasts.value =
        toasts.peek().where((t) => now.difference(t.at).inSeconds < 4).toList();
    final r = serverState.peek();
    if (sync.token.isNotEmpty) sync.sendPing();
    if (sync.token.isNotEmpty && r != null && _playerReady) {
      // Duration only once the open media is the server's current one.
      final known = !_opening && _openUrl != null && _mediaId == r.mediaId;
      sync.sendReport(
        position: playback.positionSecs,
        buffered: playback.bufferedSecsAhead,
        eventId: r.eventId,
        duration: known ? playback.durationSecs : 0,
        mediaId: known ? r.mediaId : 0,
      );
      _checkSeekLanded(r);
    }
    if (!_manualClose &&
        kickReason.peek() == null &&
        _lastStateAt != null &&
        now.difference(_lastStateAt!).inSeconds >= 5) {
      if (serverState.peek() != null) {
        serverState.value = null;
        starving.value = null;
        _wasPlayAllowed = false;
        _mediaId = -1;
        _clearPendingSeek();
        diff.reset();
      }
      if (!reconnecting.peek()) {
        health.value = const HealthStatus(
            HealthSeverity.warn, 'connection lost — retrying…');
        _scheduleReconnect();
      }
    }
    // No warning when there is nothing to lose (unready), and none while
    // PLAYING: the ready flag gates nothing then, and watching counts as
    // activity so a pause after a long watch starts a fresh idle clock.
    final event = _idle.tick(now,
        playing: serverState.peek()?.transport == 'playing',
        selfReady: selfMember.peek()?.ready ?? false);
    switch (event) {
      case IdleEvent.warn:
        _toastId++;
        toasts.value = [
          ...toasts.peek(),
          ToastItem(
              id: _toastId,
              text: 'idle — auto-unready in 2 min unless you press Space',
              at: now)
        ];
        unawaited(sfx.play(const SfxCue(SfxKind.warn)));
      case IdleEvent.unready:
        _lastReady = false;
        sync.sendReady(false, source: 'auto');
      case IdleEvent.none:
        break;
    }
  }

  void _clearPendingSeek() {
    _pendingSeekEvent = null;
    _pendingSeekAt = null;
    _seekRetries = 0;
  }

  /// A server seek that has not landed after 1.5 s is applied once more,
  /// to where the server is now (never the old target: it went stale
  /// while playing). Dropped when a newer event or a user seek took over.
  Future<void> _checkSeekLanded(StateBroadcast r) async {
    final event = _pendingSeekEvent;
    final at = _pendingSeekAt;
    if (event == null || at == null) return;
    final now = DateTime.now().toUtc();
    if (event != r.eventId || _seekGate.holdsPlayer(now)) {
      _clearPendingSeek();
      return;
    }
    if (now.difference(at).inMilliseconds < 1500) return;
    final target = serverPositionAt(r, sync.serverNow());
    if (seekLanded(ownPosition: playback.positionSecs, target: target)) {
      _clearPendingSeek();
      return;
    }
    if (_seekRetries < 1) {
      _seekRetries++;
      _pendingSeekAt = now;
      await playback.apply([SeekAction(target)]);
    } else {
      _clearPendingSeek();
    }
  }

  /// Every user seek (seek bar, arrow keys, [seekTo]) lands here: the
  /// player moves at once (scrub preview), the server hears one `seek`
  /// once the user stops for [UserSeekGate.debounce].
  void _userSeek(double position) {
    if (!position.isFinite || position < 0) return;
    if (serverState.peek() == null || _openUrl == null) return;
    markInput();
    final now = DateTime.now().toUtc();
    _seekGate.request(position, now);
    _clearPendingSeek();
    unawaited(playback.apply([SeekAction(position)]));
    _seekTimer?.cancel();
    _seekTimer = Timer(_seekGate.debounce, _flushUserSeek);
  }

  void _flushUserSeek() {
    _seekTimer = null;
    final settled = _seekGate.takeSettled(DateTime.now().toUtc());
    if (settled == null) return;
    var position = settled.position;
    // Playing on since the request: send where the player is now, so the
    // server's clock and ours agree when the echo comes back.
    final own = playback.positionSecs;
    if (_playerReady &&
        playback.player.state.playing &&
        (own - position).abs() < 2.0) {
      position = own;
    }
    sync.sendSeek(position, seq: settled.seq);
  }

  void toggleReady() {
    final self = selfMember.peek();
    // Ready but out of the set (dropped out while stale) gates like
    // unready, so Space puts self back in instead of unreadying.
    final next = !((self?.ready ?? false) && (self?.inSet ?? false));
    markInput();
    _lastReady = next;
    sync.sendReady(next, source: 'manual');
  }

  void forceTarget(String memberId, bool ready) {
    markInput();
    sync.sendForce(memberId, ready);
  }

  void forcePlayAll() {
    markInput();
    sync.sendForce('all', true);
  }

  void seekTo(double position) => _userSeek(position);

  /// Arrow keys: relative to a seek still in flight, so repeated presses
  /// add up.
  void nudge(double deltaSecs) {
    final r = serverState.peek();
    if (r == null || _openUrl == null) return;
    final base = _seekGate.target ?? serverPositionAt(r, sync.serverNow());
    final target = base + deltaSecs;
    if (target.isNaN) return;
    _userSeek(target < 0 ? 0 : target);
  }

  void sendChat(String text) {
    // Enter in the chat field can fire both onSubmitted and the focused
    // send button's onPressed; the first send clears the field, so the
    // second arrives empty. Drop blanks so at most one message ships.
    if (text.trim().isEmpty) return;
    markInput();
    sync.sendChat(text);
  }

  void kick(String memberId, {String reason = ''}) {
    markInput();
    sync.sendKick(memberId, reason: reason);
  }

  Future<void> swapLink(String url) async {
    markInput();
    sync.sendSwap(HelloMedia(
        name: linkDisplayName(url), size: 0, duration: 0, url: url));
  }

  void _scheduleReconnect({bool manual = false}) {
    if (_manualClose || kickReason.peek() != null || _params == null) return;
    if (!manual && !_everConnected) return;
    if (reconnecting.peek()) return;
    reconnecting.value = true;
    final epoch = _epoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
        const Duration(milliseconds: 1500), () => _reconnect(epoch));
  }

  /// One reconnect attempt. Every cancel/retry/leave/connect bumps
  /// [_epoch]; an attempt from an older epoch must not touch state (it
  /// would kill the newer connection and leave a ghost member).
  Future<void> _reconnect(int epoch) async {
    _reconnectTimer = null;
    bool stale() => epoch != _epoch || kickReason.peek() != null;
    final params = _params;
    if (stale() || params == null) return;
    if (_manualClose) {
      reconnecting.value = false;
      return;
    }
    final wantReady = _lastReady;
    try {
      health.value = const HealthStatus(
          HealthSeverity.info, 'reconnecting…');
      final wsUri = Uri.parse('ws://${params.host}:${params.port}/sync');
      final welcome = await sync.connect(
        wsUri: wsUri,
        secret: params.secret,
        name: params.name,
        avatar: params.avatar,
        hostKey: params.hostKey,
        resume: _resumeToken,
      );
      // Whoever bumped the epoch also closed (or replaced) the socket.
      if (stale()) return;
      reconnecting.value = false;
      _everConnected = true;
      _resumeToken = sync.token;
      _lastStateAt = DateTime.now().toUtc();
      health.value = const HealthStatus(HealthSeverity.ok, 'connected');
      final url = welcome.mediaUrl;
      if (url != null && url.isNotEmpty && url != _openUrl) {
        await _openMedia(url);
      }
      if (stale()) return;
      // The server forgot the dropped member; restore the ready flag it
      // last reported (not a local guess: others may have forced it).
      if (wantReady) {
        _lastReady = true;
        _restoringReady = true;
        sync.sendReady(true, source: 'manual');
      }
      _startTicker();
    } catch (e) {
      if (stale()) return;
      debugPrint('reconnect failed: $e');
      reconnecting.value = false;
      _scheduleReconnect();
    }
  }

  void _invalidateAttempts() {
    _epoch++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void cancelReconnect() {
    _manualClose = true;
    _invalidateAttempts();
    reconnecting.value = false;
    // Abort an attempt already dialling (no live session while retrying).
    unawaited(sync.disconnect().catchError((_) {}));
  }

  Future<void> cancelConnect() async {
    _manualClose = true;
    _invalidateAttempts();
    reconnecting.value = false;
    try {
      await sync.disconnect();
    } catch (_) {}
    health.value = const HealthStatus(HealthSeverity.info, 'cancelled');
  }

  void retry() {
    if (kickReason.peek() != null || _params == null) return;
    _invalidateAttempts();
    _manualClose = false;
    reconnecting.value = false;
    health.value =
        const HealthStatus(HealthSeverity.info, 'retrying…');
    _scheduleReconnect(manual: true);
  }

  String _friendlyError(Object e) {
    final msg = '$e';
    if (msg.contains('proto mismatch')) return 'host runs a different version — update the app';
    if (msg.contains('wrong secret')) return 'wrong server password (401)';
    if (msg.contains('SocketException') || msg.contains('Connection refused')) {
      return 'host offline — check address and port';
    }
    return 'connect failed: $e';
  }

  Future<void> leave({bool silent = false}) async {
    _invalidateAttempts();
    await _teardown(silent: silent);
  }

  Future<void> _teardown({bool silent = false}) async {
    _manualClose = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _ticker?.cancel();
    _ticker = null;
    _seekTimer?.cancel();
    _seekTimer = null;
    _seekGate.reset();
    reconnecting.value = false;
    _playerReady = false;
    try {
      await playback.dispose();
    } catch (_) {}
    try {
      await sync.disconnect();
    } catch (_) {}
    if (!silent) {
      serverState.value = null;
      starving.value = null;
      health.value = const HealthStatus(HealthSeverity.info, 'idle');
    }
  }

  Future<void> dispose() async {
    await leave(silent: true);
    await _stateSub?.cancel();
    await _feedSub?.cancel();
    await _kickSub?.cancel();
    await _errSub?.cancel();
    await _statusSub?.cancel();
    await sync.dispose();
    await playback.dispose();
  }
}
