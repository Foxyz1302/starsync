import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../playback/playback_controller.dart';
import '../sfx/sfx.dart';
import '../sync/room_diff.dart';
import '../sync/sync_client.dart';
import 'health.dart';

class ConnectParams {
  final String host;
  final int port;
  final String secret;
  final String name;
  final String avatar;
  final String mediaPath;
  final String linkUrl;
  const ConnectParams({
    required this.host,
    required this.port,
    required this.secret,
    required this.name,
    this.avatar = '',
    this.mediaPath = '',
    this.linkUrl = '',
  });
}

class ToastItem {
  final int id;
  final String text;
  final DateTime at;
  const ToastItem({required this.id, required this.text, required this.at});
}

const _toastActions = {'join', 'leave', 'kick', 'swap', 'chat'};

String? roomMediaUrl(RoomBroadcast room) {
  final media = room.media;
  if (media == null) return null;
  final url = media['url'];
  if (url is String && url.isNotEmpty) return url;
  return null;
}

class SessionCoordinator {
  final SfxService sfx;
  final SyncClient sync = SyncClient();
  final PlaybackController playback = PlaybackController();
  final RoomDiff diff = RoomDiff();

  final health =
      signal(const HealthStatus(HealthSeverity.info, 'idle'));
  final room = signal<RoomBroadcast?>(null);
  final feedLog = signal<List<FeedMessage>>([]);
  final toasts = signal<List<ToastItem>>([]);
  final reconnecting = signal(false);
  final kickReason = signal<String?>(null);
  final starving = signal<String?>(null);

  late final Computed<MemberView?> selfMember = computed(() {
    final r = room.value;
    if (r == null || sync.memberId.isEmpty) return null;
    for (final m in r.members) {
      if (m.id == sync.memberId) return m;
    }
    return null;
  });

  Timer? _ticker;
  StreamSubscription? _roomSub;
  StreamSubscription? _feedSub;
  StreamSubscription? _kickSub;
  StreamSubscription? _errSub;
  StreamSubscription? _statusSub;

  bool _manualClose = false;
  bool _playerReady = false;
  bool _warnedIdle = false;
  bool _wasPlayAllowed = false;
  bool _lastReady = false;
  int _mediaId = -1;
  String? _openUrl;
  String _wsHost = '';
  int _wsPort = 0;
  double _lastPos = 0;
  double? _pendingSeekTarget;
  DateTime? _pendingSeekAt;
  int _seekRetries = 0;
  DateTime? _lastRoomAt;
  DateTime _lastInput = DateTime.now().toUtc();
  int _toastId = 0;
  ConnectParams? _params;
  bool _everConnected = false;

  SessionCoordinator({this.sfx = const NoopSfxService()});

  Future<void> initPlayer() async {
    if (_playerReady) return;
    try {
      await playback.init();
      _playerReady = true;
    } catch (e, st) {
      debugPrint('player init failed: $e\n$st');
      health.value =
          HealthStatus(HealthSeverity.error, 'player failed to start: $e');
      rethrow;
    }
  }

  void markInput() {
    _lastInput = DateTime.now().toUtc();
    _warnedIdle = false;
  }

  Future<void> connect(ConnectParams params) async {
    await leave(silent: true);
    _params = params;
    _manualClose = false;
    kickReason.value = null;
    _wsHost = params.host;
    _wsPort = params.port;
    diff.reset();
    _mediaId = -1;
    _openUrl = null;
    _lastReady = false;
    _wasPlayAllowed = false;
    _everConnected = false;
    markInput();
    _subscribe();
    feedLog.value = [];
    toasts.value = [];
    await initPlayer();
    health.value =
        const HealthStatus(HealthSeverity.info, 'connecting…');
    final wsUri = Uri.parse('ws://${params.host}:${params.port}/sync');
    try {
      final welcome = await sync.connect(
        wsUri: wsUri,
        secret: params.secret,
        name: params.name,
        avatar: params.avatar,
      );
      reconnecting.value = false;
      _everConnected = true;
      health.value = const HealthStatus(HealthSeverity.ok, 'connected');
      _lastRoomAt = DateTime.now().toUtc();
      final url = welcome.mediaUrl;
      if (url != null && url.isNotEmpty) {
        await _openMedia(url);
      } else {
        health.value = const HealthStatus(
            HealthSeverity.info, 'connected — waiting for host media…');
      }
      if (params.linkUrl.isNotEmpty) {
        sync.sendSwap(HelloMedia(
            name: params.linkUrl, size: 0, duration: 0, url: params.linkUrl));
      }
      _startTicker();
    } catch (e) {
      debugPrint('connect failed: $e');
      health.value =
          HealthStatus(HealthSeverity.error, _friendlyError(e));
      _scheduleReconnect();
      rethrow;
    }
  }

