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
                          builder: (context) => ChapterSeekBar(
                            position: model.position.value,
                            duration: model.duration.value,
                            buffer: model.buffered.value,
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
                            child: SignalBuilder(
                              builder: (context) {
                                final s = model.snapshot.value;
                                final layout = model.bar.value;
                                return Row(
                                  key: const ValueKey('standard-buttons'),
                                  children: [
                                    for (final c in layout.left) _control(context, c, s),
                                    const Spacer(),
                                    for (final c in layout.right) _control(context, c, s),
                                  ],
                                );
                              },
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
                if (visible || !AppSettings.instance.progressLine.value) return const SizedBox.shrink();
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

  Widget _control(BuildContext context, BarControl c, ControlsSnapshot s) {
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
            button: (context, i, color, tip, onPressed) =>
                _IconButton(icon: i, tooltip: tip, color: color, size: 24 * scale, onPressed: onPressed),
          ),
        );
      case BarControl.time:
        return SignalBuilder(
          key: key,
          builder: (context) => _Clock(
            text: clockText(m.position.value, m.duration.value, m.settings.timeDisplay.value),
            tooltip: controlTooltip(c, s),
            scale: scale,
            onPressed: m.toggleTimeDisplay,
          ),
        );
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
        return Builder(
          key: key,
          builder: (context) => _IconButton(
            icon: controlIcon(c, s),
            tooltip: controlTooltip(c, s),
            size: 22 * scale,
            onPressed: () => openControlsMenu(context, m),
          ),
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

/// The clock: "6:00 / 24:00" or "-18:00"; a click switches.
class _Clock extends StatelessWidget {
  final String text;
  final String tooltip;
  final double scale;
  final VoidCallback onPressed;
  const _Clock({required this.text, required this.tooltip, required this.scale, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: 10 * scale),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: Text(
          text,
          style: TextStyle(fontSize: 14 * scale, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }
}
