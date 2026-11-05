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
      required this.notify});

  bool _capturing = false;

  /// The frame on screen now, with and (when subtitles are on) without
  /// subtitles, caught back to back; null when there is no picture (or a
  /// capture is still under way).
  Future<Shot?> capture() async {
    final p = playback.current;
    if (p == null || p.disposed || _capturing) return null;
    _capturing = true;
    try {
      final at = p.state.position;
      final sub = playback.tracks.peek().where((t) => t.type == JellyfinStreamType.subtitle && t.selected).firstOrNull;
      var grab = await p.grabFrame(subtitles: sub != null);
      if (grab == null) {
        final source = p.opened;
        if (source == null) return null;
        final subScale = await p.getProperty('sub-scale').catchError((Object _) => '1');
        final sw = Stopwatch()..start();
        // At the very end a seek finds nothing: the last moment before it.
        final end = p.state.duration - const Duration(milliseconds: 100);
        grab = await decodeStillFrame(playback.host,
            url: source.url,
            headers: source.headers,
            at: end > Duration.zero && at > end ? end : at,
            sid: sub?.id,
            subScale: subScale);
        _log.info('decoded the frame at ${at.inMilliseconds} ms again: ${sw.elapsedMilliseconds} ms');
      }
      if (grab == null) return null;
      final now = nowPlaying.peek();
      return Shot(
          clean: grab.clean, subs: grab.subs, name: screenshotName(title: now?.title, episode: now?.episode, at: at));
    } finally {
      _capturing = false;
    }
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

/// The frame at [at] of [url] (opened with [headers]), decoded once more
/// in software by a hidden player of [host] (no sound, nothing on
/// screen), and with subtitle track [sid] (at [subScale]) drawn in for
/// the second copy. For when mpv cannot hand over the frame on screen:
/// mpv 0.41 cannot read a frame back from the GPU decoder (`hwdec`
/// without `-copy`: "Input image format cuda not supported"; mpv after
/// 0.41 can). Both copies are then the very same frame. Slower: the media
/// is opened and sought again (a moment for a file, longer for a stream).
Future<FrameGrab?> decodeStillFrame(PlayerHost host,
    {required String url,
    Map<String, String> headers = const {},
    required Duration at,
    int? sid,
    String subScale = '1',
    Duration timeout = const Duration(seconds: 15)}) async {
  HostedPlayer? still;
  try {
    still = await host.create(PlayerRole.thumbnail);
    final h = still;
    for (final (k, v) in [
      ('ao', 'null'),
      ('aid', 'no'),
      ('vid', 'auto'), // media_kit starts with vid=no
      ('hwdec', 'no'),
      ('ytdl', 'no'),
      ('hr-seek', 'yes'),
      ('start', (at.inMicroseconds / 1e6).toStringAsFixed(3)),
      ('sid', sid == null ? 'no' : '$sid'),
      ('sub-ass', 'yes'),
      ('sub-visibility', 'yes'),
      ('sub-scale', subScale),
    ]) {
      await h.setProperty(k, v);
    }
    await h.open(url, headers: headers);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await h.getProperty('idle-active') == 'yes') return null;
      final w = await h.getProperty('video-params/w');
      if (w.isNotEmpty && w != '0' && await h.getProperty('seeking') != 'yes') {
        return await h.grabFrame(subtitles: sid != null);
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _log.warning('still frame: not up in ${timeout.inSeconds} s');
    return null;
  } catch (e) {
    _log.warning('still frame failed: $e');
    return null;
  } finally {
    if (still != null) unawaited(host.dispose(still));
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
