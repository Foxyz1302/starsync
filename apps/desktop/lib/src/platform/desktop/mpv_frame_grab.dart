import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show StringUtf8Pointer, Utf8, Utf8Pointer, calloc;
import 'package:media_kit/generated/libmpv/bindings.dart';
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart' show NativeLibrary;

import '../ports/player_host.dart' show FrameGrab, RawFrame;

// A screenshot straight from mpv (`screenshot-raw`) on a short-lived
// isolate, so neither mpv's work nor the pixel copy holds the UI thread.
// Not media_kit's `Player.screenshot`: that one holds the player's lock
// (the session's play, pause and seek wait meanwhile), takes one mode per
// call and hands back raw pixels without their size. The player host
// makes a dispose wait for a grab under way, since media_kit destroys the
// mpv handle as its dispose ends.
//
// mpv answers with the frame on screen at the video's display size: the
// decoded picture scaled for its aspect, and with `subtitles` the
// subtitles drawn into it at that size. media_kit's render context gives
// mpv no render-thread access (no MPV_RENDER_PARAM_ADVANCED_CONTROL), so
// mpv takes its software path ("Falling back to software screenshot"):
// the picture before the video output's shaders, never upscaled. On mpv
// 0.41 that path fails for a GPU decoder's frame (hwdec without -copy:
// "Input image format cuda not supported"); the caller then decodes the
// frame again (`decodeStillFrame`).

/// Both copies of the frame on screen from the mpv handle at [ctx]: the
/// one with subtitles first (when [subtitles]), then the clean one, back
/// to back. Null when mpv has no picture.
Future<FrameGrab?> grabMpvFrame(int ctx, {required bool subtitles}) {
  final lib = NativeLibrary.path;
  return Isolate.run(() => _grab(ctx, lib, subtitles), debugName: 'screenshot');
}

FrameGrab? _grab(int ctx, String lib, bool subtitles) {
  final mpv = MPV(DynamicLibrary.open(lib));
  final handle = Pointer<mpv_handle>.fromAddress(ctx);
  final subs = subtitles ? _shot(mpv, handle, 'subtitles') : null;
  final clean = _shot(mpv, handle, 'video');
  if (clean == null) return null;
  return (clean: clean, subs: subs);
}

/// One `screenshot-raw <mode>`: mpv's `bgr0` rows (w, h, stride) as
/// tight, opaque RGBA.
RawFrame? _shot(MPV mpv, Pointer<mpv_handle> handle, String mode) {
  final words = ['screenshot-raw', mode];
  final args = calloc<Pointer<Utf8>>(words.length + 1);
  final strings = [for (final w in words) w.toNativeUtf8()];
  for (var i = 0; i < strings.length; i++) {
    args[i] = strings[i];
  }
  final result = calloc<mpv_node>();
  try {
    final err = mpv.mpv_command_ret(handle, args.cast(), result);
    if (err < 0) throw StateError('screenshot-raw $mode: mpv error $err');
    if (result.ref.format != mpv_format.MPV_FORMAT_NODE_MAP) {
      throw StateError('screenshot-raw $mode: got format ${result.ref.format}');
    }
    int? w, h, stride;
    Uint8List? data;
    final map = result.ref.u.list.ref;
    for (var i = 0; i < map.num; i++) {
      final key = map.keys[i].cast<Utf8>().toDartString();
      final value = map.values[i];
      if (value.format == mpv_format.MPV_FORMAT_INT64) {
        switch (key) {
          case 'w':
            w = value.u.int64;
          case 'h':
            h = value.u.int64;
          case 'stride':
            stride = value.u.int64;
        }
      } else if (value.format == mpv_format.MPV_FORMAT_BYTE_ARRAY && key == 'data') {
        final ba = value.u.ba.ref;
        data = ba.data.cast<Uint8>().asTypedList(ba.size);
      }
    }
    if (w == null || h == null || stride == null || data == null || w <= 0 || h <= 0) return null;
    if (stride < w * 4 || data.length < stride * (h - 1) + w * 4) return null;
    return RawFrame(bgr0ToRgba(data, w, h, stride), w, h);
  } finally {
    mpv.mpv_free_node_contents(result);
    calloc.free(result);
    for (final s in strings) {
      calloc.free(s);
    }
    calloc.free(args);
  }
}

/// mpv's `bgr0` rows ([stride] bytes apart, the fourth byte unset) as
/// tight RGBA, alpha 255.
Uint8List bgr0ToRgba(Uint8List src, int w, int h, int stride) {
  final out = Uint8List(w * h * 4);
  var o = 0;
  for (var y = 0; y < h; y++) {
    var i = y * stride;
    final end = i + w * 4;
    while (i < end) {
      out[o] = src[i + 2];
      out[o + 1] = src[i + 1];
      out[o + 2] = src[i];
      out[o + 3] = 255;
      i += 4;
      o += 4;
    }
  }
  return out;
}
