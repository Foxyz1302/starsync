import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, listEquals, visibleForTesting;
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType, createLogger;

import '../jellyfin/track_prefs.dart' show MpvTrack;
import '../platform/ports/player_host.dart';
import '../shaders/shader_assets.dart';
import '../shaders/shader_presets.dart';
import '../state/settings.dart';
import '../sync/live_follow.dart' show growsLikeLive;
import '../sync/state_diff.dart';
import 'live_window.dart';
import 'media_marks.dart';

export '../platform/ports/player_host.dart' show RenderMode, HostedPlayer, HostedVideo;

final _log = createLogger('mpv');

/// The session player as everyone else sees it: whichever player the media
/// pipeline made current ([attach]), its marks as signals (position,
/// chapters, tracks, ...), the commands sent to it and the shaders on it.
/// It never creates or disposes a player (the pipeline does, through the
/// [PlayerHost]). Commands that come while a switch is under way (no
/// player, or its media not loaded yet) wait and go to the new player once
/// ([apply]): a seek into a player still opening is what made mpv log
/// "error running command seek".
class PlaybackController {
  final PlayerHost host;
  PlaybackController(this.host) {
    _httpSub = host.httpErrors.listen((e) => _httpError = e);
    // The probe found software rendering while shaders are on: say so.
    _renderSub = host.renderMode.subscribe((mode) {
      if (mode == RenderMode.software && _shaders.isNotEmpty) {
        _notice('Shaders have no effect: video uses software rendering');
      }
    });
  }

  /// mpv's `volume-max`: the volume controls go this far.
  static const maxVolume = 150;

  HostedPlayer? _player;
  HostedVideo? _video;
  StreamSubscription<PlayerLogLine>? _logSub;
  StreamSubscription<String>? _httpSub;
  void Function()? _renderSub;
  final List<StreamSubscription<Object?>> _timeSubs = [];
  String _chapterJson = '';
  // `glsl-shaders` as last set on the current player ('' = none).
  String _shaders = '';
  Future<void> _shaderOp = Future.value();
  int _noticeId = 0;

  /// Bumped for every new player; the video view keys itself on it so a
  /// new player gets a fresh `Video` widget.
  final generation = signal(0);

  /// True while a live player is attached. The video view shows plain
  /// black otherwise, so no texture outlives its player.
  final alive = signal(false);

  /// The current media failed to load (the HTTP error when there was one,
  /// e.g. a CDN's 403), at most once per [beginOpen].
  void Function(String error)? onLoadError;

  /// The current media's HTTP stream lost its size (see [mpvStreamLost]):
  /// at most once per player and media; the coordinator opens it again.
  void Function()? onStreamLost;

  /// The player stopped at the end of the file at `at`, more than
  /// [finishSlackSecs] short of its duration: a read that failed (a relay
  /// whose source sent nothing for longer than ffmpeg's reconnects) taken
  /// for the end. The coordinator reopens a relay viewer.
  void Function(Duration at)? onEndedShort;

  /// Seeks from the controls (seek bar, the video widget's own) go here
  /// instead of to mpv.
  void Function(Duration position)? onUserSeek;

  // Per opened media: the last HTTP error ffmpeg logged, and whether a
  // load error was reported.
  String? _httpError;
  bool _loadErrorSent = false;
  bool _streamLostSent = false;

  /// The current player. Only while [alive].
  HostedPlayer get player => _player!;

  /// The current player, null between sessions.
  HostedPlayer? get current => _player;

  /// Latest shader message for the user (the session player toasts it).
  final shaderNotice = signal<ShaderNotice?>(null);

  /// How video renders (the host's last probe; shaders need gpu).
  ReadonlySignal<RenderMode> get renderMode => host.renderMode;

  // ------------------------------------------------- media marks (signals)
  //
  // What the open file has, for any controls UI. Reset when the player goes
  // away; [segments] is owned by the coordinator (it survives Reload video,
  // the item is the same).

