import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, mapEquals, visibleForTesting;
import 'package:signals/signals.dart';
import 'package:sync_relay_core/core.dart';

import '../jellyfin/accounts.dart';
import '../jellyfin/session_media.dart';
import '../platform/ports/link_resolver.dart';
import '../platform/ports/player_host.dart';
import '../playback/playback_controller.dart';
import '../sync/state_diff.dart';
import 'app_events.dart';
import 'delivery.dart' show stateMediaRelay;
import 'media_plan.dart';
import 'relay_feeder.dart';
import 'shared_links.dart';
import 'switch_trace.dart';

export 'media_plan.dart';

final _log = createLogger('session');

// The one way to open media: plan → resolve → open → ready.
//
// - plan ([planMedia]): from the state, what this member serves and its
//   capabilities, where this app reads the media from.
// - resolve: a Jellyfin item through this app's account, the server's
//   login or the member passing it on ([openJellyfin]); a web page through
//   this app's yt-dlp ([LinkResolver]: its stream URLs, an EDL of video and
//   audio, the CDN's headers, its subtitles; mpv's own yt-dlp hook is
//   off); a relay waits until it is fed.
// - open: a player through the [PlayerHost]: the prepared one (Up next's
//   preload) promoted, else a fresh one per media; the same media again
//   keeps its player.
// - ready: the buffer the gate needs is reported at once (the
//   coordinator's report).
//
// Being a relay source ([RelayFeeder]) and the viewer's side of a source
// that drops ([recover]) live here too. A link this member passes on is
// read from the site once ([SharedLinks]): its player opens the shared
// reader's loopback URL and the relay serves the same bytes.

/// What the coordinator does next after [MediaPipeline.switchTo]: a
/// Jellyfin item resolves and opens through [MediaPipeline.openJellyfin]
/// (the coordinator keeps its per-item work: progress, episodes, tracks).
sealed class SwitchResult {
  const SwitchResult();
}

final class SwitchDone extends SwitchResult {
  const SwitchDone();
}

final class SwitchJellyfin extends SwitchResult {
  final JellyfinSource source;
  const SwitchJellyfin(this.source);
}

/// The session context the pipeline reads (the coordinator's connection
/// and accounts).
class MediaSession {
  final ServerAddress Function() server;
  final String Function() selfId;
  final ClientCaps Function() caps;
  final JellyfinAccounts jellyfin;
  const MediaSession({required this.server, required this.selfId, required this.caps, required this.jellyfin});

  static final none = MediaSession(
      server: () => const ServerAddress('', 0, ''),
      selfId: () => '',
      caps: () => const ClientCaps(),
      jellyfin: JellyfinAccounts(store: MemoryJellyfinStore()));
}

class MediaPipeline {
  final PlayerHost host;
  final LinkResolver? links;
  final PlaybackController playback;
  final SwitchTrace trace;
  late final RelayFeeder feeder;

  /// The links this member passes on, read once for its player and the
  /// relay.
  final shared = SharedLinks();
  MediaSession session;

  /// The player could not open the current media (raw words: the
  /// coordinator turns them into `report.error`; [cookies]: which ones a
  /// page's resolve used, D11).
  void Function(String raw, {String? cookies}) onError = (_, {cookies}) {};
  void Function(AppEvent event) notify = (_) {};

  /// A media opened in the session player ([open]): the coordinator
  /// reports at once (a promoted player already has its buffer).
  void Function(int mediaId, String url) onOpened = (_, _) {};

  MediaPipeline({
    required this.host,
    this.links,
    PlaybackController? playback,
    SwitchTrace? trace,
    MediaSession? session,
  })  : playback = playback ?? PlaybackController(host),
        trace = trace ?? SwitchTrace(),
        session = session ?? MediaSession.none {
    feeder = RelayFeeder(
        server: () => this.session.server(),
        notify: (e) => notify(e),
        onWarmEnded: (queueId) => shared.dropWarm(queueId));
  }

  // ------------------------------------------------------------ players

  // The current player has had media opened in it (one fresh from
  // [start] has not, so the first open after join or Reload video uses
  // it).
  bool _held = false;

  /// A live session player exists.
  bool get ready => playback.alive.peek();

  /// The session's first player (on join); each new media gets its own.
  Future<void> start() async {
    if (playback.current != null) return;
    final p = await host.create(PlayerRole.session);
    _held = false;
    playback.attach(p);
  }

  /// "Reload video": a fresh player and video output, the current media
  /// opened again (the caller resyncs).
  Future<void> reload() async {
    final old = playback.detach();
    if (old != null) await host.retire(old);
    await start();
    final url = _openUrl, headers = _openHeaders;
    _openUrl = null;
    // A page is resolved again: its stream URLs may have expired.
    if (url != null) await open(url, headers: headers, fresh: true, resolve: _openResolve);
  }

