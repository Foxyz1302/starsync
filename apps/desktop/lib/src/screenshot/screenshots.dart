import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:signals/signals_core.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType, createLogger;

import '../playback/playback_controller.dart';
import '../platform/ports/folder_access.dart';
import '../platform/ports/player_host.dart' show FrameGrab, HostedPlayer, PlayerHost, PlayerRole, RawFrame;
import '../platform/ports/shell_port.dart';
import '../session/app_events.dart';
import '../session/now_playing.dart';
import 'shot_crop.dart';
import 'shot_files.dart';

// Screenshots of the session's video (ARCHITECTURE "Screenshots"): the
// frame caught from mpv at the press, with and without subtitles, then
// saved to Pictures / Starsync and copied, cropped or whole.

final _log = createLogger('screenshot');

/// One press's catch: the frame on screen without subtitles ([clean]) and
/// with them ([subs], null when none were on), and its file name.
class Shot {
  final RawFrame clean;
  final RawFrame? subs;
  final String name;
  const Shot({required this.clean, this.subs, required this.name});

  /// Subtitles were on at the press (both copies exist).
  bool get hasSubs => subs != null;

  RawFrame frame({required bool subtitles}) => subtitles ? subs ?? clean : clean;
}

/// A screenshot's encoded picture: the PNG and a small one for the toast.
typedef ShotPng = ({Uint8List png, Uint8List thumb});

/// The width of the toast's picture (shown at 68 logical pixels; this
/// keeps it sharp at 2x).
const shotThumbWidth = 136;

/// Takes screenshots of the session's player ([capture]) and saves and
/// copies them ([save]); a toast with the picture says so.
class Screenshots {
  final PlaybackController playback;
  final ReadonlySignal<NowPlaying?> nowPlaying;
  final FolderAccess folders;
  final ShellPort shell;
  final void Function(AppEvent event) notify;
  Screenshots(
      {required this.playback,
      required this.nowPlaying,
      required this.folders,
      required this.shell,
      required this.notify})
      : stills = StillFrames(playback.host);

  /// The hidden player for frames mpv cannot hand over (GPU decoding).
  final StillFrames stills;

  Future<void>? _under;

  /// The frame on screen now, with and (when subtitles are on) without
  /// subtitles, caught back to back; null when there is no picture. A
  /// capture still under way (one given up) is waited for first.
  Future<Shot?> capture() async {
    for (var under = _under; under != null; under = _under) {
      await under;
    }
    final done = Completer<void>();
    _under = done.future;
    try {
      return await _capture();
    } finally {
      _under = null;
      done.complete();
    }
  }

  Future<Shot?> _capture() async {
    final p = playback.current;
    if (p == null || p.disposed) return null;
    final at = p.state.position;
    final sub = playback.tracks.peek().where((t) => t.type == JellyfinStreamType.subtitle && t.selected).firstOrNull;
    final sw = Stopwatch()..start();
    // A GPU decoder's frame cannot be read back (mpv 0.41): straight to
    // the hidden player then, without the grab that would fail first.
    final (hwdec, version, subScale) =
        await (p.getProperty('hwdec-current'), p.getProperty('mpv-version'), p.getProperty('sub-scale'))
            .wait
            .catchError((Object _) => ('', '', '1'));
    FrameGrab? grab;
    var how = 'from mpv';
    if (!gpuFrames(hwdec, version)) grab = await p.grabFrame(subtitles: sub != null);
    if (grab == null) {
      final source = p.opened;
      if (source == null) return null;
      // At the very end a seek finds nothing: the last moment before it.
      final end = p.state.duration - const Duration(milliseconds: 100);
      final still = await stills.frameAt(
          url: source.url,
          headers: source.headers,
          at: end > Duration.zero && at > end ? end : at,
          sid: sub?.id,
          subScale: subScale);
      grab = still?.grab;
      how = still == null ? 'decoded again, failed' : 'decoded again (${still.warm ? 'warm' : 'opened'})';
    }
    _log.info('frame at ${at.inMilliseconds} ms (hwdec ${hwdec.isEmpty ? 'no' : hwdec}), $how: ${sw.elapsedMilliseconds} ms');
    if (grab == null) return null;
    final now = nowPlaying.peek();
    return Shot(
        clean: grab.clean, subs: grab.subs, name: screenshotName(title: now?.title, episode: now?.episode, at: at));
  }

