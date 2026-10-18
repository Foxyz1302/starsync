import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../app/app_graph.dart';
import '../danmaku/danmaku_settings.dart' show DanmakuKnobs;
import '../playback/playback_controller.dart' show RenderMode;
import '../shell/mark_problem.dart' show MarkProblemButton;
import '../shell/motion.dart';
import '../shell/notice_settings.dart';
import '../state/settings.dart';
import '../widgets/app_menu.dart';
import 'player_settings.dart';

// The player panel (⚙ in the bar, both skins): a narrow glass column
// docked at the right edge of the full player that stays open while the
// controls hide and show, until ⚙ again, its × or Esc. The settings you
// adjust while looking at the video, drawn with Settings' own widgets
// (dense, under a [SettingDensity]) in sections that fold: sound first,
// subtitles & audio, picture (troubleshooting folded), over the video,
// controls. Everything applies live and is saved; "All settings" opens
// the Settings page of the section last used.

/// The panel's sections, in order.
enum PanelSection {
  sound('Sound'),
  subtitles('Subtitles & audio'),
  picture('Picture'),
  overVideo('Over the video'),
  controls('Controls');

  final String title;
  const PanelSection(this.title);
}

/// Sections folded by the user, kept for the app's run.
final _folded = <PanelSection>{PanelSection.overVideo, PanelSection.controls};

/// The section last opened or used (a click in it), kept for the app's
/// run: "All settings" opens its page.
var _lastUsed = PanelSection.sound;

class PlayerPanel extends StatelessWidget {
  static const width = 312.0;
  final VoidCallback onClose;

  /// The running player's render mode (shader and sharp video notes).
  final ReadonlySignal<RenderMode>? renderMode;

  /// "All settings": opens Settings at the page of the section last used.
  final ValueChanged<PanelSection>? onAllSettings;
  const PlayerPanel({super.key, required this.onClose, this.renderMode, this.onAllSettings});

  /// The section "All settings" goes to now.
  static PanelSection get lastUsed => _lastUsed;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return AppGlass(
      key: const ValueKey('player-panel'),
      child: SizedBox(
        width: width,
        child: SettingDensity(
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
                      const _Section(section: PanelSection.sound, children: [
                        VideoVolumeSetting(),
                        AppSoundsSetting(),
                      ]),
                      const _Section(section: PanelSection.subtitles, children: [
                        TrackSetting(type: JellyfinStreamType.subtitle),
                        TrackSetting(type: JellyfinStreamType.audio),
                        SubScaleSetting(),
                        LiftSubtitlesSetting(),
                      ]),
                      _Section(section: PanelSection.picture, children: [
                        ShaderPresetSetting(renderMode: renderMode),
                        SettingFold(
                          title: 'Troubleshooting',
                          children: [ScreenResSetting(renderMode: renderMode), const HwdecSetting()],
                        ),
                      ]),
                      _Section(section: PanelSection.overVideo, children: [
                        const NotifyStyleSetting(),
                        const ChatPopupsSetting(),
                        SignalBuilder(
                          builder: (context) => AnimatedSize(
                            duration: easeTime,
                            curve: ease,
                            alignment: Alignment.topCenter,
                            child: s.notifyStyle.value == NotifyStyle.danmaku
                                ? SettingFold(title: 'Danmaku look', children: [DanmakuKnobs(settings: s)])
                                : const SizedBox(width: double.infinity),
                          ),
                        ),
                      ]),
                      const _Section(section: PanelSection.controls, children: [
                        PlayerDesignSetting(),
                        ControlsSizeSetting(),
                        ProgressLineSetting(),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('panel-section-${widget.section.name}'),
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
      ),
    );
  }
}
