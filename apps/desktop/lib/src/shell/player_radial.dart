import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show Presence;

import '../controls/controls_probe.dart' show ControlsHold;
import '../controls/model/controls_model.dart';
import '../jellyfin/session_media.dart' show nextPromptLead;
import '../playback/media_marks.dart' show SkipKind;
import 'radial_menu.dart';

// The player's radial (right button on the video): ↑ BRB / I'm back, →
// skip ahead (Skip OP in the opening, Next episode through the ending,
// else Skip 1:30), ↓ Out / Join, ← empty (a darker quarter, so the slots
// never move). Actions that do not apply grey out in place. Hold only:
// it is there while the button is held, and letting go always closes it,
// picking the slot under the pointer (nothing in the centre). A plain
// right-click (let go before [RadialController.revealAfter] without
// leaving the centre) shows nothing. Esc closes it too.

/// The menu while the button is held: where, the slot pointed at, the
/// pointer from the centre, and whether it shows yet.
class _Open {
  final Offset centre;
  final int? hot;
  final Offset? pointer;
  final int pointerId;
  final bool shown;
  const _Open(this.centre, {this.hot, this.pointer, this.pointerId = 0, this.shown = false});

  _Open copy({int? hot, bool clearHot = false, Offset? pointer, bool? shown}) => _Open(centre,
      hot: clearHot ? null : (hot ?? this.hot),
      pointer: pointer ?? this.pointer,
      pointerId: pointerId,
      shown: shown ?? this.shown);
}

/// The radial's state, shared by the listener on the video
/// ([RadialListener]) and the layer over everything ([RadialLayer]).
class RadialController extends ChangeNotifier {
  final PlayerControlsModel model;
  final ControlsHold hold;
  RadialController(this.model, this.hold);

  /// A press shorter than this that stays in the centre is a plain
  /// right-click: the menu never shows. Leaving the centre shows it at
  /// once (a quick flick still picks).
  static const revealAfter = Duration(milliseconds: 150);

  _Open? _open;
  Size _area = Size.zero;
  Timer? _reveal;

  /// The button is held on the video (the menu may not show yet).
  bool get isOpen => _open != null;

  /// The menu shows.
  bool get isShown => _open?.shown ?? false;

