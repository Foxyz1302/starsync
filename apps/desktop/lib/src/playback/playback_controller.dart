import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../jellyfin/track_prefs.dart' show MpvTrack;
import '../shaders/shader_assets.dart';
import '../shaders/shader_presets.dart';
import '../state/settings.dart';
import '../sync/state_diff.dart';
import '../sync/user_seek.dart';
import 'frame_watchdog.dart';
import 'media_marks.dart';

/// Owns one mpv [Player] (and its [VideoController]) per session: created
/// by [init] on join, released by [dispose] on leave, swapped by
/// [recreate] for "Reload video". Never reuse a player across sessions —
/// a GPU-side freeze sticks to the player, not to the widget.
class PlaybackController {
  /// Read-ahead target: about two minutes rides out short outages and
  /// makes skipping an intro instant.
  static const readAheadSecs = 150;
  /// Forward demuxer cache. Holds [readAheadSecs] up to ~14 Mbit/s (a
  /// 1.4 GB / 24 min file is ~8); higher bitrates get less time. In RAM:
  /// media_kit sets cache-on-disk but no cache-dir, so mpv falls back.
  static const maxBytes = 256 * 1024 * 1024;
  /// Back buffer (media_kit sets it to bufferSize too): enough for a short
  /// seek back without holding another 256 MiB.
  static const maxBackBytes = 64 * 1024 * 1024;

  SyncPlayer? _player;
  VideoController? _video;
  Timer? _watchTimer;
  bool _probing = false;
  final FrameWatchdog _watchdog = FrameWatchdog();
  StreamSubscription<PlayerLog>? _logSub;
  final List<StreamSubscription<Duration>> _timeSubs = [];
  String _chapterJson = '';
  // `glsl-shaders` as last set on the current player ('' = none).
  String _shaders = '';
  Future<void> _shaderOp = Future.value();
  int _noticeId = 0;

  /// Bumped for every new player; the video view keys itself on it so a
  /// recreated player gets a fresh `Video` widget.
  final generation = signal(0);

  /// True while a live player exists. The video view shows plain black
  /// otherwise, so no texture outlives its player.
  final alive = signal(false);

  /// Called once when the watchdog sees a frozen picture.
  void Function()? onFrozen;

  /// Fingerprint of the picture on screen, installed by the video view
  /// (`ShownFrameProbe.sample`). Without it the watchdog stays idle.
  Future<int?> Function()? shownFrame;

  Player get player => _player!;

  /// Seeks from the video controls (seek bar) go here instead of to mpv.
  void Function(Duration position)? onUserSeek;

  /// Latest shader message for the user (the session player toasts it).
  final shaderNotice = signal<ShaderNotice?>(null);

  /// How media_kit renders the current player's video (shaders need
  /// [RenderMode.gpu]); [lastRenderMode] keeps it after leaving.
  final renderMode = signal(RenderMode.unknown);
  static final lastRenderMode = signal(RenderMode.unknown);

  // ------------------------------------------------- media marks (signals)
  //
  // What the open file has, for any controls UI (the session's seek bar,
  // chapter / track menus and skip pills read these; nothing here knows
  // about widgets). Reset when the player goes away; [segments] is owned
  // by the coordinator (it survives Reload video, the item is the same).

  /// mpv `chapter-list`: title and start; end = next start, or the
  /// duration for the last one. Empty without chapters.
  final chapters = signal<List<MediaChapter>>(const []);

  /// Jellyfin MediaSegments of the current item (Intro / Outro / Recap /
  /// Preview / Commercial). Only viewers with their own account fetch
  /// them (relay viewers cannot call Jellyfin): empty otherwise.
  final segments = signal<List<MediaSegment>>(const []);

  /// Audio and subtitle tracks from mpv's `track-list` (id, language,
  /// title, codec, channels, default / forced flags, [MpvTrack.selected]).
  final tracks = signal<List<MpvTrack>>(const []);

  /// Playback position, in 250 ms steps (enough for pills and menus; a
  /// seek bar should listen to `player.stream.position`).
  final position = signal(Duration.zero);

  /// Duration of the open file (zero until known).
  final duration = signal(Duration.zero);

