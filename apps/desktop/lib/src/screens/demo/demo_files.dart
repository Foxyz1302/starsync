part of 'shell_demo.dart';

// DEBUG ONLY: the Files source for real. Folders you add are scanned for
// videos (everything else is counted and hidden), grouped into series by
// a small anitomy-style name parser; a click plays the file in the demo
// player. Kept in memory for the demo session.

const _videoExt = {
  'mkv',
  'mp4',
  'webm',
  'avi',
  'mov',
  'm4v',
  'ts',
  'm2ts',
  'wmv',
  'flv',
};
const _subExt = {'ass', 'ssa', 'srt', 'vtt', 'sup'};

class _VideoFile {
  final String path;
  final int size;
  final _ParsedName parsed;
  const _VideoFile(this.path, this.size, this.parsed);
  String get name => _baseName(path);
  String get folder => _baseName(File(path).parent.path);
}

class _FolderScan {
  final List<_VideoFile> videos;
  final int hidden;
  final int subtitles;
  final List<String> hiddenExamples;
  final bool truncated;
  const _FolderScan(
    this.videos,
    this.hidden,
    this.subtitles,
    this.hiddenExamples,
    this.truncated,
  );
}

final _folders = ValueNotifier<List<String>>([]);
final _scans = <String, _FolderScan>{};
final _recentFiles = ValueNotifier<List<_VideoFile>>([]);

/// What a release file name says: series, season, episode, group.
class _ParsedName {
  final String series;
  final int? season;
  final int? episode;
  final String? group;
  const _ParsedName(this.series, {this.season, this.episode, this.group});

  String get label {
    if (episode == null) return series;
    final ep = 'E${episode.toString().padLeft(2, '0')}';
    return season == null ? ep : 'S${season.toString().padLeft(2, '0')}$ep';
  }
}

