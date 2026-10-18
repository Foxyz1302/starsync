import 'dart:async';
import 'dart:ffi' show Int8;
import 'dart:io';

import 'package:ffi/ffi.dart' show StringUtf8Pointer, malloc;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:signals/signals.dart';
import 'package:sync_relay_core/core.dart' show LogThrottle, createLogger;

import '../../state/settings.dart';
import '../ports/player_host.dart';

// The desktop's players: media_kit over libmpv. Everything mpv-specific
// that is not about one media lives here: the cache and HTTP pins, hwdec,
// mpv's log level (media_kit has no API for it: `mpv_request_log_messages`
// on its handle), the render-mode probe and its diagnostics, mpv's log into
// the app log, and the order players are torn down in.

/// Read-ahead target: about two minutes rides out short outages and makes
/// skipping an intro instant.
const readAheadSecs = 150;

/// Forward demuxer cache of a session player. Holds [readAheadSecs] up to
/// ~14 Mbit/s (a 1.4 GB / 24 min file is ~8); higher bitrates get less
/// time. In RAM: `cache-on-disk=no` (media_kit sets it on without a
/// cache-dir, and mpv warned "Failed to create file cache." per open).
const sessionAheadBytes = 256 * 1024 * 1024;

/// Back buffer (media_kit sets it to bufferSize too): enough for a short
/// seek back without holding another 256 MiB.
const sessionBackBytes = 64 * 1024 * 1024;

/// The preload's forward cache: its first seconds and the container's
/// index, at little memory. Raised to [sessionAheadBytes] when promoted.
const preloadAheadBytes = 48 * 1024 * 1024;
const preloadBackBytes = 8 * 1024 * 1024;

/// mpv's `volume-max` (its default is 130): the volume controls go this
/// far, past 100 % amplified.
const mpvMaxVolume = 150;

/// mpv's log level for session players. media_kit drains mpv's log on the
/// UI thread one line at a time, so a chatty level (ffmpeg retrying a
/// refused request logs every attempt) can starve the UI: warnings and
/// errors only, except during the render-mode probe, which needs mpv's
/// verbose GL init lines.
const sessionLogLevel = 'warn';

/// ffmpeg's HTTP options (mpv `stream-lavf-o`, comma form): reconnect after
/// a dropped connection, also on a streamed (growing) relay response, and a
/// server error (5xx) while connecting; a refused request (4xx) fails at
/// once. At most 3 tries per read, 4 s apart at most.
const streamLavfOptions = 'reconnect_streamed=1,reconnect_on_http_error=5xx,'
    'reconnect_delay_max=4,reconnect_max_retries=3';

/// mpv echoes numbers in its own format (`150` reads back `150.000000`).
bool pinMatches(String wanted, String got) {
  if (wanted == got) return true;
  final a = double.tryParse(wanted), b = double.tryParse(got);
  return a != null && b != null && a == b;
}

/// The `VideoController` behind [video], for the `Video` widget (the only
/// media_kit use outside this file).
VideoController videoControllerOf(HostedVideo video) => (video as _MkVideo).controller;

final _mpvLog = createLogger('mpv');

class MediaKitHost implements PlayerHost {
  /// The hwdec setting ([AppSettings.hwdec] by default).
  final String? Function() _hwdecSetting;
  MediaKitHost({String? Function()? hwdecSetting})
      : _hwdecSetting = hwdecSetting ?? (() => AppSettings.instance.hwdec.peek());

  final _live = <_MkPlayer>{};
  final _videos = <_MkVideo>{};
  // The size outputs render at ([setOutputSize]); null: the video's own.
  (int, int)? _outputSize;
  final _renderMode = signal(RenderMode.unknown);
  final _http = StreamController<String>.broadcast();
  final _throttle = LogThrottle(burst: 5);
  Future<void> _retiring = Future.value();
  var _closing = false;

  @override
  final List<String> pinMismatches = [];

  @override
  void init() => MediaKit.ensureInitialized();

  @override
  ReadonlySignal<RenderMode> get renderMode => _renderMode;

  @override
  void setOutputSize(int? width, int? height) {
    final size = width != null && height != null && width > 0 && height > 0 ? (width, height) : null;
    if (size == _outputSize) return;
    _outputSize = size;
    for (final v in _videos.toList()) {
      unawaited(v.applySize());
    }
  }

