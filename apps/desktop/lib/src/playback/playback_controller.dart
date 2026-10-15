import 'dart:async';
import 'dart:ffi' show Int8;
import 'dart:io';

import 'package:ffi/ffi.dart' show StringUtf8Pointer, malloc;
import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType, LogThrottle, createLogger;

import '../jellyfin/track_prefs.dart' show MpvTrack;
import '../shaders/shader_assets.dart';
import '../shaders/shader_presets.dart';
import '../state/settings.dart';
import '../sync/state_diff.dart';
import '../sync/user_seek.dart';
import 'media_marks.dart';
import 'yt_dlp_app.dart' show AppYtDlp, ytdlFormat;

/// Owns the session's mpv [Player] (and its [VideoController]): created
/// by [init] on join, released by [dispose] on leave, swapped by
/// [recreate] for "Reload video" and by [openUrl] for every new media (a
/// promoted preload or a fresh player). Never reuse a player for other
/// media — a GPU-side freeze sticks to the player, not to the widget.
class PlaybackController {
  /// Read-ahead target: about two minutes rides out short outages and
  /// makes skipping an intro instant.
  static const readAheadSecs = 150;
  /// Forward demuxer cache. Holds [readAheadSecs] up to ~14 Mbit/s (a
  /// 1.4 GB / 24 min file is ~8); higher bitrates get less time. In RAM:
  /// `cache-on-disk=no` (media_kit sets it on but no cache-dir, so mpv
  /// fell back to RAM anyway, warning "Failed to create file cache." per
  /// open).
  static const maxBytes = 256 * 1024 * 1024;
  /// Back buffer (media_kit sets it to bufferSize too): enough for a short
  /// seek back without holding another 256 MiB.
  static const maxBackBytes = 64 * 1024 * 1024;
  /// mpv's `volume-max` (its default is 130): the volume controls go
  /// this far, past 100 % amplified.
  static const maxVolume = 150;

  SyncPlayer? _player;
  VideoController? _video;
  StreamSubscription<PlayerLog>? _logSub;
  final List<StreamSubscription<Object?>> _timeSubs = [];
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

  /// mpv's yt-dlp hook could not open the current link (its error text).
  void Function(String error)? onYtdlError;

  /// The current media failed to load (the HTTP error when there was one,
  /// e.g. a CDN's 403), at most once per [openUrl].
  void Function(String error)? onLoadError;

  // Per opened media: the last HTTP error ffmpeg logged, and whether a
  // load error was reported.
  String? _httpError;
  bool _loadErrorSent = false;

  /// mpv's log level for this app. media_kit drains mpv's log on the UI
  /// thread one line at a time, so a chatty level (ffmpeg retrying a
  /// refused request logs every attempt) can starve the UI: warnings and
  /// errors only, except while the video output starts ([video]), when
  /// the render-mode probe needs mpv's verbose GL init lines.
  static const logLevel = 'warn';

  /// Points mpv's yt-dlp hook at [path] (the app's managed copy) for web
  /// page links, at most 1080p, once per player; its cookies
  /// (`ytdl-raw-options`) whenever they changed.
  Future<void> useYtDlp(String path) async {
    final p = _player;
    if (p == null) return;
    try {
      _ytdlPath = path;
      final dynamic platform = p.platform;
      if (!identical(p, _ytdlSetOn)) {
        await platform?.setProperty('script-opts', 'ytdl_hook-ytdl_path=$path');
        await platform?.setProperty('ytdl-format', ytdlFormat);
        _ytdlSetOn = p;
        _ytdlRaw = '';
      }
      final raw = await AppYtDlp.instance.mpvRawOptions();
      if (raw != _ytdlRaw && identical(p, _player)) {
        await platform?.setProperty('ytdl-raw-options', raw);
        _ytdlRaw = raw;
      }
    } catch (e) {
      debugPrint('yt-dlp path not set: $e');
    }
  }

  Player? _ytdlSetOn;
  String _ytdlRaw = '';
  String? _ytdlPath;

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

  /// The player's volume, 0..[maxVolume] (media_kit's `volume`).
  final volume = signal(100.0);

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
    _logRenderEnv();
    _requestLog(player, 'v'); // back to [logLevel] by _detectRenderMode
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

  SyncPlayer _newPlayer({required int bufferSize, required MPVLogLevel logLevel}) => SyncPlayer(
          configuration: PlayerConfiguration(
        bufferSize: bufferSize,
        libass: true,
        vo: Platform.environment['SYNC_RELAY_VO'],
        logLevel: logLevel,
      ))
        ..onUserSeek = (d) => onUserSeek?.call(d);

