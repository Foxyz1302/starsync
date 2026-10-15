import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../../library/show_matcher.dart';
import '../../shell/motion.dart';
import '../../platform/ports/folder_access.dart';
import '../../app/app_graph.dart';
import '../../widgets/app_menu.dart';
import '../folder_store.dart';
import '../scanner.dart';
import 'file_tiles.dart';
import 'library_view.dart';
import 'thumb.dart';

export 'thumb.dart' show ThumbnailLoader;

// The Files source as a library: the watched folders on the left (chips
// on top when narrow): the Library (every folder together), Recent, then
// each folder. A library is shows and movies as poster cards, grouped by
// the library's L1 and named by its L2 match, plus the videos that are
// neither; a show opens its own page. Folders are scanned when first
// needed and on Rescan; scans, the open place and the open show are kept
// for the app session. Playing goes through [onPlay].

/// Below this width the sidebar turns into chips above the list.
const filesNarrowWidth = 700.0;

/// The place that shows every watched folder together.
const libraryPlace = '\u0000library';

/// Scans kept for the app session, by folder.
final _scans = <String, FolderScan>{};
final _running = <String, Future<FolderScan>>{};
String? _lastOpen = libraryPlace;
/// The show open in each place (by show key) for the app session.
final _openShows = <String, String>{};
final _showRequests = ValueNotifier(0);

/// Opens [dir] (null: Recent; [libraryPlace]: the library) in the Files
/// page: now if one is showing, else when it next opens.
void showFilesFolder(String? dir) {
  _lastOpen = dir;
  _showRequests.value++;
}

/// Forgets the session's scans, open shows and the open place.
@visibleForTesting
void resetFilesPageSession() {
  _scans.clear();
  _running.clear();
  _openShows.clear();
  _lastOpen = libraryPlace;
}

class FilesPage extends StatefulWidget {
  /// Nobody else is in the server: no relay notice.
  final bool alone;
  /// The file will stream from this computer through the server.
  final bool relayed;
  /// Plays [path] in the session; returns an error text, or null.
  final Future<String?> Function(String path) onPlay;
  /// Adds [path] to Up next (right-click on a video); null: no server.
  final Future<String?> Function(String path, {bool next})? onAddToQueue;
  final String? nowPlayingPath;
  /// Defaults to [thumbnailFor].
  final ThumbnailLoader? thumbnails;
  /// Defaults to [FolderAccess.scan].
  final Future<FolderScan> Function(String dir)? scan;
  /// Defaults to [FolderStore.instance].
  final FolderStore? store;
  /// Defaults to the app's (`AppGraph.library`).
  final ShowMatcher? matcher;
  /// Default: the system folder / file dialogs.
  final Future<String?> Function()? pickFolder;
  final Future<String?> Function()? pickVideo;

  const FilesPage({
    super.key,
    this.alone = false,
    required this.relayed,
    required this.onPlay,
    this.onAddToQueue,
    this.nowPlayingPath,
    this.thumbnails,
    this.scan,
    this.store,
    this.matcher,
    this.pickFolder,
    this.pickVideo,
  });

  @override
  State<FilesPage> createState() => _FilesPageState();
}

/// A place's scans grouped (L1), made once per set of scans.
class _Library {
  final List<FolderScan> scans;
  final LocalLibrary lib;
  final Map<String, LocalEpisode> byPath;

  _Library(this.scans, List<String> roots)
      : lib = groupLocal([for (final s in scans) ...s.videos], roots: roots),
        byPath = {} {
    for (final e in lib.files) {
      byPath[e.path] = e;
    }
  }

  int get videos => scans.fold(0, (n, s) => n + s.videos.length);
  int get hidden => scans.fold(0, (n, s) => n + s.hiddenCount);
  int get subtitleFiles => {
        for (final s in scans)
          for (final l in s.subtitles.values) ...l
      }.length;
  bool get truncated => scans.any((s) => s.truncated);
}

class _FilesPageState extends State<FilesPage> {
  FolderAccess get _folders => AppScope.of(context).ports.folders;
  ShowMatcher get _matcher => widget.matcher ?? AppScope.of(context).library;

  late final ThumbCache _thumbs =
      widget.thumbnails == null ? ThumbCache.shared : ThumbCache(widget.thumbnails!);
  FolderStore get _store => widget.store ?? FolderStore.instance;

