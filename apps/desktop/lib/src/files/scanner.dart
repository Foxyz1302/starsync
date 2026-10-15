import 'dart:io';
import 'dart:isolate';

import 'package:sync_relay_core/core.dart';

export 'package:sync_relay_core/core.dart' show FileKind, LocalFile, kindOf, subtitleExtensions, videoExtensions;

// Folder scan for the Files source: the videos (grouped into shows by
// core's `groupLocal`, L1), sidecar subtitles, everything else counted
// and hidden. The walk is synchronous I/O, so it runs in its own isolate.

/// Files looked at per scan; past this the result is [FolderScan.truncated].
const maxScannedFiles = 20000;

/// Samples and trailers under this size are hidden next to the real thing.
const _sampleMaxBytes = 300 << 20;

class FolderScan {
  final List<LocalFile> videos;
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
  final videos = <LocalFile>[];
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
      videos.add(LocalFile(e.path, size, stat?.modified ?? DateTime.fromMillisecondsSinceEpoch(0)));
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
Map<String, List<String>> _sidecars(List<LocalFile> videos, List<String> subs) {
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

String _baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? path : path.substring(i + 1);
}

String _stripExtension(String path) {
  final dot = path.lastIndexOf('.');
  final sep = path.lastIndexOf(RegExp(r'[/\\]'));
  return dot > sep + 1 ? path.substring(0, dot) : path;
}
