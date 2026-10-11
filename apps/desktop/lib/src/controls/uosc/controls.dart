import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../state/settings.dart';
import '../controls_probe.dart' show ControlsHold;

// The mpv-style (uosc) controls frame: a full-width timeline at the
// bottom with a row of flat buttons above it, the title top left and a
// corner widget top right.
// Mouse movement shows them; after [UoscControls.hideAfter] without any
// they fade out, the timeline shrinks to a 2 px line (gone when "Progress
// line when hidden" is off) and the cursor hides. Our own frame: no
// media_kit controls state to reach into.

class UoscControls extends StatefulWidget {
  /// The timeline; [expanded] is false while the controls are hidden.
  final Widget Function(BuildContext context, bool expanded) timeline;
  /// Buttons left and right of the row above the timeline.
  final List<Widget> left;
  final List<Widget> right;
  /// Top-right corner (chat, back to the library), shown with the controls.
  final Widget? top;
  /// Top left (what is playing), shown with the controls; gets the width
  /// [top] leaves.
  final Widget? topLeft;
  final VoidCallback? onDoubleTap;
  final Duration hideAfter;
  /// Follows whether the controls are up (for overlays outside them).
  final ValueNotifier<bool>? shown;
  /// Keeps them up while held (the mouse on an overlay, an open popover).
  final ControlsHold? holdBy;
  const UoscControls({
    super.key,
    required this.timeline,
    this.left = const [],
    this.right = const [],
    this.top,
    this.topLeft,
    this.onDoubleTap,
    this.hideAfter = const Duration(seconds: 3),
    this.shown,
    this.holdBy,
  });

  static const buttonRowHeight = 40.0;
  /// Under the button row, above the timeline.
  static const rowBottomPadding = 4.0;

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
  bool _heldBy = false;
  Timer? _timer;

  bool get visible => _visible;

  @override
  void initState() {
    super.initState();
    widget.holdBy?.addListener(_holdByChanged);
    // Not during this build: an overlay listening to [shown] may be built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.shown?.value = true;
    });
    _hideLater();
  }

  @override
  void didUpdateWidget(UoscControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.holdBy != widget.holdBy) {
      oldWidget.holdBy?.removeListener(_holdByChanged);
      widget.holdBy?.addListener(_holdByChanged);
      _holdByChanged();
    }
  }

  @override
  void dispose() {
    widget.holdBy?.removeListener(_holdByChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _holdByChanged() {
    final on = widget.holdBy?.held ?? false;
    if (on == _heldBy || !mounted) return;
    _heldBy = on;
    hold(on);
  }

  /// Show the controls and restart the hide countdown.
  void wake() {
    if (!_visible && mounted) {
      setState(() => _visible = true);
      widget.shown?.value = true;
    }
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
    widget.shown?.value = false;
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
          if (widget.topLeft != null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 120,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: fade,
                  opacity: visible ? 1 : 0,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x8C000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.top != null || widget.topLeft != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                key: const ValueKey('uosc-top'),
                ignoring: !visible,
                child: AnimatedOpacity(
                  duration: fade,
                  opacity: visible ? 1 : 0,
                  // The buttons centred on the title, like the standard
                  // design's top bar.
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: widget.topLeft == null
                              ? const SizedBox.shrink()
                              : Align(alignment: AlignmentDirectional.centerStart, child: widget.topLeft),
                        ),
                      ),
                      if (widget.top != null)
                        Padding(padding: const EdgeInsets.fromLTRB(0, 12, 6, 0), child: widget.top),
                    ],
                  ),
                ),
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
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, UoscControls.rowBottomPadding),
                      child: SizedBox(
                        height: UoscControls.buttonRowHeight,
                        child: Row(children: [...widget.left, const Spacer(), ...widget.right]),
                      ),
                    ),
                  ),
                ),
                // Hidden: the collapsed timeline is the progress line,
                // unless the player settings turn it off.
                SignalBuilder(
                  builder: (context) {
                    final line = AppSettings.instance.progressLine.value;
                    return AnimatedOpacity(
                      key: const ValueKey('uosc-timeline-wrap'),
                      duration: fade,
                      opacity: visible || line ? 1 : 0,
                      child: widget.timeline(context, visible),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The session's controls: the standard ones ([material]) or, with the
/// "Player design" setting on uosc, the uosc ones ([mpv]). Switches live
/// when the setting changes.
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
