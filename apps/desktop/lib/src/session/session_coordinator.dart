import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../jellyfin/accounts.dart';
import '../jellyfin/progress.dart';
import '../jellyfin/session_media.dart';
import '../jellyfin/track_prefs.dart';
import '../library/media_refs.dart';
import '../playback/media_marks.dart';
import '../playback/playback_controller.dart';
import '../platform/ports/link_resolver.dart';
import '../playback/yt_dlp_app.dart' show AppYtDlp;
import '../schedule/anilist.dart';
import '../screens/home/picked_media.dart';
import '../sfx/sfx.dart' show NoopSfxService, SfxService;
import '../state/settings.dart';
import '../sync/avatar_cache.dart';
import '../sync/state_diff.dart';
import '../sync/user_seek.dart';
import '../queue/queue_controller.dart';
import '../platform/ports/shell_port.dart' show WindowActivity;
import 'auto_sit_out.dart';
import 'connection.dart';
import 'delivery.dart';
import 'media_art.dart';
import 'notifier.dart';
import 'now_playing.dart';
import 'now_playing_info.dart';
import 'party.dart';
import 'status.dart';
import 'switch_trace.dart';

export 'connection.dart' show ConnectCancelled, ConnectParams;
export 'notifier.dart' show ToastItem;
export 'delivery.dart' show stateMediaRelay;
export 'status.dart';

final _log = createLogger('session');

/// Display name for a link: last path segment, decoded, never the query
/// (Jellyfin-style links carry api_key there and names are broadcast).
String linkDisplayName(String url) => linkName(url);

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

