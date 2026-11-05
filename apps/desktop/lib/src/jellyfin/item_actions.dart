import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../app/app_graph.dart';
import '../session/app_events.dart' show ActionFailed;
import '../widgets/app_menu.dart';
import '../widgets/copy_open.dart';
import 'browse_scope.dart';
import 'format.dart';
import 'home_rows.dart' show continueKey;

// What a Jellyfin item offers, from one list per kind: the right-click
// menu of every card, tile and row, the details panel's buttons and its ⋮,
// the show page's buttons and its seasons' menus all read [jellyfinActions]
// and run [JellyfinItemActions.run], so they cannot drift apart.

enum JellyfinAction {
  putUp,
  addToQueue,
  playNext,
  markWatched,
  markUnwatched,
  removeFromContinue,
  openShow,
  copyTitle,
  openInJellyfin,
}

/// One action as every menu and button shows it.
typedef JellyfinActionView = ({JellyfinAction action, String label, IconData icon});

/// The words for the watched marks.
abstract final class JellyfinActionText {
  static const addToQueue = 'Add to queue';
  static const playNext = 'Play next';
  static const removeFromContinue = 'Remove from Continue';
  static const openShow = 'Open the show page';

  static String putUp({bool alone = false}) => alone ? 'Play' : 'Put it up';

  /// "Mark watched", "Mark season unwatched", "Mark show watched".
  static String mark(JellyfinItem item, {required bool played}) {
    final what = switch (item.kind) {
      JellyfinItemKind.series => 'show ',
      JellyfinItemKind.season => 'season ',
      _ => '',
    };
    return 'Mark $what${played ? 'watched' : 'unwatched'}';
  }
}

/// The show page an item belongs to: a show's own, a season's or an
/// episode's show; null for anything else.
String? showIdOf(JellyfinItem item) => switch (item.kind) {
  JellyfinItemKind.series => item.id,
  JellyfinItemKind.season || JellyfinItemKind.episode => item.seriesId,
  _ => null,
};

/// What [item] offers, in menu order. Episodes, movies and videos: put it
/// up, queue, mark watched or unwatched (by its state), remove from
/// Continue, the show page (episodes), copy and open. Shows: the same, the
/// mark for every episode and the put-up for the next one. Seasons: the
/// season's mark, the show page, copy and open. Libraries and folders:
/// copy and open. [queue]: in a server (Up next works); [alone]: put it up
/// says Play; [inContinue]: its show (or itself) is in the Continue row or
/// has a resume point; [onShowPage]: its show's page is open (no link to
/// it).
List<JellyfinActionView> jellyfinActions(
  JellyfinItem item, {
  bool queue = false,
  bool alone = false,
  bool inContinue = false,
  bool onShowPage = false,
}) {
  final kind = item.kind;
  final playable = isPlayable(item) || kind == JellyfinItemKind.series;
  final marks = playable || kind == JellyfinItemKind.season;
  final played = item.userData.played;
  return [
    if (playable) ...[
      (action: JellyfinAction.putUp, label: JellyfinActionText.putUp(alone: alone), icon: Icons.play_arrow_rounded),
      if (queue) ...[
        (action: JellyfinAction.addToQueue, label: JellyfinActionText.addToQueue, icon: Icons.playlist_add_rounded),
        (action: JellyfinAction.playNext, label: JellyfinActionText.playNext, icon: Icons.queue_play_next_rounded),
      ],
    ],
    if (marks)
      played
          ? (
              action: JellyfinAction.markUnwatched,
              label: JellyfinActionText.mark(item, played: false),
              icon: Icons.check_circle_rounded,
            )
          : (
              action: JellyfinAction.markWatched,
              label: JellyfinActionText.mark(item, played: true),
              icon: Icons.check_circle_outline_rounded,
            ),
    if (playable && inContinue)
      (
        action: JellyfinAction.removeFromContinue,
        label: JellyfinActionText.removeFromContinue,
        icon: Icons.remove_circle_outline_rounded,
      ),
    if (showIdOf(item) != null && !onShowPage)
      (action: JellyfinAction.openShow, label: JellyfinActionText.openShow, icon: Icons.live_tv_outlined),
    (action: JellyfinAction.copyTitle, label: ReuseText.copyTitle, icon: Icons.copy_rounded),
    (action: JellyfinAction.openInJellyfin, label: ReuseText.openInJellyfin, icon: Icons.open_in_browser_rounded),
  ];
}

