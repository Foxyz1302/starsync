import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

// The shell's shared motion: one curve and one duration for everything
// that moves, a fade-through for views that replace each other, popovers
// that grow from where they open, and mouse-friendly horizontal lists.

const ease = Curves.fastEaseInToSlowEaseOut;
const easeTime = Duration(milliseconds: 320);

/// Fade-through length; the old view is gone after [fadeOutPart] of it.
const fadeThroughTime = Duration(milliseconds: 360);
const fadeOutPart = 0.35;

/// Fade through (Material motion): the old view is gone after the first
/// 35%, then the new one fades and scales in; they never overlap. Key
/// [child] by what it shows so a change of key runs the transition.
/// [expand] false: sized by the views (at [alignment]) instead of filling
/// the box, for unbounded places (a row, a pill).
Widget fadeThrough(Widget child,
        {Key? key, bool expand = true, AlignmentGeometry alignment = AlignmentDirectional.topStart}) =>
    AnimatedSwitcher(
      key: key,
      duration: fadeThroughTime,
      layoutBuilder: (current, previous) => Stack(
        fit: expand ? StackFit.expand : StackFit.loose,
        alignment: alignment,
        children: [...previous, ?current],
      ),
      transitionBuilder: (c, anim) {
        if (c.key == child.key) {
          // Incoming (anim 0 -> 1): wait, then fade and scale up.
          final a = CurvedAnimation(
            parent: anim,
            curve: const Interval(fadeOutPart, 1, curve: ease),
          );
          return FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(a), child: c),
          );
        }
        // Outgoing (anim 1 -> 0): fully faded by the time it reaches 0.65.
        // Same widget shape as the incoming branch, or the old view would
        // remount (and lose its state) while it fades.
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: anim,
            curve: const Interval(1 - fadeOutPart, 1, curve: Curves.easeIn),
          ),
          child: ScaleTransition(scale: const AlwaysStoppedAnimation(1.0), child: c),
        );
      },
      child: child,
    );

/// A card over the window that fades and scales in from [at] (window
/// alignment) instead of popping; a click outside or Esc closes it. Short
/// windows: the card scrolls instead of overflowing.
Future<T?> showPopover<T>(
  BuildContext context, {
  required Alignment at,
  required Widget child,
  bool dim = false,
}) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'close',
      barrierColor: dim ? Colors.black26 : Colors.transparent,
      transitionDuration: easeTime,
      pageBuilder: (context, _, _) => SafeArea(
        child: Align(
          alignment: at,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 32),
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
      transitionBuilder: (context, anim, _, child) {
        final a = CurvedAnimation(parent: anim, curve: ease, reverseCurve: Curves.easeIn);
        return FadeTransition(
          opacity: a,
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(a),
            alignment: at,
            child: child,
          ),
        );
      },
    );

/// Horizontal lists for mouse users: drag with the mouse or Shift+wheel;
/// the plain wheel stays vertical (the page scrolls under the cursor, not
/// the row).
class HScroll extends StatefulWidget {
  final ScrollController? controller;
  final Widget Function(ScrollController controller) builder;
  /// Also map the plain (vertical) wheel to sideways scrolling (at either
  /// end the wheel goes to the page). Off by default: one wheel doing two
  /// things was confusing.
  final bool wheel;
  const HScroll({super.key, this.controller, required this.builder, this.wheel = false});

  @override
  State<HScroll> createState() => _HScrollState();
}

class _HScrollState extends State<HScroll> {
  ScrollController? _own;
  ScrollController get _c => widget.controller ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  void _wheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final dy = e.scrollDelta.dy;
    if (dy == 0 || e.scrollDelta.dx != 0 || !_c.hasClients) return;
    final p = _c.position;
    final target = (p.pixels + dy * 1.5).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (target == p.pixels) return; // at the end: let the page scroll
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      _c.animateTo(target, duration: const Duration(milliseconds: 140), curve: Curves.easeOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context)
            .copyWith(dragDevices: PointerDeviceKind.values.toSet()),
        child: widget.wheel ? Listener(onPointerSignal: _wheel, child: widget.builder(_c)) : widget.builder(_c),
      );
}
