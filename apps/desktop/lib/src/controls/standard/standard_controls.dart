import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../../queue/queue_ui.dart';
import '../../shell/now_playing_title.dart';
import '../../state/settings.dart';
import '../control_menus.dart';
import '../controls_probe.dart' show ControlsHold;
import '../frame.dart';
import '../model/controls_layout.dart';
import '../model/controls_model.dart';
import '../volume.dart';
import 'seek_bar.dart';

// The Standard skin: Material-style bars over the picture. Top: what plays,
// Up next and the window controls; bottom: the seek bar (chapter marks,
// hover time) over a row of round icon buttons in the layout's order.
// Hidden, a thin progress line stays (unless switched off).

class StandardControls extends StatelessWidget {
  final PlayerControlsModel model;
  final bool visible;
  final double scale;
  final ControlsHold? hold;

  /// Right of the top bar's own buttons (the window buttons in fullscreen).
  final Widget? windowButtons;
  const StandardControls({
    super.key,
    required this.model,
    required this.visible,
    this.scale = 1,
    this.hold,
    this.windowButtons,
  });

  /// The top bar: room for the cover (2:3, 60 px tall).
  static const topHeight = 72.0;
  static const _rowHeight = 56.0;

  /// The bottom bar (seek bar and buttons) at [scale].
  static double bottomHeight(double scale) => (_rowHeight + ChapterSeekBar.defaultHeight) * scale;

