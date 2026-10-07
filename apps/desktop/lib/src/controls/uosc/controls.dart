import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/settings.dart';

// The experimental mpv-style (uosc) controls frame: a full-width timeline
// at the bottom with a row of flat buttons above it, window buttons top
// right. Mouse movement shows them; after [UoscControls.hideAfter] without
// any they fade out, the timeline shrinks to a thin line and the cursor
// hides. Everything lives here because media_kit's fullscreen route
// renders only the video and its controls.

class UoscControls extends StatefulWidget {
  /// The timeline; [expanded] is false while the controls are hidden.
  final Widget Function(BuildContext context, bool expanded) timeline;
  /// Buttons left and right of the row above the timeline.
  final List<Widget> left;
  final List<Widget> right;
  /// Top-right corner (window buttons), shown with the controls.
  final Widget? top;
  final VoidCallback? onDoubleTap;
  final Duration hideAfter;
  const UoscControls({
    super.key,
    required this.timeline,
    this.left = const [],
    this.right = const [],
    this.top,
    this.onDoubleTap,
    this.hideAfter = const Duration(seconds: 3),
  });

  static const buttonRowHeight = 40.0;

  /// The controls around [context], for widgets that need them kept up
  /// (a timeline drag, an open menu).
  static UoscControlsState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<UoscControlsState>();

  @override
  State<UoscControls> createState() => UoscControlsState();
}

class UoscControlsState extends State<UoscControls> {
  bool _visible = true;
  int _holds = 0;
  Timer? _timer;

  bool get visible => _visible;

  @override
  void initState() {
    super.initState();
    _hideLater();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Show the controls and restart the hide countdown.
  void wake() {
    if (!_visible && mounted) setState(() => _visible = true);
    _hideLater();
  }

  /// Keep the controls up while [on] (paired calls): a drag sends no
  /// hover events and a menu route takes the mouse.
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
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    const fade = Duration(milliseconds: 150);
    return MouseRegion(
      cursor: visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      onEnter: (_) => wake(),
      onHover: (_) => wake(),
      onExit: (_) {
        _timer?.cancel();
        _hide();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: widget.onDoubleTap,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 160,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: fade,
                opacity: visible ? 1 : 0,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0x8C000000)],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.top != null)
            Positioned(
              top: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(duration: fade, opacity: visible ? 1 : 0, child: widget.top),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IgnorePointer(
                  key: const ValueKey('uosc-buttons'),
                  ignoring: !visible,
                  child: AnimatedOpacity(
                    duration: fade,
                    opacity: visible ? 1 : 0,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                      child: SizedBox(
                        height: UoscControls.buttonRowHeight,
                        child: Row(children: [...widget.left, const Spacer(), ...widget.right]),
                      ),
                    ),
                  ),
                ),
                widget.timeline(context, visible),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The session's controls: media_kit's ([material]) or, with Settings →
/// "Experimental: mpv-style controls", the uosc ones ([mpv]). Switches
/// live when the setting changes.
class SessionControlsSwitch extends StatelessWidget {
  final WidgetBuilder material;
  final WidgetBuilder mpv;
  const SessionControlsSwitch({super.key, required this.material, required this.mpv});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) =>
          AppSettings.instance.mpvControls.value ? mpv(context) : material(context),
    );
  }
}
