import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'browse_scope.dart';
import 'cards.dart' show doubleClickTime;
import 'format.dart';
import 'images.dart';

/// Series page: backdrop + logo header with overview and the smart "next
/// unwatched" button, a season selector and the season's episodes as dense
/// rows (several columns on wide windows).
class JellyfinSeriesPage extends StatefulWidget {
  final JellyfinItem series;
  final String? seasonId;
  const JellyfinSeriesPage({super.key, required this.series, this.seasonId});

  @override
  State<JellyfinSeriesPage> createState() => _JellyfinSeriesPageState();
}

typedef _SeriesData = ({JellyfinItem series, List<JellyfinItem> seasons, JellyfinItem? next});

class _JellyfinSeriesPageState extends State<JellyfinSeriesPage> {
  String? _seasonId;

  @override
  void initState() {
    super.initState();
    _seasonId = widget.seasonId;
  }

  Future<_SeriesData> _load(BrowseScope scope) async {
    final id = widget.series.id;
    final results = await Future.wait<Object?>([
      scope.load('item:$id', (c) => c.item(id)),
      scope.load('seasons:$id', (c) => c.seasons(id)),
      scope
          .load('next:$id', (c) => c.nextUp(seriesId: id, limit: 1, enableResumable: true))
          .then<List<JellyfinItem>?>((v) => v, onError: (_) => null),
    ]);
    final next = results[2] as List<JellyfinItem>?;
    return (
      series: results[0] as JellyfinItem,
      seasons: results[1] as List<JellyfinItem>,
      next: next == null || next.isEmpty ? null : next.first,
    );
  }

  /// Season to show first: the one holding the next episode, else the first
  /// with something unwatched, else the first.
  String? _defaultSeason(_SeriesData d) {
    if (d.seasons.isEmpty) return null;
    final nextSeason = d.next?.seasonId;
    if (nextSeason != null && d.seasons.any((s) => s.id == nextSeason)) return nextSeason;
    return (d.seasons.where((s) => !s.userData.played).firstOrNull ?? d.seasons.first).id;
  }

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    return Loader<_SeriesData>(
      key: ValueKey('series-${widget.series.id}-${scope.account.serverId}'),
      version: scope.controller.version,
      load: () => _load(scope),
      builder: (context, d) {
        final seasonId = (_seasonId != null && d.seasons.any((s) => s.id == _seasonId))
            ? _seasonId
            : _defaultSeason(d);
        return CustomScrollView(
          key: PageStorageKey('series-${widget.series.id}'),
          slivers: [
            SliverToBoxAdapter(child: _SeriesHeader(data: d)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in d.seasons)
                      ChoiceChip(
                        key: ValueKey('season-${s.id}'),
                        label: Text(s.name),
                        avatar: s.userData.played
                            ? const Icon(Icons.check, size: 16)
                            : null,
                        showCheckmark: false,
                        selected: s.id == seasonId,
                        onSelected: (_) => setState(() => _seasonId = s.id),
                        tooltip: s.userData.unplayedItemCount != null
                            ? '${s.userData.unplayedItemCount} unwatched'
                            : null,
                      ),
                  ],
                ),
              ),
            ),
            if (seasonId != null)
              _EpisodeList(
                key: ValueKey('episodes-$seasonId'),
                seriesId: widget.series.id,
                seasonId: seasonId,
                version: scope.controller.version,
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

class _SeriesHeader extends StatefulWidget {
  final _SeriesData data;
  const _SeriesHeader({required this.data});

  @override
  State<_SeriesHeader> createState() => _SeriesHeaderState();
}

class _SeriesHeaderState extends State<_SeriesHeader> {
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final s = widget.data.series;
    final next = widget.data.next;
    final logo = s.image(JellyfinImageType.logo);
    final meta = [
      if (s.productionYear != null) '${s.productionYear}',
      if (s.officialRating != null) s.officialRating!,
      if (s.communityRating != null) '★ ${s.communityRating!.toStringAsFixed(1)}',
      if (widget.data.seasons.isNotEmpty)
        '${widget.data.seasons.length} ${widget.data.seasons.length == 1 ? 'season' : 'seasons'}',
      if ((s.userData.unplayedItemCount ?? 0) > 0) '${s.userData.unplayedItemCount} unwatched',
    ].join(' · ');

    final String nextLabel;
    if (next == null) {
      nextLabel = 'All watched';
    } else if (next.userData.isResumable) {
      nextLabel = 'Resume ${next.episodeLabel ?? next.name}';
    } else {
      nextLabel = 'Next up: ${next.episodeLabel ?? ''} ${next.name}'.trim();
    }
    final selectedNext = next != null && scope.selectedItemId == next.id;

    return LayoutBuilder(builder: (context, box) {
      final h = (box.maxWidth * 0.28).clamp(220.0, 380.0);
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              JellyfinImage(
                client: scope.client,
                image: s.image(JellyfinImageType.backdrop),
                alignment: Alignment.topCenter,
                icon: Icons.live_tv_outlined,
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      theme.colorScheme.surface.withValues(alpha: 0.96),
                      theme.colorScheme.surface.withValues(alpha: 0.75),
                      theme.colorScheme.surface.withValues(alpha: 0.1),
                    ],
                    stops: const [0, 0.45, 1],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (logo != null)
                            SizedBox(
                              height: 72,
                              width: 320,
                              child: JellyfinImage(
                                client: scope.client,
                                image: logo,
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                                placeholder: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(s.name, style: t.headlineMedium)),
                              ),
                            )
                          else
                            Text(s.name, style: t.headlineMedium),
                          const SizedBox(height: 8),
                          Text(meta, style: t.bodyMedium?.copyWith(color: Colors.grey)),
                          if (s.overview != null) ...[
                            const SizedBox(height: 8),
                            GestureDetector(
                              onTap: () => setState(() => _more = !_more),
                              child: Text(s.overview!,
                                  maxLines: _more ? null : 3,
                                  overflow: _more ? null : TextOverflow.ellipsis,
                                  style: t.bodyMedium),
                            ),
                          ],
                          const SizedBox(height: 14),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            FilledButton.icon(
                              key: const ValueKey('series-next'),
                              onPressed: next == null ? null : () => scope.onSelect(next),
                              icon: Icon(selectedNext ? Icons.check : Icons.play_arrow),
                              label: Text(nextLabel, overflow: TextOverflow.ellipsis),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// Episodes of one season as a lazy grid of rows: one column, more past
/// ~760 px each.
class _EpisodeList extends StatefulWidget {
  final String seriesId;
  final String seasonId;
  final int version;
  const _EpisodeList(
      {super.key, required this.seriesId, required this.seasonId, required this.version});

  @override
  State<_EpisodeList> createState() => _EpisodeListState();
}

class _EpisodeListState extends State<_EpisodeList> {
  Future<List<JellyfinItem>>? _future;
  List<JellyfinItem>? _last;

  @override
  void didUpdateWidget(_EpisodeList old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _future = null;
  }

  void _load(BrowseScope scope) => _future = scope.load('episodes:${widget.seriesId}:${widget.seasonId}',
      (c) => c.episodes(widget.seriesId, seasonId: widget.seasonId));

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    if (_future == null) _load(scope);
    return FutureBuilder<List<JellyfinItem>>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return SliverToBoxAdapter(
              child: LoadError(error: snap.error!, onRetry: () => setState(() => _load(scope))));
        }
        final eps = snap.data ?? _last;
        if (snap.data != null) _last = snap.data;
        if (eps == null) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        if (eps.isEmpty) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No episodes', style: TextStyle(color: Colors.grey)),
            ),
          );
        }
        return SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 760,
            mainAxisExtent: episodeTileHeight,
            crossAxisSpacing: 12,
            mainAxisSpacing: 8,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => EpisodeTile(episode: eps[i]),
            childCount: eps.length,
          ),
        );
      },
    );
  }
}

