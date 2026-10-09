import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../jellyfin/accounts.dart';
import '../jellyfin/progress.dart';
import '../jellyfin/session_media.dart';
import '../jellyfin/track_prefs.dart';
import '../playback/media_marks.dart';
import '../playback/playback_controller.dart';
import '../playback/yt_dlp_app.dart';
import '../schedule/anilist.dart';
import '../screens/home/picked_media.dart';
import '../sfx/sfx.dart';
import '../state/settings.dart';
import '../sync/avatar_cache.dart';
import '../sync/state_diff.dart';
import '../sync/sync_client.dart';
import '../sync/user_seek.dart';
import 'health.dart';
import 'idle.dart';
import 'media_art.dart';
import 'now_playing.dart';
import 'now_playing_info.dart';

/// Thrown when a connect is superseded by cancel/leave before it finished.
class ConnectCancelled implements Exception {
  const ConnectCancelled();
  @override
  String toString() => 'connection cancelled';
}

/// Display name for a link: last path segment, decoded, never the query
/// (Jellyfin-style links carry api_key there and names are broadcast).
String linkDisplayName(String url) => linkName(url);

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
}

/// The end-of-episode countdown (auto-advance). Every client with the
/// setting on shows it; only [swapper] puts the next episode up.
class AutoAdvance {
  final int mediaId;
  final int secondsLeft;
  final EpisodeLink next;
  /// This client performs the swap (see [autoAdvanceSwapper]).
  final bool swapper;
  const AutoAdvance(
      {required this.mediaId, required this.secondsLeft, required this.next, required this.swapper});
}

/// Seconds of the end-of-episode countdown.
const autoAdvanceSecs = 10;

class ToastItem {
  final int id;
  final String text;
  final DateTime at;
  /// The member a feed or chat toast is about (their name, as the feed
  /// carries it; [text] starts with it); null for the app's own toasts.
  final String? actor;
  const ToastItem({required this.id, required this.text, required this.at, this.actor});
}

const _toastActions = {'join', 'leave', 'kick', 'swap', 'chat'};

/// "Unready when the video changes": a state with a newer [mediaId] than
/// the last one this session saw ([lastMediaId], -1 before the first) while
/// self is ready (or a reconnect is restoring it). A swap keeps the
/// server's ready flags, so the client unreadies itself.
bool unreadyForNewMedia(
        {required bool enabled,
        required int lastMediaId,
        required int mediaId,
        required bool ready}) =>
    enabled && lastMediaId >= 0 && mediaId != lastMediaId && ready;

/// `media.relay` of a state, or null when the media is not relayed.
MediaRelay? stateMediaRelay(StateBroadcast state) {
  final r = state.media?['relay'];
  return r is Map ? MediaRelay.fromJson(Map<String, Object?>.from(r)) : null;
}

/// What this member serves when its own swap is relayed: set at swap time,
/// claimed by the state that names this member as the source.
sealed class _RelayOrigin {
  const _RelayOrigin();
}

final class _FileOrigin extends _RelayOrigin {
  final String path;
  const _FileOrigin(this.path);
}

final class _LinkOrigin extends _RelayOrigin {
  final String url;
  /// What the link is (a page goes through [ytDlp]).
  final LinkProbe probe;
  final YtDlp ytDlp;
  const _LinkOrigin(this.url, this.probe, this.ytDlp);
}

/// A Jellyfin item: served with this install's account, else with the
/// pasted [link] (its api_key stays on this machine).
final class _JellyfinOrigin extends _RelayOrigin {
  final String? link;
  const _JellyfinOrigin(this.link);
}

String? stateMediaUrl(StateBroadcast state) {
  final media = state.media;
  if (media == null) return null;
  final url = media['url'];
  if (url is String && url.isNotEmpty) return url;
  return null;
}

class SessionCoordinator {
  final SfxService sfx;
  /// Linked Jellyfin servers: how this viewer plays Jellyfin refs.
  final JellyfinAccounts jellyfin;
  /// Audio/subtitle carry-over between Jellyfin items.
  final TrackPrefs trackPrefs;
  /// Set by the hosting app: makes a local file the hosted one (File swap);
  /// null when this app is not the host.
  Future<({String name, int size})?> Function(String path)? hostFile;
  /// The app's yt-dlp and link probes (tests pass their own).
  final AppYtDlp ytDlp;
  final SyncClient sync = SyncClient();
  /// Member pictures by `avatarHash`, fetched from the server.
  late final AvatarCache avatars = AvatarCache(sync);
  /// The current media's poster and banner by `state.media.art` hash.
  late final ArtCache art = ArtCache(sync);
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

  /// The current media's Jellyfin ref (null for links and files).
  final currentRef = signal<JellyfinRef?>(null);
  /// Title, episode line and art hashes of the current media; null with
  /// nothing up.
  late final nowPlaying = computed<NowPlaying?>(() => nowPlayingOf(serverState.value?.media));
  /// How this viewer plays [currentRef]; null while resolving.
  final jellyfinPlan = signal<JellyfinPlan?>(null);
  /// Set when this viewer cannot play the Jellyfin media: no account and
  /// no relay. The session shows it with a way to link an account.
  final jellyfinBlocked = signal<BlockedPlay?>(null);
  /// Neighbouring episodes this viewer can put up (own account only).
  final previousEpisode = signal<EpisodeLink?>(null);
  final nextEpisode = signal<EpisodeLink?>(null);
  /// The floating "Next episode" pill near the end of an episode.
  final nextPromptVisible = signal(false);
  /// End-of-episode countdown; null when none runs here.
  final autoAdvance = signal<AutoAdvance?>(null);

