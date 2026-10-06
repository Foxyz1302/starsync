import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../../jellyfin/track_prefs.dart' show MpvTrack;
import '../../playback/media_marks.dart';

// Session control-bar pieces built on the playback signals (chapters,
// tracks, skip offers): the seek bar with chapter marks, the chapter and
// track menus, the 1:30 skip button and the floating skip pill. Plain
// widgets fed by values and callbacks, so tests pump them without a player.

/// Keeps media_kit's desktop controls shown, as a mouse hover would.
/// While a seek bar drag runs no hover events arrive, and the controls
/// would hide (and unmount the bar) mid-drag. A guarded dynamic call on
/// the private controls state; nothing happens outside those controls.
void keepVideoControlsAwake(BuildContext context) {
  context.visitAncestorElements((e) {
    if (e is StatefulElement &&
        e.state.runtimeType.toString() == '_MaterialDesktopVideoControlsState') {
      try {
        (e.state as dynamic).onHover();
      } catch (_) {}
      return false;
    }
    return true;
  });
}

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
  /// Any pointer activity on the bar (keeps the controls up).
  final VoidCallback? onActivity;
  const ChapterSeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffer = Duration.zero,
    this.chapters = const [],
    required this.onSeek,
    this.onActivity,
  });

  static const height = 28.0;

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

  void _seekTo(double x, double width) {
    if (widget.duration <= Duration.zero || width <= 0) return;
    _dragFraction = (x / width).clamp(0.0, 1.0);
    widget.onSeek(_at(_dragFraction));
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final active = _hoverX != null || _dragging;
      final barHeight = active ? 5.0 : 3.0;
      final played = _dragging ? _dragFraction : _fraction(widget.position);
      const mid = ChapterSeekBar.height / 2;
      final hoverX = _hoverX;
      final hoverAt = hoverX == null || width <= 0 ? null : _at(hoverX / width);
      final hoverChapter = hoverAt == null ? null : chapterIndexAt(widget.chapters, hoverAt);
      final hoverTitle = hoverChapter == null ? '' : widget.chapters[hoverChapter].title;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (e) => setState(() => _hoverX = e.localPosition.dx.clamp(0, width)),
        onHover: (e) {
          setState(() => _hoverX = e.localPosition.dx.clamp(0, width));
          widget.onActivity?.call();
        },
        onExit: (_) => setState(() => _hoverX = null),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            widget.onActivity?.call();
            setState(() {
              _dragging = true;
              _dragFraction = width <= 0 ? 0 : (e.localPosition.dx / width).clamp(0.0, 1.0);
            });
          },
          onPointerMove: (e) {
            widget.onActivity?.call();
            setState(() => _hoverX = e.localPosition.dx.clamp(0, width));
            _seekTo(e.localPosition.dx, width);
          },
          onPointerUp: (e) {
            _seekTo(e.localPosition.dx, width);
            setState(() => _dragging = false);
            widget.onActivity?.call();
          },
          onPointerCancel: (_) => setState(() => _dragging = false),
          child: SizedBox(
            key: const ValueKey('seek-bar'),
            width: width,
            height: ChapterSeekBar.height,
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
                    bottom: ChapterSeekBar.height - 2,
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
    });
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
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Text(title,
                key: const ValueKey('seek-hover-chapter'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          Text(time,
              key: const ValueKey('seek-hover-time'),
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}

/// [ChapterSeekBar] on a live player: position, duration and buffer from
/// its streams. Seeks go to `player.seek`, which the session's
/// `SyncPlayer` turns into user seeks.
class PlayerSeekBar extends StatefulWidget {
  final Player player;
  final List<MediaChapter> chapters;
  const PlayerSeekBar({super.key, required this.player, required this.chapters});

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  final List<StreamSubscription<Object>> _subs = [];
  late Duration _position, _duration, _buffer;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(PlayerSeekBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.player, widget.player)) {
      _cancel();
      _listen();
    }
  }

  void _listen() {
    final p = widget.player;
    _position = p.state.position;
    _duration = p.state.duration;
    _buffer = p.state.buffer;
    void set(VoidCallback f) {
      if (mounted) setState(f);
    }

    _subs.addAll([
      p.stream.position.listen((d) => set(() => _position = d)),
      p.stream.duration.listen((d) => set(() => _duration = d)),
      p.stream.buffer.listen((d) => set(() => _buffer = d)),
    ]);
  }

  void _cancel() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChapterSeekBar(
      position: _position,
      duration: _duration,
      buffer: _buffer,
      chapters: widget.chapters,
      onSeek: (d) => widget.player.seek(d),
      onActivity: () => keepVideoControlsAwake(context),
    );
  }
}

