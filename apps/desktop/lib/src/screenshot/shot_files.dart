import 'dart:io';

// Where a screenshot goes and what it is called: the system's Pictures
// folder / Starsync, named after the show, the episode and the moment
// ("Frieren S01E05 12m34s.png"). Pure but for [screenshotFolder].

/// The folder under Pictures that screenshots go to.
const screenshotFolderName = 'Starsync';

/// A screenshot's file name without extension: [title] (the show, else the
/// media's title; "Starsync" when none), the [episode] tag
/// ([episodeTag]) and the moment ([clockTag]), safe on Linux and Windows.
String screenshotName({required String? title, String? episode, required Duration at}) {
  final t = (title ?? '').trim();
  final parts = [t.isEmpty ? 'Starsync' : t, episodeTag(episode), clockTag(at)];
  return safeFileName(parts.where((p) => p.isNotEmpty).join(' '));
}

final _seasonEpisode = RegExp(r'^S(\d+)\s*E(\d+(?:\.\d+)?)\b', caseSensitive: false);
final _episodeOnly = RegExp(r'^E(\d+(?:\.\d+)?)\b', caseSensitive: false);

/// The now-playing episode line as a file name tag: "S1 E6 · Name" is
/// "S01E06", "E25" stays "E25" (zero-padded to two), an extra keeps its
/// marker ("NCOP1"); '' without one.
String episodeTag(String? episode) {
  final e = (episode ?? '').split(' · ').first.trim();
  if (e.isEmpty) return '';
  String two(String n) => n.contains('.') ? n.padLeft(4, '0') : n.padLeft(2, '0');
  final se = _seasonEpisode.firstMatch(e);
  if (se != null) return 'S${two(se.group(1)!)}E${two(se.group(2)!)}';
  final ep = _episodeOnly.firstMatch(e);
  if (ep != null) return 'E${two(ep.group(1)!)}';
  return e;
}

/// [at] as "12m34s", "1h02m03s" (with hours) or "0m05s".
String clockTag(Duration at) {
  final s = at.isNegative ? 0 : at.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '${h}h${two(m)}m${two(sec)}s' : '${m}m${two(sec)}s';
}

final _unsafe = RegExp(r'[<>:"/\\|?*\x00-\x1F\x7F]');
final _reserved = RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$', caseSensitive: false);

/// [name] as a file name both Linux and Windows take: characters Windows
/// refuses become spaces, runs of spaces one, no leading or trailing
/// spaces or dots, a reserved device name ("CON") gets a "_", at most
/// [maxLength] characters; "Screenshot" when nothing is left.
String safeFileName(String name, {int maxLength = 150}) {
  var s = name.replaceAll(_unsafe, ' ').replaceAll(RegExp(r'\s+'), ' ');
  s = s.replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  if (s.length > maxLength) s = s.substring(0, maxLength).replaceAll(RegExp(r'[\s.]+$'), '');
  if (s.isEmpty) return 'Screenshot';
  if (_reserved.hasMatch(s)) s = '_$s';
  return s;
}

/// The first of "[base].[ext]", "[base] (2).[ext]", "[base] (3).[ext]", …
/// in [dir] that does not [exists] yet.
String uniquePath(String dir, String base, String ext, bool Function(String path) exists) {
  final sep = dir.endsWith('/') || dir.endsWith(r'\') ? '' : Platform.pathSeparator;
  var path = '$dir$sep$base.$ext';
  for (var n = 2; exists(path); n++) {
    path = '$dir$sep$base ($n).$ext';
  }
  return path;
}

/// The Pictures folder from the XDG user dirs file ([userDirs], the text
/// of `~/.config/user-dirs.dirs`): `XDG_PICTURES_DIR="$HOME/Pictures"`
/// with `$HOME` expanded; null when it is not set there (or set to the
/// home folder itself, which is how xdg-user-dirs says "none").
String? xdgPicturesDir(String userDirs, String home) {
  for (final raw in userDirs.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('XDG_PICTURES_DIR=')) continue;
    var v = line.substring('XDG_PICTURES_DIR='.length).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
    if (v.startsWith(r'$HOME')) {
      v = '$home${v.substring(5)}';
    } else if (v.startsWith(r'${HOME}')) {
      v = '$home${v.substring(7)}';
    }
    v = v.replaceAll(RegExp(r'/+$'), '');
    if (!v.startsWith('/') || v == home.replaceAll(RegExp(r'/+$'), '')) return null;
    return v;
  }
  return null;
}

/// The folder screenshots go to: Pictures / Starsync. Linux: the XDG
/// pictures folder ([xdgPicturesDir]), else `~/Pictures`; Windows: the
/// Pictures known folder ([windowsPictures]), else
/// `%USERPROFILE%\Pictures`. Not created here.
Future<String> screenshotFolder({Future<String?> Function()? windowsPictures}) async {
  final env = Platform.environment;
  final sep = Platform.pathSeparator;
  String pictures;
  if (Platform.isWindows) {
    final known = await windowsPictures?.call();
    final profile = env['USERPROFILE'] ?? env['HOMEDRIVE'] ?? 'C:';
    pictures = known != null && known.isNotEmpty ? known : '$profile${sep}Pictures';
  } else {
    final home = env['HOME'] ?? '/';
    final config = env['XDG_CONFIG_HOME'] ?? '$home/.config';
    String? xdg;
    try {
      final f = File('$config/user-dirs.dirs');
      if (await f.exists()) xdg = xdgPicturesDir(await f.readAsString(), home);
    } catch (_) {}
    pictures = xdg ?? '$home/Pictures';
  }
  return '$pictures$sep$screenshotFolderName';
}
