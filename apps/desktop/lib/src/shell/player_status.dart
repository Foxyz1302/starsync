import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../session/session_coordinator.dart';
import '../session/space_gesture.dart' show HoldKind, HoldView;
import '../app/app_graph.dart';
import '../state/settings.dart' show WaitDisplay;
import '../widgets/app_menu.dart' show AppGlass, AppMenuStyle;
import 'avatar.dart';
import 'motion.dart';
import 'wait_card.dart';

export '../session/status.dart' show KeyHint, StatusAction, StatusKind, StatusLevel, StatusLine, nameList;

/// The pill's line from the session's [SessionCoordinator.status]
/// (tracked: call inside a builder); "Connecting…" only once it has taken
/// [PlayerStatus.connectGrace] ([slowConnect]).
StatusLine? playerStatusNow(SessionCoordinator coord, {bool slowConnect = false}) {
  final line = coord.status.value.line;
  if (line?.kind == StatusKind.connecting && !slowConnect) return null;
  return line;
}

/// The player's one status pill (bottom centre, design A): a rounded
/// rectangle of the app's glass with the people it is about (36 px, side
/// by side, at most three then "+N"; while paused everyone else there with
/// their BRB / AFK / Out badge, at most five), one line, and under it the keys
/// that act now or a muted detail; at most one button. A Space hold fills
/// it from the left, fading in with an ease-in so a tap barely shows, and
/// from 150 ms on its words say what keeping on and letting go do. Fades in
/// and out; a different kind of status fades through, the pill resizing
/// around it. [onSize]: its size after each layout (the subtitle lift).
class PlayerStatus extends StatefulWidget {
  final ValueChanged<Size>? onSize;
  const PlayerStatus({super.key, this.onSize});

  static const connectGrace = Duration(seconds: 2);

  @override
  State<PlayerStatus> createState() => _PlayerStatusState();
}

class _PlayerStatusState extends State<PlayerStatus> {
  Timer? _connectTimer;
  bool _slow = false;
  StatusLine? _last;
  // The pill's laid-out size, whether it shows, and what [PlayerStatus.onSize]
  // last heard (zero while hidden).
  Size _measured = Size.zero;
  bool _visible = false;
  Size? _reported;

