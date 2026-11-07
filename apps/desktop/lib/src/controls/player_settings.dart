import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../app/app_graph.dart';
import '../playback/playback_controller.dart' show PlaybackController, RenderMode;
import '../session/session_coordinator.dart' show SessionCoordinator;
import '../shaders/shader_presets.dart';
import '../state/settings.dart';
import '../widgets/app_menu.dart';
import '../widgets/setting_rows.dart';
import 'model/controls_prefs.dart';
import 'volume.dart' as vol;

export '../widgets/setting_rows.dart';

// Every player setting, defined once: Settings → Player and the player
// panel (`player_panel.dart`, dense under a [SettingDensity]) draw these
// same widgets with the same labels (the clock's elapsed / remaining is
// only its click). Each reads and writes [AppSettings]
// and applies to a running player right away.

AppSettings _settings(BuildContext context) => AppScope.of(context).coordinator.settings;

bool _software(RenderMode? mode) => mode == RenderMode.software || mode == RenderMode.softwareGl;

/// The running player's render mode (in the player); else the last one.
RenderMode? _renderMode(BuildContext context, ReadonlySignal<RenderMode>? renderMode) =>
    (renderMode ?? AppScope.maybeOf(context)?.ports.players.renderMode)?.value;

/// The video's volume, now and from the next start on (the controls,
/// the panel and Settings all set it here).
void setVideoVolume(SessionCoordinator coord, double v) {
  final clamped = v.clamp(0.0, vol.maxVolume);
  coord.playback.setVolume(clamped);
  coord.settings.setPlayerVolume(clamped);
}

/// The video's volume, 0..150 on the bar's [vol.VolumeBar] (a tick at
/// 100 %, amber above). Live.
class VideoVolumeSetting extends StatelessWidget {
  const VideoVolumeSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final coord = AppScope.of(context).coordinator;
    final dense = SettingDensity.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SignalBuilder(builder: (context) {
      final v = coord.playback.volume.value;
      return SettingTrack(
        key: const ValueKey('video-volume'),
        label: 'Volume',
        help: "The video's, yours only; each start begins here. In the player M mutes, the wheel or ↑ / ↓ "
            'steps it',
        readout: '${v.round()} %',
        readoutColor: v > 100 ? vol.boostColor : null,
        // In line with the sliders around it: their colours, inset by
        // their thumb.
        track: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: LayoutBuilder(
            builder: (context, box) => vol.VolumeBar(
              volume: v,
              width: box.maxWidth,
              onChanged: (x) => setVideoVolume(coord, x),
              color: scheme.primary,
              trackColor: dense ? Colors.white30 : scheme.outlineVariant,
            ),
          ),
        ),
      );
    });
  }
}

/// The running player's subtitle or audio track (the player panel only);
/// remembered for the next episode.
class TrackSetting extends StatelessWidget {
  final JellyfinStreamType type;
  const TrackSetting({super.key, required this.type});

  bool get _audio => type == JellyfinStreamType.audio;

