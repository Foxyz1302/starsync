import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'accounts.dart';
import 'format.dart';
import '../widgets/app_menu.dart';
import '../widgets/copy_open.dart';

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

/// A library or folder grid, optionally opened with a sort ("Show all"
/// next to Latest opens it newest first).
final class LibraryRoute extends BrowseRoute {
  final JellyfinItem folder;
  /// A `LibrarySort` name; null = by name.
  final String? sort;
  const LibraryRoute(this.folder, {this.sort});
  @override
  String get label => folder.name;
  @override
  String get key => sort == null ? 'lib:${folder.id}' : 'lib:${folder.id}:$sort';
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

/// A route stack as JSON for [JellyfinAccounts.saveBrowseLocation]: only
/// ids, names and the fields the pages start from (each page loads the
/// full item itself).
List<Map<String, Object?>> encodeBrowseStack(List<BrowseRoute> stack) => [
      for (final r in stack)
        switch (r) {
          HomeRoute() => {'r': 'home'},
          LibraryRoute(:final folder, :final sort) => {'r': 'lib', ..._itemJson(folder), 'sort': ?sort},
          SeriesRoute(:final series, :final seasonId) => {
              'r': 'series',
              ..._itemJson(series),
              'seasonId': ?seasonId,
            },
        }
    ];

/// Inverse of [encodeBrowseStack]; always starts with Home. Null when
/// [raw] is not a stack. Entries it no longer knows are skipped.
List<BrowseRoute>? decodeBrowseStack(Object? raw) {
  if (raw is! List) return null;
  final out = <BrowseRoute>[const HomeRoute()];
  for (final e in raw) {
    if (e is! Map) return null;
    final item = _itemFrom(e);
    final route = switch (e['r']) {
      'lib' when item != null =>
        LibraryRoute(item, sort: e['sort'] is String ? e['sort'] as String : null),
      'series' when item != null =>
        SeriesRoute(item, seasonId: e['seasonId'] is String ? e['seasonId'] as String : null),
      _ => null,
    };
    if (route != null && out.every((r) => r.key != route.key)) out.add(route);
  }
  return out;
}

Map<String, Object?> _itemJson(JellyfinItem i) => {
      'id': i.id,
      'name': i.name,
      'type': i.type,
      if (i.isFolder) 'isFolder': true,
      'collectionType': ?i.collectionType,
      'seriesId': ?i.seriesId,
      'seriesName': ?i.seriesName,
      'seasonId': ?i.seasonId,
      'indexNumber': ?i.indexNumber,
      'parentIndexNumber': ?i.parentIndexNumber,
    };

JellyfinItem? _itemFrom(Map e) {
  String? s(String k) => e[k] is String && (e[k] as String).isNotEmpty ? e[k] as String : null;
  final id = s('id');
  if (id == null) return null;
  return JellyfinItem(
    id: id,
    name: s('name') ?? '',
    type: s('type') ?? '',
    isFolder: e['isFolder'] == true,
    collectionType: s('collectionType'),
    seriesId: s('seriesId'),
    seriesName: s('seriesName'),
    seasonId: e['r'] == 'series' ? null : s('seasonId'),
    indexNumber: e['indexNumber'] is int ? e['indexNumber'] as int : null,
    parentIndexNumber: e['parentIndexNumber'] is int ? e['parentIndexNumber'] as int : null,
  );
}

/// Where a browser opens instead of the remembered location: a server and
/// a route stack (e.g. the series of the episode playing).
class BrowseStart {
  final String serverId;
  final List<BrowseRoute> stack;
  const BrowseStart(this.serverId, this.stack);

  /// The series page of [episode] with its season selected.
  static BrowseStart? seriesOf(String serverId, JellyfinItem episode) {
    final sid = episode.seriesId;
    if (sid == null) return null;
    return BrowseStart(serverId, [
      const HomeRoute(),
      SeriesRoute(JellyfinItem(id: sid, name: episode.seriesName ?? '', type: 'Series'),
          seasonId: episode.seasonId),
    ]);
  }
}

/// The card selected in the library (details panel): an item on a server.
/// [item] is what the card had, when known (the panel loads it in full).
class JellyfinSelection {
  final String serverId;
  final String itemId;
  final JellyfinItem? item;
  const JellyfinSelection(this.serverId, this.itemId, [this.item]);

