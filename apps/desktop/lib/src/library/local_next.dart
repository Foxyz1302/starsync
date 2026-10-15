import 'dart:io';

import 'package:sync_relay_core/core.dart';

import '../files/scanner.dart' show FolderScan;
import 'show_matcher.dart';

// The next episode of a local show (the library's `nextAfter`, numbers
// skipped on the way included): what continues a file this app put up
// (see ARCHITECTURE.md "What's next").

/// [path]'s next episode: from the library the Files page saw this run
/// ([ShowMatcher.showAt]), else from the file's own folder read now (one
/// [scan], grouped by `groupLocal` with that folder's name as a hint). Null when there is none (the last
/// episode, not an episode, an unreadable folder).
class LocalNextFinder {
  final ShowMatcher matcher;
  final Future<FolderScan> Function(String dir) scan;
  LocalNextFinder({required this.matcher, required this.scan});

  Future<LocalNext?> nextAfter(String path) async {
    var show = matcher.showAt(path);
    if (show == null) {
      final dir = File(path).parent.path;
      final found = await scan(dir);
      // The folder itself is a hint (a bare `01.mkv` in `Bleach`).
      final lib = groupLocal(found.videos, roots: [Directory(dir).parent.path]);
      show = lib.shows.where((s) => s.files.any((e) => e.path == path)).firstOrNull;
    }
    final at = show?.files.where((e) => e.path == path).firstOrNull;
    if (show == null || at == null || at.kind != LocalKind.episode) return null;
    return show.nextAfter(at.key);
  }
}
