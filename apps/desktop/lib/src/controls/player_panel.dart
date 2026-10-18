import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../app/app_graph.dart';
import '../danmaku/danmaku_settings.dart' show DanmakuKnobs, NotifyStyleSelect;
import '../playback/playback_controller.dart' show RenderMode;
import '../sfx/sfx.dart' show SfxKind;
import '../shaders/shader_presets.dart';
import '../shell/mark_problem.dart' show MarkProblemButton;
import '../shell/motion.dart';
import '../state/settings.dart';
import '../widgets/app_menu.dart';
import 'model/controls_prefs.dart';
import 'player_settings.dart' show applyHwdecLive, applyShaderChoice;
import 'volume.dart' as vol;

// The player panel (⚙ in the bar, both skins): a narrow glass
// column docked at the right edge of the full player that stays open
// while the controls hide and show, until its × or Esc. What is useful
// while watching, in collapsible sections: sound first (the video's
// volume, the app's sounds), tracks, subtitles, picture, notifications
// (toasts or danmaku, the danmaku look) and the controls. Everything
// applies live and is saved; "All settings" opens Settings where the
// section last used lives.

/// The panel's sections, in order.
enum PanelSection {
  sound('Sound'),
  tracks('Tracks'),
  subtitles('Subtitles'),
  picture('Picture'),
  notifications('Notifications'),
  controls('Controls');

  final String title;
  const PanelSection(this.title);
}

/// Sections folded by the user, kept for the app's run.
final _folded = <PanelSection>{PanelSection.notifications, PanelSection.controls};

/// The section last opened or used (a click in it), kept for the app's
/// run: "All settings" opens its page.
var _lastUsed = PanelSection.sound;

class PlayerPanel extends StatelessWidget {
  static const width = 312.0;
  final VoidCallback onClose;

  /// The running player's render mode (shader and sharp video notes).
  final ReadonlySignal<RenderMode>? renderMode;

  /// The player's volume (0..[vol.maxVolume]) and how to set it; the
  /// video's volume row only with both.
  final ReadonlySignal<double>? volume;
  final ValueChanged<double>? onVolume;

  /// "All settings": opens Settings at the page of the section last used.
  final ValueChanged<PanelSection>? onAllSettings;
  const PlayerPanel({
    super.key,
    required this.onClose,
    this.renderMode,
    this.volume,
    this.onVolume,
    this.onAllSettings,
  });

  /// The section "All settings" goes to now.
  static PanelSection get lastUsed => _lastUsed;