  /// End of the cached range ahead of the position (mpv
  /// `demuxer-cache-time`, media_kit's `buffer`), in 250 ms steps.
  final buffered = signal(Duration.zero);

  /// The opening ([openingRange]: Intro segment, else an OP-titled
  /// chapter) and the ending ([endingRange]: Outro, else ED-titled).
  late final Computed<SkipRange?> opening =
      computed(() => openingRange(segments.value, chapters.value));
  late final Computed<SkipRange?> ending =
      computed(() => endingRange(segments.value, chapters.value));

  /// Index into [chapters] of the chapter playing now.
  late final Computed<int?> currentChapter =
      computed(() => chapterIndexAt(chapters.value, position.value));

  /// Pinned mpv properties whose read-back differs from what was set
  /// (mpv ignores invalid values silently), as `name: wanted -> got`.
  final List<String> pinMismatches = [];
  bool get _ready => _player != null;

  /// The [VideoController] of the current player. Created lazily by the
  /// video view (it needs a running Flutter binding; headless tests never
  /// touch it) and released with the player.
  VideoController get video {
    final existing = _video;
    if (existing != null) return existing;
    final hwdec = _hwdecOverride;
    // media_kit's video output sets hwdec itself on attach ('auto' unless
    // configured), which used to override SYNC_RELAY_HWDEC.
    final video = _video = VideoController(
      player,
      configuration: VideoControllerConfiguration(hwdec: hwdec),
    );
    unawaited(_detectRenderMode(player, video));
    return video;
  }

  // SYNC_RELAY_HWDEC wins over the Settings choice; read per player, so a
  // changed setting applies on the next join or Reload video.
  static String? get _hwdecOverride {
    final hwdec = Platform.environment['SYNC_RELAY_HWDEC'];
    if (hwdec != null && hwdec.isNotEmpty) return hwdec;
    return AppSettings.instance.hwdec.peek();
  }

  Future<void> init() async {
    if (_player != null) return;
    _player = SyncPlayer(
        configuration: PlayerConfiguration(
      bufferSize: maxBytes,
      libass: true,
      vo: Platform.environment['SYNC_RELAY_VO'],
      // Verbose: the render-mode probe needs mpv's GL init lines.
      logLevel: MPVLogLevel.v,
    ))
      ..onUserSeek = (d) => onUserSeek?.call(d);
    _shaders = '';
    renderMode.value = RenderMode.unknown;
    shaderNotice.value = null;
    _logSub = _player!.stream.log.listen(_onLog);
    _watchMarks(_player!);
    await _pinBufferProps();
    await applyShaders();
    _watchdog.reset();
    _watchTimer = Timer.periodic(const Duration(seconds: 1), (_) => _watch());
    generation.value++;
    alive.value = true;
  }

  /// Dispose the current player and start a fresh one (no media loaded).
  /// Keeps volume. The caller reopens media and resyncs.
  Future<void> recreate() async {
    final volume = _player?.state.volume;
    await dispose();
    await init();
    if (volume != null) {
      try {
        await player.setVolume(volume);
      } catch (_) {}
    }
  }

  Future<void> _pin(String property, String value) async {
    try {
      final dynamic platform = player.platform;
      await platform?.setProperty(property, value);
      final got = '${await platform?.getProperty(property)}';
      if (!pinMatches(value, got)) {
        pinMismatches.add('$property: $value -> $got');
        debugPrint('pin $property=$value not applied, mpv has "$got"');
      }
    } catch (e, st) {
      pinMismatches.add('$property: $value -> error $e');
      debugPrint('pin $property=$value failed: $e\n$st');
    }
  }

  Future<void> _pinBufferProps() async {
    pinMismatches.clear();
    await _pin('demuxer-readahead-secs', '$readAheadSecs');
    await _pin('cache-secs', '$readAheadSecs');
    await _pin('demuxer-max-bytes', '$maxBytes');
    await _pin('demuxer-max-back-bytes', '$maxBackBytes');
    final hwdec = _hwdecOverride;
    if (hwdec != null) {
      await _pin('hwdec', hwdec);
    }
    await _pin('stream-lavf-o',
        'reconnect_streamed=1,reconnect_on_http_error=1,reconnect_delay_max=4');
  }

