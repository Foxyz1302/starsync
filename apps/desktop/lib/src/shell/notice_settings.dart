import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../app/app_graph.dart';
import '../sfx/sfx.dart' show SfxKind;
import '../state/settings.dart';
import '../widgets/app_menu.dart' show AppSelect;
import '../widgets/setting_rows.dart';

// What shows over the video and what the app's sounds do, one widget per
// setting: Settings → Notifications & sounds and the player panel draw
// these same rows (dense there, under a [SettingDensity]).

/// How loud the app's own cues are ([AppSettings.soundVolume]); never
/// the video. Letting go of the slider plays the ready sound.
class AppSoundsSetting extends StatelessWidget {
  const AppSoundsSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final graph = AppScope.of(context);
    final s = graph.coordinator.settings;
    return SignalBuilder(
      builder: (context) => SettingTrack(
        key: const ValueKey('app-sounds'),
        label: 'App sounds',
        help: "The app's own cues: ready, joins, chat. Not the video (Settings → Player → Volume). "
            'Letting go of the slider plays the ready sound',
        brief: 'Ready, joins and chat cues, not the video',
        readout: '${(s.soundVolume.value * 100).round()} %',
        track: Slider(
          key: const ValueKey('sound-volume'),
          value: s.soundVolume.value,
          onChanged: s.setSoundVolume,
          onChangeEnd: (_) => unawaited(graph.sfx.preview(SfxKind.ready, readyIndex: 2)),
        ),
      ),
    );
  }
}

/// Over the full player: toasts or danmaku ([AppSettings.notifyStyle]).
class NotifyStyleSetting extends StatelessWidget {
  const NotifyStyleSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Notifications',
        help: 'Toasts pop up bottom left. With Danmaku, chat, joins, leaves and Up next fly across the top of '
            'the big player instead (problems stay toasts)',
        control: AppSelect<NotifyStyle>(
          key: const ValueKey('notify-style'),
          value: s.notifyStyle.value,
          onChanged: s.setNotifyStyle,
          items: [for (final m in NotifyStyle.values) (m, m.label)],
        ),
      ),
    );
  }
}

/// Which chat messages pop up ([AppSettings.chatPopups]).
class ChatPopupsSetting extends StatelessWidget {
  const ChatPopupsSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return SignalBuilder(
      builder: (context) => SettingRow(
        label: 'Chat pop-ups',
        help: 'Chat messages pop up (or fly) like the rest; they are always in Chat & activity (Tab)',
        control: AppSelect<ChatPopups>(
          key: const ValueKey('chat-popups'),
          value: s.chatPopups.value,
          onChanged: s.setChatPopups,
          items: [for (final m in ChatPopups.values) (m, m.label)],
        ),
      ),
    );
  }
}

/// Joins and leaves also reach you while out or in the
/// background ([AppSettings.notifyPeople]).
class NotifyPeopleSetting extends StatelessWidget {
  const NotifyPeopleSetting({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).coordinator.settings;
    return SignalBuilder(
      builder: (context) => SettingSwitch(
        switchKey: const ValueKey('notify-people'),
        label: 'Joins and leaves too',
        help: 'While you are out or the window is in the background, also who joins, leaves or loses connection '
            '(otherwise only chat, nudges, "starting now" and Up next)',
        value: s.notifyPeople.value,
        onChanged: s.setNotifyPeople,
      ),
    );
  }
}