  @override
  bool operator ==(Object other) =>
      other is JellyfinSelection && other.serverId == serverId && other.itemId == itemId;
  @override
  int get hashCode => Object.hash(serverId, itemId);
}

/// Browser location shared by the browser, the library chips in the
/// Library header and the details panel: the server shown, its route
/// stack (saved per server on every move), a data version that bumps after
/// watched-state changes (rows reload), and the keys in the Continue row.
class BrowseController extends ChangeNotifier {
  final JellyfinAccounts accounts;
  /// Clock for the Continue row's age cut-off (tests pin it).
  final DateTime Function() now;
  BrowseController(this.accounts, {this.now = DateTime.now}) {
    // Back from watching: the rows show what was just watched.
    _watchedSub = accounts.watched.listen((id) {
      if (!_disposed && id == serverId) dataChanged();
    });
  }

  late final StreamSubscription<String> _watchedSub;

  String? _serverId;
  List<BrowseRoute> _stack = const [HomeRoute()];
  bool _started = false;
  int _version = 0;
  Set<String> _continueKeys = const {};

  List<BrowseRoute> get stack => _stack;
  int get version => _version;
  /// [continueKey]s of the cards in the Continue row now.
  Set<String> get continueKeys => _continueKeys;

  JellyfinAccount? get account =>
      (_serverId == null ? null : accounts.account(_serverId!)) ?? accounts.defaultAccount;
  String? get serverId => account?.serverId;

  /// First use (accounts loaded): [start], else the server of [serverHint]
  /// at its remembered location, else the default server's.
  void start({BrowseStart? start, String? serverHint}) {
    if (_started) return;
    _started = true;
    if (start != null && accounts.account(start.serverId) != null) {
      _serverId = start.serverId;
      _stack = start.stack.isEmpty ? const [HomeRoute()] : start.stack;
      _remember();
    } else {
      _serverId = serverHint != null && accounts.account(serverHint) != null
          ? serverHint
          : accounts.defaultServerId;
      _stack = _restored(_serverId);
    }
  }

  List<BrowseRoute> _restored(String? serverId) =>
      (serverId == null ? null : decodeBrowseStack(accounts.browseLocation(serverId))) ??
      const [HomeRoute()];

  void _remember() {
    final id = serverId;
    if (id != null) unawaited(accounts.saveBrowseLocation(id, encodeBrowseStack(_stack)));
  }

  void switchServer(String serverId) {
    if (serverId == this.serverId) return;
    _serverId = serverId;
    _stack = _restored(serverId);
    _continueKeys = const {};
    notifyListeners();
  }

  void open(BrowseRoute route) {
    if (_stack.last.key == route.key) return;
    _stack = [..._stack, route];
    _remember();
    notifyListeners();
  }

  /// Home, then [route] (library chips: a library is a top-level place).
  void openTop(BrowseRoute route) {
    _stack = [const HomeRoute(), route];
    _remember();
    notifyListeners();
  }

  bool back() {
    if (_stack.length <= 1) return false;
    _stack = _stack.sublist(0, _stack.length - 1);
    _remember();
    notifyListeners();
    return true;
  }

  void popTo(int index) {
    _stack = _stack.sublist(0, index + 1);
    _remember();
    notifyListeners();
  }

  /// Watched state changed on the server: drop its cached lists and let
  /// the rows reload.
  void dataChanged() {
    final id = serverId;
    if (id != null) accounts.invalidate(id);
    _version++;
    notifyListeners();
  }