  /// The skip pill for the current position ([skipOfferAt]: Skip OP,
  /// Skip ED, or Skip 1:30 without opening info or chapters); null while nothing
  /// is open or at `finished`. Press it with [skip].
  late final Computed<SkipOffer?> skipOffer = computed(() {
    final r = serverState.value;
    final duration = playback.duration.value;
    if (r == null || r.transport == 'finished' || duration <= Duration.zero) return null;
    return skipOfferAt(
      position: playback.position.value,
      duration: duration,
      opening: playback.opening.value,
      ending: playback.ending.value,
      chaptered: playback.chapters.value.isNotEmpty,
    );
  });

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
  // Last mediaId seen in a state; unlike [_mediaId] it survives a
  // reconnect, so only a real swap counts as a new video.
  int _seenMediaId = -1;
  // Bumped by every connect/leave/cancel/retry: stale attempts no-op.
  int _epoch = 0;
  Timer? _reconnectTimer;
  int _mediaId = -1;
  String? _openUrl;
  String _wsHost = '';
  int _wsPort = 0;
  _RelayOrigin? _pendingOrigin;
  // This client's last swap, until a state shows it landed (a newer
  // mediaId than [after] with this member as `swapBy`): its art goes up then.
  ({HelloMedia media, int after})? _pendingArt;
  AniListClient? _aniList;
  // What this member serves for media [$1]; survives a reconnect (the
  // state then looks new again).
  (int, _RelayOrigin)? _activeOrigin;
  RelaySource? _relaySource;
  int _relaySourceMediaId = -1;
  /// This member serves the current media's bytes through the server.
  final relaying = signal<bool>(false);
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
  /// The connection-lost sound played; the reconnected one answers it once.
  bool _lostSounded = false;
  Map<String, String>? _openHeaders;

  // Jellyfin: the resolved ref, the mediaId it belongs to, a generation
  // that stale resolutions check, and the progress reporter.
  JellyfinRef? _jfRef;
  int _jfMediaId = -1;
  int _jfGen = 0;
  JellyfinProgressReporter? _reporter;
  PlayerSnapshot? _lastSnap;
  bool _jfToastShown = false;
  Timer? _advanceTimer;
  int _advanceDoneFor = -1;
  String _blockedKey = '';
  bool _jellyfinListening = false;

  SessionCoordinator(
      {this.sfx = const NoopSfxService(), JellyfinAccounts? jellyfin, TrackPrefs? trackPrefs, AppYtDlp? ytDlp})
      : ytDlp = ytDlp ?? AppYtDlp.instance,
        jellyfin = jellyfin ?? JellyfinAccounts.instance,
        trackPrefs = trackPrefs ?? TrackPrefs();