  Future<void> init() async {
    if (_player != null) return;
    _player = _newPlayer(bufferSize: maxBytes, logLevel: MPVLogLevel.warn); // see [logLevel]
    _held = false;
    _shaders = '';
    renderMode.value = RenderMode.unknown;
    shaderNotice.value = null;
    _logSub = _player!.stream.log.listen(_onLog);
    _watchMarks(_player!);
    await _pinBufferProps();
    await _pin('volume-max', '$maxVolume');
    await applyShaders();
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

  Future<void> _pin(String property, String value, [Player? on]) async {
    try {
      final dynamic platform = (on ?? player).platform;
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

  Future<void> _pinBufferProps([Player? on, int ahead = maxBytes, int back = maxBackBytes]) async {
    if (on == null) pinMismatches.clear();
    await _pin('demuxer-readahead-secs', '$readAheadSecs', on);
    await _pin('cache-secs', '$readAheadSecs', on);
    await _pin('demuxer-max-bytes', '$ahead', on);
    await _pin('demuxer-max-back-bytes', '$back', on);
    await _pin('cache-on-disk', 'no', on);
    final hwdec = _hwdecOverride;
    if (hwdec != null) {
      await _pin('hwdec', hwdec, on);
    }
    await _pin('stream-lavf-o', streamLavfOptions, on);
  }

  /// ffmpeg's HTTP options (mpv `stream-lavf-o`, comma form): reconnect
  /// after a dropped connection, also on a streamed (growing) relay
  /// response, and a server error (5xx) while connecting; a refused request
  /// (4xx) fails at once. At most 3 tries per read, 4 s apart at most.
  static const streamLavfOptions = 'reconnect_streamed=1,reconnect_on_http_error=5xx,'
      'reconnect_delay_max=4,reconnect_max_retries=3';

  // mpv_request_log_messages on [p]'s handle (media_kit has no API for it).
  static void _requestLog(Player p, String level) {
    try {
      final dynamic platform = p.platform;
      final name = level.toNativeUtf8();
      try {
        platform.mpv.mpv_request_log_messages(platform.ctx, name.cast<Int8>());
      } finally {
        malloc.free(name);
      }
    } catch (e) {
      debugPrint('mpv log level $level not set: $e');
    }
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
    final value = joinShaderPaths(paths);
    try {
      final dynamic platform = player.platform;
      await platform?.setProperty('glsl-shaders', value);
      final got = '${await platform?.getProperty('glsl-shaders')}';
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
    _toAppLog(log);
    if (log.prefix == 'ytdl_hook' && (log.level == 'error' || log.level == 'fatal')) {
      final text = log.text.trim().replaceFirst(RegExp(r'^ERROR:\s*'), '');
      if (text.isNotEmpty) {
        _loadErrorSent = true;
        onYtdlError?.call(text);
      }
      return;
    }
    // ffmpeg logs through one mpv instance per process (the first one
    // alive), so the HTTP status is a bonus, not a given.
    if (log.prefix == 'ffmpeg') {
      final http = RegExp(r'HTTP error \d{3}.*').firstMatch(log.text);
      if (http != null) _httpError = http[0]!.trim();
      return;
    }
    // Nothing playable opened (a track of mpv's yt-dlp EDL refused, ...).
    if (!_loadErrorSent && _loadFailed(log, duration.peek())) {
      _loadErrorSent = true;
      final http = _httpError;
      _mpvLog.warning('cannot open the media: [${log.prefix}] ${log.text.trim()}'
          '${http == null ? ' (no HTTP error logged; a request that timed out after 5 s looks like this)' : ' ($http)'}');
      onLoadError?.call(http == null ? 'the video stream could not be opened' : 'the video server answered $http');
      return;
    }
    if (log.prefix != 'libmpv_render') return;
    // Which GL the video output got (verbose, heard only during the
    // render-mode probe): kept in the app log.
    if (_glInfo.hasMatch(log.text)) _mpvLog.info('render: [libmpv_render] ${log.text.trim()}');
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
        await setShaderPaths(const []);
        _turnShadersOff('Shaders failed in mpv (${log.text}) — turned off');
      });
    }
  }

  // mpv's warnings and errors (the session player's; ffmpeg's through
  // whichever player logs them) go to the app log, a few per kind at a
  // time: a refused request makes ffmpeg retry and warn on every try.
  static final _mpvLog = createLogger('mpv');
  static final _mpvThrottle = LogThrottle(burst: 5);

  // mpv's GL init lines (`GL_VENDOR='...'`, `Detected desktop OpenGL 4.6.`).
  static final _glInfo =
      RegExp(r'^\s*(GL_(VENDOR|RENDERER|VERSION|SHADING_LANGUAGE_VERSION)=|Detected (GLES|desktop OpenGL))');

  // Once per app start: what decides how media_kit and mpv render (the
  // display server, Flutter's and Mesa's overrides). Not secrets.
  static bool _renderEnvLogged = false;
  static void _logRenderEnv() {
    if (_renderEnvLogged || !Platform.isLinux) return;
    _renderEnvLogged = true;
    const names = [
      'XDG_SESSION_TYPE',
      'WAYLAND_DISPLAY',
      'DISPLAY',
      'GDK_BACKEND',
      'FLUTTER_LINUX_RENDERER',
      'LIBGL_ALWAYS_SOFTWARE',
      '__EGL_VENDOR_LIBRARY_FILENAMES',
    ];
    final env = Platform.environment;
    _mpvLog.info('render env: ${[for (final n in names) '$n=${env[n] ?? '-'}'].join(' ')}');
  }

  // Once per player, after its first frame: the decoder mpv picked; the
  // first time per app start also mpv's and ffmpeg's versions.
  static bool _versionsLogged = false;
  Player? _frameLoggedFor;
  Future<void> _logFirstFrame(Player p, int? width) async {
    if (width == null || width <= 0 || identical(p, _frameLoggedFor)) return;
    _frameLoggedFor = p;
    try {
      final dynamic platform = p.platform;
      final current = await platform?.getProperty('hwdec-current');
      final wanted = await platform?.getProperty('hwdec');
      _mpvLog.info('render: first frame ${p.state.width}x${p.state.height}, '
          'hwdec-current=${'$current'.isEmpty ? 'no' : current} (hwdec=$wanted), mode ${renderMode.peek().name}');
      if (!_versionsLogged) {
        _versionsLogged = true;
        _mpvLog.info('render: ${await platform?.getProperty('mpv-version')}, '
            'ffmpeg ${await platform?.getProperty('ffmpeg-version')}');
      }
    } catch (e) {
      debugPrint('first frame info: $e');
    }
  }

  static void _toAppLog(PlayerLog log, {String player = ''}) {
    final level = log.level;
    if (level != 'warn' && level != 'error' && level != 'fatal') return;
    final text = log.text.trim();
    if (text.isEmpty) return;
    final pass = _mpvThrottle.allow('$player${log.prefix} $level ${text.length > 40 ? text.substring(0, 40) : text}');
    if (pass == null) return;
    final line = '$pass$player[${log.prefix}] $text';
    level == 'warn' ? _mpvLog.info(line) : _mpvLog.warning(line);
  }

  /// [log] says the media could not be opened: before a [duration] is
  /// known, mpv's fatal "nothing to play" or a demuxer error, or a yt-dlp
  /// hook error.
  static bool _loadFailed(PlayerLog log, Duration duration) {
    if (log.prefix == 'ytdl_hook') return log.level == 'error' || log.level == 'fatal';
    return duration == Duration.zero &&
        ((log.prefix == 'cplayer' && log.level == 'fatal') || (log.prefix == 'demux' && log.level == 'error'));
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
      await Future.delayed(const Duration(milliseconds: 1500));
    } catch (_) {
      return;
    } finally {
      if (identical(p, _player)) _requestLog(p, logLevel);
    }
    if (!identical(p, _player)) return;
    final mode = renderMode.peek();
    if (mode != RenderMode.unknown) {
      _mpvLog.info('render: ${mode.name} (${mode == RenderMode.gpu ? 'OpenGL on the GPU' : 'OpenGL on the CPU'})');
      return;
    }
    _setRenderMode(RenderMode.software);
    _mpvLog.info("render: software (no GL init logged: media_kit's own fallback; "
        'its reason is on stderr, "media_kit: VideoOutput: ..." when run from a terminal)');
    if (_shaders.isNotEmpty) {
      _notice('Shaders have no effect: video uses software rendering');
    }
  }