  @override
  Widget build(BuildContext context) {
    final coord = AppScope.of(context).coordinator;
    return SignalBuilder(builder: (context) {
      final list = [for (final t in coord.playback.tracks.value) if (t.type == type) t];
      final selected = list.where((t) => t.selected).firstOrNull?.id ?? (_audio ? null : -1);
      final items = <(int, String)>[
        if (!_audio) (-1, 'Off'),
        for (final t in list) (t.id, t.label),
      ];
      final key = ValueKey(_audio ? 'audio-track' : 'subtitle-track');
      return SettingRow(
        label: _audio ? 'Audio' : 'Subtitles',
        help: 'Remembered for the next episode of this series',
        control: items.isEmpty || selected == null
            ? Text(items.isEmpty ? 'None' : 'Pick one…', key: key, style: DenseText.label)
            : AppSelect<int>(
                key: key,
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
      );
    });
  }
}

/// Subtitle size (mpv `sub-scale`, [AppSettings.subScale]). Live.
class SubScaleSetting extends StatelessWidget {
  const SubScaleSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _settings(context);
    return SignalBuilder(
      builder: (context) => SettingTrack(
        label: 'Subtitle size',
        help: 'Of what the file sets',
        readout: '${(s.subScale.value * 100).round()} %',
        track: Slider(
          key: const ValueKey('sub-scale'),
          value: s.subScale.value,
          min: 0.5,
          max: 2,
          divisions: 30,
          onChanged: s.setSubScale,
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
    final s = _settings(context);
    return SignalBuilder(
      builder: (context) => SettingSwitch(
        switchKey: const ValueKey('lift-subtitles'),
        label: 'Subtitles above the controls',
        help: 'Bottom lines move up while the control bar shows; signs at the top stay. '
            'The chat box always moves them',
        value: s.liftSubtitles.value,
        onChanged: s.setLiftSubtitles,
      ),
    );
  }
}

/// Saves a shader choice (also used on the next join) and puts it on the
/// running player, if any; the player announces the result.
void applyShaderChoice(SessionCoordinator coord, ShaderPreset preset, ShaderQuality? quality) {
  final s = coord.settings;
  if (quality != null) s.setShaderQuality(quality);
  s.setShaderPreset(preset);
  coord.markInput();
  coord.playback.applyShaders(announce: true);
}

/// The upscaling shader: Anime4K's modes (or custom files), and HQ /
/// Fast under it for an Anime4K mode. Live.
class ShaderPresetSetting extends StatelessWidget {
  /// The running player's render mode (in the player); else the last one.
  final ReadonlySignal<RenderMode>? renderMode;
  const ShaderPresetSetting({super.key, this.renderMode});

  @override
  Widget build(BuildContext context) {
    final coord = AppScope.of(context).coordinator;
    final s = coord.settings;
    final dense = SettingDensity.of(context);
    return SignalBuilder(builder: (context) {
      final preset = s.shaderPreset.value;
      final quality = s.shaderQuality.value;
      final hasCustom = s.customShaders.value.isNotEmpty;
      final warning = switch (_renderMode(context, renderMode)) {
        RenderMode.software => 'Software rendering: shaders have no effect',
        RenderMode.softwareGl => 'OpenGL on the CPU: shaders will be slow',
        _ => null,
      };
      return SettingRow(
        label: 'Upscaling shader',
        help: 'Anime4K sharpens anime on your GPU, only you see it. '
            'A for 1080p, B for 720p, C for 480p; HQ for strong GPUs · Ctrl+1…6, Ctrl+0 off',
        control: AppSelect<ShaderPreset>(
          key: const ValueKey('shader-preset'),
          value: preset,
          items: [
            for (final p in ShaderPreset.values)
              if (p != ShaderPreset.custom || hasCustom || preset == p) (p, p.label),
          ],
          onChanged: (p) => applyShaderChoice(coord, p, null),
        ),
        below: !preset.isAnime4k && warning == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (preset.isAnime4k)
                    Padding(
                      padding: EdgeInsets.only(top: dense ? 2 : 6),
                      child: SegmentedButton<ShaderQuality>(
                        key: const ValueKey('shader-quality'),
                        showSelectedIcon: false,
                        style: const ButtonStyle(visualDensity: VisualDensity.compact),
                        segments: [
                          for (final q in ShaderQuality.values) ButtonSegment(value: q, label: Text(q.label)),
                        ],
                        selected: {quality},
                        onSelectionChanged: (q) => applyShaderChoice(coord, preset, q.first),
                      ),
                    ),
                  if (warning != null && preset != ShaderPreset.off)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(warning, style: TextStyle(fontSize: dense ? 11.5 : 12, color: Colors.orange)),
                    ),
                ],
              ),
      );
    });
  }
}

/// The video output at the player's size on screen ([AppSettings.screenResVideo]).
class ScreenResSetting extends StatelessWidget {
  final ReadonlySignal<RenderMode>? renderMode;
  const ScreenResSetting({super.key, this.renderMode});

  @override
  Widget build(BuildContext context) {
    final s = _settings(context);
    return SignalBuilder(builder: (context) {
      final software = _software(_renderMode(context, renderMode));
      return SettingSwitch(
        switchKey: const ValueKey('screen-res-video'),
        label: 'Sharp video and subtitles',
        help: software
            ? 'No effect: video uses software rendering'
            : "Scale the picture and draw subtitles at your screen's resolution, not the video's. "
                'Off: lighter on a weak GPU',
        brief: software ? 'No effect: software rendering' : null,
        value: s.screenResVideo.value,
        onChanged: s.setScreenResVideo,
      );
    });
  }
}

/// Puts the hwdec setting on the running player (mpv switches decoders
/// on the fly). `SYNC_RELAY_HWDEC` wins, as at player start.
Future<void> applyHwdecLive(PlaybackController playback, AppSettings settings) async {
  if ((Platform.environment['SYNC_RELAY_HWDEC'] ?? '').isNotEmpty) return;
  final p = playback.current;
  if (p == null) return;
  try {
    await p.setProperty('hwdec', settings.hwdec.peek());
  } catch (e) {
    debugPrint('live hwdec failed: $e');
  }
}

/// mpv's `hwdec`: auto, off, or a custom value typed under it (Enter
/// puts it on the running player). Live.
class HwdecSetting extends StatefulWidget {
  const HwdecSetting({super.key});

  @override
  State<HwdecSetting> createState() => _HwdecSettingState();
}