  /// Null: Recent; [libraryPlace]: every folder.
  String? _open = _lastOpen;
  bool _showHidden = false;
  String? _starting;
  String? _error;
  final _libs = <String, _Library>{};

  @override
  void initState() {
    super.initState();
    _showRequests.addListener(_shown);
    unawaited(_matcher.ensureLoaded());
    _store.ensureLoaded().then((_) {
      if (!mounted) return;
      final open = _open;
      if (open != null && open != libraryPlace && !_store.folders.value.contains(open)) {
        _select(libraryPlace);
      } else {
        _scanFor(open);
      }
    });
  }

  @override
  void dispose() {
    _showRequests.removeListener(_shown);
    super.dispose();
  }

  void _shown() => _select(_lastOpen);

  Future<FolderScan> _runScan(String dir) => (widget.scan ?? _folders.scan)(dir);

  /// The folders a place needs scanned.
  List<String> _foldersOf(String? place) => place == null
      ? const []
      : place == libraryPlace
          ? _store.folders.peek()
          : [place];

  void _scanFor(String? place) {
    for (final f in _foldersOf(place)) {
      if (!_scans.containsKey(f) && !_running.containsKey(f)) _scan(f);
    }
  }

  void _select(String? place) {
    setState(() {
      _open = _lastOpen = place;
      _showHidden = false;
    });
    _scanFor(place);
  }

  Future<void> _scan(String dir, {bool rescan = false}) async {
    var f = _running[dir];
    if (f == null || rescan) {
      f = _running[dir] = _runScan(dir);
      if (rescan) _thumbs.forget([for (final v in _scans[dir]?.videos ?? const <LocalFile>[]) v.path]);
    }
    if (mounted) setState(() {});
    FolderScan result;
    try {
      result = await f;
    } catch (_) {
      result = FolderScan.empty;
    }
    if (_running[dir] == f) {
      _running.remove(dir);
      _scans[dir] = result;
    }
    if (mounted) setState(() {});
  }

  /// The grouped library of [place], once its folders are scanned (the
  /// library: those scanned so far).
  _Library? _libraryOf(String place) {
    final folders = _foldersOf(place);
    final scans = [for (final f in folders) ?_scans[f]];
    if (place != libraryPlace && scans.isEmpty) return null;
    final known = _libs[place];
    if (known != null && known.scans.length == scans.length && _same(known.scans, scans)) return known;
    final lib = _libs[place] = _Library(scans, folders);
    _matcher.remember(lib.lib);
    return lib;
  }

