import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../playback/media_marks.dart';
import 'controls.dart';
import 'style.dart';

/// Fraction of [total] at [d], 0..1 (0 without a duration).
double timelineFraction(Duration d, Duration total) {
  final t = total.inMicroseconds;
  if (t <= 0) return 0;
  return (d.inMicroseconds / t).clamp(0.0, 1.0);
}

/// The cached-ahead part of a timeline of [size]: from the playing
/// position to the end of mpv's cache. Null when nothing is cached ahead.
Rect? cacheRect(Size size, {required Duration position, required Duration buffered, required Duration duration}) {
  final from = timelineFraction(position, duration) * size.width;
  final to = timelineFraction(buffered, duration) * size.width;
  if (to - from < 0.5) return null;
  return Rect.fromLTRB(from, 0, to, size.height);
}

/// The hatching of [r]: 45° strokes from bottom-left to top-right,
/// [spacing] apart along x, across all of [r] (the painter clips them).
/// The first starts half a step in, so none just grazes the corner.
List<(Offset, Offset)> hatchLines(Rect r, {double spacing = 6}) {
  if (r.isEmpty || spacing <= 0) return const [];
  final h = r.height;
  return [
    for (var x = r.left - h + spacing / 2; x < r.right; x += spacing) (Offset(x, r.bottom), Offset(x + h, r.top)),
  ];
}

/// The uosc timeline: full width, elapsed part filled, the cached range
/// ahead hatched, chapter starts as white diamonds on the top edge, the
/// current time in a box at the left and the duration at the right.
/// Hover shows the chapter title over the hover time. When the controls
/// hide ([expanded] false) it shrinks to a thin line with chapter ticks.
/// Like the media_kit bar it reports a seek on every drag move and on
/// release ([onSeek]); the session sends those through the user-seek path.
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

  static const height = 30.0;
  static const collapsedHeight = 2.0;

  @override
  State<UoscTimeline> createState() => _UoscTimelineState();
}

class _UoscTimelineState extends State<UoscTimeline> {
  double? _hoverX;
  bool _dragging = false;
  double _dragFraction = 0;

  Duration _at(double fraction) => widget.duration * fraction.clamp(0.0, 1.0);

  void _seekTo(double x, double width) {
    if (widget.duration <= Duration.zero || width <= 0) return;
    _dragFraction = (x / width).clamp(0.0, 1.0);
    widget.onSeek(_at(_dragFraction));
  }

  void _drag(bool on) {
    if (_dragging == on) return;
    setState(() => _dragging = on);
    UoscControls.maybeOf(context)?.hold(on);
  }

  @override
  void didUpdateWidget(UoscTimeline old) {
    super.didUpdateWidget(old);
    if (!widget.expanded && old.expanded) _hoverX = null;
  }

