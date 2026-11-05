import 'dart:async';
import 'dart:typed_data';

import 'package:signals/signals.dart';

// The media players as the app sees them: mpv instances, their video
// outputs, how the video is rendered, mpv's log and the order players are
// torn down in. Desktop: media_kit over libmpv
// (`platform/desktop/media_kit_host.dart`); nothing else in the app
// touches media_kit except the `Video` widget glue.

/// How the video output renders (shaders need [gpu]).
enum RenderMode {
  unknown,

  /// OpenGL on a real GPU: shaders work.
  gpu,

  /// OpenGL on a software rasterizer (llvmpipe): shaders crawl.
  softwareGl,

  /// The video output's own software fallback: shaders are ignored.
  software,
}

/// What a player is for: its cache, log level and log routing.
enum PlayerRole {
  /// The session's player (and a fresh one per media): full cache, mpv log
  /// at `warn` into the app log.
  session,

  /// The hidden player holding what plays next: small cache, muted, log
  /// at `error`.
  preload,

  /// A poster frame for Files: no audio or video output, no cache, no log.
  thumbnail,
}

/// One line of mpv's log.
class PlayerLogLine {
  final String prefix;
  final String level;
  final String text;
  const PlayerLogLine(this.prefix, this.level, this.text);

  bool get isError => level == 'error' || level == 'fatal';
}

/// A snapshot of a player's state.
class HostedPlayerState {
  final Duration position;
  final Duration duration;

  /// End of the cached range (mpv `demuxer-cache-time`).
  final Duration buffer;
  final double volume;
  final bool playing;

  /// At the end of the file.
  final bool completed;
  final int? width;
  final int? height;
  const HostedPlayerState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffer = Duration.zero,
    this.volume = 100,
    this.playing = false,
    this.completed = false,
    this.width,
    this.height,
  });
}

/// One video frame as mpv decoded it: tightly packed RGBA rows (opaque),
/// at the video's display size (aspect applied).
class RawFrame {
  final Uint8List rgba;
  final int width;
  final int height;
  const RawFrame(this.rgba, this.width, this.height);
}

/// The frame on screen, caught once without subtitles ([clean]) and,
/// when asked, once with them ([subs]), one right after the other.
typedef FrameGrab = ({RawFrame clean, RawFrame? subs});

/// One mpv player. Each media gets its own (see ARCHITECTURE "Player
/// lifecycle"); [PlayerHost.retire] / [PlayerHost.disposeAll] end it.
abstract interface class HostedPlayer {
  PlayerRole get role;
  HostedPlayerState get state;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<double> get volumeStream;
  Stream<bool> get completedStream;
  Stream<int?> get widthStream;

  /// mpv's log lines at the player's level.
  Stream<PlayerLogLine> get logs;

  /// The player is gone (disposed or being disposed): commands do nothing.
  bool get disposed;

  /// Seeks from the video widget's own controls land here instead of in
  /// mpv when set ([seek] goes through it too); [syncSeek] always moves
  /// mpv.
  void Function(Duration position)? onUserSeek;

  /// What the last [open] opened (a still frame of it is opened again
  /// from this); null before one.
  ({String url, Map<String, String> headers})? get opened;

  /// Opens [url] (with [headers] on every request), paused unless [play].
  Future<void> open(String url, {Map<String, String> headers = const {}, bool play = false});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// A user seek: through [onUserSeek] when set, else [syncSeek].
  Future<void> seek(Duration position);

  /// Moves mpv (sync corrections, scrub preview).
  Future<void> syncSeek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> setProperty(String name, String value);
  Future<String> getProperty(String name);
  Future<void> observeProperty(String name, Future<void> Function(String value) onChange);
  Future<void> command(List<String> args);

  /// Sets [name] and reads it back: null when mpv took [value], else
  /// `name: value -> got` (mpv ignores invalid values silently).
  Future<String?> pin(String name, String value);

  /// mpv's log level for this player (`warn`, `v`, ...).
  void setLogLevel(String level);

  /// The frame on screen at the video's own resolution, straight from mpv
  /// (never the app's overlays), off the UI thread; with [subtitles] also
  /// a second copy with the subtitles drawn in. Null when there is no
  /// picture (nothing open, no video track, the player gone).
  Future<FrameGrab?> grabFrame({required bool subtitles});
}

/// A player's video output (a texture the `Video` widget shows).
abstract interface class HostedVideo {
  HostedPlayer get player;

