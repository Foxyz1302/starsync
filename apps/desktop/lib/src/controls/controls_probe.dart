import 'dart:async';

import 'package:flutter/material.dart';

/// What keeps the player's controls up besides the mouse on them: the
/// mouse on a floating element over the picture (a pill, a card, the
/// status pill: [ControlsHoldRegion]) or an open popover. While anything
/// holds, the controls stay up; on release they hide on their usual
/// countdown. Both skins follow it (through `ControlsFrame`).
class ControlsHold extends ChangeNotifier {
  final _by = <Object>{};
  bool _told = false;
  bool _queued = false;
  bool _disposed = false;

  bool get held => _told;

  /// [who] holds ([on]) or lets go. Listeners hear it in a microtask, never
  /// during a build or a dispose.
  void set(Object who, bool on) {
    if (on ? !_by.add(who) : !_by.remove(who)) return;
    if (_queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (_disposed) return;
      final now = _by.isNotEmpty;
      if (now == _told) return;
      _told = now;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The mouse on [child] counts as the mouse on the controls: it holds
/// [hold] while it is there.
class ControlsHoldRegion extends StatefulWidget {
  final ControlsHold? hold;
  final Widget child;
  const ControlsHoldRegion({super.key, required this.hold, required this.child});

  @override
  State<ControlsHoldRegion> createState() => _ControlsHoldRegionState();
}

class _ControlsHoldRegionState extends State<ControlsHoldRegion> {
  @override
  void didUpdateWidget(ControlsHoldRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hold != widget.hold) oldWidget.hold?.set(this, false);
  }

  @override
  void dispose() {
    widget.hold?.set(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hold = widget.hold;
    if (hold == null) return widget.child;
    return MouseRegion(
      onEnter: (_) => hold.set(this, true),
      onExit: (_) => hold.set(this, false),
      child: widget.child,
    );
  }
}
