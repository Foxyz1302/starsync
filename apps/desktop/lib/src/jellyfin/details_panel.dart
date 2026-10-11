import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import '../shell/motion.dart';
import '../widgets/app_menu.dart';
import '../widgets/copy_open.dart';
import 'accounts.dart';
import 'browse_scope.dart';
import 'cards.dart' show doubleClickTime, kindIcon;
import 'format.dart';
import 'home_rows.dart' show continueKey;
import 'images.dart';

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
/// [solo]), mark watched / unwatched, remove from Continue, overview and,
/// for a series or an episode, the episode list (click picks which
/// episode goes up, double-click puts it up). Reloads when the
/// [controller]'s data version moves.
class JellyfinDetailsPanel extends StatefulWidget {
  final BrowseController controller;
  final JellyfinSelection selection;
  /// Nobody else watches (offline or solo): the button says Play.
  final bool solo;
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
    this.solo = false,
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

  Future<void> _putUp(JellyfinItem target) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onPutUp(JellyfinSelection(_serverId, target.id, target));
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _queue(JellyfinItem target, {bool next = false}) async {
    final add = widget.onAddToQueue;
    if (add == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await add(JellyfinSelection(_serverId, target.id, target), next: next);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  /// Right-click on an episode ([context]: its row): Put it up, Add to
  /// queue, Play next (in a server), Copy title, Open in Jellyfin.
  Future<void> _episodeMenu(BuildContext context, JellyfinItem e) async {
    final queue = widget.onAddToQueue != null;
    if (queue) setState(() => _targetId = e.id);
    final client = _client;
    final pick = await showAppMenu<int>(context, items: [
      if (queue) ...[
        AppMenuItem(value: 0, label: widget.solo ? 'Play' : 'Put it up'),
        const AppMenuItem(value: 1, label: 'Add to queue'),
        const AppMenuItem(value: 2, label: 'Play next'),
      ],
      const AppMenuItem(value: 3, label: ReuseText.copyTitle),
      if (client != null) const AppMenuItem(value: 4, label: ReuseText.openInJellyfin),
    ]);
    switch (pick) {
      case 0:
        await _putUp(e);
      case 1:
        await _queue(e);
      case 2:
        await _queue(e, next: true);
      case 3:
        await copyToClipboard(jellyfinCopyTitle(e), done: 'Title copied');
      case 4:
        await openLink(jellyfinWebUrl(client!.baseUrl, e.id, serverId: _serverId));
    }
  }

  /// Runs a watched-state change, then lets every row reload.
  Future<void> _change(Future<void> Function(JellyfinClient c) action) async {
    final c = _client;
    if (c == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await action(c);
    } on JellyfinException catch (e) {
      if (e.isUnauthorized) _accounts.markExpired(_serverId);
      error = e.isUnauthorized ? 'Jellyfin sign-in expired' : e.message;
    } catch (e) {
      error = '$e';
    }
    _c.dataChanged();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  void _toggleWatched(JellyfinItem t) =>
      _change((c) => t.userData.played ? c.markUnplayed(t.id) : c.markPlayed(t.id));

  void _removeFromContinue(JellyfinItem t) => _change((c) async {
        if (t.userData.isResumable) await c.clearResumePosition(t.id);
        await _accounts.dismissContinue(_serverId, continueKey(t));
      });

  void _tapEpisode(JellyfinItem e) {
    final now = DateTime.now();
    final again = _lastTapId == e.id && _lastTap != null && now.difference(_lastTap!) < doubleClickTime;
    _lastTap = again ? null : now;
    _lastTapId = e.id;
    setState(() => _targetId = e.id);
    if (again) _putUp(e);
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

  Widget _body(BuildContext context, _Data d) {
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
      builder: (context, eps) {
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
    final verb = widget.solo ? 'Play' : 'Put it up';
    final label = playable != null && isSeries ? '$verb · ${playable.episodeLabel ?? playable.name}' : verb;
    final inContinue = playable != null &&
        (playable.userData.isResumable || _c.continueKeys.contains(continueKey(playable)));
    final left = playable == null ? null : timeLeft(playable);

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
              Positioned(right: 4, top: 4, child: _closeButton()),
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
              Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('details-put-up'),
                    onPressed: playable == null || _busy ? null : () => _putUp(playable),
                    icon: _busy
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.play_arrow),
                    label: Text(label, overflow: TextOverflow.ellipsis),
                  ),
                  if (playable != null && widget.onAddToQueue != null)
                    GestureDetector(
                      onSecondaryTap: _busy ? null : () => _queue(playable, next: true),
                      child: IconButton(
                        key: const ValueKey('details-add-queue'),
                        onPressed: _busy ? null : () => _queue(playable),
                        tooltip: 'Add to queue (right-click: play next)',
                        icon: const Icon(Icons.playlist_add_rounded),
                      ),
                    ),
                  if (playable != null)
                    IconButton(
                      key: const ValueKey('details-watched'),
                      onPressed: _busy ? null : () => _toggleWatched(playable),
                      tooltip: playable.userData.played ? 'Mark unwatched' : 'Mark watched',
                      icon: Icon(playable.userData.played ? Icons.check_circle : Icons.check_circle_outline),
                    ),
                  if (inContinue)
                    IconButton(
                      key: const ValueKey('details-remove-continue'),
                      onPressed: _busy ? null : () => _removeFromContinue(playable),
                      tooltip: 'Remove from Continue',
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  if (isSeries)
                    IconButton(
                      key: const ValueKey('details-open-series'),
                      tooltip: 'Open the series page',
                      onPressed: () => _c.open(SeriesRoute(d.series!, seasonId: seasonId)),
                      icon: const Icon(Icons.open_in_new),
                    ),
                  if (client != null)
                    IconButton(
                      key: const ValueKey('details-open-jellyfin'),
                      tooltip: ReuseText.openInJellyfin,
                      onPressed: () => openLink(jellyfinWebUrl(client.baseUrl, shown.id, serverId: _serverId)),
                      icon: const Icon(Icons.open_in_browser_rounded),
                    ),
                ],
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

  Widget _episodesHeader(BuildContext context, _Data d, String? seasonId) {
    final seasons = d.seasons;
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