RelativeRect _menuPosition(BuildContext context) {
  final button = context.findRenderObject() as RenderBox;
  final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  return RelativeRect.fromRect(
    Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
}

/// Control-bar icon with a small count in the corner.
class _BadgedIcon extends StatelessWidget {
  final IconData icon;
  final int count;
  const _BadgedIcon(this.icon, this.count);

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        if (count > 0)
          Positioned(
            right: -7,
            top: -5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('$count',
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }
}

/// Chapter list for the controls: current chapter checked, a pick seeks
/// to its start. Nothing when the file has no chapters.
class ChaptersControlButton extends StatelessWidget {
  final List<MediaChapter> chapters;
  final int? current;
  final ValueChanged<MediaChapter> onPick;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onMenuOpen;
  const ChaptersControlButton({
    super.key,
    required this.chapters,
    required this.current,
    required this.onPick,
    this.focusNode,
    this.onMenuOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (chapters.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: 'Chapters (PgUp / PgDn)',
      child: IconButton(
        key: const ValueKey('chapters-button'),
        focusNode: focusNode,
        color: Colors.white,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        icon: _BadgedIcon(Icons.format_list_bulleted, chapters.length),
        onPressed: () => _open(context),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final position = _menuPosition(context);
    onMenuOpen?.call(true);
    final pick = await showMenu<MediaChapter>(
      context: context,
      position: position,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 420),
      items: [
        for (final c in chapters)
          CheckedPopupMenuItem(
            value: c,
            checked: c.index == current,
            height: 36,
            child: Row(
              children: [
                Expanded(
                  child: Text(c.title.isEmpty ? 'Chapter ${c.index + 1}' : c.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 12),
                Text(formatClock(c.start), style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
      ],
    );
    onMenuOpen?.call(false);
    if (pick != null) onPick(pick);
  }
}

/// A track pick from [TrackMenuButton]: audio id, subtitle id, or off.
typedef TrackPick = ({int? aid, int? sid, bool subtitlesOff});

/// Audio or subtitle menu for the controls bar (the count of tracks on the
/// icon): "Japanese · E-AC3 2.0 · title", mpv's selection checked,
/// subtitles with Off. The choice is remembered for the next Jellyfin item
/// (per viewer).
class TrackMenuButton extends StatelessWidget {
  final JellyfinStreamType type;
  /// All tracks; only those of [type] are listed.
  final List<MpvTrack> tracks;
  final void Function(TrackPick pick) onPick;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onMenuOpen;
  const TrackMenuButton({
    super.key,
    required this.type,
    required this.tracks,
    required this.onPick,
    this.focusNode,
    this.onMenuOpen,
  });

  bool get _audio => type == JellyfinStreamType.audio;

  @override
  Widget build(BuildContext context) {
    final list = tracks.where((t) => t.type == type).toList();
    return Tooltip(
      message: _audio ? 'Audio' : 'Subtitles',
      child: IconButton(
        key: ValueKey(_audio ? 'audio-button' : 'subtitles-button'),
        focusNode: focusNode,
        color: Colors.white,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        icon: _BadgedIcon(_audio ? Icons.audiotrack_outlined : Icons.subtitles_outlined, list.length),
        onPressed: () => _open(context, list),
      ),
    );
  }

  Future<void> _open(BuildContext context, List<MpvTrack> list) async {
    final position = _menuPosition(context);
    onMenuOpen?.call(true);
    final pick = await showMenu<TrackPick>(
      context: context,
      position: position,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 460),
      items: [
        if (!_audio)
          CheckedPopupMenuItem(
            value: (aid: null, sid: null, subtitlesOff: true),
            checked: !list.any((t) => t.selected),
            height: 36,
            child: const Text('Off'),
          ),
        if (_audio && list.isEmpty)
          const PopupMenuItem(enabled: false, height: 32, child: Text('None')),
        for (final t in list)
          CheckedPopupMenuItem(
            value: _audio
                ? (aid: t.id, sid: null, subtitlesOff: false)
                : (aid: null, sid: t.id, subtitlesOff: false),
            checked: t.selected,
            height: 36,
            child: Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
    onMenuOpen?.call(false);
    if (pick != null) onPick(pick);
  }
}

/// "1:30" in the controls: skip forward [fallbackSkip] (Shift+Right).
class SkipForwardButton extends StatelessWidget {
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  const SkipForwardButton({super.key, required this.onPressed, this.focusNode});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Skip 1:30 for everyone (Shift+Right)',
      child: TextButton.icon(
        key: const ValueKey('skip-forward-button'),
        focusNode: focusNode,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.fast_forward_rounded, size: 16),
        label: const Text('1:30', style: TextStyle(fontSize: 12)),
      ),
    );
  }
}

/// Floating pill over the video (Next episode, Skip OP / ED / 1:30):
/// faint at rest, lit on hover. Lives outside the auto-hiding controls, so
/// it shows in fullscreen and with the controls hidden.
class FloatingPill extends StatefulWidget {
  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  /// Key of the tap target (tests find the pill by it).
  final Key? tapKey;
  const FloatingPill({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.icon = Icons.chevron_right,
    this.tapKey,
  });

  @override
  State<FloatingPill> createState() => _FloatingPillState();
}

class _FloatingPillState extends State<FloatingPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.tooltip,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 150),
          scale: _hover ? 1.06 : 1,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _hover ? 1 : 0.45,
            child: GestureDetector(
              key: widget.tapKey,
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _hover ? primary : Colors.white24),
                  boxShadow: _hover
                      ? [BoxShadow(color: primary.withValues(alpha: 0.45), blurRadius: 16)]
                      : const [],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                    const SizedBox(width: 4),
                    Icon(widget.icon, color: Colors.white, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Skip OP" / "Skip ED" / "Skip 1:30" for a [SkipOffer].
class SkipPill extends StatelessWidget {
  final SkipOffer offer;
  final VoidCallback onPressed;
  const SkipPill({super.key, required this.offer, required this.onPressed});

  static String labelFor(SkipKind kind) => switch (kind) {
        SkipKind.opening => 'Skip OP',
        SkipKind.ending => 'Skip ED',
        SkipKind.fixed => 'Skip 1:30',
      };

  @override
  Widget build(BuildContext context) {
    return FloatingPill(
      label: labelFor(offer.kind),
      tooltip: offer.kind == SkipKind.fixed
          ? 'Skip 1:30 for everyone (Shift+Right)'
          : 'Skip to ${formatClock(offer.target)} for everyone',
      icon: Icons.fast_forward_rounded,
      tapKey: const ValueKey('skip-pill'),
      onPressed: onPressed,
    );
  }
}