  @override
  Stream<String> get httpErrors => _http.stream;

  @override
  int get live => _live.length;

  @override
  Future<void> get retiring => _retiring;

  @override
  String? get hwdec {
    final env = Platform.environment['SYNC_RELAY_HWDEC'];
    if (env != null && env.isNotEmpty) return env;
    return _hwdecSetting();
  }

  @override
  Future<HostedPlayer> create(PlayerRole role, {bool muted = false}) async {
    if (_closing) throw StateError('closing: no new players');
    final mk = _SyncPlayer(
        configuration: switch (role) {
      PlayerRole.session => PlayerConfiguration(
          bufferSize: sessionAheadBytes,
          libass: true,
          vo: Platform.environment['SYNC_RELAY_VO'],
          logLevel: MPVLogLevel.warn),
      PlayerRole.preload => PlayerConfiguration(
          bufferSize: preloadAheadBytes,
          libass: true,
          vo: Platform.environment['SYNC_RELAY_VO'],
          logLevel: MPVLogLevel.error),
      PlayerRole.thumbnail => const PlayerConfiguration(
          vo: 'null', muted: true, osc: false, libass: false, title: 'thumbnail', bufferSize: 4 << 20),
    });
    final p = _MkPlayer(this, mk, role);
    _live.add(p);
    if (role != PlayerRole.thumbnail) {
      p._logSub = p.logs.listen((l) => _route(p, l));
      final mismatches = <String>[];
      await _pinCache(p, role, mismatches);
      if (await p.pin('volume-max', '$mpvMaxVolume') case final m?) mismatches.add(m);
      if (muted || role == PlayerRole.preload) {
        if (await p.pin('mute', 'yes') case final m?) mismatches.add(m);
      }
      if (role == PlayerRole.session) {
        pinMismatches
          ..clear()
          ..addAll(mismatches);
      }
    }
    return p;
  }

  @override
  Future<void> promote(HostedPlayer p) async {
    final mk = p as _MkPlayer;
    mk._role = PlayerRole.session;
    mk.setLogLevel(sessionLogLevel);
    final mismatches = <String>[];
    if (await p.pin('mute', 'no') case final m?) mismatches.add(m);
    await _pinCache(mk, PlayerRole.session, mismatches);
    pinMismatches
      ..clear()
      ..addAll(mismatches);
  }

  Future<void> _pinCache(_MkPlayer p, PlayerRole role, List<String> out) async {
    final session = role == PlayerRole.session;
    for (final (k, v) in [
      ('demuxer-readahead-secs', '$readAheadSecs'),
      ('cache-secs', '$readAheadSecs'),
      ('demuxer-max-bytes', '${session ? sessionAheadBytes : preloadAheadBytes}'),
      ('demuxer-max-back-bytes', '${session ? sessionBackBytes : preloadBackBytes}'),
      ('cache-on-disk', 'no'),
      if (hwdec case final h?) ('hwdec', h),
      ('stream-lavf-o', streamLavfOptions),
      // Pages are resolved by the app's own yt-dlp (the media pipeline):
      // mpv's Lua hook never runs one.
      ('ytdl', 'no'),
    ]) {
      if (await p.pin(k, v) case final m?) out.add(m);
    }
  }

  @override
  HostedVideo video(HostedPlayer player, {bool probe = false}) {
    final p = player as _MkPlayer;
    if (probe) {
      _logRenderEnv();
      p.setLogLevel('v'); // back to the session level at the probe's end
    }
    // media_kit's video output sets hwdec itself on attach ('auto' unless
    // configured), which used to override SYNC_RELAY_HWDEC.
    final controller = VideoController(p.mk, configuration: VideoControllerConfiguration(hwdec: hwdec));
    final v = _MkVideo(p, controller);
    _videos.add(v);
    p._video = v;
    if (_outputSize != null) unawaited(v.applySize());
    // mpv gets `vo=libmpv` before the output's render context exists; a
    // media opened in between fails its video output ("No render context
    // set") and plays black. Opens wait for the output (seen on X11, where
    // the context comes up later, when joining with media already up).
    p._videoReady = controller.platform.future
        .then((_) {})
        .timeout(const Duration(seconds: 5), onTimeout: () {})
        .catchError((Object _) {});
    if (probe) unawaited(_probeRender(p, v));
    return v;
  }

