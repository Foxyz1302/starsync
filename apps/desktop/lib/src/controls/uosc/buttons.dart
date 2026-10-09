import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../../jellyfin/track_prefs.dart' show MpvTrack;
import '../../playback/media_marks.dart';
import '../../playback/playback_controller.dart' show RenderMode;
import '../../screens/session/player_controls.dart' show TrackPick;
import '../../shaders/shader_menu.dart';
import '../../shaders/shader_presets.dart';
import '../../state/settings.dart';
import '../volume.dart';
import 'controls.dart';
import 'menu.dart';
import 'style.dart';

/// Flat uosc button: a white icon (optionally a [label] beside it and a
/// small count [badge] in the corner), a faint highlight on hover, a dark
/// tooltip. Never takes focus (the session's keys are global).
class UoscButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final String? label;
  final int? badge;
  /// Tint for an "on" state (ready, shaders on).
  final Color? color;
  const UoscButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.label,
    this.badge,
    this.color,
  });

  @override
  State<UoscButton> createState() => _UoscButtonState();
}

class _UoscButtonState extends State<UoscButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final color = w.onPressed == null ? UoscStyle.dim.withValues(alpha: 0.4) : (w.color ?? UoscStyle.text);
    final badge = w.badge;
    return UoscTooltip(
      message: w.tooltip,
      child: MouseRegion(
        cursor: w.onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: w.onPressed,
          child: Container(
            height: UoscControls.buttonRowHeight,
            constraints: const BoxConstraints(minWidth: UoscControls.buttonRowHeight),
            padding: EdgeInsets.symmetric(horizontal: w.label == null ? 0 : 8),
            decoration: BoxDecoration(
              color: _hover && w.onPressed != null ? UoscStyle.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(UoscStyle.radius),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(w.icon, color: color, size: 22),
                    if (badge != null && badge > 0)
                      Positioned(
                        right: -8,
                        bottom: -5,
                        child: Container(
                          key: const ValueKey('uosc-badge'),
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: UoscStyle.text,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text('$badge',
                              style: const TextStyle(
                                  color: Colors.black, fontSize: 9, height: 1.3, fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ],
                ),
                if (w.label != null) ...[
                  const SizedBox(width: 6),
                  Text(w.label!, style: TextStyle(color: color, fontSize: UoscStyle.fontSize)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Badge-style text button ("HQ" in uosc): a small outlined box with a
/// short label, filled when [active].
class UoscBadgeButton extends StatefulWidget {
  final String text;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;
  const UoscBadgeButton({
    super.key,
    required this.text,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  @override
  State<UoscBadgeButton> createState() => _UoscBadgeButtonState();
}

class _UoscBadgeButtonState extends State<UoscBadgeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return UoscTooltip(
      message: w.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: w.onPressed,
          child: Container(
            height: UoscControls.buttonRowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: _hover ? UoscStyle.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(UoscStyle.radius),
            ),
            alignment: Alignment.center,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: w.active ? UoscStyle.text : Colors.transparent,
                border: Border.all(color: w.active ? UoscStyle.text : UoscStyle.dim, width: 1.4),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(w.text,
                  style: TextStyle(
                      color: w.active ? Colors.black : UoscStyle.dim,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Volume: click mutes / unmutes, hovering shows a [VolumeBar] up to
/// [maxVolume], the wheel steps 5 %.
class UoscVolumeButton extends StatefulWidget {
  /// 0..[maxVolume].
  final double volume;
  final ValueChanged<double> onChanged;
  const UoscVolumeButton({super.key, required this.volume, required this.onChanged});

  @override
  State<UoscVolumeButton> createState() => _UoscVolumeButtonState();
}

class _UoscVolumeButtonState extends State<UoscVolumeButton> {
  double _beforeMute = 100;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.volume;
    final icon = v <= 0 ? Icons.volume_off_rounded : (v < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
            widget.onChanged(stepVolume(v, e.scrollDelta.dy < 0 ? 5 : -5));
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              child: _hover
                  ? Padding(
                      padding: const EdgeInsets.only(left: 6, right: 2),
                      child: VolumeBar(
                        key: const ValueKey('uosc-volume-bar'),
                        volume: v,
                        onChanged: widget.onChanged,
                        color: UoscStyle.text,
                        trackColor: UoscStyle.dim.withValues(alpha: 0.5),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            UoscButton(
              key: const ValueKey('uosc-volume'),
              icon: icon,
              color: v > 100 ? boostColor : null,
              tooltip: 'Volume ${v.round()} % (scroll to change)',
              onPressed: () {
                if (v > 0) {
                  _beforeMute = v;
                  widget.onChanged(0);
                } else {
                  widget.onChanged(_beforeMute <= 0 ? 100 : _beforeMute);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Subtitles or audio: the icon with the track count; the menu lists the
/// tracks (mpv's selection active).
class UoscTracksButton extends StatelessWidget {
  final JellyfinStreamType type;
  final List<MpvTrack> tracks;
  final void Function(TrackPick pick) onPick;
  final ValueChanged<bool>? onMenuOpen;
  const UoscTracksButton({super.key, required this.type, required this.tracks, required this.onPick, this.onMenuOpen});

  @override
  Widget build(BuildContext context) {
    final audio = type == JellyfinStreamType.audio;
    final count = tracks.where((t) => t.type == type).length;
    return UoscButton(
      key: ValueKey(audio ? 'uosc-audio' : 'uosc-subtitles'),
      icon: audio ? Icons.graphic_eq_rounded : Icons.subtitles_outlined,
      tooltip: audio ? 'Audio' : 'Subtitles',
      badge: count,
      onPressed: () async {
        onMenuOpen?.call(true);
        final pick = await showUoscMenu<TrackPick>(context,
            title: audio ? 'Audio' : 'Subtitles', items: trackMenuItems(type, tracks));
        onMenuOpen?.call(false);
        if (pick != null) onPick(pick);
      },
    );
  }
}

/// Chapters: the list with start times, the playing one active; a pick
/// jumps there. Nothing without chapters.
class UoscChaptersButton extends StatelessWidget {
  final List<MediaChapter> chapters;
  final int? current;
  final Duration duration;
  final ValueChanged<MediaChapter> onPick;
  final ValueChanged<bool>? onMenuOpen;
  const UoscChaptersButton({
    super.key,
    required this.chapters,
    required this.current,
    required this.duration,
    required this.onPick,
    this.onMenuOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (chapters.isEmpty) return const SizedBox.shrink();
    return UoscButton(
      key: const ValueKey('uosc-chapters'),
      icon: Icons.bookmarks_outlined,
      tooltip: 'Chapters (PgUp / PgDn)',
      onPressed: () async {
        onMenuOpen?.call(true);
        final pick = await showUoscMenu<MediaChapter>(context,
            title: 'Chapters', items: chapterMenuItems(chapters, current, duration));
        onMenuOpen?.call(false);
        if (pick != null) onPick(pick);
      },
    );
  }
}

/// Shaders as uosc's quality badge: the active Anime4K preset ("A HQ"),
/// "4K" dimmed when off. Opens the shader menu.
class UoscShaderButton extends StatelessWidget {
  final ReadonlySignal<RenderMode> renderMode;
  final void Function(ShaderPreset preset, ShaderQuality? quality) onPick;
  final ValueChanged<bool>? onMenuOpen;
  const UoscShaderButton({super.key, required this.renderMode, required this.onPick, this.onMenuOpen});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(builder: (context) {
      final preset = s.shaderPreset.value;
      final quality = s.shaderQuality.value;
      final short = shaderShortLabel(preset, quality);
      return Builder(
        builder: (context) => UoscBadgeButton(
          key: const ValueKey('uosc-shaders'),
          text: short ?? '4K',
          active: short != null,
          tooltip: short == null
              ? 'Shaders: off (Ctrl+1..6)'
              : 'Shaders: ${shaderLabel(preset, quality)} (Ctrl+0 off)',
          onPressed: () {
            final controls = UoscControls.maybeOf(context);
            Future<void> open() =>
                showShaderMenu(context, renderMode: renderMode, onPick: onPick, onMenuOpen: onMenuOpen);
            controls == null ? open() : controls.holdDuring(open);
          },
        ),
      );
    });
  }
}

/// One entry of the ≡ menu.
typedef UoscAction = ({String title, String? hint, VoidCallback run});

/// ≡: the session's actions as a menu.
class UoscMainMenuButton extends StatelessWidget {
  final List<UoscAction> actions;
  final ValueChanged<bool>? onMenuOpen;
  const UoscMainMenuButton({super.key, required this.actions, this.onMenuOpen});

  @override
  Widget build(BuildContext context) {
    return UoscButton(
      key: const ValueKey('uosc-menu-button'),
      icon: Icons.menu_rounded,
      tooltip: 'Menu',
      onPressed: () async {
        onMenuOpen?.call(true);
        final pick = await showUoscMenu<UoscAction>(context, items: [
          for (final a in actions) UoscMenuItem(value: a, title: a.title, hint: a.hint),
        ]);
        onMenuOpen?.call(false);
        pick?.run();
      },
    );
  }
}