  void _set(_Open? o) {
    _open = o;
    if (o == null || o.shown) {
      _reveal?.cancel();
      _reveal = null;
    }
    // The controls stay up while it shows.
    hold.set(#radial, o?.shown ?? false);
    notifyListeners();
  }

  /// Esc, a pick, letting go.
  void close() {
    if (_open != null) _set(null);
  }

  @override
  void dispose() {
    _reveal?.cancel();
    super.dispose();
  }

  /// The menu grows with the video's shorter side: its base size at 720
  /// px and below, up to 1.6 times.
  double get scale => (_area.shortestSide / 720).clamp(1.0, 1.6);

  Offset _clampCentre(Offset at) {
    final r = RadialSize.outer * scale + 8;
    if (_area.width < r * 2 || _area.height < r * 2) return at;
    return Offset(at.dx.clamp(r, _area.width - r), at.dy.clamp(r, _area.height - r));
  }

  /// The four places now (tracked: call inside a builder).
  List<RadialItem> items() {
    final coord = model.coord;
    final self = coord.selfMember.value?.presence ?? Presence.watching;
    final up = switch (self) {
      Presence.watching => const RadialItem('brb', 'BRB', Icons.coffee_rounded),
      Presence.brb || Presence.afk => const RadialItem('back', "I'm back", Icons.waving_hand_rounded),
      Presence.out => const RadialItem('brb', 'BRB', Icons.coffee_rounded, enabled: false, why: "you're out"),
    };
    final down = self.isOut
        ? const RadialItem('join', 'Join', Icons.login_rounded)
        : const RadialItem('out', 'Out', Icons.visibility_off_rounded);
    return [up, _right(), down, const RadialItem.blank()];
  }

  /// → skip ahead: Skip OP in the opening, Next episode through the
  /// ending (the ED, else the last 90 s), else Skip 1:30.
  RadialItem _right() {
    final coord = model.coord;
    final playback = coord.playback;
    final position = playback.position.value;
    final duration = playback.duration.value;
    final skip = coord.skipOffer.value;
    if (skip?.kind == SkipKind.opening) return const RadialItem('skip-op', 'Skip OP', Icons.fast_forward_rounded);
    final ending = playback.ending.value;
    final inEnding = duration > Duration.zero &&
        ((ending != null && position >= ending.start) || duration - position <= nextPromptLead);
    if (inEnding) {
      final next = model.queue.head.value != null || coord.nextEpisode.value != null;
      return RadialItem('next', 'Next episode', Icons.skip_next_rounded,
          short: 'Next', enabled: next, why: next ? null : 'nothing next');
    }
    return RadialItem('skip', 'Skip 1:30', Icons.fast_forward_rounded, enabled: duration > Duration.zero);
  }

  int? _slotAt(Offset d) {
    final i = radialSlot(d, 4, dead: RadialSize.inner * scale);
    if (i == null) return null;
    return untracked(items)[i].blank ? null : i;
  }

  void _down(PointerDownEvent e, Size area) {
    if (e.kind != PointerDeviceKind.mouse || e.buttons & kSecondaryMouseButton == 0) return;
    _area = area;
    final c = _clampCentre(e.localPosition);
    _set(_Open(c, pointer: e.localPosition - c, pointerId: e.pointer));
    _reveal = Timer(revealAfter, () {
      final o = _open;
      if (o != null && !o.shown) _set(o.copy(shown: true));
    });
  }

  void _move(PointerMoveEvent e) {
    final o = _open;
    if (o == null || e.pointer != o.pointerId) return;
    final d = e.localPosition - o.centre;
    final hot = _slotAt(d);
    _set(o.copy(hot: hot, clearHot: hot == null, pointer: d, shown: o.shown || hot != null));
  }

  /// Letting go: the slot under the pointer, or nothing.
  void _up(PointerUpEvent e) {
    final o = _open;
    if (o == null || e.pointer != o.pointerId) return;
    final hot = o.hot;
    hot == null ? close() : _pick(hot);
  }

  void _cancel(PointerCancelEvent e) {
    final o = _open;
    if (o != null && e.pointer == o.pointerId) close();
  }

  void _pick(int slot) {
    final item = untracked(items)[slot];
    close();
    if (!item.enabled) return;
    final coord = model.coord;
    switch (item.id) {
      case 'brb':
        coord.brb();
      case 'back':
        coord.back();
      case 'join':
        coord.join();
      case 'out':
        coord.goOut();
      case 'skip-op':
        final skip = coord.skipOffer.peek();
        if (skip != null) model.skip(skip);
      case 'skip':
        model.skipForward();
      case 'next':
        model.next();
    }
  }
}

/// Around the video: the right button opens the radial. A raw [Listener]
/// (never in the gesture arena), so left clicks and the double-click to
/// fullscreen are untouched.
class RadialListener extends StatelessWidget {
  final RadialController controller;

  /// Off (the mini player): the right button does nothing.
  final bool enabled;
  final Widget child;
  const RadialListener({super.key, required this.controller, this.enabled = true, required this.child});

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (e) {
          if (enabled) controller._down(e, context.size ?? Size.zero);
        },
        onPointerMove: controller._move,
        onPointerUp: controller._up,
        onPointerCancel: controller._cancel,
        child: child,
      );
}

/// The menu, over everything on the video; it never takes the pointer
/// (the held button's moves and its release reach [RadialListener]).
class RadialLayer extends StatelessWidget {
  final RadialController controller;
  const RadialLayer({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final o = controller._open;
              final menu = o == null || !o.shown
                  ? const SizedBox.shrink(key: ValueKey('radial-none'))
                  : SignalBuilder(
                      key: const ValueKey('radial'),
                      builder: (context) => Stack(children: [
                        Positioned(
                          left: o.centre.dx - RadialSize.outer,
                          top: o.centre.dy - RadialSize.outer,
                          child: RadialMenuView(
                            items: controller.items(),
                            hot: o.hot,
                            pointer: o.pointer == null ? null : o.pointer! / controller.scale,
                            scale: controller.scale,
                          ),
                        ),
                      ]),
                    );
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 110),
                switchOutCurve: Curves.easeIn,
                child: menu,
              );
            },
          ),
        ),
      );
}
