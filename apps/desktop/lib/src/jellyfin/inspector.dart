import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'browse_scope.dart';
import 'format.dart';
import 'images.dart';

/// Side pane on wide windows: details of whatever card is hovered or
/// focused, so browsing needs no extra clicks. Pick / Open act on it.
class JellyfinInspector extends StatelessWidget {
  final ValueListenable<JellyfinItem?> item;
  const JellyfinInspector({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('jf-inspector'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: ValueListenableBuilder<JellyfinItem?>(
        valueListenable: item,
        builder: (context, it, _) => it == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Hover or focus a title to see its details here.',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                ),
              )
            : _Body(item: it),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final JellyfinItem item;
  const _Body({required this.item});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    final t = Theme.of(context).textTheme;
    final playable = isPlayable(item);
    final selected = scope.selectedItemId == item.id;
    final episode = item.kind == JellyfinItemKind.episode;
    final art = episode
        ? item.ownImage(JellyfinImageType.primary) ?? item.image(JellyfinImageType.backdrop)
        : item.image(JellyfinImageType.backdrop) ?? item.image(JellyfinImageType.thumb);
    final meta = [
      if (item.productionYear != null) '${item.productionYear}',
      if (playable && item.runTime != null) formatRuntime(item.runTime!),
      if (item.officialRating != null) item.officialRating!,
      if (item.communityRating != null) '★ ${item.communityRating!.toStringAsFixed(1)}',
      if (!playable && (item.userData.unplayedItemCount ?? 0) > 0)
        '${item.userData.unplayedItemCount} unwatched',
      if (item.userData.played) 'Watched',
    ].join(' · ');
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: JellyfinImage(client: scope.client, image: art),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (episode && item.seriesName != null)
                Text(item.seriesName!, style: t.labelLarge?.copyWith(color: Colors.grey)),
              Text(
                episode && item.episodeLabel != null ? '${item.episodeLabel}  ${item.name}' : item.name,
                style: t.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(meta, style: t.bodySmall?.copyWith(color: Colors.grey)),
              if (timeLeft(item) != null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progressOf(item), minHeight: 3),
                const SizedBox(height: 4),
                Text(timeLeft(item)!, style: t.bodySmall),
              ],
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (playable)
                  FilledButton.icon(
                    onPressed: () => scope.onPick(item),
                    icon: Icon(selected ? Icons.check : Icons.play_arrow, size: 18),
                    label: Text(selected ? 'Picked' : 'Pick'),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: () => scope.activate(item),
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text('Open'),
                  ),
                if (playable)
                  OutlinedButton(
                    onPressed: () => scope.onOpen(DetailRoute(item)),
                    child: const Text('Details'),
                  ),
                if (episode && item.seriesId != null)
                  OutlinedButton(
                    onPressed: () => scope.openSeriesOf(item),
                    child: const Text('Series'),
                  ),
              ]),
              if (item.overview != null) ...[
                const SizedBox(height: 12),
                Text(item.overview!, style: t.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
