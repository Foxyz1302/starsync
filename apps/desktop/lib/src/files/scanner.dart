import 'dart:io';
import 'dart:isolate';

import 'name_parser.dart';

// Folder scan for the Files source: videos with their parsed names,
// sidecar subtitles, everything else counted and hidden. The walk is
// synchronous I/O, so it runs in its own isolate.

const videoExtensions = {
  'mkv', 'mp4', 'webm', 'avi', 'mov', 'm4v', 'ts', 'm2ts', 'wmv', 'flv', //
};
const subtitleExtensions = {'ass', 'ssa', 'srt', 'vtt', 'sup'};

/// Files looked at per scan; past this the result is [FolderScan.truncated].
const maxScannedFiles = 20000;

/// Samples and trailers under this size are hidden next to the real thing.
const _sampleMaxBytes = 300 << 20;

enum FileKind { video, subtitle, other }

FileKind kindOf(String path) {
  final ext = _extension(_baseName(path));
  if (videoExtensions.contains(ext)) return FileKind.video;
  if (subtitleExtensions.contains(ext)) return FileKind.subtitle;
  return FileKind.other;
}

class VideoFile {
  final String path;
  final int size;
  final ParsedName parsed;
  final DateTime modified;
  const VideoFile(this.path, this.size, this.parsed, this.modified);

  String get name => _baseName(path);
}

class FolderScan {
  final List<VideoFile> videos;
  /// Non-video files and samples (subtitles and dot-entries not counted).
  final int hiddenCount;
  /// Up to 6 of the hidden file names, for "and N other files" hints.
  final List<String> hiddenExamples;
  /// Video path -> subtitle files next to it with the same base name
  /// (`Ep 01.mkv` -> `Ep 01.srt`, `Ep 01.en.ass`).
  final Map<String, List<String>> subtitles;
  /// Stopped after [maxScannedFiles] files.
  final bool truncated;

  const FolderScan({
    required this.videos,
    required this.hiddenCount,
    required this.hiddenExamples,
    required this.subtitles,
    required this.truncated,
  });

  static const empty = FolderScan(
    videos: [],
    hiddenCount: 0,
    hiddenExamples: [],
    subtitles: {},
    truncated: false,
  );
}

/// Scans [dir] recursively off the UI isolate. Symlinks are not followed,
/// hidden (dot) files and folders are skipped, unreadable subfolders are
/// left out; never throws (a missing folder is [FolderScan.empty]).
Future<FolderScan> scanFolder(String dir, {int maxFiles = maxScannedFiles}) =>
    Isolate.run(() => scanFolderSync(dir, maxFiles: maxFiles))
        .catchError((Object _) => FolderScan.empty);

/// The walk behind [scanFolder]; blocks, so call it from an isolate.
FolderScan scanFolderSync(String dir, {int maxFiles = maxScannedFiles}) {
  final videos = <VideoFile>[];
  final subs = <String>[];
  final examples = <String>[];
  var hidden = 0, seen = 0;
  var truncated = false;
  final pending = [Directory(dir)];
  walk:
  while (pending.isNotEmpty) {
    final List<FileSystemEntity> entries;
    try {
      entries = pending.removeLast().listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = _baseName(e.path);
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        pending.add(e);
        continue;
      }
      if (e is! File) continue; // links
      if (++seen > maxFiles) {
        truncated = true;
        break walk;
      }
      final kind = kindOf(name);
      if (kind == FileKind.subtitle) {
        subs.add(e.path);
        continue;
      }
      FileStat? stat;
      if (kind == FileKind.video) {
        try {
          stat = e.statSync();
        } catch (_) {}
      }
      final size = stat?.size ?? 0;
      final lower = name.toLowerCase();
      final sample = kind == FileKind.video &&
          (lower.contains('sample') || lower.contains('trailer')) &&
          size < _sampleMaxBytes;
      if (kind != FileKind.video || sample) {
        hidden++;
        if (examples.length < 6) examples.add(name);
        continue;
      }
      videos.add(VideoFile(e.path, size, parseReleaseName(name),
          stat?.modified ?? DateTime.fromMillisecondsSinceEpoch(0)));
    }
  }
  return FolderScan(
    videos: videos,
    hiddenCount: hidden,
    hiddenExamples: examples,
    subtitles: _sidecars(videos, subs),
    truncated: truncated,
  );
}