  /// `mpv-version` and `ffmpeg-version` of the session player, for
  /// diagnostics; null when there is no player.
  Future<String?> mpvVersion() async {
    final p = _player;
    if (p == null) return null;
    try {
      final dynamic platform = p.platform;
      return '${await platform?.getProperty('mpv-version')}, ffmpeg ${await platform?.getProperty('ffmpeg-version')}';
    } catch (_) {
      return null;
    }
  }

  /// Opens [url] paused. [headers] go with every request for it (mpv
  /// `http-header-fields`): a Jellyfin token travels there, not in the URL.
  /// Each media gets its own player: when [preload] holds the same [url]
  /// and [headers], that player becomes this one (true: promoted, its
  /// buffer comes along); else a player that already held media is
  /// replaced by a fresh one first ([onFreshPlayer] once it is up), unless
  /// [keepPlayer] (the same media again, e.g. after a reconnect).
  Future<bool> openUrl(String url,
      {Map<String, String>? headers, bool keepPlayer = false, void Function()? onFreshPlayer}) async {
    if (!_ready) return false;
    final pre = _pre;
    if (pre != null && pre.matches(url, headers)) {
      if (await _promote(pre)) return true;
    }
    if (_held && !keepPlayer && await _freshPlayer()) onFreshPlayer?.call();
    if (!_ready) return false;
    try {
      _held = true;
      _chapterJson = '';
      _httpError = null;
      _loadErrorSent = false;
      chapters.value = const [];
      tracks.value = const [];
      buffered.value = Duration.zero;
      // An empty map, not null: media_kit caches headers per URI.
      await player.open(Media(url, httpHeaders: headers ?? const {}), play: false);
      return false;
    } catch (e, st) {
      debugPrint('open ${Uri.tryParse(url)?.replace(query: '') ?? 'media'} failed: $e\n$st');
      rethrow;
    }
  }

