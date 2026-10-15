import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../playback/media_marks.dart';
import '../frame.dart';
import 'style.dart';

// The Minimal skin's timeline: a band across the bottom with the played
// part tinted in the accent and the position as a line, the part not
// downloaded yet striped, chapter starts as dots on the top edge (click one
// to jump), the elapsed time left and the total or the time left right,
// the buffered seconds by the position while under a minute, and a tip
// with the time (and the chapter title) under the mouse. Hidden, it shrinks
// to a thin progress line.
//
// Inspired by the timeline of uosc (github.com/tomasklaen/uosc, LGPL-2.1,
// by tomasklaen): the striped unbuffered part, the remaining time and the
// thin line when hidden come from there. The drawing, geometry and values
// here are our own.

/// Sizes at scale 1.
abstract final class MinimalTimelineSpec {
  /// The band's height while the controls are up.
  static const size = 36.0;

  /// What is left of it while they are hidden.
  static const lineSize = 3.0;

  /// The position line.
  static const lineWidth = 2.0;
  static const fontSize = 15.0;

  /// The times' inset from the ends.
  static const inset = 12.0;

  /// A chapter dot's radius (doubled-ish while hovered).
  static const dot = 3.5;

  /// The cache label shows while less than this is buffered ahead.
  static const bufferedThreshold = Duration(seconds: 60);

  /// Collapse / grow.
  static const animation = Duration(milliseconds: 120);
}

/// Fraction of [total] at [d], 0..1 (0 without a duration).
double timelineFraction(Duration d, Duration total) {
  final t = total.inMicroseconds;
  if (t <= 0) return 0;
  return (d.inMicroseconds / t).clamp(0.0, 1.0);
}

/// Where the part not downloaded yet starts (it runs to the end), as a
/// fraction; null when nothing known is missing. We know only the end of
/// mpv's cache ahead ([buffered]); a cache within half a second of the end
/// leaves nothing.
double? uncachedFrom({required Duration position, required Duration buffered, required Duration duration}) {
  if (duration <= Duration.zero || buffered <= Duration.zero) return null;
  final from = buffered > position ? buffered : position;
  if (duration - from <= const Duration(milliseconds: 500)) return null;
  return timelineFraction(from, duration);
}

/// The cache label by the position ("12s"): the seconds buffered ahead,
/// while under [MinimalTimelineSpec.bufferedThreshold] and the cache does
/// not reach the end.
String? cacheLabel({required Duration position, required Duration buffered, required Duration duration}) {
  if (duration <= Duration.zero || buffered <= Duration.zero) return null;
  if (duration - buffered <= const Duration(milliseconds: 500)) return null;
  final ahead = buffered > position ? buffered - position : Duration.zero;
  if (ahead >= MinimalTimelineSpec.bufferedThreshold) return null;
  return '${(ahead.inMilliseconds / 1000).round()}s';
}

/// The band's height while it animates between hidden (0) and shown (1).
double minimalBandSize(double visibility, double scale) =>
    MinimalTimelineSpec.lineSize +
    ((MinimalTimelineSpec.size * scale - MinimalTimelineSpec.lineSize) * visibility).roundToDouble();

/// The Minimal timeline. [expanded] false (the controls hidden) shrinks it,
/// animated, to the progress line. Seeks ([onSeek]) on press, on every drag
/// move and on release; a press on a hovered chapter dot jumps to that
/// chapter, one on the right-hand time switches it ([onToggleTime]).
class MinimalTimeline extends StatefulWidget {
  final Duration position;
  final Duration duration;

  /// End of the cached range.
  final Duration buffered;
  final List<MediaChapter> chapters;
  final bool expanded;

  /// The right-hand time: the time left instead of the total.
  final bool remaining;
  final double scale;
  final ValueChanged<Duration> onSeek;
  final VoidCallback? onToggleTime;
  const MinimalTimeline({
    super.key,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    this.chapters = const [],
    this.expanded = true,
    this.remaining = true,
    this.scale = 1,
    required this.onSeek,
    this.onToggleTime,
  });

  static double heightFor(double scale) => MinimalTimelineSpec.size * scale;
  static const collapsedHeight = MinimalTimelineSpec.lineSize;

  @override
  State<MinimalTimeline> createState() => _MinimalTimelineState();
}

class _MinimalTimelineState extends State<MinimalTimeline> {
  Offset? _hover;
  bool _dragging = false;
  double _dragFraction = 0;
  Duration? _lastSent;
  // A released seek, shown until the position catches up (else the line
  // jumps back to the old position for a moment).
  double? _pending;
  Timer? _pendingTimer;

