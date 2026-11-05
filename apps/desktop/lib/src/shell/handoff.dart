import 'dart:io';

import 'package:flutter/material.dart';

import '../files/scanner.dart' show FileKind, kindOf;
import '../files/ui/file_tiles.dart' show baseName;
import '../screens/home/picked_media.dart' show LinkRelay;

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
  /// Put the (first) video up, or the link (in the Link page's mode).
  putUp,
  /// Add the video's folder (or the folder) to Files and open it.
  addFolder,
  /// Open Library → Link with the URL filled (to see it first, or pick
  /// another way to pass it on).
  openLink,
  /// Add the videos (or the link, in the Link page's mode) to Up next.
  queue,
  /// The same, right after what plays.
  playNext,
}

/// How a link goes up for the others, on the card ([LinkRelay] as the
/// Link page names it).
String handoffLinkWay(LinkRelay r) => switch (r) {
      LinkRelay.me => 'Through you',
      LinkRelay.direct => 'Everyone fetches it',
      LinkRelay.server => 'The server fetches it',
    };

/// The card asking how to open a [Handoff] (videos, a folder or a link);
/// pops the [HandoffAction] chosen. Putting up is one click, like adding
/// to Up next; while something plays for others ([replaces]) Up next is
/// the main button and putting up says it is now.
class HandoffCard extends StatelessWidget {
  final Handoff item;
  /// Nobody else is in the server: videos play, no relay talk.
  final bool alone;
  /// In a server: videos and links can go to Up next.
  final bool queue;
  /// Others are watching something: putting up replaces it for everyone.
  final bool replaces;
  /// How a link goes up for the others (the Link page's mode).
  final LinkRelay linkWay;
  const HandoffCard({
    super.key,
    required this.item,
    required this.alone,
    this.queue = false,
    this.replaces = false,
    this.linkWay = LinkRelay.me,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    void pick(HandoffAction a) => Navigator.of(context).pop(a);
    Widget button(HandoffAction a, IconData icon, String label, {bool primary = false, String? tooltip}) {
      final b = primary
          ? FilledButton.icon(
              key: ValueKey('handoff-${a.name}'), onPressed: () => pick(a), icon: Icon(icon, size: 18), label: Text(label))
          : OutlinedButton.icon(
              key: ValueKey('handoff-${a.name}'), onPressed: () => pick(a), icon: Icon(icon, size: 18), label: Text(label));
      return tooltip == null ? b : Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 500), child: b);
    }

    final many = switch (item) { HandoffVideos(:final paths) => paths.length > 1, _ => false };
    // Replacing what others watch is the bigger step: Up next leads then,
    // and putting up names it.
    final queueFirst = queue && replaces && !alone;
    final putUp = button(
      HandoffAction.putUp,
      Icons.play_arrow,
      alone ? 'Play' : (queueFirst ? 'Put it up now' : 'Put it up'),
      primary: !queueFirst,
      tooltip: queueFirst ? 'Stops what is on and puts this up, for everyone' : null,
    );
    final queueButtons = [
      if (queue) ...[
        button(HandoffAction.queue, Icons.playlist_add_rounded, many ? 'Add all to queue' : 'Add to queue',
            primary: queueFirst),
        button(HandoffAction.playNext, Icons.queue_play_next_rounded, many ? 'Play all next' : 'Play next'),
      ],
    ];
    final actions = queueFirst ? [...queueButtons, putUp] : [putUp, ...queueButtons];

    final (IconData icon, String title, String detail, List<Widget> buttons) = switch (item) {
      HandoffVideos(:final paths) => (
          Icons.movie_outlined,
          baseName(paths.first),
          paths.length > 1 ? 'and ${paths.length - 1} more · the first one goes up' : 'A video on this computer',
          [
            ...actions,
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
          alone ? 'Plays straight from the site' : '${handoffLinkWay(linkWay)} · other ways on the Link page',
          [
            ...actions,
            button(HandoffAction.openLink, Icons.link, alone ? 'Open in Link' : 'Other ways…'),
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