  void _report() {
    final s = _visible ? _measured : Size.zero;
    if (s == _reported || widget.onSize == null) return;
    _reported = s;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSize?.call(s);
    });
  }

  @override
  void dispose() {
    _connectTimer?.cancel();
    super.dispose();
  }

  // "Connecting…" only once it takes a while.
  void _trackConnecting(StatusLine? line) {
    final connecting = line?.kind == StatusKind.connecting;
    if (!connecting) {
      _connectTimer?.cancel();
      _connectTimer = null;
      _slow = false;
    } else if (_connectTimer == null && !_slow) {
      _connectTimer = Timer(PlayerStatus.connectGrace, () {
        if (mounted) setState(() => _slow = true);
      });
    }
  }

  void _act(SessionCoordinator coord, StatusAction a) {
    switch (a) {
      case StatusAction.cancel:
        coord.cancelReconnect();
      case StatusAction.retry:
        coord.retry();
      case StatusAction.reload:
        unawaited(coord.reloadVideo());
      case StatusAction.join:
        coord.join();
      case StatusAction.back:
        coord.back();
    }
  }

  @override
  Widget build(BuildContext context) {
    final coord = AppScope.of(context).coordinator;
    return ValueListenableBuilder<StatusLine?>(
      valueListenable: coord.space.holdLine,
      builder: (context, holdLine, _) => PartyWatch(builder: (context) {
        _trackConnecting(coord.status.value.line);
        var view = holdLine ?? playerStatusNow(coord, slowConnect: _slow);
        // Out: the card in the middle says it ([OutCard]).
        if (view?.kind == StatusKind.out) view = null;
        // A waiting card shows the waiting itself (Waiting display).
        if (holdLine == null &&
            view != null &&
            coord.settings.waitDisplay.value != WaitDisplay.pill &&
            isWaitLine(view)) {
          view = null;
        }
        if (view != null) _last = view;
        _visible = view != null;
        _report();
        final shown = _last;
        final tap = view != null && view.tappable;
        final pill = shown == null
            ? const SizedBox.shrink()
            : MouseRegion(
                cursor: tap ? SystemMouseCursors.click : MouseCursor.defer,
                child: GestureDetector(
                  key: const ValueKey('player-status'),
                  onTap: tap ? () => _act(coord, view!.action!) : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: AppGlass(
                      radius: StatusPill.radius,
                      color: AppMenuStyle.pillGlass,
                      shadow: false,
                      child: Stack(
                        children: [
                          Positioned.fill(child: HoldFill(hold: coord.space.hold)),
                          AnimatedSize(
                            duration: holdLine != null ? const Duration(milliseconds: 160) : easeTime,
                            curve: ease,
                            child: holdLine != null
                                ? AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 140),
                                    layoutBuilder: (current, previous) =>
                                        Stack(alignment: Alignment.center, children: [...previous, ?current]),
                                    child: StatusPill(
                                        key: ValueKey('hold-${shown.text}'),
                                        view: shown,
                                        coord: coord,
                                        onAction: (a) => _act(coord, a)),
                                  )
                                : fadeThrough(
                                    StatusPill(
                                      key: ValueKey(shown.kind),
                                      view: shown,
                                      coord: coord,
                                      onAction: (a) => _act(coord, a),
                                    ),
                                    expand: false,
                                    alignment: Alignment.center,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
        return AnimatedOpacity(
          duration: easeTime,
          curve: ease,
          opacity: view == null ? 0 : 1,
          child: IgnorePointer(
            ignoring: view == null,
            child: widget.onSize == null
                ? pill
                : SizeReport(
                    onSize: (s) {
                      _measured = s;
                      _report();
                    },
                    child: pill),
          ),
        );
      }),
    );
  }
}

/// The player's pill surface (the action pills, the unread chip): the
/// app's glass as a stadium ([AppGlass.pill]).
class PlayerGlass extends StatelessWidget {
  final Widget child;
  const PlayerGlass({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: AppGlass.pill(child: child),
      );
}

/// A Space hold's fill: the pill's background from the left edge to the
/// progress, its strength an ease-in of the progress (amber for BRB, white
/// for continuing without). Repaints from the gesture without rebuilding
/// the pill; the glass clips it to its shape.
class HoldFill extends StatelessWidget {
  final ValueListenable<HoldView?> hold;
  const HoldFill({super.key, required this.hold});

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: CustomPaint(painter: _FillPainter(hold, Curves.easeIn)));
}

class _FillPainter extends CustomPainter {
  final ValueListenable<HoldView?> hold;
  final Curve curve;
  _FillPainter(this.hold, this.curve) : super(repaint: hold);

  @override
  void paint(Canvas canvas, Size size) {
    final h = hold.value;
    if (h == null || h.progress <= 0) return;
    final strength = curve.transform(h.progress.clamp(0.0, 1.0));
    if (strength <= 0.002) return;
    final brb = h.kind == HoldKind.brb;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * h.progress, size.height),
        Paint()..color = (brb ? Colors.amber : Colors.white).withValues(alpha: (brb ? 0.55 : 0.32) * strength));
  }

  @override
  bool shouldRepaint(_FillPainter old) => old.hold != hold || old.curve != curve;
}

/// Tells [onSize] its child's size after each layout that changes it.
class SizeReport extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;
  const SizeReport({super.key, required this.onSize, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => RenderSizeReport(onSize);

  @override
  void updateRenderObject(BuildContext context, RenderSizeReport renderObject) => renderObject.onSize = onSize;
}

class RenderSizeReport extends RenderProxyBox {
  ValueChanged<Size> onSize;
  Size? _last;
  RenderSizeReport(this.onSize);

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final s = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(s));
  }
}

/// The pill's content: the people, the line, the keys or the detail, a
/// button.
class StatusPill extends StatelessWidget {
  final StatusLine view;
  final SessionCoordinator coord;
  final ValueChanged<StatusAction> onAction;
  const StatusPill({super.key, required this.view, required this.coord, required this.onAction});

  static const radius = 14.0;

  /// As tall as the two lines of text beside them.
  static const avatar = 36.0;
  // Room for the standing badge that sits a third over the corner.
  static const _gap = 6.0;
  static const _most = 3;
  static const _mostPaused = 5;

  Widget? _lead() => switch (view.kind) {
        StatusKind.problem => Icon(
            view.level == StatusLevel.error ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
            size: 20,
            color: view.level == StatusLevel.error ? Colors.redAccent.shade100 : Colors.amber),
        StatusKind.reconnecting => const _Spinner(color: Colors.amber),
        StatusKind.connecting || StatusKind.fetching || StatusKind.seeking => const _Spinner(color: Colors.white70),
        StatusKind.out || StatusKind.afk || StatusKind.paused => null,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final v = view;
    final r = coord.serverState.value;
    // A pause shows everyone there; the other lines the few they are about.
    final who = v.who.take(v.kind == StatusKind.paused ? _mostPaused : _most).toList();
    final more = v.who.length - who.length;
    final shape = AvatarShape.of(context);
    final lead = who.isEmpty ? _lead() : null;
    final action = v.action == StatusAction.cancel || v.action == StatusAction.retry || v.action == StatusAction.reload
        ? v.action
        : null;
    final second = v.keys.isNotEmpty
        ? KeyHints(v.keys)
        : v.detail != null
            ? Text(v.detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 11.5, fontWeight: FontWeight.w500, height: 1.3))
            : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in who) ...[
            StatusAvatar(info: memberAvatarInfo(m, r, coord), size: avatar, badges: false),
            const SizedBox(width: _gap),
          ],
          if (more > 0) ...[
            Container(
              width: avatar,
              height: avatar,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: shape.radius(avatar)),
              child: Text('+$more', style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: _gap),
          ],
          if (who.isNotEmpty) const SizedBox(width: 10 - _gap),
          if (lead != null) ...[lead, const SizedBox(width: 10)],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: who.isEmpty ? 0 : avatar),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.text,
                    key: const ValueKey('player-status-text'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, height: 1.2),
                  ),
                  if (second != null) ...[const SizedBox(height: 3), second],
                ],
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 12),
            _PillButton(
              label: action == StatusAction.cancel ? 'Cancel' : 'Retry',
              onPressed: () => onAction(action),
            ),
          ],
        ],
      ),
    );
  }
}

