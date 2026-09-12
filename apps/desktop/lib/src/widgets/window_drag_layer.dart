import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

typedef ExclusionZone = Rect Function(Size);

class WindowDragLayer extends StatefulWidget {
  final bool enabled;
  final List<ExclusionZone> exclusions;
  const WindowDragLayer({
    super.key,
    this.enabled = true,
    this.exclusions = const [],
  });

  @override
  State<WindowDragLayer> createState() => _WindowDragLayerState();
}

class _WindowDragLayerState extends State<WindowDragLayer> {
  int? _armedPointer;
  Offset? _downPos;
  bool _dragging = false;

  void _onDown(PointerDownEvent e) {
    if (!widget.enabled) return;
    _armedPointer = e.pointer;
    _downPos = e.position;
    _dragging = false;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _armedPointer || _dragging) return;
    final down = _downPos;
    if (down == null) return;
    if ((e.position - down).distance < kTouchSlop) return;
    final size = context.size;
    if (size != null) {
      for (final zone in widget.exclusions) {
        if (zone(size).contains(down)) {
          _armedPointer = null;
          return;
        }
      }
    }
    _dragging = true;
    windowManager.startDragging();
  }

  void _onEnd(PointerEvent e) {
    if (e.pointer == _armedPointer) {
      _armedPointer = null;
      _dragging = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onEnd,
      onPointerCancel: _onEnd,
      child: const SizedBox.expand(),
    );
  }
}
