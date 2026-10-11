import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../playback/media_marks.dart';
import 'controls.dart';
import 'style.dart';

// A port of uosc's timeline (`elements/Timeline.lua`, defaults from
// `uosc.conf` / `main.lua`), style `line`, scale 1: a translucent black
// band, the position a thin white line (no filled progress), the
// uncached part hatched, chapter diamonds on the top edge, elapsed time
// left and the time remaining right, the buffered seconds next to the
// position while under the threshold, and a tooltip with the time (and
// the chapter title) under the mouse.

/// uosc's defaults at scale 1.
abstract final class UoscTimelineSpec {
  /// `timeline_size`: the band's height when expanded.
  static const size = 40.0;

  /// `timeline_border`: band above the line, also the diamonds' border.
  static const border = 1.0;

  /// `timeline_line_width`: the position line.
  static const lineWidth = 2.0;

  /// `progress_size`: what is left when the controls hide.
  static const progressSize = 2.0;

  /// `progress_line_width`: the position line once minimized.
  static const progressLineWidth = 20.0;

  /// floor(min((size + 60) * 0.2, size * 0.96)).
  static const fontSize = 20.0;

  /// max(floor((size - fontSize) / 2.5), 4): the times' inset.
  static const spacing = 8.0;

  /// `text_border`: the outline of text drawn on the band.
  static const textBorder = 1.2;

  /// `opacity.timeline` (the band) and `opacity.chapters` (diamond fill).
  static const opacity = 0.9;
  static const chaptersOpacity = 0.8;

  /// Gap between the band and its tooltips, and between tooltips.
  static const tooltipGap = 2.0;

  /// `buffered_time_threshold`: the cache label shows below this.
  static const bufferedThreshold = Duration(seconds: 60);

  /// max((size + border) / 10, 3): diamond radius cap.
  static const chapterSize = (size + border) / 10;
}

/// uosc's `format_time(seconds, duration)`: mpv's "HH:MM:SS", trimmed to
/// "MM:SS" for media under an hour and "SS" under a minute; negative
/// values keep their minus ("-01:47:30").
String uoscClock(Duration d, Duration max) {
  final neg = d.isNegative && d.inSeconds != 0;
  final t = d.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  final full = '${two(t.inHours)}:${two(t.inMinutes % 60)}:${two(t.inSeconds % 60)}';
  final trim = max < const Duration(minutes: 1) ? 6 : (max < const Duration(hours: 1) ? 3 : 0);
  return '${neg ? '-' : ''}${full.substring(trim)}';
}

/// Fraction of [total] at [d], 0..1 (0 without a duration).
double timelineFraction(Duration d, Duration total) {
  final t = total.inMicroseconds;
  if (t <= 0) return 0;
  return (d.inMicroseconds / t).clamp(0.0, 1.0);
}

/// Where the uncached part starts (it runs to the end), as a fraction;
/// null when nothing known is uncached. We know only the end of mpv's
/// cache ahead ([buffered]); without it (0) uosc draws no ranges either,
/// and a cache that reaches the end (within uosc's 0.5 s) leaves none.
double? uncachedFrom({required Duration position, required Duration buffered, required Duration duration}) {
  if (duration <= Duration.zero || buffered <= Duration.zero) return null;
  final from = buffered > position ? buffered : position;
  if (duration - from <= const Duration(milliseconds: 500)) return null;
  return timelineFraction(from, duration);
}

/// The cache label next to the position ("12s"): the seconds buffered
/// ahead, shown while under [UoscTimelineSpec.bufferedThreshold] and the
/// cache does not reach the end (uosc drops it at eof-cached).
String? cacheLabel({required Duration position, required Duration buffered, required Duration duration}) {
  if (duration <= Duration.zero || buffered <= Duration.zero) return null;
  if (duration - buffered <= const Duration(milliseconds: 500)) return null;
  final ahead = buffered > position ? buffered - position : Duration.zero;
  if (ahead >= UoscTimelineSpec.bufferedThreshold) return null;
  return '${(ahead.inMilliseconds / 1000).round()}s';
}

/// The band's geometry at one size, as uosc lays it out: the position
/// line takes [lineWidth] pixels, and times map around it (`t2x`) so no
/// time lies inside the line.
class UoscTimelineGeometry {
  final double width;

  /// The foreground height (without the top border).
  final double size;

  /// The playing position, 0..1.
  final double progress;
  final double lineWidth;
  const UoscTimelineGeometry({
    required this.width,
    required this.size,
    required this.progress,
    this.lineWidth = UoscTimelineSpec.lineWidth,
  });

