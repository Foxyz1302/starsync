import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../shell/motion.dart';
import '../thumbnails.dart';

// Lazy poster frames for the Files page. A tile asks for its frame only
// after it has stayed on screen for a moment, so a fast scroll requests
// nothing; tiles sharing a file share one request, and the request is
// cancelled once no tile on screen wants it any more.

/// [thumbnailFor]'s shape; swapped in tests.
typedef ThumbnailLoader = Future<Thumbnail?> Function(String path, {bool Function()? cancelled});

/// A tile waits this long on screen before asking for its frame.
const thumbRequestDelay = Duration(milliseconds: 120);

/// Results of a [ThumbnailLoader] and who is waiting for them.
class ThumbCache {
  final ThumbnailLoader load;
  ThumbCache(this.load);

  final _done = <String, Thumbnail?>{};
  final _pending = <String, Future<Thumbnail?>>{};
  final _waiting = <String, int>{};

  /// Shared by every page using [thumbnailFor].
  static final shared = ThumbCache(thumbnailFor);

  bool has(String path) => _done.containsKey(path);
  Thumbnail? cached(String path) => _done[path];

  /// Pair every call with one [release].
  Future<Thumbnail?> request(String path) {
    _waiting.update(path, (n) => n + 1, ifAbsent: () => 1);
    if (_done.containsKey(path)) return Future.value(_done[path]);
    return _pending[path] ??= _start(path);
  }

  void release(String path) {
    final n = (_waiting[path] ?? 0) - 1;
    if (n > 0) {
      _waiting[path] = n;
    } else {
      _waiting.remove(path);
    }
  }

  /// Drops results, so the next request asks the loader again (rescan).
  void forget(Iterable<String> paths) {
    for (final p in paths) {
      _done.remove(p);
    }
  }

  Future<Thumbnail?> _start(String path) {
    var gaveUp = false;
    return load(path, cancelled: () => gaveUp = !_waiting.containsKey(path))
        .catchError((Object _) => null)
        .then((t) {
      if (t == null && gaveUp) {
        // Cancelled: not a result. Someone may have come back meanwhile.
        if (_waiting.containsKey(path)) return _start(path);
        _pending.remove(path);
        return null;
      }
      _pending.remove(path);
      _done[path] = t;
      return t;
    });
  }
}

/// Builds with the frame of [path] (null while loading or when there is
/// none); [loaded] is false until the request finished.
class ThumbBuilder extends StatefulWidget {
  final ThumbCache cache;
  final String path;
  final Widget Function(BuildContext context, Thumbnail? thumb, bool loaded) builder;
  const ThumbBuilder({super.key, required this.cache, required this.path, required this.builder});

  @override
  State<ThumbBuilder> createState() => _ThumbBuilderState();
}

class _ThumbBuilderState extends State<ThumbBuilder> {
  Thumbnail? _thumb;
  bool _loaded = false;
  Timer? _delay;
  // The request held right now: its path, and a token so a late answer to
  // an older request is ignored.
  String? _holding;
  Object? _token;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void didUpdateWidget(ThumbBuilder old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.cache != widget.cache) {
      _end(old.cache);
      _begin();
    }
  }

  @override
  void dispose() {
    _end(widget.cache);
    super.dispose();
  }

  void _begin() {
    final cache = widget.cache, path = widget.path;
    _loaded = cache.has(path);
    _thumb = cache.cached(path);
    if (_loaded) return;
    _delay = Timer(thumbRequestDelay, () {
      _delay = null;
      _holding = path;
      final token = _token = Object();
      cache.request(path).then((t) {
        if (_token != token) return;
        _holding = _token = null;
        cache.release(path);
        if (!mounted) return;
        setState(() {
          _thumb = t;
          _loaded = true;
        });
      });
    });
  }

  void _end(ThumbCache cache) {
    _delay?.cancel();
    _delay = null;
    final held = _holding;
    _holding = _token = null;
    if (held != null) cache.release(held);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _thumb, _loaded);
}

/// The frame, fading in over a placeholder.
class ThumbImage extends StatelessWidget {
  final Thumbnail? thumb;
  final double? width, height;
  const ThumbImage(this.thumb, {super.key, this.width, this.height});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.movie_outlined, color: scheme.onSurfaceVariant, size: 20),
    );
    final t = thumb;
    if (t == null) return placeholder;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Stack(
      fit: width == null ? StackFit.expand : StackFit.loose,
      children: [
        placeholder,
        Image.file(
          File(t.imagePath),
          width: width,
          height: height,
          fit: BoxFit.cover,
          cacheWidth: width == null ? null : (width! * dpr).round(),
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
          frameBuilder: (context, child, frame, sync) => sync
              ? child
              : AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: easeTime,
                  curve: ease,
                  child: child,
                ),
        ),
      ],
    );
  }
}

/// `1:02:03` / `24:05`.
String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// `1.4 GB` / `350 MB` / `12 KB`.
String formatSize(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
  return '${(bytes / 1024).ceil()} KB';
}

/// The frame's duration, or null when unknown (no frame, 0 length).
String? durationText(Thumbnail? t) =>
    t == null || t.duration <= Duration.zero ? null : formatDuration(t.duration);