/// The hint line: `[Space] BRB too  [Hold Space] continue without`: small
/// keycaps a little lighter than the glass, the actions muted.
class KeyHints extends StatelessWidget {
  final List<KeyHint> keys;
  const KeyHints(this.keys, {super.key});

  @override
  Widget build(BuildContext context) {
    const action = TextStyle(color: Colors.white60, fontSize: 11.5, fontWeight: FontWeight.w500, height: 1.2);
    return Row(
      key: const ValueKey('player-status-keys'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < keys.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Keycap(keys[i].$1),
          const SizedBox(width: 5),
          Flexible(child: Text(keys[i].$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: action)),
        ],
      ],
    );
  }
}

/// One key as a small keycap, a little lighter than what it sits on
/// ([ink]: its letters, and a tint of it under them; white by default).
class Keycap extends StatelessWidget {
  final String label;
  final Color? ink;
  const Keycap(this.label, {super.key, this.ink});

  @override
  Widget build(BuildContext context) {
    final c = ink ?? Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withValues(alpha: 0.16), width: 0.5),
      ),
      child: Text(label,
          style: TextStyle(
              color: c.withValues(alpha: 0.7), fontSize: 10.5, fontWeight: FontWeight.w600, height: 1.25, letterSpacing: 0.2)),
    );
  }
}

class _Spinner extends StatelessWidget {
  final Color color;
  const _Spinner({required this.color});

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: color));
}

class _PillButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _PillButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) => TextButton(
        key: ValueKey('player-status-$label'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: Colors.white12,
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 26),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      );
}
