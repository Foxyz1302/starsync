import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../playback/playback_controller.dart' show PlaybackController;
import '../widgets/app_menu.dart' show AppGlass;

/// The player's top volume (mpv's `volume-max`): past 100 % mpv amplifies.
const maxVolume = PlaybackController.maxVolume * 1.0;

/// The part of the volume bar above 100 %.
const boostColor = Color(0xFFFFB74D);

/// One wheel notch or arrow key.
const volumeStep = 5.0;

/// [volume] moved by [delta] (wheel, keys), kept within 0..[maxVolume].
double stepVolume(double volume, double delta) => (volume + delta).clamp(0.0, maxVolume);

/// Turns wheel deltas into volume steps: a mouse notch (a big delta) is
/// one step, small smooth-scroll deltas add up to one. Mostly horizontal
/// scrolls (Shift+wheel, sideways pans) are no steps.
class WheelSteps {
  // Flutter makes a notch 53 px on Linux, 60 on Windows (3 lines).
  static const _notch = 50.0;
  double _sum = 0;

  /// Whether [e] is a vertical scroll (the only kind that steps).
  static bool vertical(PointerSignalEvent e) =>
      e is PointerScrollEvent && e.scrollDelta.dy != 0 && e.scrollDelta.dy.abs() > e.scrollDelta.dx.abs();

  /// +1 louder (wheel up), -1 quieter, 0 not a step yet.
  int take(PointerScrollEvent e) {
    final dy = e.scrollDelta.dy;
    if (dy.abs() >= _notch) {
      _sum = 0;
      return dy < 0 ? 1 : -1;
    }
    if (_sum != 0 && _sum.sign != dy.sign) _sum = 0;
    _sum += dy;
    if (_sum.abs() < _notch) return 0;
    final step = _sum < 0 ? 1 : -1;
    _sum = 0;
    return step;
  }

  /// Claims [e] if it is a vertical scroll that nothing under the mouse
  /// claimed first (a list, a menu), then calls [onStep] per step.
  void handle(PointerSignalEvent e, ValueChanged<int> onStep) {
    if (!vertical(e)) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      final step = take(event as PointerScrollEvent);
      if (step != 0) onStep(step);
    });
  }
}

/// The wheel anywhere over [child] steps the volume ([onStep]: +1 / -1),
/// unless something under the mouse scrolls (it claims the event first)
/// or [enabled] is off.
class VolumeWheel extends StatefulWidget {
  final ValueChanged<int> onStep;
  final bool enabled;
  final Widget child;
  const VolumeWheel({super.key, required this.onStep, this.enabled = true, required this.child});

  @override
  State<VolumeWheel> createState() => _VolumeWheelState();
}

class _VolumeWheelState extends State<VolumeWheel> {
  final _steps = WheelSteps();

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (e) {
      if (widget.enabled) _steps.handle(e, widget.onStep);
    },
    child: widget.child,
  );
}

/// Shows [builder] for a second after each [trigger] tick (a wheel or
/// key volume step), fading in and out; ignores the mouse.
class VolumeFlash extends StatefulWidget {
  final ValueListenable<int> trigger;
  final WidgetBuilder builder;
  const VolumeFlash({super.key, required this.trigger, required this.builder});

  /// uosc's `flash_duration`.
  static const hold = Duration(seconds: 1);

  @override
  State<VolumeFlash> createState() => _VolumeFlashState();
}

class _VolumeFlashState extends State<VolumeFlash> {
  bool _on = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.trigger.addListener(_flash);
  }

  @override
  void didUpdateWidget(VolumeFlash old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) {
      old.trigger.removeListener(_flash);
      widget.trigger.addListener(_flash);
    }
  }

  @override
  void dispose() {
    widget.trigger.removeListener(_flash);
    _timer?.cancel();
    super.dispose();
  }

  void _flash() {
    if (!mounted) return;
    setState(() => _on = true);
    _timer?.cancel();
    _timer = Timer(VolumeFlash.hold, () {
      if (mounted) setState(() => _on = false);
    });
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: _on ? 1 : 0,
      child: _on || _timer != null ? widget.builder(context) : const SizedBox.shrink(),
    ),
  );
}

/// The standard design's volume readout for [VolumeFlash]: a glass pill
/// (the player's pill look) with the icon, a [VolumeBar] and the
/// percentage.
class VolumeReadout extends StatelessWidget {
  final double volume;
  const VolumeReadout({super.key, required this.volume});

