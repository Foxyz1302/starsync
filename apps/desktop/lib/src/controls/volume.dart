import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

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

  /// How long the readout stays after the last step.
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

/// The volume readout for [VolumeFlash] (both skins): a glass pill
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
            Icon(volumeIcon(v), size: 20, color: v > 100 ? boostColor : Colors.white),
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

/// The speaker icon for [volume].
IconData volumeIcon(double volume) =>
    volume <= 0 ? Icons.volume_off_rounded : (volume < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded);

/// Builds a skin's button for the [VolumeControl].
typedef VolumeButtonBuilder = Widget Function(
  BuildContext context,
  IconData icon,
  Color? color,
  String tooltip,
  VoidCallback onPressed,
);

/// The bar's volume slider at full width, and with its gaps.
const volumeSliderWidth = 72.0;
const _sliderGaps = 4.0 + 8;

/// Where a bar [width] wide puts the volume slider, given its [buttons]
/// buttons of [button] each and [fixed] other room (the clock, paddings,
/// a gap between the clusters): beside the speaker when it fits
/// ([always]), else sliding out on hover as wide as the room left
/// ([width] 0: none, the wheel, keys and the panel still set it).
({bool always, double width}) volumeSliderRoom(
    {required double width, required int buttons, required double button, double fixed = 0}) {
  final spare = width - buttons * button - fixed - _sliderGaps;
  if (spare >= volumeSliderWidth) return (always: true, width: volumeSliderWidth);
  return (always: false, width: spare < 32 ? 0 : spare);
}

/// The speaker's tooltip at [volume].
String volumeTooltip(double volume) => 'Volume ${volume.round()} %  (M mutes, scroll, ↑ / ↓)';

/// The bar's volume, in both skins: the skin's speaker button (click
/// mutes / unmutes) and a [VolumeBar] beside it, always when the bar has
/// room, else sliding out while the mouse is on it (see
/// [volumeSliderRoom]); the wheel on it steps [volumeStep] (claimed, so
/// the player's wheel skips it).
class VolumeControl extends StatefulWidget {
  /// 0..[maxVolume].
  final double volume;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;
  final VolumeButtonBuilder button;
  final Color sliderColor;
  final Color trackColor;

  /// Where the slider goes ([volumeSliderRoom]); full width beside the
  /// speaker by default.
  final ({bool always, double width}) slider;
  const VolumeControl({
    super.key,
    required this.volume,
    required this.onChanged,
    required this.onToggleMute,
    required this.button,
    this.sliderColor = Colors.white,
    this.trackColor = Colors.white30,
    this.slider = (always: true, width: volumeSliderWidth),
  });

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  final _steps = WheelSteps();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.volume;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerSignal: (e) => _steps.handle(e, (step) => widget.onChanged(stepVolume(v, step * volumeStep))),
        child: Row(
          key: const ValueKey('volume-control'),
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.button(
              context,
              volumeIcon(v),
              v > 100 ? boostColor : null,
              volumeTooltip(v),
              widget.onToggleMute,
            ),
            // Only the hover slides; the bar growing past or below the
            // room for the slider switches it without a slide (no
            // overflow while it would shrink).
            AnimatedSize(
              key: ValueKey(widget.slider.always),
              duration: const Duration(milliseconds: 150),
              child: widget.slider.width > 0 && (widget.slider.always || _hover)
                  ? Padding(
                      padding: const EdgeInsets.only(left: 4, right: 8),
                      child: VolumeBar(
                        key: const ValueKey('volume-bar'),
                        volume: v,
                        onChanged: widget.onChanged,
                        width: widget.slider.width,
                        color: widget.sliderColor,
                        trackColor: widget.trackColor,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