const episodeTileHeight = 6 + 176 * 9 / 16 + 6 + 2;

/// One episode: thumbnail with progress, number + title, runtime / air
/// date, two lines of overview. Click selects it (details panel), a second
/// click soon after puts it up.
class EpisodeTile extends StatefulWidget {
  final JellyfinItem episode;
  const EpisodeTile({super.key, required this.episode});

  @override
  State<EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<EpisodeTile> {
  bool _focus = false;
  bool _hover = false;
  DateTime? _lastTap;

  void _tap(BrowseScope scope) {
    final now = DateTime.now();
    final last = _lastTap;
    _lastTap = now;
    if (last != null && now.difference(last) < doubleClickTime) {
      _lastTap = null;
      scope.onPutUp(widget.episode);
    } else {
      scope.onSelect(widget.episode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = theme.textTheme;
    final e = widget.episode;
    final selected = scope.selectedItemId == e.id;
    final played = e.userData.played;
    final progress = progressOf(e);
    final meta = [
      ?e.episodeLabel,
      ?timeLeft(e),
      if (timeLeft(e) == null && e.runTime != null) formatRuntime(e.runTime!),
      if (e.premiereDate != null)
        '${e.premiereDate!.year}-${e.premiereDate!.month.toString().padLeft(2, '0')}-${e.premiereDate!.day.toString().padLeft(2, '0')}',
    ].join(' · ');
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.35)
          : _hover || _focus
              ? scheme.surfaceContainerHigh
              : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color: selected ? scheme.primary : _focus ? scheme.onSurface : Colors.transparent,
            width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('episode-${e.id}'),
        focusColor: Colors.transparent,
        onTap: () => _tap(scope),
        onHover: (h) => setState(() => _hover = h),
        onFocusChange: (f) => setState(() => _focus = f),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 176,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(fit: StackFit.expand, children: [
                      JellyfinImage(
                        client: scope.client,
                        image: e.ownImage(JellyfinImageType.primary) ??
                            e.image(JellyfinImageType.thumb) ??
                            e.image(JellyfinImageType.backdrop),
                        icon: Icons.tv_outlined,
                      ),
                      if (progress > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                              value: progress, minHeight: 3, backgroundColor: Colors.black54),
                        ),
                      if (played || selected)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: CircleAvatar(
                            radius: 10,
                            backgroundColor: selected ? scheme.primary : const Color(0xCC1B5E20),
                            child: Icon(Icons.check,
                                size: 13, color: selected ? scheme.onPrimary : Colors.white),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.indexNumber == null ? e.name : '${e.indexNumber}. ${e.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall?.copyWith(
                        color: selected ? scheme.primary : played ? Colors.grey : null,
                      ),
                    ),
                    Text(meta, style: t.bodySmall?.copyWith(color: Colors.grey)),
                    if (e.overview != null) ...[
                      const SizedBox(height: 4),
                      Text(e.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