  /// Leave: the prepared player and the session player go.
  Future<void> release() async {
    await dropPrepared();
    final old = playback.detach();
    _held = false;
    if (old != null) await host.retire(old);
  }

  /// App close: every player goes now (no mpv may outlive the engine).
  Future<void> disposeAll() async {
    _pre = null;
    playback.detach();
    await host.disposeAll();
  }

  /// Replaces the current player with a fresh one (pins, hwdec, volume,
  /// yt-dlp hook, shaders), its video output ready before the view swaps
  /// to it when the view is up. True once it is the session player.
  Future<bool> _freshPlayer() async {
    await host.retiring;
    final old = playback.current;
    if (old == null) return false;
    final HostedPlayer p;
    try {
      p = await host.create(PlayerRole.session);
    } catch (e) {
      debugPrint('fresh player: $e');
      return false;
    }
    HostedVideo? video;
    try {
      // The view is up: the new output is created (and its texture
      // registered) before the view swaps, so the old picture stays until
      // then. Made by the view instead while the render mode is unknown,
      // so the probe hears its GL init.
      if (playback.hasVideo && host.renderMode.peek() != RenderMode.unknown) {
        video = host.video(p);
        await video.ready;
      }
    } catch (e) {
      debugPrint('fresh player setup: $e');
    }
    // Released or reloaded meanwhile: that player stays.
    if (!identical(old, playback.current)) {
      await host.dispose(p);
      return false;
    }
    final prev = playback.attach(p, video: video);
    _held = true;
    if (prev != null) unawaited(host.retire(prev));
    return true;
  }

  // ------------------------------------------------------------ resolve