/// [views] as menu rows (with their icons).
List<AppMenuItem<JellyfinAction>> jellyfinMenuItems(List<JellyfinActionView> views) => [
  for (final v in views)
    AppMenuItem(key: ValueKey('jf-action-${v.action.name}'), value: v.action, label: v.label, icon: v.icon),
];

/// Runs the actions of items on one Jellyfin server: put it up and queue
/// through the Library's callbacks (each returns an error text, or null),
/// watched marks and Continue through the [controller] (rows update at
/// once), the show page in the browser, copy and open.
class JellyfinItemActions {
  final BrowseController controller;
  final String serverId;

  /// Nobody else in the server: put it up says Play.
  final bool alone;
  final Future<String?> Function(JellyfinItem item) putUp;

  /// Null: no server, no queue actions.
  final Future<String?> Function(JellyfinItem item, {bool next})? queue;
  const JellyfinItemActions({
    required this.controller,
    required this.serverId,
    required this.putUp,
    this.queue,
    this.alone = false,
  });

  JellyfinClient? get client => controller.accounts.clientFor(serverId);

  /// [item] with the watched marks made here (see [BrowseController.marked]).
  JellyfinItem marked(JellyfinItem item) => controller.marked(serverId, item);

  /// Its show (or itself) is in the Continue row, or it has a resume point.
  bool inContinue(JellyfinItem item) =>
      (isPlayable(item) && item.userData.isResumable) || controller.continueKeys.contains(continueKey(item));

  /// The browser shows [item]'s show page now.
  bool onShowPage(JellyfinItem item) {
    final top = controller.stack.last;
    final show = showIdOf(item);
    return show != null && controller.serverId == serverId && top is SeriesRoute && top.series.id == show;
  }

  /// What [item] offers here and now (see [jellyfinActions]).
  List<JellyfinActionView> of(JellyfinItem item) {
    final i = marked(item);
    return jellyfinActions(i, queue: queue != null, alone: alone, inContinue: inContinue(i), onShowPage: onShowPage(i));
  }

  /// Runs [action] on [item] ([context]: where it was asked, for the
  /// confirmation and the copy toast). Returns an error text, or null when
  /// done or cancelled. Marking a whole show asks first.
  Future<String?> run(BuildContext context, JellyfinItem item, JellyfinAction action) async {
    try {
      switch (action) {
        case JellyfinAction.putUp:
          return await putUp(item);
        case JellyfinAction.addToQueue:
          return await queue?.call(item);
        case JellyfinAction.playNext:
          return await queue?.call(item, next: true);
        case JellyfinAction.markWatched || JellyfinAction.markUnwatched:
          final played = action == JellyfinAction.markWatched;
          if (item.kind == JellyfinItemKind.series && !await confirmShowMark(context, item, played: played)) {
            return null;
          }
          await controller.setPlayed(serverId, item, played);
        case JellyfinAction.removeFromContinue:
          await controller.removeFromContinue(serverId, item);
        case JellyfinAction.openShow:
          openShow(item);
        case JellyfinAction.copyTitle:
          if (context.mounted) await copyToClipboard(context, jellyfinCopyTitle(item), done: 'Title copied');
        case JellyfinAction.openInJellyfin:
          final c = client;
          if (c == null) return 'that Jellyfin server is not linked any more';
          if (context.mounted) await openLink(context, jellyfinWebUrl(c.baseUrl, item.id, serverId: serverId));
      }
    } on JellyfinException catch (e) {
      return e.isUnauthorized ? 'Jellyfin sign-in expired' : e.message;
    } catch (e) {
      return '$e';
    }
    return null;
  }

  /// Opens [item]'s show page (a season's: on that season; an episode's:
  /// on its season).
  void openShow(JellyfinItem item) {
    final show = showIdOf(item);
    if (show == null) return;
    if (controller.serverId != serverId) controller.switchServer(serverId);
    final series = item.kind == JellyfinItemKind.series
        ? item
        : JellyfinItem(id: show, name: item.seriesName ?? '', type: 'Series');
    controller.open(
      SeriesRoute(
        series,
        seasonId: switch (item.kind) {
          JellyfinItemKind.season => item.id,
          JellyfinItemKind.episode => item.seasonId,
          _ => null,
        },
      ),
    );
  }

  /// [run], an error as a toast.
  Future<void> runOrToast(BuildContext context, JellyfinItem item, JellyfinAction action) async {
    final error = await run(context, item, action);
    if (error != null && context.mounted) AppScope.maybeOf(context)?.notifier.notify(ActionFailed(error));
  }