  /// mpv `chapter-list`: title and start; end = next start, or the
  /// duration for the last one. Empty without chapters.
  final chapters = signal<List<MediaChapter>>(const []);

  /// Jellyfin MediaSegments of the current item. Only viewers with their
  /// own account fetch them: empty otherwise.
  final segments = signal<List<MediaSegment>>(const []);

  /// Audio and subtitle tracks from mpv's `track-list`.
  final tracks = signal<List<MpvTrack>>(const []);

  /// Playback position, in 250 ms steps.
  final position = signal(Duration.zero);

  /// Duration of the open file (zero until known).
  final duration = signal(Duration.zero);

  /// End of the cached range ahead of the position, in 250 ms steps.
  final buffered = signal(Duration.zero);

  /// What mpv's cache holds (`demuxer-cache-state`), ends in 250 ms steps;
  /// the timelines draw it.
  final cached = signal(CachedRanges.none);

  /// The player's volume, 0..[maxVolume]; kept across players.
  final volume = signal(100.0);

  /// The open media's length keeps growing like a live stream's
  /// ([growsLikeLive]): this player found it live.
  final growing = signal(false);
  final List<double> _lengths = [];
  double? _streamStart;

  /// How far back the open live stream lets this player rewind; a new
  /// media starts it over, [reopenLive] keeps it.
  LiveWindow liveWindow = LiveWindow();

  late final Computed<SkipRange?> opening = computed(() => openingRange(segments.value, chapters.value));
  late final Computed<SkipRange?> ending = computed(() => endingRange(segments.value, chapters.value));

  /// Index into [chapters] of the chapter playing now.
  late final Computed<int?> currentChapter = computed(() => chapterIndexAt(chapters.value, position.value));

  /// The [HostedVideo] of the current player. Created by the video view
  /// when the pipeline did not make one ahead (it needs a running Flutter
  /// binding; headless tests never touch it). The first one of an app
  /// start probes the render mode.
  HostedVideo get video =>
      _video ??= host.video(player, probe: host.renderMode.peek() == RenderMode.unknown);

  /// The current player has a video output (the view is up).
  bool get hasVideo => _video != null;

  // ------------------------------------------------------------- attach

  /// [p] becomes the session player (the first one, a fresh one per media,
  /// a promoted preload, Reload video's): log, marks and track observers
  /// move over, the view swaps to [video] ([generation]), volume and
  /// shaders carry over. Returns the previous player for the pipeline to
  /// retire. [loaded]: [p] already holds its media (a promoted preload).
  HostedPlayer? attach(HostedPlayer p, {HostedVideo? video, bool loaded = false}) {
    final old = _player;
    _unwatch();
    _player = p;
    _video = video;
    _chapterJson = '';
    _httpError = null;
    _loadErrorSent = false;
    _streamLostSent = false;
    _shaders = '';
    _resetLive();
    _loaded = loaded && p.state.duration > Duration.zero;
    _opened = loaded;
    p.onUserSeek = (d) => onUserSeek?.call(d);
    final st = p.state;
    position.value = _step(st.position);
    duration.value = st.duration;
    buffered.value = _step(st.buffer);
    cached.value = CachedRanges.none;
    chapters.value = const [];
    tracks.value = const [];
    _logSub = p.logs.listen(_onLog);
    _watchMarks(p);
    generation.value++;
    alive.value = true;
    unawaited(p.setVolume(volume.peek()).catchError((Object e) => debugPrint('new player volume: $e')));
    unawaited(applyShaders());
    unawaited(_refreshTracks());
    if (_loaded) unawaited(_flush());
    return old;
  }

  /// The player leaves (leave, Reload video): the view drops its texture
  /// ([alive] false) and the marks clear. Returns it for the pipeline to
  /// dispose.
  HostedPlayer? detach() {
    final p = _player;
    _unwatch();
    _player = null;
    _video = null;
    _loaded = false;
    _pending.clear();
    alive.value = false;
    _clearMarks();
    return p;
  }