class _HwdecSettingState extends State<HwdecSetting> {
  late final _coord = AppScope.of(context).coordinator;
  late final _s = _coord.settings;
  late final _custom = TextEditingController(text: _s.hwdecCustom.peek());

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dense = SettingDensity.of(context);
    return SignalBuilder(builder: (context) {
      final mode = _s.hwdecMode.value;
      return SettingRow(
        label: 'Hardware decoding',
        help: 'Decodes video on the GPU. Turn it off if the picture glitches or stays black',
        control: AppSelect<HwdecMode>(
          key: const ValueKey('hwdec'),
          value: mode,
          items: const [(HwdecMode.auto, 'Auto'), (HwdecMode.off, 'Off'), (HwdecMode.custom, 'Custom')],
          onChanged: (m) {
            _s.setHwdecMode(m);
            applyHwdecLive(_coord.playback, _s);
          },
        ),
        below: mode != HwdecMode.custom
            ? null
            : Padding(
                padding: EdgeInsets.only(top: dense ? 4 : 8, bottom: dense ? 4 : 0),
                child: TextField(
                  key: const ValueKey('hwdec-custom'),
                  controller: _custom,
                  style: dense ? DenseText.label : null,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'mpv hwdec value (Enter applies)',
                    hintText: 'e.g. vaapi, nvdec, d3d11va, auto-safe',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _s.setHwdecCustom,
                  onSubmitted: (_) => applyHwdecLive(_coord.playback, _s),
                ),
              ),
      );
    });
  }
}

/// The controls' skin: Standard or Minimal. Live.
class PlayerDesignSetting extends StatelessWidget {
  const PlayerDesignSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _settings(context);
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Player design',
        help: 'Minimal has a thick timeline with chapters and what is downloaded yet',
        control: AppSelect<ControlsSkin>(
          key: const ValueKey('player-design'),
          value: s.controlsSkin.value,
          items: [for (final k in ControlsSkin.values) (k, k.label)],
          onChanged: s.setControlsSkin,
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
    final s = _settings(context);
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Controls size',
        help: 'Large makes the bar and its buttons a quarter bigger',
        control: AppSelect<ControlsSize>(
          key: const ValueKey('controls-size'),
          value: s.controlsSize.value,
          items: [for (final z in ControlsSize.values) (z, z.label)],
          onChanged: s.setControlsSize,
        ),
      ),
    );
  }
}

/// One optional bar button on or off (off: it is in the top bar's ⋯).
/// Live.
class BarButtonSetting extends StatelessWidget {
  final OptionalControl control;
  const BarButtonSetting({super.key, required this.control});

  @override
  Widget build(BuildContext context) {
    final s = _settings(context);
    return SignalBuilder(
      builder: (context) => SettingSwitch(
        switchKey: ValueKey('bar-${control.name}'),
        label: control.label,
        help: control.help,
        value: !s.hiddenControls.value.contains(control),
        onChanged: (on) => s.setControlShown(control, on),
      ),
    );
  }
}

/// The 2 px line at the bottom while the controls are hidden. Live.
class ProgressLineSetting extends StatelessWidget {
  const ProgressLineSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _settings(context);
    return SignalBuilder(
      builder: (context) => SettingSwitch(
        switchKey: const ValueKey('progress-line'),
        label: 'Progress line when hidden',
        help: 'A thin bar at the bottom of the video while the controls are hidden',
        value: s.progressLine.value,
        onChanged: s.setProgressLine,
      ),
    );
  }
}

/// A hold time in seconds, one decimal ("0.6 s").
String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';

/// How long Space is held to go BRB ([AppSettings.brbHoldMs], 0.4–0.8 s
/// in 0.1 s steps). Settings → Player → More only; the next press uses it.
class BrbHoldSetting extends StatelessWidget {
  const BrbHoldSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _settings(context);
    return SignalBuilder(
      builder: (context) => SettingTrack(
        label: 'BRB hold',
        help: 'How long to hold Space to go BRB; a shorter press plays or pauses',
        readout: _seconds(s.brbHoldMs.value),
        track: Slider(
          key: const ValueKey('brb-hold'),
          value: s.brbHoldMs.value.toDouble(),
          min: brbHoldRange.min.toDouble(),
          max: brbHoldRange.max.toDouble(),
          divisions: (brbHoldRange.max - brbHoldRange.min) ~/ 100,
          onChanged: (v) => s.setBrbHold(v.round()),
        ),
      ),
    );
  }
}

/// How long Space is held, while someone else is BRB, to continue
/// without them ([AppSettings.continueHoldMs], 1.5–3 s in 0.5 s steps).
/// Settings → Player → More only; the next press uses it.
class ContinueHoldSetting extends StatelessWidget {
  const ContinueHoldSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = _settings(context);
    return SignalBuilder(
      builder: (context) => SettingTrack(
        label: 'Continue-without hold',
        help: 'While someone is BRB: how long to hold Space to go on without them; a tap makes you BRB too',
        readout: _seconds(s.continueHoldMs.value),
        track: Slider(
          key: const ValueKey('continue-hold'),
          value: s.continueHoldMs.value.toDouble(),
          min: continueHoldRange.min.toDouble(),
          max: continueHoldRange.max.toDouble(),
          divisions: (continueHoldRange.max - continueHoldRange.min) ~/ 500,
          onChanged: (v) => s.setContinueHold(v.round()),
        ),
      ),
    );
  }
}
