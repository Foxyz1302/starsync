import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../shell/motion.dart';
import '../../platform/ports/folder_access.dart';
import '../../app/app_graph.dart';
import '../../widgets/app_menu.dart';
import '../folder_store.dart';
import '../name_parser.dart';
import '../scanner.dart';
import 'file_tiles.dart';
import 'thumb.dart';

export 'thumb.dart' show ThumbnailLoader;

// The Files source: watched folders on the left (chips on top when
// narrow), the open one on the right grouped into series and loose
// videos, or Recent. A folder is scanned when first opened and on Rescan;
// scans are kept for the app session. Series start collapsed; the ones
// opened stay open for the app session. Playing goes through [onPlay].

/// Below this width the sidebar turns into chips above the list.
const filesNarrowWidth = 700.0;

/// Scans kept for the app session, by folder.
final _scans = <String, FolderScan>{};
final _running = <String, Future<FolderScan>>{};
String? _lastOpen;
/// Series opened this session, by `folder\nseries key`.
final _expanded = <String>{};
final _showRequests = ValueNotifier(0);


/// Opens [dir] (null: Recent) in the Files page: now if one is showing,
/// else when it next opens.
void showFilesFolder(String? dir) {
  _lastOpen = dir;
  _showRequests.value++;
}

/// Forgets the session's scans, open series and the open folder.
@visibleForTesting
void resetFilesPageSession() {
  _scans.clear();
  _running.clear();
  _expanded.clear();
  _lastOpen = null;
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
    this.pickFolder,
    this.pickVideo,
  });

  @override
  State<FilesPage> createState() => _FilesPageState();
}

/// A scan grouped for display, made once per scan.
class _Library {
  final GroupedVideos grouped;
  final int subtitleFiles;

  _Library(FolderScan scan)
      : grouped = groupBySeries(scan.videos),
        subtitleFiles = {for (final l in scan.subtitles.values) ...l}.length;

  /// Series rows in order: a header (video null), then, for the series
  /// [open] says, its episodes and extras.
  List<(SeriesGroup, VideoFile?)> rows(bool Function(SeriesGroup g) open) => [
        for (final g in grouped.series) ...[
          (g, null),
          if (open(g))
            for (final v in [...g.episodes, ...g.extras]) (g, v),
        ],
      ];
}

final _libraries = Expando<_Library>();

class _FilesPageState extends State<FilesPage> {
  FolderAccess get _folders => AppScope.of(context).ports.folders;

  late final ThumbCache _thumbs =
      widget.thumbnails == null ? ThumbCache.shared : ThumbCache(widget.thumbnails!);
  FolderStore get _store => widget.store ?? FolderStore.instance;

  /// Null: Recent.
  String? _open = _lastOpen;
  bool _showHidden = false;
  String? _starting;
  String? _error;