  static bool _same(List<FolderScan> a, List<FolderScan> b) {
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  Future<void> _addFolder() async {
    String? dir;
    try {
      dir = await (widget.pickFolder ??
          () => _folders.pickFolder(dialogTitle: 'Add a folder with videos'))();
    } catch (e) {
      _showError('Folder dialog unavailable (${e.runtimeType})');
    }
    if (dir == null || !mounted) return;
    _store.addFolder(dir);
    _select(dir);
  }

  Future<void> _browse() async {
    String? path;
    try {
      path = await (widget.pickVideo ?? _pickVideo)();
    } catch (e) {
      _showError('File dialog unavailable (${e.runtimeType})');
    }
    if (path != null && mounted) await _play(path);
  }

  Future<String?> _pickVideo() async {
    final files = await _folders.pickFiles(dialogTitle: 'Pick a video', extensions: videoExtensions.toList());
    return files.firstOrNull;
  }

  void _removeFolder(String dir) {
    _store.removeFolder(dir);
    _scans.remove(dir);
    if (_open == dir) _select(libraryPlace);
    setState(() {});
  }

  Future<void> _play(String path) async {
    if (_starting != null) return;
    setState(() {
      _starting = path;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onPlay(path);
    } catch (e) {
      error = '$e';
    }
    if (error == null) _store.addRecent(path);
    if (!mounted) return;
    setState(() {
      _starting = null;
      _error = error;
    });
  }

  void _showError(String text) {
    if (mounted) setState(() => _error = text);
  }

  PlayState _stateOf(String path) => path == _starting
      ? PlayState.starting
      : path == widget.nowPlayingPath
          ? PlayState.playing
          : PlayState.idle;

  VoidCallback _tapOf(String path) => () => _play(path);

  /// Right-click on a video ([context]: its tile): Put it up, Add to
  /// queue, Play next.
  Future<void> _menu(BuildContext context, String path) async {
    final add = widget.onAddToQueue;
    if (add == null) return;
    final pick = await showAppMenu<int>(context, items: [
      AppMenuItem(value: 0, label: widget.alone ? 'Play' : 'Put it up'),
      const AppMenuItem(value: 1, label: 'Add to queue'),
      const AppMenuItem(value: 2, label: 'Play next'),
    ]);
    if (pick == null || !mounted) return;
    if (pick == 0) return _play(path);
    String? error;
    try {
      error = await add(path, next: pick == 2);
    } catch (e) {
      error = '$e';
    }
    if (error != null) _showError(error);
  }

  /// [child] with the right-click menu (when there is a server).
  Widget _menuable(String path, Widget child) => widget.onAddToQueue == null
      ? child
      : KeyedSubtree(
          key: ValueKey('menu:$path'),
          child: Builder(
              builder: (context) => GestureDetector(onSecondaryTap: () => _menu(context, path), child: child)));

  late final _actions = FilesActions(
    play: (p) => unawaited(_play(p)),
    stateOf: _stateOf,
    menuable: _menuable,
    thumbs: _thumbs,
  );

  /// The last episode of [show] played here (Recent), by key.
  String? _lastPlayed(_Library lib, LocalShow show) {
    for (final p in _store.recent.value) {
      final e = lib.byPath[p];
      if (e != null && e.showKey == show.key && e.kind == LocalKind.episode) return e.key;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < filesNarrowWidth;
          return SignalBuilder(builder: (context) {
            final folders = _store.folders.value;
            final recent = _store.recent.value;
            _matcher.revision.value;
            final open = _open == null || _open == libraryPlace || folders.contains(_open) ? _open : libraryPlace;
            final showKey = open == null ? null : _openShows[open];
            final main = fadeThrough(
              KeyedSubtree(
                key: ValueKey('${open ?? ''}\n${showKey ?? ''}'),
                child: _main(context, narrow, folders, recent, open, showKey),
              ),
            );
            if (narrow) return main;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 260, child: _sidebar(context, folders, open)),
                Expanded(child: main),
              ],
            );
          });
        },
      );

  Widget _browseButton(Widget Function(VoidCallback? onPressed) build) => build(_browse);

  Widget _sidebar(BuildContext context, List<String> folders, String? open) {
    final scheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
    Widget? status(String? s) =>
        s == null ? null : Text(s, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11));
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 8, 20),
      children: [
        ListTile(
          key: const ValueKey('place:library'),
          dense: true,
          selected: open == libraryPlace,
          shape: shape,
          leading: const Icon(Icons.video_library_outlined, size: 18),
          title: const Text('Library'),
          subtitle: status(_libraryStatus(folders)),
          onTap: () => _select(libraryPlace),
        ),
        ListTile(
          key: const ValueKey('place:recent'),
          dense: true,
          selected: open == null,
          shape: shape,
          leading: const Icon(Icons.history, size: 18),
          title: const Text('Recent'),
          onTap: () => _select(null),
        ),
        const SizedBox(height: 12),
        const Text('Folders', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        for (final f in folders)
          ListTile(
            key: ValueKey('folder:$f'),
            dense: true,
            selected: open == f,
            shape: shape,
            leading: const Icon(Icons.folder_outlined, size: 18),
            title: Text(baseName(f), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: status(_folderStatus(f)),
            trailing: IconButton(
              tooltip: 'Remove folder',
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => _removeFolder(f),
            ),
            onTap: () => _select(f),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addFolder,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add folder'),
          ),
        ),
        const Divider(),
        _browseButton((onPressed) => OutlinedButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Browse…'),
            )),
        const SizedBox(height: 6),
        Text(
          'The system file picker, for anything outside your folders.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
        ),
      ],
    );
  }

  /// "scanning…", "N videos", or null before the first scan.
  String? _folderStatus(String dir) {
    if (_running.containsKey(dir)) return 'scanning…';
    final n = _scans[dir]?.videos.length;
    return n == null ? null : '$n ${n == 1 ? 'video' : 'videos'}';
  }

  String? _libraryStatus(List<String> folders) {
    if (folders.any(_running.containsKey)) return 'scanning…';
    if (folders.isEmpty || folders.any((f) => !_scans.containsKey(f))) return null;
    final n = _libraryOf(libraryPlace)?.lib.shows.length ?? 0;
    return '$n ${n == 1 ? 'show' : 'shows'}';
  }

  List<Widget> _notices() => [
        if (!widget.alone && widget.relayed) const _RelayNotice(),
        AnimatedSize(
          duration: easeTime,
          curve: ease,
          alignment: Alignment.topLeft,
          child: _error == null
              ? const SizedBox(width: double.infinity)
              : _ErrorBanner(_error!, onClose: () => setState(() => _error = null)),
        ),
      ];

  Widget _main(
    BuildContext context,
    bool narrow,
    List<String> folders,
    List<String> recent,
    String? open,
    String? showKey,
  ) {
    final lib = open == null ? null : _libraryOf(open);
    final show = showKey == null ? null : lib?.lib.show(showKey);
    if (open != null && lib != null && show != null) {
      return ShowPage(
        key: ValueKey('show:$open:${show.key}'),
        show: show,
        matcher: _matcher,
        actions: _actions,
        lastPlayed: _lastPlayed(lib, show),
        backLabel: open == libraryPlace ? 'Library' : baseName(open),
        onBack: () => setState(() => _openShows.remove(open)),
        top: [if (narrow) _chips(folders, open), ..._notices()],
      );
    }
    final scanning = _foldersOf(open).any(_running.containsKey);
    // A folder added elsewhere (a drop, the handoff) joins the library.
    if (open == libraryPlace && folders.any((f) => !_scans.containsKey(f) && !_running.containsKey(f))) {
      scheduleMicrotask(() {
        if (mounted) _scanFor(libraryPlace);
      });
    }
    final top = <Widget>[
      _header(context, open),
      if (narrow) _chips(folders, open),
      ..._notices(),
    ];
    final slivers = <Widget>[
      SliverList.list(children: top),
      if (open == null)
        ..._recent(context, recent)
      else if (open == libraryPlace && folders.isEmpty)
        SliverToBoxAdapter(
          child: FilesEmpty(
            Icons.video_library_outlined,
            'Your library is empty',
            'Add a folder with your videos: shows, seasons and movies are found by their names.',
            action: FilledButton.icon(
              onPressed: _addFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder'),
            ),
          ),
        )
      else if (lib == null)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 60),
            child: Center(child: CircularProgressIndicator()),
          ),
        )
      else
        ..._library(context, open, lib, scanning),
    ];
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(narrow ? 20 : 12, 20, 20, 20),
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, String? open) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, title, sub) = switch (open) {
      null => (Icons.history, 'Recent', null),
      libraryPlace => (Icons.video_library, 'Library', null),
      final dir => (Icons.folder, baseName(dir), dir),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                if (sub != null)
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chips(List<String> folders, String? open) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Library'),
              selected: open == libraryPlace,
              onSelected: (_) => _select(libraryPlace),
            ),
            ChoiceChip(
              label: const Text('Recent'),
              selected: open == null,
              onSelected: (_) => _select(null),
            ),
            for (final f in folders)
              // InputChip: selectable like the others, plus the remove x
              // the sidebar has.
              InputChip(
                key: ValueKey('chip:$f'),
                label: Text(baseName(f)),
                selected: open == f,
                onSelected: (_) => _select(f),
                onDeleted: () => _removeFolder(f),
                deleteButtonTooltipMessage: 'Remove folder',
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('Folder'),
              onPressed: _addFolder,
            ),
            _browseButton((onPressed) => ActionChip(
                  avatar: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Browse…'),
                  onPressed: onPressed,
                )),
          ],
        ),
      );

  List<Widget> _recent(BuildContext context, List<String> recent) {
    if (recent.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: FilesEmpty(
            Icons.video_library_outlined,
            'Nothing played yet',
            'Add a folder with your videos, or Browse for a single file.',
            action: FilledButton.icon(
              onPressed: _addFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder'),
            ),
          ),
        ),
      ];
    }
    return [
      SliverList.builder(
        itemCount: recent.length,
        itemBuilder: (context, i) {
          final path = recent[i];
          return _menuable(
              path,
              _RecentRow(
                key: ValueKey(path),
                path: path,
                matcher: _matcher,
                state: _stateOf(path),
                thumbs: _thumbs,
                onTap: _tapOf(path),
                onRemove: () => _store.removeRecent(path),
              ));
        },
      ),
    ];
  }

  Widget _section(BuildContext context, String title, {String? count}) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(count, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
          ],
        ]),
      );

  List<Widget> _library(BuildContext context, String place, _Library lib, bool scanning) {
    final scheme = Theme.of(context).colorScheme;
    final l = lib.lib;
    final folderScan = place == libraryPlace ? null : _scans[place];
    String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
    final summary = [
      count(lib.videos, 'video', 'videos') +
          (l.shows.isEmpty ? '' : ' in ${count(l.shows.length, 'show', 'shows')}'),
      if (lib.hidden > 0) '${count(lib.hidden, 'other file', 'other files')} hidden',
      if (lib.subtitleFiles > 0) count(lib.subtitleFiles, 'subtitle file', 'subtitle files'),
      if (lib.truncated) 'stopped after $maxScannedFiles files',
    ].join(' · ');
    final folders = _foldersOf(place);
    final movies = l.movies;
    final other = l.other;
    return [
      SliverToBoxAdapter(
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.filter_alt_outlined, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(summary, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            if (folderScan != null && folderScan.hiddenCount > 0) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _showHidden = !_showHidden),
                child: Text(_showHidden ? 'Hide them' : 'Show some'),
              ),
            ],
            TextButton.icon(
              onPressed: scanning
                  ? null
                  : () {
                      for (final f in folders) {
                        _scan(f, rescan: true);
                      }
                    },
              icon: scanning
                  ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: Text(scanning ? 'Scanning…' : 'Rescan'),
            ),
          ],
        ),
      ),
      if (folderScan != null)
        SliverToBoxAdapter(
          child: AnimatedSize(
            duration: easeTime,
            curve: ease,
            alignment: Alignment.topLeft,
            child: !_showHidden
                ? const SizedBox(width: double.infinity)
                : Column(
                    children: [
                      for (final f in folderScan.hiddenExamples)
                        ListTile(
                          dense: true,
                          enabled: false,
                          leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
                          title: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Text(
                            kindOf(f) == FileKind.video ? 'sample' : 'not a video',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      if (folderScan.hiddenCount > folderScan.hiddenExamples.length)
                        ListTile(
                          dense: true,
                          enabled: false,
                          title: Text('and ${folderScan.hiddenCount - folderScan.hiddenExamples.length} more'),
                        ),
                    ],
                  ),
          ),
        ),
      if (lib.videos == 0)
        SliverToBoxAdapter(
          child: place == libraryPlace || _folders.folderExists(place)
              ? const FilesEmpty(
                  Icons.search_off,
                  'No videos here',
                  'Only video files are listed (mkv, mp4, webm…).',
                )
              : const FilesEmpty(
                  Icons.folder_off_outlined,
                  'Folder not found',
                  'It may have been moved, renamed or be on a drive that is not connected.',
                ),
        ),
      if (l.shows.isNotEmpty) ...[
        SliverToBoxAdapter(child: _section(context, 'Shows', count: '${l.shows.length}')),
        SliverGrid.builder(
          gridDelegate: posterGrid(),
          itemCount: l.shows.length,
          itemBuilder: (context, i) => _showCard(place, lib, l.shows[i]),
        ),
      ],
      if (movies.isNotEmpty) ...[
        SliverToBoxAdapter(child: _section(context, 'Movies', count: '${movies.length}')),
        SliverGrid.builder(
          gridDelegate: posterGrid(),
          itemCount: movies.length,
          itemBuilder: (context, i) => _movieCard(movies[i]),
        ),
      ],
      if (other.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: _section(context, l.shows.isEmpty && movies.isEmpty ? 'Videos' : 'Other videos'),
        ),
        SliverLayoutBuilder(builder: (context, c) {
          const gap = 12.0;
          final w = c.crossAxisExtent;
          final cols = (w / 240).floor().clamp(2, 8);
          final cardW = (w - gap * (cols - 1)) / cols;
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              mainAxisExtent: cardW * 9 / 16 + videoCardTextHeight,
            ),
            itemCount: other.length,
            itemBuilder: (context, i) {
              final v = other[i];
              return _menuable(
                  v.path,
                  VideoCard(
                    key: ValueKey(v.path),
                    video: v,
                    state: _stateOf(v.path),
                    thumbs: _thumbs,
                    onTap: _tapOf(v.path),
                  ));
            },
          );
        }),
      ],
    ];
  }

  Widget _showCard(String place, _Library lib, LocalShow show) {
    final m = _matcher.showMatch(show);
    final last = _lastPlayed(lib, show);
    final String subtitle;
    if (last == null) {
      final n = show.episodeCount;
      subtitle = '$n ${n == 1 ? 'episode' : 'episodes'}';
    } else {
      final next = show.nextAfter(last);
      subtitle = next == null ? 'Watched to the end' : 'Next: ${episodeNumber(next.episode)}';
    }
    final playing = widget.nowPlayingPath != null && show.files.any((e) => e.path == widget.nowPlayingPath);
    return PosterCard(
      key: ValueKey('showcard:${show.key}'),
      title: m?.entry.title ?? show.title,
      subtitle: subtitle,
      coverUrl: m?.entry.cover,
      framePath: show.episodes.firstOrNull?.path,
      thumbs: _thumbs,
      playing: playing,
      onShown: () => _matcher.want(show),
      onTap: () => setState(() => _openShows[place] = show.key),
    );
  }

  Widget _movieCard(LocalEpisode movie) {
    final m = _matcher.seasonMatch(movie);
    return _menuable(
        movie.path,
        PosterCard(
          key: ValueKey('moviecard:${movie.path}'),
          title: m?.entry.title ?? (movie.parsed.year == null ? movie.title : '${movie.title} (${movie.parsed.year})'),
          subtitle: [
            if (movie.movieNumber != null) movie.label,
            if (m?.entry.year != null) '${m!.entry.year}' else if (movie.parsed.year != null) '${movie.parsed.year}',
            formatSize(movie.file.size),
          ].join(' · '),
          coverUrl: m?.entry.cover,
          framePath: movie.path,
          thumbs: _thumbs,
          playing: _stateOf(movie.path) == PlayState.playing,
          onShown: () => _matcher.wantMovie(movie),
          onTap: _tapOf(movie.path),
        ));
  }
}