  double get _scale => widget.scale;
  Duration _at(double fraction) => widget.duration * fraction.clamp(0.0, 1.0);

  void _send(Duration d) {
    if (d == _lastSent) return;
    _lastSent = d;
    widget.onSeek(d);
  }

  void _drag(bool on) {
    if (_dragging == on) return;
    setState(() => _dragging = on);
    ControlsFrame.maybeOf(context)?.hold(on);
  }

  void _settle(double fraction) {
    _pending = fraction;
    _pendingTimer?.cancel();
    _pendingTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _pending = null);
    });
  }

  @override
  void didUpdateWidget(MinimalTimeline old) {
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
    if (_dragging) ControlsFrame.maybeOf(context)?.hold(false);
    super.dispose();
  }

  double _dotRadius(bool hovered) => MinimalTimelineSpec.dot * _scale * (hovered ? 1.7 : 1);

  /// The chapter whose dot is within reach of [at].
  int? _hoveredChapter(double width, List<MediaChapter> marks, Offset? at) {
    if (at == null || _dragging) return null;
    final reach = _dotRadius(false) * 2.5;
    int? best;
    var bestD = double.infinity;
    for (var i = 0; i < marks.length; i++) {
      final cx = width * timelineFraction(marks[i].start, widget.duration);
      final d = (Offset(cx, 0) - at).distance;
      if (d <= reach && d < bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  String? _rightText(Duration shown) {
    final d = widget.duration;
    if (d <= Duration.zero) return null;
    if (!widget.remaining) return formatClock(d);
    final left = d - shown;
    return '-${formatClock(left.isNegative ? Duration.zero : left)}';
  }

  // The painter's text takes the app's font (a TextPainter does not
  // inherit it).
  String? _font;

  TextStyle get _timeStyle => TextStyle(
    fontFamily: _font,
    color: MinimalStyle.text,
    fontSize: MinimalTimelineSpec.fontSize * _scale,
    height: 1,
    fontWeight: FontWeight.w500,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Where the right-hand time sits (a press there switches it).
  bool _onRightTime(Offset at, double width, String? text) {
    if (text == null || widget.onToggleTime == null) return false;
    final tp = TextPainter(
      text: TextSpan(text: text, style: _timeStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return at.dx >= width - MinimalTimelineSpec.inset * _scale - tp.width - 6;
  }

  @override
  Widget build(BuildContext context) {
    _font = DefaultTextStyle.of(context).style.fontFamily ?? Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return LayoutBuilder(
      builder: (context, constraints) => TweenAnimationBuilder<double>(
        tween: Tween(end: widget.expanded ? 1 : 0),
        duration: MinimalTimelineSpec.animation,
        builder: (context, visibility, _) => _band(context, constraints.maxWidth, visibility),
      ),
    );
  }

  Widget _band(BuildContext context, double width, double visibility) {
    final expanded = widget.expanded;
    final duration = widget.duration;
    final size = minimalBandSize(visibility, _scale);
    final progress = _dragging ? _dragFraction : (_pending ?? timelineFraction(widget.position, duration));
    final shown = _at(progress);
    final marks = duration > Duration.zero ? widget.chapters : const <MediaChapter>[];
    final hover = expanded ? _hover : null;
    final hovered = _hoveredChapter(width, marks, hover);
    final hoverFraction = hovered != null
        ? timelineFraction(marks[hovered].start, duration)
        : (hover == null || duration <= Duration.zero || width <= 0 ? null : (hover.dx / width).clamp(0.0, 1.0));
    final hoverAt = hoverFraction == null ? null : _at(hoverFraction);
    final cursorX = hoverFraction == null ? null : width * hoverFraction;
    final hoverChapter = hoverAt == null ? null : chapterIndexAt(widget.chapters, hoverAt);
    final hoverTitle = hoverChapter == null ? '' : widget.chapters[hoverChapter].title;
    // Text fades out before it would overflow the shrinking band.
    final minText = MinimalTimelineSpec.fontSize * _scale;
    final textOpacity = ((size - minText) / (minText / 2)).clamp(0.0, 1.0);
    final right = _rightText(shown);
    final primary = Theme.of(context).colorScheme.primary;
    final painter = MinimalTimelinePainter(
      progress: progress,
      visibility: visibility,
      accent: primary,
      scale: _scale,
      uncached: uncachedFrom(position: widget.position, buffered: widget.buffered, duration: duration),
      chapters: [for (final c in marks) timelineFraction(c.start, duration)],
      hoveredChapter: hovered,
      hoverX: hovered == null ? cursorX : null,
      textOpacity: textOpacity,
      elapsed: duration > Duration.zero ? formatClock(shown) : null,
      right: right,
      cache: cacheLabel(position: widget.position, buffered: widget.buffered, duration: duration),
      timeStyle: _timeStyle,
    );
    final bar = SizedBox(
      key: const ValueKey('minimal-timeline'),
      width: width,
      height: size,
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
              bottom: size + 8,
              height: 120,
              child: IgnorePointer(
                child: CustomMultiChildLayout(
                  delegate: _TipLayout(x: cursorX),
                  children: [
                    LayoutId(
                      id: #tip,
                      child: _HoverTip(time: formatClock(hoverAt), chapter: hoverTitle, scale: _scale),
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
          if (width <= 0) return;
          final at = clampTo(e.localPosition);
          if (_onRightTime(at, width, right)) {
            widget.onToggleTime?.call();
            return;
          }
          if (duration <= Duration.zero) return;
          final chapter = _hoveredChapter(width, marks, at);
          _lastSent = null;
          if (chapter != null) {
            _settle(timelineFraction(marks[chapter].start, duration));
            _send(marks[chapter].start);
            setState(() {});
            return;
          }
          _pending = null;
          _dragFraction = (at.dx / width).clamp(0.0, 1.0);
          _drag(true);
          _send(_at(_dragFraction));
        },
        onPointerMove: (e) {
          if (!_dragging) return;
          final at = clampTo(e.localPosition);
          setState(() {
            _hover = at;
            _dragFraction = (at.dx / width).clamp(0.0, 1.0);
          });
          _send(_at(_dragFraction));
        },
        onPointerUp: (e) {
          if (!_dragging) return;
          _send(_at(_dragFraction));
          _settle(_dragFraction);
          final p = e.localPosition;
          if (p.dx < 0 || p.dx > width || p.dy < 0 || p.dy > size) _hover = null;
          _drag(false);
        },
        onPointerCancel: (_) => _drag(false),
        child: bar,
      ),
    );
  }
}

class _HoverTip extends StatelessWidget {
  final String time;
  final String chapter;
  final double scale;
  const _HoverTip({required this.time, required this.chapter, required this.scale});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 5 * scale),
      decoration: BoxDecoration(
        color: MinimalStyle.tip,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x1FFFFFFF), width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chapter.isNotEmpty)
            Text(
              chapter,
              key: const ValueKey('minimal-hover-chapter'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: MinimalStyle.text, fontSize: 13 * scale, fontWeight: FontWeight.w600),
            ),
          Text(
            time,
            key: const ValueKey('minimal-hover-time'),
            style: TextStyle(
              color: chapter.isEmpty ? MinimalStyle.text : MinimalStyle.dim,
              fontSize: 13 * scale,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// The hover tip centred on [x], kept inside the band's ends.
class _TipLayout extends MultiChildLayoutDelegate {
  final double x;
  _TipLayout({required this.x});

  @override
  void performLayout(Size size) {
    const gap = 4.0;
    final tip = layoutChild(#tip, BoxConstraints.loose(size));
    final left = (x - tip.width / 2).clamp(gap, math.max(gap, size.width - gap - tip.width)).toDouble();
    positionChild(#tip, Offset(left, size.height - tip.height));
  }

  @override
  bool shouldRelayout(_TipLayout old) => old.x != x;
}

/// Paints the band: background, the played tint and the (white) position
/// line, the stripes over the part not downloaded, chapter marks, the
/// times, the hover line.
class MinimalTimelinePainter extends CustomPainter {
  /// The playing position, 0..1.
  final double progress;

  /// 0 hidden .. 1 shown.
  final double visibility;
  final Color accent;
  final double scale;

  /// Start of the part not downloaded (to the end), as a fraction.
  final double? uncached;

  /// Chapter starts, as fractions.
  final List<double> chapters;
  final int? hoveredChapter;
  final double? hoverX;
  final double textOpacity;
  final String? elapsed;
  final String? right;
  final String? cache;
  final TextStyle timeStyle;
  const MinimalTimelinePainter({
    required this.progress,
    this.visibility = 1,
    this.accent = Colors.white,
    this.scale = 1,
    this.uncached,
    this.chapters = const [],
    this.hoveredChapter,
    this.hoverX,
    this.textOpacity = 1,
    this.elapsed,
    this.right,
    this.cache,
    this.timeStyle = const TextStyle(fontSize: MinimalTimelineSpec.fontSize),
  });

  /// x of the position line's centre.
  double lineX(double width) {
    final lw = MinimalTimelineSpec.lineWidth * scale;
    return (width * progress).clamp(lw / 2, math.max(lw / 2, width - lw / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final x = lineX(w);
    final band = Offset.zero & size;
    // The band, darker as it grows; hidden, a faint track.
    canvas.drawRect(band, Paint()..color = Color.lerp(const Color(0x40FFFFFF), MinimalStyle.band, visibility)!);
    // Played: an accent tint, solid once the band is a line.
    canvas.drawRect(
      Rect.fromLTRB(0, 0, x, h),
      Paint()..color = accent.withValues(alpha: 0.28 + 0.72 * (1 - visibility)),
    );
    _stripes(canvas, w, h);
    _chapters(canvas, w, h);
    if (visibility > 0) {
      final lw = MinimalTimelineSpec.lineWidth * scale;
      canvas.drawRect(
        Rect.fromLTRB(x - lw / 2, 0, x + lw / 2, h),
        Paint()..color = Colors.white.withValues(alpha: visibility),
      );
    }
    if (textOpacity > 0) _times(canvas, w, h, x);
    final hx = hoverX;
    if (hx != null) {
      canvas.drawRect(Rect.fromLTRB(hx - 0.5, 0, hx + 0.5, h), Paint()..color = Colors.white.withValues(alpha: 0.45));
    }
  }

  /// Thin 45° stripes over the part not downloaded yet.
  void _stripes(Canvas canvas, double w, double h) {
    final from = uncached;
    if (from == null) return;
    final ax = (w * from).floorToDouble();
    if (ax >= w) return;
    final period = 7.0 * scale;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(ax, 0, w, h));
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.10 + 0.08 * (1 - visibility))
      ..strokeWidth = 1.5 * scale;
    for (var c = (ax / period).floorToDouble() * period - h; c <= w; c += period) {
      canvas.drawLine(Offset(c, h), Offset(c + h, 0), paint);
    }
    canvas.restore();
  }

  void _chapters(Canvas canvas, double w, double h) {
    final cut = Paint()..color = Colors.black.withValues(alpha: 0.55);
    for (final f in chapters) {
      if (f <= 0) continue;
      final cx = w * f;
      canvas.drawRect(Rect.fromLTRB(cx - 0.5, 0, cx + 0.5, h), cut);
    }
    if (visibility <= 0) return;
    final r = MinimalTimelineSpec.dot * scale * visibility;
    void dot(double f, double radius, Color fill) {
      final c = Offset(w * f, 0);
      canvas.drawCircle(c, radius + 1, Paint()..color = Colors.black.withValues(alpha: 0.7));
      canvas.drawCircle(c, radius, Paint()..color = fill);
    }

    // Not at 0: the band's start says that already.
    for (var i = 0; i < chapters.length; i++) {
      if (i != hoveredChapter && chapters[i] > 0) dot(chapters[i], r, Colors.white.withValues(alpha: 0.9));
    }
    final hv = hoveredChapter;
    if (hv != null && hv < chapters.length) dot(chapters[hv], r * 1.7, accent);
  }

  TextPainter _text(String s, TextStyle style) => TextPainter(
    text: TextSpan(text: s, style: style),
    textDirection: TextDirection.ltr,
  )..layout();

  /// White text with a soft shadow, so it reads over the accent tint too.
  void _label(Canvas canvas, String s, TextStyle style, Offset at) {
    final o = textOpacity;
    _text(
      s,
      style.copyWith(
        color: (style.color ?? Colors.white).withValues(alpha: o),
        shadows: [Shadow(color: Colors.black.withValues(alpha: 0.8 * o), blurRadius: 3)],
      ),
    ).paint(canvas, at);
  }

  void _times(Canvas canvas, double w, double h, double lineX) {
    final inset = MinimalTimelineSpec.inset * scale;
    final fs = timeStyle.fontSize ?? MinimalTimelineSpec.fontSize;
    final cy = h / 2;
    final e = elapsed, r = right;
    final ew = e == null ? 0.0 : _text(e, timeStyle).width;
    final rw = r == null ? 0.0 : _text(r, timeStyle).width;
    final c = cache;
    if (c != null) {
      final cs = timeStyle.copyWith(fontSize: fs * 0.8, color: MinimalStyle.dim);
      final cw = _text(c, cs).width;
      const margin = 6.0;
      var x = lineX + margin;
      final minX = inset + margin + ew, maxX = w - inset - margin - rw;
      if (x < minX) {
        x = minX;
      } else if (x + cw > maxX) {
        x = maxX - cw;
      }
      _label(canvas, c, cs, Offset(x, cy - fs * 0.4));
    }
    if (e != null) _label(canvas, e, timeStyle, Offset(inset, cy - fs / 2));
    if (r != null) _label(canvas, r, timeStyle, Offset(w - inset - rw, cy - fs / 2));
  }

  @override
  bool shouldRepaint(MinimalTimelinePainter old) => true;
}