  void _subscribe() {
    _roomSub ??= sync.rooms.listen(_onRoom);
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
    try {
      await playback.openUrl(url);
      health.value =
          const HealthStatus(HealthSeverity.ok, 'connected');
    } catch (e) {
      debugPrint('open media failed: $e');
      health.value =
          HealthStatus(HealthSeverity.error, 'cannot open media: $e');
    }
  }

  String _fileUrlFor(String name) {
    return 'http://$_wsHost:$_wsPort/m/default/${sync.token}/${Uri.encodeComponent(name)}';
  }

  Future<void> _onRoom(RoomBroadcast r) async {
    final now = DateTime.now().toUtc();
    _lastRoomAt = now;
    room.value = r;
    if (r.mediaId != _mediaId) {
      _mediaId = r.mediaId;
      var url = roomMediaUrl(r);
      if ((url == null || url.isEmpty) && sync.token.isNotEmpty) {
        final name = (r.media?['name'] as String?) ?? '';
        if (name.isNotEmpty) url = _fileUrlFor(name);
      }
      if (url != null && url.isNotEmpty) {
        await _openMedia(url);
      } else {
        _openUrl = null;
      }
      _pendingSeekTarget = null;
      _seekRetries = 0;
    }
    if (!_playerReady || _openUrl == null) {
      _wasPlayAllowed = false;
      _updateStarving(r, 0);
      return;
    }
    final allowed = localPlayAllowed(r, sync.memberId);
    var actions = diff.diff(r, playback.positionSecs, now);
    if (r.transport == 'playing' && !allowed) {
      actions = [
        for (final a in actions) if (a is! TransportAction) a,
        const TransportAction(false),
      ];
    }
    if (allowed && !_wasPlayAllowed && r.transport == 'playing') {
      final edge = roomPositionAt(r, now);
      actions = [
        for (final a in actions) if (a is! TransportAction) a,
        SeekAction(edge),
        const TransportAction(true),
      ];
      _pendingSeekTarget = edge;
      _pendingSeekAt = now;
    }
    _wasPlayAllowed = allowed;
    for (final a in actions) {
      if (a is SeekAction) {
        _pendingSeekTarget = a.position;
        _pendingSeekAt = now;
      }
    }
    await playback.apply(actions);
    _updateStarving(r, playback.bufferedSecsAhead);
  }

