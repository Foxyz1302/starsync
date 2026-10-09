import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../playback/playback_controller.dart' show PlaybackController;

/// The player's top volume (mpv's `volume-max`): past 100 % mpv amplifies.
const maxVolume = PlaybackController.maxVolume * 1.0;

/// The part of the volume bar above 100 %.
const boostColor = Color(0xFFFFB74D);

/// [volume] moved by [delta] (wheel, keys), kept within 0..[maxVolume].
double stepVolume(double volume, double delta) => (volume + delta).clamp(0.0, maxVolume);

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
    canvas.drawLine(Offset(full, y - 5), Offset(full, y + 5), Paint()
      ..color = trackColor
      ..strokeWidth = 1.5);
    if (volume > 0) canvas.drawLine(Offset(0, y), Offset(x(volume.clamp(0, 100)), y), line..color = color);
    if (volume > 100) canvas.drawLine(Offset(full, y), Offset(x(volume), y), line..color = boostColor);
    canvas.drawCircle(Offset(x(volume), y), 5, Paint()..color = volume > 100 ? boostColor : color);
  }

  @override
  bool shouldRepaint(_VolumePainter old) =>
      old.volume != volume || old.color != color || old.trackColor != trackColor;
}

/// Volume for the standard bar (instead of media_kit's, which stops at
/// 100): the icon mutes / unmutes, hovering shows a [VolumeBar], the
/// wheel steps 5 %.
class VolumeButton extends StatefulWidget {
  final Player player;
  final FocusNode? focusNode;
  const VolumeButton({super.key, required this.player, this.focusNode});

  @override
  State<VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<VolumeButton> {
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
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
                player.setVolume(stepVolume(v, e.scrollDelta.dy < 0 ? 5 : -5));
              }
            },
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