  /// Puts the saved shader choice (Settings, Ctrl+0..6, shader button) on
  /// the current player, live. A missing file or a value mpv won't take
  /// turns shaders off and says why in [shaderNotice]; [announce] also
  /// reports success ("Shaders: Mode A (HQ)").
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
      paths = await shaderPathsFor(
          preset, s.shaderQuality.peek(), s.customShaders.peek());
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
    final value = joinShaderPaths(paths);
    if (value != _shaders || problem != null) {
      final got = await setShaderValue(value);
      if (!identical(p, _player)) return;
      if (problem == null && got != value) {
        problem = 'mpv did not take them';
        await setShaderValue('');
      }
    }
    if (problem != null) {
      _turnShadersOff('$label failed: $problem — turned off');
    } else if (announce) {
      _notice('Shaders: $label${_softwareHint(paths)}');
    }
  }

  /// Sets mpv `glsl-shaders` on the current player and returns the
  /// read-back (null on error).
  @visibleForTesting
  Future<String?> setShaderValue(String value) async {
    try {
      final dynamic platform = player.platform;
      await platform?.setProperty('glsl-shaders', value);
      final got = '${await platform?.getProperty('glsl-shaders')}';
      _shaders = got;
      if (got != value) debugPrint('glsl-shaders=$value not applied: "$got"');
      return got;
    } catch (e, st) {
      debugPrint('glsl-shaders=$value failed: $e\n$st');
      return null;
    }
  }

  void _turnShadersOff(String message) {
    AppSettings.instance.setShaderPreset(ShaderPreset.off);
    _notice(message);
  }

  void _notice(String text) {
    shaderNotice.value = ShaderNotice(++_noticeId, text);
  }

  String _softwareHint(List<String> paths) => paths.isEmpty
      ? ''
      : switch (renderMode.peek()) {
          RenderMode.software => ' (no effect: video uses software rendering)',
          RenderMode.softwareGl => ' (likely slow: OpenGL runs on the CPU)',
          _ => '',
        };

  // mpv logs from the render context: GL init lines mean GPU rendering;
  // an error there while shaders are on is a shader that failed to load
  // or compile (mpv then renders without it).
  void _onLog(PlayerLog log) {
    if (log.prefix != 'libmpv_render') return;
    if (log.text.contains('suspected software renderer')) {
      _setRenderMode(RenderMode.softwareGl);
    } else if (log.text.startsWith('GL_VERSION') &&
        renderMode.peek() == RenderMode.unknown) {
      _setRenderMode(RenderMode.gpu);
    } else if ((log.level == 'error' || log.level == 'fatal') &&
        _shaders.isNotEmpty) {
      debugPrint('shader error: ${log.text}');
      final p = _player;
      _shaders = '';
      _shaderOp = _shaderOp.then((_) async {
        if (!identical(p, _player)) return;
        await setShaderValue('');
        _turnShadersOff('Shaders failed in mpv (${log.text}) — turned off');
      });
    }
  }

  void _setRenderMode(RenderMode mode) {
    renderMode.value = mode;
    lastRenderMode.value = mode;
  }

  // media_kit's Linux/Windows video output creates mpv's render context
  // while the controller is created: OpenGL when it can, else the
  // software renderer, which never logs GL init (and ignores shaders).
  Future<void> _detectRenderMode(Player p, VideoController video) async {
    try {
      await video.platform.future;
    } catch (_) {
      return;
    }
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!identical(p, _player) || renderMode.peek() != RenderMode.unknown) {
      return;
    }
    _setRenderMode(RenderMode.software);
    debugPrint('video output: software rendering (no GL init logged)');
    if (_shaders.isNotEmpty) {
      _notice('Shaders have no effect: video uses software rendering');
    }
  }

  /// Fingerprint of the decoder's current frame (mpv `screenshot-raw`,
  /// off-thread); null without video.
  Future<int?> _sourceFrame(Player p) async {
    try {
      final raw = await p.screenshot(format: null);
      return raw == null || raw.isEmpty ? null : hashSpread(raw);
    } catch (_) {
      return null;
    }
  }

  /// A suspected freeze is real only if mpv's own frames still move: a
  /// still scene looks frozen on screen too.
  Future<bool> _sourceMoving(Player p) async {
    final a = await _sourceFrame(p);
    await Future.delayed(const Duration(milliseconds: 500));
    if (!identical(p, _player) || !p.state.playing) return false;
    final b = await _sourceFrame(p);
    return a != null && b != null && a != b;
  }

  static bool get _windowVisible {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == null ||
          s == AppLifecycleState.resumed ||
          s == AppLifecycleState.inactive;
    } catch (_) {
      return false;
    }
  }

  Future<void> _watch() async {
    final p = _player;
    final probe = shownFrame;
    // Only meaningful once the video view is up.
    if (p == null || _video == null || probe == null || _probing) return;
    _probing = true;
    try {
      final frames = await probe();
      if (!identical(p, _player)) return;
      final s = p.state;
      final eligible = s.playing &&
          !s.buffering &&
          !s.completed &&
          s.rate > 0 &&
          (s.width ?? 0) > 0 &&
          _windowVisible;
      final fired = _watchdog.feed(FrameSample(
        at: DateTime.now(),
        position: positionSecs,
        frames: frames,
        eligible: eligible,
      ));
      if (fired) {
        if (await _sourceMoving(p) && identical(p, _player)) {
          debugPrint('video watchdog: picture stuck while mpv frames move');
          onFrozen?.call();
        } else {
          _watchdog.dismiss();
        }
      }
    } finally {
      _probing = false;
    }
  }

  /// Opens [url] paused. [headers] go with every request for it (mpv
  /// `http-header-fields`): a Jellyfin token travels there, not in the URL.
  Future<void> openUrl(String url, {Map<String, String>? headers}) async {
    if (!_ready) return;
    try {
      _chapterJson = '';
      chapters.value = const [];
      tracks.value = const [];
      buffered.value = Duration.zero;
      // An empty map, not null: media_kit caches headers per URI.
      await player.open(Media(url, httpHeaders: headers ?? const {}), play: false);
    } catch (e, st) {
      debugPrint('open ${Uri.tryParse(url)?.replace(query: '') ?? 'media'} failed: $e\n$st');
      rethrow;
    }
  }

  // Position / duration from media_kit's streams; chapter-list and
  // track-list observed in mpv (read back as JSON).
  void _watchMarks(SyncPlayer p) {
    _timeSubs.add(p.stream.position.listen((d) {
      final ms = d.inMilliseconds;
      position.value = Duration(milliseconds: ms - ms % 250);
    }));
    _timeSubs.add(p.stream.buffer.listen((d) {
      final ms = d.inMilliseconds;
      buffered.value = Duration(milliseconds: ms - ms % 250);
    }));
    _timeSubs.add(p.stream.duration.listen((d) {
      duration.value = d;
      // The last chapter ends at the duration.
      if (_chapterJson.isNotEmpty) chapters.value = parseChapterList(_chapterJson, d);
    }));
    () async {
      try {
        final dynamic platform = p.platform;
        await platform?.observeProperty('chapter-list', (String v) async {
          if (!identical(p, _player)) return;
          _chapterJson = v;
          chapters.value = parseChapterList(v, duration.peek());
        });
        await platform?.observeProperty('track-list', (String v) async {
          if (!identical(p, _player)) return;
          _setTracks(parseTrackList(v));
        });
      } catch (e) {
        debugPrint('observe chapters / tracks failed: $e');
      }
    }();
  }

  void _setTracks(List<MpvTrack> list) {
    if (!listEquals(tracks.peek(), list)) tracks.value = list;
  }

  /// Reads `track-list` now (after a selection: [tracks] then shows it at
  /// once instead of on mpv's next change notice).
  Future<void> _refreshTracks() async {
    final p = _player;
    if (p == null) return;
    try {
      final dynamic platform = p.platform;
      final v = '${await platform?.getProperty('track-list')}';
      if (identical(p, _player)) _setTracks(parseTrackList(v));
    } catch (_) {}
  }

  void _clearMarks() {
    _chapterJson = '';
    chapters.value = const [];
    tracks.value = const [];
    position.value = Duration.zero;
    duration.value = Duration.zero;
    buffered.value = Duration.zero;
  }

  /// Waits (bounded) until the open file's tracks are listed and mpv has
  /// selected its audio track, so a report or a carried-over choice sees
  /// the real selection.
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
      final dynamic platform = p.platform;
      final aid = int.tryParse('${await platform?.getProperty('current-tracks/audio/id')}');
      final sid = int.tryParse('${await platform?.getProperty('current-tracks/sub/id')}');
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
      final dynamic platform = p.platform;
      if (aid != null) await platform?.setProperty('aid', '$aid');
      if (subtitlesOff) {
        await platform?.setProperty('sid', 'no');
      } else if (sid != null) {
        await platform?.setProperty('sid', '$sid');
      }
    } catch (e) {
      debugPrint('select tracks failed: $e');
    }
    await _refreshTracks();
  }

  double get positionSecs {
    final p = _player;
    if (p == null) return 0;
    return p.state.position.inMilliseconds / 1000.0;
  }

  double get bufferedSecsAhead {
    final p = _player;
    if (p == null) return 0;
    final ahead = (p.state.buffer - p.state.position).inMilliseconds / 1000.0;
    if (ahead.isNaN || ahead < 0) return 0;
    return ahead;
  }

  double get durationSecs {
    final p = _player;
    if (p == null) return 0;
    return p.state.duration.inMilliseconds / 1000.0;
  }

  Future<void> apply(List<PlayerAction> actions) async {
    if (!_ready) return;
    for (final action in actions) {
      try {
        switch (action) {
          case SeekAction(:final position):
            if ((positionSecs - position).abs() < 0.5) break;
            await _player!
                .syncSeek(Duration(milliseconds: (position * 1000).round()));
          case TransportAction(:final playing):
            if (playing) {
              await player.play();
            } else {
              await player.pause();
            }
          case RateAction(:final rate):
            await player.setRate(rate);
        }
      } catch (e, st) {
        debugPrint('player action $action failed: $e\n$st');
      }
    }
  }

  /// Release the player. The view drops its texture first ([alive] goes
  /// false, one frame passes), then mpv is torn down.
  Future<void> dispose() async {
    final p = _player;
    if (p == null) return;
    _watchTimer?.cancel();
    _watchTimer = null;
    await _logSub?.cancel();
    _logSub = null;
    for (final sub in _timeSubs) {
      await sub.cancel();
    }
    _timeSubs.clear();
    _player = null;
    _video = null;
    alive.value = false;
    _clearMarks();
    await _settleUi();
    try {
      await p.dispose();
    } catch (_) {}
  }

  // Two frames: one may already be mid-build when [alive] flips. Then
  // the length of a route pop (the fullscreen route holds its own `Video`
  // and leaves animated). Bounded, since a hidden window renders no
  // frames; headless tests have no binding and skip it all.
  static Future<void> _settleUi() async {
    try {
      for (var i = 0; i < 2; i++) {
        await WidgetsBinding.instance.endOfFrame
            .timeout(const Duration(milliseconds: 300));
      }
      await Future.delayed(const Duration(milliseconds: 350));
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!_ready) return;
    try {
      await player.stop();
    } catch (e, st) {
      debugPrint('player stop failed: $e\n$st');
    }
  }
}

enum RenderMode {
  unknown,
  /// OpenGL on a real GPU: shaders work.
  gpu,
  /// OpenGL on a software rasterizer (llvmpipe): shaders crawl.
  softwareGl,
  /// media_kit's software fallback: shaders are ignored.
  software,
}

class ShaderNotice {
  final int id;
  final String text;
  const ShaderNotice(this.id, this.text);
}

/// mpv echoes numbers in its own format (`150` reads back `150.000000`).
bool pinMatches(String wanted, String got) {
  if (wanted == got) return true;
  final a = double.tryParse(wanted), b = double.tryParse(got);
  return a != null && b != null && a == b;
}
