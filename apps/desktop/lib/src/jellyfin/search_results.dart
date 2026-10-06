import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'browse_scope.dart';
import 'cards.dart';

/// Search results grouped by kind: shows and movies as posters, episodes
/// as thumbnails, each a grid that fills the width.
class JellyfinSearchResults extends StatelessWidget {
  final String term;
  const JellyfinSearchResults({super.key, required this.term});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    return Loader<List<JellyfinItem>>(
      key: ValueKey('search-$term-${scope.account.serverId}'),
      load: () => scope.load('search:$term', (c) => c.search(term, limit: 80)),
      builder: (context, items) {
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text('Nothing found for "$term"',
                  key: const ValueKey('search-empty'),
                  style: const TextStyle(color: Colors.grey)),
            ),
          );
        }
        final groups = [
          ('Shows', CardShape.poster, items.where((i) => i.kind == JellyfinItemKind.series).toList()),
          ('Movies', CardShape.poster, items.where((i) => i.kind == JellyfinItemKind.movie).toList()),
          ('Episodes', CardShape.thumb, items.where((i) => i.kind == JellyfinItemKind.episode).toList()),
          (
            'Other',
            CardShape.poster,
            items
                .where((i) => !const [
                      JellyfinItemKind.series,
                      JellyfinItemKind.movie,
                      JellyfinItemKind.episode
                    ].contains(i.kind))
                .toList()
          ),
        ].where((g) => g.$3.isNotEmpty);
        return CustomScrollView(
          key: const ValueKey('search-results'),
          slivers: [
            for (final (title, shape, list) in groups) ...[
              SliverToBoxAdapter(child: SectionHeader(title, count: '${list.length}')),
              SliverGrid(
                gridDelegate: CardGridDelegate(shape),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => MediaCard(
                    item: list[i],
                    shape: shape,
                    seriesFirst: shape == CardShape.thumb,
                  ),
                  childCount: list.length,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],
          ],
        );
      },
    );
  }
}
