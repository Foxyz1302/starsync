import 'dart:async';

import 'package:flutter/material.dart';

/// Follows whether media_kit's desktop controls around [child] are up,
/// by the same rule they use: up on mount and on any mouse movement,
/// down [hideAfter] later or when the mouse leaves. media_kit does not
/// expose its visibility; this lets the player draw a progress line while
/// they are down. Never takes input.
class ControlsHoverProbe extends StatefulWidget {
  final ValueNotifier<bool> shown;
  final Duration hideAfter;
  final Widget child;
  const ControlsHoverProbe({super.key, required this.shown, required this.hideAfter, required this.child});

  @override
  State<ControlsHoverProbe> createState() => _ControlsHoverProbeState();
}

class _ControlsHoverProbeState extends State<ControlsHoverProbe> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Not during this build: the line listening to [shown] may be built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _wake();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _wake() {
    widget.shown.value = true;
    _timer?.cancel();
    _timer = Timer(widget.hideAfter, _hide);
  }

  void _hide() {
    _timer?.cancel();
    if (mounted) widget.shown.value = false;
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: (_) => _wake(),
        onHover: (_) => _wake(),
        onExit: (_) => _hide(),
        child: widget.child,
      );
}
