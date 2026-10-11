import 'dart:async';

import 'package:flutter/material.dart';

/// What keeps the player's controls up besides the mouse on them: the
/// mouse on a floating element over the picture (a pill, a card, the
/// status pill: [ControlsHoldRegion]) or an open popover. While anything
/// holds, the controls stay up; on release they hide on their usual
/// countdown. Both designs follow it ([ControlsHoverProbe] with
/// media_kit's controls, `UoscControls`).
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

/// Follows whether media_kit's desktop controls around [child] are up,
/// by the same rule they use: up on mount and on any mouse movement,
/// down [hideAfter] later or when the mouse leaves. media_kit does not
/// expose its visibility; this lets the player draw a progress line while
/// they are down. With [hold] held it keeps them (and itself) up. Never
/// takes input.
class ControlsHoverProbe extends StatefulWidget {
  final ValueNotifier<bool> shown;
  final Duration hideAfter;
  final ControlsHold? hold;
  final Widget child;
  const ControlsHoverProbe(
      {super.key, required this.shown, required this.hideAfter, this.hold, required this.child});

  @override
  State<ControlsHoverProbe> createState() => _ControlsHoverProbeState();
}

class _ControlsHoverProbeState extends State<ControlsHoverProbe> {
  Timer? _timer;
  // While held: media_kit's own countdown is restarted before it ends.
  Timer? _keep;

  bool get _held => widget.hold?.held ?? false;

  @override
  void initState() {
    super.initState();
    widget.hold?.addListener(_holdChanged);
    // Not during this build: the line listening to [shown] may be built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _wake();
    });
  }

  @override
  void didUpdateWidget(ControlsHoverProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hold != widget.hold) {
      oldWidget.hold?.removeListener(_holdChanged);
      widget.hold?.addListener(_holdChanged);
      _holdChanged();
    }
  }

  @override
  void dispose() {
    widget.hold?.removeListener(_holdChanged);
    _timer?.cancel();
    _keep?.cancel();
    super.dispose();
  }

  void _holdChanged() {
    if (!mounted) return;
    _keep?.cancel();
    _keep = null;
    if (_held) {
      _keep = Timer.periodic(widget.hideAfter * 0.5, (_) => _pokeControls());
    }
    _pokeControls();
    _wake();
  }

  /// media_kit's controls state is private: a guarded dynamic call to its
  /// hover handler, as a mouse movement on it would make.
  void _pokeControls() {
    if (!mounted) return;
    void visit(Element e) {
      if (e is StatefulElement && e.state.runtimeType.toString() == '_MaterialDesktopVideoControlsState') {
        try {
          (e.state as dynamic).onHover();
        } catch (_) {}
        return;
      }
      e.visitChildElements(visit);
    }

    context.visitChildElements(visit);
  }

  void _wake() {
    widget.shown.value = true;
    _timer?.cancel();
    _timer = Timer(widget.hideAfter, _hide);
  }

  void _hide() {
    _timer?.cancel();
    if (!mounted || _held) return;
    widget.shown.value = false;
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: (_) => _wake(),
        onHover: (_) => _wake(),
        // Held (the mouse went onto a pill or the popover): media_kit's
        // controls just hid on their own exit; bring them straight back.
        onExit: (_) => _held ? _pokeControls() : _hide(),
        child: widget.child,
      );
}
