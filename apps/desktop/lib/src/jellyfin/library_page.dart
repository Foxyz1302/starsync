import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'browse_scope.dart';
import 'cards.dart';
import 'home_page.dart' show SkeletonCard;

enum LibrarySort {
  name('Name', JellyfinSortBy.sortName, false),
  added('Date added', JellyfinSortBy.dateCreated, true),
  premiere('Release date', JellyfinSortBy.premiereDate, true),
  rating('Rating', JellyfinSortBy.communityRating, true),
  random('Random', JellyfinSortBy.random, false);

  final String label;
  final String apiName;
  /// Natural direction: newest / best first.
  final bool descending;
  const LibrarySort(this.label, this.apiName, this.descending);
}

/// Item types and recursion for a library: movie and show libraries list
/// their titles flat; anything else is browsed folder by folder.
({List<String> types, bool recursive}) libraryShape(JellyfinItem folder) =>
    switch (folder.collectionType) {
      'movies' => (types: const [JellyfinItemType.movie], recursive: true),
      'tvshows' => (types: const [JellyfinItemType.series], recursive: true),
      'boxsets' => (types: const [JellyfinItemType.boxSet], recursive: true),
      _ => (types: const <String>[], recursive: false),
    };

const libraryPageSize = 100;

/// One library (or folder) as a grid that fills the width, with sort,
/// unplayed / favourite filters and infinite scroll. The scrollbar spans
/// the full count from the start: not-yet-loaded cells are skeletons and
/// pages load as they come near the viewport.
class JellyfinLibraryPage extends StatefulWidget {
  final JellyfinItem folder;
  /// A [LibrarySort] name to start with (in its natural direction).
  final String? sort;
  const JellyfinLibraryPage({super.key, required this.folder, this.sort});

  @override
  State<JellyfinLibraryPage> createState() => _JellyfinLibraryPageState();
}

class _JellyfinLibraryPageState extends State<JellyfinLibraryPage> {
  late LibrarySort _sort =
      LibrarySort.values.where((s) => s.name == widget.sort).firstOrNull ?? LibrarySort.name;
  late bool _descending = _sort.descending;
  bool _unplayed = false;
  bool _favorites = false;

  final _items = <JellyfinItem>[];
  int? _total;
  bool _loading = false;
  Object? _error;
  int _gen = 0;
  final _scroll = ScrollController();