  @override
  Widget build(BuildContext context) {
    const fade = ControlsFrame.fade;
    Widget bar(Widget child) => IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(duration: fade, opacity: visible ? 1 : 0, child: child),
    );
    // No button here takes focus (Space is the ready key); the top bar's
    // Up next keeps its own (its popover has a text field).
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: bar(
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
              child: SizedBox(
                key: const ValueKey('standard-top'),
                height: topHeight,
                child: Padding(padding: const EdgeInsets.only(left: 16, right: 8), child: _top()),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: bar(
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xB3000000)],
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(top: 24 * scale),
                child: SizedBox(
                  key: const ValueKey('standard-bottom'),
                  height: bottomHeight(scale),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: SignalBuilder(
                          // Live: no timeline (LIVE sits where the clock is),
                          // or one over what everyone can rewind to, live at
                          // its right end.
                          builder: (context) => model.live.value
                              ? switch (model.liveBar.value) {
                                  final bar? => ChapterSeekBar(
                                      key: const ValueKey('live-seek-bar'),
                                      position: bar.position,
                                      duration: bar.length,
                                      cached: bar.cached,
                                      height: ChapterSeekBar.defaultHeight * scale,
                                      onSeek: model.seekLive,
                                      hoverText: (at) => liveTimeText((bar.length - at).inMilliseconds / 1000),
                                    ),
                                  null => SizedBox(height: ChapterSeekBar.defaultHeight * scale),
                                }
                              : ChapterSeekBar(
                            position: model.position.value,
                            duration: model.duration.value,
                            buffer: model.buffered.value,
                            cached: model.cached.value,
                            chapters: model.chapters.value,
                            height: ChapterSeekBar.defaultHeight * scale,
                            onSeek: model.seek,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: ExcludeFocus(
                            child: LayoutBuilder(
                              builder: (context, box) => SignalBuilder(
                                builder: (context) {
                                  final s = model.snapshot.value;
                                  final layout = model.bar.value;
                                  // The volume slider stays out where the
                                  // row has room for it beside the buttons
                                  // and the clock (at its widest).
                                  final d = model.duration.value;
                                  // Live: its time at its widest, and Go
                                  // live (wider than a button) when shown.
                                  final clock = s.live
                                      ? _Clock.widthOf(liveTimeText(35999), scale, dot: true)
                                      : _Clock.widthOf(clockText(d, d, model.settings.timeDisplay.value), scale);
                                  final goLive = layout.left.contains(BarControl.goLive);
                                  final slider = volumeSliderRoom(
                                    width: box.maxWidth,
                                    buttons: layout.left.length + layout.right.length - 1 - (goLive ? 1 : 0),
                                    button: 48 * scale,
                                    fixed: clock + 24 + (goLive ? _GoLive.widthOf(scale) : 0),
                                  );
                                  return Row(
                                    key: const ValueKey('standard-buttons'),
                                    children: [
                                      for (final c in layout.left) _control(context, c, s, slider: slider),
                                      const Spacer(),
                                      for (final c in layout.right) _control(context, c, s, slider: slider),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // Hidden: the thin progress line.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: SignalBuilder(
              builder: (context) {
                if (visible || !AppSettings.instance.progressLine.value || model.live.value) {
                  return const SizedBox.shrink();
                }
                final d = model.duration.value, p = model.position.value;
                final v = d.inMilliseconds == 0 ? 0.0 : (p.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0);
                return LinearProgressIndicator(
                  key: const ValueKey('progress-line-standard'),
                  value: v,
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _top() {
    final m = model;
    return Row(
      children: [
        const Expanded(child: NowPlayingTitle()),
        UpNextButton(queue: m.queue, look: UpNextLook.standard, hold: hold),
        ExcludeFocus(
          child: Builder(
            builder: (context) => _IconButton(
              key: const ValueKey('controls-more'),
              icon: moreIcon,
              tooltip: moreTooltip,
              onPressed: () => openMoreMenu(context, m),
            ),
          ),
        ),
        SignalBuilder(
          builder: (context) {
            final full = m.fullscreen.value;
            return ExcludeFocus(
              child: _IconButton(
                key: const ValueKey('standard-collapse'),
                icon: full ? Icons.fullscreen_exit_rounded : Icons.close_fullscreen_rounded,
                tooltip: full ? 'Exit fullscreen (Esc)' : 'Back to the library (keeps playing)',
                onPressed: full ? m.toggleFullscreen : m.collapse,
              ),
            );
          },
        ),
        ?windowButtons,
      ],
    );
  }

  Widget _control(BuildContext context, BarControl c, ControlsSnapshot s,
      {({bool always, double width}) slider = (always: true, width: volumeSliderWidth)}) {
    final m = model;
    final key = ValueKey('control-${c.name}');
    final enabled = controlEnabled(c, s);
    Widget icon(VoidCallback? onPressed, {int badge = 0, double size = 24, Color? color}) => _IconButton(
      key: key,
      icon: controlIcon(c, s),
      tooltip: controlTooltip(c, s),
      badge: badge,
      size: size * scale,
      color: color,
      onPressed: enabled ? onPressed : null,
    );
    switch (c) {
      case BarControl.playPause:
        final waiting = s.play == PlayState.waiting;
        return icon(m.togglePlay, size: 30, color: waiting ? Theme.of(context).colorScheme.primary : null);
      case BarControl.previous:
        return icon(m.previous);
      case BarControl.next:
        return icon(m.next);
      case BarControl.chapterPrevious:
        return icon(() => m.stepChapter(-1));
      case BarControl.chapterNext:
        return icon(() => m.stepChapter(1));
      case BarControl.volume:
        return SignalBuilder(
          key: key,
          builder: (context) => VolumeControl(
            volume: m.volume.value,
            onChanged: m.setVolume,
            onToggleMute: m.toggleMute,
            slider: slider,
            button: (context, i, color, tip, onPressed) =>
                _IconButton(icon: i, tooltip: tip, color: color, size: 24 * scale, onPressed: onPressed),
          ),
        );
      case BarControl.time:
        return SignalBuilder(
          key: key,
          builder: (context) {
            // Live: LIVE, or how far behind it, in the clock's place and
            // look (nothing to switch).
            if (m.live.value) {
              final behind = m.liveBehind.value;
              return _Clock(
                key: const ValueKey('live-time'),
                text: liveTimeText(behind),
                tooltip: controlTooltip(c, s),
                scale: scale,
                dot: behind < atLiveSecs,
              );
            }
            return _Clock(
              text: clockText(m.position.value, m.duration.value, m.settings.timeDisplay.value),
              tooltip: controlTooltip(c, s),
              scale: scale,
              onPressed: m.toggleTimeDisplay,
            );
          },
        );
      case BarControl.goLive:
        return _GoLive(key: key, tooltip: controlTooltip(c, s), icon: controlIcon(c, s), scale: scale, onPressed: m.goLive);
      case BarControl.subtitles || BarControl.audio:
        final type = c == BarControl.audio ? JellyfinStreamType.audio : JellyfinStreamType.subtitle;
        return SignalBuilder(
          key: key,
          builder: (context) => Builder(
            builder: (context) => _IconButton(
              icon: controlIcon(c, s),
              tooltip: controlTooltip(c, s),
              badge: trackCount(m.tracks.value, type),
              size: 22 * scale,
              onPressed: () => openTrackMenu(context, m, type),
            ),
          ),
        );
      case BarControl.settings:
        return _IconButton(
          key: key,
          icon: controlIcon(c, s),
          tooltip: controlTooltip(c, s),
          size: 22 * scale,
          onPressed: m.togglePanel,
        );
      case BarControl.chat:
        return SignalBuilder(
          key: key,
          builder: (context) => _IconButton(
            icon: controlIcon(c, s),
            tooltip: controlTooltip(c, s),
            badge: m.unread.value,
            size: 22 * scale,
            onPressed: m.toggleChat,
          ),
        );
      case BarControl.fullscreen:
        return icon(m.toggleFullscreen, size: 26);
    }
  }
}

/// A round white icon button with an optional count badge (the Material
/// look of media_kit's bar).
class _IconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final int badge;
  final double size;
  final Color? color;
  const _IconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.badge = 0,
    this.size = 24,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      iconSize: size,
      color: color ?? Colors.white,
      disabledColor: Colors.white38,
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: badge > 0,
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        label: Text('$badge'),
        child: Icon(icon),
      ),
    );
  }
}

/// The clock: "6:00 / 24:00" or "-18:00"; a click switches. A live
/// stream's time ("LIVE", "−2:30") in the same look: [dot] the live dot,
/// no [onPressed].
class _Clock extends StatelessWidget {
  final String text;
  final String tooltip;
  final double scale;
  final VoidCallback? onPressed;
  final bool dot;
  const _Clock({
    super.key,
    required this.text,
    required this.tooltip,
    required this.scale,
    this.onPressed,
    this.dot = false,
  });

  static TextStyle _style(double scale) =>
      TextStyle(fontSize: 14 * scale, fontFeatures: const [FontFeature.tabularFigures()]);

  static double _dot(double scale) => 8 * scale;
  static double _dotGap(double scale) => 7 * scale;

  /// The clock's width showing [text] (its padding included).
  static double widthOf(String text, double scale, {bool dot = false}) {
    final p = TextPainter(text: TextSpan(text: text, style: _style(scale)), textDirection: TextDirection.ltr)..layout();
    final w = p.width;
    p.dispose();
    return w + 20 * scale + (dot ? _dot(scale) + _dotGap(scale) : 0);
  }

  @override
  Widget build(BuildContext context) {
    final label = Text(text, style: _style(scale));
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: 10 * scale),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: dot
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: _dot(scale),
                    height: _dot(scale),
                    decoration: const BoxDecoration(color: liveDotColor, shape: BoxShape.circle),
                  ),
                  SizedBox(width: _dotGap(scale)),
                  label,
                ],
              )
            : label,
      ),
    );
  }
}

/// Go live, in the clock's look with the skin's icon.
class _GoLive extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final double scale;
  final VoidCallback onPressed;
  const _GoLive(
      {super.key, required this.tooltip, required this.icon, required this.scale, required this.onPressed});

  static double _icon(double scale) => 20 * scale;

  /// Its width (padding included).
  static double widthOf(double scale) => _Clock.widthOf(goLiveLabel, scale) + _icon(scale) + 6 * scale;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: 10 * scale),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          iconSize: _icon(scale),
        ),
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(goLiveLabel, style: _Clock._style(scale)),
      ),
    );
  }
}