  /// Completes once the output is up (its texture registered).
  Future<void> get ready;
}

/// Creates, owns and disposes the app's players. One per app (the
/// composition root's `Ports`); tests make their own.
abstract interface class PlayerHost {
  /// Once at start, before any player.
  void init();

  /// A new player for [role], set up before it is returned to the caller's
  /// first await: cache, pins ([pinMismatches]), hwdec, log level.
  Future<HostedPlayer> create(PlayerRole role, {bool muted = false});

  /// [player] (a preload) becomes a session player: unmuted, the full
  /// cache pins, the session's log level.
  Future<void> promote(HostedPlayer player);

  /// [player]'s video output, with the hwdec policy. [probe]: listen to
  /// mpv's render init to learn [renderMode] (the first output of an app
  /// start).
  HostedVideo video(HostedPlayer player, {bool probe = false});

  /// The view's pixel size: every video output renders the picture fitted
  /// in it ([fitOutputSize]), so mpv scales the picture and draws
  /// subtitles at screen resolution (Settings → Player, "Sharp video").
  /// Null: each output at its video's own size. Applies to live outputs
  /// and to new ones once they are up.
  void setOutputSize(int? width, int? height);

  /// How video renders, as last learned (kept after leaving).
  ReadonlySignal<RenderMode> get renderMode;

  /// mpv `hwdec` for new players: env `SYNC_RELAY_HWDEC` wins over the
  /// setting (Windows' auto is `auto-copy`).
  String? get hwdec;

  /// Pins that did not take on the last session player created.
  List<String> get pinMismatches;

  /// ffmpeg's HTTP errors (`HTTP error 403 Forbidden`), from whichever
  /// player ffmpeg logs through (one per process).
  Stream<String> get httpErrors;

  /// `mpv-version` and `ffmpeg-version` of [player], for diagnostics.
  Future<String?> versions(HostedPlayer player);

  /// Ends [player] once the view let go of its texture (two frames and a
  /// route pop); at most one retiring player lingers, a new [create] of a
  /// session player waits for it ([retiring]).
  Future<void> retire(HostedPlayer player);

  /// The last retire, until done.
  Future<void> get retiring;

  /// Disposes [player] at once (no view showed it).
  Future<void> dispose(HostedPlayer player);

  /// App close: every live player goes, each bounded by [each], before
  /// the engine does (a live mpv calls back into a dead isolate).
  Future<void> disposeAll({Duration each});

  /// Live players, for tests and the close.
  int get live;
}

/// [log] says ffmpeg's HTTP stream lost the file's size and so every
/// seek on it fails ("Seek failed (to 3417735, size -38)": -38 is ENOSYS,
/// what ffmpeg answers for the size once a reconnect's or a seek's request
/// failed). Only a fresh open gets it back.
bool mpvStreamLost(PlayerLogLine log) =>
    log.prefix == 'ffmpeg' && log.text.contains('Seek failed') && log.text.contains('size -38)');

/// [log] says the media could not be opened: before a [duration] is known,
/// mpv's fatal "nothing to play" or a demuxer error.
bool mpvLoadFailed(PlayerLogLine log, Duration duration) {
  return duration == Duration.zero &&
      ((log.prefix == 'cplayer' && log.level == 'fatal') || (log.prefix == 'demux' && log.level == 'error'));
}

/// The size a video output renders at for a [view] of that many pixels:
/// the [video]'s picture (its display size, aspect included) fitted
/// inside, no letterbox. The texture then has the picture's aspect, so
/// while a resize settles Flutter scales the last one to the new view
/// with no jump (a texture of the whole view would shrink inside its own
/// black bars until the new one came). Drawn 1:1: the fitted side is the
/// view's, the other is rounded down to the view's parity, so the
/// picture sits on whole pixels when centred (a half-pixel offset would
/// blur every line). Unknown video: the view.
(int, int) fitOutputSize((int, int) view, (int, int)? video) {
  final (vw, vh) = view;
  if (video == null || video.$1 <= 0 || video.$2 <= 0) return view;
  final aspect = video.$1 / video.$2;
  int under(double x, int full) {
    var n = x.floor().clamp(1, full);
    if ((full - n).isOdd) n = n > 1 ? n - 1 : n;
    return n;
  }

  if (vw / vh > aspect) return (under(vh * aspect, vw), vh); // pillarbox
  return (vw, under(vw / aspect, vh)); // letterbox (or exact)
}