  BrowseScope? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = BrowseScope.of(context);
    final first = _scope == null;
    final changedServer = _scope != null && _scope!.client != scope.client;
    _scope = scope;
    if (first || changedServer) {
      _version = scope.controller.version;
      _reload();
    }
  }

  /// The browser's data version the items were loaded at.
  int _version = 0;

  @override
  void didUpdateWidget(JellyfinLibraryPage old) {
    super.didUpdateWidget(old);
    // Watched state changed (a mark, a playback): the loaded items again,
    // in place.
    final scope = _scope;
    if (scope != null && scope.controller.version != _version) {
      _version = scope.controller.version;
      _refresh();
    }
  }

  /// Loads the items shown so far again and swaps them in when they come
  /// (the grid keeps its place meanwhile).
  Future<void> _refresh() async {
    final scope = _scope;
    if (scope == null || _items.isEmpty || _loading) return;
    final gen = ++_gen;
    // No page loads meanwhile: they would land on the old list.
    _loading = true;
    try {
      final page = await scope.client.items(_query.page(0, math.max(_items.length, libraryPageSize)));
      if (gen != _gen || !mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.items.isEmpty ? 0 : page.totalRecordCount;
        _loading = false;
      });
    } catch (_) {
      // The grid stays as it was.
      if (gen == _gen && mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  JellyfinItemQuery get _query {
    final shape = libraryShape(widget.folder);
    return JellyfinItemQuery(
      parentId: widget.folder.id,
      includeItemTypes: shape.types,
      recursive: shape.recursive,
      sortBy: [
        // Folders first when browsing a folder tree.
        if (!shape.recursive && _sort == LibrarySort.name) 'IsFolder',
        _sort.apiName,
        if (_sort != LibrarySort.name) JellyfinSortBy.sortName,
      ],
      descending: _descending,
      filters: [
        if (_unplayed) JellyfinFilter.isUnplayed,
        if (_favorites) JellyfinFilter.isFavorite,
      ],
    );
  }

  void _reload() {
    _gen++;
    _items.clear();
    _total = null;
    _error = null;
    _loading = false;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _loadMore();
  }

  Future<void> _loadMore() async {
    final scope = _scope;
    if (scope == null || _loading) return;
    if (_total != null && _items.length >= _total!) return;
    final gen = _gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await scope.client.items(_query.page(_items.length, libraryPageSize));
      if (gen != _gen || !mounted) return;
      setState(() {
        _items.addAll(page.items);
        // An empty page before the advertised end: the library shrank.
        _total = page.items.isEmpty ? _items.length : page.totalRecordCount;
        _loading = false;
      });
    } catch (e) {
      if (gen != _gen || !mounted) return;
      if (e is JellyfinException && e.isUnauthorized) {
        scope.accounts.markExpired(scope.account.serverId);
      }
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  void _setSort(LibrarySort s) {
    setState(() {
      _sort = s;
      _descending = s.descending;
    });
    _reload();
  }

  CardShape get _shape =>
      widget.folder.collectionType == 'homevideos' ? CardShape.thumb : CardShape.poster;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final total = _total;
    final toolbar = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(widget.folder.name, style: t.titleLarge),
        const SizedBox(width: 4),
        Text(total == null ? '' : '$total ${total == 1 ? 'item' : 'items'}',
            key: const ValueKey('library-count'),
            style: t.bodySmall?.copyWith(color: Colors.grey)),
        const SizedBox(width: 12),
        _SortMenu(sort: _sort, onSelected: _setSort),
        if (_sort != LibrarySort.random)
          IconButton(
            tooltip: _descending ? 'Descending' : 'Ascending',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() => _descending = !_descending);
              _reload();
            },
            icon: Icon(_descending ? Icons.arrow_downward : Icons.arrow_upward, size: 18),
          )
        else
          IconButton(
            tooltip: 'Shuffle again',
            visualDensity: VisualDensity.compact,
            onPressed: _reload,
            icon: const Icon(Icons.shuffle, size: 18),
          ),
        FilterChip(
          key: const ValueKey('filter-unplayed'),
          label: const Text('Unwatched'),
          selected: _unplayed,
          visualDensity: VisualDensity.compact,
          onSelected: (v) {
            setState(() => _unplayed = v);
            _reload();
          },
        ),
        FilterChip(
          key: const ValueKey('filter-favorites'),
          label: const Text('Favorites'),
          selected: _favorites,
          visualDensity: VisualDensity.compact,
          onSelected: (v) {
            setState(() => _favorites = v);
            _reload();
          },
        ),
      ],
    );

    final count = total ?? (_loading ? libraryPageSize ~/ 4 : 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 12), child: toolbar),
        if (_error != null && _items.isEmpty)
          LoadError(error: _error!, onRetry: _loadMore)
        else if (total == 0)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('Nothing here', style: TextStyle(color: Colors.grey))),
          )
        else
          Expanded(
            child: Scrollbar(
              controller: _scroll,
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverGrid(
                    gridDelegate: CardGridDelegate(_shape),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        if (i >= _items.length - 40 && _error == null) {
                          // Near the loaded edge: fetch the next page.
                          scheduleMicrotask(_loadMore);
                        }
                        if (i >= _items.length) return SkeletonCard(shape: _shape);
                        return MediaCard(item: _items[i], shape: _shape);
                      },
                      childCount: count,
                    ),
                  ),
                  if (_error != null && _items.isNotEmpty)
                    SliverToBoxAdapter(child: LoadError(error: _error!, onRetry: _loadMore)),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SortMenu extends StatelessWidget {
  final LibrarySort sort;
  final ValueChanged<LibrarySort> onSelected;
  const _SortMenu({required this.sort, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final s in LibrarySort.values)
          MenuItemButton(
            key: ValueKey('sort-${s.name}'),
            leadingIcon: Icon(s == sort ? Icons.check : null, size: 18),
            onPressed: () => onSelected(s),
            child: Text(s.label),
          ),
      ],
      builder: (context, menu, _) => OutlinedButton.icon(
        key: const ValueKey('library-sort'),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.sort, size: 18),
        label: Text(sort.label),
      ),
    );
  }
}