  set continueKeys(Set<String> keys) {
    if (setEquals(keys, _continueKeys)) return;
    _continueKeys = keys;
    // Set while building a row: tell listeners after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_watchedSub.cancel());
    super.dispose();
  }
}

/// An item's title to copy: an episode with its series ("Show · Name").
String jellyfinCopyTitle(JellyfinItem item) {
  final series = item.seriesName;
  return item.kind == JellyfinItemKind.episode && series != null && series.isNotEmpty
      ? '$series · ${item.name}'
      : item.name;
}

/// What every browser page needs, provided by [JellyfinBrowser].
class BrowseScope extends InheritedWidget {
  final JellyfinAccounts accounts;
  final JellyfinAccount account;
  final JellyfinClient client;
  final BrowseController controller;
  /// Item id of the selected card on this server, highlighted everywhere.
  final String? selectedItemId;
  /// Click: select (details panel).
  final ValueChanged<JellyfinItem> onSelect;
  /// Double-click: put it up (a series: its next episode).
  final ValueChanged<JellyfinItem> onPutUp;
  /// Adds it to Up next (with next: right after what plays); null: no
  /// server (the cards' menu then only copies and opens).
  final void Function(JellyfinItem item, {bool next})? onAddToQueue;
  /// Home shows the library chips itself (the Library tab has them in its
  /// header instead).
  final bool libraryStrip;

  const BrowseScope({
    super.key,
    required this.accounts,
    required this.account,
    required this.client,
    required this.controller,
    required this.selectedItemId,
    required this.onSelect,
    required this.onPutUp,
    this.onAddToQueue,
    this.libraryStrip = true,
    required super.child,
  });

  static BrowseScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BrowseScope>()!;

  void onOpen(BrowseRoute route) => controller.open(route);

  /// Right-click on a card ([context]: the card): Put it up, Add to queue,
  /// Play next (playable, in a server), Copy title, Open in Jellyfin.
  Future<void> cardMenu(BuildContext context, JellyfinItem item) async {
    final queue = isSelectable(item) ? onAddToQueue : null;
    final pick = await showAppMenu<int>(context, items: [
      if (queue != null) ...const [
        AppMenuItem(value: 0, label: 'Put it up'),
        AppMenuItem(value: 1, label: 'Add to queue'),
        AppMenuItem(value: 2, label: 'Play next'),
      ],
      const AppMenuItem(value: 3, label: ReuseText.copyTitle),
      const AppMenuItem(value: 4, label: ReuseText.openInJellyfin),
    ]);
    switch (pick) {
      case 0:
        onPutUp(item);
      case 1:
        queue!(item);
      case 2:
        queue!(item, next: true);
      case 3:
        await copyToClipboard(jellyfinCopyTitle(item), done: 'Title copied');
      case 4:
        await openLink(jellyfinWebUrl(client.baseUrl, item.id, serverId: account.serverId));
    }
  }

  /// Cached browse call on this server.
  Future<T> load<T>(String key, Future<T> Function(JellyfinClient c) fn) =>
      accounts.cached(account.serverId, key, () => fn(client));

  /// Click / Enter on a card: series, movies and episodes are selected,
  /// seasons open their series, libraries and folders open.
  void activate(JellyfinItem item) {
    if (isSelectable(item)) {
      onSelect(item);
      return;
    }
    switch (item.kind) {
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

  /// Opens the series of an episode.
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
      old.client != client ||
      old.libraryStrip != libraryStrip;
}

/// Runs [load] once (again on [retry] and when [version] changes) and
/// shows [builder] with the result, a spinner meanwhile, and a compact
/// error with Retry on failure. A reload for a new [version] keeps the old
/// result on screen until the new one arrives.
class Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;
  final Widget? loading;
  /// When false the error collapses to nothing (optional sections).
  final bool showError;
  final Object? version;
  const Loader({
    super.key,
    required this.load,
    required this.builder,
    this.loading,
    this.showError = true,
    this.version,
  });

  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  late Future<T> _future = widget.load();
  (T,)? _last;

  void _retry() => setState(() => _future = widget.load());

  @override
  void didUpdateWidget(Loader<T> old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _future = widget.load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasData || (snap.connectionState == ConnectionState.done && !snap.hasError)) {
          _last = (snap.data as T,);
          return widget.builder(context, snap.data as T);
        }
        if (snap.hasError) {
          if (!widget.showError) return const SizedBox.shrink();
          return LoadError(error: snap.error!, onRetry: _retry);
        }
        final last = _last;
        if (last != null) return widget.builder(context, last.$1);
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
