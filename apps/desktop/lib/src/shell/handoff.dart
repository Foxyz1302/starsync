import 'dart:io';

import 'package:flutter/material.dart';

import '../files/scanner.dart' show FileKind, kindOf;
import '../files/ui/file_tiles.dart' show baseName;

// Something handed to the app, by a drop or by Ctrl+V outside a text
// field: what it is ([classifyHandoff], pure) and the small card that asks
// how to open it ([HandoffCard]). The shell wires both.

/// Open overlays over the shell that take drops and pastes themselves
/// (the Up next popover, which is not a route): the shell's own handoff
/// stays off while any is open.
int handoffHolds = 0;

/// What was dropped or pasted.
sealed class Handoff {
  const Handoff();
}

/// Video files (by the Files page's extensions), in the order given.
final class HandoffVideos extends Handoff {
  final List<String> paths;
  const HandoffVideos(this.paths);
}

final class HandoffFolder extends Handoff {
  final String path;
  const HandoffFolder(this.path);
}

/// An http(s) link.
final class HandoffLink extends Handoff {
  final String url;
  const HandoffLink(this.url);
}

/// An image file. Nothing takes one yet; the shell ignores it.
final class HandoffImage extends Handoff {
  final String path;
  const HandoffImage(this.path);
}

final class HandoffNothing extends Handoff {
  const HandoffNothing();
}

const _imageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'};

final _link = RegExp(r'^https?://\S+$', caseSensitive: false);
final _windowsAbsolute = RegExp(r'^([A-Za-z]:[\\/]|\\\\)');

bool _absolute(String p) => p.startsWith('/') || _windowsAbsolute.hasMatch(p);

/// A `file://` URI as a path; anything else as is.
String _pathOf(String p) {
  if (!p.startsWith('file://')) return p;
  try {
    return Uri.parse(p).toFilePath();
  } catch (_) {
    return p;
  }
}

/// Classifies dropped or pasted [paths] (files first) or, when there are
/// none, pasted [text]: a link, or one absolute path (or `file://` URI) per
/// line. Videos win over folders, folders over images; paths that do not
/// exist ([typeOf], defaults to the file system) count for nothing.
Handoff classifyHandoff({
  List<String> paths = const [],
  String? text,
  FileSystemEntityType Function(String path)? typeOf,
}) {
  final type = typeOf ?? (p) => FileSystemEntity.typeSync(p);
  var list = [for (final p in paths) if (p.trim().isNotEmpty) _pathOf(p.trim())];
  if (list.isEmpty && text != null) {
    final t = text.trim();
    if (_link.hasMatch(t)) return HandoffLink(t);
    final lines = [for (final l in t.split(RegExp(r'[\r\n]+'))) if (l.trim().isNotEmpty) _pathOf(l.trim())];
    if (lines.isEmpty || !lines.every(_absolute)) return const HandoffNothing();
    list = lines;
  }
  final types = {for (final p in list) p: type(p)};
  bool file(String p) => types[p] == FileSystemEntityType.file;
  final videos = [for (final p in list) if (file(p) && kindOf(p) == FileKind.video) p];
  if (videos.isNotEmpty) return HandoffVideos(videos);
  for (final p in list) {
    if (types[p] == FileSystemEntityType.directory) return HandoffFolder(p);
  }
  for (final p in list) {
    final dot = p.lastIndexOf('.');
    if (file(p) && dot >= 0 && _imageExtensions.contains(p.substring(dot + 1).toLowerCase())) {
      return HandoffImage(p);
    }
  }
  return const HandoffNothing();
}

/// What the card's buttons ask the shell to do.
enum HandoffAction {
  /// Put the (first) video up (offline: watch it solo).
  putUp,
  /// Add the video's folder (or the folder) to Files and open it.
  addFolder,
  /// Open Library → Link with the URL filled.
  openLink,
  /// Add the videos (or the link, in the Link page's mode) to Up next.
  queue,
  /// The same, right after what plays.
  playNext,
}

/// The card asking how to open a [Handoff] (videos, a folder or a link);
/// pops the [HandoffAction] chosen.
class HandoffCard extends StatelessWidget {
  final Handoff item;
  /// Nobody else watches (offline or solo): videos play, no relay talk.
  final bool solo;
  /// In a server: videos and links can go to Up next.
  final bool queue;
  const HandoffCard({super.key, required this.item, required this.solo, this.queue = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    void pick(HandoffAction a) => Navigator.of(context).pop(a);
    Widget button(HandoffAction a, IconData icon, String label, {bool primary = false}) => primary
        ? FilledButton.icon(
            key: ValueKey('handoff-${a.name}'), onPressed: () => pick(a), icon: Icon(icon, size: 18), label: Text(label))
        : OutlinedButton.icon(
            key: ValueKey('handoff-${a.name}'), onPressed: () => pick(a), icon: Icon(icon, size: 18), label: Text(label));
    final many = switch (item) { HandoffVideos(:final paths) => paths.length > 1, _ => false };
    final queueButtons = [
      if (queue) ...[
        button(HandoffAction.queue, Icons.playlist_add_rounded, many ? 'Add all to queue' : 'Add to queue'),
        button(HandoffAction.playNext, Icons.queue_play_next_rounded, many ? 'Play all next' : 'Play next'),
      ],
    ];

    final (IconData icon, String title, String detail, List<Widget> buttons) = switch (item) {
      HandoffVideos(:final paths) => (
          Icons.movie_outlined,
          baseName(paths.first),
          paths.length > 1 ? 'and ${paths.length - 1} more · the first one goes up' : 'A video on this computer',
          [
            button(HandoffAction.putUp, Icons.play_arrow, solo ? 'Play' : 'Put it up', primary: true),
            ...queueButtons,
            button(HandoffAction.addFolder, Icons.create_new_folder_outlined, 'Add its folder to Files'),
          ],
        ),
      HandoffFolder(:final path) => (
          Icons.folder_outlined,
          baseName(path),
          path,
          [button(HandoffAction.addFolder, Icons.create_new_folder_outlined, 'Add to Files', primary: true)],
        ),
      HandoffLink(:final url) => (
          Icons.link,
          url,
          solo ? 'Opens it on the Link page' : 'Pick how the others get it on the Link page',
          [
            button(HandoffAction.openLink, Icons.link, solo ? 'Open in Link' : 'Put it up as a link…',
                primary: true),
            ...queueButtons,
          ],
        ),
      HandoffImage() || HandoffNothing() => (Icons.help_outline, '', '', const <Widget>[]),
    };
    return Material(
      key: const ValueKey('handoff-card'),
      elevation: 12,
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall),
                        Text(detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: buttons),
            ],
          ),
        ),
      ),
    );
  }
}