  /// [url] is a web page this app resolves: http(s), not this server, not
  /// named like a media file.
  bool _isPage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return false;
    final s = session.server();
    if (uri.host == s.host && uri.port == s.port) return false;
    return !hasMediaExtension(uri);
  }

  /// The resolve step for a link: a page through this app's yt-dlp (the
  /// probe, remembered a while; [fresh] asks again: stream URLs expire)
  /// gives what a player opens; a media file is opened as is, and so is a
  /// stream opened with headers (a Jellyfin item's, with its token). Throws
  /// a [ResolveFailure] in plain words, with the cookies used (D11).
  Future<_Target> _resolve(String url, Map<String, String>? headers, {bool fresh = false}) async {
    if (headers == null || headers.isEmpty) {
      // A link this member passes on: the shared reader's loopback URL
      // (it resolves an expired URL again itself, so [fresh] is moot).
      final link = await shared.playerFor(url);
      if (link != null) return _Target(link.source.playerUrl, const {}, subtitles: link.subtitles, shared: true);
    }
    if (!_isPage(url) || (headers != null && headers.isNotEmpty)) return _Target(url, headers ?? const {});
    final l = links;
    if (l == null) throw const ResolveFailure('no link resolver here');
    final LinkProbe probe;
    try {
      probe = await l.probe(url, fresh: fresh).timeout(const Duration(seconds: 60));
    } catch (e) {
      throw ResolveFailure('$e');
    }
    if (!probe.isPage) return _Target(url, headers ?? const {});
    final play = probe.info?.play;
    if (play == null) {
      throw ResolveFailure(probe.ytDlpError ?? (probe.info == null ? 'Not a video page yt-dlp knows' : 'no format a player opens'),
          cookies: probe.cookies);
    }
    if (headers == null || headers.isEmpty) {
      // Played here only: through a reader of its own too, which resumes
      // after a cut and gets a fresh address (a CDN cuts mpv's reconnects
      // off). Pieces tracks, or a reader that cannot open: the site as is.
      final y = await l.ytDlp;
      final local =
          await shared.local(url, probe, () => LinkRelayMedia(Uri.parse(url), ytDlp: y, probe: probe), fresh: fresh);
      if (local != null) {
        return _Target(local.source.playerUrl, const {}, subtitles: local.subtitles, shared: true, local: true);
      }
    }
    return _Target(play.mpvUrl, {...play.headers, ...?headers}, subtitles: play.subtitles);
  }

  /// The [SharedLinks.local] readers the player and the preload use stay;
  /// the rest close.
  void _trimLocal() => shared.trimLocal({_openUrl, _pre?.url});

  /// The page's subtitles on [p] once its media is in (not selected: the
  /// usual choice applies).
  Future<void> _addSubtitles(HostedPlayer p, List<YtDlpSubtitle> subs) async {
    if (subs.isEmpty) return;
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (p.state.duration <= Duration.zero) {
      if (p.disposed || DateTime.now().isAfter(end)) return;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    for (final sub in subs) {
      try {
        await p.command(['sub-add', sub.url, 'auto', sub.name.isEmpty ? sub.lang : sub.name, sub.lang]);
      } catch (e) {
        debugPrint('subtitle ${sub.lang}: $e');
      }
    }
  }

  // --------------------------------------------------------------- open

  String? _openUrl;
  Map<String, String>? _openHeaders;
  // [_openUrl] went through the page resolve (not a Jellyfin stream).
  bool _openResolve = true;
  bool _opening = false;
  int _opens = 0;

  /// The URL open (or opening) in the player; null for none.
  String? get openUrl => _openUrl;

  /// An open is in flight: the player's duration may still be the
  /// previous media's.
  bool get opening => _opening;

  /// How many times this session opened a media (a drop and return must
  /// not add one).
  int get opens => _opens;

  /// The mediaId whose media the player holds (or is opening); -1 none.
  int playerMediaId = -1;
  // [playerMediaId] at the last open: the same media again (a reconnect,
  // joining back) keeps the player, any other gets a fresh one.
  int _openedFor = -1;
  int _mediaId = -1;

  /// The media of the latest state is open here (or has nothing to open,
  /// could not, or waits for the server): its mediaId. Up next prepares
  /// what comes next only then, so the two never compete.
  final settledMediaId = signal(-1);

  /// Opens [url] (with [headers] on every request) in the session player:
  /// the prepared player when it holds the same, else a fresh one when the
  /// player held other media. False on failure (the error went to
  /// [onError]). [resolve]: a web page is resolved first (not for a
  /// Jellyfin stream).
  Future<bool> open(String url, {Map<String, String>? headers, bool fresh = false, bool resolve = true}) async {
    if (url == _openUrl) return true;
    _opens++;
    final mediaId = _mediaId;
    _log.info('media $mediaId: open ${_urlKind(url, headers)}: ${logUrl(url)}'
        '${headers == null || headers.isEmpty ? '' : ' (headers: ${headers.keys.join(', ')})'}');
    final keepPlayer = playerMediaId == _openedFor;
    _openedFor = playerMediaId;
    _openUrl = url;
    _openHeaders = headers;
    _openResolve = resolve;
    _opening = true;
    _trimLocal();
    try {
      trace.mark(mediaId, SwitchTrace.open);
      final promoted = await _openInPlayer(url, headers,
          keepPlayer: keepPlayer,
          fresh: fresh,
          resolve: resolve,
          onFresh: () => trace.mark(mediaId, SwitchTrace.player));
      trace.mark(mediaId, promoted ? SwitchTrace.preloaded : SwitchTrace.opened);
      _opening = false;
      onOpened(mediaId, url);
      return true;
    } on ResolveFailure catch (e) {
      _log.warning('media $mediaId: cannot resolve ${logUrl(url)}: ${e.message}${e.cookies == null ? '' : ' (${e.cookies})'}');
      onError(e.message, cookies: e.cookies);
      return false;
    } catch (e) {
      debugPrint('open media failed: $e');
      onError('$e');
      return false;
    } finally {
      _opening = false;
    }
  }

  Future<bool> _openInPlayer(String url, Map<String, String>? headers,
      {required bool keepPlayer, bool fresh = false, bool resolve = true, void Function()? onFresh}) async {
    if (playback.current == null) return false;
    final pre = _pre;
    if (pre != null && pre.matches(url, headers) && await _promote(pre)) return true;
    final target = resolve ? await _resolve(url, headers, fresh: fresh) : _Target(url, headers ?? const {});
    if (!identical(target.url, url)) trace.mark(_mediaId, SwitchTrace.resolved);
    if (_held && !keepPlayer && await _freshPlayer()) onFresh?.call();
    final p = playback.current;
    if (p == null) return false;
    _held = true;
    playback.beginOpen();
    await p.open(target.url, headers: target.headers);
    unawaited(_addSubtitles(p, target.subtitles));
    return false;
  }

  /// What [url] is, for the log.
  String _urlKind(String url, Map<String, String>? headers) {
    if (url.startsWith('edl://')) return 'relay (tracks)';
    final u = Uri.tryParse(url);
    if (u == null || !(u.isScheme('http') || u.isScheme('https'))) return 'local file';
    final s = session.server();
    if (u.host == s.host && u.port == s.port && u.pathSegments.isNotEmpty) {
      return switch (u.pathSegments.first) {
        'r' => 'relay',
        'm' => "the host's file",
        'j' => "Jellyfin through the server's login",
        _ => 'server URL',
      };
    }
    if (headers != null && headers.isNotEmpty) return 'Jellyfin, own sign-in';
    if (shared.has(url)) return 'link passed on, read once here';
    if (shared.hasLocal(url)) return 'link, read here with resume';
    return 'link, fetched here';
  }

  // ----------------------------------------------------- plan and switch

  // What this member serves: set at its swap, claimed by the state that
  // names it as the relay's source.
  MediaOrigin? _pendingOrigin;
  (int, MediaOrigin)? _activeOrigin;
  // The relayed media this viewer opens once it is live.
  int _awaitLiveFor = -1;

  /// This member's swap is about to be relayed from [origin].
  void expectOrigin(MediaOrigin origin) => _pendingOrigin = origin;

  /// Where this app reads [r]'s media from (claims a pending origin when
  /// the state names this member as the source).
  SourcePlan plan(StateBroadcast r) {
    final relay = stateMediaRelay(r);
    final self = session.selfId();
    if (relay != null && relay.source.isNotEmpty && relay.source == self) {
      final pending = _pendingOrigin;
      if (pending != null) {
        _pendingOrigin = null;
        _activeOrigin = (r.mediaId, pending);
      }
    }
    final active = _activeOrigin;
    return planMedia(PlanInput(
      state: r,
      selfId: self,
      caps: session.caps(),
      server: session.server(),
      origin: active != null && active.$1 == r.mediaId ? active.$2 : null,
      ownJellyfin: (id) =>
          session.jellyfin.account(id) != null &&
          session.jellyfin.statusOf(id) != JellyfinAccountStatus.expired,
    ));
  }

  /// A new media [r.mediaId]: the previous one leaves the player at once
  /// (nobody sees or hears it while the new one resolves, is fetched or
  /// opens), then plan → resolve → open. A Jellyfin item comes back to
  /// the coordinator ([SwitchJellyfin]).
  Future<SwitchResult> switchTo(StateBroadcast r) async {
    _mediaId = r.mediaId;
    _awaitLiveFor = -1;
    _recovery = null;
    final source = plan(r);
    if (feeder.mediaId != r.mediaId) feeder.stop();
    _jellyfinFeed = null;
    await leavePrevious(r.mediaId);
    final name = (r.media?['name'] as String?) ?? '';
    final queueId = stateMediaRelay(r)?.queueId ?? '';
    final duration = (r.media?['duration'] as num?)?.toDouble() ?? 0;
    if (source is! OwnLink) await shared.closeCurrent();
    switch (source) {
      case JellyfinSource():
        return SwitchJellyfin(source);
      case OwnFile(:final path):
        // The source first: viewers wait on it, not on this player.
        feeder.serve(r.mediaId, RelayMedia.single(FileRelayBytes(File(path))),
            announce: true, queueId: queueId, name: name, duration: duration);
        await open(path);
      case OwnLink(:final url, :final origin):
        // Read from the site once: the relay serves what the player reads
        // (pieces tracks keep the two fetches).
        RelayMedia link() => LinkRelayMedia(Uri.parse(url), ytDlp: origin.ytDlp, probe: origin.probe);
        final one = await shared.current(url, origin.probe, link, queueId: queueId);
        feeder.serve(r.mediaId, one?.upload ?? link(), announce: true, queueId: queueId, name: name, duration: duration);
        await open(url);
      case RelayedSource(:final url, :final waiting, :final fetch, :final sourceId):
        if (waiting) {
          // The server is still getting it (yt-dlp takes seconds), or the
          // member passing it on has not dialled in yet: mpv gives up on a
          // silent request after 5 s, so open once it is live.
          _openUrl = null;
          _awaitLiveFor = r.mediaId;
          final who = r.members.where((m) => m.id == sourceId).firstOrNull?.name;
          _log.info('media ${r.mediaId}: waiting for ${fetch ? 'the server' : who} before opening the relay');
        } else {
          await open(url);
        }
      case Unresolvable(:final reason):
        _openUrl = null;
        onError(reason);
      case ServerFile(:final url) || DirectLink(:final url):
        await open(url);
      case NoSource():
        _openUrl = null;
    }
    return const SwitchDone();
  }

  /// The previous media leaves the player at once; a reconnect to the
  /// media the player holds keeps it.
  Future<void> leavePrevious(int mediaId) async {
    final held = playerMediaId;
    playerMediaId = mediaId;
    // Opened from the welcome, before any state: that was this media.
    if (held == -1 && _openedFor == -1 && _openUrl != null) _openedFor = mediaId;
    if (held == -1 || held == mediaId) return;
    _openUrl = null;
    _openHeaders = null;
    await playback.stop();
    _trimLocal();
  }

  /// The same media came back as [r.mediaId] (a restarted server put back
  /// what played, `swap.restore`) and the player keeps it open: what this
  /// member passes on is served again (its file, its link, the Jellyfin
  /// item played with its own account: [ownJellyfin]).
  void resumeAs(StateBroadcast r, {({String url, Map<String, String> headers})? ownJellyfin}) {
    renumber(r.mediaId);
    settledMediaId.value = r.mediaId;
    final source = plan(r);
    final name = (r.media?['name'] as String?) ?? '';
    final queueId = stateMediaRelay(r)?.queueId ?? '';
    final duration = (r.media?['duration'] as num?)?.toDouble() ?? 0;
    switch (source) {
      case OwnFile(:final path):
        feeder.serve(r.mediaId, RelayMedia.single(FileRelayBytes(File(path))),
            queueId: queueId, name: name, duration: duration);
      case OwnLink(:final url, :final origin):
        feeder.serve(r.mediaId,
            shared.currentFor(url)?.upload ?? LinkRelayMedia(Uri.parse(url), ytDlp: origin.ytDlp, probe: origin.probe),
            queueId: queueId, name: name, duration: duration);
      case JellyfinSource(:final ref, :final origin):
        if (origin == null || ownJellyfin == null) return;
        final media = RelayMedia.single(HttpRelayBytes(Uri.parse(ownJellyfin.url), headers: ownJellyfin.headers));
        if (jellyfinRelayNeeded(r, ref, session.selfId())) {
          feeder.serve(r.mediaId, media, queueId: queueId, name: name, duration: duration);
        } else {
          _jellyfinFeed = (mediaId: r.mediaId, ref: ref, media: media, queueId: queueId, name: name, duration: duration);
        }
      default:
        break;
    }
  }

  /// The media was settled here (opened, failed, nothing to open).
  void settled(int mediaId) {
    if (_mediaId == mediaId) settledMediaId.value = mediaId;
  }

  /// Same media, a new state: a relay that became live opens, a relay
  /// opened while its source was away and never loaded opens again now
  /// that it is back (D6), a Jellyfin stream this member holds back starts
  /// once someone needs it.
  Future<void> onState(StateBroadcast r) async {
    final rec = _recovery;
    final relay = stateMediaRelay(r);
    final url = _openUrl;
    if (rec != null && rec.mediaId == r.mediaId && relay != null && relay.live && !relay.sourceGone &&
        url != null && !_opening && playback.durationSecs <= 0) {
      _recovery = null;
      _log.info('media ${r.mediaId}: the relay has its source again; opening it again (it never loaded)');
      _openUrl = null;
      _openedFor = -2; // a fresh player: the old one may be stuck in a broken open
      await open(url, headers: _openHeaders, resolve: _openResolve);
    }
    if (_awaitLiveFor == r.mediaId) {
      final source = plan(r);
      if (source is RelayedSource && !source.waiting) {
        _awaitLiveFor = -1;
        await open(source.url);
      }
    }
    final feed = _jellyfinFeed;
    if (feed != null && feed.mediaId == r.mediaId && jellyfinRelayNeeded(r, feed.ref, session.selfId())) {
      _jellyfinFeed = null;
      _log.info('media ${r.mediaId}: someone needs the Jellyfin item passed on, starting the relay');
      feeder.serve(r.mediaId, feed.media, queueId: feed.queueId, name: feed.name, duration: feed.duration);
    }
  }

  /// Sitting out: nothing open, nothing pulled. A relay this member serves
  /// goes on (it does not use the player).
  Future<void> unload() async {
    _awaitLiveFor = -1;
    if (_mediaId == -1 && _openUrl == null) return;
    _mediaId = -1;
    playerMediaId = -1;
    _openUrl = null;
    _openHeaders = null;
    _recovery = null;
    if (ready) await playback.stop();
    _trimLocal();
  }

  /// The next state's media is new to this player: it opens again from
  /// scratch (a relay this member served for the old one stops).
  void forget() {
    _mediaId = -1;
    playerMediaId = -1;
    _openUrl = null;
    _openHeaders = null;
    _awaitLiveFor = -1;
    _recovery = null;
    _activeOrigin = null;
    _jellyfinFeed = null;
    feeder.stopAll();
    unawaited(shared.closeAll());
  }

  /// The same media under a restarted server's numbering: the player keeps
  /// it.
  void renumber(int mediaId) => _mediaId = playerMediaId = _openedFor = mediaId;

  /// A new session (connect): nothing held, nothing served.
  void reset() {
    _mediaId = -1;
    playerMediaId = -1;
    _openedFor = -1;
    _openUrl = null;
    _openHeaders = null;
    _awaitLiveFor = -1;
    _recovery = null;
    _pendingOrigin = null;
    _activeOrigin = null;
    _jellyfinFeed = null;
    settledMediaId.value = -1;
    feeder.stopAll();
    unawaited(shared.closeAll());
  }

  // ----------------------------------------------------------- Jellyfin

  // A Jellyfin stream this member holds back: nobody present needs it
  // passed on yet.
  ({int mediaId, JellyfinRef ref, RelayMedia media, String queueId, String name, double duration})? _jellyfinFeed;

  /// The resolve step of a Jellyfin item: this app's account (or the
  /// [warm] plan resolved ahead), else the server's login, else the member
  /// passing it on, else blocked. This member's own item is passed on to
  /// viewers without an account once someone needs it. Then it opens.
  /// Null when [current] went false meanwhile.
  Future<JellyfinPlan?> openJellyfin(JellyfinSource source, StateBroadcast r,
      {OwnPlay? warm, required bool Function() current}) async {
    // Until it resolves nothing is open: no syncing the previous media.
    final prev = _openUrl;
    _openUrl = null;
    _opening = true;
    if (ready) {
      try {
        await playback.player.pause();
      } catch (_) {}
    }
    JellyfinPlan plan;
    try {
      plan = warm ??
          await resolveJellyfinRef(session.jellyfin, source.ref,
              relay: source.serverLogin != null, relayUrl: source.serverLogin, memberRelayUrl: source.memberRelay);
    } finally {
      if (current()) _opening = false;
    }
    if (!current()) return null;
    trace.mark(r.mediaId, SwitchTrace.resolved);
    final origin = source.origin;
    if (origin != null) {
      final name = (r.media?['name'] as String?) ?? '';
      final duration = (r.media?['duration'] as num?)?.toDouble() ?? 0;
      final queueId = stateMediaRelay(r)?.queueId ?? '';
      RelayMedia? media;
      if (plan is OwnPlay) {
        media = RelayMedia.single(HttpRelayBytes(Uri.parse(plan.url), headers: plan.headers));
      } else if (origin.link != null) {
        plan = RelayPlay(origin.link!);
        media = RelayMedia.single(HttpRelayBytes(Uri.parse(origin.link!)));
      }
      if (media != null) {
        if (jellyfinRelayNeeded(r, source.ref, session.selfId())) {
          feeder.serve(r.mediaId, media, queueId: queueId, name: name, duration: duration);
        } else {
          _jellyfinFeed =
              (mediaId: r.mediaId, ref: source.ref, media: media, queueId: queueId, name: name, duration: duration);
        }
      }
    }
    switch (plan) {
      case BlockedPlay():
        await playback.stop();
      case RelayPlay(:final url):
        // The same relay URL (a resumed member): the player still has it.
        if (url == prev) {
          _openUrl = url;
        } else if (!await open(url, resolve: false)) {
          return current() ? plan : null;
        }
      case OwnPlay(:final url, :final headers):
        if (!await open(url, headers: headers, resolve: false)) return current() ? plan : null;
    }
    return current() ? plan : null;
  }

  // ------------------------------------------------------ recovery (D6)

  // The relay this viewer reads lost its source and the buffer ran dry:
  // what it waits for.
  _Recovery? _recovery;

  /// This viewer reads the current media through a relay whose source is
  /// gone, or left: it plays what the server has.
  bool get sourceDown => _recovery != null;

  /// The player reads the current media through the server's relay (a
  /// `/r/` URL, or an EDL of its tracks).
  bool get readsRelay {
    final url = _openUrl;
    return url != null && (url.startsWith('edl://') || Uri.tryParse(url)?.pathSegments.firstOrNull == 'r');
  }

  /// The user sought to [to] (applied at once): while the source is down,
  /// that is the one try.
  void noteUserSeek(double to) {
    final rec = _recovery;
    if (rec == null) return;
    rec.tried = true;
    rec.tryTo = to;
  }

  /// While the source is down, this player cannot be where the server is
  /// ([serverPosition]): a seek waits, or the player is stuck short of it.
  /// The report then says nothing is buffered, so the server waits for the
  /// source instead of playing on without this viewer.
  bool starved(double serverPosition) {
    final rec = _recovery;
    if (rec == null) return false;
    return rec.seekTo != null || (playback.positionSecs - serverPosition).abs() > 3;
  }

  /// Seeks while the source is down, not applied (tests: never a loop).
  @visibleForTesting
  int heldBackSeeks = 0;

  /// The viewer's side of a source that drops (D6): while the relay this
  /// app reads has no source, it plays what is buffered. A seek past it
  /// (the server's buffer may still hold it) is tried once; any further
  /// one waits (mpv would wait on bytes nobody sends, time out after 5 s
  /// and be asked again: the seek loop), and the report says nothing is
  /// buffered ([starved]), so the server holds everyone with the reason
  /// `source` ("waiting for Bob"). When the source is back, one seek to
  /// where the server is resumes the player. Returns the [actions] to
  /// apply.
  List<PlayerAction> recover(StateBroadcast r, List<PlayerAction> actions, {required double serverPosition}) {
    final relay = stateMediaRelay(r);
    final down = relay != null &&
        readsRelay &&
        !relay.fetch &&
        relay.source != session.selfId() &&
        (relay.sourceGone || !relay.live);
    final rec = _recovery;
    if (down) {
      final at = playback.positionSecs;
      final reach = at + playback.bufferedSecsAhead;
      final now = _recovery ??= _Recovery(r.mediaId);
      if (rec == null) {
        _log.info('media ${r.mediaId}: the relay has no source; playing what is buffered '
            '(to ${reach.toStringAsFixed(1)} s)');
      }
      final out = <PlayerAction>[];
      for (final a in actions) {
        if (a is SeekAction && (a.position > reach + 0.5 || a.position < at - 30)) {
          final last = now.tryTo;
          if (!now.tried && (last == null || (a.position - last).abs() > 1.5)) {
            now.tried = true;
            now.tryTo = a.position;
            out.add(a);
            continue;
          }
          heldBackSeeks++;
          now.seekTo = a.position;
        } else {
          out.add(a);
        }
      }
      return out;
    }
    _recovery = null;
    if (rec == null || rec.mediaId != r.mediaId) return actions;
    final stuck = rec.seekTo != null ||
        (playback.positionSecs - serverPosition).abs() > 1.0 ||
        playback.bufferedSecsAhead < 1;
    _log.info('media ${r.mediaId}: the relay has its source again'
        '${stuck ? '; resuming at ${serverPosition.toStringAsFixed(1)} s' : ''}');
    if (!stuck) return actions;
    // One seek to where the server is: the demuxer reads from there again.
    return [
      for (final a in actions) if (a is! SeekAction) a,
      SeekAction(serverPosition),
    ];
  }

  // ------------------------------------------------------------ prepare

  /// Preparing on (env `SYNC_RELAY_PRELOAD=0` turns it off; tests set it).
  bool preloadEnabled = Platform.environment['SYNC_RELAY_PRELOAD'] != '0';

  _Prepared? _pre;

  /// The URL prepared now (null: none).
  String? get preloadUrl => _pre?.url;

  /// This viewer's URL of the warm relay of Up next's first [item]: the
  /// same URL the media has once the item goes up, so the prepared player
  /// is promoted.
  String warmRelayUrl(QueueItem item, MediaRelay relay) =>
      session.server().relayUrl(item.media.name.isEmpty ? item.title : item.media.name, item.id, relay.tracks);

  /// Feeds the warm relay of Up next item [queueId], the link [url] this
  /// member passes on, from one shared reader (pieces tracks: from their
  /// own fetch, as [LinkRelayMedia]). A preload of [url] that reads the
  /// site itself (it was prepared before the reader existed) is prepared
  /// again on the reader, so the item is fetched once.
  Future<void> feedWarmLink(String queueId, String url, LinkProbe probe, YtDlp ytDlp) async {
    if (feeder.feedsWarm(queueId)) return;
    RelayMedia link() => LinkRelayMedia(Uri.parse(url), ytDlp: ytDlp, probe: probe);
    final one = await shared.warm(queueId, url, probe, link);
    if (feeder.feedsWarm(queueId)) return;
    feeder.feedWarm(queueId, one?.upload ?? link());
    final pre = _pre;
    if (one != null && pre != null && pre.url == url && pre.headers.isEmpty && !pre.shared && !pre.failed) {
      _log.info('Up next ${logUrl(url)}: preparing it again on the shared reader');
      unawaited(prepare(url, fresh: true));
    }
  }

  /// Opens [url] early in a hidden player (paused at the start, muted, a
  /// small cache, its own video output when the view is up), replacing any
  /// other; completes once [need] seconds are buffered or the whole media
  /// is: true, false when it failed (or was dropped or replaced
  /// meanwhile). The same [url] and [headers] again is the same one unless
  /// [fresh]. [open] for the same URL promotes it.
  Future<bool> prepare(String url, {Map<String, String>? headers, double need = 4, bool fresh = false}) async {
    if (!preloadEnabled || !ready) return false;
    final had = _pre;
    if (had != null && had.matches(url, headers) && !had.failed && !fresh) return had.ready.future;
    // Set before any await: a second call for the same URL finds it.
    _pre = null;
    if (had != null) unawaited(_disposePrepared(had));
    final pre = _pre = _Prepared(url, headers ?? const {});
    _trimLocal();
    try {
      final target = await _resolve(url, headers, fresh: fresh);
      pre.shared = target.shared && !target.local;
      if (!identical(_pre, pre)) {
        pre.fail();
        return false;
      }
      final p = pre.player = await host.create(PlayerRole.preload);
      pre.logSub = p.logs.listen((log) {
        if (mpvLoadFailed(log, p.state.duration)) pre.fail();
      });
      pre.subtitles = target.subtitles;
      if (playback.hasVideo) {
        pre.video = host.video(p);
        await pre.video!.ready;
      }
      if (!identical(_pre, pre)) {
        pre.fail();
        await _disposePrepared(pre);
        return false;
      }
      await p.open(target.url, headers: target.headers);
      if (!pre.opened.isCompleted) pre.opened.complete();
    } catch (e) {
      debugPrint('preload failed: $e');
      pre.fail();
      if (identical(_pre, pre)) _pre = null;
      await _disposePrepared(pre);
      return false;
    }
    unawaited(_watchPrepared(pre, need));
    return pre.ready.future;
  }

  Future<void> _watchPrepared(_Prepared pre, double need) async {
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (identical(_pre, pre) && !pre.failed && DateTime.now().isBefore(end)) {
      final st = pre.player!.state;
      final secs = st.duration.inMilliseconds / 1000;
      final buffered = (st.buffer - st.position).inMilliseconds / 1000;
      if (secs > 0 && (buffered >= need || st.buffer.inMilliseconds / 1000 >= secs - 0.5)) {
        if (!pre.ready.isCompleted) pre.ready.complete(true);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!pre.ready.isCompleted) pre.ready.complete(false);
  }

  /// Drops the prepared player (nothing to get ready, or something else
  /// is).
  Future<void> dropPrepared() async {
    final pre = _pre;
    if (pre == null) return;
    _pre = null;
    await _disposePrepared(pre);
  }

  Future<void> _disposePrepared(_Prepared pre) async {
    pre.fail();
    await pre.logSub?.cancel();
    final p = pre.player;
    if (p != null) await host.dispose(p);
    if (!identical(_pre, pre)) _trimLocal();
  }

  /// [pre] becomes the session player; its buffer comes along.
  Future<bool> _promote(_Prepared pre) async {
    await pre.opened.future;
    final old = playback.current;
    if (!identical(_pre, pre) || old == null) return false;
    _pre = null;
    final p = pre.player;
    if (pre.failed || p == null) {
      unawaited(_disposePrepared(pre));
      return false;
    }
    await pre.logSub?.cancel();
    if (!pre.ready.isCompleted) pre.ready.complete(true);
    await host.promote(p);
    final prev = playback.attach(p, video: pre.video, loaded: true);
    _held = true;
    unawaited(_addSubtitles(p, pre.subtitles));
    if (prev != null) unawaited(host.retire(prev));
    return true;
  }

  Future<void> dispose() async {
    await release();
    feeder.stopAll();
    await shared.closeAll();
    await playback.dispose();
  }
}

class _Recovery {
  final int mediaId;

  /// The latest seek held back (where the server went meanwhile).
  double? seekTo;

  /// The one seek past the buffer was tried ([tryTo]: where to).
  bool tried = false;
  double? tryTo;
  _Recovery(this.mediaId);
}

class _Prepared {
  final String url;
  final Map<String, String> headers;
  HostedPlayer? player;
  HostedVideo? video;
  StreamSubscription<PlayerLogLine>? logSub;
  List<YtDlpSubtitle> subtitles = const [];

  /// It reads a shared reader's loopback URL, not the site.
  bool shared = false;

  /// Completes once the media is handed to mpv (or it failed).
  final opened = Completer<void>();
  bool failed = false;
  final ready = Completer<bool>();
  _Prepared(this.url, this.headers);

  bool matches(String url, Map<String, String>? headers) =>
      url == this.url && mapEquals(headers ?? const {}, this.headers);

  void fail() {
    failed = true;
    if (!ready.isCompleted) ready.complete(false);
    if (!opened.isCompleted) opened.complete();
  }
}

/// What a player opens for a link (the resolve step).
class _Target {
  final String url;
  final Map<String, String> headers;
  final List<YtDlpSubtitle> subtitles;

  /// A link this member passes on, read through its shared reader.
  final bool shared;

  /// Read through a [SharedLinks.local] reader (played here only).
  final bool local;
  const _Target(this.url, this.headers, {this.subtitles = const [], this.shared = false, this.local = false});
}

/// A page could not be resolved: why ([message], yt-dlp's words) and which
/// cookies that used ([cookies], D11).
class ResolveFailure implements Exception {
  final String message;
  final String? cookies;
  const ResolveFailure(this.message, {this.cookies});
  @override
  String toString() => message;
}