  void _unwatch() {
    unawaited(_logSub?.cancel());
    _logSub = null;
    for (final sub in _timeSubs) {
      unawaited(sub.cancel());
    }
    _timeSubs.clear();
  }

  /// A media is about to be opened in the current player: its marks and
  /// errors start over, and commands wait until it is loaded.
  void beginOpen() {
    _opened = true;
    _chapterJson = '';
    _httpError = null;
    _loadErrorSent = false;
    _streamLostSent = false;
    _loaded = false;
    _resetLive();
    chapters.value = const [];
    tracks.value = const [];
    buffered.value = Duration.zero;
    cached.value = CachedRanges.none;
  }

  void _resetLive() {
    _lengths.clear();
    _streamStart = null;
    growing.value = false;
    liveWindow = LiveWindow();
  }

  /// Opens the live stream again in the same player, [segments] behind its
  /// edge ([liveStartOption]): mpv seeks a live stream only inside its
  /// cache, so a rewind past it opens it again there. The URL mpv has
  /// (no new resolve), its [liveWindow] kept; later opens go back to
  /// [liveOpenSegments]. False when there is nothing to open again.
  Future<bool> reopenLive(int segments) async {
    final p = _player;
    final o = p?.opened;
    if (p == null || o == null || p.disposed) return false;
    final window = liveWindow;
    final wasGrowing = growing.peek();
    await p.setProperty('demuxer-lavf-o', liveStartOption(segments));
    // Stopped first: none of the old open's position or length events
    // can count as the new one loaded (its start would be the old one's).
    await p.stop();
    if (!identical(p, _player)) return false;
    beginOpen();
    liveWindow = window;
    growing.value = wasGrowing;
    await p.open(o.url, headers: o.headers, play: true);
    // Back to the usual once this open read its start.
    unawaited(() async {
      for (var i = 0; i < 300 && identical(p, _player) && !p.disposed; i++) {
        if (_loaded) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!p.disposed) await p.setProperty('demuxer-lavf-o', liveStartOption(liveOpenSegments));
    }().catchError((Object e) => debugPrint('live reopen option: $e')));
    return true;
  }

  /// The stream time of the player's 0 (mpv `demuxer-start-time`, read once
  /// per open): a live stream's position in its own time is `time-pos`
  /// plus this, the same for every viewer. 0 until the media is in.
  Future<double> streamStart() async {
    final known = _streamStart;
    if (known != null) return known;
    final p = _player;
    if (p == null || !_loaded) return 0;
    try {
      final v = double.tryParse(await p.getProperty('demuxer-start-time'));
      if (v != null && v.isFinite && identical(p, _player) && _loaded) return _streamStart = v;
    } catch (_) {}
    return 0;
  }

  /// [streamStart] once read for this open, else null.
  double? get knownStreamStart => _streamStart;

  /// The player stopped at the end of what it had (a live stream: the
  /// stream ended, or the player lost it).
  bool get completed => _player?.state.completed ?? false;

  static Duration _step(Duration d) {
    final ms = d.inMilliseconds;
    return Duration(milliseconds: ms - ms % 250);
  }

  /// [p] stopped at the end of the file, not short of it (see
  /// [onEndedShort]).
  bool _atEnd(HostedPlayer p) {
    final d = duration.peek();
    return p.state.completed &&
        d > Duration.zero &&
        (d - p.state.position).inMilliseconds <= finishSlackSecs * 1000;
  }

