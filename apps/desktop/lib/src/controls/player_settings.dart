import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../jellyfin/track_prefs.dart' show MpvTrack;
import '../playback/playback_controller.dart' show PlaybackController, RenderMode;
import '../shaders/shader_presets.dart';
import '../state/session_state.dart';
import '../shell/motion.dart';
import '../state/settings.dart';
import 'uosc/buttons.dart';
import 'uosc/controls.dart';

// Everything about the player, defined once: the rows of the ⚙ card in
// both control designs and of Settings → Player. Each row reads and
// writes [AppSettings] and applies to a running player right away.

/// One setting: a label, one line of help under it, the control at the
/// right ([below]: an extra line under the row, e.g. a text field).
class SettingRow extends StatelessWidget {
  final String label;
  final String? help;
  final Widget control;
  final Widget? below;
  const SettingRow({super.key, required this.label, this.help, required this.control, this.below});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label),
                    if (help != null) Text(help!, style: TextStyle(color: muted, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              control,
            ],
          ),
          ?below,
        ],
      ),
    );
  }
}

DropdownButton<T> _dropdown<T>({
  required Key key,
  required T value,
  required List<(T, String)> items,
  required ValueChanged<T> onChanged,
  bool expanded = false,
}) =>
    DropdownButton<T>(
      key: key,
      value: value,
      isExpanded: expanded,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(10),
      items: [
        for (final (v, label) in items)
          DropdownMenuItem(value: v, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );

/// Standard (our bars over media_kit's controls) or uosc. Live.
class PlayerDesignSetting extends StatelessWidget {
  const PlayerDesignSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Player design',
        help: 'uosc is modeled on mpv: a thick timeline with chapters and what is cached',
        control: _dropdown<bool>(
          key: const ValueKey('player-design'),
          value: s.mpvControls.value,
          items: const [(false, 'Standard'), (true, 'uosc')],
          onChanged: s.setMpvControls,
        ),
      ),
    );
  }
}

/// The 2 px line at the bottom while the controls are hidden. Live.
class ProgressLineSetting extends StatelessWidget {
  const ProgressLineSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Progress line when hidden',
        help: 'A thin bar at the bottom of the video while the controls are hidden',
        control: Switch(
          key: const ValueKey('progress-line'),
          value: s.progressLine.value,
          onChanged: s.setProgressLine,
        ),
      ),
    );
  }
}

/// Saves a shader choice (also used on the next join) and puts it on the
/// running player, if any; the player announces the result.
void applyShaderChoice(ShaderPreset preset, ShaderQuality? quality) {
  final s = AppSettings.instance;
  if (quality != null) s.setShaderQuality(quality);
  s.setShaderPreset(preset);
  final coord = SessionState.instance.coordinator;
  coord.markInput();
  coord.playback.applyShaders(announce: true);
}

/// Anime4K preset (or custom files) and HQ / Fast. Live.
class ShaderPresetSetting extends StatelessWidget {
  /// The running player's render mode (in the player); else the last one.
  final ReadonlySignal<RenderMode>? renderMode;
  const ShaderPresetSetting({super.key, this.renderMode});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(builder: (context) {
      final preset = s.shaderPreset.value;
      final quality = s.shaderQuality.value;
      final hasCustom = s.customShaders.value.isNotEmpty;
      final mode = (renderMode ?? PlaybackController.lastRenderMode).value;
      final warning = switch (mode) {
        RenderMode.software => 'Software rendering: shaders have no effect',
        RenderMode.softwareGl => 'OpenGL on the CPU: shaders will be slow',
        _ => null,
      };
      return SettingRow(
        label: 'Upscaling shader',
        help: 'Anime4K sharpens anime on your GPU, only you see it. '
            'A for 1080p, B for 720p, C for 480p · Ctrl+1…6, Ctrl+0 off',
        control: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dropdown<ShaderPreset>(
              key: const ValueKey('shader-preset'),
              value: preset,
              items: [
                for (final p in ShaderPreset.values)
                  if (p != ShaderPreset.custom || hasCustom || preset == p) (p, p.label),
              ],
              onChanged: (p) => applyShaderChoice(p, null),
            ),
            if (preset.isAnime4k) ...[
              const SizedBox(width: 8),
              _dropdown<ShaderQuality>(
                key: const ValueKey('shader-quality'),
                value: quality,
                items: [for (final q in ShaderQuality.values) (q, q.label)],
                onChanged: (q) => applyShaderChoice(preset, q),
              ),
            ],
          ],
        ),
        below: warning == null
            ? null
            : Text(warning, style: const TextStyle(fontSize: 12, color: Colors.orange)),
      );
    });
  }
}

/// Puts the hwdec setting on the running player (mpv switches decoders
/// on the fly). `SYNC_RELAY_HWDEC` wins, as at player start.
Future<void> applyHwdecLive() async {
  if ((Platform.environment['SYNC_RELAY_HWDEC'] ?? '').isNotEmpty) return;
  final playback = SessionState.instance.coordinator.playback;
  if (!playback.alive.peek()) return;
  try {
    final dynamic platform = playback.player.platform;
    await platform?.setProperty('hwdec', AppSettings.instance.hwdec.peek());
  } catch (e) {
    debugPrint('live hwdec failed: $e');
  }
}

/// mpv's `hwdec`: auto, off, or a custom value. Live.
class HwdecSetting extends StatefulWidget {
  const HwdecSetting({super.key});