  @override
  void dispose() {
    // A drag cut short by a rebuild must not keep the controls up.
    if (_dragging) UoscControls.maybeOf(context)?.hold(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final expanded = widget.expanded;
      final h = expanded ? UoscTimeline.height : UoscTimeline.collapsedHeight;
      final played = _dragging ? _dragFraction : timelineFraction(widget.position, widget.duration);
      final hoverX = expanded ? _hoverX : null;
      final hoverAt = hoverX == null || width <= 0 ? null : _at(hoverX / width);
      final hoverChapter = hoverAt == null ? null : chapterIndexAt(widget.chapters, hoverAt);
      final hoverTitle = hoverChapter == null ? '' : widget.chapters[hoverChapter].title;
      final withHours = widget.duration >= const Duration(hours: 1);
      final marks = [
        for (final c in widget.chapters)
          if (c.start > Duration.zero && widget.duration > Duration.zero) c,
      ];
      final bar = SizedBox(
        key: const ValueKey('uosc-timeline'),
        width: width,
        height: h,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: UoscTimelinePainter(
                  played: played,
                  cache: (size) => cacheRect(size,
                      position: widget.position, buffered: widget.buffered, duration: widget.duration),
                  cacheKey: (widget.position, widget.buffered, widget.duration),
                  hoverX: _dragging ? null : hoverX,
                  hatched: expanded,
                ),
              ),
            ),
            for (final c in marks)
              if (expanded)
                Positioned(
                  key: ValueKey('uosc-chapter-${c.index}'),
                  left: width * timelineFraction(c.start, widget.duration) - 4,
                  top: -4,
                  width: 8,
                  height: 8,
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: math.pi / 4,
                      child: Container(
                        margin: const EdgeInsets.all(1.2),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.black54, width: 0.6),
                        ),
                      ),
                    ),
                  ),
                )
              else
                Positioned(
                  key: ValueKey('uosc-chapter-tick-${c.index}'),
                  left: width * timelineFraction(c.start, widget.duration) - 1,
                  top: -2,
                  width: 2,
                  height: h + 2,
                  child: const IgnorePointer(child: ColoredBox(color: Colors.white70)),
                ),
            if (expanded) ...[
              Positioned(
                left: 4,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Center(
                    child: UoscBox(formatUoscTime(_at(played), withHours: withHours),
                        key: const ValueKey('uosc-time'), color: UoscStyle.bar),
                  ),
                ),
              ),
              Positioned(
                right: 4,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Center(
                    child: UoscBox(formatUoscTime(widget.duration, withHours: withHours),
                        key: const ValueKey('uosc-duration'), color: UoscStyle.bar),
                  ),
                ),
              ),
            ],
            if (hoverAt != null)
              Positioned(
                // Kept clear of the window edges (the tip is centred).
                left: hoverX!.clamp(math.min(60.0, width / 2), math.max(width - 60, width / 2)),
                bottom: h + 8,
                child: IgnorePointer(
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        if (hoverTitle.isNotEmpty) UoscBox(hoverTitle, key: const ValueKey('uosc-hover-chapter')),
                        UoscBox(formatUoscTime(hoverAt, withHours: withHours),
                            key: const ValueKey('uosc-hover-time')),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
      if (!expanded) return IgnorePointer(child: bar);
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (e) => setState(() => _hoverX = e.localPosition.dx.clamp(0, width)),
        onHover: (e) => setState(() => _hoverX = e.localPosition.dx.clamp(0, width)),
        onExit: (_) => setState(() => _hoverX = null),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            _dragFraction = width <= 0 ? 0 : (e.localPosition.dx / width).clamp(0.0, 1.0);
            _drag(true);
          },
          onPointerMove: (e) {
            setState(() => _hoverX = e.localPosition.dx.clamp(0, width));
            _seekTo(e.localPosition.dx, width);
          },
          onPointerUp: (e) {
            _seekTo(e.localPosition.dx, width);
            _drag(false);
          },
          onPointerCancel: (_) => _drag(false),
          child: bar,
        ),
      );
    });
  }
}

/// Background, cached range (hatched, or a faint band when collapsed),
/// the played part and the hover line.
class UoscTimelinePainter extends CustomPainter {
  final double played;
  final Rect? Function(Size size) cache;
  /// What [cache] depends on (repaint when it changes).
  final Object cacheKey;
  final double? hoverX;
  final bool hatched;
  const UoscTimelinePainter({
    required this.played,
    required this.cache,
    required this.cacheKey,
    this.hoverX,
    this.hatched = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final all = Offset.zero & size;
    canvas.drawRect(all, Paint()..color = UoscStyle.bar);
    final c = cache(size);
    if (c != null) {
      if (hatched) {
        canvas.save();
        canvas.clipRect(c);
        final stroke = Paint()
          ..color = const Color(0x40FFFFFF)
          ..strokeWidth = 1.5;
        for (final (a, b) in hatchLines(c)) {
          canvas.drawLine(a, b, stroke);
        }
        canvas.restore();
      } else {
        canvas.drawRect(c, Paint()..color = const Color(0x40FFFFFF));
      }
    }
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * played, size.height), Paint()..color = UoscStyle.fill);
    final x = hoverX;
    if (x != null) {
      canvas.drawRect(Rect.fromLTWH(x - 0.5, 0, 1, size.height), Paint()..color = Colors.white70);
    }
  }

  @override
  bool shouldRepaint(UoscTimelinePainter old) =>
      old.played != played || old.cacheKey != cacheKey || old.hoverX != hoverX || old.hatched != hatched;
}
