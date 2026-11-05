import 'package:flutter/painting.dart' show Alignment, Offset, Rect, Size;

// From the selection on screen to the frame's own pixels. The frozen
// frame is shown as the video is: fitted whole in the player (BoxFit
// .contain), black bars around it when the aspects differ.

/// A rectangle of whole pixels in the frame.
typedef PixelRect = ({int x, int y, int width, int height});

/// Below this size (logical pixels, either side) a drag is a click: the
/// whole frame.
const minSelection = 4.0;

/// Where a [frame]-sized picture sits in a [view] when fitted whole:
/// centred, letterboxed (bars top and bottom) or pillarboxed (bars left
/// and right).
Rect pictureRect(Size view, Size frame) {
  if (frame.width <= 0 || frame.height <= 0 || view.isEmpty) return Offset.zero & view;
  final scale = (view.width / frame.width) < (view.height / frame.height)
      ? view.width / frame.width
      : view.height / frame.height;
  final w = frame.width * scale, h = frame.height * scale;
  return Rect.fromLTWH((view.width - w) / 2, (view.height - h) / 2, w, h);
}

/// [p] kept inside [picture] (a drag never leaves the picture).
Offset clampToPicture(Offset p, Rect picture) =>
    Offset(p.dx.clamp(picture.left, picture.right), p.dy.clamp(picture.top, picture.bottom));

/// The pixels of a [width] x [height] frame under [selection] (view
/// coordinates) when the frame is shown in [picture]; null for the whole
/// frame (a click, or a selection too small to be one). Edges round
/// outward to whole pixels, so what was inside the rectangle is kept.
PixelRect? cropFor(Rect selection, Rect picture, int width, int height) {
  final s = selection.intersect(picture);
  if (s.width < minSelection || s.height < minSelection || picture.isEmpty) return null;
  final sx = width / picture.width, sy = height / picture.height;
  final left = ((s.left - picture.left) * sx).floor().clamp(0, width - 1);
  final top = ((s.top - picture.top) * sy).floor().clamp(0, height - 1);
  final right = ((s.right - picture.left) * sx).ceil().clamp(left + 1, width);
  final bottom = ((s.bottom - picture.top) * sy).ceil().clamp(top + 1, height);
  if (left == 0 && top == 0 && right == width && bottom == height) return null;
  return (x: left, y: top, width: right - left, height: bottom - top);
}

/// The corners the live picture may sit in, in order of preference.
const pipCorners = [Alignment.bottomRight, Alignment.bottomLeft, Alignment.topRight, Alignment.topLeft];

/// Where a [pip]-sized live picture sits in [view] at [corner], [margin]
/// from the edges ([top] from the top: under the selection's bar).
Rect pipRect(Size view, Size pip, Alignment corner, {double margin = 16, double top = 64}) => Rect.fromLTWH(
    corner.x < 0 ? margin : view.width - pip.width - margin,
    corner.y < 0 ? top : view.height - pip.height - margin,
    pip.width,
    pip.height);

/// The corner the live picture moves to so it never covers the
/// [selection] being drawn nor sits under the [pointer]: [current] while
/// it is clear of both, else the clear corner farthest from the pointer;
/// [current] when none is clear.
Alignment pipCorner(Size view, Size pip, Alignment current, {Rect? selection, Offset? pointer}) {
  bool clear(Alignment c) {
    final r = pipRect(view, pip, c).inflate(12);
    if (selection != null && r.overlaps(selection)) return false;
    if (pointer != null && r.contains(pointer)) return false;
    return true;
  }

  if (clear(current)) return current;
  final open = pipCorners.where(clear).toList();
  if (open.isEmpty) return current;
  if (pointer == null) return open.first;
  double away(Alignment c) => (pipRect(view, pip, c).center - pointer).distanceSquared;
  open.sort((a, b) => away(b).compareTo(away(a)));
  return open.first;
}
