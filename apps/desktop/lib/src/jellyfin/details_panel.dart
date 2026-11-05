import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../shell/motion.dart';
import '../widgets/app_menu.dart';
import 'accounts.dart';
import 'browse_scope.dart';
import 'cards.dart' show doubleClickTime, kindIcon;
import 'format.dart';
import 'images.dart';
import 'item_actions.dart';

/// Width of the details panel (docked or floating).
const detailsPanelWidth = 400.0;

/// What putting up [item] plays: itself when playable; for a series its
/// next episode (resume point or next up), else its first unwatched, else
/// its first episode. Null when there is nothing to play.
Future<JellyfinItem?> playableFor(JellyfinClient c, JellyfinItem item) async {
  if (isPlayable(item)) return item;
  if (item.kind != JellyfinItemKind.series) return null;
  final next = await c.nextUp(seriesId: item.id, limit: 1, enableResumable: true);
  if (next.isNotEmpty) return next.first;
  final eps = await c.episodes(item.id);
  return eps.where((e) => !e.userData.played).firstOrNull ?? eps.firstOrNull;
}

typedef _Data = ({
  JellyfinItem item,
  JellyfinItem? series,
  List<JellyfinItem> seasons,
  JellyfinItem? next,
});

/// The selected card's details, at the right of the library: banner,
/// title, meta, "Put it up · S1E3" ("Play · S1E3" when watching
/// [alone]) and the item's actions ([jellyfinActions]: the common ones as
/// buttons, all of them under ⋮, the same list as its right-click menu;
/// a series' marks are the whole show's, an episode's its own), overview
/// and, for a series or an episode, the episode list (click picks which
/// episode goes up, double-click puts it up, right-click its menu) under
/// the season picker and the season's actions. Reloads when the
/// [controller]'s data version moves.
class JellyfinDetailsPanel extends StatefulWidget {
  final BrowseController controller;
  final JellyfinSelection selection;
  /// Nobody else is in the server: the button says Play.
  final bool alone;
  /// Puts [item] (playable) up; returns an error text, or null when sent.
  final Future<String?> Function(JellyfinSelection item) onPutUp;
  /// Adds [item] to Up next (with next: right after what plays); null: no
  /// server, no queue actions.
  final Future<String?> Function(JellyfinSelection item, {bool next})? onAddToQueue;
  final VoidCallback onClose;
  const JellyfinDetailsPanel({
    super.key,
    required this.controller,
    required this.selection,
    required this.onPutUp,
    this.onAddToQueue,
    required this.onClose,
    this.alone = false,
  });

  @override
  State<JellyfinDetailsPanel> createState() => _JellyfinDetailsPanelState();
}

class _JellyfinDetailsPanelState extends State<JellyfinDetailsPanel> {
  String? _seasonId;
  String? _targetId;
  bool _busy = false;
  String? _error;
  DateTime? _lastTap;
  String? _lastTapId;

  BrowseController get _c => widget.controller;
  JellyfinAccounts get _accounts => _c.accounts;
  String get _serverId => widget.selection.serverId;
  JellyfinClient? get _client => _accounts.clientFor(_serverId);

  Future<T> _cached<T>(String key, Future<T> Function(JellyfinClient c) fn) {
    final c = _client;
    if (c == null) return Future.error(const JellyfinException('that Jellyfin server is not linked any more'));
    return _accounts.cached(_serverId, key, () => fn(c));
  }

  Future<_Data> _load() async {
    await _accounts.ensureLoaded();
    final id = widget.selection.itemId;
    final item = await _cached('item:$id', (c) => c.item(id));
    final sid = item.kind == JellyfinItemKind.series ? item.id : item.seriesId;
    if (sid == null || (item.kind != JellyfinItemKind.series && item.kind != JellyfinItemKind.episode)) {
      return (item: item, series: null, seasons: const <JellyfinItem>[], next: null);
    }
    final r = await Future.wait<Object?>([
      item.kind == JellyfinItemKind.series ? Future.value(item) : _cached('item:$sid', (c) => c.item(sid)),
      _cached('seasons:$sid', (c) => c.seasons(sid)),
      _cached('next:$sid', (c) => c.nextUp(seriesId: sid, limit: 1, enableResumable: true))
          .then<List<JellyfinItem>?>((v) => v, onError: (_) => null),
    ]);
    final next = r[2] as List<JellyfinItem>?;
    return (
      item: item,
      series: r[0] as JellyfinItem,
      seasons: r[1] as List<JellyfinItem>,
      next: next == null || next.isEmpty ? null : next.first,
    );
  }