  @override
  Widget build(BuildContext context) {
    final v = volume.clamp(0.0, maxVolume);
    return AppGlass.pill(
      key: const ValueKey('volume-readout'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 14, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              v <= 0 ? Icons.volume_off : (v < 50 ? Icons.volume_down : Icons.volume_up),
              size: 20,
              color: v > 100 ? boostColor : Colors.white,
            ),
            const SizedBox(width: 8),
            VolumeBar(volume: v, onChanged: (_) {}, width: 96),
            const SizedBox(width: 10),
            SizedBox(
              width: 44,
              child: Text(
                '${v.round()} %',
                textAlign: TextAlign.right,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A thin volume track over 0..[maxVolume]: filled up to the volume, the
/// part above 100 % in [boostColor], a tick at 100 %. Click or drag sets
/// it.
class VolumeBar extends StatelessWidget {
  final double volume;
  final ValueChanged<double> onChanged;
  final double width;
  final Color color;
  final Color trackColor;
  const VolumeBar({
    super.key,
    required this.volume,
    required this.onChanged,
    this.width = 64,
    this.color = Colors.white,
    this.trackColor = Colors.white30,
  });

  @override
  Widget build(BuildContext context) {
    void at(double x) => onChanged((x / width * maxVolume).clamp(0.0, maxVolume).roundToDouble());
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (e) => at(e.localPosition.dx),
      onHorizontalDragUpdate: (e) => at(e.localPosition.dx),
      child: SizedBox(
        width: width,
        height: 24,
        child: CustomPaint(painter: _VolumePainter(volume.clamp(0.0, maxVolume), color, trackColor)),
      ),
    );
  }
}

class _VolumePainter extends CustomPainter {
  final double volume;
  final Color color, trackColor;
  _VolumePainter(this.volume, this.color, this.trackColor);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    double x(double v) => size.width * v / maxVolume;
    final line = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), line..color = trackColor);
    final full = x(100);
    canvas.drawLine(
      Offset(full, y - 5),
      Offset(full, y + 5),
      Paint()
        ..color = trackColor
        ..strokeWidth = 1.5,
    );
    if (volume > 0) canvas.drawLine(Offset(0, y), Offset(x(volume.clamp(0, 100)), y), line..color = color);
    if (volume > 100) canvas.drawLine(Offset(full, y), Offset(x(volume), y), line..color = boostColor);
    canvas.drawCircle(Offset(x(volume), y), 5, Paint()..color = volume > 100 ? boostColor : color);
  }

  @override
  bool shouldRepaint(_VolumePainter old) => old.volume != volume || old.color != color || old.trackColor != trackColor;
}

/// Volume for the standard bar (instead of media_kit's, which stops at
/// 100): the icon mutes / unmutes, hovering shows a [VolumeBar], the
/// wheel steps [volumeStep].
class VolumeButton extends StatefulWidget {
  final Player player;
  final FocusNode? focusNode;
  const VolumeButton({super.key, required this.player, this.focusNode});

  @override
  State<VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<VolumeButton> {
  final _steps = WheelSteps();
  bool _hover = false;
  double _beforeMute = 100;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return StreamBuilder<double>(
      stream: player.stream.volume,
      initialData: player.state.volume,
      builder: (context, snap) {
        final v = snap.data ?? 100;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Listener(
            // Claimed here, so the player's own wheel handler skips it.
            onPointerSignal: (e) =>
                _steps.handle(e, (step) => player.setVolume(stepVolume(player.state.volume, step * volumeStep))),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('volume-button'),
                  focusNode: widget.focusNode,
                  tooltip: 'Volume ${v.round()} %',
                  iconSize: 22,
                  color: Colors.white,
                  onPressed: () {
                    if (v > 0) {
                      _beforeMute = v;
                      player.setVolume(0);
                    } else {
                      player.setVolume(_beforeMute <= 0 ? 100 : _beforeMute);
                    }
                  },
                  icon: Icon(v <= 0 ? Icons.volume_off : (v < 50 ? Icons.volume_down : Icons.volume_up)),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 150),
                  child: _hover
                      ? Padding(
                          padding: const EdgeInsets.only(left: 4, right: 12),
                          child: VolumeBar(volume: v, onChanged: player.setVolume),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
