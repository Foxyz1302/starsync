import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';

import '../playback/playback_controller.dart';

// What the session's video view tells mpv about where it is shown: the
// size its output renders at ("Sharp video and subtitles") and how far
// bottom subtitles move up while something covers the bottom of the
// picture (the quick chat box; the control bar when chosen).

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

/// The subtitle lift moves in [liftStepCount] steps [liftStepGap] apart
/// (about 130 ms): each `sub-pos` change makes mpv re-render the
/// subtitles, and a playing video shows a change only with its next
/// frame, so a change per screen frame (60 a second against a video's 24)
/// landed unevenly and looked choppy. One step per frame of a 24 fps
/// video, eased out (most of the way in the first step), reads as one
/// quick, smooth move.
const liftStepCount = 4;
const liftStepGap = Duration(milliseconds: 42);

/// The covered heights a lift from [from] to [to] passes through, one per
/// step, eased out; the last is exactly [to]. Empty when there is nothing
/// to move.
List<double> liftSteps(double from, double to, {int count = liftStepCount}) {
  if ((to - from).abs() < 0.5) return const [];
  return [
    for (var i = 1; i <= count; i++) i == count ? to : from + (to - from) * Curves.easeOutQuad.transform(i / count),
  ];
}

/// How much of the bottom of the view is covered, as it moves: [value]
/// the covered height in logical px (0: nothing), stepping toward the
/// latest [animateTo] target ([liftSteps], [liftStepGap] apart; a new
/// target starts from where it is). mpv's `sub-pos` follows it
/// ([SubtitleLifter]), and so do the danmaku preview's mock subtitles.
class SubtitleLift extends ChangeNotifier implements ValueListenable<double> {
  double _value = 0;
  double _target = 0;
  List<double> _steps = const [];
  int _next = 0;
  Timer? _timer;

  @override
  double get value => _value;
  double get target => _target;

  /// Moves toward [target] (px); the first step at once.
  void animateTo(double target) {
    target = math.max(0, target);
    if ((target - _target).abs() < 0.5) return;
    _target = target;
    _timer?.cancel();
    _timer = null;
    _steps = liftSteps(_value, target);
    _next = 0;
    if (_steps.isEmpty) return;
    _step();
    if (_next < _steps.length) _timer = Timer.periodic(liftStepGap, (_) => _step());
  }

  void _step() {
    if (_next >= _steps.length) return;
    _value = _steps[_next++];
    if (_next >= _steps.length) {
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Bottom subtitles of the current player sit above what covers the
/// bottom of the full player ([lift]: the quick chat box, and the control
/// bar while it is up when [AppSettings.liftSubtitles] is on): mpv
/// `sub-pos` follows each step of [lift], only as far as the letterbox
/// under the picture leaves no room ([subtitleLiftPos]). Top-aligned
/// signs stay put. Draws nothing.
class SubtitleLifter extends StatefulWidget {
  final PlaybackController playback;
  final SubtitleLift lift;

  /// Only the full player lifts.
  final bool active;
  const SubtitleLifter({super.key, required this.playback, required this.lift, required this.active});

  @override
  State<SubtitleLifter> createState() => _SubtitleLifterState();
}

class _SubtitleLifterState extends State<SubtitleLifter> {
  static const _home = '100.0';
  String _sent = _home;
  HostedPlayer? _player;
  Size _view = Size.zero;
  late final void Function() _stop;

  @override
  void initState() {
    super.initState();
    widget.lift.addListener(_apply);
    // A new player starts where the file wants its subtitles.
    _stop = effect(() {
      widget.playback.generation.value;
      untracked(_apply);
    });
  }

  @override
  void didUpdateWidget(SubtitleLifter old) {
    super.didUpdateWidget(old);
    if (old.lift != widget.lift) {
      old.lift.removeListener(_apply);
      widget.lift.addListener(_apply);
    }
    if (old.active != widget.active) _apply();
  }

  @override
  void dispose() {
    widget.lift.removeListener(_apply);
    _stop();
    // Leave the player as the file wants it.
    if (_sent != _home) _send(_home);
    super.dispose();
  }

  void _apply() {
    if (!mounted) return;
    final p = widget.playback.current;
    if (!identical(p, _player)) {
      _player = p;
      _sent = _home;
    }
    final cover = widget.active ? widget.lift.value : 0.0;
    final st = p?.state;
    final pos = cover <= 0
        ? 100.0
        : subtitleLiftPos(view: _view, videoW: st?.width, videoH: st?.height, controls: cover, gap: 0);
    final v = pos.toStringAsFixed(1);
    if (v != _sent) _send(v);
  }

  void _send(String pos) {
    _sent = pos;
    final p = widget.playback.current;
    if (p == null || p.disposed) return;
    unawaited(p.setProperty('sub-pos', pos).catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        if (box.biggest != _view) {
          _view = box.biggest;
          WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
        }
        return const SizedBox.shrink();
      });
}