  /// [size] while the band animates between hidden (0) and shown (1)
  /// (`get_effective_size`).
  static double sizeAt(double visibility) =>
      UoscTimelineSpec.progressSize +
      ((UoscTimelineSpec.size - UoscTimelineSpec.progressSize) * visibility).ceilToDouble();

  /// The position line's width at [size]: it grows to
  /// [UoscTimelineSpec.progressLineWidth] over the last eighth of the
  /// collapse.
  static double lineWidthAt(double size) {
    const p = UoscTimelineSpec.progressSize;
    final minimized = 1 - math.min((size - p) / ((UoscTimelineSpec.size - p) / 8), 1.0);
    return UoscTimelineSpec.lineWidth + (UoscTimelineSpec.progressLineWidth - UoscTimelineSpec.lineWidth) * minimized;
  }

  double get height => size + UoscTimelineSpec.border;

  /// Top of the foreground (below the border).
  double get top => UoscTimelineSpec.border;
  double get lineLeft => ((width - lineWidth) * progress).roundToDouble();
  double get lineRight => ((width - lineWidth) * progress + lineWidth).roundToDouble();

  /// x of [fraction] (uosc's `t2x`): past the position, shifted over the line.
  double x(double fraction) {
    final lw = lineWidth - 1;
    final at = 0.5 + (width - lw - 1) * fraction;
    return fraction <= progress ? at : at + lw;
  }

  /// The fraction at [x] (uosc's `get_time_at_x`): x on the line is the
  /// position.
  double fractionAt(double x) {
    const lw = UoscTimelineSpec.lineWidth - 1;
    final timeWidth = width - lw - 1;
    if (timeWidth <= 0) return 0;
    final a = timeWidth * progress, b = a + lw;
    var at = x - 0.5;
    if (at > b) {
      at -= lw;
    } else if (at > a) {
      at = a;
    }
    return (at / timeWidth).clamp(0.0, 1.0);
  }

  /// Chapter diamond radius at this size; doubled while hovered.
  double get diamondRadius => math.min(math.max(1.0, size * 0.8), UoscTimelineSpec.chapterSize);
}

/// The uosc timeline. [expanded] false (the controls hidden) shrinks it,
/// animated, to the progress line. Seeks ([onSeek]) on press, on every
/// drag move and on release; a press on a hovered chapter diamond jumps
/// to that chapter. The session sends those through the user-seek path.
class UoscTimeline extends StatefulWidget {
  final Duration position;
  final Duration duration;

  /// End of the cached range ([PlaybackController.buffered]).
  final Duration buffered;
  final List<MediaChapter> chapters;
  final bool expanded;
  final ValueChanged<Duration> onSeek;
  const UoscTimeline({
    super.key,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    this.chapters = const [],
    this.expanded = true,
    required this.onSeek,
  });

  static const height = UoscTimelineSpec.size + UoscTimelineSpec.border;
  static const collapsedHeight = UoscTimelineSpec.progressSize + UoscTimelineSpec.border;

  /// uosc's `animation_duration`.
  static const animation = Duration(milliseconds: 100);

  @override
  State<UoscTimeline> createState() => _UoscTimelineState();
}

class _UoscTimelineState extends State<UoscTimeline> {
  Offset? _hover;
  bool _dragging = false;
  double _dragFraction = 0;
  Duration? _lastSent;
  // A released seek, shown until the position catches up (else the line
  // jumps back to the old position for a moment).
  double? _pending;
  Timer? _pendingTimer;

  Duration _at(double fraction) => widget.duration * fraction.clamp(0.0, 1.0);

  void _send(Duration d) {
    if (d == _lastSent) return;
    _lastSent = d;
    widget.onSeek(d);
  }

  void _drag(bool on) {
    if (_dragging == on) return;
    setState(() => _dragging = on);
    UoscControls.maybeOf(context)?.hold(on);
  }

