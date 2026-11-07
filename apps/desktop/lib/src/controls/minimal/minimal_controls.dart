import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../../queue/queue_ui.dart';
import '../../shell/now_playing_title.dart';
import '../../state/settings.dart';
import '../control_menus.dart';
import '../controls_probe.dart' show ControlsHold;
import '../frame.dart';
import '../live_badge.dart';
import '../model/controls_layout.dart';
import '../model/controls_model.dart';
import '../model/controls_prefs.dart';
import '../volume.dart';
import 'style.dart';
import 'timeline.dart';

// The Minimal skin (inspired by mpv's uosc): a timeline band across the
// bottom that carries the clock, and above it the buttons in two glass
// capsules, in the layout's order. Top: what plays, Up next and the window
// controls. Hidden, the band shrinks to a thin progress line (unless
// switched off).

class MinimalControls extends StatelessWidget {
  final PlayerControlsModel model;
  final bool visible;
  final double scale;
  final ControlsHold? hold;
  final Widget? windowButtons;
  const MinimalControls({
    super.key,
    required this.model,
    required this.visible,
    this.scale = 1,
    this.hold,
    this.windowButtons,
  });

  static const _rowGap = 8.0;

  /// The button row's height at [scale] (a capsule).
  static double rowHeight(double scale) => MinimalStyle.button * scale + 2 * MinimalStyle.capsulePad;

  /// Buttons and timeline at [scale].
  static double bottomHeight(double scale) => rowHeight(scale) + _rowGap + MinimalTimeline.heightFor(scale);

  /// The top bar's height.
  static const topHeight = 72.0;

