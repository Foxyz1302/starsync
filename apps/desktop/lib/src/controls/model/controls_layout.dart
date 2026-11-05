import 'package:flutter/material.dart' show IconData, Icons;

import '../../playback/media_marks.dart' show formatClock;
import 'controls_prefs.dart';

// The controls layout, defined once for both skins: which controls the
// bottom bar has, in which order, which actions sit in the top bar's ⋯
// menu ("Video and session") instead, and their icons, tooltips and
// labels. ⚙ is the player panel. Pure: everything here is a function of a
// [ControlsSnapshot] and the user's choices, so tests cover it without a
// player.

/// What playback does as this viewer sees it. In a server "play" is being
/// ready: the video plays once everyone is.
enum PlayState {
  /// The video plays (the button pauses: you go unready).
  playing,

  /// You are ready; the others are not yet (the button unreadies you).
  waiting,

  /// You are not ready (the button readies you).
  paused,

  /// The media ended.
  finished,
}

/// A control in the bottom bar.
enum BarControl {
  playPause,

  /// Previous episode.
  previous,

  /// Up next's first item, else the next episode.
  next,
  chapterPrevious,
  chapterNext,
  volume,
  time,
  subtitles,
  audio,

  /// ⚙: opens and closes the player panel.
  settings,
  chat,
  fullscreen,
}

/// An action in the top bar's ⋯ menu: what plays and the server, then
/// the bar buttons the user hid.
enum ControlAction {
  changeVideo('Change video', null),
  copyLink('Copy link', null),
  reload('Reload video', 'Ctrl+R'),
  skipForward('Skip 1:30', 'Shift+Right'),
  chapters('Chapters…', 'PgDn / PgUp'),
  subtitles('Subtitles…', null),
  audio('Audio…', null),
  chat('Chat & activity', 'Tab'),
  markAllReady('Mark everyone ready', null),
  markProblem('Mark a problem', 'Ctrl+Shift+B'),
  leave('Leave server', null);

  final String label;
  final String? hint;
  const ControlAction(this.label, this.hint);
}

/// The bar's order, left cluster then right cluster. The play button is
/// always first and fullscreen always last; controls that do not apply
/// (no episode, no chapters) or that the user hid are left out, the rest
/// keep their order.
abstract final class ControlsLayout {
  static const left = [
    BarControl.playPause,
    BarControl.previous,
    BarControl.next,
    BarControl.chapterPrevious,
    BarControl.chapterNext,
    BarControl.volume,
    BarControl.time,
  ];
  static const right = [
    BarControl.subtitles,
    BarControl.audio,
    BarControl.settings,
    BarControl.chat,
    BarControl.fullscreen,
  ];

  /// The ⋯ menu's order.
  static const menu = ControlAction.values;
}

/// What the layout depends on, at one moment.
class ControlsSnapshot {
  final PlayState play;

  /// The previous episode's label; null: none.
  final String? previousLabel;

  /// Up next's first item's title, else the next episode's label; null:
  /// nothing next.
  final String? nextLabel;

  /// [nextLabel] is Up next (not an episode).
  final bool nextIsUpNext;
  final bool hasChapters;

  /// The media's length is known (seeks and skips make sense).
  final bool hasDuration;

  /// Watching alone (no one to mark ready).
  final bool alone;

  /// A link to copy (`SessionCoordinator.currentLink`).
  final bool hasLink;
  final bool fullscreen;
  final bool chatOpen;

  /// The player panel is open (⚙ shows it).
  final bool panelOpen;
  const ControlsSnapshot({
    this.play = PlayState.paused,
    this.previousLabel,
    this.nextLabel,
    this.nextIsUpNext = false,
    this.hasChapters = false,
    this.hasDuration = false,
    this.alone = false,
    this.hasLink = false,
    this.fullscreen = false,
    this.chatOpen = false,
    this.panelOpen = false,
  });
}

/// The bar's two clusters for [s], in [ControlsLayout] order.
({List<BarControl> left, List<BarControl> right}) barControls(ControlsSnapshot s, Set<OptionalControl> hidden) {
  bool on(BarControl c) => switch (c) {
    BarControl.previous => s.previousLabel != null,
    BarControl.next => s.nextLabel != null,
    BarControl.chapterPrevious || BarControl.chapterNext => s.hasChapters && !hidden.contains(OptionalControl.chapters),
    BarControl.subtitles => !hidden.contains(OptionalControl.subtitles),
    BarControl.audio => !hidden.contains(OptionalControl.audio),
    BarControl.chat => !hidden.contains(OptionalControl.chat),
    _ => true,
  };
  return (
    left: [
      for (final c in ControlsLayout.left)
        if (on(c)) c,
    ],
    right: [
      for (final c in ControlsLayout.right)
        if (on(c)) c,
    ],
  );
}

