import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';

import 'controls_probe.dart' show ControlsHold;

// The frame both control skins live in: when the controls are up, and the
// double-click on the picture. Mouse movement shows them; [hideAfter]
// without any (or the mouse leaving) hides them and the cursor. Holds keep
// them up: a seek drag (no hover events arrive), an open menu (a route
// takes the mouse), and the session's [ControlsHold] (the mouse on a
// floating pill or card, the Up next popover). Only real mouse movement
// wakes them: a widget appearing or going under a still pointer (the
// quick chat box) does not, nor does typing. [ControlsFrame.suppress]
// hides them while something takes their place (the quick chat box).

class ControlsFrame extends StatefulWidget {
  /// Draws the controls; [visible] false while they are hidden.
  final Widget Function(BuildContext context, bool visible) builder;
  final VoidCallback? onDoubleClick;

  /// Bands at the top and bottom where a double-click is the bars', not
  /// the picture's.
  final double barTop;
  final double barBottom;
  final Duration hideAfter;

  /// Follows whether the controls are up (for overlays outside them).
  final ValueNotifier<bool>? shown;

  /// Keeps them up while held.
  final ControlsHold? holdBy;

  /// While true the controls are drawn hidden and [shown] says so; the
  /// cursor still follows the mouse. They come back as they would have
  /// been once it is false again.
  final ValueListenable<bool>? suppress;
  const ControlsFrame({
    super.key,
    required this.builder,
    this.onDoubleClick,
    this.barTop = 0,
    this.barBottom = 0,
    this.hideAfter = const Duration(seconds: 3),
    this.shown,
    this.holdBy,
    this.suppress,
  });

  /// The frame around [context], for widgets that keep it up (a drag, a
  /// menu).
  static ControlsFrameState? maybeOf(BuildContext context) => context.findAncestorStateOfType<ControlsFrameState>();

  /// Runs [open] (a menu, a popover) with the controls around [context]
  /// held up, if there are any.
  static Future<T> holdWhile<T>(BuildContext context, Future<T> Function() open) {
    final frame = maybeOf(context);
    return frame == null ? open() : frame.holdDuring(open);
  }

  /// The fade of the controls.
  static const fade = Duration(milliseconds: 150);

  @override
  State<ControlsFrame> createState() => ControlsFrameState();
}

class ControlsFrameState extends State<ControlsFrame> {
  bool _visible = true;
  int _holds = 0;
  bool _heldBy = false;
  Timer? _timer;
  // Where the mouse was last seen, to tell real movement from a widget
  // appearing or going under it.
  Offset? _lastPos;

  bool get _suppressed => widget.suppress?.value ?? false;

  /// The controls are drawn (up and not suppressed).
  bool get visible => _visible && !_suppressed;

  @override
  void initState() {
    super.initState();
    widget.holdBy?.addListener(_holdByChanged);
    widget.suppress?.addListener(_suppressChanged);
    // Not during this build: an overlay listening to [shown] may be built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.shown?.value = visible;
    });
    _hideLater();
  }

  @override
  void didUpdateWidget(ControlsFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.holdBy != widget.holdBy) {
      oldWidget.holdBy?.removeListener(_holdByChanged);
      widget.holdBy?.addListener(_holdByChanged);
      _holdByChanged();
    }
    if (oldWidget.suppress != widget.suppress) {
      oldWidget.suppress?.removeListener(_suppressChanged);
      widget.suppress?.addListener(_suppressChanged);
    }
    if (oldWidget.hideAfter != widget.hideAfter && _visible) _hideLater();
  }

  @override
  void dispose() {
    widget.holdBy?.removeListener(_holdByChanged);
    widget.suppress?.removeListener(_suppressChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _holdByChanged() {
    final on = widget.holdBy?.held ?? false;
    if (on == _heldBy || !mounted) return;
    _heldBy = on;
    hold(on);
  }

  void _suppressChanged() {
    if (!mounted) return;
    setState(() {});
    widget.shown?.value = visible;
  }

  /// Show the controls and restart the hide countdown.
  void wake() {
    if (!_visible && mounted) {
      setState(() => _visible = true);
      widget.shown?.value = visible;
    }
    _hideLater();
  }

  /// A hover or enter at [pos]: wakes only when the mouse really moved.
  void _moved(Offset pos) {
    final last = _lastPos;
    _lastPos = pos;
    if (last != null && (pos - last).distance < 0.5) return;
    wake();
  }

  /// Keep the controls up while [on] (paired calls).
  void hold(bool on) {
    _holds = on ? _holds + 1 : (_holds - 1).clamp(0, 1 << 20);
    wake();
  }

  /// Runs [open] (a menu) with the controls held up.
  Future<T> holdDuring<T>(Future<T> Function() open) async {
    hold(true);
    try {
      return await open();
    } finally {
      if (mounted) hold(false);
    }
  }

  void _hideLater() {
    _timer?.cancel();
    _timer = Timer(widget.hideAfter, _hide);
  }

  void _hide() {
    if (!mounted || _holds > 0 || !_visible) return;
    setState(() => _visible = false);
    widget.shown?.value = false;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      onEnter: (e) => _moved(e.position),
      onHover: (e) => _moved(e.position),
      onExit: (e) {
        _lastPos = e.position;
        _timer?.cancel();
        _hide();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.onDoubleClick != null)
            Positioned.fill(
              child: DoubleClickListener(
                onDoubleClick: widget.onDoubleClick!,
                skipTop: visible ? widget.barTop : 0,
                skipBottom: visible ? widget.barBottom : 0,
                child: const ColoredBox(color: Color(0x00000000), child: SizedBox.expand()),
              ),
            ),
          widget.builder(context, visible),
        ],
      ),
    );
  }
}

/// Double-click on the picture (not on the bars) without joining the
/// gesture arena, so single clicks on buttons stay instant.
class DoubleClickListener extends StatefulWidget {
  final VoidCallback onDoubleClick;
  final double skipTop, skipBottom;
  final Widget child;
  const DoubleClickListener({
    super.key,
    required this.onDoubleClick,
    this.skipTop = 0,
    this.skipBottom = 0,
    required this.child,
  });

  @override
  State<DoubleClickListener> createState() => _DoubleClickListenerState();
}

class _DoubleClickListenerState extends State<DoubleClickListener> {
  DateTime? _last;
  Offset? _lastAt;

  void _down(PointerDownEvent e) {
    if (e.buttons != kPrimaryMouseButton) return;
    final h = context.size?.height ?? 0;
    final y = e.localPosition.dy;
    if (y < widget.skipTop || y > h - widget.skipBottom) {
      _last = null;
      return;
    }
    final now = DateTime.now();
    final last = _last, at = _lastAt;
    if (last != null &&
        at != null &&
        now.difference(last) < const Duration(milliseconds: 400) &&
        (e.localPosition - at).distance < 24) {
      _last = null;
      widget.onDoubleClick();
      return;
    }
    _last = now;
    _lastAt = e.localPosition;
  }

  @override
  Widget build(BuildContext context) =>
      Listener(behavior: HitTestBehavior.translucent, onPointerDown: _down, child: widget.child);
}