/// A Recent entry: `Show · E02` over the file name (the library's names
/// when it knows the show), or the cleaned title over its folder; greyed
/// when the file is gone.
class _RecentRow extends StatefulWidget {
  final String path;
  final ShowMatcher matcher;
  final PlayState state;
  final ThumbCache thumbs;
  final VoidCallback? onTap;
  final VoidCallback onRemove;
  const _RecentRow({
    super.key,
    required this.path,
    required this.matcher,
    required this.state,
    required this.thumbs,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  FolderAccess get _folders => AppScope.of(context).ports.folders;

  FileStat? _stat;

  @override
  void initState() {
    super.initState();
    _folders.stat(widget.path).then((s) {
      if (mounted) setState(() => _stat = s);
    }, onError: (Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    final e = widget.matcher.episodeAt(path) ??
        readLocalFile(LocalFile(path, 0, DateTime.fromMillisecondsSinceEpoch(0)));
    final missing = _stat?.type == FileSystemEntityType.notFound;
    final episode = e.kind == LocalKind.episode || e.kind == LocalKind.extra;
    final name = widget.matcher.seasonMatch(e)?.entry.title ?? e.title;
    return FileRow(
      path: path,
      title: episode ? '$name · ${e.label}' : (e.kind == LocalKind.other ? cleanTitle(e.parsed) : name),
      subtitle: missing ? 'File not found' : (episode ? baseName(path) : parentName(path)),
      size: _stat == null || missing ? null : formatSize(_stat!.size),
      state: widget.state,
      thumbs: widget.thumbs,
      onTap: missing ? null : widget.onTap,
      indent: false,
      trailing: IconButton(
        tooltip: 'Remove from recent',
        icon: const Icon(Icons.close, size: 16),
        onPressed: widget.onRemove,
      ),
    );
  }
}

class _RelayNotice extends StatelessWidget {
  const _RelayNotice();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.lightBlueAccent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            Icon(Icons.cell_tower, size: 18, color: Colors.lightBlueAccent),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Files stream from this computer through the server. '
                'Keep the app open while it plays.',
              ),
            ),
          ],
        ),
      );
}

class _ErrorBanner extends StatelessWidget {
  final String text;
  final VoidCallback onClose;
  const _ErrorBanner(this.text, {required this.onClose});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: scheme.onErrorContainer))),
          IconButton(
            tooltip: 'Dismiss',
            icon: Icon(Icons.close, size: 16, color: scheme.onErrorContainer),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