  // Position, duration and volume from media_kit's streams; chapter-list and
  // track-list observed in mpv (read back as JSON).
  void _watchMarks(SyncPlayer p) {
    volume.value = p.state.volume;
    _timeSubs.add(p.stream.volume.listen((v) => volume.value = v));
    _timeSubs.add(p.stream.position.listen((d) {
      // At the end the bar shows full: mpv's last position is the last
      // frame's start (and the 250 ms steps round down), short of duration.
      if (p.state.completed && duration.value > Duration.zero) {
        position.value = duration.value;
        return;
      }
      final ms = d.inMilliseconds;
      position.value = Duration(milliseconds: ms - ms % 250);
    }));
    _timeSubs.add(p.stream.completed.listen((done) {
      if (done && duration.value > Duration.zero) position.value = duration.value;
    }));
    _timeSubs.add(p.stream.width.listen((w) => _logFirstFrame(p, w)));
    unawaited(_logFirstFrame(p, p.state.width)); // a promoted preload has one already
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
    await dropPreload();
    final p = _player;
    if (p == null) return;
    await _logSub?.cancel();
    _logSub = null;
    for (final sub in _timeSubs) {
      await sub.cancel();
    }
    _timeSubs.clear();
    _player = null;
    _video = null;
    _held = false;
    alive.value = false;
    _clearMarks();
    await _settleUi();
    try {
      await p.dispose();
    } catch (_) {}
  }