  Future<List<JellyfinItem>> _episodes(String seriesId, String seasonId) =>
      _cached('episodes:$seriesId:$seasonId', (c) => c.episodes(seriesId, seasonId: seasonId));

  /// The actions of this server's items, put-up and queue through the
  /// Library (their errors show here).
  JellyfinItemActions get _actions {
    final add = widget.onAddToQueue;
    return JellyfinItemActions(
      controller: _c,
      serverId: _serverId,
      alone: widget.alone,
      putUp: (item) => widget.onPutUp(JellyfinSelection(_serverId, item.id, item)),
      queue: add == null ? null : (item, {next = false}) => add(JellyfinSelection(_serverId, item.id, item), next: next),
    );
  }

  /// Runs [action] on [item]; the panel waits for what goes to a server and
  /// shows its error under the buttons.
  Future<void> _run(JellyfinItem item, JellyfinAction action) async {
    if (_busy) return;
    final waits = switch (action) {
      JellyfinAction.copyTitle || JellyfinAction.openInJellyfin || JellyfinAction.openShow => false,
      _ => true,
    };
    if (waits) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    final error = await _actions.run(context, item, action);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  /// Right-click on an episode ([context]: its row): its menu; it becomes
  /// the panel's episode.
  Future<void> _episodeMenu(BuildContext context, JellyfinItem e) async {
    setState(() => _targetId = e.id);
    final pick = await showAppMenu<JellyfinAction>(context, items: jellyfinMenuItems(_actions.of(e)));
    if (pick != null && mounted) await _run(e, pick);
  }

  void _tapEpisode(JellyfinItem e) {
    final now = DateTime.now();
    final again = _lastTapId == e.id && _lastTap != null && now.difference(_lastTap!) < doubleClickTime;
    _lastTap = again ? null : now;
    _lastTapId = e.id;
    setState(() => _targetId = e.id);
    if (again) _run(e, JellyfinAction.putUp);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('jf-details'),
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        width: detailsPanelWidth,
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) => Loader<_Data>(
            key: ValueKey('details-${widget.selection.serverId}-${widget.selection.itemId}'),
            version: _c.version,
            load: _load,
            loading: Stack(children: [
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              Positioned(right: 4, top: 4, child: _closeButton()),
            ]),
            builder: (context, d) => _body(context, d),
          ),
        ),
      ),
    );
  }

  Widget _closeButton() => IconButton(
        key: const ValueKey('details-close'),
        tooltip: 'Close',
        onPressed: widget.onClose,
        icon: const Icon(Icons.close),
      );

  /// [i] with the watched marks made here (they show before the reload).
  JellyfinItem _m(JellyfinItem i) => _c.marked(_serverId, i);

  Widget _body(BuildContext context, _Data loaded) {
    final d = (
      item: _m(loaded.item),
      series: loaded.series == null ? null : _m(loaded.series!),
      seasons: [for (final s in loaded.seasons) _m(s)],
      next: loaded.next == null ? null : _m(loaded.next!),
    );
    final series = d.series;
    if (series == null) return _view(context, d, null, null);
    final preferred = d.item.kind == JellyfinItemKind.episode ? d.item : null;
    final baseTarget = preferred ?? d.next;
    final seasons = d.seasons;
    final seasonId = (_seasonId != null && seasons.any((s) => s.id == _seasonId))
        ? _seasonId
        : seasons.any((s) => s.id == baseTarget?.seasonId)
            ? baseTarget!.seasonId
            : (seasons.where((s) => !s.userData.played).firstOrNull ?? seasons.firstOrNull)?.id;
    if (seasonId == null) return _view(context, d, baseTarget, const []);
    return Loader<List<JellyfinItem>>(
      key: ValueKey('details-episodes-$seasonId'),
      version: _c.version,
      load: () => _episodes(series.id, seasonId),
      loading: _view(context, d, baseTarget, null),
      builder: (context, loadedEps) {
        final eps = [for (final e in loadedEps) _m(e)];
        final chosen = _targetId == null
            ? null
            : eps.where((e) => e.id == _targetId).firstOrNull ??
                (baseTarget?.id == _targetId ? baseTarget : null);
        final fresh = baseTarget == null ? null : eps.where((e) => e.id == baseTarget.id).firstOrNull;
        final target = chosen ??
            fresh ??
            baseTarget ??
            eps.where((e) => !e.userData.played).firstOrNull ??
            eps.firstOrNull;
        return _view(context, d, target, eps, seasonId: seasonId);
      },
    );
  }

  /// [episodes] null = loading, empty = none (or not a series).
  Widget _view(BuildContext context, _Data d, JellyfinItem? target, List<JellyfinItem>? episodes,
      {String? seasonId}) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final scheme = theme.colorScheme;
    final client = _client;
    final shown = d.series ?? d.item;
    final isSeries = d.series != null;
    final playable = isSeries ? target : (isPlayable(d.item) ? d.item : null);
    final banner = shown.image(JellyfinImageType.backdrop) ??
        shown.image(JellyfinImageType.thumb) ??
        (d.item.kind == JellyfinItemKind.episode ? d.item.ownImage(JellyfinImageType.primary) : null) ??
        shown.image(JellyfinImageType.primary);
    final eps = shown.recursiveItemCount;
    final meta = [
      if (shown.productionYear != null) '${shown.productionYear}',
      if (isSeries && d.seasons.length > 1) '${d.seasons.length} seasons',
      if (isSeries && eps != null && eps > 0) '$eps episodes',
      if (!isSeries && shown.runTime != null) formatRuntime(shown.runTime!),
      ?shown.officialRating,
      if (shown.communityRating != null) '★ ${shown.communityRating!.toStringAsFixed(1)}',
      if (!isSeries && shown.userData.played) 'Watched',
    ].join(' · ');
    final verb = JellyfinActionText.putUp(alone: widget.alone);
    final label = playable != null && isSeries ? '$verb · ${playable.episodeLabel ?? playable.name}' : verb;
    final left = playable == null ? null : timeLeft(playable);
    // Whose actions the buttons are: a show's (its marks are the whole
    // show's), else the episode picked in the list (or the item).
    final subject = d.item.kind == JellyfinItemKind.series
        ? shown
        : d.item.kind == JellyfinItemKind.episode
            ? (target ?? d.item)
            : d.item;
    // A show's put-up and queue go to the episode picked in the list.
    final to = playable ?? subject;
    final views = _actions.of(subject);
    void run(JellyfinAction a) => _run(
        switch (a) {
          JellyfinAction.putUp || JellyfinAction.addToQueue || JellyfinAction.playNext => to,
          _ => subject,
        },
        a);

    return ListView(
      key: const ValueKey('details-list'),
      padding: EdgeInsets.zero,
      children: [
        SizedBox(
          height: 180,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (client != null)
                JellyfinImage(client: client, image: banner, alignment: Alignment.topCenter, icon: kindIcon(shown))
              else
                ColoredBox(color: scheme.surfaceContainerHighest),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, scheme.surfaceContainerLow],
                    stops: const [0.55, 1],
                  ),
                ),
              ),
              // ⋮: every action of the item, its right-click menu.
              Positioned(
                right: 4,
                top: 4,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  JellyfinMoreButton(key: const ValueKey('details-more'), views: views, onRun: run),
                  _closeButton(),
                ]),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(shown.name, style: t.titleLarge),
              if (meta.isNotEmpty) Text(meta, style: t.bodyMedium?.copyWith(color: Colors.grey)),
              const SizedBox(height: 12),
              JellyfinActionButtons(
                keyPrefix: 'details',
                views: views,
                primary: JellyfinAction.putUp,
                primaryLabel: label,
                icons: JellyfinActionButtons.panelIcons,
                busy: _busy,
                more: false,
                onRun: run,
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(
                  _error!,
                  key: const ValueKey('details-hint'),
                  style: t.bodySmall?.copyWith(color: scheme.error),
                ),
              ],
              if (isSeries && playable != null) ...[
                const SizedBox(height: 10),
                Text(
                  [playable.episodeLabel ?? '', playable.name].where((s) => s.isNotEmpty).join(' · '),
                  style: t.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (left != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  SizedBox(width: 160, child: LinearProgressIndicator(value: progressOf(playable!), minHeight: 3)),
                  const SizedBox(width: 8),
                  Text(left, style: t.bodySmall?.copyWith(color: Colors.grey)),
                ]),
              ],
              if (shown.overview != null) ...[
                const SizedBox(height: 12),
                Text(shown.overview!, style: t.bodyMedium),
              ],
              if (!isSeries) ...[
                const SizedBox(height: 12),
                _Tracks(item: d.item),
              ],
              if (isSeries) ...[
                const SizedBox(height: 16),
                _episodesHeader(context, d, seasonId),
                if (episodes == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (episodes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No episodes', style: TextStyle(color: Colors.grey)),
                  )
                else
                  for (final e in episodes) _episodeRow(context, e, target?.id == e.id),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// "Episodes", the season picker and the season's own actions (its
  /// mark; ⋮: the same as its right-click menu on the show page).
  Widget _episodesHeader(BuildContext context, _Data d, String? seasonId) {
    final seasons = d.seasons;
    final season = seasons.where((s) => s.id == seasonId).firstOrNull;
    return Row(
      children: [
        const Expanded(child: Text('Episodes', style: TextStyle(fontWeight: FontWeight.w600))),
        if (seasons.length > 1)
          Flexible(
            child: AppSelect<String?>(
              key: const ValueKey('details-season'),
              value: seasonId,
              items: [for (final s in seasons) (s.id, s.name)],
              onChanged: (id) => setState(() => _seasonId = id),
            ),
          ),
        if (season != null)
          JellyfinActionButtons(
            keyPrefix: 'details-season',
            views: _actions.of(season),
            icons: const {JellyfinAction.markWatched, JellyfinAction.markUnwatched},
            busy: _busy,
            onRun: (a) => _run(season, a),
          ),
      ],
    );
  }

  Widget _episodeRow(BuildContext context, JellyfinItem e, bool isTarget) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final client = _client;
    final sub = e.userData.played ? 'watched' : timeLeft(e) ?? (e.runTime == null ? '' : formatRuntime(e.runTime!));
    return Material(
      color: isTarget ? scheme.primary.withValues(alpha: 0.10) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      // The row's own context: its menu opens at the row.
      child: Builder(builder: (context) => InkWell(
        key: ValueKey('details-episode-${e.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _tapEpisode(e),
        onSecondaryTap: () => _episodeMenu(context, e),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 64,
                  height: 36,
                  child: client == null
                      ? ColoredBox(color: scheme.surfaceContainerHighest)
                      : JellyfinImage(
                          client: client,
                          image: e.ownImage(JellyfinImageType.primary) ?? e.image(JellyfinImageType.thumb),
                          icon: Icons.tv_outlined,
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.indexNumber == null ? e.name : 'E${e.indexNumber} · ${e.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyMedium?.copyWith(
                        color: isTarget ? scheme.primary : e.userData.played ? Colors.grey : null,
                        fontWeight: isTarget ? FontWeight.w600 : null,
                      ),
                    ),
                    if (sub.isNotEmpty) Text(sub, style: t.bodySmall?.copyWith(color: Colors.grey)),
                  ],
                ),
              ),
              AnimatedOpacity(
                opacity: isTarget ? 1 : 0,
                duration: easeTime,
                child: Icon(Icons.play_circle, color: scheme.primary),
              ),
            ],
          ),
        ),
      )),
    );
  }
}

/// What the file holds, one line per track kind.
class _Tracks extends StatelessWidget {
  final JellyfinItem item;
  const _Tracks({required this.item});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final source = item.mediaSources.firstOrNull;
    final streams = source?.mediaStreams.isNotEmpty == true ? source!.mediaStreams : item.mediaStreams;
    if (streams.isEmpty) return const SizedBox.shrink();
    String names(JellyfinStreamType type) => streams
        .where((s) => s.type == type)
        .map((s) => s.displayTitle ?? [s.language, s.codec].whereType<String>().join(' '))
        .join('  ·  ');
    final rows = [
      ('Video', names(JellyfinStreamType.video)),
      ('Audio', names(JellyfinStreamType.audio)),
      ('Subtitles', names(JellyfinStreamType.subtitle)),
      if (source?.container != null || source?.size != null)
        ('File', [
          ?source?.container,
          if (source?.size != null) '${(source!.size! / (1 << 30)).toStringAsFixed(2)} GB',
        ].join(' · ')),
    ].where((r) => r.$2.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 76, child: Text(label, style: t.bodySmall?.copyWith(color: Colors.grey))),
                Expanded(child: Text(value, style: t.bodySmall)),
              ],
            ),
          ),
      ],
    );
  }
}
