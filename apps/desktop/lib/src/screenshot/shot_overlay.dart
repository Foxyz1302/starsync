import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/app_menu.dart' show AppGlass;
import '../widgets/text_focus.dart' show KeyboardClaim;
import 'screenshots.dart' show ShotImages;
import 'shot_crop.dart';

/// What the selection does with a key: pick the selection (or the whole
/// frame), toggle the subtitles, cancel; null for anything else.
enum ShotKey { pick, subtitles, cancel }

/// [event] as a [ShotKey]: Enter takes the selection (none: the whole
/// frame), T switches the subtitles, Esc cancels. Only fresh presses
/// without Ctrl, Alt or Meta.
ShotKey? shotKeyFor(KeyEvent event, {bool control = false, bool alt = false, bool meta = false}) {
  if (event is! KeyDownEvent || control || alt || meta) return null;
  final k = event.logicalKey;
  if (k == LogicalKeyboardKey.escape) return ShotKey.cancel;
  if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) return ShotKey.pick;
  if (k == LogicalKeyboardKey.keyT) return ShotKey.subtitles;
  return null;
}

/// The area selection over a frozen frame (S in the player): the frame
/// caught at the press fills the player as the video did (fitted, black
/// bars around it), only for this person; the video goes on under it.
/// A drag draws the rectangle (kept inside the picture), a click without
/// a drag takes the whole frame; either is picked the moment the button
/// is let go ([onPick]: the subtitles choice and the crop in the frame's
/// own pixels, null for the whole frame). The bar at the top switches
/// the subtitles (T; instant, both copies were caught at the press);
/// During a drag, Esc or a right-click drops the rectangle to draw it
/// again (letting go then takes nothing); otherwise they cancel
/// ([onCancel]). While it is up it has the
/// keys ([KeyboardClaim]): the player's and the app's keys stay off.
/// The video playing on shows small in a corner ([live]), out of the way
/// of the pointer and the selection. It disposes [images] when it goes.
class ShotOverlay extends StatefulWidget {
  final ShotImages images;

  /// Subtitles on at the start (as they were on screen).
  final bool subtitles;
  final void Function(bool subtitles, PixelRect? crop) onPick;
  final VoidCallback onCancel;

  /// The live video, drawn into a box of the frame's aspect; none: no
  /// live picture.
  final Widget? live;
  const ShotOverlay(
      {super.key,
      required this.images,
      required this.subtitles,
      required this.onPick,
      required this.onCancel,
      this.live});

  /// The live picture's width (at most a quarter of the view's).
  static const liveWidth = 320.0;

  @override
  State<ShotOverlay> createState() => _ShotOverlayState();
}

class _ShotOverlayState extends State<ShotOverlay> {
  final _focus = FocusNode(debugLabel: 'screenshot');
  late bool _subs = widget.subtitles && widget.images.subs != null;
  Offset? _anchor;
  Offset? _end;

  /// The drag was dropped (Esc or a right-click while drawing): the
  /// button's release picks nothing.
  bool _dropped = false;
  Rect _picture = Rect.zero;
  bool _done = false;
  Offset? _pointer;
  Alignment _corner = pipCorners.first;