_ParsedName _parseName(String file) {
  var s = file;
  final dot = s.lastIndexOf('.');
  if (dot > 0) s = s.substring(0, dot);
  final group = RegExp(r'^\s*\[([^\]]+)\]').firstMatch(s)?.group(1);
  // Brackets/parens hold group, resolution, codec, CRC.
  s = s.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), ' ');
  // Dots/underscores as separators (scene style), unless it has spaces.
  if (!s.contains(' ') || RegExp(r'\w\.\w').allMatches(s).length > 2) {
    s = s.replaceAll(RegExp(r'[._]'), ' ');
  }
  int? season, episode;
  var cut = s.length;
  final se = RegExp(
    r'\bS(\d{1,2})\s?E(\d{1,4})\b',
    caseSensitive: false,
  ).firstMatch(s);
  if (se != null) {
    season = int.parse(se.group(1)!);
    episode = int.parse(se.group(2)!);
    cut = se.start;
  } else {
    final dash = RegExp(r'\s-\s(\d{1,4})(?:v\d)?\b').firstMatch(s);
    final ep = RegExp(
      r'\b(?:E|EP|Episode)\s?(\d{1,4})\b',
      caseSensitive: false,
    ).firstMatch(s);
    final m = dash ?? ep;
    if (m != null) {
      episode = int.parse(m.group(1)!);
      cut = m.start;
    }
  }
  var series = s.substring(0, cut);
  // Season markers inside the title ("Title S2", "Title 2nd Season").
  final sInTitle = RegExp(
    r'\s(?:S(\d{1,2})|(\d)(?:st|nd|rd|th) Season)\s*$',
    caseSensitive: false,
  ).firstMatch(series);
  if (sInTitle != null && season == null) {
    season = int.parse(sInTitle.group(1) ?? sInTitle.group(2)!);
  }
  // Release junk after the title.
  series = series
      .replaceAll(
        RegExp(
          r'\b(1080p|720p|2160p|480p|x26[45]|HEVC|WEB(-?DL|Rip)?|BD(Rip)?|BluRay|AAC|FLAC|10bit)\b.*',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[\s\-–:]+$'), '')
      .trim();
  if (series.isEmpty) series = file;
  return _ParsedName(series, season: season, episode: episode, group: group);
}

Future<_FolderScan> _scanFolder(String dir) async {
  final videos = <_VideoFile>[];
  var hidden = 0, subs = 0;
  final examples = <String>[];
  var seen = 0;
  var truncated = false;
  try {
    await for (final e in Directory(
      dir,
    ).list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (++seen > 20000) {
        truncated = true;
        break;
      }
      final name = e.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (_subExt.contains(ext)) {
        subs++;
        continue;
      }
      final isVideo = _videoExt.contains(ext);
      final lower = name.toLowerCase();
      int size = 0;
      try {
        size = await e.length();
      } catch (_) {}
      // Samples and trailers next to the real thing.
      final junk =
          isVideo &&
          (lower.contains('sample') || lower.contains('trailer')) &&
          size < 300 << 20;
      if (!isVideo || junk) {
        hidden++;
        if (examples.length < 6) examples.add(name);
        continue;
      }
      videos.add(_VideoFile(e.path, size, _parseName(name)));
    }
  } catch (_) {
    // Unreadable subfolders: show what was found.
  }
  return _FolderScan(videos, hidden, subs, examples, truncated);
}

String _size(int b) => b >= 1 << 30
    ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
    : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

class _RealFilesTab extends StatefulWidget {
  final bool online;
  final VoidCallback onPlay;
  const _RealFilesTab({required this.online, required this.onPlay});

  @override
  State<_RealFilesTab> createState() => _RealFilesTabState();
}

class _RealFilesTabState extends State<_RealFilesTab> {
  String? _open; // null = Recent
  bool _scanning = false;
  bool _showOther = false;

  Future<void> _addFolder() async {
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Add a folder with videos',
      );
    } catch (_) {}
    if (dir == null || _folders.value.contains(dir)) return;
    _folders.value = [..._folders.value, dir];
    await _select(dir, rescan: true);
  }

  Future<void> _select(String? dir, {bool rescan = false}) async {
    setState(() {
      _open = dir;
      _showOther = false;
    });
    if (dir == null || (_scans.containsKey(dir) && !rescan)) return;
    setState(() => _scanning = true);
    final scan = await _scanFolder(dir);
    if (!mounted) return;
    setState(() {
      _scans[dir] = scan;
      _scanning = false;
    });
  }

  Future<void> _browse() async {
    List<PlatformFile> files = const [];
    try {
      files = await FilePicker.pickFiles(
        dialogTitle: 'Pick a video',
        type: FileType.custom,
        allowedExtensions: _videoExt.toList(),
      );
    } catch (_) {}
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return;
    final f = File(path);
    await _play(
      _VideoFile(path, await f.length(), _parseName(f.uri.pathSegments.last)),
    );
  }

  Future<void> _play(_VideoFile v) async {
    _recentFiles.value = [
      v,
      ..._recentFiles.value.where((x) => x.path != v.path),
    ].take(30).toList();
    // Structured names read as "Series · S01E03"; anything else as the
    // cleaned name and the folder it is in.
    await _playMedia(
      _DemoMedia(
        v.parsed.series,
        v.parsed.episode == null ? v.folder : v.parsed.label,
        v.path,
      ),
    );
    widget.onPlay();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 700;
        final list = _list(context, narrow);
        if (narrow) return list;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 260, child: _sidebar(context)),
            Expanded(child: list),
          ],
        );
      },
    );
  }

  Widget _sidebar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: _folders,
      builder: (context, folders, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 8, 20),
        children: [
          const Text('Folders', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ListTile(
            dense: true,
            selected: _open == null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            leading: const Icon(Icons.history, size: 18),
            title: const Text('Recent'),
            onTap: () => _select(null),
          ),
          for (final f in folders)
            ListTile(
              dense: true,
              selected: _open == f,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              leading: const Icon(Icons.folder_outlined, size: 18),
              title: Text(
                _baseName(f),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _scans[f] == null
                    ? 'scanning…'
                    : '${_scans[f]!.videos.length} videos',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
              ),
              trailing: IconButton(
                tooltip: 'Remove folder',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () {
                  _folders.value = [...folders]..remove(f);
                  _scans.remove(f);
                  if (_open == f) _select(null);
                },
              ),
              onTap: () => _select(f),
            ),
          TextButton.icon(
            onPressed: _addFolder,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add folder'),
          ),
          const Divider(),
          OutlinedButton.icon(
            onPressed: _browse,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Browse…'),
          ),
          const SizedBox(height: 6),
          const Text(
            'The system file picker, for anything outside your folders.',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, bool narrow) {
    final scheme = Theme.of(context).colorScheme;
    final open = _open;
    final scan = open == null ? null : _scans[open];
    final children = <Widget>[
      // Where you are: Recent, or the folder and its path.
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            Icon(
              open == null ? Icons.history : Icons.folder,
              color: scheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    open == null ? 'Recent' : _baseName(open),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  if (open != null)
                    Text(
                      open,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      if (narrow)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: ValueListenableBuilder(
            valueListenable: _folders,
            builder: (context, folders, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Recent'),
                  selected: open == null,
                  onSelected: (_) => _select(null),
                ),
                for (final f in folders)
                  ChoiceChip(
                    label: Text(_baseName(f)),
                    selected: open == f,
                    onSelected: (_) => _select(f),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('Folder'),
                  onPressed: _addFolder,
                ),
                ActionChip(
                  avatar: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Browse…'),
                  onPressed: _browse,
                ),
              ],
            ),
          ),
        ),
      if (widget.online)
        Container(
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
                  'Files stream from this computer through the server. Keep the app open while it plays.',
                ),
              ),
            ],
          ),
        ),
    ];
    if (open == null) {
      children.add(
        ValueListenableBuilder(
          valueListenable: _recentFiles,
          builder: (context, recent, _) => recent.isEmpty
              ? _empty(
                  context,
                  Icons.video_library_outlined,
                  'Nothing played yet',
                  'Add a folder with your videos, or Browse for a single file.',
                  action: FilledButton.icon(
                    onPressed: _addFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Add folder'),
                  ),
                )
              : Column(
                  children: [
                    for (final v in recent)
                      _episodeTile(context, v, showSeries: true),
                  ],
                ),
        ),
      );
    } else if (_scanning || scan == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.only(top: 60),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    } else {
      final groups = <String, List<_VideoFile>>{};
      for (final v in scan.videos) {
        groups.putIfAbsent(v.parsed.series, () => []).add(v);
      }
      final names = groups.keys.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      for (final g in groups.values) {
        g.sort((a, b) {
          final s = (a.parsed.season ?? 0).compareTo(b.parsed.season ?? 0);
          if (s != 0) return s;
          final e = (a.parsed.episode ?? 0).compareTo(b.parsed.episode ?? 0);
          return e != 0 ? e : a.name.compareTo(b.name);
        });
      }
      children.add(
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(
              Icons.filter_alt_outlined,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              '${scan.videos.length} videos in ${groups.length} series'
              '${scan.hidden > 0 ? ' · ${scan.hidden} other files hidden' : ''}'
              '${scan.subtitles > 0 ? ' · ${scan.subtitles} subtitle files' : ''}'
              '${scan.truncated ? ' · stopped after 20 000 files' : ''}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            if (scan.hidden > 0) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _showOther = !_showOther),
                child: Text(_showOther ? 'Hide them' : 'Show some'),
              ),
            ],
            TextButton.icon(
              onPressed: () => _select(open, rescan: true),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Rescan'),
            ),
          ],
        ),
      );
      children.add(
        AnimatedSize(
          duration: _easeTime,
          curve: _ease,
          alignment: Alignment.topLeft,
          child: !_showOther
              ? const SizedBox(width: double.infinity)
              : Column(
                  children: [
                    for (final f in scan.hiddenExamples)
                      ListTile(
                        dense: true,
                        enabled: false,
                        leading: const Icon(
                          Icons.insert_drive_file_outlined,
                          size: 18,
                        ),
                        title: Text(f),
                        trailing: const Text(
                          'not a video',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
        ),
      );
      if (scan.videos.isEmpty) {
        children.add(
          _empty(
            context,
            Icons.search_off,
            'No videos here',
            'Only video files are listed (mkv, mp4, webm…).',
          ),
        );
      }
      // Series: files whose names carry an episode number. Everything
      // else is a loose video, shown as a thumbnail grid.
      final loose = <_VideoFile>[];
      for (final name in names) {
        final eps = groups[name]!;
        if (eps.every((e) => e.parsed.episode == null)) {
          loose.addAll(eps);
          continue;
        }
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 4),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _Thumb(eps.first.path, width: 96, height: 54),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${eps.length} ${eps.length == 1 ? 'episode' : 'episodes'}'
                        '${eps.first.parsed.group == null ? '' : ' · ${eps.first.parsed.group}'}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
        for (final v in eps) {
          children.add(_episodeTile(context, v));
        }
      }
      if (loose.isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 22, bottom: 10),
            child: Text(
              names.length == loose.length ? 'Videos' : 'Other videos',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        );
        children.add(
          LayoutBuilder(
            builder: (context, box) {
              const gap = 12.0;
              final cols = (box.maxWidth / 240).floor().clamp(2, 8);
              final w = (box.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final v in loose)
                    SizedBox(width: w, child: _videoCard(context, v)),
                ],
              );
            },
          ),
        );
      }
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(narrow ? 20 : 12, 20, 20, 20),
      children: children,
    );
  }

  Widget _episodeTile(
    BuildContext context,
    _VideoFile v, {
    bool showSeries = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: _nowPlaying,
      builder: (context, now, _) {
        final playing = now?.path == v.path;
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: showSeries ? 0 : 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          selected: playing,
          leading: SizedBox(
            width: 112,
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _Thumb(v.path, width: 80, height: 45),
                ),
                const SizedBox(width: 8),
                Icon(
                  playing ? Icons.graphic_eq : Icons.play_circle_outline,
                  size: 20,
                  color: scheme.primary,
                ),
              ],
            ),
          ),
          minLeadingWidth: 112,
          title: Text(
            showSeries
                ? '${v.parsed.series} · ${v.parsed.label}'
                : v.parsed.label,
          ),
          subtitle: Text(
            showSeries && v.parsed.episode == null ? v.folder : v.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            _size(v.size),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          onTap: () => _play(v),
        );
      },
    );
  }

  Widget _videoCard(BuildContext context, _VideoFile v) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: _nowPlaying,
      builder: (context, now, _) {
        final playing = now?.path == v.path;
        return InkWell(
          onTap: () => _play(v),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: playing ? scheme.primary : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _Thumb(v.path),
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: _DurationBadge(v.path),
                        ),
                        if (playing)
                          const Center(
                            child: Icon(
                              Icons.graphic_eq,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                v.parsed.series,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: playing ? scheme.primary : null,
                ),
              ),
              Text(
                _size(v.size),
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(
    BuildContext context,
    IconData icon,
    String title,
    String sub, {
    Widget? action,
  }) => Padding(
    padding: const EdgeInsets.only(top: 60),
    child: Column(
      children: [
        Icon(
          icon,
          size: 44,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 10),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(sub, style: const TextStyle(color: Colors.grey)),
        if (action != null) ...[const SizedBox(height: 14), action],
      ],
    ),
  );
}

String _baseName(String path) {
  final parts = path
      .split(RegExp(r'[/\\]'))
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isEmpty ? path : parts.last;
}

// ------------------------------------------------------------ thumbnails
//
// Demo: ffmpeg/ffprobe when installed (a frame at 25%, cached in the temp
// dir). The real app would ask mpv for the frame instead (no extra tool).

class _ThumbInfo {
  final File? image;
  final Duration? duration;
  const _ThumbInfo(this.image, this.duration);
}

final _thumbs = <String, Future<_ThumbInfo>>{};
var _thumbRunning = 0;
final _thumbQueue = <Completer<void>>[];

Future<_ThumbInfo> _thumbFor(String path) =>
    _thumbs.putIfAbsent(path, () async {
      // At most 3 ffmpeg runs at a time.
      if (_thumbRunning >= 3) {
        final c = Completer<void>();
        _thumbQueue.add(c);
        await c.future;
      }
      _thumbRunning++;
      try {
        return await _makeThumb(path);
      } finally {
        _thumbRunning--;
        if (_thumbQueue.isNotEmpty) _thumbQueue.removeAt(0).complete();
      }
    });

Future<_ThumbInfo> _makeThumb(String path) async {
  Duration? dur;
  try {
    final r = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'csv=p=0',
      path,
    ]);
    final secs = double.tryParse('${r.stdout}'.trim());
    if (secs != null) dur = Duration(milliseconds: (secs * 1000).round());
  } catch (_) {
    return const _ThumbInfo(null, null); // no ffmpeg on this machine
  }
  final dir = Directory('${Directory.systemTemp.path}/wt-demo-thumbs')
    ..createSync(recursive: true);
  final key = path.hashCode.toUnsigned(32).toRadixString(16);
  final out = File('${dir.path}/$key.jpg');
  if (out.existsSync() && out.lengthSync() > 0) return _ThumbInfo(out, dur);
  final at = dur == null ? 5.0 : dur.inMilliseconds / 1000 * 0.25;
  try {
    final r = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-y',
      '-ss',
      at.toStringAsFixed(2),
      '-i',
      path,
      '-frames:v',
      '1',
      '-vf',
      'scale=480:-2',
      '-q:v',
      '4',
      out.path,
    ]);
    if (r.exitCode == 0 && out.existsSync()) return _ThumbInfo(out, dur);
  } catch (_) {}
  return _ThumbInfo(null, dur);
}

class _Thumb extends StatelessWidget {
  final String path;
  final double? width, height;
  const _Thumb(this.path, {this.width, this.height});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.movie_outlined,
        color: scheme.onSurfaceVariant,
        size: 20,
      ),
    );
    return FutureBuilder<_ThumbInfo>(
      future: _thumbFor(path),
      builder: (context, snap) {
        final img = snap.data?.image;
        return AnimatedSwitcher(
          duration: _easeTime,
          child: img == null
              ? placeholder
              : Image.file(
                  img,
                  key: ValueKey(img.path),
                  width: width,
                  height: height,
                  fit: BoxFit.cover,
                ),
        );
      },
    );
  }
}

class _DurationBadge extends StatelessWidget {
  final String path;
  const _DurationBadge(this.path);

  @override
  Widget build(BuildContext context) => FutureBuilder<_ThumbInfo>(
    future: _thumbFor(path),
    builder: (context, snap) {
      final d = snap.data?.duration;
      if (d == null) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          _fmt(d),
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      );
    },
  );
}
