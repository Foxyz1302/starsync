import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

// Linux: what a player's mpv threads free stays in glibc's malloc arenas
// after the player is gone (tens of MiB per player, never reused in
// full), so the app's memory only grew with every video. glibc's
// `malloc_trim(0)` hands the free pages back.

typedef _TrimC = Int Function(Size pad);
typedef _TrimD = int Function(int pad);

final _TrimD? _mallocTrim = () {
  if (!Platform.isLinux) return null;
  try {
    final libc = DynamicLibrary.process();
    if (!libc.providesSymbol('malloc_trim')) return null;
    return libc.lookupFunction<_TrimC, _TrimD>('malloc_trim');
  } catch (e, st) {
    debugPrint('malloc_trim unavailable: $e\n$st');
    return null;
  }
}();

Timer? _trim;

/// Trims the native heap [after] from now (Linux with glibc; nothing
/// elsewhere). A call before then moves it later: a run of disposals
/// (a folder's thumbnails) ends in one trim.
void trimNativeHeapSoon({Duration after = const Duration(seconds: 6)}) {
  final trim = _mallocTrim;
  if (trim == null) return;
  _trim?.cancel();
  _trim = Timer(after, () {
    _trim = null;
    final sw = Stopwatch()..start();
    try {
      trim(0);
    } catch (e, st) {
      debugPrint('malloc_trim failed: $e\n$st');
    }
    if (sw.elapsedMilliseconds > 20) debugPrint('native heap trimmed in ${sw.elapsedMilliseconds} ms');
  });
}