  void _updateStarving(RoomBroadcast r, double bufferedAhead) {
    if (r.transport == 'playing') {
      starving.value = null;
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
        readyIndex = room.peek()?.members.where((m) => m.ready).length ?? 0;
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
    reconnecting.value = false;
    _ticker?.cancel();
    _ticker = null;
    try {
      await playback.apply(const [TransportAction(false)]);
    } catch (_) {}
    await sync.disconnect();
    health.value = HealthStatus(
        HealthSeverity.error,
        reason.isEmpty ? 'kicked from room' : 'kicked: $reason');
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _tick() async {
    final now = DateTime.now().toUtc();
    toasts.value =
        toasts.peek().where((t) => now.difference(t.at).inSeconds < 4).toList();
    final r = room.peek();
    if (sync.token.isNotEmpty && r != null && _playerReady) {
      sync.sendReport(
        position: playback.positionSecs,
        buffered: playback.bufferedSecsAhead,
        eventId: r.eventId,
      );
      _detectUserSeek(r);
      _checkSeekLanded(r);
    }
    if (!_manualClose &&
        kickReason.peek() == null &&
        _lastRoomAt != null &&
        now.difference(_lastRoomAt!).inSeconds >= 5) {
      if (room.peek() != null) {
        room.value = null;
        starving.value = null;
        _wasPlayAllowed = false;
        _mediaId = -1;
        _pendingSeekTarget = null;
        _seekRetries = 0;
        diff.reset();
      }
      if (!reconnecting.peek()) {
        health.value = const HealthStatus(
            HealthSeverity.warn, 'connection lost — retrying…');
        _scheduleReconnect();
      }
    }
    final idleSecs = now.difference(_lastInput).inSeconds;
    if (idleSecs >= 8 * 60 && !_warnedIdle) {
      _warnedIdle = true;
      _toastId++;
      toasts.value = [
        ...toasts.peek(),
        ToastItem(
            id: _toastId,
            text: 'idle — auto-unready in 2 min unless you press Space',
            at: now)
      ];
      unawaited(sfx.play(const SfxCue(SfxKind.warn)));
    }
    if (idleSecs >= 10 * 60) {
      final self = selfMember.peek();
      if (self != null && self.ready) {
        _lastReady = false;
        sync.sendReady(false, source: 'auto');
        markInput();
      }
    }
  }

  void _detectUserSeek(RoomBroadcast r) {
    if (_openUrl == null) {
      _lastPos = playback.positionSecs;
      return;
    }
    final now = DateTime.now().toUtc();
    final pos = playback.positionSecs;
    final jumped = (pos - _lastPos).abs();
    _lastPos = pos;
    if (jumped <= 2.0) return;
    if ((pos - roomPositionAt(r, now)).abs() < 2.0) return;
    final recentSync = _pendingSeekAt != null &&
        now.difference(_pendingSeekAt!).inMilliseconds < 1000;
    if (recentSync) return;
    markInput();
    sync.sendSeek(pos);
  }

  Future<void> _checkSeekLanded(RoomBroadcast r) async {
    final target = _pendingSeekTarget;
    final at = _pendingSeekAt;
    if (target == null || at == null) return;
    if (DateTime.now().toUtc().difference(at).inMilliseconds < 1500) return;
    if (seekLanded(ownPosition: playback.positionSecs, target: target)) {
      _pendingSeekTarget = null;
      _pendingSeekAt = null;
      _seekRetries = 0;
      return;
    }
    if (_seekRetries < 1) {
      _seekRetries++;
      _pendingSeekAt = DateTime.now().toUtc();
      await playback.apply([SeekAction(target)]);
    } else {
      _pendingSeekTarget = null;
      _pendingSeekAt = null;
      _seekRetries = 0;
    }
  }

  void toggleReady() {
    final self = selfMember.peek();
    final next = !(self?.ready ?? false);
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

  void seekTo(double position) {
    markInput();
    sync.sendSeek(position);
  }

  void nudge(double deltaSecs) {
    final r = room.peek();
    if (r == null || _openUrl == null) return;
    final target =
        roomPositionAt(r, DateTime.now().toUtc()) + deltaSecs;
    if (target.isNaN || target < 0) return;
    markInput();
    sync.sendSeek(target);
  }

  void sendChat(String text) {
    markInput();
    sync.sendChat(text);
  }

  void kick(String memberId, {String reason = ''}) {
    markInput();
    sync.sendKick(memberId, reason: reason);
  }

  Future<void> swapLink(String url) async {
    markInput();
    sync.sendSwap(
        HelloMedia(name: url, size: 0, duration: 0, url: url));
  }

  void _scheduleReconnect({bool manual = false}) {
    if (_manualClose || kickReason.peek() != null || _params == null) return;
    if (!manual && !_everConnected) return;
    if (reconnecting.peek()) return;
    reconnecting.value = true;
    Future.delayed(const Duration(milliseconds: 1500), () async {
      if (_manualClose || kickReason.peek() != null) {
        reconnecting.value = false;
        return;
      }
      final params = _params;
      if (params == null) {
        reconnecting.value = false;
        return;
      }
      try {
        health.value = const HealthStatus(
            HealthSeverity.info, 'reconnecting…');
        final wsUri = Uri.parse('ws://${params.host}:${params.port}/sync');
        final welcome = await sync.connect(
          wsUri: wsUri,
          secret: params.secret,
          name: params.name,
          avatar: params.avatar,
        );
        reconnecting.value = false;
        _everConnected = true;
        health.value = const HealthStatus(HealthSeverity.ok, 'connected');
        final url = welcome.mediaUrl;
        if (url != null && url.isNotEmpty && url != _openUrl) {
          await _openMedia(url);
        }
        if (_lastReady) sync.sendReady(true, source: 'manual');
        _startTicker();
      } catch (e) {
        debugPrint('reconnect failed: $e');
        reconnecting.value = false;
        _scheduleReconnect();
      }
    });
  }

  void cancelReconnect() {
    _manualClose = true;
    reconnecting.value = false;
  }

  Future<void> cancelConnect() async {
    _manualClose = true;
    reconnecting.value = false;
    try {
      await sync.disconnect();
    } catch (_) {}
    health.value = const HealthStatus(HealthSeverity.info, 'cancelled');
  }

  void retry() {
    if (kickReason.peek() != null || _params == null) return;
    _manualClose = false;
    reconnecting.value = false;
    health.value =
        const HealthStatus(HealthSeverity.info, 'retrying…');
    _scheduleReconnect(manual: true);
  }

  String _friendlyError(Object e) {
    final msg = '$e';
    if (msg.contains('proto mismatch')) return 'host runs a different version — update the app';
    if (msg.contains('wrong secret')) return 'wrong room password (401)';
    if (msg.contains('SocketException') || msg.contains('Connection refused')) {
      return 'host offline — check address and port';
    }
    return 'connect failed: $e';
  }

  Future<void> leave({bool silent = false}) async {
    _manualClose = true;
    _ticker?.cancel();
    _ticker = null;
    reconnecting.value = false;
    try {
      await playback.stop();
    } catch (_) {}
    try {
      await sync.disconnect();
    } catch (_) {}
    if (!silent) {
      room.value = null;
      starving.value = null;
      health.value = const HealthStatus(HealthSeverity.info, 'idle');
    }
  }

  Future<void> dispose() async {
    await leave(silent: true);
    await _roomSub?.cancel();
    await _feedSub?.cancel();
    await _kickSub?.cancel();
    await _errSub?.cancel();
    await _statusSub?.cancel();
    await sync.dispose();
    await playback.dispose();
  }
}