/// Subtitles in the same folder whose name is the video's base name,
/// optionally followed by `.lang` / `.forced` style suffixes.
Map<String, List<String>> _sidecars(List<VideoFile> videos, List<String> subs) {
  final byStem = <String, List<String>>{};
  for (final s in subs) {
    final stem = _stripExtension(s);
    byStem.putIfAbsent(stem, () => []).add(s);
    // `Ep 01.en.ass`, `Ep 01.en.forced.ass`: also index the shorter stems.
    var shorter = stem;
    for (var i = 0; i < 2; i++) {
      final dot = shorter.lastIndexOf('.');
      if (dot <= shorter.lastIndexOf(RegExp(r'[/\\]')) + 1) break;
      final suffix = shorter.substring(dot + 1);
      // Language / flag tags only (en, eng, pt-BR, forced, sdh): a suffix
      // with digits is part of the name (`Show.S01E01.srt` is not `Show`'s).
      if (!RegExp(r'^[A-Za-z]{2,8}(-[A-Za-z]{2,4})?$').hasMatch(suffix)) break;
      shorter = shorter.substring(0, dot);
      byStem.putIfAbsent(shorter, () => []).add(s);
    }
  }
  return {
    for (final v in videos)
      if (byStem[_stripExtension(v.path)] case final list?)
        v.path: (list.toSet().toList()..sort()),
  };
}

/// One show: its episodes in season/episode order plus its extras
/// (NCOP, OVA...) in name order.
class SeriesGroup {
  /// Display title: the most common spelling among the files.
  final String title;
  final String key;
  final List<VideoFile> episodes;
  final List<VideoFile> extras;
  const SeriesGroup(this.title, this.key, this.episodes, this.extras);

  /// Distinct seasons, ascending; files without one count as season 1.
  List<int> get seasons =>
      ({for (final e in episodes) e.parsed.season ?? 1}.toList()..sort());
}

/// [groupBySeries] result: shows, and videos that are not episodes.
class GroupedVideos {
  final List<SeriesGroup> series;
  final List<VideoFile> loose;
  const GroupedVideos(this.series, this.loose);
}

/// Groups videos with an episode number (or an extra marker) by
/// [ParsedName.seriesKey]; the rest (movies, clips) stay loose, by name.
/// An extra whose series has no episodes in the list is loose too.
GroupedVideos groupBySeries(Iterable<VideoFile> videos) {
  final episodes = <String, List<VideoFile>>{};
  final extras = <String, List<VideoFile>>{};
  final loose = <VideoFile>[];
  for (final v in videos) {
    final p = v.parsed;
    final key = p.seriesKey;
    if (p.episode != null && key.isNotEmpty) {
      episodes.putIfAbsent(key, () => []).add(v);
    } else if (p.extra != null && key.isNotEmpty) {
      extras.putIfAbsent(key, () => []).add(v);
    } else {
      loose.add(v);
    }
  }
  for (final e in extras.entries) {
    if (!episodes.containsKey(e.key)) loose.addAll(e.value);
  }
  int byName(VideoFile a, VideoFile b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
  final groups = [
    for (final e in episodes.entries)
      SeriesGroup(
        _commonTitle(e.value),
        e.key,
        e.value..sort(_byEpisode),
        (extras[e.key] ?? [])..sort(byName),
      ),
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return GroupedVideos(groups, loose..sort(byName));
}

int _byEpisode(VideoFile a, VideoFile b) {
  final pa = a.parsed, pb = b.parsed;
  final s = (pa.season ?? 1).compareTo(pb.season ?? 1);
  if (s != 0) return s;
  final e = pa.episode!.compareTo(pb.episode!);
  if (e != 0) return e;
  // Same episode twice (v2, another group): newest release first.
  return b.name.compareTo(a.name);
}

String _commonTitle(List<VideoFile> files) {
  final counts = <String, int>{};
  for (final f in files) {
    counts.update(f.parsed.series, (n) => n + 1, ifAbsent: () => 1);
  }
  return counts.entries
      .reduce((a, b) => b.value > a.value ? b : a)
      .key;
}

String _baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? path : path.substring(i + 1);
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

String _stripExtension(String path) {
  final dot = path.lastIndexOf('.');
  final sep = path.lastIndexOf(RegExp(r'[/\\]'));
  return dot > sep + 1 ? path.substring(0, dot) : path;
}