  /// The menu of [item] at [context] (its card or row); errors as a toast.
  Future<void> showMenu(BuildContext context, JellyfinItem item) async {
    final pick = await showAppMenu<JellyfinAction>(context, items: jellyfinMenuItems(of(item)));
    if (pick != null && context.mounted) await runOrToast(context, item, pick);
  }
}

/// Asks before marking every episode of [show] (it is many items, and
/// unwatched drops their play counts and resume points too).
Future<bool> confirmShowMark(BuildContext context, JellyfinItem show, {required bool played}) async {
  final count = show.recursiveItemCount;
  final every = count != null && count > 0 ? 'all $count episodes' : 'every episode';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('jf-confirm-mark'),
      title: Text(played ? 'Mark ${show.name} watched?' : 'Mark ${show.name} unwatched?'),
      content: Text(
        played
            ? 'This marks $every watched on Jellyfin.'
            : 'This marks $every unwatched on Jellyfin and clears where you stopped in them.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(
          key: const ValueKey('jf-confirm-mark-ok'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(played ? 'Mark watched' : 'Mark unwatched'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// "⋮" with the whole list of [views] (the same as the right-click menu).
class JellyfinMoreButton extends StatelessWidget {
  final List<JellyfinActionView> views;
  final ValueChanged<JellyfinAction> onRun;
  const JellyfinMoreButton({super.key, required this.views, required this.onRun});

  @override
  Widget build(BuildContext context) => AppMenuButton<JellyfinAction>(
    tooltip: 'More',
    icon: const Icon(Icons.more_vert),
    items: () => jellyfinMenuItems(views),
    onSelected: onRun,
  );
}

/// Buttons for [views]: [primary] as a filled button with [primaryLabel]
/// (put it up), [icons] as icon buttons with the action's own icon and
/// name, and ([more]) a ⋮ with the whole list ([JellyfinMoreButton]).
/// [busy] disables them; [onRun] runs one.
class JellyfinActionButtons extends StatelessWidget {
  final List<JellyfinActionView> views;
  final JellyfinAction? primary;
  final String? primaryLabel;
  final Set<JellyfinAction> icons;
  final bool busy;
  final bool more;
  final ValueChanged<JellyfinAction> onRun;

  /// Key prefix of the buttons ('details', 'series').
  final String keyPrefix;
  const JellyfinActionButtons({
    super.key,
    required this.views,
    required this.onRun,
    required this.keyPrefix,
    this.primary,
    this.primaryLabel,
    this.icons = const {},
    this.busy = false,
    this.more = true,
  });

  /// The icon buttons the details panel shows next to Put it up.
  static const panelIcons = {
    JellyfinAction.addToQueue,
    JellyfinAction.markWatched,
    JellyfinAction.markUnwatched,
    JellyfinAction.removeFromContinue,
    JellyfinAction.openShow,
  };

  @override
  Widget build(BuildContext context) {
    final main = views.where((v) => v.action == primary).firstOrNull;
    final hasQueueNext = views.any((v) => v.action == JellyfinAction.playNext);
    // Compact icons: Put it up and the common ones fit one line of the
    // 400 px panel.
    return IconButtonTheme(
      data: IconButtonThemeData(style: IconButton.styleFrom(visualDensity: VisualDensity.compact)),
      child: Wrap(
        spacing: 2,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (main != null)
            FilledButton.icon(
              key: ValueKey('$keyPrefix-put-up'),
              onPressed: busy ? null : () => onRun(main.action),
              icon: busy
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(main.icon),
              label: Text(primaryLabel ?? main.label, overflow: TextOverflow.ellipsis),
            ),
          for (final v in views)
            if (v.action != primary && icons.contains(v.action))
              v.action == JellyfinAction.addToQueue && hasQueueNext
                  // Right-click: play next, as before.
                  ? GestureDetector(
                      onSecondaryTap: busy ? null : () => onRun(JellyfinAction.playNext),
                      child: _icon(
                        v,
                        tooltip: '${v.label} (right-click: ${JellyfinActionText.playNext.toLowerCase()})',
                      ),
                    )
                  : _icon(v),
          if (more) JellyfinMoreButton(key: ValueKey('$keyPrefix-more'), views: views, onRun: onRun),
        ],
      ),
    );
  }

  Widget _icon(JellyfinActionView v, {String? tooltip}) => IconButton(
    key: ValueKey('$keyPrefix-${v.action.name}'),
    tooltip: tooltip ?? v.label,
    onPressed: busy ? null : () => onRun(v.action),
    icon: Icon(v.icon),
  );
}