  /// Player lifetime = one session: created here on connect, disposed by
  /// [leave]. Never reused across sessions (a GPU-side video freeze sticks
  /// to the player).
  Future<void> initPlayer() async {
    if (_playerReady) return;
    try {
      playback.onFrozen = () => unawaited(reloadVideo(auto: true));
      playback.onYtdlError = (e) => health.value = HealthStatus(HealthSeverity.error, "can't open this link: $e");
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
      final headers = _openHeaders;
      _openUrl = null;
      _clearPendingSeek();
      if (url != null) await _openMedia(url, headers: headers);
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
    _seenMediaId = -1;
    _wasPlayAllowed = false;
    _everConnected = false;
    _lostSounded = false;
    _resumeToken = '';
    _seekGate.reset();
    _clearPendingSeek();
    _lastEventId = -1;
    _resetJellyfin();
    _jfToastShown = false;
    if (!_jellyfinListening) {
      _jellyfinListening = true;
      jellyfin.addListener(_onAccountsChanged);
    }
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
      final media = params.media ??
          (params.linkUrl.isEmpty ? null : await mediaForLink(jellyfin, params.linkUrl));
      if (epoch != _epoch) throw const ConnectCancelled();
      if (media != null) _swap(media);
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
        _soundLost();
        _scheduleReconnect();
      }
    });
  }

  /// Opens [url] (with [headers] on every request); false on failure.
  Future<bool> _openMedia(String url, {Map<String, String>? headers}) async {
    if (url == _openUrl) return true;
    _openUrl = url;
    _openHeaders = headers;
    diff.reset();
    _opening = true;
    try {
      await _prepareYtDlp(url);
      await playback.openUrl(url, headers: headers);
      health.value =
          const HealthStatus(HealthSeverity.ok, 'connected');
      return true;
    } catch (e) {
      debugPrint('open media failed: $e');
      health.value =
          HealthStatus(HealthSeverity.error, 'cannot open media: $e');
      return false;
    } finally {
      _opening = false;
    }
  }

  /// A web link (not this server's): mpv's yt-dlp hook gets the app's
  /// managed yt-dlp, downloaded first if needed; a media file name does
  /// not wait for that.
  Future<void> _prepareYtDlp(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;
    if (uri.host == _wsHost && uri.port == _wsPort) return;
    try {
      final y = await ytDlp.ytDlp;
      final ready = y.ensure();
      final path = hasMediaExtension(uri)
          ? y.path
          : await ready.timeout(const Duration(seconds: 90), onTimeout: () => null);
      if (path != null) await playback.useYtDlp(path);
    } catch (e) {
      debugPrint('yt-dlp not ready: $e');
    }
  }

  bool _relayWaitShown = false;

  /// The server-fetched media this viewer opens once it is live.
  int _awaitLiveFor = -1;

  /// Relayed through a member whose channel is down: say who everyone is
  /// waiting for (the buffer still plays what it has).
  void _relayStatus(StateBroadcast r) {
    final relay = stateMediaRelay(r);
    final waiting = relay != null &&
        relay.source.isNotEmpty &&
        relay.source != sync.memberId &&
        !relay.live &&
        _openUrl != null &&
        jellyfinPlan.peek() is! OwnPlay;
    if (waiting) {
      final who = r.members.where((m) => m.id == relay.source).firstOrNull?.name;
      health.value = HealthStatus(HealthSeverity.warn,
          who == null ? 'the member who put this up left' : 'waiting for $who to pass the video on');
      _relayWaitShown = true;
    } else if (_relayWaitShown) {
      _relayWaitShown = false;
      health.value = const HealthStatus(HealthSeverity.ok, 'connected');
    }
  }

  String _relayMediaUrlFor(String name, int mediaId) =>
      'http://$_wsHost:$_wsPort/r/default/${sync.token}/$mediaId/${relayUrlName(name)}';

  /// Serves [bytes] for media [mediaId] on this member's relay channel.
  /// The server only pulls while someone watches through it.
  void _startRelaySource(int mediaId, RelayBytes bytes, {bool announce = false}) {
    // Back after a reconnect on the same media: it is still serving (and
    // redials by itself).
    if (_relaySource != null && _relaySourceMediaId == mediaId) {
      unawaited(bytes.close());
      return;
    }
    _stopRelaySource();
    final src = RelaySource(
        Uri.parse('ws://$_wsHost:$_wsPort/r/default/${sync.token}/source'), bytes);
    _relaySource = src;
    _relaySourceMediaId = mediaId;
    relaying.value = true;
    if (announce) {
      _pushToast('Passing the video on through the server. Keep the app open while it plays.');
    }
    unawaited(() async {
      try {
        await src.start();
      } catch (e) {
        debugPrint('relay source failed: $e');
        if (identical(_relaySource, src)) {
          _relaySource = null;
          relaying.value = false;
          _pushToast('Cannot pass the video on: $e');
        }
        return;
      }
      await src.done;
      if (identical(_relaySource, src)) {
        _relaySource = null;
        relaying.value = false;
      }
    }());
  }

  void _stopRelaySource() {
    final src = _relaySource;
    _relaySource = null;
    _relaySourceMediaId = -1;
    relaying.value = false;
    if (src != null) unawaited(src.close());
  }

  String _fileUrlFor(String name) {
    return 'http://$_wsHost:$_wsPort/m/default/${sync.token}/${Uri.encodeComponent(name)}';
  }

  StateBroadcast? _queuedState;
  bool _applying = false;

  /// States are applied one at a time, newest first: two applies running
  /// interleaved could land an older pause after a newer play (seen with
  /// three viewers readying at once). A state that arrives meanwhile
  /// replaces any still waiting.
  void _onState(StateBroadcast r) {
    _lastStateAt = DateTime.now().toUtc();
    serverState.value = r;
    _maybeSendArt(r);
    _queuedState = r;
    if (_applying) return;
    _applying = true;
    () async {
      try {
        while (_queuedState != null) {
          final next = _queuedState!;
          _queuedState = null;
          try {
            await _applyState(next);
          } catch (e, st) {
            debugPrint('apply state failed: $e\n$st');
          }
        }
      } finally {
        _applying = false;
      }
    }();
  }

  Future<void> _applyState(StateBroadcast r) async {
    _trackSelfReady(r);
    _seekGate.observe(r, sync.memberId);
    final newEvent = r.eventId != _lastEventId;
    _lastEventId = r.eventId;
    if (r.mediaId != _mediaId) {
      _mediaId = r.mediaId;
      final ref = refOfStateMedia(r.media);
      // Back after a dropped connection on the same item played with our
      // own account: nothing to resolve or reopen.
      final same = ref != null &&
          r.mediaId == _jfMediaId &&
          sameJellyfinItem(ref, _jfRef) &&
          jellyfinPlan.peek() is OwnPlay;
      final relay = stateMediaRelay(r);
      final mine = relay != null && relay.source.isNotEmpty && relay.source == sync.memberId;
      _RelayOrigin? origin;
      if (mine) {
        final pending = _pendingOrigin;
        if (pending != null) {
          _pendingOrigin = null;
          _activeOrigin = (r.mediaId, pending);
        }
        origin = _activeOrigin?.$1 == r.mediaId ? _activeOrigin!.$2 : null;
      }
      if (_relaySourceMediaId != r.mediaId) _stopRelaySource();
      if (!same) {
        _seekGate.reset();
        _clearPendingSeek();
        _leaveJellyfinItem();
        final name = (r.media?['name'] as String?) ?? '';
        if (ref != null) {
          await _playJellyfin(ref, r,
              origin: origin is _JellyfinOrigin ? origin : null,
              memberRelayUrl: relay != null && !mine ? _relayMediaUrlFor(name, r.mediaId) : null);
        } else if (origin is _FileOrigin) {
          await _openMedia(origin.path);
          _startRelaySource(r.mediaId, FileRelayBytes(File(origin.path)), announce: true);
        } else if (origin is _LinkOrigin) {
          await _openMedia(origin.url);
          _startRelaySource(
              r.mediaId, LinkRelayBytes(Uri.parse(origin.url), ytDlp: origin.ytDlp, probe: origin.probe),
              announce: true);
        } else if (relay != null && !mine) {
          if (relay.fetch && !relay.live) {
            // The server is still getting it (yt-dlp takes seconds; mpv
            // gives up on a silent request after 5): open once it is live.
            _openUrl = null;
            _awaitLiveFor = r.mediaId;
            health.value = const HealthStatus(HealthSeverity.info, 'the server is getting the video…');
          } else {
            await _openMedia(_relayMediaUrlFor(name, r.mediaId));
          }
        } else {
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
        }
      }
      _seekGate.reset();
      _clearPendingSeek();
    } else if (_awaitLiveFor == r.mediaId && (stateMediaRelay(r)?.live ?? false)) {
      _awaitLiveFor = -1;
      await _openMedia(_relayMediaUrlFor((r.media?['name'] as String?) ?? '', r.mediaId));
    }
    _jellyfinTransport(r);
    _relayStatus(r);
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
    // [_seenMediaId], not [_mediaId]: that one is -1 after a lost
    // connection, which would end the restore before its echo.
    if (_seenMediaId >= 0 && r.mediaId != _seenMediaId) _restoringReady = false;
    if (_restoringReady) {
      if (self.ready) _restoringReady = false;
    } else {
      _lastReady = self.ready;
    }
    final last = _seenMediaId;
    _seenMediaId = r.mediaId;
    // A ready restored by a reconnect may not have echoed yet: unready
    // anyway (it was sent first, so this one lands last).
    if (unreadyForNewMedia(
        enabled: AppSettings.instance.unreadyOnSwap.peek(),
        lastMediaId: last,
        mediaId: r.mediaId,
        ready: self.ready || _restoringReady)) {
      _lastReady = false;
      _restoringReady = false;
      sync.sendReady(false, source: 'auto');
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
      if (m.inSet && m.buffered < r.bufferNeed) {
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
        ToastItem(id: _toastId, text: text, at: DateTime.now().toUtc(), actor: f.actor)
      ];
    }
    final kind = sfxForFeedAction(f.action);
    // Your own message needs no sound.
    final own = f.action == 'chat' && f.actor == selfMember.peek()?.name;
    if (kind != null && !own) {
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
    await _stopJellyfin();
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
        jf: _jfAccessFor(r),
      );
      _checkSeekLanded(r);
      unawaited(_tickJellyfin(r));
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
        _soundLost();
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

  /// A skip pill: Skip OP / Skip ED seek to the range's end, Skip 1:30
  /// is [skipForward]. Through the user-seek path, so everyone follows.
  void skip(SkipOffer offer) {
    if (offer.kind == SkipKind.fixed) {
      skipForward();
    } else {
      seekTo(offer.target.inMicroseconds / 1e6);
    }
  }

  /// +[fallbackSkip] (1:30): the controls' button, Shift+Right and the
  /// fallback pill. Relative to a seek in flight, like the arrow keys.
  void skipForward() => nudge(fallbackSkip.inMicroseconds / 1e6);

  /// PgDn (+1) / PgUp (-1): next / previous chapter as mpv steps them
  /// ([chapterStepTarget]). False when there is no chapter to go to.
  bool stepChapter(int delta) {
    final base = _seekGate.target;
    final at = base == null
        ? playback.position.peek()
        : Duration(microseconds: (base * 1e6).round());
    final target = chapterStepTarget(playback.chapters.peek(), at, delta);
    if (target == null) return false;
    seekTo(target.inMicroseconds / 1e6);
    return true;
  }

  void sendChat(String text) {
    // Enter in the chat field can fire both onSubmitted and the focused
    // send button's onPressed; the first send clears the field, so the
    // second arrives empty. Drop blanks so at most one message ships.
    if (text.trim().isEmpty) return;
    markInput();
    sync.sendChat(text);
  }

  /// Name and/or picture (base64 PNG, empty removes it) change for
  /// everyone now; a later fresh join sends them too.
  void updateProfile({String? name, String? avatar}) {
    final p = _params;
    if (p != null) {
      _params = ConnectParams(
        host: p.host,
        port: p.port,
        secret: p.secret,
        name: name ?? p.name,
        avatar: avatar ?? p.avatar,
        mediaPath: p.mediaPath,
        linkUrl: p.linkUrl,
        hostKey: p.hostKey,
        media: p.media,
      );
    }
    sync.sendProfile(name: name, avatar: avatar);
  }

  void kick(String memberId, {String reason = ''}) {
    markInput();
    sync.sendKick(memberId, reason: reason);
  }

  void _swap(HelloMedia media) {
    _pendingArt = (media: media, after: serverState.peek()?.mediaId ?? 0);
    sync.sendSwap(media);
  }

  void _maybeSendArt(StateBroadcast r) {
    final pending = _pendingArt;
    if (pending == null || r.mediaId <= pending.after) return;
    if (sync.memberId.isEmpty || r.media?['swapBy'] != sync.memberId) return;
    _pendingArt = null;
    unawaited(_sendArt(r.mediaId, pending.media));
  }

  /// Fetches the art of [media] (this client's swap, now [mediaId]) and
  /// sends it; quietly nothing on any failure.
  Future<void> _sendArt(int mediaId, HelloMedia media) async {
    try {
      final ref = media.jellyfin;
      final client = ref == null ? null : jellyfin.clientFor(ref.serverId);
      final ArtBytes? bytes;
      if (ref != null && client != null) {
        bytes = await jellyfinArt(client, ref.itemId);
      } else if (ref == null && (media.url ?? '').isNotEmpty) {
        // A web link is not a show: never guess. A page's thumbnail is
        // its banner.
        final thumb = (await _probeFor(media.url!))?.info?.thumbnail;
        final uri = thumb == null ? null : Uri.tryParse(thumb);
        bytes = uri == null ? null : (banner: await fetchImage(uri, const {}, RelayConstants.maxBannerBytes), poster: null);
      } else {
        final name = ref == null ? media.name : jellyfinTitle(ref.title, ref.subtitle).$1;
        bytes = await aniListArt(_aniList ??= AniListClient(), name);
      }
      final poster = bytes?.poster, banner = bytes?.banner;
      if (poster == null && banner == null) return;
      if (serverState.peek()?.mediaId != mediaId) return;
      sync.sendArt(mediaId,
          poster: poster == null ? null : base64Encode(poster),
          banner: banner == null ? null : base64Encode(banner));
    } catch (e) {
      debugPrint('art for media $mediaId: $e');
    }
  }

  /// A pasted link: a recognised Jellyfin item link goes up as a ref
  /// (see [mediaForLink]) that this member relays for viewers without an
  /// account (with the link's key, which stays here); anything else as the
  /// link, or relayed per [relay]. Returns an error text, or null when sent.
  Future<String?> swapLink(String url, {LinkRelay relay = LinkRelay.direct}) async {
    markInput();
    final media = await mediaForLink(jellyfin, url);
    if (media.jellyfin != null) {
      _pendingOrigin = _JellyfinOrigin(url);
      _swap(media.copyWith(relay: const MediaRelay()));
      return null;
    }
    LinkProbe? probe;
    String? probeError;
    try {
      probe = await ytDlp.probe(url).timeout(const Duration(seconds: 45));
    } catch (e) {
      probeError = '$e';
    }
    // A page is named by its title, never its URL tail ("1", "watch").
    final uri = Uri.tryParse(url) ?? Uri();
    final name = probe?.title ?? (probe != null || hasMediaExtension(uri) || uri.host.isEmpty ? media.name : uri.host);
    if (relay == LinkRelay.direct) {
      _swap(HelloMedia(name: name, size: 0, duration: 0, url: url));
      return null;
    }
    if (relay == LinkRelay.me) {
      // This computer reads it: a file, or a page's single-file format.
      if (probe == null) return 'cannot pass this link on: $probeError';
      final problem = probe.relayProblem;
      if (problem != null) return problem;
      final y = await ytDlp.ytDlp;
      final check = LinkRelayBytes(uri, ytDlp: y, probe: probe);
      final int size;
      try {
        size = await check.size().timeout(const Duration(seconds: 15));
      } catch (e) {
        return 'cannot pass this link on: $e';
      } finally {
        await check.close();
      }
      _pendingOrigin = _LinkOrigin(url, probe, y);
      _swap(HelloMedia(name: name, size: size, duration: 0, relay: const MediaRelay()));
      return null;
    }
    // The server reads it with its own yt-dlp; only a page this app knows
    // has no single file is refused here (the server may reach what this
    // computer cannot).
    if (probe != null && probe.isPage && probe.info != null && probe.info!.single == null) {
      return noSingleFileText;
    }
    _swap(HelloMedia(
        name: name, size: max(0, probe?.size ?? 0), duration: 0, url: url, relay: const MediaRelay(fetch: true)));
    return null;
  }

  Future<LinkProbe?> _probeFor(String url) async {
    try {
      return await ytDlp.probe(url).timeout(const Duration(seconds: 45));
    } catch (_) {
      return null;
    }
  }

  /// A Jellyfin pick (browser, next / previous episode) goes up as a ref,
  /// relayed by this member for viewers without an account.
  void swapJellyfin(JellyfinMedia media) {
    markInput();
    _pendingOrigin = const _JellyfinOrigin(null);
    _swap(mediaForPick(media).copyWith(relay: const MediaRelay()));
  }

  /// A file on this computer. The host's app serves it itself; anyone
  /// else's goes through the server's relay. Returns an error text, or null
  /// when sent.
  Future<String?> swapFile(String path) async {
    markInput();
    final host = hostFile;
    if (host != null) {
      final file = await host(path);
      if (file == null) return 'file not found — check the path';
      _swap(HelloMedia(name: file.name, size: file.size, duration: 0));
      return null;
    }
    final file = File(path);
    if (!await file.exists()) return 'file not found — check the path';
    _pendingOrigin = _FileOrigin(path);
    _swap(HelloMedia(
        name: file.uri.pathSegments.last, size: await file.length(), duration: 0, relay: const MediaRelay()));
    return null;
  }

  /// Any picker selection.
  Future<String?> swapPicked(PickedMedia media) async {
    switch (media) {
      case LinkMedia(:final url, :final relay):
        return swapLink(url, relay: relay);
      case JellyfinMedia():
        swapJellyfin(media);
      case FileMedia(:final path):
        return swapFile(path);
    }
    return null;
  }

  void playNextEpisode() {
    final n = nextEpisode.peek();
    if (n != null) swapJellyfin(n.pick);
  }

  void playPreviousEpisode() {
    final p = previousEpisode.peek();
    if (p != null) swapJellyfin(p.pick);
  }

  /// Hides the countdown here; this client will not auto-advance this
  /// item (if it is the swapper, nobody does).
  void cancelAutoAdvance() {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    final a = autoAdvance.peek();
    if (a != null) _advanceDoneFor = a.mediaId;
    autoAdvance.value = null;
  }

  // ------------------------------------------------------------- jellyfin

  /// A toast from outside the session (e.g. the Schedule tab's request
  /// results), shown like the session's own.
  void showToast(String text) => _pushToast(text);

  void _pushToast(String text) {
    _toastId++;
    toasts.value = [
      ...toasts.peek(),
      ToastItem(id: _toastId, text: text, at: DateTime.now().toUtc())
    ];
  }

  void _resetJellyfin() {
    _jfGen++;
    _jfRef = null;
    _jfMediaId = -1;
    _reporter = null;
    _lastSnap = null;
    _openHeaders = null;
    _blockedKey = '';
    currentRef.value = null;
    jellyfinPlan.value = null;
    jellyfinBlocked.value = null;
    previousEpisode.value = null;
    nextEpisode.value = null;
    nextPromptVisible.value = false;
    playback.segments.value = const [];
    _advanceTimer?.cancel();
    _advanceTimer = null;
    _advanceDoneFor = -1;
    autoAdvance.value = null;
  }

  /// The current item is being replaced: Stopped goes out (not awaited:
  /// reports are sent in order), per-item state clears.
  void _leaveJellyfinItem() {
    final reporter = _reporter;
    final snap = _snapNow();
    _resetJellyfin();
    if (reporter != null && snap != null) unawaited(reporter.stop(snap));
  }

  /// Leave / kick / window close: Stopped, bounded so leaving never hangs.
  Future<void> _stopJellyfin() async {
    final reporter = _reporter;
    final snap = _snapNow();
    _resetJellyfin();
    if (reporter == null || snap == null) return;
    try {
      await reporter.stop(snap).timeout(const Duration(milliseconds: 1500));
    } catch (_) {}
  }

  /// The last sampled tracks with the position as of now.
  PlayerSnapshot? _snapNow() {
    if (!_playerReady) return _lastSnap;
    final last = _lastSnap;
    return PlayerSnapshot(
      position: playback.positionSecs,
      paused: !playback.player.state.playing,
      aid: last?.aid,
      sid: last?.sid,
    );
  }

  Future<PlayerSnapshot?> _snapshot() async {
    if (!_playerReady) return null;
    final ids = await playback.currentTrackIds();
    if (!_playerReady) return null;
    return _lastSnap = PlayerSnapshot(
      position: playback.positionSecs,
      paused: !playback.player.state.playing,
      aid: ids.aid,
      sid: ids.sid,
    );
  }

  String? _relayUrlFor(JellyfinRef ref) {
    if (sync.token.isEmpty) return null;
    final welcome = sync.relayUrl;
    if (welcome != null &&
        welcome.contains('/${sync.token}/') &&
        welcome.endsWith('/${Uri.encodeComponent(ref.itemId)}')) {
      return welcome;
    }
    return relayUrlFor(_wsHost, _wsPort, sync.token, ref.itemId);
  }

  Map<String, bool>? _jfAccessFor(StateBroadcast r) {
    final ref = _jfRef;
    final access = jellyfinPlan.peek()?.jfAccess;
    if (ref == null || access == null || r.mediaId != _jfMediaId) return null;
    return {ref.serverId: access};
  }

  /// Resolves [ref] for this viewer and opens it: own account (direct
  /// play, progress reports, neighbouring episodes), the relay, or the
  /// blocked state. Then carries the audio/subtitle choice over.
  Future<void> _playJellyfin(JellyfinRef ref, StateBroadcast r,
      {_JellyfinOrigin? origin, String? memberRelayUrl}) async {
    final gen = ++_jfGen;
    _jfRef = ref;
    _jfMediaId = r.mediaId;
    currentRef.value = ref;
    // Until it resolves nothing is open: no syncing the previous media.
    final prevUrl = _openUrl;
    _openUrl = null;
    _opening = true;
    if (_playerReady) {
      try {
        await playback.player.pause();
      } catch (_) {}
    }
    JellyfinPlan plan;
    try {
      plan = await resolveJellyfinRef(jellyfin, ref,
          relay: r.relay, relayUrl: _relayUrlFor(ref), memberRelayUrl: memberRelayUrl);
    } finally {
      if (gen == _jfGen) _opening = false;
    }
    if (gen != _jfGen) return;
    // This member put it up: serve it to viewers without an account, with
    // its own sign-in, else the pasted link (played directly here too).
    if (origin != null) {
      if (plan is OwnPlay) {
        _startRelaySource(r.mediaId, HttpRelayBytes(Uri.parse(plan.url), headers: plan.headers));
      } else if (origin.link != null) {
        plan = RelayPlay(origin.link!);
        _startRelaySource(r.mediaId, HttpRelayBytes(Uri.parse(origin.link!)));
      }
    }
    jellyfinPlan.value = plan;
    switch (plan) {
      case BlockedPlay():
        jellyfinBlocked.value = plan;
        _blockedKey = _accountKey(ref.serverId);
        try {
          await playback.stop();
        } catch (_) {}
        return;
      case RelayPlay(:final url):
        jellyfinBlocked.value = null;
        // Same relay URL (resumed member): the player still has it.
        if (url == prevUrl) {
          _openUrl = url;
          return;
        }
        if (!await _openMedia(url) || gen != _jfGen) return;
      case OwnPlay(:final url, :final headers):
        jellyfinBlocked.value = null;
        if (!await _openMedia(url, headers: headers) || gen != _jfGen) return;
        final reporter = JellyfinProgressReporter(
          client: plan.client,
          itemId: ref.itemId,
          source: plan.source,
          playSessionId: plan.info.playSessionId,
          onUnauthorized: () => jellyfin.markExpired(ref.serverId),
          onError: (e) {
            if (_jfToastShown) return;
            _jfToastShown = true;
            _pushToast('Jellyfin progress not saved: ${e is JellyfinException && e.isUnauthorized ? 'sign-in expired' : 'server unreachable'}');
          },
        );
        unawaited(_findEpisodes(plan, gen));
        unawaited(_loadSegments(plan, ref, gen));
        // Playing carries the tracks: wait (bounded) until the file is in.
        await playback.waitForTracks();
        if (gen != _jfGen) return;
        final snap = await _snapshot();
        if (gen != _jfGen || snap == null) return;
        // Installed once started: the per-state restart (after the end)
        // must not send the first Playing without the tracks.
        _reporter = reporter..start(snap);
    }
    await _applyTrackChoice(plan, gen);
  }

  Future<void> _findEpisodes(OwnPlay plan, int gen) async {
    final around = await findAdjacentEpisodes(plan);
    if (gen != _jfGen) return;
    previousEpisode.value = around.previous;
    nextEpisode.value = around.next;
    final r = serverState.peek();
    if (r != null) _jellyfinTransport(r);
  }

  /// The item's MediaSegments (own account only; a server without the
  /// endpoint or without a segment provider gives none).
  Future<void> _loadSegments(OwnPlay plan, JellyfinRef ref, int gen) async {
    try {
      final list = await plan.client.mediaSegments(ref.itemId).timeout(const Duration(seconds: 15));
      if (gen != _jfGen) return;
      playback.segments.value = [for (final s in list) MediaSegment.fromJellyfin(s)];
    } catch (e) {
      debugPrint('media segments for ${ref.itemId} failed: $e');
    }
  }

  Future<void> _applyTrackChoice(JellyfinPlan plan, int gen) async {
    final own = plan is OwnPlay ? plan : null;
    final choice = await trackPrefs.load(seriesId: own?.item?.seriesId);
    if (choice == null || gen != _jfGen || !_playerReady) return;
    final tracks = await playback.waitForTracks();
    if (gen != _jfGen) return;
    final pick = chooseTracks(choice, source: own?.source, tracks: tracks);
    await playback.selectTracks(aid: pick.aid, sid: pick.sid, subtitlesOff: pick.subtitlesOff);
  }

  /// A track picked in the player: applied, remembered for the next
  /// Jellyfin item (per series and overall), reported.
  Future<void> selectTrack({int? aid, int? sid, bool subtitlesOff = false}) async {
    markInput();
    await playback.selectTracks(aid: aid, sid: sid, subtitlesOff: subtitlesOff);
    final ids = await playback.currentTrackIds();
    final plan = jellyfinPlan.peek();
    final own = plan is OwnPlay ? plan : null;
    await trackPrefs.save(
        TrackChoice.of(aid: ids.aid, sid: ids.sid, source: own?.source, tracks: playback.tracks.peek()),
        seriesId: own?.item?.seriesId);
    final snap = await _snapshot();
    if (snap != null) _reporter?.update(snap, force: true);
  }

  Future<void> _tickJellyfin(StateBroadcast r) async {
    final reporter = _reporter;
    if (_jfRef == null || r.mediaId != _jfMediaId) return;
    final snap = await _snapshot();
    if (snap == null) return;
    if (reporter != null && identical(reporter, _reporter) && r.transport != 'finished') {
      reporter.update(snap);
    }
    final next = nextEpisode.peek();
    final duration = playback.durationSecs;
    var show = false;
    if (next != null && duration > 0 && autoAdvance.peek() == null && r.transport != 'finished') {
      final item = (jellyfinPlan.peek() as OwnPlay?)?.item;
      final at = nextPromptStart(item, Duration(milliseconds: (duration * 1000).round()),
          endingStart: playback.ending.peek()?.start);
      show = snap.position * 1000 >= at.inMilliseconds;
    }
    nextPromptVisible.value = show;
  }

  /// Per state: played to the end -> Stopped (Jellyfin marks it watched)
  /// and the auto-advance countdown; seeked back from the end -> Playing
  /// again.
  void _jellyfinTransport(StateBroadcast r) {
    final ref = _jfRef;
    if (ref == null || r.mediaId != _jfMediaId) return;
    final reporter = _reporter;
    final finished = r.transport == 'finished';
    if (reporter != null && _openUrl != null && !_opening) {
      final snap = _snapNow();
      if (finished && reporter.active && snap != null) {
        unawaited(reporter.stop(PlayerSnapshot(
            position: r.position, paused: true, aid: snap.aid, sid: snap.sid)));
      } else if (!finished && !reporter.active && snap != null) {
        reporter.start(snap);
      }
    }
    if (!finished) {
      if (autoAdvance.peek() != null) cancelAutoAdvance();
      _advanceDoneFor = -1;
      return;
    }
    nextPromptVisible.value = false;
    final next = nextEpisode.peek();
    if (next == null ||
        !AppSettings.instance.autoAdvance.peek() ||
        _advanceDoneFor == r.mediaId ||
        autoAdvance.peek()?.mediaId == r.mediaId) {
      return;
    }
    autoAdvance.value = AutoAdvance(
        mediaId: r.mediaId, secondsLeft: autoAdvanceSecs, next: next, swapper: _isSwapper(r, ref));
    _advanceTimer?.cancel();
    _advanceTimer = Timer.periodic(const Duration(seconds: 1), (_) => _advanceTick());
  }

  bool _isSwapper(StateBroadcast r, JellyfinRef ref) =>
      autoAdvanceSwapper(r.members, ref.serverId) == sync.memberId;

  void _advanceTick() {
    final a = autoAdvance.peek();
    final r = serverState.peek();
    final ref = _jfRef;
    if (a == null || r == null || ref == null || r.mediaId != a.mediaId || r.transport != 'finished') {
      cancelAutoAdvance();
      return;
    }
    final left = a.secondsLeft - 1;
    if (left > 0) {
      autoAdvance.value = AutoAdvance(
          mediaId: a.mediaId, secondsLeft: left, next: a.next, swapper: _isSwapper(r, ref));
      return;
    }
    // Decided on the latest state: one swapper among the clients counting.
    final swap = _isSwapper(r, ref);
    cancelAutoAdvance();
    if (swap) swapJellyfin(a.next.pick);
  }

  String _accountKey(String serverId) =>
      '${jellyfin.account(serverId)?.token}|${jellyfin.statusOf(serverId).name}';

  /// A blocked viewer links (or reconnects) the account: try again.
  void _onAccountsChanged() {
    final blocked = jellyfinBlocked.peek();
    if (blocked == null) return;
    final key = _accountKey(blocked.serverId);
    if (key == _blockedKey) return;
    _blockedKey = key;
    final status = jellyfin.statusOf(blocked.serverId);
    if (jellyfin.account(blocked.serverId) == null ||
        status == JellyfinAccountStatus.expired ||
        status == JellyfinAccountStatus.checking) {
      return;
    }
    retryJellyfin();
  }

  /// "Try again" on the blocked card (and after linking an account).
  void retryJellyfin() {
    final r = serverState.peek();
    final ref = refOfStateMedia(r?.media);
    if (r == null || ref == null) return;
    unawaited(_playJellyfin(ref, r));
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
    var wantReady = _lastReady;
    final seenBefore = _seenMediaId;
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
      if (_lostSounded) {
        _lostSounded = false;
        unawaited(sfx.play(const SfxCue(SfxKind.back)));
      }
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
      // Not when the video changed meanwhile and the user unreadies then.
      if (unreadyForNewMedia(
          enabled: AppSettings.instance.unreadyOnSwap.peek(),
          lastMediaId: seenBefore,
          mediaId: sync.lastState?.mediaId ?? seenBefore,
          ready: wantReady)) {
        wantReady = false;
        _lastReady = false;
      }
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

  void _soundLost() {
    if (!_everConnected || _lostSounded) return;
    _lostSounded = true;
    unawaited(sfx.play(const SfxCue(SfxKind.lost)));
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
    await _stopJellyfin();
    _stopRelaySource();
    _pendingOrigin = null;
    _pendingArt = null;
    _activeOrigin = null;
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
    if (_jellyfinListening) {
      _jellyfinListening = false;
      jellyfin.removeListener(_onAccountsChanged);
    }
    await _stateSub?.cancel();
    await _feedSub?.cancel();
    await _kickSub?.cancel();
    await _errSub?.cancel();
    await _statusSub?.cancel();
    _aniList?.close();
    await sync.dispose();
    await playback.dispose();
  }
}