  bool get _hasSubs => widget.images.subs != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    widget.images.clean.dispose();
    widget.images.subs?.dispose();
    super.dispose();
  }

  Rect? get _selection {
    final a = _anchor, b = _end;
    return a == null || b == null ? null : Rect.fromPoints(a, b);
  }

  void _toggleSubs() {
    if (!_hasSubs) return;
    setState(() => _subs = !_subs);
  }

  /// Drops the rectangle being drawn, to draw it again.
  void _drop() => setState(() {
        _anchor = null;
        _end = null;
        _dropped = true;
      });

  void _cancel() {
    if (_done) return;
    _done = true;
    widget.onCancel();
  }

  void _pick() {
    if (_done) return;
    _done = true;
    final sel = _selection;
    final image = widget.images.clean;
    widget.onPick(_subs, sel == null ? null : cropFor(sel, _picture, image.width, image.height));
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    switch (shotKeyFor(event, control: keys.isControlPressed, alt: keys.isAltPressed, meta: keys.isMetaPressed)) {
      case ShotKey.cancel:
        _anchor != null ? _drop() : _cancel();
      case ShotKey.pick:
        _pick();
      case ShotKey.subtitles:
        _toggleSubs();
      case null:
        break;
    }
    // Nothing reaches the player or the app while selecting.
    return KeyEventResult.handled;
  }

  void _down(PointerDownEvent e) {
    if (e.buttons & kSecondaryMouseButton != 0) return _anchor != null ? _drop() : _cancel();
    if (e.buttons & kPrimaryMouseButton == 0) return;
    final p = clampToPicture(e.localPosition, _picture);
    setState(() {
      _anchor = p;
      _end = p;
    });
  }

  void _move(PointerMoveEvent e) {
    _pointer = e.localPosition;
    // A right-click while drawing comes as a move with both buttons.
    if (_anchor != null && e.buttons & kSecondaryMouseButton != 0) return _drop();
    if (_anchor == null) return setState(() {});
    setState(() => _end = clampToPicture(e.localPosition, _picture));
  }

  void _hover(PointerHoverEvent e) {
    if (widget.live == null) return;
    setState(() => _pointer = e.localPosition);
  }

  void _up(PointerUpEvent e) {
    if (_dropped) {
      _dropped = false;
      return;
    }
    if (_anchor == null) return;
    _end = clampToPicture(e.localPosition, _picture);
    _pick();
  }

  @override
  Widget build(BuildContext context) {
    final image = _subs ? widget.images.subs! : widget.images.clean;
    return KeyboardClaim(
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _key,
        child: LayoutBuilder(builder: (context, box) {
          final view = box.biggest;
          _picture = pictureRect(view, Size(image.width.toDouble(), image.height.toDouble()));
          final sel = _selection;
          final crop = sel == null ? null : cropFor(sel, _picture, image.width, image.height);
          return Stack(
            fit: StackFit.expand,
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.precise,
                child: Listener(
                  key: const ValueKey('shot-area'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerHover: _hover,
                  onPointerUp: _up,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Colors.black),
                      Positioned.fromRect(
                        rect: _picture,
                        child: RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                      ),
                      CustomPaint(painter: _MaskPainter(sel, crop != null)),
                      if (sel != null && crop != null) _sizeLabel(sel, crop, view),
                    ],
                  ),
                ),
              ),
              if (widget.live case final live?) _livePicture(live, view, image),
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Center(child: ExcludeFocus(child: _toolbar(context))),
              ),
            ],
          );
        }),
      ),
    );
  }

  /// The live video small in a corner, moving to another as the pointer
  /// or the selection comes near; clicks go through it to the selection.
  Widget _livePicture(Widget live, Size view, ui.Image image) {
    final w = (view.width / 4).clamp(0.0, ShotOverlay.liveWidth);
    final size = Size(w, w * image.height / image.width);
    if (view.height < size.height * 3) return const SizedBox.shrink();
    _corner = pipCorner(view, size, _corner, selection: _selection, pointer: _pointer);
    final r = pipRect(view, size, _corner);
    return AnimatedPositioned(
      key: const ValueKey('shot-live'),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 14, offset: Offset(0, 4))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(color: Colors.black, child: live),
          ),
        ),
      ),
    );
  }

  /// The crop's size in the frame's pixels, under the selection's bottom
  /// right (inside it when it reaches the bottom).
  Widget _sizeLabel(Rect sel, PixelRect crop, Size view) {
    final below = sel.bottom + 30 < view.height;
    return Positioned(
      right: (view.width - sel.right).clamp(4.0, view.width),
      top: below ? sel.bottom + 6 : null,
      bottom: below ? null : (view.height - sel.bottom + 6).clamp(4.0, view.height),
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(6)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Text('${crop.width} × ${crop.height}',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    const dim = Color(0xB3FFFFFF);
    return AppGlass.pill(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolButton(
              key: const ValueKey('shot-subtitles'),
              icon: _subs ? Icons.closed_caption_rounded : Icons.closed_caption_disabled_outlined,
              label: _hasSubs ? (_subs ? 'Subtitles on' : 'Subtitles off') : 'No subtitles',
              keyCap: 'T',
              selected: _subs,
              onTap: _hasSubs ? _toggleSubs : null,
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text('Drag to select · click for the whole frame',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: dim, fontSize: 13)),
            ),
            const SizedBox(width: 10),
            _ToolButton(
              key: const ValueKey('shot-cancel'),
              icon: Icons.close_rounded,
              label: 'Cancel',
              keyCap: 'Esc',
              onTap: _cancel,
            ),
          ],
        ),
      ),
    );
  }
}

/// The moment between a screenshot key and its frame (S or Shift+S),
/// shown from the next frame on. [area] (S): the player dimmed under a
/// "Capturing…" pill, where the selection will open; clicks stay on it.
/// Otherwise (Shift+S): only the pill, clicks go through. Either way it
/// has the keys ([KeyboardClaim]): nothing reaches the player meanwhile,
/// and Esc gives up the capture ([onCancel]).
class ShotPending extends StatefulWidget {
  final bool area;
  final VoidCallback onCancel;
  const ShotPending({super.key, required this.area, required this.onCancel});

  @override
  State<ShotPending> createState() => _ShotPendingState();
}

class _ShotPendingState extends State<ShotPending> {
  final _focus = FocusNode(debugLabel: 'screenshot pending');

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) widget.onCancel();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final pill = Center(
      child: AppGlass.pill(
        key: const ValueKey('shot-pending'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                  dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              const SizedBox(width: 10),
              Text(widget.area ? 'Capturing…' : 'Taking a screenshot…',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
    return KeyboardClaim(
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _key,
        child: widget.area
            ? Listener(
                key: const ValueKey('shot-pending-area'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  if (e.buttons & kSecondaryMouseButton != 0) widget.onCancel();
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Color(0x73000000)),
                    Positioned(top: 16, left: 16, right: 16, child: pill),
                  ],
                ),
              )
            : IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(padding: const EdgeInsets.only(top: 16), child: pill),
                ),
              ),
      ),
    );
  }
}

/// A button of the selection's bar: icon, label and its key.
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String keyCap;
  final bool selected;
  final VoidCallback? onTap;
  const _ToolButton(
      {super.key, required this.icon, required this.label, required this.keyCap, this.selected = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = enabled ? Colors.white : Colors.white38;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        canRequestFocus: false,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          decoration: BoxDecoration(
            color: selected ? Colors.white.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: fg.withValues(alpha: 0.5)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  child: Text(keyCap, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dims everything but the selection (lightly before there is one) and
/// outlines it.
class _MaskPainter extends CustomPainter {
  final Rect? selection;
  final bool real;
  const _MaskPainter(this.selection, this.real);

  @override
  void paint(Canvas canvas, Size size) {
    final all = Offset.zero & size;
    final sel = real ? selection : null;
    if (sel == null) {
      canvas.drawRect(all, Paint()..color = const Color(0x33000000));
      return;
    }
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(all)
      ..addRect(sel);
    canvas.drawPath(mask, Paint()..color = const Color(0x8C000000));
    canvas.drawRect(
        sel.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_MaskPainter old) => old.selection != selection || old.real != real;
}