  @override
  Widget build(BuildContext context) {
    const fade = ControlsFrame.fade;
    Widget shown(Widget child, {Key? key}) => IgnorePointer(
      key: key,
      ignoring: !visible,
      child: AnimatedOpacity(duration: fade, opacity: visible ? 1 : 0, child: child),
    );
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: shown(
            key: const ValueKey('minimal-top'),
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
              child: SizedBox(
                height: topHeight + 24,
                child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 10, 24), child: _top()),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              shown(
                key: const ValueKey('minimal-buttons'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, _rowGap),
                  child: SizedBox(
                    height: rowHeight(scale),
                    child: LayoutBuilder(
                      builder: (context, box) => SignalBuilder(
                        builder: (context) {
                          final s = model.snapshot.value;
                          final layout = model.bar.value;
                          // The clock lives on the timeline.
                          final buttons = [...layout.left, ...layout.right].where((c) => c != BarControl.time).length;
                          // The volume slider stays out where the row has
                          // room for it (two capsules, a gap between).
                          final slider = volumeSliderRoom(
                            width: box.maxWidth,
                            buttons: buttons,
                            button: MinimalStyle.button * scale,
                            fixed: 4 * MinimalStyle.capsulePad + 4 * scale + 24,
                          );
                          List<Widget> cluster(List<BarControl> cs) => [
                            for (final c in cs)
                              if (c != BarControl.time) _control(context, c, s, slider: slider),
                          ];
                          return Row(
                            children: [
                              MinimalCapsule(scale: scale, children: cluster(layout.left)),
                              const Spacer(),
                              MinimalCapsule(scale: scale, children: cluster(layout.right)),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              SignalBuilder(
                builder: (context) {
                  final line = AppSettings.instance.progressLine.value;
                  // Live: no timeline; LIVE where its clock is.
                  if (model.live.value) {
                    return AnimatedOpacity(
                      key: const ValueKey('minimal-timeline-wrap'),
                      duration: fade,
                      opacity: visible ? 1 : 0,
                      child: SizedBox(
                        height: MinimalTimeline.heightFor(scale),
                        child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: LiveBadge(
                              paused: model.livePaused.value, scale: scale, onBackToLive: model.togglePlay),
                        ),
                      ),
                    );
                  }
                  return AnimatedOpacity(
                    key: const ValueKey('minimal-timeline-wrap'),
                    duration: fade,
                    opacity: visible || line ? 1 : 0,
                    child: MinimalTimeline(
                      position: model.position.value,
                      duration: model.duration.value,
                      buffered: model.buffered.value,
                      cached: model.cached.value,
                      chapters: model.chapters.value,
                      expanded: visible,
                      remaining: model.settings.timeDisplay.value == TimeDisplay.remaining,
                      scale: scale,
                      onSeek: model.seek,
                      onToggleTime: model.toggleTimeDisplay,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _top() {
    final m = model;
    return Row(
      children: [
        const Expanded(
          child: Align(alignment: AlignmentDirectional.centerStart, child: NowPlayingTitle()),
        ),
        UpNextButton(queue: m.queue, look: UpNextLook.minimal, hold: hold),
        const SizedBox(width: 4),
        Builder(
          builder: (context) => MinimalButton(
            key: const ValueKey('controls-more'),
            icon: moreIcon,
            tooltip: moreTooltip,
            onPressed: () => openMoreMenu(context, m),
          ),
        ),
        SignalBuilder(
          builder: (context) {
            final full = m.fullscreen.value;
            return MinimalButton(
              key: const ValueKey('minimal-collapse'),
              icon: full ? Icons.fullscreen_exit_rounded : Icons.close_fullscreen_rounded,
              tooltip: full ? 'Exit fullscreen (Esc)' : 'Back to the library (keeps playing)',
              onPressed: full ? m.toggleFullscreen : m.collapse,
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
    Widget button(VoidCallback? onPressed, {int? badge, bool accent = false}) => MinimalButton(
      key: key,
      icon: controlIcon(c, s),
      tooltip: controlTooltip(c, s),
      badge: badge,
      accent: accent,
      scale: scale,
      onPressed: enabled ? onPressed : null,
    );
    switch (c) {
      case BarControl.playPause:
        return Padding(
          padding: EdgeInsets.only(right: 4 * scale),
          child: button(m.togglePlay, accent: true),
        );
      case BarControl.previous:
        return button(m.previous);
      case BarControl.next:
        return button(m.next);
      case BarControl.chapterPrevious:
        return button(() => m.stepChapter(-1));
      case BarControl.chapterNext:
        return button(() => m.stepChapter(1));
      case BarControl.volume:
        return SignalBuilder(
          key: key,
          builder: (context) => VolumeControl(
            volume: m.volume.value,
            onChanged: m.setVolume,
            onToggleMute: m.toggleMute,
            slider: slider,
            sliderColor: Theme.of(context).colorScheme.primary,
            trackColor: MinimalStyle.dim.withValues(alpha: 0.4),
            button: (context, i, color, tip, onPressed) =>
                MinimalButton(icon: i, tooltip: tip, color: color, scale: scale, onPressed: onPressed),
          ),
        );
      case BarControl.time:
        return const SizedBox.shrink();
      case BarControl.subtitles || BarControl.audio:
        final type = c == BarControl.audio ? JellyfinStreamType.audio : JellyfinStreamType.subtitle;
        return SignalBuilder(
          key: key,
          builder: (context) => Builder(
            builder: (context) => MinimalButton(
              icon: controlIcon(c, s),
              tooltip: controlTooltip(c, s),
              badge: trackCount(m.tracks.value, type),
              scale: scale,
              onPressed: () => openTrackMenu(context, m, type),
            ),
          ),
        );
      case BarControl.settings:
        return MinimalButton(
          key: key,
          icon: controlIcon(c, s),
          tooltip: controlTooltip(c, s),
          scale: scale,
          onPressed: m.togglePanel,
        );
      case BarControl.chat:
        return SignalBuilder(
          key: key,
          builder: (context) => MinimalButton(
            icon: controlIcon(c, s),
            tooltip: controlTooltip(c, s),
            badge: m.unread.value,
            scale: scale,
            onPressed: m.toggleChat,
          ),
        );
      case BarControl.fullscreen:
        return button(m.toggleFullscreen);
    }
  }
}
