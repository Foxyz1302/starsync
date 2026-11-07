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
import '../playback/live_window.dart' show LiveWindow;
import '../playback/media_marks.dart';
import '../playback/playback_controller.dart';
import '../platform/desktop/media_kit_host.dart' show MediaKitHost;
import '../platform/ports/link_resolver.dart';
import '../platform/ports/player_host.dart';
import '../playback/yt_dlp_app.dart' show AppYtDlp;
import '../schedule/anilist.dart';
import '../screens/home/picked_media.dart';
import '../sfx/sfx.dart' show NoopSfxService, SfxService;
import '../state/settings.dart';
import '../watch/watch_tracker.dart';
import '../sync/avatar_cache.dart';
import '../sync/live_follow.dart';
import '../sync/state_diff.dart';
import '../sync/user_seek.dart';
import '../queue/queue_controller.dart';
import '../platform/ports/shell_port.dart' show WindowActivity;
import 'afk_watch.dart';
import 'space_key.dart';
import 'connection.dart';
import 'delivery.dart';
import 'media_art.dart';
import 'media_pipeline.dart';
import 'notifier.dart';
import 'now_playing.dart';
import 'now_playing_info.dart';
import 'party.dart';
import 'shared_links.dart';
import 'status.dart';
import 'switch_trace.dart';

export 'connection.dart' show ConnectCancelled, ConnectParams;
export 'notifier.dart' show ToastItem;
export 'delivery.dart' show stateMediaRelay;
export 'status.dart';
export 'media_pipeline.dart' show MediaPipeline;

final _log = createLogger('session');