  /// Saves [shot] ([subtitles] on or off, cropped to [crop], whole when
  /// null) as a new file and copies it; the toast shows it, and a click on
  /// it runs [onEdit] with the same shot.
  Future<void> save(Shot shot, {required bool subtitles, PixelRect? crop, void Function(Shot shot)? onEdit}) async {
    final ShotPng out;
    try {
      out = await encodeShot(shot.frame(subtitles: subtitles), crop);
    } catch (e) {
      _log.warning('encode failed: $e');
      notify(const ActionFailed("Couldn't take the screenshot"));
      return;
    }
    String? path;
    try {
      final dir = await folders.screenshotFolder();
      await Directory(dir).create(recursive: true);
      path = uniquePath(dir, shot.name, 'png', (p) => File(p).existsSync());
      await File(path).writeAsBytes(out.png, flush: true);
    } catch (e) {
      _log.warning('save failed: $e');
      path = null;
    }
    final copied = await shell.copyImage(out.png);
    _log.info('${path ?? 'not saved'}${copied ? ', copied' : ', not copied'}'
        '${crop == null ? '' : ' (${crop.width}x${crop.height})'}');
    if (path == null && !copied) {
      notify(const ActionFailed("Couldn't save or copy the screenshot"));
      return;
    }
    final text = path == null
        ? "Copied (couldn't save it)"
        : copied
            ? 'Saved and copied'
            : "Saved (couldn't copy it)";
    notify(ScreenshotTaken(text, out.thumb, onEdit: onEdit == null ? null : () => onEdit(shot)));
  }
}

/// mpv's `hwdec-current` [hwdec] leaves the frames on the GPU (a decoder
/// without `-copy`) and mpv [version] (`mpv-version`) cannot hand one
/// over: 0.41 and before ("Input image format cuda not supported"; mpv
/// after 0.41 can). An unknown version is tried.
bool gpuFrames(String hwdec, String version) {
  if (hwdec.isEmpty || hwdec == 'no' || hwdec.endsWith('-copy')) return false;
  final m = RegExp(r'(\d+)\.(\d+)').firstMatch(version);
  if (m == null) return false;
  return int.parse(m[1]!) == 0 && int.parse(m[2]!) <= 41;
}

/// Frames of the session's media decoded once more, in software, by a
/// hidden player of [host] (no sound, nothing on screen): for when mpv
/// cannot hand over the frame on screen ([gpuFrames]). Its first frame
/// opens the media at that moment; the player then stays on that media,
/// paused, for [keep] after the last frame (or while [hold] holds it, the
/// selection being up), so the next one is only an exact seek. Another
/// media, or the time out, closes it.
class StillFrames {
  final PlayerHost host;
  final Duration keep;
  StillFrames(this.host, {this.keep = const Duration(minutes: 2)});

  HostedPlayer? _player;
  String? _source; // what [_player] has open
  ({int? sid, String subScale})? _subs;
  Timer? _idle;
  int _holds = 0;
  Future<void> _queue = Future.value();

  /// A hidden player is up.
  bool get warm => _player != null;