  @override
  void initState() {
    super.initState();
    _showRequests.addListener(_shown);
    _store.ensureLoaded().then((_) {
      if (!mounted) return;
      final open = _open;
      if (open != null && !_store.folders.value.contains(open)) {
        _select(null);
      } else if (open != null) {
        _scan(open);
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

  void _select(String? dir) {
    setState(() {
      _open = _lastOpen = dir;
      _showHidden = false;
    });
    if (dir != null && !_scans.containsKey(dir)) _scan(dir);
  }

  Future<void> _scan(String dir, {bool rescan = false}) async {
    var f = _running[dir];
    if (f == null || rescan) {
      f = _running[dir] = _runScan(dir);
      if (rescan) _thumbs.forget([for (final v in _scans[dir]?.videos ?? const <VideoFile>[]) v.path]);
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
    if (_open == dir) _select(null);
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

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < filesNarrowWidth;
          return SignalBuilder(builder: (context) {
            final folders = _store.folders.value;
            final recent = _store.recent.value;
            final open = _open != null && folders.contains(_open) ? _open : null;
            final main = fadeThrough(
              KeyedSubtree(
                key: ValueKey(open ?? ''),
                child: _main(context, narrow, folders, recent, open),
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 8, 20),
      children: [
        const Text('Folders', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ListTile(
          dense: true,
          selected: open == null,
          shape: shape,
          leading: const Icon(Icons.history, size: 18),
          title: const Text('Recent'),
          onTap: () => _select(null),
        ),
        for (final f in folders)
          ListTile(
            key: ValueKey('folder:$f'),
            dense: true,
            selected: open == f,
            shape: shape,
            leading: const Icon(Icons.folder_outlined, size: 18),
            title: Text(baseName(f), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: switch (_folderStatus(f)) {
              final s? => Text(s, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
              null => null,
            },
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

  Widget _main(
    BuildContext context,
    bool narrow,
    List<String> folders,
    List<String> recent,
    String? open,
  ) {
    final scan = open == null ? null : _scans[open];
    final scanning = open != null && _running.containsKey(open);
    final top = <Widget>[
      _header(context, open),
      if (narrow) _chips(folders, open),
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
    final slivers = <Widget>[
      SliverList.list(children: top),
      if (open == null)
        ..._recent(context, recent)
      else if (scan == null)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 60),
            child: Center(child: CircularProgressIndicator()),
          ),
        )
      else
        ..._folder(context, open, scan, scanning),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(open == null ? Icons.history : Icons.folder, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  open == null ? 'Recent' : baseName(open),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                if (open != null)
                  Text(
                    open,
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
                state: _stateOf(path),
                thumbs: _thumbs,
                onTap: _tapOf(path),
                onRemove: () => _store.removeRecent(path),
              ));
        },
      ),
    ];
  }

  List<Widget> _folder(BuildContext context, String dir, FolderScan scan, bool scanning) {
    final scheme = Theme.of(context).colorScheme;
    final lib = _libraries[scan] ??= _Library(scan);
    final series = lib.grouped.series.length;
    String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
    final summary = [
      count(scan.videos.length, 'video', 'videos') + (series > 0 ? ' in $series series' : ''),
      if (scan.hiddenCount > 0)
        '${count(scan.hiddenCount, 'other file', 'other files')} hidden',
      if (lib.subtitleFiles > 0) count(lib.subtitleFiles, 'subtitle file', 'subtitle files'),
      if (scan.truncated) 'stopped after $maxScannedFiles files',
    ].join(' · ');
    final loose = lib.grouped.loose;
    String seriesId(SeriesGroup g) => '$dir\n${g.key}';
    final rows = lib.rows((g) => _expanded.contains(seriesId(g)));
    return [
      SliverToBoxAdapter(
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.filter_alt_outlined, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(summary, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            if (scan.hiddenCount > 0) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _showHidden = !_showHidden),
                child: Text(_showHidden ? 'Hide them' : 'Show some'),
              ),
            ],
            TextButton.icon(
              onPressed: scanning ? null : () => _scan(dir, rescan: true),
              icon: scanning
                  ? const SizedBox.square(
                      dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: Text(scanning ? 'Scanning…' : 'Rescan'),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AnimatedSize(
          duration: easeTime,
          curve: ease,
          alignment: Alignment.topLeft,
          child: !_showHidden
              ? const SizedBox(width: double.infinity)
              : Column(
                  children: [
                    for (final f in scan.hiddenExamples)
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
                    if (scan.hiddenCount > scan.hiddenExamples.length)
                      ListTile(
                        dense: true,
                        enabled: false,
                        title: Text('and ${scan.hiddenCount - scan.hiddenExamples.length} more'),
                      ),
                  ],
                ),
        ),
      ),
      if (scan.videos.isEmpty)
        SliverToBoxAdapter(
          child: _folders.folderExists(dir)
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
      // Series: files whose names carry an episode number; a header
      // click opens or closes its episodes.
      SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final (group, v) = rows[i];
          if (v == null) {
            final id = seriesId(group);
            return SeriesHeader(
              key: ValueKey('series:${group.key}'),
              group: group,
              thumbs: _thumbs,
              expanded: _expanded.contains(id),
              onTap: () => setState(() => _expanded.contains(id) ? _expanded.remove(id) : _expanded.add(id)),
            );
          }
          return _menuable(
              v.path,
              FileRow(
                key: ValueKey(v.path),
                path: v.path,
                title: v.parsed.label.isEmpty ? v.parsed.series : v.parsed.label,
                subtitle: v.name,
                size: formatSize(v.size),
                state: _stateOf(v.path),
                thumbs: _thumbs,
                onTap: _tapOf(v.path),
              ));
        },
      ),
      // Everything else (movies, clips) as a thumbnail grid.
      if (loose.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 22, bottom: 10),
            child: Text(
              series == 0 ? 'Videos' : 'Other videos',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
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
            itemCount: loose.length,
            itemBuilder: (context, i) {
              final v = loose[i];
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
}

/// A Recent entry: `Series · S01E03` over the file name, or the cleaned
/// title over its folder; greyed when the file is gone.
class _RecentRow extends StatefulWidget {
  final String path;
  final PlayState state;
  final ThumbCache thumbs;
  final VoidCallback? onTap;
  final VoidCallback onRemove;
  const _RecentRow({
    super.key,
    required this.path,
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
    final p = parseReleaseName(baseName(path));
    final missing = _stat?.type == FileSystemEntityType.notFound;
    final episode = p.episode != null || p.extra != null;
    return FileRow(
      path: path,
      title: episode ? '${p.series} · ${p.label}' : cleanTitle(p),
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
