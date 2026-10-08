import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../state/settings.dart';
import 'browse_scope.dart';
import 'cards.dart';
import 'home_rows.dart';

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

/// The video libraries of the scope's server (cached).
Future<List<JellyfinItem>> videoLibraries(BrowseScope scope) =>
    scope.load('views', (c) => c.userViews()).then((all) => all.where(isVideoLibrary).toList());

/// Start page: (library shortcuts,) one Continue row (resume points and
/// next up merged per series, see [mergeContinue]), then the newest
/// additions of each library as series cards ([latestCards]). Each row
/// loads on its own, so a slow library does not hold up the rest; rows
/// reload when watched state changes ([BrowseController.dataChanged]).
class JellyfinHomePage extends StatelessWidget {
  const JellyfinHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    return Loader<List<JellyfinItem>>(
      key: ValueKey('views-${scope.account.serverId}'),
      load: () => videoLibraries(scope),
      builder: (context, views) => ListenableBuilder(
        listenable: scope.controller,
        builder: (context, _) {
          final v = scope.controller.version;
          return ListView(
            key: const PageStorageKey('jf-home'),
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
            children: [
              if (scope.libraryStrip) ...[
                LibraryStrip(views: views),
                const SizedBox(height: 20),
              ] else if (views.isEmpty)
                const _NoLibraries(),
              _ContinueRow(version: v),
              for (final view in views) _LatestRow(key: ValueKey('row-latest-${view.id}'), view: view, version: v),
            ],
          );
        },
      ),
    );
  }
}

class _NoLibraries extends StatelessWidget {
  const _NoLibraries();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(bottom: 20),
        child: Text('No video libraries on this server for your user.', style: TextStyle(color: Colors.grey)),
      );
}

/// The libraries as chips; a click opens one.
class LibraryStrip extends StatelessWidget {
  final List<JellyfinItem> views;
  const LibraryStrip({super.key, required this.views});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    if (views.isEmpty) return const _NoLibraries();
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
            onPressed: () => scope.controller.openTop(LibraryRoute(v)),
          ),
      ],
    );
  }
}

class _ContinueRow extends StatelessWidget {
  final int version;
  const _ContinueRow({required this.version});

  static const title = 'Continue';

  Future<List<JellyfinItem>> _load(BrowseScope scope) async {
    final lists = await Future.wait([
      scope.load('resume', (c) => c.resume(limit: 40)),
      scope.load('nextup', (c) => c.nextUp(limit: 40)),
      // Only for ordering: a failure leaves the row as it is.
      scope
          .load('played', (c) => c.recentlyPlayed(limit: 150))
          .catchError((Object _) => const <JellyfinItem>[]),
    ]);
    return mergeContinue(
      resume: lists[0],
      nextUp: lists[1],
      recentlyPlayed: lists[2],
      dismissed: scope.accounts.continueDismissed(scope.account.serverId),
      now: scope.controller.now(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    return Loader<List<JellyfinItem>>(
      version: version,
      load: () => _load(scope),
      showError: false,
      loading: const _RowSkeleton(title: title, shape: CardShape.thumb),
      builder: (context, items) {
        scope.controller.continueKeys = {for (final i in items) continueKey(i)};
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          key: const ValueKey('row-continue'),
          padding: const EdgeInsets.only(bottom: 24),
          child: MediaRow(
            title: title,
            entries: cardEntries(items),
            shape: CardShape.thumb,
            seriesFirst: true,
          ),
        );
      },
    );
  }
}

class _LatestRow extends StatelessWidget {
  final JellyfinItem view;
  final int version;
  const _LatestRow({super.key, required this.view, required this.version});

  @override
  Widget build(BuildContext context) {
    final scope = BrowseScope.of(context);
    final title = 'Latest in ${view.name}';
    final shape = view.collectionType == 'homevideos' ? CardShape.thumb : CardShape.poster;
    return Loader<List<JellyfinItem>>(
      version: version,
      load: () => scope.load('latest:${view.id}', (c) => c.latest(view.id, limit: 100, groupItems: false)),
      showError: false,
      loading: _RowSkeleton(title: title, shape: shape),
      builder: (context, items) => SignalBuilder(builder: (context) {
        final hide = AppSettings.instance.hideReReleases.value;
        final cards = latestCards(items, hideReReleases: hide);
        if (cards.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: MediaRow(
            key: ValueKey('latest-${view.id}'),
            title: title,
            entries: [for (final c in cards) (item: c.item, display: c.display, subtitle: c.subtitle)],
            shape: shape,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: ValueKey('show-all-${view.id}'),
                  // Newest first, like the row.
                  onPressed: () => scope.onOpen(LibraryRoute(view, sort: 'added')),
                  child: const Text('Show all'),
                ),
                PopupMenuButton<void>(
                  key: ValueKey('latest-menu-${view.id}'),
                  tooltip: 'Row options',
                  icon: const Icon(Icons.more_vert, size: 18),
                  itemBuilder: (context) => [
                    CheckedPopupMenuItem(
                      key: const ValueKey('hide-rereleases'),
                      checked: hide,
                      onTap: () => AppSettings.instance.setHideReReleases(!hide),
                      child: const Text('Hide re-releases in Latest'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }),
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
