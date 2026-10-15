import 'dart:convert';
import 'dart:io';

// First start of the renamed app (Starsync, app id dev.foxyz.starsync):
// copy what the old names left, never move, so a 1.2.x install keeps
// working next to it. Runs once (the marker file), then never again.

/// Written into the new support folder once the migration ran (whether or
/// not anything was found): `migratedFrom` (the old support folder or
/// null), `hiveFrom` (the folder the boxes came from or null), `boxes`,
/// `files`.
const migrationMarker = 'migration.json';

/// The Hive boxes the app opens, by name (settings, connect form, Files,
/// Jellyfin sign-ins, track choices). Only these leave the documents
/// folder, which other apps' boxes share.
const appHiveBoxes = ['settings', 'connect_form', 'files', 'jellyfin', 'track_prefs'];

/// Support folders of the old names for the new [support] folder, the
/// most likely first. Linux: `$XDG_DATA_HOME/moe.senkochan.watch_together`
/// (the GTK application id up to 1.2.x), then `watch_together` (the
/// executable name path_provider falls back to). Windows:
/// `%APPDATA%\com.example\watch_together` (company and product name of
/// the exe up to 1.2.x).
List<String> legacySupportDirs(String support, {bool? windows}) {
  final win = windows ?? Platform.isWindows;
  final sep = win ? r'\' : '/';
  String parent(String p) {
    final norm = p.endsWith(sep) ? p.substring(0, p.length - 1) : p;
    final i = norm.lastIndexOf(sep);
    return i <= 0 ? norm : norm.substring(0, i);
  }

  if (win) return ['${parent(parent(support))}${sep}com.example${sep}watch_together'];
  final share = parent(support);
  return ['$share${sep}moe.senkochan.watch_together', '$share${sep}watch_together'];
}

/// Copies the first existing [oldSupport] folder into [support] and the
/// [appHiveBoxes] (`.hive` and `.lock`) from [documents] into [hive],
/// skipping anything already there; the originals stay. Once per support
/// folder ([migrationMarker]). Returns one log line per thing copied
/// (paths and counts, never contents); empty when it ran before.
Future<List<String>> migrateLegacyData(
    {required String support, required String hive, required List<String> oldSupport, String? documents}) async {
  final sep = Platform.pathSeparator;
  final marker = File('$support$sep$migrationMarker');
  if (marker.existsSync()) return const [];
  final lines = <String>[];
  String? from;
  var files = 0;
  for (final old in oldSupport) {
    final dir = Directory(old);
    if (!dir.existsSync() || _same(old, support)) continue;
    files = await _copyTree(dir, Directory(support));
    from = old;
    lines.add('migration: copied $files files from $old to $support');
    break;
  }
  final boxes = <String>[];
  if (documents != null && Directory(documents).existsSync() && !_same(documents, hive)) {
    await Directory(hive).create(recursive: true);
    for (final box in appHiveBoxes) {
      for (final ext in const ['hive', 'lock']) {
        final src = File('$documents$sep$box.$ext');
        final dst = File('$hive$sep$box.$ext');
        if (!src.existsSync() || dst.existsSync()) continue;
        await src.copy(dst.path);
        if (ext == 'hive') boxes.add(box);
      }
    }
    if (boxes.isNotEmpty) {
      lines.add('migration: copied ${boxes.length} Hive boxes (${boxes.join(', ')}) from $documents to $hive');
    }
  }
  if (lines.isEmpty) lines.add('migration: no data from before the rename');
  await Directory(support).create(recursive: true);
  await marker.writeAsString(jsonEncode({
    'migratedFrom': from,
    'hiveFrom': boxes.isEmpty ? null : documents,
    'boxes': boxes,
    'files': files,
  }));
  return lines;
}

bool _same(String a, String b) {
  try {
    return FileSystemEntity.identicalSync(a, b);
  } catch (_) {
    return false;
  }
}

// Files (File.copy keeps the mode on POSIX: cookies.txt stays 0600, yt-dlp
// executable) and symlinks as they are; existing targets win.
Future<int> _copyTree(Directory from, Directory to) async {
  var n = 0;
  await to.create(recursive: true);
  await for (final e in from.list(recursive: true, followLinks: false)) {
    final target = '${to.path}${e.path.substring(from.path.length)}';
    if (e is Directory) {
      await Directory(target).create(recursive: true);
    } else if (await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      continue;
    } else if (e is Link) {
      await Directory(File(target).parent.path).create(recursive: true);
      await Link(target).create(await e.target());
    } else if (e is File) {
      await Directory(File(target).parent.path).create(recursive: true);
      await e.copy(target);
      n++;
    }
  }
  return n;
}