  // ------------------------------------------------------------ the log

  // mpv's warnings and errors to the app log, a few per kind at a time (a
  // refused request makes ffmpeg retry and warn on every try); ffmpeg's
  // HTTP status to [httpErrors]; the GL init lines while probing.
  void _route(_MkPlayer p, PlayerLogLine log) {
    // Windows: the controller can be "ready" before mpv's render context
    // exists, and an open in that gap fails its video output ("No render
    // context set"). Open the same media again once, a moment later.
    if (log.prefix == 'cplayer' && log.text.contains('initializing the selected video_out')) {
      final last = p._lastOpen;
      if (last != null && !p._voRetried && !p._retired) {
        p._voRetried = true;
        _mpvLog.info('render: the video output was not up for the open; opening it again');
        unawaited(Future.delayed(const Duration(milliseconds: 500), () async {
          if (p._retired || !identical(p._lastOpen, last)) return;
          await p.mk.open(Media(last.url, httpHeaders: last.headers), play: last.play);
        }).catchError((Object e) => _mpvLog.warning('render: opening again failed: $e')));
      }
    }
    if (log.prefix == 'ffmpeg') {
      final http = RegExp(r'HTTP error \d{3}.*').firstMatch(log.text);
      if (http != null) _http.add(http[0]!.trim());
    }
    if (log.prefix == 'libmpv_render') {
      if (_glInfo.hasMatch(log.text)) _mpvLog.info('render: [libmpv_render] ${log.text.trim()}');
      if (log.text.contains('suspected software renderer')) {
        _probeMode = RenderMode.softwareGl;
        _renderMode.value = RenderMode.softwareGl;
      } else if (log.text.startsWith('GL_VERSION') && p._probing && _probeMode == RenderMode.unknown) {
        _probeMode = RenderMode.gpu;
        _renderMode.value = RenderMode.gpu;
      }
    }
    final level = log.level;
    if (level != 'warn' && !log.isError) return;
    final text = log.text.trim();
    if (text.isEmpty) return;
    final who = p.role == PlayerRole.preload ? 'preload ' : '';
    final pass = _throttle.allow('$who${log.prefix} $level ${text.length > 40 ? text.substring(0, 40) : text}');
    if (pass == null) return;
    final line = '$pass$who[${log.prefix}] $text';
    level == 'warn' ? _mpvLog.info(line) : _mpvLog.warning(line);
  }

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

  RenderMode _probeMode = RenderMode.unknown;

  // media_kit's Linux/Windows video output creates mpv's render context
  // while the controller is created: OpenGL when it can, else the software
  // renderer, which never logs GL init (and ignores shaders). No GL line
  // within 1.5 s of the output being up means software.
  Future<void> _probeRender(_MkPlayer p, _MkVideo v) async {
    p._probing = true;
    _probeMode = RenderMode.unknown;
    try {
      await v.controller.platform.future;
      await Future.delayed(const Duration(milliseconds: 1500));
    } catch (_) {
      return;
    } finally {
      p._probing = false;
      if (!p.disposed) p.setLogLevel(sessionLogLevel);
    }
    if (p.disposed) return;
    final mode = _probeMode;
    if (mode != RenderMode.unknown) {
      _renderMode.value = mode;
      _mpvLog.info('render: ${mode.name} (${mode == RenderMode.gpu ? 'OpenGL on the GPU' : 'OpenGL on the CPU'})');
      return;
    }
    _renderMode.value = RenderMode.software;
    _mpvLog.info("render: software (no GL init logged: media_kit's own fallback; "
        'its reason is on stderr, "media_kit: VideoOutput: ..." when run from a terminal)');
  }

  // Once per player, after its first frame: the decoder mpv picked; the
  // first time per app start also mpv's and ffmpeg's versions.
  static bool _versionsLogged = false;
  Future<void> _logFirstFrame(_MkPlayer p) async {
    try {
      final current = await p.getProperty('hwdec-current');
      final wanted = await p.getProperty('hwdec');
      _mpvLog.info('render: first frame ${p.state.width}x${p.state.height}, '
          'hwdec-current=${current.isEmpty ? 'no' : current} (hwdec=$wanted), mode ${_renderMode.peek().name}');
      if (!_versionsLogged) {
        _versionsLogged = true;
        _mpvLog.info('render: ${await versions(p)}');
      }
    } catch (e) {
      debugPrint('first frame info: $e');
    }
  }

