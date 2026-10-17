import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';

import '../playback/playback_controller.dart';
import 'motion.dart';

// What the session's video view tells mpv about where it is shown: the
// size its output renders at ("Sharp video and subtitles") and, as a dev
// experiment, how far bottom subtitles move up while the controls are up.

/// The video output's size for a view of [logical] size at [dpr]: its
/// physical pixels when [on] and video renders on the GPU, else null (the
/// video's own size). Software rendering keeps the video's size: every
/// pixel there is CPU work.
(int, int)? videoOutputSize(Size logical, double dpr, {required bool on, required RenderMode mode}) {
  if (!on || mode != RenderMode.gpu) return null;
  final w = (logical.width * dpr).round(), h = (logical.height * dpr).round();
  if (w < 16 || h < 16) return null;
  return (w, h);
}

/// How long a view size must hold before the output follows it (a
/// window drag resizes many times a second; each resize reallocates the
/// output's texture).
const outputResizeDelay = Duration(milliseconds: 180);

/// Sends the size of the view around [child] to the player host (see
/// [videoOutputSize]): at once the first time, then once a resize has
/// settled for [outputResizeDelay]. Follows the setting and the render
/// mode live.
class VideoOutputSizer extends StatefulWidget {
  final PlaybackController playback;

  /// The setting ([AppSettings.screenResVideo]).
  final ReadonlySignal<bool> sharp;
  final Widget child;
  const VideoOutputSizer({super.key, required this.playback, required this.sharp, required this.child});

  @override
  State<VideoOutputSizer> createState() => _VideoOutputSizerState();
}

class _VideoOutputSizerState extends State<VideoOutputSizer> {
  Size? _view;
  double _dpr = 1;
  Timer? _debounce;
  late final void Function() _stop;
  var _first = true;

  @override
  void initState() {
    super.initState();
    _stop = effect(() {
      widget.sharp.value;
      widget.playback.renderMode.value;
      untracked(_send);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _stop();
    super.dispose();
  }

  void _send() {
    final view = _view;
    if (view == null) return;
    final size = videoOutputSize(view, _dpr,
        on: widget.sharp.peek(), mode: widget.playback.renderMode.peek());
    widget.playback.host.setOutputSize(size?.$1, size?.$2);
  }

  void _resized(Size view, double dpr) {
    if (view == _view && dpr == _dpr) return;
    _view = view;
    _dpr = dpr;
    _debounce?.cancel();
    if (_first) {
      _first = false;
      _send();
      return;
    }
    _debounce = Timer(outputResizeDelay, _send);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, box) {
      _resized(box.biggest, dpr);
      return widget.child;
    });
  }
}

/// mpv `sub-pos` (100 = where the file puts them) that lifts bottom
/// subtitles clear of what covers the bottom of the view ([controls]
/// logical px tall: the control bar or the chat line, plus [gap]) in a [view] showing a [videoW] x [videoH] video fitted
/// inside it: only as far as the letterbox under the picture does not
/// already make room. `sub-pos` moves bottom-aligned lines by a share of
/// the picture's height; top-aligned ASS signs stay put.
double subtitleLiftPos({required Size view, int? videoW, int? videoH, required double controls, double gap = 8}) {
  if (view.height <= 0 || view.width <= 0) return 100;
  var picH = view.height;
  if (videoW != null && videoH != null && videoW > 0 && videoH > 0) {
    picH = math.min(view.height, view.width * videoH / videoW);
  }
  final bar = (view.height - picH) / 2;
  final shift = math.max(0.0, controls + gap - bar);
  return (100 - shift / picH * 100).clamp(50.0, 100.0);
}

/// Dev experiment ([AppSettings.liftSubtitles]): while something covers
/// the bottom of the full player ([cover]: its height, 0 for nothing; the
/// chat line, else the control bar while it is up), bottom subtitles of the
/// current player move above it, and back down when it goes, animated over
/// the shell's [easeTime] in mpv `sub-pos` steps. Top-aligned signs stay
/// put. Draws nothing.
class SubtitleLifter extends StatefulWidget {
  final PlaybackController playback;

  /// Fires when [cover] may have changed.
  final Listenable changes;
  final double Function() cover;

  /// The dev setting ([AppSettings.liftSubtitles]).
  final ReadonlySignal<bool> lift;

  /// Only the full player lifts.
  final bool active;
  const SubtitleLifter({
    super.key,
    required this.playback,
    required this.changes,
    required this.cover,
    required this.lift,
    required this.active,
  });

  @override
  State<SubtitleLifter> createState() => _SubtitleLifterState();
}

class _SubtitleLifterState extends State<SubtitleLifter> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: easeTime)
    ..addListener(_tick);
  double _from = 100, _to = 100;
  double _sent = 100;
  HostedPlayer? _player;
  Size _view = Size.zero;
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_retarget);
    _stop = effect(() {
      widget.lift.value;
      widget.playback.generation.value;
      untracked(_retarget);
    });
  }

  @override
  void didUpdateWidget(SubtitleLifter old) {
    super.didUpdateWidget(old);
    if (old.changes != widget.changes) {
      old.changes.removeListener(_retarget);
      widget.changes.addListener(_retarget);
    }
    _retarget();
  }

  @override
  void dispose() {
    widget.changes.removeListener(_retarget);
    _stop();
    _anim.dispose();
    // Leave the player as the file wants it.
    if (_sent != 100) _send(100);
    super.dispose();
  }

  double get _target {
    final cover = widget.cover();
    if (!widget.active || !widget.lift.peek() || cover <= 0) return 100;
    final st = widget.playback.current?.state;
    return subtitleLiftPos(view: _view, videoW: st?.width, videoH: st?.height, controls: cover);
  }

  void _retarget() {
    if (!mounted) return;
    final p = widget.playback.current;
    if (!identical(p, _player)) {
      // A new player starts where the file wants its subtitles.
      _player = p;
      _sent = 100;
      _from = _to = 100;
      _anim.value = 1;
    }
    final t = _target;
    if ((t - _to).abs() < 0.1) return;
    _from = _sent;
    _to = t;
    _anim.forward(from: 0);
  }

  void _tick() {
    final v = _from + (_to - _from) * ease.transform(_anim.value);
    // mpv redraws on every change: whole tenths are enough.
    final r = (v * 10).round() / 10;
    if (r != _sent) _send(r);
  }

  void _send(double pos) {
    _sent = pos;
    final p = widget.playback.current;
    if (p == null || p.disposed) return;
    unawaited(p.setProperty('sub-pos', pos.toStringAsFixed(1)).catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        if (box.biggest != _view) {
          _view = box.biggest;
          WidgetsBinding.instance.addPostFrameCallback((_) => _retarget());
        }
        return const SizedBox.shrink();
      });
}
