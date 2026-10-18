import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../playback/playback_controller.dart' show PlaybackController, RenderMode;
import '../session/session_coordinator.dart' show SessionCoordinator;
import '../shaders/shader_presets.dart';
import '../app/app_graph.dart';
import '../state/settings.dart';
import '../widgets/app_menu.dart';
import 'model/controls_prefs.dart';

// Everything about the player, defined once: the rows of Settings →
// Player (the player panel, `player_panel.dart`, has compact rows for the
// same settings). Each row reads and writes [AppSettings] and applies to
// a running player right away.

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

AppSelect<T> _dropdown<T>({
  required Key key,
  required T value,
  required List<(T, String)> items,
  required ValueChanged<T> onChanged,
  bool expanded = false,
}) =>
    AppSelect<T>(key: key, value: value, items: items, onChanged: onChanged, expanded: expanded);

/// The controls' skin: Standard or Minimal. Live.
class PlayerDesignSetting extends StatelessWidget {
  const PlayerDesignSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Player design',
        help: 'Minimal has a thick timeline with chapters and what is downloaded yet',
        control: _dropdown<ControlsSkin>(
          key: const ValueKey('player-design'),
          value: s.controlsSkin.value,
          items: [for (final k in ControlsSkin.values) (k, k.label)],
          onChanged: s.setControlsSkin,
        ),
      ),
    );
  }
}

/// The bar's clock: elapsed / total or the time left. Live.
class TimeDisplaySetting extends StatelessWidget {
  const TimeDisplaySetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Time display',
        help: 'Also switched by a click on the time',
        control: _dropdown<TimeDisplay>(
          key: const ValueKey('time-display'),
          value: s.timeDisplay.value,
          items: [for (final t in TimeDisplay.values) (t, t.label)],
          onChanged: s.setTimeDisplay,
        ),
      ),
    );
  }
}

/// Normal or large bar and buttons. Live.
class ControlsSizeSetting extends StatelessWidget {
  const ControlsSizeSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Controls size',
        help: 'Large makes the bar and its buttons a quarter bigger',
        control: _dropdown<ControlsSize>(
          key: const ValueKey('controls-size'),
          value: s.controlsSize.value,
          items: [for (final z in ControlsSize.values) (z, z.label)],
          onChanged: s.setControlsSize,
        ),
      ),
    );
  }
}

/// How long the controls stay up without mouse movement. Live.
class HideDelaySetting extends StatelessWidget {
  const HideDelaySetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Hide the controls after',
        help: 'Without mouse movement over the video',
        control: _dropdown<int>(
          key: const ValueKey('controls-hide'),
          value: s.controlsHideSecs.value,
          items: [for (final secs in controlsHideChoices) (secs, '$secs s')],
          onChanged: s.setControlsHideSecs,
        ),
      ),
    );
  }
}

/// One optional bar button on or off (off: it is still in ⋯). Live.
class BarButtonSetting extends StatelessWidget {
  final OptionalControl control;
  const BarButtonSetting({super.key, required this.control});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: control.label,
        help: control.help,
        control: Switch(
          key: ValueKey('bar-${control.name}'),
          value: !s.hiddenControls.value.contains(control),
          onChanged: (on) => s.setControlShown(control, on),
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

/// The video output at the player's size on screen ([AppSettings.screenResVideo]).
class ScreenResSetting extends StatelessWidget {
  final ReadonlySignal<RenderMode>? renderMode;
  const ScreenResSetting({super.key, this.renderMode});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return SignalBuilder(builder: (context) {
      final software = switch (renderMode?.value) {
        RenderMode.software || RenderMode.softwareGl => true,
        _ => false,
      };
      return SettingRow(
        label: 'Sharp video and subtitles',
        help: software
            ? 'No effect: video uses software rendering'
            : "Scale the picture and draw subtitles at your screen's resolution, not the video's. "
                'Off: lighter on a weak GPU',
        control: Switch(
          key: const ValueKey('screen-res-video'),
          value: s.screenResVideo.value,
          onChanged: s.setScreenResVideo,
        ),
      );
    });
  }
}

/// Saves a shader choice (also used on the next join) and puts it on the
/// running player, if any; the player announces the result.
void applyShaderChoice(SessionCoordinator coord, ShaderPreset preset, ShaderQuality? quality) {
  final s = AppSettings.instance;
  if (quality != null) s.setShaderQuality(quality);
  s.setShaderPreset(preset);
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
      final mode = (renderMode ??
              context.getInheritedWidgetOfExactType<AppScope>()?.graph.ports.players.renderMode)
          ?.value;
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
              onChanged: (p) => applyShaderChoice(AppScope.of(context).coordinator, p, null),
            ),
            if (preset.isAnime4k) ...[
              const SizedBox(width: 8),
              _dropdown<ShaderQuality>(
                key: const ValueKey('shader-quality'),
                value: quality,
                items: [for (final q in ShaderQuality.values) (q, q.label)],
                onChanged: (q) => applyShaderChoice(AppScope.of(context).coordinator, preset, q),
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
Future<void> applyHwdecLive(PlaybackController playback) async {
  if ((Platform.environment['SYNC_RELAY_HWDEC'] ?? '').isNotEmpty) return;
  final p = playback.current;
  if (p == null) return;
  try {
    await p.setProperty('hwdec', AppSettings.instance.hwdec.peek());
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
            applyHwdecLive(AppScope.of(context).coordinator.playback);
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
                  onSubmitted: (_) => applyHwdecLive(AppScope.of(context).coordinator.playback),
                ),
              ),
      );
    });
  }
}

/// The controls' own choices (Settings → Player → Controls).
List<Widget> controlsSettingRows() => [
  const TimeDisplaySetting(),
  const ControlsSizeSetting(),
  const HideDelaySetting(),
  const Padding(
    padding: EdgeInsets.only(top: 10, bottom: 2),
    child: Text('Buttons in the bar (hidden ones stay in ⋯)', style: TextStyle(fontWeight: FontWeight.w600)),
  ),
  for (final c in OptionalControl.values) BarButtonSetting(control: c),
];

/// The player rows of Settings → Player, in order (the player panel has
/// its own compact rows for the same settings).
List<Widget> playerSettingRows({ReadonlySignal<RenderMode>? renderMode}) => [
      const PlayerDesignSetting(),
      const ProgressLineSetting(),
      ShaderPresetSetting(renderMode: renderMode),
      ScreenResSetting(renderMode: renderMode),
      const HwdecSetting(),
      const SubScaleSetting(),
      const LiftSubtitlesSetting(),
    ];

/// Subtitle size (mpv `sub-scale`, [AppSettings.subScale]). Live.
class SubScaleSetting extends StatelessWidget {
  const SubScaleSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Subtitle size',
        help: '${(s.subScale.value * 100).round()} % of what the file sets',
        control: SizedBox(
          width: 220,
          child: Slider(
            key: const ValueKey('sub-scale'),
            value: s.subScale.value,
            min: 0.5,
            max: 2,
            divisions: 30,
            onChanged: s.setSubScale,
          ),
        ),
      ),
    );
  }
}

/// Bottom subtitles above the control bar while it is up
/// ([AppSettings.liftSubtitles]). Live.
class LiftSubtitlesSetting extends StatelessWidget {
  const LiftSubtitlesSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Subtitles above the controls',
        help: 'Bottom lines move up while the control bar shows; signs at the top stay. '
            'The chat box always moves them',
        control: Switch(
          key: const ValueKey('lift-subtitles'),
          value: s.liftSubtitles.value,
          onChanged: s.setLiftSubtitles,
        ),
      ),
    );
  }
}