  /// App close: every mpv this controller holds goes before the engine
  /// does (a live one calls back into a dead isolate): the preload, the
  /// session player and the one still retiring, each bounded by [each].
  /// A player an open in flight brought up meanwhile goes too.
  Future<void> disposeAll({Duration each = const Duration(milliseconds: 1500)}) async {
    Future<void> bounded(Future<void> f) => f.timeout(each).catchError((Object _) {});
    for (var round = 0; round < 2; round++) {
      final pre = _pre;
      _pre = null;
      await Future.wait([
        if (pre != null) bounded(_disposePreload(pre)),
        bounded(_retiring),
        bounded(dispose()),
      ]);
      if (_player == null && _pre == null) return;
    }
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

  // ------------------------------------------------------------ preload
  //
  // A second, hidden player holding what plays next (Up next's first
  // item), open paused at its start and muted, with a small cache: its
  // first seconds are in before anyone asks. [openUrl] for the same URL
  // promotes it to the session player (see ARCHITECTURE.md "Getting
  // ready"). One at a time.

  /// Preloading on (env `SYNC_RELAY_PRELOAD=0` turns it off; tests set it).
  bool preloadEnabled = Platform.environment['SYNC_RELAY_PRELOAD'] != '0';

  /// The preload's forward cache: its first seconds and the container's
  /// index, at little memory. Raised to [maxBytes] when promoted.
  static const preloadBytes = 48 * 1024 * 1024;
  static const _preloadBackBytes = 8 * 1024 * 1024;

  _Preload? _pre;

  /// The URL preloaded now (null: none).
  String? get preloadUrl => _pre?.url;

  /// Opens [url] in the hidden preload player (replacing any other), and
  /// completes once [need] seconds are buffered or the whole media is:
  /// true, false when it failed (or was dropped or replaced meanwhile).
  /// The same [url] and [headers] again is the same preload unless
  /// [fresh]. [ytdlPath]: mpv's yt-dlp hook for web pages.
  Future<bool> preload(String url,
      {Map<String, String>? headers, String? ytdlPath, double need = 4, bool fresh = false}) async {
    if (!preloadEnabled || !_ready) return false;
    final had = _pre;
    if (had != null && had.matches(url, headers) && !had.failed && !fresh) return had.ready.future;
    // Set before any await: a second call for the same URL finds it.
    _pre = null;
    if (had != null) unawaited(_disposePreload(had));
    final p = _newPlayer(bufferSize: preloadBytes, logLevel: MPVLogLevel.error);
    final pre = _pre = _Preload(p, url, headers ?? const {});
    pre.logSub = p.stream.log.listen((log) {
      // ffmpeg logs through one mpv per process: the first one, and once
      // that is gone (a promotion disposes it) the next one created, which
      // can be this preload. Its HTTP errors still name the session's.
      if (log.prefix == 'ffmpeg') return _onLog(log);
      _toAppLog(log, player: 'preload ');
      if (_loadFailed(log, p.state.duration)) pre.fail();
    });
    try {
      await _pinBufferProps(p, preloadBytes, _preloadBackBytes);
      await _pin('volume-max', '$maxVolume', p);
      await _pin('mute', 'yes', p);
      final path = ytdlPath ?? _ytdlPath;
      if (path != null) {
        pre.ytdlRaw = await _setYtdl(p, path);
        pre.ytdl = true;
      }
      // With a view up, its own video output: mpv decodes (media_kit
      // starts players with vid=no) and the first frame is there.
      if (_video != null) {
        pre.video = VideoController(p, configuration: VideoControllerConfiguration(hwdec: _hwdecOverride));
        await pre.video!.platform.future;
      }
      if (!identical(_pre, pre)) {
        pre.fail();
        return false;
      }
      await p.open(Media(url, httpHeaders: headers ?? const {}), play: false);
      if (!pre.opened.isCompleted) pre.opened.complete();
    } catch (e) {
      debugPrint('preload failed: $e');
      pre.fail();
      return false;
    }
    unawaited(_watchPreload(pre, need));
    return pre.ready.future;
  }

  Future<void> _watchPreload(_Preload pre, double need) async {
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (identical(_pre, pre) && !pre.failed && DateTime.now().isBefore(end)) {
      final st = pre.player.state;
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

  /// Drops the preload (nothing to get ready, or something else is).
  Future<void> dropPreload() async {
    final pre = _pre;
    if (pre == null) return;
    _pre = null;
    await _disposePreload(pre);
  }

  Future<void> _disposePreload(_Preload pre) async {
    pre.fail();
    await pre.logSub?.cancel();
    try {
      await pre.player.dispose();
    } catch (_) {}
  }

  /// [pre] becomes the session player ([_adopt]); the full cache pins
  /// replace its small ones.
  Future<bool> _promote(_Preload pre) async {
    await pre.opened.future;
    final old = _player;
    if (!identical(_pre, pre) || old == null) return false;
    _pre = null;
    if (pre.failed) {
      unawaited(_disposePreload(pre));
      return false;
    }
    await pre.logSub?.cancel();
    if (!pre.ready.isCompleted) pre.ready.complete(true);
    final p = pre.player;
    await _adopt(p, pre.video, ytdl: pre.ytdl, ytdlRaw: pre.ytdlRaw);
    try {
      await _pin('mute', 'no', p);
      await _pinBufferProps(p);
    } catch (e) {
      debugPrint('promoted player settings: $e');
    }
    return true;
  }

  // The current player has had media opened in it (one fresh from [init]
  // has not, so the first open after join or Reload video uses it).
  bool _held = false;

  // The last replaced player until it is disposed: a fresh player waits
  // for it, so at most one old player lingers.
  Future<void> _retiring = Future.value();

  /// Replaces the current player with a fresh one set up like [init]'s
  /// (pins, hwdec, volume, yt-dlp hook, shaders, observers), its video
  /// output ready before the view swaps to it when the view is up. True
  /// once it is the session player.
  Future<bool> _freshPlayer() async {
    await _retiring;
    final old = _player;
    if (old == null) return false;
    final p = _newPlayer(bufferSize: maxBytes, logLevel: MPVLogLevel.warn); // see [logLevel]
    VideoController? video;
    var ytdl = false, ytdlRaw = '';
    try {
      pinMismatches.clear();
      await _pinBufferProps(p);
      await _pin('volume-max', '$maxVolume', p);
      final path = _ytdlPath;
      if (path != null) {
        ytdlRaw = await _setYtdl(p, path);
        ytdl = true;
      }
      // The view is up: the new output is created (and its texture
      // registered) before the view swaps, so the old picture stays until
      // then. Created by the view instead while the render mode is not
      // known yet, so the probe hears its GL init ([video]).
      if (_video != null && renderMode.peek() != RenderMode.unknown) {
        video = VideoController(p, configuration: VideoControllerConfiguration(hwdec: _hwdecOverride));
        await video.platform.future;
      }
    } catch (e) {
      debugPrint('fresh player setup: $e');
    }
    // Disposed or reloaded meanwhile: that player stays.
    if (!identical(old, _player)) {
      try {
        await p.dispose();
      } catch (_) {}
      return false;
    }
    await _adopt(p, video, ytdl: ytdl, ytdlRaw: ytdlRaw);
    return true;
  }

  /// mpv's yt-dlp hook on [p] (see [useYtDlp]); returns the raw options set.
  static Future<String> _setYtdl(Player p, String path) async {
    final dynamic platform = p.platform;
    await platform?.setProperty('script-opts', 'ytdl_hook-ytdl_path=$path');
    await platform?.setProperty('ytdl-format', ytdlFormat);
    final raw = await AppYtDlp.instance.mpvRawOptions();
    await platform?.setProperty('ytdl-raw-options', raw);
    return raw;
  }

  /// [p] becomes the session player (a promoted preload or a fresh
  /// player): log, marks and track observers move over, the view swaps to
  /// its video output ([generation]), volume and shaders carry over, and
  /// the old player is paused and disposed once the view let go of its
  /// texture (as in [dispose]).
  Future<void> _adopt(SyncPlayer p, VideoController? video, {required bool ytdl, String ytdlRaw = ''}) async {
    final old = _player!;
    final volume = old.state.volume;
    await _logSub?.cancel();
    for (final sub in _timeSubs) {
      await sub.cancel();
    }
    _timeSubs.clear();
    _player = p;
    _video = video;
    _held = true;
    _ytdlSetOn = ytdl ? p : null;
    _ytdlRaw = ytdlRaw;
    _chapterJson = '';
    _httpError = null;
    _loadErrorSent = false;
    _shaders = '';
    final at = p.state.position.inMilliseconds;
    position.value = Duration(milliseconds: at - at % 250);
    duration.value = p.state.duration;
    final ms = p.state.buffer.inMilliseconds;
    buffered.value = Duration(milliseconds: ms - ms % 250);
    chapters.value = const [];
    tracks.value = const [];
    _logSub = p.stream.log.listen(_onLog);
    _requestLog(p, logLevel);
    _watchMarks(p);
    generation.value++;
    // Normally stopped already (the coordinator leaves the previous
    // media first): never two sounds at once.
    unawaited(old.pause().catchError((_) {}));
    try {
      await p.setVolume(volume);
    } catch (e) {
      debugPrint('new player volume: $e');
    }
    unawaited(applyShaders());
    unawaited(_refreshTracks());
    _retiring = () async {
      await _settleUi();
      try {
        await old.dispose();
      } catch (_) {}
    }();
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

class _Preload {
  final SyncPlayer player;
  final String url;
  final Map<String, String> headers;
  VideoController? video;
  StreamSubscription<PlayerLog>? logSub;
  /// Completes once the media is handed to mpv (or the preload failed).
  final opened = Completer<void>();
  bool ytdl = false;
  String ytdlRaw = '';
  bool failed = false;
  final ready = Completer<bool>();
  _Preload(this.player, this.url, this.headers);

  bool matches(String url, Map<String, String>? headers) =>
      url == this.url && mapEquals(headers ?? const {}, this.headers);

  void fail() {
    failed = true;
    if (!ready.isCompleted) ready.complete(false);
    if (!opened.isCompleted) opened.complete();
  }
}