  // Position, duration and volume from the player's streams; chapter-list
  // and track-list observed in mpv (read back as JSON).
  void _watchMarks(HostedPlayer p) {
    _timeSubs.add(p.volumeStream.listen((v) {
      if (identical(p, _player)) volume.value = v;
    }));
    _timeSubs.add(p.positionStream.listen((d) {
      // At the end the bar shows full: mpv's last position is the last
      // frame's start (and the 250 ms steps round down), short of duration.
      if (_atEnd(p)) {
        position.value = duration.value;
        return;
      }
      position.value = _step(d);
      // Media without a known length (a live link) counts as loaded once
      // it plays.
      if (d > Duration.zero && !_loaded && _opened && identical(p, _player)) {
        _loaded = true;
        unawaited(_flush());
      }
    }));
    _timeSubs.add(p.completedStream.listen((done) {
      if (!done || duration.peek() <= Duration.zero) return;
      if (_atEnd(p)) {
        position.value = duration.peek();
      } else if (identical(p, _player)) {
        onEndedShort?.call(p.state.position);
      }
    }));
    _timeSubs.add(p.bufferStream.listen((d) => buffered.value = _step(d)));
    _timeSubs.add(p.durationStream.listen((d) {
      duration.value = d;
      if (identical(p, _player) && d > Duration.zero && !growing.peek() && _lengths.length < 64) {
        _lengths.add(d.inMicroseconds / 1e6);
        if (growsLikeLive(_lengths)) growing.value = true;
      }
      // The last chapter ends at the duration.
      if (_chapterJson.isNotEmpty) chapters.value = parseChapterList(_chapterJson, d);
      if (d > Duration.zero && !_loaded && identical(p, _player)) {
        _loaded = true;
        unawaited(_flush());
      }
    }));
    () async {
      try {
        await p.observeProperty('chapter-list', (String v) async {
          if (!identical(p, _player)) return;
          _chapterJson = v;
          chapters.value = parseChapterList(v, duration.peek());
        });
        await p.observeProperty('track-list', (String v) async {
          if (!identical(p, _player)) return;
          _setTracks(parseTrackList(v));
        });
        await p.observeProperty('demuxer-cache-state', (String v) async {
          if (!identical(p, _player)) return;
          final c = parseCacheState(v);
          if (c != cached.peek()) cached.value = c;
        });
      } catch (e) {
        debugPrint('observe chapters / tracks / cache failed: $e');
      }
    }();
  }

  void _setTracks(List<MpvTrack> list) {
    if (!listEquals(tracks.peek(), list)) tracks.value = list;
  }

  Future<void> _refreshTracks() async {
    final p = _player;
    if (p == null) return;
    try {
      final v = await p.getProperty('track-list');
      if (identical(p, _player)) _setTracks(parseTrackList(v));
    } catch (_) {}
  }

  void _clearMarks() {
    _resetLive();
    _chapterJson = '';
    chapters.value = const [];
    tracks.value = const [];
    position.value = Duration.zero;
    duration.value = Duration.zero;
    buffered.value = Duration.zero;
    cached.value = CachedRanges.none;
  }

  // -------------------------------------------------------------- log

  // The current player's log: load failures become player errors; a render
  // error while shaders are on is a shader that failed to load or compile
  // (mpv then renders without it).
  void _onLog(PlayerLogLine log) {
    if (log.prefix == 'ffmpeg') {
      if (!_streamLostSent && mpvStreamLost(log)) {
        _streamLostSent = true;
        _log.warning('the media stream lost its size, every seek fails: [ffmpeg] ${log.text.trim()}');
        onStreamLost?.call();
      }
      return;
    }
    if (!_loadErrorSent && mpvLoadFailed(log, duration.peek())) {
      _loadErrorSent = true;
      final http = _httpError;
      _log.warning('cannot open the media: [${log.prefix}] ${log.text.trim()}'
          '${http == null ? ' (no HTTP error logged; a request that timed out after 5 s looks like this)' : ' ($http)'}');
      onLoadError?.call(http == null ? 'the video stream could not be opened' : 'the video server answered $http');
      return;
    }
    if (log.prefix == 'libmpv_render' && log.isError && _shaders.isNotEmpty) {
      debugPrint('shader error: ${log.text}');
      final p = _player;
      _shaders = '';
      _shaderOp = _shaderOp.then((_) async {
        if (!identical(p, _player)) return;
        await setShaderPaths(const []);
        _turnShadersOff('Shaders failed in mpv (${log.text}) — turned off');
      });
    }
  }

  // ---------------------------------------------------------- shaders