  @override
  Widget build(BuildContext context) {
    final graph = AppScope.of(context);
    final s = graph.coordinator.settings;
    return AppGlass(
      key: const ValueKey('player-panel'),
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 6, 2),
              child: Row(
                children: [
                  const Icon(Icons.settings_outlined, size: 18, color: Colors.white70),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Player settings', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                  IconButton(
                    key: const ValueKey('player-panel-close'),
                    tooltip: 'Close (Esc)',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(section: PanelSection.sound, children: [
                      if ((volume, onVolume) case (final v?, final set?))
                        SignalBuilder(
                          builder: (context) => _Row(
                            label: 'Volume',
                            control: _VolumeSlider(key: const ValueKey('panel-volume'), volume: v.value, onChanged: set),
                          ),
                        ),
                      SignalBuilder(
                        builder: (context) => _SliderRow(
                          key: const ValueKey('panel-app-sounds'),
                          label: 'App sounds',
                          help: 'Ready, joins and chat cues, not the video',
                          value: s.soundVolume.value,
                          min: 0,
                          max: 1,
                          readout: '${(s.soundVolume.value * 100).round()} %',
                          onChanged: s.setSoundVolume,
                          onChangeEnd: (_) => unawaited(graph.sfx.preview(SfxKind.ready, readyIndex: 2)),
                        ),
                      ),
                    ]),
                    const _Section(section: PanelSection.tracks, children: [
                      _TrackRow(type: JellyfinStreamType.subtitle),
                      _TrackRow(type: JellyfinStreamType.audio),
                    ]),
                    _Section(section: PanelSection.subtitles, children: [
                      SignalBuilder(
                        builder: (context) => _SliderRow(
                          key: const ValueKey('panel-sub-scale'),
                          label: 'Size',
                          value: s.subScale.value,
                          min: 0.5,
                          max: 2,
                          divisions: 30,
                          readout: '${(s.subScale.value * 100).round()} %',
                          onChanged: s.setSubScale,
                        ),
                      ),
                      SignalBuilder(
                        builder: (context) => _SwitchRow(
                          key: const ValueKey('panel-lift'),
                          label: 'Above the controls',
                          help: 'Bottom lines move up while the control bar shows (the chat box always lifts them)',
                          value: s.liftSubtitles.value,
                          onChanged: s.setLiftSubtitles,
                        ),
                      ),
                    ]),
                    _Section(section: PanelSection.picture, children: [
                      _ShaderRow(renderMode: renderMode),
                      SignalBuilder(builder: (context) {
                        final m = renderMode?.value;
                        final software = m == RenderMode.software || m == RenderMode.softwareGl;
                        return _SwitchRow(
                          key: const ValueKey('panel-sharp'),
                          label: 'Sharp video and subtitles',
                          help: software ? 'No effect: software rendering' : "At your screen's resolution",
                          value: s.screenResVideo.value,
                          onChanged: s.setScreenResVideo,
                        );
                      }),
                      const _HwdecRow(),
                    ]),
                    _Section(section: PanelSection.notifications, children: [
                      _Row(label: 'Show as', control: NotifyStyleSelect(settings: s)),
                      SignalBuilder(
                        builder: (context) => AnimatedSize(
                          duration: easeTime,
                          curve: ease,
                          alignment: Alignment.topCenter,
                          child: s.notifyStyle.value == NotifyStyle.danmaku
                              ? DanmakuKnobs(settings: s, dense: true)
                              : const SizedBox(width: double.infinity),
                        ),
                      ),
                    ]),
                    _Section(section: PanelSection.controls, children: [
                      SignalBuilder(
                        builder: (context) => _Row(
                          label: 'Design',
                          control: AppSelect<ControlsSkin>(
                            key: const ValueKey('panel-design'),
                            value: s.controlsSkin.value,
                            items: [for (final k in ControlsSkin.values) (k, k.label)],
                            onChanged: s.setControlsSkin,
                          ),
                        ),
                      ),
                      SignalBuilder(
                        builder: (context) => _SwitchRow(
                          key: const ValueKey('panel-progress-line'),
                          label: 'Progress line when hidden',
                          value: s.progressLine.value,
                          onChanged: s.setProgressLine,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        if (onAllSettings case final open?)
                          TextButton.icon(
                            key: const ValueKey('panel-all-settings'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onPressed: () => open(_lastUsed),
                            iconAlignment: IconAlignment.end,
                            icon: const Icon(Icons.chevron_right_rounded, size: 18),
                            label: const Text('All settings'),
                          ),
                        const MarkProblemButton(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled group that folds (its title is the toggle). A click anywhere
/// in it makes it the section last used.
class _Section extends StatefulWidget {
  final PanelSection section;
  final List<Widget> children;
  const _Section({required this.section, required this.children});

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  late bool _open = !_folded.contains(widget.section);

  void _toggle() {
    setState(() => _open = !_open);
    _open ? _folded.remove(widget.section) : _folded.add(widget.section);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Colors.white.withValues(alpha: 0.55);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _lastUsed = widget.section,
      child: _column(muted),
    );
  }

  Widget _column(Color muted) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('panel-section-${widget.section.title}'),
          borderRadius: BorderRadius.circular(AppMenuStyle.rowRadius),
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.section.title.toUpperCase(),
                      style: TextStyle(fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w600, color: muted)),
                ),
                AnimatedRotation(
                  turns: _open ? 0 : -0.25,
                  duration: easeTime,
                  curve: ease,
                  child: Icon(Icons.expand_more_rounded, size: 18, color: muted),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: easeTime,
          curve: ease,
          alignment: Alignment.topCenter,
          child: _open
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final Widget control;
  const _Row({required this.label, required this.control});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 40,
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Flexible(flex: 2, child: Align(alignment: Alignment.centerRight, child: control)),
          ],
        ),
      );
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final String? help;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({super.key, required this.label, this.help, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13)),
                  if (help != null)
                    Text(help!, style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.5))),
                ],
              ),
            ),
            Transform.scale(
              scale: 0.8,
              alignment: Alignment.centerRight,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ],
        ),
      );
}

class _SliderRow extends StatelessWidget {
  final String label;
  final String? help;
  final double value, min, max;
  final int? divisions;
  final String readout;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  const _SliderRow({
    super.key,
    required this.label,
    this.help,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.readout,
    required this.onChanged,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final row = _row(context);
    if (help == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        Text(help!, style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.5))),
      ],
    );
  }

  Widget _row(BuildContext context) => SizedBox(
        height: 38,
        child: Row(
          children: [
            SizedBox(width: 84, child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                ),
                child: Slider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text(readout,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.7),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ),
          ],
        ),
      );
}