  void _settle(double fraction) {
    _pending = fraction;
    _pendingTimer?.cancel();
    _pendingTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _pending = null);
    });
  }

  @override
  void didUpdateWidget(UoscTimeline old) {
    super.didUpdateWidget(old);
    if (!widget.expanded && old.expanded) _hover = null;
    final p = _pending;
    if (p != null && widget.duration > Duration.zero) {
      final off = (widget.position - _at(p)).abs();
      if (off < const Duration(milliseconds: 1500)) {
        _pending = null;
        _pendingTimer?.cancel();
      }
    }
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    // A drag cut short by a rebuild must not keep the controls up.
    if (_dragging) UoscControls.maybeOf(context)?.hold(false);
    super.dispose();
  }

  /// The chapter whose diamond is within twice its radius of [at].
  int? _hoveredChapter(UoscTimelineGeometry geo, List<MediaChapter> marks, Offset? at) {
    if (at == null || _dragging) return null;
    final reach = geo.diamondRadius * 2;
    int? best;
    var bestD = double.infinity;
    for (var i = 0; i < marks.length; i++) {
      final cx = geo.x(timelineFraction(marks[i].start, widget.duration));
      final d = (Offset(cx, 0) - at).distance;
      if (d <= reach && d < bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final font = DefaultTextStyle.of(context).style.fontFamily ?? Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return TweenAnimationBuilder<double>(
          tween: Tween(end: widget.expanded ? 1 : 0),
          duration: UoscTimeline.animation,
          builder: (context, visibility, _) => _band(width, visibility, font),
        );
      },
    );
  }

  Widget _band(double width, double visibility, String? font) {
    final expanded = widget.expanded;
    final duration = widget.duration;
    final size = UoscTimelineGeometry.sizeAt(visibility);
    final progress = _dragging ? _dragFraction : (_pending ?? timelineFraction(widget.position, duration));
    final shown = _at(progress);
    final geo = UoscTimelineGeometry(
      width: width,
      size: size,
      progress: progress,
      lineWidth: UoscTimelineGeometry.lineWidthAt(size),
    );
    final marks = duration > Duration.zero ? widget.chapters : const <MediaChapter>[];
    final hover = expanded ? _hover : null;
    final hovered = _hoveredChapter(geo, marks, hover);
    final hoverFraction = hovered != null
        ? timelineFraction(marks[hovered].start, duration)
        : (hover == null || duration <= Duration.zero ? null : geo.fractionAt(hover.dx));
    final hoverAt = hoverFraction == null ? null : _at(hoverFraction);
    final cursorX = hovered != null ? geo.x(hoverFraction!) : hover?.dx;
    final hoverChapter = hoverAt == null ? null : chapterIndexAt(widget.chapters, hoverAt);
    final hoverTitle = hoverChapter == null ? '' : widget.chapters[hoverChapter].title;
    // Text fades out just before it would overflow the shrinking band.
    const hideBelow = UoscTimelineSpec.fontSize * 0.8;
    final textOpacity = (size - hideBelow).clamp(0.0, hideBelow / 2) / (hideBelow / 2);
    final radius = geo.diamondRadius;
    final timestampGap = UoscTimelineSpec.tooltipGap + (hovered != null ? radius * 2 : radius).roundToDouble();
    final painter = UoscTimelinePainter(
      geometry: geo,
      visibility: visibility,
      uncached: uncachedFrom(position: widget.position, buffered: widget.buffered, duration: duration),
      chapters: [for (final c in marks) timelineFraction(c.start, duration)],
      hoveredChapter: hovered,
      hoverX: cursorX,
      textOpacity: textOpacity,
      elapsed: duration > Duration.zero ? uoscClock(shown, duration) : null,
      remaining: duration > Duration.zero ? uoscClock(shown - duration, duration) : null,
      cache: cacheLabel(position: widget.position, buffered: widget.buffered, duration: duration),
      fontFamily: font,
    );
    final bar = SizedBox(
      key: const ValueKey('uosc-timeline'),
      width: width,
      height: geo.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: RepaintBoundary(child: CustomPaint(painter: painter)),
          ),
          if (hoverAt != null && cursorX != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: geo.height + timestampGap,
              height: 160,
              child: IgnorePointer(
                child: CustomMultiChildLayout(
                  delegate: _TooltipLayout(x: cursorX),
                  children: [
                    LayoutId(
                      id: #time,
                      child: UoscBox(
                        uoscClock(hoverAt, duration),
                        key: const ValueKey('uosc-hover-time'),
                        color: Colors.black,
                        style: _tipStyle,
                      ),
                    ),
                    if (hoverTitle.isNotEmpty)
                      LayoutId(
                        id: #chapter,
                        child: UoscBox(
                          hoverTitle,
                          key: const ValueKey('uosc-hover-chapter'),
                          color: Colors.black,
                          style: _tipStyle.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (!expanded) return IgnorePointer(child: bar);
    Offset clampTo(Offset p) => Offset(p.dx.clamp(0.0, width), p.dy);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (e) => setState(() => _hover = clampTo(e.localPosition)),
      onHover: (e) => setState(() => _hover = clampTo(e.localPosition)),
      onExit: (_) {
        if (!_dragging) setState(() => _hover = null);
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (duration <= Duration.zero || width <= 0) return;
          final at = clampTo(e.localPosition);
          final chapter = _hoveredChapter(geo, marks, at);
          _lastSent = null;
          if (chapter != null) {
            final f = timelineFraction(marks[chapter].start, duration);
            _settle(f);
            _send(marks[chapter].start);
            setState(() {});
            return;
          }
          _pending = null;
          _dragFraction = geo.fractionAt(at.dx);
          _drag(true);
          _send(_at(_dragFraction));
        },
        onPointerMove: (e) {
          if (!_dragging) return;
          final at = clampTo(e.localPosition);
          setState(() {
            _hover = at;
            _dragFraction = geo.fractionAt(at.dx);
          });
          _send(_at(_dragFraction));
        },
        onPointerUp: (e) {
          if (!_dragging) return;
          _send(_at(_dragFraction));
          _settle(_dragFraction);
          final p = e.localPosition;
          if (p.dx < 0 || p.dx > width || p.dy < 0 || p.dy > geo.height) _hover = null;
          _drag(false);
        },
        onPointerCancel: (_) => _drag(false),
        child: bar,
      ),
    );
  }

  static const _tipStyle = TextStyle(color: UoscStyle.text, fontSize: UoscTimelineSpec.fontSize, height: 1);
}

/// The hover tooltips: the time centred on [x], the chapter title over
/// it; each kept [UoscTimelineSpec.tooltipGap] inside the band's ends.
class _TooltipLayout extends MultiChildLayoutDelegate {
  final double x;
  _TooltipLayout({required this.x});

  @override
  void performLayout(Size size) {
    const gap = UoscTimelineSpec.tooltipGap;
    double left(double w) => (x - w / 2).clamp(gap, math.max(gap, size.width - gap - w));
    final loose = BoxConstraints.loose(size);
    final time = layoutChild(#time, loose);
    final timeTop = size.height - time.height;
    positionChild(#time, Offset(left(time.width), timeTop));
    if (hasChild(#chapter)) {
      final chapter = layoutChild(#chapter, loose);
      positionChild(#chapter, Offset(left(chapter.width), timeTop - gap - chapter.height));
    }
  }

  @override
  bool shouldRelayout(_TooltipLayout old) => old.x != x;
}

/// Paints the band as uosc does: background, the position line, the
/// uncached hatching, chapter diamonds, the times, the hover line.
class UoscTimelinePainter extends CustomPainter {
  final UoscTimelineGeometry geometry;

  /// 0 hidden .. 1 shown (picks the hatching texture and its strength).
  final double visibility;

  /// Start of the uncached part (to the end), as a fraction.
  final double? uncached;

  /// Chapter starts, as fractions.
  final List<double> chapters;
  final int? hoveredChapter;

  /// The hover line (the mouse, or the hovered chapter).
  final double? hoverX;
  final double textOpacity;
  final String? elapsed;
  final String? remaining;
  final String? cache;
  final String? fontFamily;
  const UoscTimelinePainter({
    required this.geometry,
    this.visibility = 1,
    this.uncached,
    this.chapters = const [],
    this.hoveredChapter,
    this.hoverX,
    this.textOpacity = 1,
    this.elapsed,
    this.remaining,
    this.cache,
    this.fontFamily,
  });

  double get played => geometry.progress;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final w = size.width, bottom = size.height, top = g.top;
    final line = Rect.fromLTRB(g.lineLeft, top, g.lineRight, bottom);
    // Background (`opacity.timeline`) around the position line.
    final bg = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(line);
    canvas.drawPath(bg, Paint()..color = Colors.black.withValues(alpha: UoscTimelineSpec.opacity));
    canvas.drawRect(line, Paint()..color = Colors.white);
    _hatch(canvas, w, top, bottom);
    _chapters(canvas);
    if (textOpacity > 0) _times(canvas, w, top, bottom, line);
    final x = hoverX;
    if (x != null) {
      final onLine = line.left - 0.5 < x && x < line.right + 0.5;
      canvas.drawRect(
        Rect.fromLTRB(x - 0.5, top, x + 0.5, bottom),
        Paint()..color = (onLine ? Colors.black : Colors.white).withValues(alpha: 0.33),
      );
    }
  }

  /// uosc's texture "b" (shown) or "a" (hidden) at 80 px: "/" stripes
  /// 1.6 px thick, white then black shifted by size / 24 (or / 28).
  void _hatch(Canvas canvas, double w, double top, double bottom) {
    final from = uncached;
    if (from == null) return;
    final ax = from * (geometry.width) < 0.5 ? 0.0 : geometry.x(from).floorToDouble();
    if (ax >= w) return;
    final shown = visibility > 0;
    const tile = 80.0, unit = tile / 100;
    final period = (shown ? 100 / 12 : 100 / 14) * unit;
    final phase = shown ? 0.0 : 5.727 * unit;
    final offset = tile / (shown ? 24 : 28);
    final h = bottom - top;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(ax, top, w, bottom));
    void stripes(Color color, double opacity, double anchor) {
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..strokeWidth = 2 * unit;
      // x + (y - bottom) = anchor + phase + k * period.
      final base = anchor + phase;
      final k0 = ((ax - h - base) / period).floor() - 1;
      for (var k = k0; base + k * period <= w + 1; k++) {
        final c = base + k * period;
        canvas.drawLine(Offset(c, bottom), Offset(c + h, top), paint);
      }
    }

    stripes(Colors.white, 0.4 - 0.2 * visibility, 0);
    stripes(Colors.black, 0.6 - 0.2 * visibility, offset);
    canvas.restore();
  }

  void _chapters(Canvas canvas) {
    final g = geometry;
    final r = g.diamondRadius;
    if (r <= 0) return;
    void diamond(double fraction, double radius) {
      final c = Offset(g.x(fraction), 0);
      Path shape(double r) => Path()
        ..moveTo(c.dx - r, c.dy)
        ..lineTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..close();
      final inner = shape(radius);
      // A 1 px border outside the fill (`\bord`), the fill translucent.
      final outer = shape(radius + UoscTimelineSpec.border * math.sqrt2);
      canvas.drawPath(Path.combine(PathOperation.difference, outer, inner), Paint()..color = Colors.black);
      canvas.drawPath(inner, Paint()..color = Colors.white.withValues(alpha: UoscTimelineSpec.chaptersOpacity));
    }

    for (var i = 0; i < chapters.length; i++) {
      if (i != hoveredChapter) diamond(chapters[i], r);
    }
    final h = hoveredChapter;
    if (h != null && h < chapters.length) diamond(chapters[h], r * 2);
  }

  TextPainter _text(String s, double fontSize, Color color, {Paint? foreground}) => TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        height: 1,
        color: foreground == null ? color : null,
        foreground: foreground,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  /// Text on the band: white with a black outline, inverted where it
  /// crosses the position line (uosc clips one copy to each).
  void _label(Canvas canvas, String s, double fontSize, double opacity, Offset at, Rect line, Size size) {
    void copy(Color fill, Color outline) {
      _text(
        s,
        fontSize,
        fill,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = UoscTimelineSpec.textBorder * 2
          ..strokeJoin = StrokeJoin.round
          ..color = outline.withValues(alpha: opacity),
      ).paint(canvas, at);
      _text(s, fontSize, fill.withValues(alpha: opacity)).paint(canvas, at);
    }

    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Rect.fromLTWH(-20, -20, size.width + 40, size.height + 40))
        ..addRect(line),
    );
    copy(Colors.white, Colors.black);
    canvas.restore();
    canvas.save();
    canvas.clipRect(line);
    copy(Colors.black, Colors.white);
    canvas.restore();
  }

  void _times(Canvas canvas, double w, double top, double bottom, Rect line) {
    const fs = UoscTimelineSpec.fontSize, spacing = UoscTimelineSpec.spacing;
    final size = Size(w, bottom);
    final cy = top + (bottom - top) / 2;
    final e = elapsed, r = remaining;
    final ew = e == null ? 0.0 : _text(e, fs, Colors.white).width;
    final rw = r == null ? 0.0 : _text(r, fs, Colors.white).width;
    final c = cache;
    if (c != null) {
      const cfs = fs * 0.8, margin = 5.0;
      final cw = _text(c, cfs, Colors.white).width;
      var x = line.right + margin;
      final minX = spacing + margin + ew, maxX = w - spacing - margin - rw;
      if (x < minX) {
        x = minX;
      } else if (x + cw > maxX) {
        x = maxX - cw;
      }
      _label(canvas, c, cfs, textOpacity * 0.6, Offset(x, cy - cfs / 2), line, size);
    }
    if (e != null) _label(canvas, e, fs, textOpacity, Offset(spacing, cy - fs / 2), line, size);
    if (r != null) _label(canvas, r, fs, textOpacity, Offset(w - spacing - rw, cy - fs / 2), line, size);
  }

  @override
  bool shouldRepaint(UoscTimelinePainter old) => true;
}