/// "Unready when the video changes": a state with a newer [mediaId] than
/// the last one this session saw ([lastMediaId], -1 before the first) while
/// self is ready (or a fresh member after a reconnect is restoring it). A
/// swap keeps the server's ready flags, so the client unreadies itself.
bool unreadyForNewMedia(
        {required bool enabled,
        required int lastMediaId,
        required int mediaId,
        required bool ready}) =>
    enabled && lastMediaId >= 0 && mediaId != lastMediaId && ready;

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
  /// Toasts, sounds and the activity log: every event goes through
  /// [notify].
  final Notifier notifier;
  /// Linked Jellyfin servers: how this viewer plays Jellyfin refs.
  final JellyfinAccounts jellyfin;
  /// Audio/subtitle carry-over between Jellyfin items.
  final TrackPrefs trackPrefs;
  /// Set by the hosting app: makes a local file the hosted one (File swap);
  /// null when this app is not the host.
  Future<({String name, int size})?> Function(String path)? hostFile;
  /// What a local file is (`media.ref`, from the library: `ShowMatcher`),
  /// set by the composition root; null: files go up without one.
  MediaRef? Function(String path)? fileRef;
  /// The app's yt-dlp and link probes (tests pass their own).
  final LinkResolver ytDlp;
  /// The link to the server (socket, reconnects, clock offset, its
  /// [ConnState]); made in the composition root.
  final Connection connection;
  /// This app's log lines to the server's session log ([Connection.diag]).
  DiagUploader get diag => connection.diag;

  /// "Mark a problem": a marker with [note] in the server's session log
  /// (and this app's log). False when not in a session: then only this
  /// app's log has it.
  Future<bool> markProblem(String note) async {
    if (!diag.running) {
      createLogger(DiagUploader.markLogger).warning('=== PROBLEM marked${note.trim().isEmpty ? '' : ': ${note.trim()}'} ===');
      return false;
    }
    await diag.markProblem(note);
    return true;
  }

  /// The server's session log of the last [hours], null when not in a
  /// session or the server has none.
  Future<String?> sessionLog({int hours = 6}) => diag.fetchSessionLog(hours: hours);
  /// Up next: the server's queue, adding to it, and putting items up.
  late final QueueController queue = QueueController(this);
  /// The server has a password (it fetches links only then).
  bool get serverHasPassword => (connection.params?.secret ?? '').isNotEmpty;
  /// Member pictures by `avatarHash`, fetched from the server.
  late final AvatarCache avatars = AvatarCache(connection.client);
  /// The current media's poster and banner by `state.media.art` hash.
  late final ArtCache art = ArtCache(connection.client);
  final PlaybackController playback = PlaybackController();
  /// Timings of each media change here (see [SwitchTrace]).
  final SwitchTrace switchTrace = SwitchTrace();
  final StateDiff diff = StateDiff();

  /// The server's latest state. A drop keeps it (with the player, the
  /// media and a relay this member serves): [stateStale] says it is not
  /// current; only leaving clears it.
  final serverState = signal<StateBroadcast?>(null);
  /// [serverState] is from before a drop: the connection is reconnecting
  /// or ended (replaced, refused).
  late final Computed<bool> stateStale = computed(() {
    final s = connection.state.value;
    return serverState.value != null && (s.retrying || s is ConnReplaced || s is ConnRefused);
  });
  /// The activity log ([Notifier.feedLog]).
  Signal<List<FeedMessage>> get feedLog => notifier.feedLog;
  /// Toasts on screen ([Notifier.toasts]).
  Signal<List<ToastItem>> get toasts => notifier.toasts;
  /// The reconnect loop runs ([ConnState.retrying]).
  late final Computed<bool> reconnecting = computed(() => connection.state.value.retrying);
  /// The link is up but went quiet ([ConnUnstable]).
  late final Computed<bool> unstable = computed(() => connection.state.value is ConnUnstable);
  /// The player itself failed (a "Reload video" that failed); '' when
  /// fine. A fact for [status].
  final playerFault = signal('');
  /// The mediaId the server said it could not fetch (`fetch-fail`); -1.
  final fetchFailedFor = signal(-1);
  /// Reconnects that found the server restarted (another
  /// `welcome.instance`).
  final restarts = signal(0);
  // The status's clock, moved on by the tick when the minute changes (a
  // "(2 min)" in it).
  final _clock = signal(DateTime.now().toUtc());

  /// The one computed status (session/status.dart): the player's pill,
  /// the strip's line, the members card's source line. Nothing sets it;
  /// [StatusWatch] turns its transitions into notices.
  late final Computed<Status> status = computed(() {
    final plan = jellyfinPlan.value;
    return statusOf(StatusFacts(
      conn: connection.state.value,
      state: serverState.value,
      selfId: connection.memberId,
      playerError: playerError.value,
      playerFault: playerFault.value,
      ownPlan: plan is OwnPlay,
      fetchFailedFor: fetchFailedFor.value,
      names: memberNames,
      restarts: restarts.value,
      now: _clock.value,
    ));
  });
  final StatusWatch _statusWatch = StatusWatch();
  void Function()? _statusEffect;
  /// Why this player cannot open the current media, in plain words
  /// ([playErrorText]); empty while it can. It rides in `report.error`, so
  /// the server stops waiting for this member and the others see it.
  final playerError = signal('');

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
  /// An item this app is about to put up, resolved ahead with its own
  /// account (Up next's first item, the next episode; see
  /// `QueueController`): opening it then skips PlaybackInfo. Used once,
  /// until [until].
  ({JellyfinRef ref, OwnPlay plan, DateTime until})? warmJellyfin;
  /// Neighbouring episodes this viewer can put up (own account only).
  final previousEpisode = signal<EpisodeLink?>(null);
  final nextEpisode = signal<EpisodeLink?>(null);
  /// The "Next episode" pill's window ([nextPromptStart]: the known ending,
  /// else the last two minutes); the pill shows in it only while the
  /// controls are up.
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
    if (r == null || connection.memberId.isEmpty) return null;
    for (final m in r.members) {
      if (m.id == connection.memberId) return m;
    }
    return null;
  });

  /// Self sits out (`away`): the player has nothing open until [joinBack].
  late final Computed<bool> selfAway = computed(() => selfMember.value?.presence == Presence.away);

  Timer? _ticker;
  StreamSubscription? _stateSub;
  StreamSubscription? _feedSub;
  StreamSubscription? _nudgeSub;
  StreamSubscription? _errSub;

  /// Nobody else is in the server (D9): a plain player, Play rather than
  /// Ready, links go up direct. Also true before the first state.
  late final Computed<bool> alone = computed(() {
    final r = serverState.value;
    return r == null || aloneIn(r.members, connection.memberId);
  });
  bool _playerReady = false;
  bool _wasPlayAllowed = false;
  // Last ready flag the server reported for self; sent again when a
  // reconnect lands as a new member (grace over, server restarted).
  bool _lastReady = false;
  // Set after such a reconnect until the server echoes the restored
  // ready, so the fresh member's ready=false doesn't overwrite [_lastReady].
  bool _restoringReady = false;
  // Self is `away` in the last state; a reconnect that lands as a new
  // member sits out again.
  bool _lastAway = false;
  // [joinBack] ran while playing: ready once the player has buffered
  // (or after [_joinBackWait]), so the others do not pause for the load.
  DateTime? _joinBackAt;
  static const _joinBackWait = Duration(seconds: 15);
  // Last mediaId seen in a state; unlike [_mediaId] it survives sitting
  // out, so only a real swap counts as a new video.
  int _seenMediaId = -1;
  int _mediaId = -1;
  // The mediaId whose media the player holds (or is opening); -1 for none.
  // A swap stops the previous media.
  int _playerMediaId = -1;
  // [_playerMediaId] at the last open: the same media again (a reconnect,
  // joining back) keeps the player, any other gets a fresh one (see
  // [_openMedia]).
  int _openedFor = -1;
  String? _openUrl;
  String _wsHost = '';
  int _wsPort = 0;
  _RelayOrigin? _pendingOrigin;
  // This client's last swap, until a state shows it landed (a newer
  // mediaId than [after] with this member as `swapBy`): its art goes up then.
  // [link]: the web link it came from (a relayed one has no `url`).
  ({HelloMedia media, int after, String? link, Uint8List? art})? _pendingArt;
  AniListClient? _aniList;
  // What this member serves for media [$1].
  (int, _RelayOrigin)? _activeOrigin;
  RelaySource? _relaySource;
  int _relaySourceMediaId = -1;
  /// This member serves the current media's bytes through the server.
  final relaying = signal<bool>(false);
  /// Names by member id, kept after they leave (a relay source that left).
  final memberNames = MemberNames();
  // The media this member was told its upload is too slow for.
  int _slowWarnedFor = -1;
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
  /// Auto sit-out (Settings: "Auto sit-out"): idle or minimised for a
  /// while sets this member away, coming back sets it in again.
  final AutoSitOut autoSitOut = AutoSitOut(DateTime.now().toUtc());
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
  // The mediaId [playerError] belongs to, and the player's duration when
  // it came: a new duration means the media opened after all.
  int _playerErrorFor = -1;
  Duration _playerErrorDuration = Duration.zero;
  // Members' last `error`, by id, so a new one toasts once.
  Map<String, String> _memberErrors = const {};

  /// [notifier] defaults to one playing [sfx], [connection] to one
  /// telling that notifier (tests).
  factory SessionCoordinator(
      {SfxService sfx = const NoopSfxService(),
      Notifier? notifier,
      Connection? connection,
      JellyfinAccounts? jellyfin,
      TrackPrefs? trackPrefs,
      LinkResolver? ytDlp}) {
    final n = notifier ?? Notifier(sfx: sfx);
    return SessionCoordinator._(
      notifier: n,
      connection: connection ?? Connection(notify: n.notify),
      ytDlp: ytDlp ?? AppYtDlp.instance,
      jellyfin: jellyfin ?? JellyfinAccounts.instance,
      trackPrefs: trackPrefs ?? TrackPrefs(),
    );
  }

  SessionCoordinator._(
      {required this.notifier,
      required this.connection,
      required this.ytDlp,
      required this.jellyfin,
      required this.trackPrefs}) {
    connection
      ..onWelcome = _onWelcome
      ..caps = () => caps;
    // The Notifier's view of the session (Status → Notifier, never back).
    notifier.session = () {
      final r = serverState.peek();
      return (
        self: selfMember.peek()?.presence,
        alone: r != null && aloneIn(r.members, connection.memberId),
        playing: r?.transport == 'playing',
      );
    };
    _statusEffect = effect(() => _stepStatus(status.value));
  }

  /// Status transitions worth a notice (see [StatusWatch]).
  void _stepStatus(Status s) {
    final events = _statusWatch.step(s, DateTime.now().toUtc());
    if (events.isEmpty) return;
    untracked(() {
      for (final e in events) {
        notify(e);
      }
    });
  }

  // yt-dlp is there to resolve links (checked at each connect).
  bool _canResolve = false;

  /// `hello.caps`: this app serves relays; resolves links when its yt-dlp
  /// is there; plays Jellyfin with its own account when one is linked.
  ClientCaps get caps => ClientCaps(
      source: true,
      resolve: _canResolve,
      jellyfin: jellyfin.accounts.any((a) => jellyfin.statusOf(a.serverId) != JellyfinAccountStatus.expired));

  Future<void> _checkResolve() async {
    try {
      final y = await ytDlp.ytDlp.timeout(const Duration(milliseconds: 500));
      _canResolve = y.enabled && (y.path != null || await File(y.managedPath).exists());
    } catch (_) {}
  }

  /// The session's first player: created here on connect, disposed by
  /// [leave]; each new media gets its own ([PlaybackController.openUrl]).
  /// Never reused across sessions or media (a GPU-side video freeze sticks
  /// to the player).
  Future<void> initPlayer() async {
    if (_playerReady) return;
    try {
      playback.onYtdlError = _setPlayerError;
      playback.onLoadError = _setPlayerError;
      playback.onUserSeek = (d) => _userSeek(d.inMicroseconds / 1e6);
      _bufferSub ??= playback.buffered.subscribe((_) => _onBuffered());
      await playback.init();
      _playerReady = true;
    } catch (e, st) {
      debugPrint('player init failed: $e\n$st');
      rethrow;
    }
  }

  void _setPlayerError(String raw) {
    _log.warning('player cannot open media $_mediaId: $raw');
    _playerErrorFor = _mediaId;
    _playerErrorDuration = playback.duration.peek();
    playerError.value = playErrorText(raw);
  }

  /// Clears [playerError] once the media opened (a new duration) or the
  /// server moved to another media.
  void _checkPlayerError(int mediaId) {
    if (playerError.peek().isEmpty) return;
    final d = playback.duration.peek();
    if (_playerErrorFor != mediaId || (d > Duration.zero && d != _playerErrorDuration)) {
      playerError.value = '';
    }
  }

  /// A member's new `error` toasts once (the pill is hidden while playing).
  void _toastMemberErrors(StateBroadcast r) {
    final now = {for (final m in r.members) if (m.error.isNotEmpty) m.id: m.error};
    for (final m in r.members) {
      final e = now[m.id];
      if (e != null && m.id != connection.memberId && _memberErrors[m.id] != e) {
        notify(MemberCantPlay(m.name, e));
      }
    }
    _memberErrors = now;
  }

  /// Remembers names, and tells this member once per media when it
  /// passes the video on slower than the video plays.
  void _warnSlowSource(StateBroadcast r) {
    memberNames.observe(r);
    if (_slowWarnedFor == r.mediaId) return;
    final warning = slowSourceWarning(r, connection.memberId);
    if (warning == null) return;
    _slowWarnedFor = r.mediaId;
    notify(SlowSource(warning));
  }

  bool _reloadingVideo = false;
  void Function()? _bufferSub;

  /// "Reload video" (button, Ctrl+R, status menu): fresh
  /// player + video output, current media reopened. While it runs the
  /// player counts as not ready, so reports/seek detection pause and the
  /// next broadcast resyncs position and play/pause (diff reset + play
  /// edge). The ready flag is never touched.
  Future<void> reloadVideo() async {
    // Also allowed after a failed reload (player gone, session still on).
    if (connection.params == null || _reloadingVideo) return;
    _reloadingVideo = true;
    _playerReady = false;
    playerFault.value = '';
    try {
      await playback.recreate();
      final url = _openUrl;
      final headers = _openHeaders;
      _openUrl = null;
      _clearPendingSeek();
      if (url != null) await _openMedia(url, headers: headers);
    } catch (e, st) {
      debugPrint('video reload failed: $e\n$st');
      playerFault.value = 'video reload failed: $e';
    } finally {
      _playerReady = playback.alive.peek();
      _reloadingVideo = false;
    }
  }

  /// Keyboard, mouse or an action: activity for auto sit-out.
  void markInput() => autoSitOut.input(DateTime.now().toUtc());

  /// The window gained or lost the focus, was minimised or restored (the
  /// shell port's [WindowActivity], wired in `main`).
  void windowActivity(WindowActivity a) => autoSitOut.window(a, DateTime.now().toUtc());

  Future<void> connect(ConnectParams params) async {
    // Own epoch first: a cancel during any await below makes this stale.
    final epoch = connection.invalidate();
    await _teardown(silent: true);
    if (!connection.isCurrent(epoch)) throw const ConnectCancelled();
    connection.begin(params);
    _wsHost = params.host;
    _wsPort = params.port;
    diff.reset();
    _mediaId = -1;
    _playerMediaId = -1;
    _openedFor = -1;
    settledMediaId.value = -1;
    _openUrl = null;
    playerError.value = '';
    playerFault.value = '';
    fetchFailedFor.value = -1;
    restarts.value = 0;
    _statusWatch.reset();
    _memberErrors = const {};
    _lastReady = false;
    _restoringReady = false;
    _lastAway = false;
    _joinBackAt = null;
    _seenMediaId = -1;
    _wasPlayAllowed = false;
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
    notifier.clear();
    await _checkResolve();
    await initPlayer();
    if (!connection.isCurrent(epoch)) throw const ConnectCancelled();
    // Health follows the connection's state from here (connecting,
    // connected; a failed dial leaves its reason).
    final welcome = await connection.dial(epoch);
    // Reports, the seek check and auto sit-out run from here until leave,
    // through drops.
    _startTicker();
    try {
      final url = welcome.mediaUrl;
      if (url != null && url.isNotEmpty) await _openMedia(url);
      final media = params.media ??
          (params.linkUrl.isEmpty ? null : await mediaForLink(jellyfin, params.linkUrl));
      if (!connection.isCurrent(epoch)) throw const ConnectCancelled();
      if (media != null) _swap(media);
    } catch (e) {
      if (!connection.isCurrent(epoch)) throw const ConnectCancelled();
      debugPrint('connect failed: $e');
      connection.scheduleReconnect();
      rethrow;
    }
  }

  void _subscribe() {
    queue.attach();
    _stateSub ??= connection.states.listen(_onState);
    _feedSub ??= connection.feeds.listen(_onFeed);
    _nudgeSub ??= connection.nudges.listen(_onNudge);
    // The server refused something this app sent: a toast.
    _errSub ??= connection.errors.listen((msg) => notify(ServerRefused(_sentenceCase(msg))));
  }

  /// Opens [url] (with [headers] on every request); false on failure. A
  /// new media gets a fresh player (or the preload holding it); the media
  /// the player held before (back from sitting out, a reload) keeps it.
  Future<bool> _openMedia(String url, {Map<String, String>? headers}) async {
    if (url == _openUrl) return true;
    _opens++;
    _log.info('media $_mediaId: open ${_urlKind(url, headers)}: ${logUrl(url)}'
        '${headers == null || headers.isEmpty ? '' : ' (headers: ${headers.keys.join(', ')})'}');
    final keepPlayer = _playerMediaId == _openedFor;
    _openedFor = _playerMediaId;
    _openUrl = url;
    _openHeaders = headers;
    diff.reset();
    _opening = true;
    final mediaId = _mediaId;
    var ok = false;
    try {
      await _prepareYtDlp(url);
      switchTrace.mark(mediaId, SwitchTrace.open);
      final promoted = await playback.openUrl(url,
          headers: headers,
          keepPlayer: keepPlayer,
          onFreshPlayer: () => switchTrace.mark(mediaId, SwitchTrace.player));
      switchTrace.mark(mediaId, promoted ? SwitchTrace.preloaded : SwitchTrace.opened);
      ok = true;
    } catch (e) {
      debugPrint('open media failed: $e');
      _setPlayerError('$e');
    } finally {
      _opening = false;
    }
    // Tell the server at once (a preloaded media already has its buffer).
    final r = serverState.peek();
    if (ok && r != null && r.mediaId == mediaId && url == _openUrl && connection.token.isNotEmpty && _playerReady) {
      _sendReport(r);
    }
    return ok;
  }

  int _opens = 0;

  /// How many times this session opened a media in the player (a drop
  /// and return must not add one).
  int get opens => _opens;

  // The media whose buffer reached the gate's need was reported at once.
  int _bufferReportedFor = -1;

  /// While held, the report that the buffer reached the gate's need goes
  /// out as it happens, not on the next tick.
  void _onBuffered() {
    final r = serverState.peek();
    if (r == null || r.transport != 'held' || _bufferReportedFor == r.mediaId) return;
    if (_lastAway || _opening || _openUrl == null || _playerMediaId != r.mediaId || !_playerReady) return;
    if (connection.token.isEmpty || playback.bufferedSecsAhead < r.bufferNeed) return;
    _bufferReportedFor = r.mediaId;
    _sendReport(r);
  }

  /// What [url] is, for the log.
  String _urlKind(String url, Map<String, String>? headers) {
    if (url.startsWith('edl://')) return 'relay (tracks)';
    final u = Uri.tryParse(url);
    if (u == null || !(u.isScheme('http') || u.isScheme('https'))) return 'local file';
    if (u.host == _wsHost && u.port == _wsPort && u.pathSegments.isNotEmpty) {
      return switch (u.pathSegments.first) {
        'r' => 'relay',
        'm' => "the host's file",
        'j' => "Jellyfin through the server's login",
        _ => 'server URL',
      };
    }
    if (headers != null && headers.isNotEmpty) return 'Jellyfin, own sign-in';
    return 'link, fetched here';
  }

  /// A web link (not this server's): mpv's yt-dlp hook gets the app's
  /// managed yt-dlp, downloaded first if needed; a media file name does
  /// not wait for that.
  Future<void> _prepareYtDlp(String url) async {
    final path = await _ytDlpPathFor(url);
    if (path != null) await playback.useYtDlp(path);
  }

  /// The yt-dlp mpv's hook needs for [url] (null: none, not a web link).
  Future<String?> _ytDlpPathFor(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return null;
    if (uri.host == _wsHost && uri.port == _wsPort) return null;
    try {
      final y = await ytDlp.ytDlp;
      final ready = y.ensure();
      return hasMediaExtension(uri)
          ? y.path
          : await ready.timeout(const Duration(seconds: 90), onTimeout: () => null);
    } catch (e) {
      debugPrint('yt-dlp not ready: $e');
      return null;
    }
  }

  /// The media of the latest `state` is open here (or has nothing to
  /// open, could not, or waits for the server): its mediaId. Up next
  /// preloads what comes next only then, so the two never compete, and a
  /// preload a swap is about to take is never replaced first.
  final settledMediaId = signal(-1);

  /// Opens [url] in the hidden preload player ([PlaybackController.preload]);
  /// [openUrl] for the same URL and headers then starts from it. True
  /// once its first seconds are in.
  Future<bool> preloadMedia(String url, {Map<String, String>? headers, bool fresh = false}) async {
    if (!_playerReady) return false;
    final path = await _ytDlpPathFor(url);
    if (!_playerReady) return false;
    return playback.preload(url, headers: headers, ytdlPath: path, fresh: fresh);
  }

  /// The server-fetched media this viewer opens once it is live.
  int _awaitLiveFor = -1;

  /// A relay nobody feeds yet: the server's fetch before it is read, or a
  /// member's before its channel is up while that member is still here
  /// (once it is gone or left, the server's buffer is all there is: open
  /// that).
  bool _waitForSource(StateBroadcast r, MediaRelay relay) =>
      !relay.live && !relay.sourceGone && (relay.fetch || r.members.any((m) => m.id == relay.source));

  /// This viewer's `/r/` URL; with tracks, a pieces track's playlist, or
  /// an mpv EDL of every track when there are several (a page's separate
  /// video and audio). A relay started in Up next ([queueId]) keeps its
  /// queue id in the URL, so the preload of its warm relay matches.
  String _relayMediaUrlFor(String name, int mediaId,
          [List<RelayTrackSpec> tracks = const [], String queueId = '']) =>
      relayViewerUrl('http://$_wsHost:$_wsPort/r/default/${connection.token}/${queueId.isEmpty ? mediaId : queueId}', name,
          tracks: tracks);

  /// This viewer's URL of the warm relay of Up next's first [item]
  /// (`queue[0].media.relay`, see ARCHITECTURE "Getting ready"): the same
  /// URL the media has once the item goes up, so the preload is promoted.
  String warmRelayUrl(QueueItem item, MediaRelay relay) =>
      _relayMediaUrlFor(item.media.name.isEmpty ? item.title : item.media.name, -1, relay.tracks, item.id);

  // This member feeds the warm relay of Up next item `queueId` (its
  // link, file or Jellyfin stream) before the item goes up; the swap
  // that puts it up takes the source over.
  ({String queueId, RelaySource src})? _warmSource;

  /// Feeds the warm relay of Up next item [queueId] from here with
  /// [media]; one already feeding it is kept. The server pulls only while
  /// someone preloads it, and closes the channel once the item is no
  /// longer first (the source then stops).
  void feedWarm(String queueId, RelayMedia media) {
    if (_warmSource?.queueId == queueId) {
      unawaited(media.close());
      return;
    }
    stopWarmSource();
    final src = RelaySource(
        Uri.parse('ws://$_wsHost:$_wsPort/r/default/${connection.token}/source?q=${Uri.encodeQueryComponent(queueId)}'),
        media);
    _warmSource = (queueId: queueId, src: src);
    unawaited(() async {
      try {
        await src.start();
      } catch (e) {
        debugPrint('warm relay source of $queueId failed: $e');
        if (identical(_warmSource?.src, src)) _warmSource = null;
        return;
      }
      await src.done;
      if (identical(_warmSource?.src, src)) _warmSource = null;
    }());
  }

  void stopWarmSource() {
    final w = _warmSource;
    _warmSource = null;
    if (w != null) unawaited(w.src.close());
  }

  /// Serves [media] for media [mediaId] on this member's relay channel.
  /// The server only pulls while someone watches through it. When the
  /// media came from Up next item [queueId] whose warm relay this member
  /// feeds, that source carries on instead.
  void _startRelaySource(int mediaId, RelayMedia media,
      {bool announce = false, String queueId = '', String name = '', double duration = 0}) {
    // Already serving this media (it redials by itself through a drop and
    // goes on once this member is back).
    if (_relaySource != null && _relaySourceMediaId == mediaId) {
      unawaited(media.close());
      return;
    }
    _stopRelaySource();
    final warm = _warmSource;
    if (queueId.isNotEmpty && warm != null && warm.queueId == queueId) {
      _warmSource = null;
      unawaited(media.close());
      _relaySource = warm.src;
      _relaySourceMediaId = mediaId;
      relaying.value = true;
      if (announce) notify(const RelayStarted());
      unawaited(warm.src.done.then((_) {
        if (identical(_relaySource, warm.src)) {
          _relaySource = null;
          relaying.value = false;
        }
      }));
      return;
    }
    // The same `info` on every dial (name and length included), so the
    // server knows a re-dial after a drop as the same media and continues.
    final src = RelaySource(
        Uri.parse('ws://$_wsHost:$_wsPort/r/default/${connection.token}/source'), media,
        name: name, duration: duration);
    _relaySource = src;
    _relaySourceMediaId = mediaId;
    relaying.value = true;
    if (announce) notify(const RelayStarted());
    unawaited(() async {
      try {
        await src.start();
      } catch (e) {
        debugPrint('relay source failed: $e');
        if (identical(_relaySource, src)) {
          _relaySource = null;
          relaying.value = false;
          notify(RelayFailed('$e'));
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
    return 'http://$_wsHost:$_wsPort/m/default/${connection.token}/${Uri.encodeComponent(name)}';
  }

  StateBroadcast? _queuedState;
  bool _applying = false;

  /// States are applied one at a time, newest first: two applies running
  /// interleaved could land an older pause after a newer play (seen with
  /// three viewers readying at once). A state that arrives meanwhile
  /// replaces any still waiting.
  void _onState(StateBroadcast r) {
    serverState.value = r;
    if (r.transport == 'playing') switchTrace.mark(r.mediaId, SwitchTrace.playing);
    _toastMemberErrors(r);
    _warnSlowSource(r);
    _checkPlayerError(r.mediaId);
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
    if (_lastAway) {
      // A newer media than the one this member serves: that relay ended.
      if (_relaySourceMediaId != -1 && _relaySourceMediaId != r.mediaId) _stopRelaySource();
      await _unloadForOut();
      return;
    }
    _seekGate.observe(r, connection.memberId);
    final newEvent = r.eventId != _lastEventId;
    _lastEventId = r.eventId;
    if (r.mediaId != _mediaId) {
      _mediaId = r.mediaId;
      switchTrace.start(r.mediaId);
      final ref = refOfStateMedia(r.media);
      // Back after a dropped connection on the same item played with our
      // own account: nothing to resolve or reopen.
      final same = ref != null &&
          r.mediaId == _jfMediaId &&
          sameJellyfinItem(ref, _jfRef) &&
          jellyfinPlan.peek() is OwnPlay;
      final relay = stateMediaRelay(r);
      final mine = relay != null && relay.source.isNotEmpty && relay.source == connection.memberId;
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
        await _leavePreviousMedia(r.mediaId);
        final name = (r.media?['name'] as String?) ?? '';
        if (ref != null) {
          await _playJellyfin(ref, r,
              origin: origin is _JellyfinOrigin ? origin : null,
              memberRelayUrl:
                  relay != null && !mine ? _relayMediaUrlFor(name, r.mediaId, const [], relay.queueId) : null);
        } else if (origin is _FileOrigin) {
          // The source first: viewers wait on it, not on this player.
          _startRelaySource(r.mediaId, RelayMedia.single(FileRelayBytes(File(origin.path))),
              announce: true, queueId: relay?.queueId ?? '', name: name, duration: _durationOf(r));
          await _openMedia(origin.path);
        } else if (origin is _LinkOrigin) {
          _startRelaySource(
              r.mediaId, LinkRelayMedia(Uri.parse(origin.url), ytDlp: origin.ytDlp, probe: origin.probe),
              announce: true, queueId: relay?.queueId ?? '', name: name, duration: _durationOf(r));
          await _openMedia(origin.url);
        } else if (relay != null && !mine) {
          if (_waitForSource(r, relay)) {
            // The server is still getting it (yt-dlp takes seconds), or the
            // member passing it on has not dialled in yet (its app opens the
            // link first): mpv gives up on a silent request after 5 s, so
            // open once it is live.
            _openUrl = null;
            _awaitLiveFor = r.mediaId;
            final who = r.members.where((m) => m.id == relay.source).firstOrNull?.name;
            _log.info('media ${r.mediaId}: waiting for ${relay.fetch ? 'the server' : who} before opening the relay');
          } else {
            await _openMedia(_relayMediaUrlFor(name, r.mediaId, relay.tracks, relay.queueId));
          }
        } else {
          var url = stateMediaUrl(r);
          if ((url == null || url.isEmpty) && connection.token.isNotEmpty) {
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
      if (_mediaId == r.mediaId) settledMediaId.value = r.mediaId;
    } else if (_awaitLiveFor == r.mediaId && stateMediaRelay(r) != null && !_waitForSource(r, stateMediaRelay(r)!)) {
      _awaitLiveFor = -1;
      final relay = stateMediaRelay(r)!;
      await _openMedia(
          _relayMediaUrlFor((r.media?['name'] as String?) ?? '', r.mediaId, relay.tracks, relay.queueId));
    }
    _jellyfinTransport(r);
    if (!_playerReady || _openUrl == null) {
      _wasPlayAllowed = false;
      return;
    }
    // Server clock: serverTime in the state is the server's.
    final now = connection.serverNow();
    final allowed = localPlayAllowed(r, connection.memberId);
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
        (newEvent && _seekGate.isOwnEcho(r, connection.memberId))) {
      actions = [for (final a in actions) if (a is! SeekAction) a];
    }
    if (actions.any((a) => a is SeekAction)) {
      _pendingSeekEvent = r.eventId;
      _pendingSeekAt = DateTime.now().toUtc();
      _seekRetries = 0;
    }
    await playback.apply(actions);
  }

  /// Mirrors the server's ready flag for self into [_lastReady] (force
  /// by others included), and whether self is away.
  void _trackSelfReady(StateBroadcast r) {
    final self = selfMember.peek();
    if (self == null) return;
    // [_seenMediaId], not [_mediaId]: that one is -1 while sitting out.
    if (_seenMediaId >= 0 && r.mediaId != _seenMediaId) _restoringReady = false;
    if (_restoringReady) {
      if (self.ready) _restoringReady = false;
    } else {
      _lastReady = self.ready;
    }
    _lastAway = self.presence == Presence.away;
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
      connection.sendReady(false, source: 'auto');
    }
  }

  /// Sitting out: nothing open, nothing pulled. A relay this member
  /// serves goes on (it does not use the player). The next state after
  /// [joinBack] opens the media as new.
  Future<void> _unloadForOut() async {
    _wasPlayAllowed = false;
    _awaitLiveFor = -1;
    if (_mediaId == -1 && _openUrl == null) return;
    _mediaId = -1;
    _playerMediaId = -1;
    _openUrl = null;
    _openHeaders = null;
    _seekGate.reset();
    _clearPendingSeek();
    diff.reset();
    _leaveJellyfinItem();
    if (!_playerReady) return;
    try {
      await playback.stop();
    } catch (_) {}
  }

  /// A new media [mediaId]: the previous one leaves the player at once, so
  /// nobody sees or hears it while the new one resolves, is fetched by the
  /// server or opens. A reconnect to the media the player holds keeps it.
  Future<void> _leavePreviousMedia(int mediaId) async {
    final held = _playerMediaId;
    _playerMediaId = mediaId;
    // Opened from the welcome, before any state: that was this media.
    if (held == -1 && _openedFor == -1 && _openUrl != null) _openedFor = mediaId;
    if (held == -1 || held == mediaId) return;
    _openUrl = null;
    _openHeaders = null;
    diff.reset();
    if (!_playerReady) return;
    try {
      await playback.stop();
    } catch (_) {}
  }

  void _onFeed(FeedMessage f) {
    final r = serverState.peek();
    final event = FeedEvent.of(f,
        selfId: connection.memberId,
        readyCount: f.action == 'ready' ? r?.members.where((m) => m.ready && countsForReady(m)).length ?? 0 : 0,
        // The state goes out before its feed: the item is in it.
        queueThumb: f.action == 'queue-add' ? _addedThumb(r, f) : '');
    // The server gave up fetching what everyone waits for (a fact for
    // [status]).
    if (event is FetchFailed && r != null && !f.replayed) fetchFailedFor.value = r.mediaId;
    notify(event);
  }

  /// The picture of the Up next item [f] (`queue-add`) added: the newest
  /// item of that title by that member.
  static String _addedThumb(StateBroadcast? r, FeedMessage f) {
    for (final q in (r?.queue ?? const <QueueItem>[]).reversed) {
      if (q.title == f.target && (f.actorId.isEmpty || q.by == f.actorId)) return q.thumb;
    }
    return '';
  }

  static String _sentenceCase(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Someone poked this member: sound (even when its switch is off; the
  /// volume still applies), a toast, and the window asks for attention.
  void _onNudge(NudgeNotice n) => notify(Nudged(n.name));

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// The 1 s `report` (also sent at once when a new media is open, so the
  /// server's gate does not wait for the next tick).
  void _sendReport(StateBroadcast r) {
    // Duration only once the open media is the server's current one.
    // Sitting out: still a report, empty.
    final known = !_lastAway && !_opening && _openUrl != null && _mediaId == r.mediaId;
    // The buffer counts only while the player holds the server's current
    // media: before a swap's media is open it is the previous one's (or
    // none), and the start must wait for this member.
    final holds = !_lastAway && !_opening && _openUrl != null && _playerMediaId == r.mediaId;
    _checkPlayerError(r.mediaId);
    final error = playerError.peek();
    final buffered = holds ? playback.bufferedSecsAhead : 0.0;
    if (holds && buffered >= r.bufferNeed) switchTrace.mark(r.mediaId, SwitchTrace.buffered);
    connection.sendReport(
      position: _lastAway ? 0 : playback.positionSecs,
      buffered: buffered,
      eventId: r.eventId,
      duration: known ? playback.durationSecs : 0,
      mediaId: known ? r.mediaId : 0,
      jf: _jfAccessFor(r),
      error: known && _playerErrorFor == r.mediaId ? error : '',
    );
  }

  Future<void> _tick() async {
    final now = DateTime.now().toUtc();
    // The status's clock moves by the minute; its transitions (a source
    // gone long enough) are checked every second.
    if (now.difference(_clock.peek()).inMinutes >= 1 || now.minute != _clock.peek().minute) _clock.value = now;
    _stepStatus(status.peek());
    final r = serverState.peek();
    final online = connection.state.peek().online;
    if (online && connection.token.isNotEmpty && r != null && _playerReady) {
      _sendReport(r);
      if (!_lastAway) _checkSeekLanded(r);
    }
    // The Jellyfin progress goes on through a drop (the player does).
    if (connection.token.isNotEmpty && r != null && _playerReady && !_lastAway) unawaited(_tickJellyfin(r));
    if (r != null && online) _readyAfterJoinBack(r, now);
    _tickAutoSitOut(r, now, online: online);
  }

  /// Auto sit-out's second (only while online: the state is current).
  void _tickAutoSitOut(StateBroadcast? r, DateTime now, {required bool online}) {
    final step = autoSitOut.tick(now,
        self: online ? selfMember.peek()?.presence : null,
        playing: r?.transport == 'playing',
        alone: r == null || aloneIn(r.members, connection.memberId),
        enabled: AppSettings.instance.autoSitOut.peek());
    switch (step) {
      case AutoAway(:final reason):
        _log.info('auto sit-out: away (${reason.name})');
        _joinBackAt = null;
        connection.sendPresence(PresenceIntent(state: Presence.away, reason: reason));
      case AutoBack():
        _log.info('auto sit-out: back');
        _joinBack(ready: false);
      case AutoStay():
        break;
    }
  }

  /// After [joinBack] while playing: ready once the player holds what the
  /// gate needs, or after [_joinBackWait] (then the gate waits for it).
  void _readyAfterJoinBack(StateBroadcast r, DateTime now) {
    final at = _joinBackAt;
    if (at == null) return;
    final self = selfMember.peek();
    if (self == null || self.presence == Presence.away) {
      if (now.difference(at) > _joinBackWait) _joinBackAt = null;
      return;
    }
    final loaded = _playerReady && !_opening && _openUrl != null && _mediaId == r.mediaId;
    if (self.ready ||
        (loaded && playback.bufferedSecsAhead >= r.bufferNeed) ||
        now.difference(at) > _joinBackWait) {
      _joinBackAt = null;
      if (!self.ready) {
        _lastReady = true;
        connection.sendReady(true, source: 'manual');
      }
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
    final target = serverPositionAt(r, connection.serverNow());
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
    connection.sendSeek(position, seq: settled.seq);
  }

  void toggleReady() {
    final self = selfMember.peek();
    if (self?.presence == Presence.away) {
      joinBack();
      return;
    }
    // Ready but out of the set (joined while playing, a player error)
    // gates like unready, so Space puts self back in instead of
    // unreadying.
    final next = !((self?.ready ?? false) && (self?.inSet ?? false));
    markInput();
    _lastReady = next;
    connection.sendReady(next, source: 'manual');
  }

  void forceTarget(String memberId, bool ready) {
    markInput();
    connection.sendForce(memberId, ready);
  }

  void forcePlayAll() {
    markInput();
    connection.sendForce('all', true);
  }

  void seekTo(double position) => _userSeek(position);

  /// Arrow keys: relative to a seek still in flight, so repeated presses
  /// add up.
  void nudge(double deltaSecs) {
    final r = serverState.peek();
    if (r == null || _openUrl == null) return;
    final base = _seekGate.target ?? serverPositionAt(r, connection.serverNow());
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
    connection.sendChat(text);
  }

  /// Name and/or picture (base64 PNG, empty removes it) change for
  /// everyone now; a later fresh join sends them too.
  void updateProfile({String? name, String? avatar}) {
    connection.updateProfile(name: name, avatar: avatar);
  }

  /// Sits [memberId] out (anyone, the host included), self when null.
  void sitOut([String? memberId]) {
    final target = memberId ?? connection.memberId;
    if (target.isEmpty) return;
    final self = target == connection.memberId;
    if (self) {
      _joinBackAt = null;
      autoSitOut.manual();
    }
    markInput();
    connection.sendPresence(PresenceIntent(target: self ? '' : target, state: Presence.away));
  }

  /// Back from sitting out (`in`, through joining): the media opens at
  /// the server position and this member readies. Held: at once (the
  /// gate waits for the buffer); playing: once buffered, so the others do
  /// not pause for the load.
  void joinBack() {
    final self = selfMember.peek();
    if (self == null || self.presence != Presence.away) return;
    autoSitOut.manual();
    markInput();
    _joinBack(ready: true);
  }

  /// `in` again; with [ready] this member readies too (auto sit-out's
  /// return keeps the ready flag the server kept).
  void _joinBack({required bool ready}) {
    connection.sendPresence(const PresenceIntent(state: Presence.watching));
    if (!ready) {
      _joinBackAt = null;
    } else if (serverState.peek()?.transport == 'playing') {
      _joinBackAt = DateTime.now().toUtc();
    } else {
      _joinBackAt = null;
      _lastReady = true;
      connection.sendReady(true, source: 'manual');
    }
  }

  /// Pokes [memberId]: only they hear it (sitting out or not).
  void nudgeMember(String memberId) {
    if (memberId.isEmpty || memberId == connection.memberId) return;
    markInput();
    connection.sendNudge(memberId);
  }

  /// [queueId]: the Up next item this puts up (the server takes it off
  /// the queue); [art]: a picture to send as its art (a queued item's).
  void _swap(HelloMedia media, {String? link, String? queueId, Uint8List? art}) {
    // A swap sent into a dropped link would be lost without a word.
    if (!connection.state.peek().online) {
      notify(const ActionFailed('Reconnecting: put it up again once back'));
      return;
    }
    // Putting something up means watching it: back first. Not for Up next
    // coming up by itself: whoever puts it up may be sitting out.
    final self = selfMember.peek();
    if (self != null && self.presence == Presence.away && queueId == null) {
      autoSitOut.manual();
      connection.sendPresence(const PresenceIntent(state: Presence.watching));
    }
    _pendingArt = (media: media, after: serverState.peek()?.mediaId ?? 0, link: link ?? media.url, art: art);
    connection.sendSwap(media, queueId: queueId);
  }

  /// An Up next item put up as queued, for one this app cannot build
  /// itself (a server-fetched link: the server has the URL); [art] goes up
  /// as its art.
  void swapQueued(HelloMedia media, String queueId, {Uint8List? art}) {
    markInput();
    _swap(media, queueId: queueId, art: art);
  }

  void _maybeSendArt(StateBroadcast r) {
    final pending = _pendingArt;
    if (pending == null || r.mediaId <= pending.after) return;
    if (connection.memberId.isEmpty || r.media?['swapBy'] != connection.memberId) return;
    _pendingArt = null;
    final link = pending.link;
    _ownLink = link == null || link.isEmpty ? null : (r.mediaId, link);
    unawaited(_sendArt(r.mediaId, pending.media, pending.link, given: pending.art));
  }

  /// The link this app put up as [StateBroadcast.mediaId] (passed on or
  /// fetched by the server, so not in the state).
  (int, String)? _ownLink;

  /// The link of what plays, as this app may hand it out (Copy link, Open
  /// in browser): one this app put up, else one everyone opens (it is in
  /// the state); null otherwise (another member's passed-on link, a
  /// server fetch by someone else, Jellyfin, files).
  String? currentLink() {
    final r = serverState.peek();
    if (r == null || r.media == null) return null;
    final own = _ownLink;
    if (own != null && own.$1 == r.mediaId) return own.$2;
    final url = stateMediaUrl(r);
    return url != null && (url.startsWith('http://') || url.startsWith('https://')) ? url : null;
  }

  /// Fetches the art of [media] (this client's swap, now [mediaId], from
  /// web [link] if any) and sends it; quietly nothing on any failure.
  Future<void> _sendArt(int mediaId, HelloMedia media, String? link, {Uint8List? given}) async {
    try {
      final ref = media.jellyfin;
      final client = ref == null ? null : jellyfin.clientFor(ref.serverId);
      final ArtBytes? bytes;
      if (given != null) {
        bytes = (poster: given, banner: given);
      } else if (ref != null && client != null) {
        bytes = await jellyfinArt(client, ref.itemId);
      } else if (ref == null && (link ?? '').isNotEmpty) {
        // A web link is not a show: never guess. A page's thumbnail is
        // its cover and banner both.
        final thumb = (await _probeFor(link!))?.info?.thumbnail;
        final uri = thumb == null ? null : Uri.tryParse(thumb);
        bytes = uri == null ? null : await thumbnailArt(uri);
      } else {
        // The library's match names the AniList entry; else a title search.
        final known = ref == null ? media.ref?.anilistId : null;
        final name = ref == null ? media.name : jellyfinTitle(ref.title, ref.subtitle).$1;
        final aniList = _aniList ??= AniListClient();
        bytes = await (known != null ? aniListArtById(aniList, known) : null) ?? await aniListArt(aniList, name);
      }
      final poster = bytes?.poster, banner = bytes?.banner;
      if (poster == null && banner == null) return;
      if (serverState.peek()?.mediaId != mediaId) return;
      connection.sendArt(mediaId,
          poster: poster == null ? null : base64Encode(poster),
          banner: banner == null ? null : base64Encode(banner));
    } catch (e) {
      debugPrint('art for media $mediaId: $e');
    }
  }

  /// A pasted link: a recognised Jellyfin item link goes up as a ref
  /// (see [mediaForLink]) that this member relays for viewers without an
  /// account (with the link's key, which stays here); anything else as the
  /// link, or relayed per [relay]. A link this computer cannot open (its
  /// probe's [LinkProbe.problem], or unreachable) is refused with the
  /// reason in plain words unless [anyway]. Returns an error text, or null
  /// when sent.
  Future<String?> swapLink(String url,
      {LinkRelay relay = LinkRelay.direct, bool anyway = false, String? queueId}) async {
    markInput();
    final media = await mediaForLink(jellyfin, url);
    if (media.jellyfin != null) {
      _pendingOrigin = _JellyfinOrigin(url);
      _swap(media.copyWith(relay: const MediaRelay()), queueId: queueId);
      return null;
    }
    LinkProbe? probe;
    String? probeError;
    try {
      probe = await ytDlp.probe(url).timeout(const Duration(seconds: 45));
    } catch (e) {
      probeError = '$e';
    }
    final problem = probe == null ? playErrorText(probeError ?? '') : probe.problem;
    if (problem != null && !anyway) return problem;
    // A page is named by its title, never its URL tail ("1", "watch").
    final uri = Uri.tryParse(url) ?? Uri();
    final name = probe?.title ?? (probe != null || hasMediaExtension(uri) || uri.host.isEmpty ? media.name : uri.host);
    final what = linkMediaRef(name);
    if (relay == LinkRelay.direct) {
      _swap(HelloMedia(name: name, size: 0, duration: 0, url: url, ref: what), queueId: queueId);
      return null;
    }
    if (relay == LinkRelay.me) {
      // This computer reads it: a file, or a page's formats (one file,
      // separate video and audio tracks, or segmented playlists).
      if (probe == null) return problem;
      final relayProblem = probe.relayProblem;
      if (relayProblem != null) return relayProblem;
      final y = await ytDlp.ytDlp;
      // Up next's item this app already feeds (its warm relay): read.
      final warm = _warmSource;
      final fed = queueId != null && warm != null && warm.queueId == queueId && warm.src.tracks.isNotEmpty;
      final check = fed ? null : LinkRelayMedia(uri, ytDlp: y, probe: probe);
      var size = 0;
      final List<RelayTrackSpec> specs;
      try {
        final tracks = fed ? warm.src.tracks : await check!.open().timeout(const Duration(seconds: 15));
        for (final t in tracks) {
          // A playlist is read (DRM and live refused) but has no size.
          final pieces = t.pieces;
          if (pieces != null) {
            await pieces.list().timeout(const Duration(seconds: 15));
          } else {
            size += await t.bytes!.size().timeout(const Duration(seconds: 15));
          }
        }
        specs = relayTrackSpecs(tracks);
      } catch (e) {
        return 'cannot pass this link on: $e';
      } finally {
        await check?.close();
      }
      _pendingOrigin = _LinkOrigin(url, probe, y);
      _swap(HelloMedia(name: name, size: size, duration: 0, relay: MediaRelay(tracks: specs), ref: what),
          link: url, queueId: queueId);
      return null;
    }
    // The server reads it with its own yt-dlp; only a page this app knows
    // it cannot relay (live, nothing a relay can read) is refused here (the server
    // may reach what this computer cannot).
    if (probe != null && probe.isPage && probe.info != null && probe.relayProblem != null) {
      return probe.relayProblem;
    }
    _swap(HelloMedia(
        name: name,
        size: max(0, probe?.size ?? 0),
        duration: 0,
        url: url,
        relay: const MediaRelay(fetch: true),
        ref: what),
        queueId: queueId);
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
  void swapJellyfin(JellyfinMedia media, {String? queueId}) {
    markInput();
    _pendingOrigin = const _JellyfinOrigin(null);
    _swap(mediaForPick(media).copyWith(relay: const MediaRelay()), queueId: queueId);
  }

  /// A file on this computer. The host's app serves it itself; anyone
  /// else's goes through the server's relay. Returns an error text, or null
  /// when sent.
  Future<String?> swapFile(String path, {String? queueId}) async {
    markInput();
    final what = fileRef?.call(path);
    final host = hostFile;
    if (host != null) {
      final file = await host(path);
      if (file == null) return 'file not found — check the path';
      _swap(HelloMedia(name: file.name, size: file.size, duration: 0, ref: what), queueId: queueId);
      return null;
    }
    final file = File(path);
    if (!await file.exists()) return 'file not found — check the path';
    _pendingOrigin = _FileOrigin(path);
    _swap(HelloMedia(
        name: file.uri.pathSegments.last,
        size: await file.length(),
        duration: 0,
        relay: const MediaRelay(),
        ref: what),
        queueId: queueId);
    return null;
  }

  /// Any picker selection; [queueId] when it is an Up next item.
  Future<String?> swapPicked(PickedMedia media, {String? queueId}) async {
    switch (media) {
      case LinkMedia(:final url, :final relay, :final anyway):
        return swapLink(url, relay: relay, anyway: anyway, queueId: queueId);
      case JellyfinMedia():
        swapJellyfin(media, queueId: queueId);
      case FileMedia(:final path):
        return swapFile(path, queueId: queueId);
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

  /// News for the user, from the session or anywhere in the app (see
  /// [Notifier]).
  void notify(AppEvent event) => notifier.notify(event);

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

  /// Leave / window close: Stopped, bounded so leaving never hangs.
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

  /// This member's `/j/` URL for [ref] (the server's Jellyfin login).
  String? jellyfinRelayUrl(JellyfinRef ref) => _relayUrlFor(ref);

  String? _relayUrlFor(JellyfinRef ref) {
    if (connection.token.isEmpty) return null;
    final welcome = connection.relayUrl;
    if (welcome != null &&
        welcome.contains('/${connection.token}/') &&
        welcome.endsWith('/${Uri.encodeComponent(ref.itemId)}')) {
      return welcome;
    }
    return relayUrlFor(_wsHost, _wsPort, connection.token, ref.itemId);
  }

  /// `report.jf`: every linked account that works (so a queued Jellyfin
  /// item finds someone to put it up while other media plays), then how
  /// the current item plays here.
  Map<String, bool>? _jfAccessFor(StateBroadcast r) {
    final linked = {
      for (final a in jellyfin.accounts)
        if (jellyfin.statusOf(a.serverId) != JellyfinAccountStatus.expired) a.serverId: true,
    };
    final ref = _jfRef;
    final access = jellyfinPlan.peek()?.jfAccess;
    if (ref == null || access == null || r.mediaId != _jfMediaId) return linked.isEmpty ? null : linked;
    return {...linked, ref.serverId: access};
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
      plan = _takeWarmJellyfin(ref) ??
          await resolveJellyfinRef(jellyfin, ref,
              relay: r.relay, relayUrl: _relayUrlFor(ref), memberRelayUrl: memberRelayUrl);
    } finally {
      if (gen == _jfGen) _opening = false;
    }
    if (gen != _jfGen) return;
    switchTrace.mark(r.mediaId, SwitchTrace.resolved);
    // This member put it up: serve it to viewers without an account, with
    // its own sign-in, else the pasted link (played directly here too).
    if (origin != null) {
      final name = (r.media?['name'] as String?) ?? '';
      if (plan is OwnPlay) {
        _startRelaySource(r.mediaId, RelayMedia.single(HttpRelayBytes(Uri.parse(plan.url), headers: plan.headers)),
            queueId: stateMediaRelay(r)?.queueId ?? '', name: name, duration: _durationOf(r));
      } else if (origin.link != null) {
        plan = RelayPlay(origin.link!);
        _startRelaySource(r.mediaId, RelayMedia.single(HttpRelayBytes(Uri.parse(origin.link!))),
            name: name, duration: _durationOf(r));
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
        // Played before and the resume point, fresh (a warmed plan's item
        // is older): the watched rule never unmarks a played item.
        final known = plan.item?.userData;
        final userDataF = plan.client
            .userData(ref.itemId)
            .timeout(const Duration(seconds: 5))
            .then<JellyfinUserData?>((d) => d, onError: (_) => known);
        unawaited(_findEpisodes(plan, gen));
        unawaited(_loadSegments(plan, ref, gen));
        // Playing carries the tracks: wait (bounded) until the file is in.
        await playback.waitForTracks();
        if (gen != _jfGen) return;
        final before = await userDataF;
        if (gen != _jfGen) return;
        final reporter = JellyfinProgressReporter(
          client: plan.client,
          itemId: ref.itemId,
          source: plan.source,
          playSessionId: plan.info.playSessionId,
          playedBefore: before?.played ?? false,
          resumeTicksBefore: before?.playbackPositionTicks ?? 0,
          onUnauthorized: () => jellyfin.markExpired(ref.serverId),
          onStopped: () => jellyfin.watchedChanged(ref.serverId),
          onError: (e) {
            if (_jfToastShown) return;
            _jfToastShown = true;
            notify(JellyfinProgressFailed(signInExpired: e is JellyfinException && e.isUnauthorized));
          },
        );
        final snap = await _snapshot();
        if (gen != _jfGen || snap == null) return;
        // Installed once started: the per-state restart (after the end)
        // must not send the first Playing without the tracks.
        _reporter = reporter..start(snap);
    }
    await _applyTrackChoice(plan, gen);
  }

  /// [warmJellyfin] when it is [ref], still fresh and its account
  /// unchanged.
  OwnPlay? _takeWarmJellyfin(JellyfinRef ref) {
    final w = warmJellyfin;
    if (w == null || !sameJellyfinItem(w.ref, ref)) return null;
    warmJellyfin = null;
    final fresh = DateTime.now().isBefore(w.until) &&
        jellyfin.account(ref.serverId)?.token == w.plan.account.token &&
        jellyfin.statusOf(ref.serverId) != JellyfinAccountStatus.expired;
    return fresh ? w.plan : null;
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
      final ending = playback.ending.peek()?.start;
      reporter
        ..timeline(duration: playback.durationSecs, endingStart: ending == null ? null : ending.inMilliseconds / 1000)
        ..update(snap);
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
    // Up next goes first; "Clear" in it hides the next episode here.
    if (next == null ||
        !queue.continuationShown(r.mediaId) ||
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
      autoAdvanceSwapper(r.members, ref.serverId) == connection.memberId;

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

  /// A welcome's part here (see [WelcomeHandler]), before its state is
  /// applied. The first one and a resumed one need nothing: the member
  /// kept everything (ready flag, presence, queue items, relay) and the
  /// player kept the media. A new member after a drop (grace over, or the
  /// server restarted) gets this app's intent again (ready, away), and
  /// the media opens again only if it changed or its URL named the old
  /// token.
  void _onWelcome(WelcomeMessage welcome, Rejoin rejoin) {
    if (!rejoin.reconnect) return;
    _log.info('reconnected: ${rejoin.resumed ? 'resumed' : 'a new member'}'
        '${rejoin.sameServer ? '' : ' (the server restarted)'}');
    if (!rejoin.sameServer) restarts.value++;
    if (rejoin.resumed) return;
    final before = serverState.peek();
    final raw = welcome.state;
    StateBroadcast? now;
    try {
      now = raw == null ? null : StateBroadcast.fromJson(raw);
    } catch (_) {}
    final changed = before == null ||
        now == null ||
        (rejoin.sameServer ? now.mediaId != before.mediaId : !_sameMedia(before.media, now.media));
    final tokenUrl = rejoin.oldToken.isNotEmpty &&
        rejoin.oldToken != welcome.token &&
        (_openUrl?.contains('/${rejoin.oldToken}/') ?? false);
    if (changed || tokenUrl) {
      _forgetMedia();
    } else if (!rejoin.sameServer && _mediaId != -1) {
      // The same media under a restarted server's numbering: the player
      // keeps it.
      _mediaId = _playerMediaId = _openedFor = now.mediaId;
      _seenMediaId = now.mediaId;
    }
    // The intent the server lost: ready (unless the video changed and the
    // user unreadies then), and sitting out.
    var wantReady = _lastReady && !_lastAway;
    if (changed && wantReady && _seenMediaId >= 0 && AppSettings.instance.unreadyOnSwap.peek()) {
      wantReady = false;
      _lastReady = false;
    }
    if (_lastAway) {
      connection.sendPresence(PresenceIntent(
          state: Presence.away, reason: autoSitOut.autoAway ? PresenceReason.idle : PresenceReason.manual));
    }
    if (wantReady) {
      _restoringReady = true;
      connection.sendReady(true, source: 'manual');
    }
  }

  /// Whether two states' `media` are the same media (a restarted server
  /// counts its `mediaId` from 1 again).
  static bool _sameMedia(Map<String, Object?>? a, Map<String, Object?>? b) {
    if (a == null || b == null) return a == b;
    final ra = refOfStateMedia(a), rb = refOfStateMedia(b);
    if (ra != null || rb != null) return ra != null && rb != null && sameJellyfinItem(ra, rb);
    return a['name'] == b['name'] && a['size'] == b['size'] && a['url'] == b['url'] && (a['relay'] == null) == (b['relay'] == null);
  }

  /// The next state's media is new to this player: it opens again from
  /// scratch (a relay this member served for the old one stops).
  void _forgetMedia() {
    _mediaId = -1;
    _playerMediaId = -1;
    _openUrl = null;
    _openHeaders = null;
    _awaitLiveFor = -1;
    _wasPlayAllowed = false;
    diff.reset();
    _clearPendingSeek();
    _stopRelaySource();
    stopWarmSource();
    _activeOrigin = null;
  }

  /// The media's length from a state (0 unknown).
  static double _durationOf(StateBroadcast r) => (r.media?['duration'] as num?)?.toDouble() ?? 0;

  /// "Stop reconnecting".
  void cancelReconnect() => connection.cancelReconnect();

  Future<void> cancelConnect() => connection.cancelConnect();

  void retry() => connection.retry();

  /// App close, before [leave]: the players go first (no mpv may outlive
  /// the engine). The Jellyfin stop report [leave] sends keeps the
  /// position they had.
  Future<void> releasePlayers() async {
    if (_playerReady) _lastSnap = _snapNow();
    _playerReady = false;
    _ticker?.cancel();
    _ticker = null;
    await playback.disposeAll();
  }

  /// Out of the session: with [bye] (Leave, closing the app) the member
  /// leaves the server at once (others see "left"); without it (Update and
  /// restart) it goes `gone` and the restarted app takes it back within
  /// the grace.
  Future<void> leave({bool silent = false, bool bye = true}) async {
    connection.invalidate();
    await _teardown(silent: silent, bye: bye);
  }

  Future<void> _teardown({bool silent = false, bool bye = true}) async {
    connection.stop();
    _ticker?.cancel();
    _ticker = null;
    _seekTimer?.cancel();
    _seekTimer = null;
    _seekGate.reset();
    await _stopJellyfin();
    _stopRelaySource();
    stopWarmSource();
    _pendingOrigin = null;
    _pendingArt = null;
    _ownLink = null;
    _activeOrigin = null;
    _playerReady = false;
    try {
      await playback.dispose();
    } catch (_) {}
    // The last lines go before the token does, then the bye.
    await connection.close(bye: bye);
    if (!silent) serverState.value = null;
  }

  Future<void> dispose() async {
    await leave(silent: true);
    if (_jellyfinListening) {
      _jellyfinListening = false;
      jellyfin.removeListener(_onAccountsChanged);
    }
    await _stateSub?.cancel();
    await _feedSub?.cancel();
    await _nudgeSub?.cancel();
    await _errSub?.cancel();
    _statusEffect?.call();
    _bufferSub?.call();
    _aniList?.close();
    await connection.dispose();
    await playback.dispose();
  }
}