  /// Puts the saved shader choice on the current player, live. A missing
  /// file or a value mpv won't take turns shaders off and says why in
  /// [shaderNotice]; [announce] also reports success.
  Future<void> applyShaders({bool announce = false}) =>
      _shaderOp = _shaderOp.then((_) => _applyShaders(announce));

  Future<void> _applyShaders(bool announce) async {
    final p = _player;
    if (p == null) return;
    final s = AppSettings.instance;
    final preset = s.shaderPreset.peek();
    final label = shaderLabel(preset, s.shaderQuality.peek());
    String? problem;
    var paths = const <String>[];
    try {
      paths = await shaderPathsFor(preset, s.shaderQuality.peek(), s.customShaders.peek());
      if (preset == ShaderPreset.custom && paths.isEmpty) {
        problem = 'no custom shader files picked';
      } else {
        problem = shaderPathsProblem(paths);
      }
    } catch (e) {
      problem = 'could not unpack the shaders ($e)';
    }
    if (!identical(p, _player)) return;
    if (problem != null) paths = const [];
    if (joinShaderPaths(paths) != _shaders || problem != null) {
      final took = await setShaderPaths(paths);
      if (!identical(p, _player)) return;
      if (problem == null && !took) {
        problem = 'mpv did not take them';
        await setShaderPaths(const []);
      }
    }
    if (problem != null) {
      _turnShadersOff('$label failed: $problem — turned off');
    } else if (announce) {
      _notice('Shaders: $label${_softwareHint(paths)}');
    }
  }

  /// Sets mpv `glsl-shaders` to [paths] on the current player; true when
  /// mpv's read-back is that list ([shaderListMatches]: old mpv prints it
  /// joined with ',').
  @visibleForTesting
  Future<bool> setShaderPaths(List<String> paths) async {
    final p = _player;
    if (p == null) return false;
    final value = joinShaderPaths(paths);
    try {
      await p.setProperty('glsl-shaders', value);
      final got = await p.getProperty('glsl-shaders');
      final took = shaderListMatches(paths, got);
      _shaders = took ? value : got;
      if (!took) debugPrint('glsl-shaders=$value not applied: "$got"');
      return took;
    } catch (e, st) {
      debugPrint('glsl-shaders=$value failed: $e\n$st');
      return false;
    }
  }

  void _turnShadersOff(String message) {
    AppSettings.instance.setShaderPreset(ShaderPreset.off);
    _notice(message);
  }

  void _notice(String text) => shaderNotice.value = ShaderNotice(++_noticeId, text);

  String _softwareHint(List<String> paths) => paths.isEmpty
      ? ''
      : switch (renderMode.peek()) {
          RenderMode.software => ' (no effect: video uses software rendering)',
          RenderMode.softwareGl => ' (likely slow: OpenGL runs on the CPU)',
          _ => '',
        };

  /// `mpv-version` and `ffmpeg-version` of the session player.
  Future<String?> mpvVersion() async {
    final p = _player;
    return p == null ? null : host.versions(p);
  }

  // ------------------------------------------------------------ tracks