  @override
  Future<String?> versions(HostedPlayer player) async {
    try {
      return '${await player.getProperty('mpv-version')}, ffmpeg ${await player.getProperty('ffmpeg-version')}';
    } catch (_) {
      return null;
    }
  }

  // --------------------------------------------------------- tear-down

  @override
  Future<void> retire(HostedPlayer player) {
    final p = player as _MkPlayer;
    p._retired = true;
    unawaited(p.mk.pause().catchError((_) {}));
    return _retiring = () async {
      await _settleUi();
      await dispose(p);
    }();
  }

  @override
  Future<void> dispose(HostedPlayer player) async {
    final p = player as _MkPlayer;
    if (!_live.remove(p)) return;
    p._retired = true;
    if (p._video case final v?) {
      _videos.remove(v);
      await v._paramsSub?.cancel();
    }
    await p._logSub?.cancel();
    try {
      await p.mk.dispose();
    } catch (_) {}
  }

  @override
  Future<void> disposeAll({Duration each = const Duration(milliseconds: 1500)}) async {
    _closing = true;
    await Future.wait([
      for (final p in _live.toList()) dispose(p).timeout(each).catchError((Object _) {}),
    ]);
    _closing = false;
  }

  // Two frames: one may already be mid-build when the view drops the
  // output. Then the length of a route pop (the fullscreen route holds its
  // own `Video` and leaves animated). Bounded, since a hidden window
  // renders no frames; headless tests have no binding and skip it all.
  static Future<void> _settleUi() async {
    try {
      for (var i = 0; i < 2; i++) {
        await WidgetsBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 300));
      }
      await Future.delayed(const Duration(milliseconds: 350));
    } catch (_) {}
  }
}

/// A [Player] whose public [seek] belongs to the user. media_kit's controls
/// call `player.seek`; with [onUserSeek] set those calls become explicit
/// events for the sync layer instead of moving mpv behind its back.
class _SyncPlayer extends Player {
  _SyncPlayer({super.configuration});

  void Function(Duration position)? onUserSeek;

  @override
  Future<void> seek(Duration duration) async {
    final hook = onUserSeek;
    if (hook == null) return super.seek(duration);
    hook(duration);
  }

  Future<void> syncSeek(Duration duration) => super.seek(duration);
}

class _MkPlayer implements HostedPlayer {
  final MediaKitHost host;
  final _SyncPlayer mk;
  PlayerRole _role;
  _MkPlayer(this.host, this.mk, this._role) {
    _firstFrame = mk.stream.width.listen((w) {
      if (w == null || w <= 0 || _role == PlayerRole.thumbnail) return;
      unawaited(_firstFrame?.cancel());
      unawaited(host._logFirstFrame(this));
    });
  }

  StreamSubscription<PlayerLogLine>? _logSub;
  StreamSubscription<int?>? _firstFrame;
  bool _probing = false;
  bool _retired = false;
  Future<void>? _videoReady; // set once a video output is attached
  // The last open, for one retry when mpv's video output was not up yet.
  ({String url, Map<String, String> headers, bool play})? _lastOpen;
  bool _voRetried = false;
  _MkVideo? _video;

  dynamic get _mpv => mk.platform;

  @override
  PlayerRole get role => _role;

  @override
  bool get disposed => _retired;

  @override
  HostedPlayerState get state {
    final s = mk.state;
    return HostedPlayerState(
      position: s.position,
      duration: s.duration,
      buffer: s.buffer,
      volume: s.volume,
      playing: s.playing,
      completed: s.completed,
      width: s.width,
      height: s.height,
    );
  }

  @override
  Stream<Duration> get positionStream => mk.stream.position;
  @override
  Stream<Duration> get durationStream => mk.stream.duration;
  @override
  Stream<Duration> get bufferStream => mk.stream.buffer;
  @override
  Stream<double> get volumeStream => mk.stream.volume;
  @override
  Stream<bool> get completedStream => mk.stream.completed;
  @override
  Stream<int?> get widthStream => mk.stream.width;
  @override
  Stream<PlayerLogLine> get logs => mk.stream.log.map((l) => PlayerLogLine(l.prefix, l.level, l.text));

