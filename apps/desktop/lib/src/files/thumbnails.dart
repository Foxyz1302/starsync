import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

// Poster frames for the Files source, made by mpv itself (no ffmpeg on
// users' machines; Windows ships only libmpv). A hidden player per file
// with `vo=null`: mpv still keeps the last decoded frame, so
// `screenshot-to-file` encodes it with mpv's own JPEG writer. `start=25%`
// makes the first decoded frame the one we want, `vf=scale` keeps it
// small. Results (and failures) are cached on disk by path+size+mtime.

class Thumbnail {
  /// JPEG on disk, at most [thumbnailWidth] wide.
  final String imagePath;
  final Duration duration;
  const Thumbnail(this.imagePath, this.duration);
}

const thumbnailWidth = 480;

/// Where thumbnails are cached; swapped in tests.
Future<Directory> Function() thumbnailCacheRoot = getApplicationCacheDirectory;

/// Generations running at once: each is a full decoder.
const _maxConcurrent = 2;
const _timeout = Duration(seconds: 20);

int _running = 0;
final _waiting = <Completer<void>>[];
final _inFlight = <String, Future<Thumbnail?>>{};
final _players = <Player>{};
bool _closed = false;

/// App close: no new thumbnails, running ones stop at their next check
/// and dispose their player. Players still up after [deadline] are
/// disposed here, so no mpv outlives the engine.
Future<void> cancelAllThumbnails({
  Duration deadline = const Duration(milliseconds: 800),
}) async {
  _closed = true;
  try {
    await Future.wait(_inFlight.values.toList()).timeout(deadline);
  } catch (_) {}
  for (final p in _players.toList()) {
    _players.remove(p);
    try {
      await p.dispose().timeout(deadline);
    } catch (_) {}
  }
}

/// The cached or freshly made thumbnail of the video at [path], or null
/// when it can't be made (not a video, unreadable, timed out, cancelled).
/// Never throws. [cancelled] is checked while queued and before the
/// expensive steps: a scrolled-away tile returns null without decoding.
Future<Thumbnail?> thumbnailFor(String path, {bool Function()? cancelled}) {
  if (_closed) return Future.value(null);
  final existing = _inFlight[path];
  if (existing != null) return existing;
  final f = _thumbnailFor(path, () => _closed || (cancelled?.call() ?? false)).catchError((
    Object e,
    StackTrace st,
  ) {
    debugPrint('thumbnail $path failed: $e\n$st');
    return null;
  });
  _inFlight[path] = f;
  f.whenComplete(() => _inFlight.remove(path));
  return f;
}

/// Cache key: the same file at the same size and mtime reuses its frame.
String thumbnailKey(String path, int size, DateTime modified) => sha1
    .convert(utf8.encode('$path|$size|${modified.millisecondsSinceEpoch}'))
    .toString();

Future<Thumbnail?> _thumbnailFor(String path, bool Function() cancelled) async {
  final stat = await File(path).stat();
  if (stat.type != FileSystemEntityType.file) return null;
  final dir = Directory(
      '${(await thumbnailCacheRoot()).path}${Platform.pathSeparator}thumbnails');
  await dir.create(recursive: true);
  final base =
      '${dir.path}${Platform.pathSeparator}${thumbnailKey(path, stat.size, stat.modified)}';
  final cached = await _readCache(base);
  if (cached != null) return cached.$1;

  if (cancelled()) return null;
  await _acquire();
  try {
    if (cancelled()) return null;
    final made = await _generate(path, '$base.jpg', cancelled)
        .timeout(_timeout, onTimeout: () => null);
    if (made == null) {
      // Remember broken files, not cancellations.
      if (!cancelled()) await File('$base.json').writeAsString('{}');
      return null;
    }
    await File('$base.json')
        .writeAsString(jsonEncode({'ms': made.duration.inMilliseconds}));
    return made;
  } finally {
    _release();
  }
}

/// (thumbnail or null for a remembered failure), or null when not cached.
Future<(Thumbnail?,)?> _readCache(String base) async {
  try {
    final meta = File('$base.json');
    if (!await meta.exists()) return null;
    final ms = (jsonDecode(await meta.readAsString()) as Map)['ms'];
    if (ms is! int) return (null,);
    final jpg = File('$base.jpg');
    if (!await jpg.exists()) return null;
    return (Thumbnail(jpg.path, Duration(milliseconds: ms)),);
  } catch (_) {
    return null;
  }
}

Future<void> _acquire() async {
  if (_running < _maxConcurrent) {
    _running++;
    return;
  }
  final c = Completer<void>();
  _waiting.add(c);
  await c.future; // the releaser hands its slot over
}

void _release() {
  if (_waiting.isNotEmpty) {
    _waiting.removeAt(0).complete();
  } else {
    _running--;
  }
}

Future<Thumbnail?> _generate(
  String path,
  String out,
  bool Function() cancelled,
) async {
  final player = Player(
    configuration: const PlayerConfiguration(
      vo: 'null',
      muted: true,
      osc: false,
      libass: false,
      title: 'thumbnail',
      bufferSize: 4 << 20,
    ),
  );
  _players.add(player);
  try {
    final mpv = player.platform as NativePlayer;
    for (final (k, v) in [
      ('ao', 'null'),
      ('aid', 'no'),
      ('sid', 'no'),
      ('vid', 'auto'), // media_kit starts with vid=no
      ('hwdec', 'no'),
      ('cache', 'no'),
      ('hr-seek', 'no'), // nearest keyframe is fine for a poster
      ('start', '25%'),
      ('vf', 'scale=w=$thumbnailWidth:h=-2'),
      ('screenshot-format', 'jpg'),
      ('screenshot-jpeg-quality', '85'),
      ('screenshot-tag-colorspace', 'no'),
    ]) {
      await mpv.setProperty(k, v);
    }
    await player.open(Media(path), play: false);
    final target = File(out);
    final deadline = DateTime.now().add(_timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cancelled()) return null;
      // Unreadable or no video (with aid=no, audio-only stops too): mpv
      // drops the file and goes idle at once.
      if (await mpv.getProperty('idle-active') == 'yes') return null;
      // A frame is up once the video has a size and the seek is done.
      final w = await mpv.getProperty('video-params/w');
      final seeking = await mpv.getProperty('seeking');
      if (w.isNotEmpty && w != '0' && seeking != 'yes') {
        await mpv.command(['screenshot-to-file', out, 'video']);
        if (await target.exists() && await target.length() > 0) {
          final d = double.tryParse(await mpv.getProperty('duration')) ?? 0;
          return Thumbnail(out, Duration(milliseconds: (d * 1000).round()));
        }
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return null;
  } finally {
    // [cancelAllThumbnails] may have taken it already.
    if (_players.remove(player)) await player.dispose();
  }
}