  @override
  State<HwdecSetting> createState() => _HwdecSettingState();
}

class _HwdecSettingState extends State<HwdecSetting> {
  final _s = AppSettings.instance;
  late final _custom = TextEditingController(text: _s.hwdecCustom.peek());

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final mode = _s.hwdecMode.value;
      return SettingRow(
        label: 'Hardware decoding',
        help: 'Decodes video on the GPU. Turn it off if the picture glitches or stays black',
        control: _dropdown<HwdecMode>(
          key: const ValueKey('hwdec'),
          value: mode,
          items: const [(HwdecMode.auto, 'Auto'), (HwdecMode.off, 'Off'), (HwdecMode.custom, 'Custom')],
          onChanged: (m) {
            _s.setHwdecMode(m);
            applyHwdecLive();
          },
        ),
        below: mode != HwdecMode.custom
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  controller: _custom,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'mpv hwdec value (Enter applies)',
                    hintText: 'e.g. vaapi, nvdec, d3d11va, auto-safe',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _s.setHwdecCustom,
                  onSubmitted: (_) => applyHwdecLive(),
                ),
              ),
      );
    });
  }
}

/// Audio or subtitle track of the running player (in the player only).
/// The pick is remembered for the next Jellyfin item.
class TrackSetting extends StatelessWidget {
  final JellyfinStreamType type;
  const TrackSetting({super.key, required this.type});

  bool get _audio => type == JellyfinStreamType.audio;

  @override
  Widget build(BuildContext context) {
    final coord = SessionState.instance.coordinator;
    return SignalBuilder(builder: (context) {
      final list = [
        for (final t in coord.playback.tracks.value)
          if (t.type == type) t,
      ];
      // -1: subtitles off.
      final selected = list.where((t) => t.selected).firstOrNull?.id ?? (_audio ? null : -1);
      final items = <(int, String)>[
        if (!_audio) (-1, 'Off'),
        for (final MpvTrack t in list) (t.id, t.label),
      ];
      return SettingRow(
        label: _audio ? 'Audio' : 'Subtitles',
        help: 'Remembered for the next episode',
        control: SizedBox(
          width: 190,
          child: items.isEmpty || selected == null
              ? Text(items.isEmpty ? 'None' : 'Pick one…',
                  key: ValueKey(_audio ? 'audio-track' : 'subtitle-track'), textAlign: TextAlign.end)
              : _dropdown<int>(
                  key: ValueKey(_audio ? 'audio-track' : 'subtitle-track'),
                  value: selected,
                  expanded: true,
                  items: items,
                  onChanged: (id) {
                    coord.markInput();
                    if (id == -1) {
                      coord.selectTrack(subtitlesOff: true);
                    } else if (_audio) {
                      coord.selectTrack(aid: id);
                    } else {
                      coord.selectTrack(sid: id);
                    }
                  },
                ),
        ),
      );
    });
  }
}

/// The player rows of Settings → Player and the ⚙ card, in order.
List<Widget> playerSettingRows({ReadonlySignal<RenderMode>? renderMode}) => [
      const PlayerDesignSetting(),
      const ProgressLineSetting(),
      ShaderPresetSetting(renderMode: renderMode),
      const HwdecSetting(),
    ];

/// The ⚙ card: every player setting, plus the running player's tracks.
class PlayerSettingsCard extends StatelessWidget {
  final ReadonlySignal<RenderMode>? renderMode;
  /// Show the audio / subtitle pickers (a player is running).
  final bool tracks;
  const PlayerSettingsCard({super.key, this.renderMode, this.tracks = true});

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('player-settings-card'),
      elevation: 12,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Player', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 4),
              ...playerSettingRows(renderMode: renderMode),
              if (tracks) ...[
                const Divider(),
                const TrackSetting(type: JellyfinStreamType.subtitle),
                const TrackSetting(type: JellyfinStreamType.audio),
              ],
              const SizedBox(height: 4),
              Text(
                'Custom shader files: Settings → Player',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the ⚙ card over the player, near the controls' right end. The
/// uosc controls stay up while it is open.
Future<void> showPlayerSettings(BuildContext context, {ReadonlySignal<RenderMode>? renderMode}) {
  Future<void> open() => showPopover<void>(
        context,
        at: const Alignment(0.96, 0.5),
        child: PlayerSettingsCard(renderMode: renderMode),
      );
  final controls = UoscControls.maybeOf(context);
  return controls == null ? open() : controls.holdDuring(open);
}

/// ⚙ in the standard controls' bottom bar.
class PlayerSettingsButton extends StatelessWidget {
  final FocusNode? focusNode;
  final ReadonlySignal<RenderMode>? renderMode;
  const PlayerSettingsButton({super.key, this.focusNode, this.renderMode});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('player-settings'),
      focusNode: focusNode,
      tooltip: 'Player settings',
      color: Colors.white,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.tune),
      onPressed: () => showPlayerSettings(context, renderMode: renderMode),
    );
  }
}

/// ⚙ in the uosc controls' button row.
class UoscPlayerSettingsButton extends StatelessWidget {
  final ReadonlySignal<RenderMode>? renderMode;
  const UoscPlayerSettingsButton({super.key, this.renderMode});

  @override
  Widget build(BuildContext context) {
    return UoscButton(
      key: const ValueKey('uosc-player-settings'),
      icon: Icons.tune_rounded,
      tooltip: 'Player settings',
      onPressed: () => showPlayerSettings(context, renderMode: renderMode),
    );
  }
}