  @override
  void Function(Duration position)? get onUserSeek => mk.onUserSeek;
  @override
  set onUserSeek(void Function(Duration position)? f) => mk.onUserSeek = f;

  @override
  Future<void> open(String url, {Map<String, String> headers = const {}, bool play = false}) async {
    if (_videoReady case final ready?) await ready;
    _lastOpen = (url: url, headers: headers, play: play);
    _voRetried = false;
    // An empty map, not null: media_kit caches headers per URI.
    await mk.open(Media(url, httpHeaders: headers), play: play);
  }

  @override
  Future<void> play() => mk.play();
  @override
  Future<void> pause() => mk.pause();
  @override
  Future<void> stop() => mk.stop();
  @override
  Future<void> seek(Duration position) => mk.seek(position);
  @override
  Future<void> syncSeek(Duration position) => mk.syncSeek(position);
  @override
  Future<void> setRate(double rate) => mk.setRate(rate);
  @override
  Future<void> setVolume(double volume) => mk.setVolume(volume);

  // media_kit has no public property API: a guarded dynamic call on
  // `player.platform` (its NativePlayer).
  @override
  Future<void> setProperty(String name, String value) async => await _mpv?.setProperty(name, value);

  @override
  Future<String> getProperty(String name) async => '${await _mpv?.getProperty(name)}';

  @override
  Future<void> observeProperty(String name, Future<void> Function(String value) onChange) async =>
      await _mpv?.observeProperty(name, onChange);

  @override
  Future<void> command(List<String> args) async => await _mpv?.command(args);

  @override
  Future<String?> pin(String name, String value) async {
    try {
      await setProperty(name, value);
      final got = await getProperty(name);
      if (pinMatches(value, got)) return null;
      debugPrint('pin $name=$value not applied, mpv has "$got"');
      return '$name: $value -> $got';
    } catch (e) {
      debugPrint('pin $name=$value failed: $e');
      return '$name: $value -> error $e';
    }
  }

  // mpv_request_log_messages on media_kit's handle.
  @override
  void setLogLevel(String level) {
    try {
      final dynamic platform = mk.platform;
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
}

class _MkVideo implements HostedVideo {
  @override
  final _MkPlayer player;
  final VideoController controller;
  _MkVideo(this.player, this.controller);

  @override
  Future<void> get ready => controller.platform.future;

  // What this output was last set to: null with [_sized] the video's own
  // size again; nothing sent yet while [_sized] is false.
  (int, int)? _sent;
  bool _sized = false;
  StreamSubscription<VideoParams>? _paramsSub;
  Future<void> _sizeOp = Future.value();

  /// Renders at the host's output size (or the video's own when it has
  /// none). media_kit's controller sets the output back to the video's
  /// size whenever the video's parameters change (a new file, a track
  /// with another size); the fixed size is sent again after it, under
  /// the controller's own lock so it lands last.
  Future<void> applySize({bool again = false}) => _sizeOp = _sizeOp.then((_) async {
        if (player.disposed) return;
        try {
          // NativeVideoController (Linux, Windows): not exported, reached
          // through its public fields.
          final dynamic native = await controller.platform.future;
          final view = player.host._outputSize;
          final params = player.mk.state.videoParams;
          final dw = params.dw ?? 0, dh = params.dh ?? 0;
          final want = view == null ? null : fitOutputSize(view, dw > 0 && dh > 0 ? (dw, dh) : null);
          if (_sized && want == _sent && !again) return;
          if (want == null) {
            if (!_sized) return; // never resized: already the video's size
            await native.setSize();
          } else {
            // setSize skips a size it believes is set; after media_kit's own
            // reset it is not.
            native.width = null;
            await native.setSize(width: want.$1, height: want.$2);
          }
          _sent = want;
          _sized = true;
          // The output takes its new size with the next frame mpv draws;
          // paused, none comes: a pan too small to see makes mpv redraw.
          if (!player.state.playing) {
            await player.setProperty('video-pan-x', '0.000001');
            await player.setProperty('video-pan-x', '0');
          }
          _paramsSub ??= player.mk.stream.videoParams.listen((params) async {
            if ((params.dw ?? 0) == 0 || _sent == null) return;
            try {
              await (native.lock.synchronized(() async {}) as Future);
            } catch (_) {}
            unawaited(applySize(again: true));
          });
        } catch (e) {
          debugPrint('video output size: $e');
        }
      });
}
