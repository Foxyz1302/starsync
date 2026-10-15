import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../playback/media_marks.dart';
import '../frame.dart';

// The Standard skin's seek bar: a Material-style track with the played and
// buffered parts, chapter marks and a hover tip.

/// The seek bar: played / buffered track, a diamond at each chapter start
/// (not the one at 0), and on hover the time with the chapter title above
/// it. Like media_kit's bar it reports a seek on every drag move and on
/// release ([onSeek]); the session routes those through the user-seek path
/// (debounced, everyone follows).
class ChapterSeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final List<MediaChapter> chapters;
  final ValueChanged<Duration> onSeek;

  /// The bar's height (its hit area); the track is centred in it.
  final double height;
  const ChapterSeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffer = Duration.zero,
    this.chapters = const [],
    required this.onSeek,
    this.height = ChapterSeekBar.defaultHeight,
  });

  static const defaultHeight = 28.0;

  @override
  State<ChapterSeekBar> createState() => _ChapterSeekBarState();
}

class _ChapterSeekBarState extends State<ChapterSeekBar> {
  double? _hoverX;
  bool _dragging = false;
  double _dragFraction = 0;

  double _fraction(Duration d) {
    final total = widget.duration.inMicroseconds;
    if (total <= 0) return 0;
    return (d.inMicroseconds / total).clamp(0.0, 1.0);
  }

  Duration _at(double fraction) => widget.duration * fraction.clamp(0.0, 1.0);

  // A drag sends no hover events: the controls are held up through it.
  void _drag(bool on) {
    if (_dragging == on) return;
    setState(() => _dragging = on);
    ControlsFrame.maybeOf(context)?.hold(on);
  }

  @override
  void dispose() {
    if (_dragging) ControlsFrame.maybeOf(context)?.hold(false);
    super.dispose();
  }

  void _seekTo(double x, double width) {
    if (widget.duration <= Duration.zero || width <= 0) return;
    _dragFraction = (x / width).clamp(0.0, 1.0);
    widget.onSeek(_at(_dragFraction));
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final active = _hoverX != null || _dragging;
        final barHeight = active ? 5.0 : 3.0;
        final played = _dragging ? _dragFraction : _fraction(widget.position);
        final mid = widget.height / 2;
        final hoverX = _hoverX;
        final hoverAt = hoverX == null || width <= 0 ? null : _at(hoverX / width);
        final hoverChapter = hoverAt == null ? null : chapterIndexAt(widget.chapters, hoverAt);
        final hoverTitle = hoverChapter == null ? '' : widget.chapters[hoverChapter].title;
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
            child: SizedBox(
              key: const ValueKey('seek-bar'),
              width: width,
              height: widget.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: mid - barHeight / 2,
                    height: barHeight,
                    child: Container(color: Colors.white24),
                  ),
                  Positioned(
                    left: 0,
                    top: mid - barHeight / 2,
                    height: barHeight,
                    width: width * _fraction(widget.buffer),
                    child: Container(color: Colors.white24),
                  ),
                  if (hoverX != null && !_dragging)
                    Positioned(
                      left: 0,
                      top: mid - barHeight / 2,
                      height: barHeight,
                      width: hoverX,
                      child: Container(color: Colors.white24),
                    ),
                  Positioned(
                    left: 0,
                    top: mid - barHeight / 2,
                    height: barHeight,
                    width: width * played,
                    child: Container(color: primary),
                  ),
                  for (final c in widget.chapters)
                    if (c.start > Duration.zero && widget.duration > Duration.zero)
                      Positioned(
                        key: ValueKey('chapter-mark-${c.index}'),
                        left: width * _fraction(c.start) - 4,
                        top: mid - 4,
                        width: 8,
                        height: 8,
                        child: IgnorePointer(
                          child: Transform.rotate(
                            angle: math.pi / 4,
                            child: Container(
                              margin: const EdgeInsets.all(1),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(color: Colors.black54, width: 0.8),
                              ),
                            ),
                          ),
                        ),
                      ),
                  if (active)
                    Positioned(
                      left: width * played - 6,
                      top: mid - 6,
                      width: 12,
                      height: 12,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                  if (hoverAt != null)
                    Positioned(
                      // Kept clear of the window edges (the tip is centred).
                      left: hoverX!.clamp(math.min(60.0, width / 2), math.max(width - 60, width / 2)),
                      bottom: widget.height - 2,
                      child: IgnorePointer(
                        child: FractionalTranslation(
                          translation: const Offset(-0.5, 0),
                          child: _HoverTip(title: hoverTitle, time: formatClock(hoverAt)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HoverTip extends StatelessWidget {
  final String title;
  final String time;
  const _HoverTip({required this.title, required this.time});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(6)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Text(
              title,
              key: const ValueKey('seek-hover-chapter'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          Text(
            time,
            key: const ValueKey('seek-hover-time'),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