  /// Waits (bounded) until the open file's tracks are listed and mpv has
  /// selected its audio track.
  Future<List<MpvTrack>> waitForTracks({Duration timeout = const Duration(seconds: 5)}) async {
    final end = DateTime.now().add(timeout);
    while (_player != null && DateTime.now().isBefore(end)) {
      final t = tracks.peek();
      final hasAudio = t.any((x) => x.type == JellyfinStreamType.audio);
      if (t.isNotEmpty && (!hasAudio || (await currentTrackIds()).aid != null)) return t;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return tracks.peek();
  }

  /// mpv's selected audio and subtitle track ids (null = none / off).
  Future<({int? aid, int? sid})> currentTrackIds() async {
    final p = _player;
    if (p == null) return (aid: null, sid: null);
    try {
      final aid = int.tryParse(await p.getProperty('current-tracks/audio/id'));
      final sid = int.tryParse(await p.getProperty('current-tracks/sub/id'));
      return (aid: aid, sid: sid);
    } catch (_) {
      return (aid: null, sid: null);
    }
  }

  /// Selects tracks by mpv id; a null [aid] keeps audio, [subtitlesOff]
  /// turns subtitles off, else a null [sid] keeps them.
  Future<void> selectTracks({int? aid, int? sid, bool subtitlesOff = false}) async {
    final p = _player;
    if (p == null) return;
    try {
      if (aid != null) await p.setProperty('aid', '$aid');
      if (subtitlesOff) {
        await p.setProperty('sid', 'no');
      } else if (sid != null) {
        await p.setProperty('sid', '$sid');
      }
    } catch (e) {
      debugPrint('select tracks failed: $e');
    }
    await _refreshTracks();
  }

  // ---------------------------------------------------------- position

  double get positionSecs {
    final p = _player;
    if (p == null) return 0;
    return p.state.position.inMilliseconds / 1000.0;
  }

  double get bufferedSecsAhead {
    final p = _player;
    if (p == null) return 0;
    final st = p.state;
    final ahead = (st.buffer - st.position).inMilliseconds / 1000.0;
    if (ahead.isNaN || ahead < 0) return 0;
    return ahead;
  }

  double get durationSecs {
    final p = _player;
    if (p == null) return 0;
    return p.state.duration.inMilliseconds / 1000.0;
  }

  /// The player is playing (not paused, not waiting for a switch).
  bool get playing => _player?.state.playing ?? false;

  // ---------------------------------------------------------- commands

  // The current player holds its media (a duration is known since
  // [beginOpen]); until then commands wait in [_pending].
  bool _loaded = false;
  // An open was started on the current player since it was attached.
  bool _opened = false;
  final _pending = <PlayerAction>[];

  /// Commands applied to mpv, per kind (tests: a switch applies queued
  /// ones once).
  @visibleForTesting
  int seeksSent = 0;

  /// A switch is under way: no player, or its media is not loaded yet.
  bool get switching => _player == null || !_loaded;

  /// Applies [actions] (from the sync diff, a user seek, the play gate):
  /// at once to a loaded player, else queued for the new one, where the
  /// latest seek, transport and rate apply once it is loaded.
  Future<void> apply(List<PlayerAction> actions) async {
    if (switching) {
      for (final a in actions) {
        _pending
          ..removeWhere((p) => p.runtimeType == a.runtimeType)
          ..add(a);
      }
      return;
    }
    await _run(actions);
  }

  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    final list = [..._pending];
    _pending.clear();
    await _run(list);
  }

  Future<void> _run(List<PlayerAction> actions) async {
    final p = _player;
    if (p == null) return;
    for (final action in actions) {
      try {
        switch (action) {
          case SeekAction(:final position):
            if ((positionSecs - position).abs() < 0.5) break;
            seeksSent++;
            await p.syncSeek(Duration(milliseconds: (position * 1000).round()));
          case TransportAction(:final playing):
            playing ? await p.play() : await p.pause();
          case RateAction(:final rate):
            await p.setRate(rate);
        }
      } catch (e, st) {
        debugPrint('player action $action failed: $e\n$st');
      }
    }
  }

  /// The controls' volume: on the player now, and on every next one.
  Future<void> setVolume(double v) async {
    final clamped = v.clamp(0.0, maxVolume * 1.0);
    volume.value = clamped;
    final p = _player;
    if (p != null) await p.setVolume(clamped);
  }

  /// A seek from the controls (seek bar, keys): the sync layer's user
  /// seek ([onUserSeek]).
  void userSeek(Duration to) => onUserSeek?.call(to);

  /// Stops what plays (the player stays for the next media).
  Future<void> stop() async {
    final p = _player;
    if (p == null) return;
    _pending.clear();
    _loaded = false;
    try {
      await p.stop();
    } catch (e) {
      debugPrint('player stop failed: $e');
    }
  }

  Future<void> dispose() async {
    _unwatch();
    _renderSub?.call();
    await _httpSub?.cancel();
  }
}

class ShaderNotice {
  final int id;
  final String text;
  const ShaderNotice(this.id, this.text);
}
