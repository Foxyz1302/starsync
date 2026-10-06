import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'browse_scope.dart';
import 'format.dart';
import 'images.dart';

/// Movie / episode detail: art, title, meta, overview, the pick button and
/// what is in the file (video, audio and subtitle tracks).
class JellyfinDetailPage extends StatelessWidget {
  final JellyfinItem item;
  const JellyfinDetailPage({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    return Loader<JellyfinItem>(
      key: ValueKey('detail-${item.id}-${scope.account.serverId}'),
      load: () => scope.load('item:${item.id}', (c) => c.item(item.id)),
      builder: (context, full) => _Detail(item: full),
    );
  }
}

class _Detail extends StatelessWidget {
  final JellyfinItem item;
  const _Detail({required this.item});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final episode = item.kind == JellyfinItemKind.episode;
    final selected = scope.selectedItemId == item.id;
    final meta = [
      ?item.episodeLabel,
      if (item.productionYear != null) '${item.productionYear}',
      if (item.runTime != null) formatRuntime(item.runTime!),
      ?timeLeft(item),
      if (item.officialRating != null) item.officialRating!,
      if (item.communityRating != null) '★ ${item.communityRating!.toStringAsFixed(1)}',
      if (item.userData.played) 'Watched',
    ].join(' · ');

    final art = episode
        ? AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: JellyfinImage(
                  client: scope.client,
                  image: item.ownImage(JellyfinImageType.primary) ??
                      item.image(JellyfinImageType.backdrop),
                  icon: Icons.tv_outlined),
            ),
          )
        : AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: JellyfinImage(
                  client: scope.client, image: item.image(JellyfinImageType.primary)),
            ),
          );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (episode && item.seriesName != null)
          TextButton.icon(
            key: const ValueKey('detail-series'),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => scope.openSeriesOf(item),
            icon: const Icon(Icons.live_tv_outlined, size: 18),
            label: Text(item.seriesName!, style: t.titleMedium),
          ),
        SelectableText(item.name, style: t.headlineSmall),
        const SizedBox(height: 6),
        Text(meta, style: t.bodyMedium?.copyWith(color: Colors.grey)),
        if (progressOf(item) > 0) ...[
          const SizedBox(height: 8),
          SizedBox(
              width: 240,
              child: LinearProgressIndicator(value: progressOf(item), minHeight: 4)),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('detail-pick'),
          onPressed: () => scope.onPick(item),
          icon: Icon(selected ? Icons.check : Icons.play_arrow),
          label: Text(selected ? 'Picked' : 'Pick to watch'),
        ),
        if (item.overview != null) ...[
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SelectableText(item.overview!, style: t.bodyMedium),
          ),
        ],
        const SizedBox(height: 16),
        _Tracks(item: item),
      ],
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 760;
        final artWidth = episode ? (box.maxWidth * 0.32).clamp(280.0, 480.0) : 240.0;
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: episode ? 320 : 180, child: art)),
              const SizedBox(height: 16),
              info,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: artWidth, child: art),
            const SizedBox(width: 24),
            Expanded(child: info),
          ],
        );
      }),
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
                SizedBox(
                    width: 84,
                    child: Text(label, style: t.bodySmall?.copyWith(color: Colors.grey))),
                Expanded(child: Text(value, style: t.bodySmall)),
              ],
            ),
          ),
      ],
    );
  }
}
