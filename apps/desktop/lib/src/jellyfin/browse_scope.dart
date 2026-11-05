import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sync_relay_core/core.dart';

import 'accounts.dart';
import 'format.dart';
import 'home_rows.dart' show continueKey;
import 'item_actions.dart';

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

  /// Watched state changed on [server] (default: the one shown): drop its
  /// cached lists and let the rows reload.
  void dataChanged([String? server]) {
    final id = server ?? serverId;
    if (id != null) accounts.invalidate(id);
    _version++;
    notifyListeners();
  }

  /// Watched marks made here ('serverId|itemId'), shown at once while the
  /// lists holding the item load again; the newest mark wins.
  final _marks = <String, ({bool played, int seq, DateTime at})>{};
  int _markSeq = 0;

  /// How long a mark stands in for the server's answer: the lists have
  /// loaded again long before.
  static const markHold = Duration(seconds: 30);

  /// [item] as the marks made here say: watched or unwatched when it, its
  /// season or its show was marked lately (no resume point either way, as
  /// Jellyfin does).
  JellyfinItem marked(String server, JellyfinItem item) {
    if (_marks.isEmpty) return item;
    ({bool played, int seq, DateTime at})? best;
    for (final id in [item.id, item.seasonId, item.seriesId]) {
      if (id == null) continue;
      final m = _marks['$server|$id'];
      if (m == null || now().difference(m.at) >= markHold) continue;
      if (best == null || m.seq > best.seq) best = m;
    }
    if (best == null) return item;
    final u = item.userData;
    final folder = item.kind == JellyfinItemKind.series || item.kind == JellyfinItemKind.season;
    return item.withUserData(JellyfinUserData(
      played: best.played,
      playCount: best.played ? math.max(1, u.playCount) : 0,
      isFavorite: u.isFavorite,
      unplayedItemCount: !folder
          ? u.unplayedItemCount
          : best.played
              ? 0
              : (u.unplayedItemCount == 0 ? null : u.unplayedItemCount),
      playedPercentage: best.played && folder ? 100 : null,
      lastPlayedDate: u.lastPlayedDate,
    ));
  }

  /// Marks [item] watched or unwatched on [server]: an episode or a movie,
  /// a season or a whole show (Jellyfin marks every episode in it). Every
  /// row showing it (and a season's or show's episodes) shows it at once;
  /// the lists load again. Throws what Jellyfin answered.
  Future<void> setPlayed(String server, JellyfinItem item, bool played) async {
    final c = accounts.clientFor(server);
    if (c == null) throw const JellyfinException('that Jellyfin server is not linked any more');
    final key = '$server|${item.id}';
    _marks[key] = (played: played, seq: ++_markSeq, at: now());
    notifyListeners();
    try {
      played ? await c.markPlayed(item.id) : await c.markUnplayed(item.id);
    } catch (e) {
      _marks.remove(key);
      if (e is JellyfinException && e.isUnauthorized) accounts.markExpired(server);
      rethrow;
    } finally {
      if (!_disposed) dataChanged(server);
    }
  }

  /// Takes [item] out of the Continue row on [server]: its resume points
  /// go (its own, or for a show every one in it: what Jellyfin offers), and
  /// the row leaves its show out until it is played again (a next-up show
  /// Jellyfin cannot drop).
  Future<void> removeFromContinue(String server, JellyfinItem item) async {
    final c = accounts.clientFor(server);
    if (c == null) throw const JellyfinException('that Jellyfin server is not linked any more');
    final key = continueKey(item);
    try {
      await accounts.dismissContinue(server, key);
      final resumable = item.userData.isResumable
          ? [item]
          : (await accounts.cached(server, 'resume', () => c.resume(limit: 40)))
              .where((r) => continueKey(r) == key && r.userData.isResumable);
      for (final r in resumable) {
        await c.clearResumePosition(r.id);
      }
    } on JellyfinException catch (e) {
      if (e.isUnauthorized) accounts.markExpired(server);
      rethrow;
    } finally {
      if (!_disposed) dataChanged(server);
    }
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
  /// server (the menus then have no queue actions).
  final void Function(JellyfinItem item, {bool next})? onAddToQueue;
  /// Nobody else in the server: put it up says Play.
  final bool alone;
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
    this.alone = false,
    this.libraryStrip = true,
    required super.child,
  });

  static BrowseScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BrowseScope>()!;

  void onOpen(BrowseRoute route) => controller.open(route);

  /// The actions of this server's items (errors of put-up and queue go
  /// out as the Library's toasts).
  JellyfinItemActions get actions {
    final queue = onAddToQueue;
    return JellyfinItemActions(
      controller: controller,
      serverId: account.serverId,
      alone: alone,
      putUp: (item) async {
        onPutUp(item);
        return null;
      },
      queue: queue == null
          ? null
          : (item, {next = false}) async {
              queue(item, next: next);
              return null;
            },
    );
  }

  /// [item] with the watched marks made here.
  JellyfinItem marked(JellyfinItem item) => controller.marked(account.serverId, item);

  /// Right-click on a card, tile or row ([context]: it): what [item]
  /// offers ([jellyfinActions]), the same as the details panel's.
  Future<void> itemMenu(BuildContext context, JellyfinItem item) => actions.showMenu(context, item);

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
      old.alone != alone ||
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