/// The video's volume: the bar's [vol.VolumeBar] (a tick at 100 %, amber
/// above) across the row, and the percentage.
class _VolumeSlider extends StatelessWidget {
  final double volume;
  final ValueChanged<double> onChanged;
  const _VolumeSlider({super.key, required this.volume, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => vol.VolumeBar(volume: volume, onChanged: onChanged, width: box.maxWidth),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text('${volume.round()} %',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12,
                  color: volume > 100 ? vol.boostColor : Colors.white.withValues(alpha: 0.7),
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ),
        ],
      );
}

/// Hardware decoding: auto, off, or custom with mpv's value typed below
/// (Enter puts it on the running player).
class _HwdecRow extends StatefulWidget {
  const _HwdecRow();

  @override
  State<_HwdecRow> createState() => _HwdecRowState();
}

class _HwdecRowState extends State<_HwdecRow> {
  late final _s = AppScope.of(context).coordinator.settings;
  late final _custom = TextEditingController(text: _s.hwdecCustom.peek());

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = AppScope.of(context).coordinator.playback;
    return SignalBuilder(builder: (context) {
      final mode = _s.hwdecMode.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row(
            label: 'Hardware decoding',
            control: AppSelect<HwdecMode>(
              key: const ValueKey('panel-hwdec'),
              value: mode,
              items: const [(HwdecMode.auto, 'Auto'), (HwdecMode.off, 'Off'), (HwdecMode.custom, 'Custom')],
              onChanged: (m) {
                _s.setHwdecMode(m);
                applyHwdecLive(playback);
              },
            ),
          ),
          if (mode == HwdecMode.custom)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: TextField(
                key: const ValueKey('panel-hwdec-custom'),
                controller: _custom,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'mpv hwdec value (Enter applies)',
                  hintText: 'e.g. vaapi, nvdec, d3d11va',
                  border: OutlineInputBorder(),
                ),
                onChanged: _s.setHwdecCustom,
                onSubmitted: (_) => applyHwdecLive(playback),
              ),
            ),
        ],
      );
    });
  }
}

/// Subtitle or audio track of the running player; remembered for the
/// next episode.
class _TrackRow extends StatelessWidget {
  final JellyfinStreamType type;
  const _TrackRow({required this.type});

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
      final key = ValueKey(_audio ? 'panel-audio' : 'panel-subtitles');
      return _Row(
        label: _audio ? 'Audio' : 'Subtitles',
        control: items.isEmpty || selected == null
            ? Text(items.isEmpty ? 'None' : 'Pick one…', key: key, style: const TextStyle(fontSize: 13))
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

/// The upscaling shader: Anime4K mode (or custom files) and HQ / Fast.
class _ShaderRow extends StatelessWidget {
  final ReadonlySignal<RenderMode>? renderMode;
  const _ShaderRow({this.renderMode});

  @override
  Widget build(BuildContext context) {
    final coord = AppScope.of(context).coordinator;
    final s = coord.settings;
    return SignalBuilder(builder: (context) {
      final preset = s.shaderPreset.value;
      final hasCustom = s.customShaders.value.isNotEmpty;
      final software = switch (renderMode?.value) {
        RenderMode.software || RenderMode.softwareGl => true,
        _ => false,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row(
            label: 'Upscaling',
            control: AppSelect<ShaderPreset>(
              key: const ValueKey('panel-shader'),
              value: preset,
              items: [
                for (final p in ShaderPreset.values)
                  if (p != ShaderPreset.custom || hasCustom || preset == p) (p, p.label),
              ],
              onChanged: (p) => applyShaderChoice(coord, p, null),
            ),
          ),
          if (preset.isAnime4k)
            _Row(
              label: 'Shader quality',
              control: AppSelect<ShaderQuality>(
                key: const ValueKey('panel-shader-quality'),
                value: s.shaderQuality.value,
                items: [for (final q in ShaderQuality.values) (q, q.label)],
                onChanged: (q) => applyShaderChoice(coord, preset, q),
              ),
            ),
          if (software && preset != ShaderPreset.off)
            const Text('Software rendering: shaders have little or no effect',
                style: TextStyle(fontSize: 11.5, color: Colors.orange)),
        ],
      );
    });
  }
}