  /// The frame at [at] of [url] (opened with [headers]), and with
  /// subtitle track [sid] (at [subScale]) drawn in for the second copy;
  /// both copies are the very same frame. `warm`: the player was already
  /// on that media. Null when it cannot be had in [timeout].
  Future<({FrameGrab grab, bool warm})?> frameAt(
      {required String url,
      Map<String, String> headers = const {},
      required Duration at,
      int? sid,
      String subScale = '1',
      Duration timeout = const Duration(seconds: 15)}) {
    final run = _queue.then((_) => _frameAt(url, headers, at, sid, subScale, timeout));
    _queue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<({FrameGrab grab, bool warm})?> _frameAt(
      String url, Map<String, String> headers, Duration at, int? sid, String subScale, Duration timeout) async {
    _idle?.cancel();
    final source = [url, for (final e in headers.entries) '${e.key}: ${e.value}'].join('\n');
    var p = _player;
    final warm = p != null && !p.disposed && _source == source;
    try {
      if (p != null && warm) {
        if (_subs != (sid: sid, subScale: subScale)) await _setSubs(p, sid, subScale);
        await p.command(['seek', _secs(at), 'absolute+exact']);
      } else {
        await close();
        final h = p = _player = await host.create(PlayerRole.thumbnail);
        _source = source;
        for (final (k, v) in [
          ('ao', 'null'),
          ('aid', 'no'),
          ('vid', 'auto'), // media_kit starts with vid=no
          ('hwdec', 'no'),
          ('ytdl', 'no'),
          ('hr-seek', 'yes'),
          ('start', _secs(at)),
          ('sub-ass', 'yes'),
          ('sub-visibility', 'yes'),
        ]) {
          await h.setProperty(k, v);
        }
        await _setSubs(h, sid, subScale);
        await h.open(url, headers: headers);
      }
      final grab = await _settled(p, at, timeout, subtitles: sid != null);
      if (grab == null) {
        await close();
        return null;
      }
      return (grab: grab, warm: warm);
    } catch (e) {
      _log.warning('still frame failed: $e');
      await close();
      return null;
    } finally {
      _later();
    }
  }

  Future<void> _setSubs(HostedPlayer p, int? sid, String subScale) async {
    await p.setProperty('sid', sid == null ? 'no' : '$sid');
    await p.setProperty('sub-scale', subScale);
    _subs = (sid: sid, subScale: subScale);
  }

  /// The grab once the player shows the frame at [at]: decoded, not
  /// seeking, on the frame at [at].
  Future<FrameGrab?> _settled(HostedPlayer p, Duration at, Duration timeout, {required bool subtitles}) async {
    final deadline = DateTime.now().add(timeout);
    final target = at.inMicroseconds / 1e6;
    while (DateTime.now().isBefore(deadline)) {
      if (await p.getProperty('idle-active') == 'yes') return null;
      final w = await p.getProperty('video-params/w');
      if (w.isNotEmpty && w != '0' && await p.getProperty('seeking') != 'yes') {
        final pos = double.tryParse(await p.getProperty('time-pos'));
        // An exact seek lands on the first frame at or after the moment (the
        // session player's position is the pts of the frame on screen).
        if (pos == null || (pos > target - 0.01 && pos < target + 0.5)) return await p.grabFrame(subtitles: subtitles);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    _log.warning('still frame: not up in ${timeout.inSeconds} s');
    return null;
  }

  /// Keeps the player while held (the selection is up); the time out
  /// starts again once the last hold lets go ([release]).
  void hold() {
    _holds++;
    _idle?.cancel();
  }

  void release() {
    if (_holds > 0) _holds--;
    _later();
  }

  void _later() {
    _idle?.cancel();
    if (_holds > 0 || _player == null) return;
    _idle = Timer(keep, () => unawaited(close()));
  }

  /// The hidden player goes.
  Future<void> close() async {
    _idle?.cancel();
    final p = _player;
    _player = null;
    _source = null;
    _subs = null;
    if (p != null && !p.disposed) await host.dispose(p);
  }

  static String _secs(Duration d) => (d.inMicroseconds / 1e6).toStringAsFixed(3);
}

/// One frame decoded again by a hidden player that goes at once
/// ([StillFrames] keeping nothing).
Future<FrameGrab?> decodeStillFrame(PlayerHost host,
    {required String url,
    Map<String, String> headers = const {},
    required Duration at,
    int? sid,
    String subScale = '1',
    Duration timeout = const Duration(seconds: 15)}) async {
  final stills = StillFrames(host);
  try {
    final still = await stills.frameAt(url: url, headers: headers, at: at, sid: sid, subScale: subScale, timeout: timeout);
    return still?.grab;
  } finally {
    await stills.close();
  }
}

/// [frame] (cropped to [crop]) as a PNG, and a small one for the toast,
/// on another isolate.
Future<ShotPng> encodeShot(RawFrame frame, PixelRect? crop) =>
    Isolate.run(() => encodeShotSync(frame, crop), debugName: 'screenshot png');

/// [encodeShot] on this isolate.
ShotPng encodeShotSync(RawFrame frame, PixelRect? crop) {
  final c = crop ?? (x: 0, y: 0, width: frame.width, height: frame.height);
  final rgb = Uint8List(c.width * c.height * 3);
  final src = frame.rgba;
  var o = 0;
  for (var y = c.y; y < c.y + c.height; y++) {
    var i = (y * frame.width + c.x) * 4;
    for (var x = 0; x < c.width; x++) {
      rgb[o] = src[i];
      rgb[o + 1] = src[i + 1];
      rgb[o + 2] = src[i + 2];
      o += 3;
      i += 4;
    }
  }
  final image = img.Image.fromBytes(width: c.width, height: c.height, bytes: rgb.buffer, numChannels: 3);
  final png = img.encodePng(image);
  final small = c.width > shotThumbWidth
      ? img.copyResize(image, width: shotThumbWidth, interpolation: img.Interpolation.average)
      : image;
  return (png: png, thumb: img.encodePng(small, level: 1));
}

/// [shot]'s two pictures for the screen (the selection shows them).
typedef ShotImages = ({ui.Image clean, ui.Image? subs});

Future<ShotImages> decodeShot(Shot shot) async {
  final clean = await _decode(shot.clean);
  final subs = shot.subs == null ? null : await _decode(shot.subs!);
  return (clean: clean, subs: subs);
}

Future<ui.Image> _decode(RawFrame f) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(f.rgba, f.width, f.height, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}
