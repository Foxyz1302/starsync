import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart' show JellyfinStreamType;

import '../jellyfin/track_prefs.dart' show MpvTrack;
import '../playback/media_marks.dart';
import '../shell/mark_problem.dart';
import '../widgets/app_menu.dart';
import '../widgets/copy_open.dart';
import 'frame.dart';
import 'model/controls_layout.dart';
import 'model/controls_model.dart';

// The controls' menus, shared by both skins: the track and chapter lists
// and the top bar's ⋯ menu, all on the app's menu (`showAppMenu`),
// anchored on the button that opens them. Each keeps the controls up
// while open.

/// How many tracks of [type] there are.
int trackCount(List<MpvTrack> tracks, JellyfinStreamType type) => tracks.where((t) => t.type == type).length;

/// The audio or subtitle tracks ("Japanese · E-AC3 2.0 · title"), mpv's
/// selection checked; subtitles start with Off.
List<AppMenuItem<TrackPick>> trackMenuItems(JellyfinStreamType type, List<MpvTrack> tracks) {
  final audio = type == JellyfinStreamType.audio;
  final list = tracks.where((t) => t.type == type).toList();
  return [
    if (!audio)
      AppMenuItem(
        key: const ValueKey('track-off'),
        value: (aid: null, sid: null, subtitlesOff: true),
        label: 'Off',
        checked: !list.any((t) => t.selected),
      ),
    if (audio && list.isEmpty)
      const AppMenuItem(value: (aid: null, sid: null, subtitlesOff: false), label: 'None', enabled: false),
    for (final t in list)
      AppMenuItem(
        key: ValueKey('track-${t.type.name}-${t.id}'),
        value: audio ? (aid: t.id, sid: null, subtitlesOff: false) : (aid: null, sid: t.id, subtitlesOff: false),
        label: t.label,
        checked: t.selected,
      ),
  ];
}

/// Chapters with their start times, the playing one checked.
List<AppMenuItem<MediaChapter>> chapterMenuItems(List<MediaChapter> chapters, int? current) => [
  for (final c in chapters)
    AppMenuItem(
      key: ValueKey('chapter-${c.index}'),
      value: c,
      label: c.title.isEmpty ? 'Chapter ${c.index + 1}' : c.title,
      hint: formatClock(c.start),
      checked: c.index == current,
    ),
];

Future<T?> _menu<T>(BuildContext context, PlayerControlsModel model, List<AppMenuItem<T>> items) async {
  model.menusOpen++;
  try {
    return await showAppMenu<T>(context, items: items);
  } finally {
    model.menusOpen--;
  }
}

/// The audio or subtitle list; a pick is applied (and remembered).
Future<void> openTrackMenu(BuildContext context, PlayerControlsModel model, JellyfinStreamType type) async {
  final pick = await _menu(context, model, trackMenuItems(type, model.tracks.peek()));
  if (pick != null) model.pickTrack(pick);
}

/// The chapter list; a pick jumps there for everyone.
Future<void> openChapterMenu(BuildContext context, PlayerControlsModel model) async {
  final pick = await _menu(context, model, chapterMenuItems(model.chapters.peek(), model.currentChapter.peek()));
  if (pick != null) model.pickChapter(pick);
}

/// The top bar's ⋯ menu ("Video and session"): what plays and the
/// server, and the bar buttons the user hid.
Future<void> openMoreMenu(BuildContext context, PlayerControlsModel model) async {
  final pick = await _menu(context, model, [
    for (final a in model.menu())
      AppMenuItem(key: ValueKey('controls-menu-${a.name}'), value: a, label: a.label, hint: a.hint),
  ]);
  if (pick != null && context.mounted) await runControlAction(context, model, pick);
}

/// Runs a ⋯ menu action; [context] anchors what it opens next.
Future<void> runControlAction(BuildContext context, PlayerControlsModel model, ControlAction action) async {
  switch (action) {
    case ControlAction.chapters:
      await openChapterMenu(context, model);
    case ControlAction.subtitles:
      await openTrackMenu(context, model, JellyfinStreamType.subtitle);
    case ControlAction.audio:
      await openTrackMenu(context, model, JellyfinStreamType.audio);
    case ControlAction.skipForward:
      model.skipForward();
    case ControlAction.chat:
      model.toggleChat();
    case ControlAction.changeVideo:
      model.changeVideo();
    case ControlAction.copyLink:
      final link = model.link();
      if (link != null) await copyToClipboard(context, link, done: 'Link copied');
    case ControlAction.screenshot:
      model.screenshot();
    case ControlAction.reload:
      model.reload();
    case ControlAction.markProblem:
      await ControlsFrame.holdWhile(context, () => showMarkProblem(context));
    case ControlAction.leave:
      model.leave();
  }
}