/// The ⋯ menu for [s]: every action that applies, minus the buttons the
/// bar already shows.
List<ControlAction> menuActions(ControlsSnapshot s, Set<OptionalControl> hidden) => [
  for (final a in ControlsLayout.menu)
    if (switch (a) {
      ControlAction.chapters => s.hasChapters,
      ControlAction.subtitles => hidden.contains(OptionalControl.subtitles),
      ControlAction.audio => hidden.contains(OptionalControl.audio),
      ControlAction.skipForward => s.hasDuration,
      ControlAction.chat => hidden.contains(OptionalControl.chat),
      ControlAction.copyLink => s.hasLink,
      ControlAction.markAllReady => !s.alone,
      _ => true,
    })
      a,
];

/// Whether a bar control does something now (a skin dims it otherwise).
bool controlEnabled(BarControl c, ControlsSnapshot s) => switch (c) {
  BarControl.chapterPrevious || BarControl.chapterNext => s.hasChapters && s.hasDuration,
  BarControl.previous => s.previousLabel != null,
  BarControl.next => s.nextLabel != null,
  _ => true,
};

/// The icon of a bar control (volume and the clock draw their own).
IconData controlIcon(BarControl c, ControlsSnapshot s) => switch (c) {
  BarControl.playPause => switch (s.play) {
    PlayState.playing => Icons.pause_rounded,
    // Ready: the check says so; a click unreadies.
    PlayState.waiting => Icons.check_rounded,
    PlayState.finished => Icons.replay_rounded,
    PlayState.paused => Icons.play_arrow_rounded,
  },
  BarControl.previous => Icons.skip_previous_rounded,
  BarControl.next => Icons.skip_next_rounded,
  BarControl.chapterPrevious => Icons.chevron_left_rounded,
  BarControl.chapterNext => Icons.chevron_right_rounded,
  BarControl.volume => Icons.volume_up_rounded,
  BarControl.time => Icons.schedule_rounded,
  BarControl.subtitles => Icons.subtitles_outlined,
  BarControl.audio => Icons.graphic_eq_rounded,
  BarControl.settings => s.panelOpen ? Icons.settings_rounded : Icons.settings_outlined,
  BarControl.chat => s.chatOpen ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
  BarControl.fullscreen => s.fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
};

/// The tooltip of a bar control, with its key.
String controlTooltip(BarControl c, ControlsSnapshot s) => switch (c) {
  BarControl.playPause => switch (s.play) {
    PlayState.playing => 'Pause for everyone (Space)',
    PlayState.waiting => 'Ready, waiting for the others (Space: not ready)',
    PlayState.paused => s.alone ? 'Play (Space)' : 'Ready: play when everyone is (Space)',
    PlayState.finished => 'Ready (Space)',
  },
  BarControl.previous => 'Previous: ${s.previousLabel ?? ''}  (< or Shift+P)',
  BarControl.next => '${s.nextIsUpNext ? 'Up next' : 'Next'}: ${s.nextLabel ?? ''}  (> or Shift+N)',
  BarControl.chapterPrevious => 'Previous chapter (PgDn)',
  BarControl.chapterNext => 'Next chapter (PgUp)',
  BarControl.volume => 'Volume (M mutes, scroll, ↑ / ↓)',
  BarControl.time => 'Elapsed / remaining (click to switch)',
  BarControl.subtitles => 'Subtitles',
  BarControl.audio => 'Audio',
  BarControl.settings => 'Player settings',
  BarControl.chat => 'Chat & activity (Tab)',
  BarControl.fullscreen => s.fullscreen ? 'Exit fullscreen (F, Esc)' : 'Fullscreen (F)',
};

/// The top bar's ⋯: the [ControlAction] menu.
const moreIcon = Icons.more_horiz_rounded;
const moreTooltip = 'Video and session';

/// The bar's clock: "6:00 / 24:00", or the time left ("-18:00"); "0:00"
/// parts while the length is unknown.
String clockText(Duration position, Duration duration, TimeDisplay display) {
  if (display == TimeDisplay.remaining && duration > Duration.zero) {
    final left = duration - position;
    return '-${formatClock(left.isNegative ? Duration.zero : left)}';
  }
  return '${formatClock(position)} / ${formatClock(duration)}';
}
