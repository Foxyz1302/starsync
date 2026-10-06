import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'browse_scope.dart';
import 'cards.dart';

/// Libraries that hold videos; music, books, photos and playlists are left
/// out of the browser.
bool isVideoLibrary(JellyfinItem view) => switch (view.collectionType) {
      'movies' || 'tvshows' || 'homevideos' || 'boxsets' || 'mixed' || 'musicvideos' || null => true,
      _ => false,
    };

IconData libraryIcon(JellyfinItem view) => switch (view.collectionType) {
      'movies' => Icons.movie_outlined,
      'tvshows' => Icons.live_tv_outlined,
      'boxsets' => Icons.collections_bookmark_outlined,
      'homevideos' => Icons.videocam_outlined,
      _ => Icons.folder_outlined,
    };

/// Start page: library shortcuts, then Continue watching, Next up and the
/// latest additions of each library. Each row loads on its own, so a slow
/// library does not hold up the rest.
class JellyfinHomePage extends StatelessWidget {
  const JellyfinHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    return Loader<List<JellyfinItem>>(
      key: ValueKey('views-${scope.account.serverId}'),
      load: () => scope.load('views', (c) => c.userViews()),
      builder: (context, all) {
        final views = all.where(isVideoLibrary).toList();
        return ListView(
          key: const PageStorageKey('jf-home'),
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
          children: [
            _LibraryStrip(views: views),
            const SizedBox(height: 20),
            _Section(
              key: const ValueKey('row-resume'),
              title: 'Continue watching',
              shape: CardShape.thumb,
              seriesFirst: true,
              load: () => scope.load('resume', (c) => c.resume(limit: 30)),
            ),
            _Section(
              key: const ValueKey('row-nextup'),
              title: 'Next up',
              shape: CardShape.thumb,
              seriesFirst: true,
              load: () => scope.load('nextup', (c) => c.nextUp(limit: 30)),
            ),
            for (final v in views)
              _Section(
                key: ValueKey('row-latest-${v.id}'),
                title: 'Latest in ${v.name}',
                shape: v.collectionType == 'homevideos' ? CardShape.thumb : CardShape.poster,
                load: () => scope.load('latest:${v.id}', (c) => c.latest(v.id, limit: 30)),
                trailing: TextButton(
                  onPressed: () => scope.onOpen(LibraryRoute(v)),
                  child: const Text('Show all'),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LibraryStrip extends StatelessWidget {
  final List<JellyfinItem> views;
  const _LibraryStrip({required this.views});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    if (views.isEmpty) {
      return const Text('No video libraries on this server for your user.',
          style: TextStyle(color: Colors.grey));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final v in views)
          ActionChip(
            key: ValueKey('library-${v.id}'),
            avatar: Icon(libraryIcon(v), size: 18),
            label: Text(v.name),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onPressed: () => scope.onOpen(LibraryRoute(v)),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final CardShape shape;
  final bool seriesFirst;
  final Future<List<JellyfinItem>> Function() load;
  final Widget? trailing;
  const _Section({
    super.key,
    required this.title,
    required this.shape,
    required this.load,
    this.seriesFirst = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Loader<List<JellyfinItem>>(
      load: load,
      showError: false,
      loading: _RowSkeleton(title: title, shape: shape),
      builder: (context, items) => items.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: MediaRow(
                title: title,
                items: items,
                shape: shape,
                seriesFirst: seriesFirst,
                trailing: trailing,
              ),
            ),
    );
  }
}

class _RowSkeleton extends StatelessWidget {
  final String title;
  final CardShape shape;
  const _RowSkeleton({required this.title, required this.shape});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title),
          LayoutBuilder(builder: (context, box) {
            final fit = fitColumns(box.maxWidth, shape.minWidth);
            return Row(
              children: [
                for (var i = 0; i < fit.cols; i++) ...[
                  if (i > 0) const SizedBox(width: cardGap),
                  Expanded(child: SkeletonCard(shape: shape)),
                ],
              ],
            );
          }),
        ],
      ),
    );
  }
}

class SkeletonCard extends StatelessWidget {
  final CardShape shape;
  const SkeletonCard({super.key, required this.shape});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: shape.aspect,
          child: DecoratedBox(
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8))),
        ),
        const SizedBox(height: cardTextHeight),
      ],
    );
  }
}
