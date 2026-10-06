import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'accounts.dart';
import 'format.dart';

/// One level of the library browser's back stack.
sealed class BrowseRoute {
  const BrowseRoute();
  String get label;
  /// Identity for keeping a page's state while it is in the stack.
  String get key;
}

final class HomeRoute extends BrowseRoute {
  const HomeRoute();
  @override
  String get label => 'Home';
  @override
  String get key => 'home';
}

/// A library or folder grid.
final class LibraryRoute extends BrowseRoute {
  final JellyfinItem folder;
  const LibraryRoute(this.folder);
  @override
  String get label => folder.name;
  @override
  String get key => 'lib:${folder.id}';
}

final class SeriesRoute extends BrowseRoute {
  final JellyfinItem series;
  /// Season to open on (from a season card or an episode's "open series").
  final String? seasonId;
  const SeriesRoute(this.series, {this.seasonId});
  @override
  String get label => series.name;
  @override
  String get key => 'series:${series.id}';
}

/// Movie / episode / video detail.
final class DetailRoute extends BrowseRoute {
  final JellyfinItem item;
  const DetailRoute(this.item);
  @override
  String get label => item.kind == JellyfinItemKind.episode
      ? (item.episodeLabel ?? item.name)
      : item.name;
  @override
  String get key => 'item:${item.id}';
}

/// What every browser page needs, provided by [JellyfinBrowser].
class BrowseScope extends InheritedWidget {
  final JellyfinAccounts accounts;
  final JellyfinAccount account;
  final JellyfinClient client;
  /// Item id of the current pick on this server, highlighted everywhere.
  final String? selectedItemId;
  final ValueChanged<JellyfinItem> onPick;
  final ValueChanged<BrowseRoute> onOpen;
  /// Hover / focus: the inspector pane follows it.
  final ValueChanged<JellyfinItem> onPeek;

  const BrowseScope({
    super.key,
    required this.accounts,
    required this.account,
    required this.client,
    required this.selectedItemId,
    required this.onPick,
    required this.onOpen,
    required this.onPeek,
    required super.child,
  });

  static BrowseScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BrowseScope>()!;

  /// Cached browse call on this server.
  Future<T> load<T>(String key, Future<T> Function(JellyfinClient c) fn) =>
      accounts.cached(account.serverId, key, () => fn(client));

  /// Click / Enter on a card: playable items are picked, containers open.
  void activate(JellyfinItem item) {
    if (isPlayable(item)) {
      onPick(item);
      return;
    }
    switch (item.kind) {
      case JellyfinItemKind.series:
        onOpen(SeriesRoute(item));
      case JellyfinItemKind.season:
        final sid = item.seriesId;
        if (sid != null) {
          onOpen(SeriesRoute(
              JellyfinItem(id: sid, name: item.seriesName ?? item.name, type: 'Series'),
              seasonId: item.id));
        }
      default:
        onOpen(LibraryRoute(item));
    }
  }

  /// Opens the series of an episode (or the item itself if it has none).
  void openSeriesOf(JellyfinItem episode) {
    final sid = episode.seriesId;
    if (sid == null) return;
    onOpen(SeriesRoute(
        JellyfinItem(id: sid, name: episode.seriesName ?? '', type: 'Series'),
        seasonId: episode.seasonId));
  }

  @override
  bool updateShouldNotify(BrowseScope old) =>
      old.selectedItemId != selectedItemId ||
      old.account != account ||
      old.client != client;
}

/// Runs [load] once (again on [retry]) and shows [builder] with the result,
/// a spinner meanwhile, and a compact error with Retry on failure.
class Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;
  final Widget? loading;
  /// When false the error collapses to nothing (optional sections).
  final bool showError;
  const Loader({
    super.key,
    required this.load,
    required this.builder,
    this.loading,
    this.showError = true,
  });

  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  late Future<T> _future = widget.load();

  void _retry() => setState(() => _future = widget.load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasData) return widget.builder(context, snap.data as T);
        if (snap.hasError) {
          if (!widget.showError) return const SizedBox.shrink();
          return LoadError(error: snap.error!, onRetry: _retry);
        }
        if (snap.connectionState == ConnectionState.done) {
          return widget.builder(context, snap.data as T);
        }
        return widget.loading ??
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
      },
    );
  }
}

class LoadError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const LoadError({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final e = error;
    final msg = e is JellyfinException
        ? (e.isUnauthorized ? 'Sign-in expired' : e.message)
        : '$e';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 18, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 8),
          Flexible(
            child: Text(msg.length > 160 ? '${msg.substring(0, 160)}…' : msg,
                style: const TextStyle(color: Colors.grey)),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