/// Display name for a link: last path segment, decoded, never the query
/// (Jellyfin-style links carry api_key there and names are broadcast).
String linkDisplayName(String url) => linkName(url);

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
  /// The next episode of the local show a file belongs to (the library's
  /// `nextAfter`, `LocalNextFinder`), set by the composition root; null:
  /// files have no continuation.
  Future<LocalNext?> Function(String path)? nextFile;
  /// The app's preferences (the composition root's).
  final AppSettings settings;
  /// Watch tracking: one watch per media, fed every second (D3).
  final WatchTracker watch;
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
  /// The one way to open media: plan → resolve → open → ready, the
  /// players, Up next's prepared one, being a relay source.
  final MediaPipeline media;
  /// The session player's marks and commands.
  PlaybackController get playback => media.playback;
  /// Timings of each media change here (see [SwitchTrace]).
  SwitchTrace get switchTrace => media.trace;
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
      pausedBy: pausedBy.value,
      liveLoading: liveLoading.value,
      liveBackAtLive: liveBackAtLive.value,
      now: _clock.value,
    ));
  });

  /// Who paused last (the member id of the feed's last `pause` from a
  /// member; a `play` clears it): "Paused by Bob".
  final pausedBy = signal<String?>(null);
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

  /// The skip pill for the current position ([skipOfferAt]: Skip OP,
  /// Skip ED, or Skip 1:30 without opening info or chapters); null while nothing
  /// is open or at `finished`. Press it with [skip].
  late final Computed<SkipOffer?> skipOffer = computed(() {
    final r = serverState.value;
    final duration = playback.duration.value;
    if (r == null || r.transport == 'finished' || duration <= Duration.zero || live.value) return null;
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

  /// Self is out (AFK or Out): not waited for, its player stays at its
  /// spot until [join].
  late final Computed<bool> selfOut = computed(() => selfMember.value?.isOut ?? false);

  /// Self is BRB: the group waits for it.
  late final Computed<bool> selfBrb = computed(() => selfMember.value?.brb ?? false);

  /// What plays is a live stream (`media.live`, ARCHITECTURE "Live
  /// streams"): no time, a timeline only to rewind; play and pause are the
  /// group's, as for any media.
  late final Computed<bool> live = computed(() => _isLive(serverState.value));

  final LiveFollow _liveFollow = LiveFollow();
  int _liveFor = -1;
  int _liveEventSeen = -1;
  DateTime? _liveReloadAt;
  // The last time the live stream was opened again at the group's point.
  ({int mediaId, int eventId, DateTime at})? _liveReopen;
  // Ticks every second while a live stream is paused: its live point runs
  // on, so how far behind it the group is grows.
  final _liveClock = signal(DateTime.now().toUtc());
  // This member's seek on the live stream until its player is there
  // (stream time [at] when it was made, running on while the group
  // plays): the bar and the time show it at once.
  final _liveSeekTarget = signal<({double at, DateTime since, bool running, int eventId})?>(null);
  // The live seek the server has not heard yet (sent at once, then once
  // the user stops for [_liveSeekGap]).
  Timer? _liveSeekTimer;
  ({double at, DateTime since, bool running})? _liveSeekNext;
  DateTime? _liveSeekSentAt;
  static const _liveSeekGap = Duration(milliseconds: RelayConstants.seekDebounceMs);
  Timer? _liveNoteTimer;
  DateTime? _liveLoadingSince;
  StateBroadcast? _liveBefore;

  /// This player opens the live stream again at a seek's moment: a brief
  /// loading state (the pill) until it plays there.
  final liveLoading = signal(false);

  /// A paused live stream that cannot be rewound went on at the live
  /// point (the pill says so for a few seconds).
  final liveBackAtLive = signal(false);

  /// Stream time of [_liveSeekTarget] now, null without one.
  double? _liveSeekNow() {
    final s = _liveSeekTarget.peek();
    if (s == null) return null;
    return s.running ? s.at + DateTime.now().toUtc().difference(s.since).inMicroseconds / 1e6 : s.at;
  }

  /// The live point of [r] at [now] (server clock): where the group would
  /// be without a rewind or a pause.
  static double _liveTopOf(StateBroadcast r, DateTime now) => serverPositionAt(r, now) + r.liveBehindAt(now);

  /// How far the group watches the live stream behind its live point (a
  /// rewind, a pause), seconds; 0 at live. A seek of this member counts
  /// at once.
  late final Computed<double> liveBehind = computed(() {
    final r = serverState.value;
    _liveClock.value;
    final pending = _liveSeekTarget.value;
    if (!_isLive(r) || r!.transport == 'finished') return 0;
    final now = connection.serverNow();
    if (pending == null) return r.liveBehindAt(now);
    return max(0, _liveTopOf(r, now) - _liveSeekNow()!);
  });

  /// The live stream's seek bar now ([LiveBar]); null unless every
  /// member can rewind it (`state.liveFrom`). Follows the player's
  /// position (a seek of this member at once).
  late final Computed<LiveBar?> liveBar = computed(() {
    final r = serverState.value;
    final pos = playback.position.value;
    final cached = playback.cached.value;
    _liveClock.value;
    final pending = _liveSeekTarget.value;
    if (!_isLive(r) || r!.transport == 'finished' || r.liveFrom <= 0) return null;
    final start = playback.knownStreamStart;
    if (start == null) return null;
    final top = _liveTopOf(r, connection.serverNow());
    final own = pending == null ? pos.inMicroseconds / 1e6 + start : _liveSeekNow()!;
    return LiveBar.of(from: r.liveFrom, top: top, own: own, start: start, cached: cached);
  });

  static bool _isLive(StateBroadcast? r) => r?.media?['live'] == true;

  Timer? _ticker;
  StreamSubscription? _stateSub;
  StreamSubscription? _feedSub;
  StreamSubscription? _nudgeSub;
  StreamSubscription? _errSub;

  /// Nobody else is in the server (D9): a plain player, links go up
  /// direct. Also true before the first state.
  late final Computed<bool> alone = computed(() {
    final r = serverState.value;
    return r == null || aloneIn(r.members, connection.memberId);
  });
  bool _playerReady = false;
  bool _wasPlayAllowed = false;
  // Self's standing in the last state; a reconnect that lands as a new
  // member (grace over, server restarted) reports it again.
  Presence _lastPresence = Presence.watching;
  // Self is out (AFK or Out) in the last state: the player stays at its
  // spot, following nothing.
  bool _lastOut = false;
  int _mediaId = -1;
  String _wsHost = '';
  int _wsPort = 0;
  // This client's last swap, until a state shows it landed (a newer
  // mediaId than [after] with this member as `swapBy`): its art goes up then.
  // [link]: the web link it came from (a relayed one has no `url`).
  // [file]: the local file it came from.
  ({HelloMedia media, int after, String? link, String? file, Uint8List? art})? _pendingArt;
  AniListClient? _aniList;
  /// This member serves the current media's bytes through the server.
  Signal<bool> get relaying => media.feeder.relaying;
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
  // The media is open here (or opening).
  String? get _openUrl => media.openUrl;
  // True while a media open is in flight: the player's duration may still
  // belong to the previous media then.
  bool get _opening => media.opening;
  /// AFK: idle while nothing plays sets this member AFK (any input
  /// brings it back), minimised while it plays sets it out.
  final AfkWatch afk = AfkWatch(DateTime.now().toUtc());

  /// The Space key: tap play / pause, hold BRB, continue without
  /// ([SpaceKey]); fed by the window's key handler.
  late final SpaceKey space = SpaceKey(this);

  // Jellyfin: the resolved ref, the mediaId it belongs to, a generation
  // that stale resolutions check, and the progress reporter.
  JellyfinRef? _jfRef;
  int _jfMediaId = -1;
  int _jfGen = 0;
  JellyfinProgressReporter? _reporter;
  PlayerSnapshot? _lastSnap;
  bool _jfToastShown = false;
  // The media whose end was recorded as a watch checkpoint.
  int _watchEndFor = -1;
  // A restarted server came back without media while this app still had
  // what played: that state, this member's id in it and the token then,
  // until a state has media again (see [_beginRestore]).
  ({StateBroadcast before, String self, String oldToken, DateTime at})? _restore;
  Timer? _restoreTimer;
  static const _restoreGiveUp = Duration(seconds: 30);
  // The member id the latest state was seen as (the old one, at a welcome).
  String _stateSelf = '';
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
      LinkResolver? ytDlp,
      PlayerHost? players,
      AppSettings? settings,
      WatchTracker? watch}) {
    final n = notifier ?? Notifier(sfx: sfx);
    final links = ytDlp ?? AppYtDlp.instance;
    return SessionCoordinator._(
      notifier: n,
      connection: connection ?? Connection(notify: n.notify),
      ytDlp: links,
      jellyfin: jellyfin ?? JellyfinAccounts.instance,
      trackPrefs: trackPrefs ?? TrackPrefs(),
      media: MediaPipeline(host: players ?? (MediaKitHost()..init()), links: links),
      settings: settings ?? AppSettings.instance,
      watch: watch ?? WatchTracker(),
    );
  }

  SessionCoordinator._(
      {required this.notifier,
      required this.connection,
      required this.ytDlp,
      required this.jellyfin,
      required this.trackPrefs,
      required this.media,
      required this.settings,
      required this.watch}) {
    connection
      ..onWelcome = _onWelcome
      ..caps = () => caps;
    media
      ..session = MediaSession(
          server: () => ServerAddress(_wsHost, _wsPort, connection.token),
          selfId: () => connection.memberId,
          // What this app can open itself: pages through the link
          // resolver (desktop: always), Jellyfin with its accounts.
          caps: () => ClientCaps(source: true, resolve: ytDlp.resolvesLinks, jellyfin: caps.jellyfin),
          jellyfin: jellyfin)
      ..notify = notify
      ..onError = _setPlayerError
      ..onOpened = _onOpened;
    // The video starts at the volume last set (the controls keep it).
    playback.volume.value = settings.playerVolume.peek();
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
  /// [leave]; each new media gets its own (the [media] pipeline). Never
  /// reused across sessions or media (a GPU-side video freeze sticks to
  /// the player).
  Future<void> initPlayer() async {
    if (_playerReady) return;
    try {
      playback.onLoadError = _setPlayerError;
      playback.onStreamLost = _streamLost;
      playback.onEndedShort = _endedShort;
      playback.onUserSeek = (d) => _userSeek(d.inMicroseconds / 1e6);
      _bufferSub ??= playback.buffered.subscribe((_) => _onBuffered());
      await media.start();
      _playerReady = true;
    } catch (e, st) {
      debugPrint('player init failed: $e\n$st');
      rethrow;
    }
  }

  /// [raw]: why this player cannot open the current media; [cookies]:
  /// which cookies a page's resolve used (D11), said with a sign-in error.
  void _setPlayerError(String raw, {String? cookies}) {
    _log.warning('player cannot open media $_mediaId: $raw${cookies == null ? '' : ' ($cookies)'}');
    _playerErrorFor = _mediaId;
    _playerErrorDuration = playback.duration.peek();
    playerError.value = withCookieNote(playErrorText(raw), cookies);
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
  // The media whose lost stream was reloaded already (once per media).
  int _streamReloadedFor = -1;

  /// The player's HTTP stream lost the file's size (an old server, a
  /// request that timed out): every seek on it would fail until a fresh
  /// open. "Reload video" once per media, as the user would.
  void _streamLost() {
    if (_streamReloadedFor == _mediaId || _mediaId < 0) return;
    _streamReloadedFor = _mediaId;
    _log.info('media $_mediaId: the stream lost its size; reloading the video once');
    unawaited(reloadVideo());
  }

  // A relay read that stopped short of the end ([_endedShort]): the media
  // waiting to be reopened (-1: none), and the reopens so far per media.
  int _shortEndFor = -1;
  ({int mediaId, int count}) _shortReopens = (mediaId: -1, count: 0);
  static const _maxShortReopens = 3;

  /// The player stopped at [at], short of the end: when it reads a relay,
  /// that is a read that failed (the source sent nothing for longer than
  /// ffmpeg's reconnects), not the end. [_reopenShort] opens it again at
  /// the server's position once the relay has its source.
  void _endedShort(Duration at) {
    if (_mediaId < 0 || !media.readsRelay) return;
    _log.info('media $_mediaId: the player stopped at ${(at.inMilliseconds / 1000).toStringAsFixed(1)} s, '
        'short of the end, reading the relay');
    _shortEndFor = _mediaId;
  }

  void _reopenShort(StateBroadcast r) {
    if (_shortEndFor < 0) return;
    final what = shortEndOf(r, _shortEndFor,
        serverPosition: serverPositionAt(r, connection.serverNow()), selfId: connection.memberId);
    if (what == ShortEnd.wait) return;
    _shortEndFor = -1;
    if (what == ShortEnd.none) return;
    final n = _shortReopens.mediaId == r.mediaId ? _shortReopens.count + 1 : 1;
    _shortReopens = (mediaId: r.mediaId, count: n);
    if (n > _maxShortReopens) {
      _log.warning('media ${r.mediaId}: stopped short again; reopened $_maxShortReopens times already, leaving it');
      return;
    }
    _log.info('media ${r.mediaId}: reopening the relay at the server\'s position');
    unawaited(reloadVideo());
  }

  void Function()? _bufferSub;

  /// "Reload video" (button, Ctrl+R, status menu): fresh
  /// player + video output, current media reopened. While it runs the
  /// player counts as not ready, so reports/seek detection pause and the
  /// next broadcast resyncs position and play/pause (diff reset + play
  /// edge). The group's wish is never touched.
  Future<void> reloadVideo() async {
    // Also allowed after a failed reload (player gone, session still on).
    if (connection.params == null || _reloadingVideo) return;
    _reloadingVideo = true;
    _playerReady = false;
    playerFault.value = '';
    try {
      _clearPendingSeek();
      diff.reset();
      await media.reload();
    } catch (e, st) {
      debugPrint('video reload failed: $e\n$st');
      playerFault.value = 'video reload failed: $e';
    } finally {
      _playerReady = playback.alive.peek();
      _reloadingVideo = false;
    }
  }

  /// Keyboard, mouse or an action: activity for AFK (and the end of it).
  void markInput() {
    final now = DateTime.now().toUtc();
    afk.input(now);
    // Back at once rather than on the next second.
    if (_lastPresence == Presence.afk) _tickAfk(serverState.peek(), now, online: connection.state.peek().online);
  }

  /// The window gained or lost the focus, was minimised or restored (the
  /// shell port's [WindowActivity], wired in `main`).
  void windowActivity(WindowActivity a) => afk.window(a, DateTime.now().toUtc());

  Future<void> connect(ConnectParams params) async {
    // Own epoch first: a cancel during any await below makes this stale.
    final epoch = connection.invalidate();
    await _teardown(silent: true);
    if (!connection.isCurrent(epoch)) throw const ConnectCancelled();
    // The last server's state is not this one's: kept, its media opened the
    // player (full, on a friend's server) over an empty new server.
    serverState.value = null;
    connection.begin(params);
    _wsHost = params.host;
    _wsPort = params.port;
    diff.reset();
    _mediaId = -1;
    media.reset();
    playerError.value = '';
    playerFault.value = '';
    fetchFailedFor.value = -1;
    restarts.value = 0;
    _statusWatch.reset();
    _memberErrors = const {};
    _lastPresence = Presence.watching;
    _lastOut = false;
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
    // Reports, the seek check and AFK run from here until leave,
    // through drops.
    _startTicker();
    try {
      final url = welcome.mediaUrl;
      if (url != null && url.isNotEmpty) await this.media.open(url);
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

  /// A media opened (the pipeline's open step): the server hears at once
  /// (a prepared media already has its buffer).
  void _onOpened(int mediaId, String url) {
    diff.reset();
    _liveFollow.reset();
    final r = serverState.peek();
    if (r != null && r.mediaId == mediaId && url == _openUrl && connection.token.isNotEmpty && _playerReady) {
      _sendReport(r);
    }
  }

  /// How many times this session opened a media in the player (a drop
  /// and return must not add one).
  int get opens => media.opens;

  // The media whose buffer reached the group's need was reported at once.
  int _bufferReportedFor = -1;

  /// While held, the report that the buffer reached the group's need goes
  /// out as it happens, not on the next tick.
  void _onBuffered() {
    final r = serverState.peek();
    if (r == null || r.transport != 'held' || _bufferReportedFor == r.mediaId) return;
    if (_lastOut || _opening || _openUrl == null || media.playerMediaId != r.mediaId || !_playerReady) return;
    if (connection.token.isEmpty || playback.bufferedSecsAhead < r.bufferNeed) return;
    _bufferReportedFor = r.mediaId;
    _sendReport(r);
  }

  /// The media of the latest `state` is open here (or has nothing to
  /// open, could not, or waits for the server): its mediaId. Up next
  /// prepares what comes next only then.
  Signal<int> get settledMediaId => media.settledMediaId;

  StateBroadcast? _queuedState;
  bool _applying = false;

  /// States are applied one at a time, newest first: two applies running
  /// interleaved could land an older pause after a newer play (seen with
  /// three viewers pressing play at once). A state that arrives meanwhile
  /// replaces any still waiting.
  void _onState(StateBroadcast r) {
    final hold = _restore;
    if (hold != null && r.media != null) _landRestore(hold, r);
    _liveBefore = serverState.peek();
    serverState.value = r;
    media.feeder.onState(r);
    _stateSelf = connection.memberId;
    if (r.transport == 'playing') switchTrace.mark(r.mediaId, SwitchTrace.playing);
    _noteLiveResume(_liveBefore, r);
    _toastMemberErrors(r);
    _warnSlowSource(r);
    _checkPlayerError(r.mediaId);
    _maybeSendArt(r);
    _enqueueApply(r);
  }

  void _enqueueApply(StateBroadcast r) {
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
    // A restarted server without media yet: the player goes on with what
    // played until it is back (or given up).
    if (_restore != null && r.media == null) return;
    final wasOut = _lastOut;
    _trackSelf(r);
    if (_lastOut) {
      // A newer media than the one this member serves: that relay ended.
      if (media.feeder.mediaId != -1 && media.feeder.mediaId != r.mediaId) media.feeder.stop();
      await _holdForOut(r);
      return;
    }
    // Back from out: the player goes to the group's moment (a fresh diff
    // seeks and sets play or pause).
    if (wasOut) diff.reset();
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
      if (same) {
        media.plan(r);
      } else {
        _seekGate.reset();
        _clearPendingSeek();
        _leaveJellyfinItem();
        diff.reset();
        final next = await media.switchTo(r);
        if (next is SwitchJellyfin) await _playJellyfin(next.source, r);
      }
      _seekGate.reset();
      _clearPendingSeek();
      if (_mediaId == r.mediaId) media.settled(r.mediaId);
    } else {
      await media.onState(r);
      _reopenShort(r);
    }
    _jellyfinTransport(r);
    if (!_playerReady || _openUrl == null) {
      _wasPlayAllowed = false;
      return;
    }
    if (_isLive(r)) {
      await _applyLive(r);
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
    // A relay without its source: what is buffered plays, nothing seeks
    // past it; one seek resumes when the source is back (D6).
    actions = media.recover(r, actions, serverPosition: serverPositionAt(r, now));
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

  /// A live stream ([live]): no diff; the player plays or pauses with the
  /// group, kept on the group's point in stream time ([LiveFollow]); at
  /// `finished` it stops where it is.
  Future<void> _applyLive(StateBroadcast r) async {
    // Whatever comes after it starts from a fresh diff.
    diff.reset();
    _wasPlayAllowed = false;
    if (_liveFor != r.mediaId) {
      _liveFor = r.mediaId;
      _liveFollow.reset();
      _liveSeekTarget.value = null;
      _setLiveLoading(false);
    }
    if (playback.switching || media.playerMediaId != r.mediaId) return;
    if (r.transport == 'finished') {
      if (playback.playing) await playback.apply(const [TransportAction(false)]);
      return;
    }
    // At the stream's end the player stays there (its reports say so; a
    // play would start the now finished playlist over).
    if (playback.completed) return;
    final start = await playback.streamStart();
    // Not read yet (an open just loaded): nothing to compare.
    if (playback.knownStreamStart == null) return;
    final playing = r.transport == 'playing';
    // Held at 0: no live point yet (the first report sets it), so it plays
    // to report one.
    final noPoint = !playing && r.position <= 0;
    // This member's own seek the server has not echoed yet: the player
    // stays where it went.
    final own = _liveSeekTarget.peek();
    final group = own != null && r.eventId <= own.eventId
        ? _liveSeekNow()
        : playing
            ? serverPositionAt(r, connection.serverNow())
            : (noPoint ? null : r.position);
    // A new point that is not this member's own seek (its player is there
    // already): followed at once, whatever an earlier seek still settles.
    if (r.eventId != _liveEventSeen) {
      _liveEventSeen = r.eventId;
      if (r.seekBy != connection.memberId) _liveFollow.moved();
    }
    final window = playback.liveWindow;
    if (playback.current?.opened case final o?) unawaited(window.read(o.url, o.headers));
    final clock = LiveWindow.clock();
    final rewind = window.fromAt(clock) != null;
    final step = _liveFollow.step(
        group: group,
        own: playback.positionSecs + start,
        start: start,
        cached: playback.cached.peek(),
        now: DateTime.now().toUtc(),
        rewind: rewind,
        paused: !playing && !noPoint);
    // Out of what mpv holds, and the stream can be rewound: opened again
    // at the group's point in this player (no new resolve), once per
    // point, then every 30 s at most.
    if (step.reload && rewind && group != null) {
      final now = DateTime.now().toUtc();
      final last = _liveReopen;
      if (last == null ||
          last.mediaId != r.mediaId ||
          last.eventId != r.eventId ||
          now.difference(last.at) > const Duration(seconds: 30)) {
        final back = window.segmentsBack(group, clock);
        if (back != null) {
          _liveReopen = (mediaId: r.mediaId, eventId: r.eventId, at: now);
          _log.info('live: the group\'s point is out of what this player holds; '
              'opening the stream again $back segments back');
          _liveFollow.reset();
          _setLiveLoading(true);
          await playback.reopenLive(back);
        }
      } else {
        // Opened again for this point already (this member's own seek):
        // the seek there once it loads need not wait.
        _liveFollow.moved();
      }
      return;
    }
    if (step.reload) {
      final at = _liveReloadAt;
      final now = DateTime.now().toUtc();
      if (at == null || now.difference(at) > const Duration(seconds: 30)) {
        _liveReloadAt = now;
        _log.info('live: the live point is far past what this player holds; opening it afresh');
        unawaited(reloadVideo());
        return;
      }
    }
    final play = playing || noPoint;
    await playback.apply([
      if (playback.playing != play) TransportAction(play),
      ...step.actions,
    ]);
  }

  void _setLiveLoading(bool on) {
    _liveLoadingSince = on ? DateTime.now().toUtc() : null;
    liveLoading.value = on;
  }

  /// Every second on a live stream: the paused live point runs on (the
  /// time and the bar follow it); this member's seek and the loading state
  /// end once the player is there (or after a while).
  void _tickLive(StateBroadcast r, DateTime now) {
    if (!_isLive(r)) return;
    if (r.transport == 'held') _liveClock.value = now;
    final start = playback.knownStreamStart;
    final own = start == null || playback.switching ? null : playback.positionSecs + start;
    final pending = _liveSeekNow();
    final since = _liveSeekTarget.peek()?.since;
    if (pending != null &&
        ((own != null && (own - pending).abs() < 1.5) || now.difference(since!) > const Duration(seconds: 15))) {
      _liveSeekTarget.value = null;
    }
    final loading = _liveLoadingSince;
    if (loading != null && _liveSeekTarget.peek() == null) {
      final group = r.transport == 'playing' ? serverPositionAt(r, connection.serverNow()) : r.position;
      if ((own != null && (own - group).abs() < 1.5) || now.difference(loading) > const Duration(seconds: 15)) {
        _setLiveLoading(false);
      }
    }
  }

  /// A paused live stream nobody can rewind went on at the live point:
  /// the pill says so for a few seconds.
  void _noteLiveResume(StateBroadcast? before, StateBroadcast r) {
    if (before == null || !_isLive(r) || before.mediaId != r.mediaId) return;
    if (before.transport != 'held' || before.position <= 0 || r.transport != 'playing') return;
    if (r.liveFrom > 0 || r.behind > 0) return;
    if (before.liveBehindAt(connection.serverNow()) < 2) return;
    liveBackAtLive.value = true;
    _liveNoteTimer?.cancel();
    _liveNoteTimer = Timer(const Duration(seconds: 5), () => liveBackAtLive.value = false);
  }

  /// Mirrors self's standing in the server into [_lastPresence] (set by
  /// others included) and [_lastOut].
  void _trackSelf(StateBroadcast r) {
    final self = selfMember.peek();
    if (self == null) return;
    _lastPresence = self.presence;
    _lastOut = self.isOut;
  }

  /// Out: the player stays at its spot, paused, following nothing. A
  /// relay this member serves goes on (it does not use the player). A
  /// new media while out: nothing to stay at, so nothing open; [join]
  /// opens it as new.
  Future<void> _holdForOut(StateBroadcast r) async {
    _wasPlayAllowed = false;
    if (r.mediaId == _mediaId && _openUrl != null) {
      if (playback.playing) await playback.apply(const [TransportAction(false)]);
      return;
    }
    await _unloadForOut();
  }

  Future<void> _unloadForOut() async {
    _wasPlayAllowed = false;
    if (_mediaId == -1 && _openUrl == null) return;
    _mediaId = -1;
    _seekGate.reset();
    _clearPendingSeek();
    diff.reset();
    _leaveJellyfinItem();
    await media.unload();
  }

  void _onFeed(FeedMessage f) {
    final r = serverState.peek();
    final event = FeedEvent.of(f,
        selfId: connection.memberId,
        // The state goes out before its feed: the item is in it.
        queueThumb: f.action == 'queue-add' ? _addedThumb(r, f) : '');
    // The server gave up fetching what everyone waits for (a fact for
    // [status]).
    if (event is FetchFailed && r != null && !f.replayed) fetchFailedFor.value = r.mediaId;
    if (f.action == 'pause' && f.actorId != 'server') pausedBy.value = f.actorId;
    if (f.action == 'play') pausedBy.value = null;
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
    // Duration only once the open media is the server's current one. Out:
    // the player at its spot says where it is.
    final known = !_opening && _openUrl != null && _mediaId == r.mediaId;
    // The buffer counts only while the player holds the server's current
    // media: before a swap's media is open it is the previous one's (or
    // none), and the start must wait for this member.
    final holds = !_opening && _openUrl != null && media.playerMediaId == r.mediaId;
    _checkPlayerError(r.mediaId);
    final error = playerError.peek();
    // A relay without its source this player cannot follow: nothing
    // buffered, so the server waits for the source (D6).
    final starved = holds && media.starved(serverPositionAt(r, connection.serverNow()));
    final buffered = holds && !starved ? playback.bufferedSecsAhead : 0.0;
    if (holds && buffered >= r.bufferNeed) switchTrace.mark(r.mediaId, SwitchTrace.buffered);
    // A live stream (or one this player found growing): positions in
    // stream time with this player's edge; a length only once the player
    // reached the end (PROTOCOL.md "Live").
    final start = playback.knownStreamStart;
    if (holds && known && (_isLive(r) || playback.growing.peek())) {
      if (start == null) {
        unawaited(playback.streamStart());
      } else {
        final own = playback.positionSecs + start;
        final ended = playback.completed;
        final edge = ended ? 0.0 : playback.durationSecs + start;
        // With how far back this player can rewind it.
        final clock = LiveWindow.clock();
        playback.liveWindow.noteEdge(edge: edge, own: own, at: clock);
        connection.sendReport(
          position: own,
          buffered: buffered,
          eventId: r.eventId,
          duration: ended ? own : 0,
          mediaId: r.mediaId,
          jf: _jfAccessFor(r),
          error: _playerErrorFor == r.mediaId ? error : '',
          edge: edge,
          from: ended ? 0 : playback.liveWindow.fromAt(clock) ?? 0,
        );
        return;
      }
    }
    connection.sendReport(
      position: holds ? playback.positionSecs : 0,
      buffered: buffered,
      eventId: r.eventId,
      // A live stream's growing length is no end.
      duration: known && !_isLive(r) && !playback.growing.peek() ? playback.durationSecs : 0,
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
    if (r != null) _tickLive(r, now);
    if (online && connection.token.isNotEmpty && r != null && _playerReady) {
      _sendReport(r);
      if (!_lastOut) _checkSeekLanded(r);
    }
    // The Jellyfin progress and the watch go on through a drop (the
    // player does).
    if (r != null) _sampleWatch(r, now);
    if (connection.token.isNotEmpty && r != null && _playerReady && !_lastOut) unawaited(_tickJellyfin(r));
    _tickAfk(r, now, online: online);
  }

  /// One second of the watch of what plays ([WatchTracker]): its position
  /// while this player holds it, whether it plays here, whether this
  /// viewer is In; its end is recorded once (it may go on after a seek
  /// back).
  void _sampleWatch(StateBroadcast state, DateTime now) {
    // A restarted server waiting for what played to come back: the watch
    // goes on with it (the player plays on); a reconnect never ends it.
    final hold = _restore;
    final waiting = hold != null && state.media == null;
    final r = waiting ? hold.before : state;
    // A live stream has no length or place to resume: watched for nothing.
    final holds = _playerReady &&
        !_lastOut &&
        !_opening &&
        _openUrl != null &&
        media.playerMediaId == r.mediaId &&
        !_isLive(r);
    final ending = playback.ending.peek()?.start;
    final self = selfMember.peek();
    watch.sample(WatchSample(
      mediaId: r.mediaId,
      media: r.media,
      ownFile: _ownFile?.$1 == r.mediaId ? _ownFile!.$2 : null,
      ownLink: _ownLink?.$1 == r.mediaId ? _ownLink!.$2 : null,
      position: holds ? playback.positionSecs : 0,
      playing: holds && (waiting || r.transport == 'playing') && playback.playing,
      present: self != null &&
          presencePolicy.countsFor(self.presence, Purpose.tracking, gone: self.gone, loading: self.loading),
      duration: holds ? playback.durationSecs : 0,
      endingStart: ending == null ? null : ending.inMilliseconds / 1000,
      at: now,
    ));
    if (waiting || _isLive(r)) return;
    if (r.transport == 'finished' && _watchEndFor != r.mediaId) {
      _watchEndFor = r.mediaId;
      watch.checkpoint(at: now);
    } else if (r.transport != 'finished' && _watchEndFor == r.mediaId) {
      _watchEndFor = -1;
    }
  }

  /// AFK's second (only while online: the state is current).
  void _tickAfk(StateBroadcast? r, DateTime now, {required bool online}) {
    final self = online ? selfMember.peek() : null;
    final step = afk.tick(now,
        self: self == null || self.gone ? null : self.presence,
        playing: r?.transport == 'playing',
        alone: r == null || aloneIn(r.members, connection.memberId));
    switch (step) {
      case AfkStep.afk:
        _log.info('afk: no input while nothing plays');
        connection.sendPresence(const PresenceIntent(state: Presence.afk));
      case AfkStep.outMinimised:
        _log.info('out: minimised while it plays');
        connection.sendPresence(const PresenceIntent(state: Presence.out, reason: PresenceReason.minimised));
      case AfkStep.back:
        _log.info('afk: back');
        connection.sendPresence(const PresenceIntent(state: Presence.watching));
      case AfkStep.stay:
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
    // A relay without its source: never asked again (the seek loop).
    if (event != r.eventId || _seekGate.holdsPlayer(now) || media.sourceDown) {
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
    // Live: the player time is no group time; rewinds go through [seekLive].
    if (live.peek()) return;
    markInput();
    final now = DateTime.now().toUtc();
    _seekGate.request(position, now);
    _clearPendingSeek();
    unawaited(playback.apply([SeekAction(position)]));
    media.noteUserSeek(position);
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
    if (_playerReady && playback.playing && (own - position).abs() < 2.0) {
      position = own;
    }
    connection.sendSeek(position, seq: settled.seq);
  }

  /// The group wants to play (anyone's): it plays once nobody is waited
  /// for (a live stream: from the paused moment, or back at live when it
  /// cannot be rewound).
  void play() {
    markInput();
    connection.sendTransport(true);
  }

  /// The group pauses (anyone's); it lasts until someone plays.
  void pause() {
    markInput();
    connection.sendTransport(false);
  }

  /// The play button: out, it joins; else play or pause the group's wish.
  void togglePlay() {
    if (selfOut.peek()) {
      join();
      return;
    }
    if (serverState.peek()?.wantsPlay ?? false) {
      pause();
    } else {
      play();
    }
  }

  /// Self BRB: the group waits until it is back. [resume]: the group was
  /// playing when the press began (its pause on key-down came first), so
  /// it plays again once everyone is back.
  void brb({bool resume = false}) {
    markInput();
    connection.sendPresence(PresenceIntent(state: Presence.brb, resume: resume));
  }

  /// Back from BRB (or AFK, or out: [join]).
  void back() {
    final self = selfMember.peek();
    if (self == null) return;
    if (self.isOut) {
      join();
      return;
    }
    if (!self.brb) return;
    markInput();
    connection.sendPresence(const PresenceIntent(state: Presence.watching));
  }

  /// "Wait for Bob": [memberId] BRB (they ran off without it); their own
  /// Space clears it.
  void waitFor(String memberId) {
    if (memberId.isEmpty) return;
    markInput();
    connection.sendPresence(PresenceIntent(target: memberId == connection.memberId ? '' : memberId, state: Presence.brb));
  }

  /// "Don't wait for Bob": continue without [memberId] (BRB: out; their
  /// video: they catch up).
  void dontWaitFor(String memberId) {
    if (memberId.isEmpty) return;
    markInput();
    connection.sendContinue(target: memberId);
  }

  /// Continue without everyone the group waits for, and play (the Space
  /// hold while someone is BRB).
  void continueWithout() {
    markInput();
    connection.sendContinue();
  }

  void seekTo(double position) => _userSeek(position);

  /// Seeks the live stream for everyone to [streamTime] (the stream's own
  /// time, within `state.liveFrom` and the live point; at or past the live
  /// point the group goes back to live, and plays). This player goes there
  /// at once when its cache holds that moment, else it opens the stream
  /// again there at once (a brief loading state); the server hears it at
  /// once, and while it keeps moving (a drag) once it stops. The others
  /// follow the state.
  void seekLive(double streamTime) {
    final r = serverState.peek();
    if (r == null || !_isLive(r) || r.transport == 'finished' || !streamTime.isFinite || streamTime <= 0) return;
    final top = _liveTopOf(r, connection.serverNow());
    final toLive = streamTime >= top - 1;
    // Without a window only Go live moves anyone.
    if (!toLive && r.liveFrom <= 0) return;
    markInput();
    _seekLiveHere(r, toLive ? top : max(streamTime, r.liveFrom));
    _sendLiveSeek(streamTime, running: toLive || r.transport == 'playing');
  }

  /// This player to [target] (stream time) now, ahead of the server.
  void _seekLiveHere(StateBroadcast r, double target) {
    final start = playback.knownStreamStart;
    if (start == null || playback.switching || media.playerMediaId != r.mediaId || playback.completed) return;
    final now = DateTime.now().toUtc();
    final toLive = target >= _liveTopOf(r, connection.serverNow()) - 1;
    // Go live plays; a seek keeps the group's play or pause.
    _liveSeekTarget.value =
        (at: target, since: now, running: toLive || r.transport == 'playing', eventId: r.eventId);
    final at = target - start;
    if (LiveFollow.holds(playback.cached.peek(), at)) {
      _liveFollow.noteSeek(now);
      unawaited(playback.apply([SeekAction(at)]));
      return;
    }
    final back = playback.liveWindow.segmentsBack(target, LiveWindow.clock());
    if (back == null) return;
    // The state that follows (this seek's) finds the cache holding it.
    _liveReopen = (mediaId: r.mediaId, eventId: r.eventId + 1, at: now);
    _liveFollow.reset();
    _setLiveLoading(true);
    _log.info('live: a seek out of what this player holds; opening the stream again $back segments back');
    unawaited(playback.reopenLive(back).then((_) async {
      // Once it is loaded, at the moment itself (the open starts at a
      // segment's start).
      for (var i = 0; i < 100 && playback.switching; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final s = serverState.peek();
      if (s != null) _enqueueApply(s);
    }));
  }

  /// [streamTime] to the server: at once, or, while seeks keep coming (a
  /// drag), the last once they stop for [_liveSeekGap]; [running]: the
  /// moment runs on since (the group plays), as this player's does.
  void _sendLiveSeek(double streamTime, {required bool running}) {
    final now = DateTime.now();
    final last = _liveSeekSentAt;
    if (_liveSeekTimer == null && (last == null || now.difference(last) >= _liveSeekGap)) {
      _liveSeekSentAt = now;
      connection.sendSeek(streamTime);
      return;
    }
    _liveSeekNext = (at: streamTime, since: now, running: running);
    _liveSeekTimer?.cancel();
    _liveSeekTimer = Timer(_liveSeekGap, () {
      _liveSeekTimer = null;
      final next = _liveSeekNext;
      _liveSeekNext = null;
      if (next == null) return;
      final sent = DateTime.now();
      _liveSeekSentAt = sent;
      connection.sendSeek(next.running ? next.at + sent.difference(next.since).inMicroseconds / 1e6 : next.at);
    });
  }

  /// Go live: the group back to the live point (and playing).
  void goLive() {
    final r = serverState.peek();
    if (r == null || !_isLive(r) || r.transport == 'finished') return;
    seekLive(_liveTopOf(r, connection.serverNow()) + 60);
  }

  /// Arrow keys: relative to a seek still in flight, so repeated presses
  /// add up. Live: within the window everyone can rewind.
  void nudge(double deltaSecs) {
    final r = serverState.peek();
    if (r == null || _openUrl == null) return;
    if (_isLive(r)) {
      if (r.liveFrom > 0 && r.transport != 'finished') {
        final now = connection.serverNow();
        final base = _liveSeekNow() ?? serverPositionAt(r, now);
        final target = base + deltaSecs;
        seekLive(target < r.liveFrom ? r.liveFrom : target);
      }
      return;
    }
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

  /// PgUp (+1) / PgDn (-1): next / previous chapter as mpv steps them
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

  /// Name, picture (base64 PNG, empty removes it) and/or colour
  /// (`#rrggbb`) change for everyone now; a later fresh join sends them
  /// too.
  void updateProfile({String? name, String? avatar, String? color}) {
    connection.updateProfile(name: name, avatar: avatar, color: color);
  }

  /// Sets [memberId] out (anyone, the host included), self when null.
  /// [reason]: why self goes out (the player closed).
  void goOut([String? memberId, PresenceReason reason = PresenceReason.manual]) {
    final target = memberId ?? connection.memberId;
    if (target.isEmpty) return;
    final self = target == connection.memberId;
    markInput();
    connection.sendPresence(PresenceIntent(target: self ? '' : target, state: Presence.out, reason: reason));
  }

  /// Back from AFK or out (`in`): the player goes to the group's moment,
  /// loading in the background (a playing group does not wait for it).
  void join() {
    final self = selfMember.peek();
    if (self == null || !self.isOut) return;
    markInput();
    connection.sendPresence(const PresenceIntent(state: Presence.watching));
  }

  /// Pokes [memberId]: only they hear it (out or not).
  void nudgeMember(String memberId) {
    if (memberId.isEmpty || memberId == connection.memberId) return;
    markInput();
    connection.sendNudge(memberId);
  }

  /// [queueId]: the Up next item this puts up (the server takes it off
  /// the queue); [art]: a picture to send as its art (a queued item's).
  void _swap(HelloMedia media, {String? link, String? file, String? queueId, Uint8List? art, SwapRestore? restore}) {
    // A swap sent into a dropped link would be lost without a word.
    if (!connection.state.peek().online) {
      notify(const ActionFailed('Reconnecting: put it up again once back'));
      return;
    }
    // Putting something up means watching it: in first. Not for Up next
    // coming up by itself: whoever puts it up may be out.
    final self = selfMember.peek();
    if (self != null && self.isOut && queueId == null && restore == null) {
      connection.sendPresence(const PresenceIntent(state: Presence.watching));
    }
    _pendingArt =
        (media: media, after: serverState.peek()?.mediaId ?? 0, link: link ?? media.url, file: file, art: art);
    connection.sendSwap(media, queueId: queueId, restore: restore);
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
    final file = pending.file;
    _ownFile = file == null ? null : (r.mediaId, file);
    ownFile.value = _ownFile;
    unawaited(_sendArt(r.mediaId, pending.media, pending.link, given: pending.art));
  }

  /// The link this app put up as [StateBroadcast.mediaId] (passed on or
  /// fetched by the server, so not in the state).
  (int, String)? _ownLink;
  (int, String)? _ownFile;

  /// The local file this app put up, with the mediaId it went up as (null:
  /// none); Up next's continuation of a show reads it.
  final ownFile = signal<(int, String)?>(null);

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
      {LinkRelay relay = LinkRelay.direct, bool anyway = false, String? queueId, SwapRestore? restore}) async {
    markInput();
    final media = await mediaForLink(jellyfin, url);
    if (media.jellyfin != null) {
      this.media.expectOrigin(JellyfinOrigin(url));
      _swap(media.copyWith(relay: const MediaRelay()), queueId: queueId, restore: restore);
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
    // A live stream is never passed on or fetched: everyone opens it, in
    // any mode (ARCHITECTURE "Live streams").
    final live = probe?.info?.isLive ?? false;
    if (relay == LinkRelay.direct || live) {
      _swap(HelloMedia(name: name, size: 0, duration: 0, url: url, ref: what, live: live),
          queueId: queueId, restore: restore);
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
      final warm = queueId == null ? const <RelayTrack>[] : this.media.feeder.warmTracks(queueId);
      final fed = warm.isNotEmpty;
      // Read once for the player and the relay (SharedLinks): the check's
      // reader is the one the media then uses. Pieces tracks: a check of
      // their own.
      final share = !fed && SharedLinks.fits(probe);
      final check = fed || share ? null : LinkRelayMedia(uri, ytDlp: y, probe: probe);
      var size = 0;
      final List<RelayTrackSpec> specs;
      try {
        final tracks = fed
            ? warm
            : share
                ? await (await this.media.shared.forSwap(url, LinkRelayMedia(uri, ytDlp: y, probe: probe), probe))
                    .upload
                    .open()
                : await check!.open().timeout(const Duration(seconds: 15));
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
      this.media.expectOrigin(LinkOrigin(url, probe, y));
      _swap(HelloMedia(name: name, size: size, duration: 0, relay: MediaRelay(tracks: specs), ref: what),
          link: url, queueId: queueId, restore: restore);
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
        queueId: queueId,
        restore: restore);
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
  void swapJellyfin(JellyfinMedia media, {String? queueId, SwapRestore? restore}) {
    markInput();
    this.media.expectOrigin(const JellyfinOrigin(null));
    _swap(mediaForPick(media).copyWith(relay: const MediaRelay()), queueId: queueId, restore: restore);
  }

  /// A file on this computer. The host's app serves it itself; anyone
  /// else's goes through the server's relay. Returns an error text, or null
  /// when sent.
  Future<String?> swapFile(String path, {String? queueId, SwapRestore? restore}) async {
    markInput();
    final what = fileRef?.call(path);
    final host = hostFile;
    if (host != null) {
      final file = await host(path);
      if (file == null) return 'file not found — check the path';
      _swap(HelloMedia(name: file.name, size: file.size, duration: 0, ref: what),
          file: path, queueId: queueId, restore: restore);
      return null;
    }
    final file = File(path);
    if (!await file.exists()) return 'file not found — check the path';
    media.expectOrigin(FileOrigin(path));
    _swap(HelloMedia(
        name: file.uri.pathSegments.last,
        size: await file.length(),
        duration: 0,
        relay: const MediaRelay(),
        ref: what),
        file: path,
        queueId: queueId,
        restore: restore);
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

  /// The next episode now: through Up next when it is the continuation
  /// there (its preload and relay carry on), else a swap.
  void playNextEpisode() {
    final n = nextEpisode.peek();
    if (n == null) return;
    final auto = queue.continues.peek();
    if (auto != null && auto.media.jellyfin?.itemId == n.item.id) {
      queue.playNow(auto.id);
    } else {
      swapJellyfin(n.pick);
    }
  }

  void playPreviousEpisode() {
    final p = previousEpisode.peek();
    if (p != null) swapJellyfin(p.pick);
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
    _blockedKey = '';
    currentRef.value = null;
    jellyfinPlan.value = null;
    jellyfinBlocked.value = null;
    previousEpisode.value = null;
    nextEpisode.value = null;
    nextPromptVisible.value = false;
    playback.segments.value = const [];
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
      paused: !playback.playing,
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
      paused: !playback.playing,
      aid: ids.aid,
      sid: ids.sid,
    );
  }

  /// This member's `/j/` URL for [ref] (the server's Jellyfin login).
  String? jellyfinRelayUrl(JellyfinRef ref) =>
      connection.token.isEmpty ? null : ServerAddress(_wsHost, _wsPort, connection.token).jellyfinUrl(ref);

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

  /// Resolves [source]'s item for this viewer and opens it (the media
  /// pipeline: own account, the server's login, the member passing it on,
  /// or blocked), then this item's own work: progress reports and
  /// neighbouring episodes with an own account, the audio/subtitle choice
  /// carried over.
  Future<void> _playJellyfin(JellyfinSource source, StateBroadcast r) async {
    final ref = source.ref;
    final gen = ++_jfGen;
    _jfRef = ref;
    _jfMediaId = r.mediaId;
    currentRef.value = ref;
    final plan = await media.openJellyfin(source, r, warm: _takeWarmJellyfin(ref), current: () => gen == _jfGen);
    if (plan == null || gen != _jfGen) return;
    jellyfinPlan.value = plan;
    switch (plan) {
      case BlockedPlay():
        jellyfinBlocked.value = plan;
        _blockedKey = _accountKey(ref.serverId);
        return;
      case RelayPlay():
        jellyfinBlocked.value = null;
        if (_openUrl == null) return;
      case OwnPlay():
        jellyfinBlocked.value = null;
        if (_openUrl == null) return;
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
        // The watch of this media (the tracker feeds it; Jellyfin's played
        // state and resume point are what came before).
        _sampleWatch(r, DateTime.now().toUtc());
        watch.before(
            played: before?.played ?? false,
            resumeAt: (before?.playbackPositionTicks ?? 0) / jellyfinTicksPerSecond);
        final reporter = JellyfinProgressReporter(
          client: plan.client,
          itemId: ref.itemId,
          source: plan.source,
          playSessionId: plan.info.playSessionId,
          playedBefore: before?.played ?? false,
          resumeTicksBefore: before?.playbackPositionTicks ?? 0,
          watch: watch.mediaId == r.mediaId ? watch.session : null,
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
    if (next != null && duration > 0 && r.transport != 'finished') {
      final item = (jellyfinPlan.peek() as OwnPlay?)?.item;
      final at = nextPromptStart(item, Duration(milliseconds: (duration * 1000).round()),
          endingStart: playback.ending.peek()?.start);
      show = snap.position * 1000 >= at.inMilliseconds;
    }
    nextPromptVisible.value = show;
  }

  /// Per state: played to the end -> Stopped (with the watched rule's
  /// verdict); seeked back from the end -> Playing again.
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
    if (finished) nextPromptVisible.value = false;
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
    if (r == null) return;
    final source = media.plan(r);
    if (source is JellyfinSource) unawaited(_playJellyfin(source, r));
  }

  /// A welcome's part here (see [WelcomeHandler]), before its state is
  /// applied: any welcome's AnimeFlow address is remembered. The first one and a resumed one need nothing: the member
  /// kept everything (its standing, queue items, relay) and the player
  /// kept the media. A new member after a drop (grace over, or the server
  /// restarted) reports its standing again (BRB, AFK, out), and the media
  /// opens again only if it changed or its URL named the old token.
  void _onWelcome(WelcomeMessage welcome, Rejoin rejoin) {
    // The server's AnimeFlow (the Schedule's): kept for when no server
    // says one.
    if (welcome.animeFlow case final flow?) settings.rememberAnimeFlow(flow);
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
    // A restarted server without media while this app had some: it is
    // offered back (and the player keeps playing it meanwhile).
    final restoring = !rejoin.sameServer && before?.media != null && now != null && now.media == null;
    if (restoring) {
      _beginRestore(before!, rejoin.oldToken);
    } else if (changed || tokenUrl) {
      _forgetMedia();
    } else if (!rejoin.sameServer && _mediaId != -1) {
      // The same media under a restarted server's numbering: the player
      // keeps it, and so do the watch and the Jellyfin reports.
      watch.renumber(before.mediaId, now.mediaId);
      if (_jfMediaId == before.mediaId) _jfMediaId = now.mediaId;
      _mediaId = now.mediaId;
      media.renumber(now.mediaId);
    }
    // The standing the server lost: BRB survives a server restart (the
    // group waits again), and so do AFK and out.
    if (_lastPresence != Presence.watching) connection.sendPresence(PresenceIntent(state: _lastPresence));
  }

  /// A restarted server answered without media while this app had [before]
  /// up: one app puts it back (`swap.restore`; the server keeps the first
  /// offer). Who offers is decided from the old state alone, so the apps
  /// agree: who put it up or passes it on first, then the others by their
  /// old member id, 1.5 s apart; each only while the server is still
  /// empty and only what it can put up (see [_offerBack]). Given up after
  /// [_restoreGiveUp]: then the next state is applied as it is.
  void _beginRestore(StateBroadcast before, String oldToken) {
    final self = _stateSelf;
    _restore = (before: before, self: self, oldToken: oldToken, at: DateTime.now());
    queue.restoreFrom(before.mediaId);
    final swapBy = before.media?['swapBy'];
    final source = stateMediaRelay(before)?.source;
    final first = self.isNotEmpty && (self == swapBy || self == source);
    final others = [
      for (final m in before.members)
        if (m.id != swapBy && m.id != source && isPresent(m)) m.id,
    ]..sort(compareMemberIds);
    final rank = others.indexOf(self);
    final wait = first
        ? const Duration(milliseconds: 500)
        : Duration(milliseconds: 3000 + 1500 * (rank < 0 ? others.length : rank));
    _log.info('the server restarted without media: offering "${before.media?['name']}" back in '
        '${wait.inMilliseconds} ms unless someone does first');
    _restoreTimer?.cancel();
    _restoreTimer = Timer(wait, () => unawaited(_offerBack()));
  }

  /// Puts what played back up the way it went up, from here, when this app
  /// can: a Jellyfin item with its own account (it passes it on again),
  /// its file, the link it put up (passed on, fetched by the server, or
  /// opened by everyone), a link everyone opens. Where it was: this
  /// player's position, else the old server's clock; and whether it
  /// played.
  Future<void> _offerBack() async {
    final hold = _restore;
    if (hold == null) return;
    _restoreTimer = Timer(_restoreGiveUp - DateTime.now().difference(hold.at), _giveUpRestore);
    final r = serverState.peek();
    if (r == null || r.media != null || !connection.state.peek().online) return;
    final before = hold.before;
    final m = before.media!;
    final holds = _playerReady && media.playerMediaId == before.mediaId && _openUrl != null;
    final position = holds ? playback.positionSecs : serverPositionAt(before, connection.serverNow());
    final restore = SwapRestore(position: position, transport: before.transport);
    final relay = stateMediaRelay(before);
    final ownFile = _ownFile?.$1 == before.mediaId ? _ownFile!.$2 : null;
    final ownLink = _ownLink?.$1 == before.mediaId ? _ownLink!.$2 : null;
    final ref = refOfStateMedia(m);
    String? error = 'nothing here to put it back from';
    if (ref != null) {
      final pick = pickForRef(jellyfin, ref);
      if (pick != null) {
        swapJellyfin(pick, restore: restore);
        error = null;
      }
    } else if (ownFile != null) {
      error = await swapFile(ownFile, restore: restore);
    } else {
      final url = ownLink ?? stateMediaUrl(before);
      final mode = relay == null ? LinkRelay.direct : (relay.fetch ? LinkRelay.server : LinkRelay.me);
      if (url != null && (url.startsWith('http://') || url.startsWith('https://')) && (mode != LinkRelay.me || ownLink != null)) {
        error = await swapLink(url, relay: mode, anyway: true, restore: restore);
      }
    }
    _log.info(error == null
        ? 'offered "${m['name']}" back at ${position.toStringAsFixed(1)} s (${before.transport})'
        : 'cannot offer "${m['name']}" back: $error');
  }

  /// Nobody put it back: the player lets go of it with the next state.
  void _giveUpRestore() {
    if (_restore == null) return;
    _log.info('nothing came back after the restart: letting go of what played');
    _restore = null;
    _restoreTimer = null;
    queue.restoreFrom(-1);
    _forgetMedia();
    final r = serverState.peek();
    if (r != null) _onState(r);
  }

  /// What played is up again ([r], a new mediaId) or other media is: the
  /// same media carries on here, the player keeping it unless its URL
  /// named the old server's token (a relay, the host's file: opened
  /// again); the watch, the Jellyfin reports and what this member passes
  /// on go on with it. Up next comes back too ([QueueController]).
  void _landRestore(({StateBroadcast before, String self, String oldToken, DateTime at}) hold, StateBroadcast r) {
    _restore = null;
    _restoreTimer?.cancel();
    _restoreTimer = null;
    final before = hold.before;
    if (!_sameMedia(before.media, r.media)) {
      _log.info('after the restart the server has other media: "${r.media?['name']}"');
      queue.restoreFrom(-1);
      _forgetMedia();
      return;
    }
    _log.info('"${r.media?['name']}" is back as media ${r.mediaId}');
    watch.renumber(before.mediaId, r.mediaId);
    if (_watchEndFor == before.mediaId) _watchEndFor = r.mediaId;
    queue.restoreAfterRestart(before, hold.self, winner: r.media?['swapBy'] == connection.memberId);
    final url = _openUrl;
    final keep = _mediaId == before.mediaId &&
        media.playerMediaId == before.mediaId &&
        url != null &&
        (hold.oldToken.isEmpty || !url.contains('/${hold.oldToken}/'));
    if (!keep) {
      _forgetMedia();
      return;
    }
    if (_jfMediaId == before.mediaId) _jfMediaId = r.mediaId;
    _mediaId = r.mediaId;
    diff.reset();
    final plan = jellyfinPlan.peek();
    media.resumeAs(r, ownJellyfin: plan is OwnPlay ? (url: plan.url, headers: plan.headers) : null);
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
    _wasPlayAllowed = false;
    diff.reset();
    _clearPendingSeek();
    media.forget();
  }

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
    await media.disposeAll();
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
    watch.close();
    _watchEndFor = -1;
    _restore = null;
    _restoreTimer?.cancel();
    _restoreTimer = null;
    queue.restoreFrom(-1);
    await _stopJellyfin();
    media.reset();
    _pendingArt = null;
    _ownLink = null;
    _ownFile = null;
    ownFile.value = null;
    _playerReady = false;
    try {
      await media.release();
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
    _liveSeekTimer?.cancel();
    _liveNoteTimer?.cancel();
    _statusEffect?.call();
    _bufferSub?.call();
    _aniList?.close();
    await connection.dispose();
    await media.dispose();
  }
}
