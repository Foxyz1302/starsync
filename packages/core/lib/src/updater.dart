import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'constants.dart';
import 'logging.dart';

// The one updater for both programs: the app (`starsync --upgrade`
// and the in-app update card, via UpdateController) and the dedicated
// server (`starsync-server --upgrade`). Both ship in the same
// release archive, so either one swaps the whole install folder: fetch
// manifest, download, verify sha256, apply over the live install.
//
// Apply stages inside the install root (same filesystem, so every move is
// a rename — /tmp is often tmpfs and rename across filesystems fails).
// Linux: unlinking/renaming files under a running process is fine, only
// opening the running binary for writing is refused (ETXTBSY), so the
// swap moves each top-level bundle entry aside, moves the new one in,
// and rolls everything back on any failure. Windows: a running exe/dll
// can be renamed but not deleted, so in-use files go to `*.old`, new
// files move in, and `*.old` is swept on the next start
// (cleanupUpdateLeftovers). CI runs that against a live exe on NTFS.

final _log = createLogger('update');

/// Where the releases' manifest lives, tried in order ([fetchManifest]):
/// when the server moves, its new address goes first and the old one
/// stays as long as it works, so installs keep updating across the move.
/// Never an address that no longer belongs to the project: whoever owns
/// it next could serve a manifest.
const updateManifestUrls = [
  'https://git.example.org/Foxyz/sync_replay_project/raw/branch/main/updates/manifest.json',
];

/// Test builds (`tool/dev_release.sh`): one Gitea prerelease, tag `dev`,
/// whose assets each run replaces. Only dev builds read it. Tried in
/// order, like [updateManifestUrls].
const devManifestUrls = [
  'https://git.example.org/Foxyz/sync_replay_project/releases/download/dev/manifest.json',
];

const appVersion = String.fromEnvironment('APP_VERSION',
    defaultValue: '0.0.0-dev');

// Key into the manifest's `assets` map, e.g. linux-x64, windows-x64.
final updatePlatform = '${Platform.operatingSystem}-x64';

/// The app's binary in a release bundle (`.exe` on Windows).
const appBinaryName = 'starsync';
/// The dedicated server's binary next to it (`.exe` on Windows).
const serverBinaryName = 'starsync-server';
/// The names up to 1.2.x, which archives up to 1.4.x still carried
/// (launchers on Linux, copies on Windows). No longer shipped:
/// [removeOldNames] deletes them from an install. An install started by
/// one still updates ([applyUpdate] accepts the new name for it) and
/// restarts as the new binary ([relaunchExecutable]).
const legacyAppBinaryName = 'watch_together';
const legacyServerBinaryName = 'watch-together-server';

// For an old binary name, the new one (same extension); else null.
String? _renamedBinary(String name) {
  final exe = name.toLowerCase().endsWith('.exe');
  final stem = exe ? name.substring(0, name.length - 4) : name;
  final renamed = switch (stem) {
    legacyAppBinaryName => appBinaryName,
    legacyServerBinaryName => serverBinaryName,
    _ => null,
  };
  return renamed == null ? null : '$renamed${exe ? name.substring(name.length - 4) : ''}';
}

/// The binary to start after an update replaced [executablePath]: the
/// same one, except that an old name (a launcher, or on Windows a copy
/// of the new binary) gives way to the new binary next to it.
String relaunchExecutable(String executablePath) {
  final norm = executablePath.replaceAll('\\', '/');
  final cut = norm.lastIndexOf('/');
  final renamed = _renamedBinary(norm.substring(cut + 1));
  if (renamed == null) return executablePath;
  final next = '${executablePath.substring(0, cut + 1)}$renamed';
  return File(next).existsSync() ? next : executablePath;
}

const _stagingDir = '.update-staging';
const _backupDir = '.update-backup';
const _downloadFile = '.update-download';

/// What a release changed, in the words of CHANGELOG.md: the manifest's
/// `changes` ({"added": [...], "changed": [...], "fixed": [...]}).
/// Manifests from before it have only `notes`.
class ReleaseChanges {
  final List<String> added;
  final List<String> changed;
  final List<String> fixed;
  const ReleaseChanges({this.added = const [], this.changed = const [], this.fixed = const []});

  /// Null for anything that is not a map, or one with no items; entries
  /// that are not strings (or blank) are dropped, unknown keys ignored.
  static ReleaseChanges? fromJson(Object? json) {
    if (json is! Map) return null;
    List<String> list(String key) => List.unmodifiable([
          if (json[key] case final List l)
            for (final item in l)
              if (item is String && item.trim().isNotEmpty) item.trim(),
        ]);
    final c = ReleaseChanges(added: list('added'), changed: list('changed'), fixed: list('fixed'));
    return c.isEmpty ? null : c;
  }

  Map<String, Object?> toJson() => {'added': added, 'changed': changed, 'fixed': fixed};

  bool get isEmpty => added.isEmpty && changed.isEmpty && fixed.isEmpty;
  int get length => added.length + changed.length + fixed.length;
}

/// The manifest's `highlights`, read leniently: anything but a list is
/// none, entries that are not strings (or blank) are dropped.
List<String> releaseHighlights(Object? json) => List.unmodifiable([
      if (json case final List l)
        for (final item in l)
          if (item is String && item.trim().isNotEmpty) item.trim(),
    ]);

class UpdateManifest {
  final String version;
  final int protocol;
  final String url;
  final String? sha256;
  /// One line for every app (1.2.x and 1.3.x show only this).
  final String notes;
  /// Null in manifests from before the changelog (show [notes] then).
  final ReleaseChanges? changes;
  /// The few noticeable things What's new shows first (CHANGELOG.md's
  /// `### Highlights`); empty in manifests from before them.
  final List<String> highlights;
  const UpdateManifest(
      {required this.version,
      required this.protocol,
      required this.url,
      this.sha256,
      required this.notes,
      this.changes,
      this.highlights = const []});

  // `assets` maps platform → archive URL. Top-level `url` is the Linux
  // tarball, kept for builds from before `assets` existed (<= 0.2.1).
  factory UpdateManifest.fromJson(Map<String, Object?> json,
      {String? platform}) {
    final version = json['version'];
    final protocol = json['protocol'];
    final assets = json['assets'];
    final url =
        assets is Map ? assets[platform ?? updatePlatform] : json['url'];
    if (version is! String ||
        version.isEmpty ||
        protocol is! int ||
        url is! String ||
        url.isEmpty) {
      throw FormatException(assets is Map && version is String
          ? 'release $version has no ${platform ?? updatePlatform} build'
          : 'update manifest missing version/protocol/url');
    }
    final sha = json['sha256'];
    return UpdateManifest(
        version: version,
        protocol: protocol,
        url: url,
        sha256: sha is String && sha.isNotEmpty ? sha : null,
        notes: json['notes'] is String ? json['notes'] as String : '',
        changes: ReleaseChanges.fromJson(json['changes']),
        highlights: releaseHighlights(json['highlights']));
  }

  // Newer wire protocol: this build can't join servers running it.
  bool get isRequired => protocol > RelayConstants.protoVersion;
}

List<int> parseVersion(String v) {
  final core = v.split('+').first.split('-').first;
  final out = <int>[];
  for (final part in core.split('.')) {
    final m = RegExp(r'\d+').firstMatch(part);
    if (m == null) break;
    out.add(int.parse(m.group(0)!));
    if (out.length == 3) break;
  }
  while (out.length < 3) {
    out.add(0);
  }
  return out;
}

// Semver precedence: core numbers, then a prerelease sorts below its
// release (1.2.3-rc1 < 1.2.3); prerelease identifiers compare dot by dot,
// numeric ones numerically and below alphanumeric ones. Build metadata
// (+...) is ignored.
int compareVersions(String a, String b) {
  final ca = parseVersion(a);
  final cb = parseVersion(b);
  for (var i = 0; i < 3; i++) {
    if (ca[i] != cb[i]) return ca[i].compareTo(cb[i]);
  }
  String? pre(String v) {
    final noBuild = v.split('+').first;
    final i = noBuild.indexOf('-');
    return i < 0 ? null : noBuild.substring(i + 1);
  }

  final pa = pre(a);
  final pb = pre(b);
  if (pa == null || pb == null) {
    if (pa == pb) return 0;
    return pa == null ? 1 : -1;
  }
  final ia = pa.split('.');
  final ib = pb.split('.');
  for (var i = 0; i < ia.length && i < ib.length; i++) {
    final na = int.tryParse(ia[i]);
    final nb = int.tryParse(ib[i]);
    final c = na != null && nb != null
        ? na.compareTo(nb)
        : na != null
            ? -1
            : nb != null
                ? 1
                : ia[i].compareTo(ib[i]);
    if (c != 0) return c;
  }
  return ia.length.compareTo(ib.length);
}

bool isNewerVersion(String current, String latest) =>
    compareVersions(latest, current) > 0;

/// The manifest from the first of [urls] that serves a valid one; when
/// none does, the first address's error.
Future<UpdateManifest> fetchManifest(
    {HttpClient? http, List<String> urls = updateManifestUrls}) async {
  if (urls.isEmpty) throw ArgumentError.value(urls, 'urls', 'no manifest address');
  Object? first;
  StackTrace? firstStack;
  for (final url in urls) {
    try {
      return await _fetchManifestFrom(url, http);
    } catch (e, st) {
      if (urls.length > 1) _log.warning('manifest $url: $e');
      first ??= e;
      firstStack ??= st;
    }
  }
  Error.throwWithStackTrace(first!, firstStack!);
}

Future<UpdateManifest> _fetchManifestFrom(String url, HttpClient? http) async {
  final client = http ?? HttpClient();
  try {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw HttpException('manifest fetch failed: HTTP ${res.statusCode}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('manifest is not a JSON object');
    }
    return UpdateManifest.fromJson(decoded);
  } finally {
    if (http == null) client.close();
  }
}

/// A test build (`1.1.3-dev.4`); `0.0.0-dev` (a dev run) is not one.
bool isDevBuild(String version) => version.contains('-dev.');

/// Where an install takes its updates from. [stable]: releases only.
/// [dev]: test builds as well ([devManifestUrls]), whichever of the two is
/// newer, so a release newer than the running test build is installed and
/// the next test line after it still is.
enum UpdateChannel {
  stable,
  dev;

  static UpdateChannel? fromName(Object? name) {
    for (final c in values) {
      if (c.name == name) return c;
    }
    return null;
  }
}

/// The channel of an install that never chose one: [UpdateChannel.dev]
/// for a test build, else [UpdateChannel.stable].
UpdateChannel defaultUpdateChannel(String version) =>
    isDevBuild(version) ? UpdateChannel.dev : UpdateChannel.stable;

/// Of the stable and dev manifests read (null: that one failed), the one
/// [channel] updates from: on stable the stable one, on dev the newer of
/// the two by semver (a release outranks its own test builds).
UpdateManifest? pickManifest(UpdateChannel channel,
    {UpdateManifest? stable, UpdateManifest? dev}) {
  if (channel == UpdateChannel.stable || dev == null) return stable;
  if (stable == null) return dev;
  return isNewerVersion(stable.version, dev.version) ? dev : stable;
}

/// A stable [latest] that is older than the running test build
/// [currentVersion]: on [UpdateChannel.stable] it is offered only after
/// asking ("go back to stable X?"), never as an update.
bool isStableBehind(String currentVersion, UpdateManifest latest) =>
    isDevBuild(currentVersion) &&
    !isDevBuild(latest.version) &&
    compareVersions(latest.version, currentVersion) < 0;

/// The manifest to update from on [channel] (default by [currentVersion]:
/// [defaultUpdateChannel]): the stable one, and on dev also the dev one,
/// the newer of the two ([pickManifest]; either alone if the other fails).
Future<UpdateManifest> fetchLatestManifest(
    {HttpClient? http,
    String currentVersion = appVersion,
    UpdateChannel? channel,
    List<String> urls = updateManifestUrls,
    List<String> devUrls = devManifestUrls}) async {
  final stable = fetchManifest(http: http, urls: urls);
  if ((channel ?? defaultUpdateChannel(currentVersion)) == UpdateChannel.stable) {
    return stable;
  }
  stable.ignore(); // awaited below; don't let an early failure go uncaught
  final dev = await fetchManifest(http: http, urls: devUrls)
      .then<UpdateManifest?>((m) => m, onError: (Object e) {
    _log.warning('dev manifest: $e');
    return null;
  });
  if (dev == null) return stable;
  final s = await stable.then<UpdateManifest?>((m) => m, onError: (Object _) => null);
  return pickManifest(UpdateChannel.dev, stable: s, dev: dev)!;
}

typedef DownloadProgress = void Function(int received, int? total);

Future<void> downloadFile(String url, File dest,
    {HttpClient? http, DownloadProgress? onProgress}) async {
  final client = http ?? HttpClient();
  try {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw HttpException('download failed: HTTP ${res.statusCode}');
    }
    final total = res.contentLength >= 0 ? res.contentLength : null;
    var received = 0;
    final sink = dest.openWrite();
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
    }
    if (total != null && received != total) {
      throw HttpException('download truncated: $received of $total bytes');
    }
  } finally {
    if (http == null) client.close();
  }
}

Future<void> verifySha256(File file, String want) async {
  final digest = await sha256.bind(file.openRead()).first;
  if (digest.toString() != want.trim().toLowerCase()) {
    throw const FormatException('sha256 mismatch — download is corrupt');
  }
}

// Release bundle layout is <root>/<binary> with <root>/data and <root>/lib
// siblings (Windows: data/ next to flutter_windows.dll, no lib/).
// Anything else (dev runs, dart run) is not a packaged install.
bool _isBundle(String dir, bool windows) =>
    Directory('$dir/data').existsSync() &&
    (windows
        ? File('$dir/flutter_windows.dll').existsSync()
        : Directory('$dir/lib').existsSync());

Directory? findInstallRoot(String executablePath, {bool? windows}) {
  final dir = File(executablePath).parent;
  return _isBundle(dir.path, windows ?? Platform.isWindows) ? dir : null;
}

String _basename(String path) => path.replaceAll('\\', '/').split('/').last;

// Path of the running binary. Read it before applying: after the swap,
// /proc/self/exe points at the replaced inode ("... (deleted)").
String currentExecutablePath() {
  const deleted = ' (deleted)';
  final p = Platform.resolvedExecutable;
  return p.endsWith(deleted) ? p.substring(0, p.length - deleted.length) : p;
}

// Sweep what a previous apply left behind: staging/backup dirs from an
// interrupted run, Windows `*.old` files that were still in use, and the
// old names an update by a 1.4.x updater kept (removeOldNames).
// The running app is complete (it started), so leftovers are garbage.
Future<void> cleanupUpdateLeftovers(Directory root, {bool? windows}) async {
  for (final name in [_stagingDir, _backupDir, _downloadFile]) {
    await _deleteQuietly('${root.path}/$name');
  }
  if (!await root.exists()) return;
  await removeOldNames(root, windows: windows);
  final old = RegExp(r'\.old(\.\d+)?$');
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is File && old.hasMatch(e.path)) {
      try {
        await e.delete();
      } catch (err) {
        _log.fine('still in use, retry next start: ${e.path} ($err)');
      }
    }
  }
}

/// Deletes the launchers or copies by the names up to 1.2.x
/// ([legacyAppBinaryName], [legacyServerBinaryName], `.exe` on Windows)
/// and their `.old` copies from [root], each only when its new binary is
/// there. A running one (Windows: an app started by the old name) is
/// renamed to `.old` instead, swept on a later start. Never throws.
Future<void> removeOldNames(Directory root, {bool? windows}) async {
  final ext = (windows ?? Platform.isWindows) ? '.exe' : '';
  for (final (old, now) in [
    (legacyAppBinaryName, appBinaryName),
    (legacyServerBinaryName, serverBinaryName),
  ]) {
    final path = '${root.path}/$old$ext';
    try {
      if (!await File('${root.path}/$now$ext').exists()) continue;
      try {
        if (await _exists('$path.old')) await File('$path.old').delete();
      } on FileSystemException {
        // Still in use: the sweep of a later start takes it.
      }
      if (!await _exists(path)) continue;
      try {
        await File(path).delete();
      } on FileSystemException {
        // Running (Windows): it can be renamed, not deleted.
        await File(path).rename(await _exists('$path.old')
            ? '$path.old.${DateTime.now().millisecondsSinceEpoch}'
            : '$path.old');
      }
      _log.info('removed the old name $old$ext');
    } catch (e) {
      _log.warning('old name $old$ext stays for now: $e');
    }
  }
}

List<ArchiveFile> _decodeArchive(List<int> raw) {
  if (raw.length > 2 && raw[0] == 0x1f && raw[1] == 0x8b) {
    return TarDecoder().decodeBytes(GZipDecoder().decodeBytes(raw)).files;
  }
  if (raw.length > 2 && raw[0] == 0x50 && raw[1] == 0x4b) {
    return ZipDecoder().decodeBytes(raw).files;
  }
  throw const FormatException('update is neither .tar.gz nor .zip');
}

// Archive-relative path → clean segments; rejects anything that could
// escape the target directory.
List<String> _safeSegments(String name) {
  final norm = name.replaceAll('\\', '/');
  if (norm.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(norm)) {
    throw FormatException('unsafe archive entry: $name');
  }
  final segs = norm.split('/').where((s) => s.isNotEmpty && s != '.').toList();
  if (segs.contains('..')) {
    throw FormatException('unsafe archive entry: $name');
  }
  return segs;
}

// Release archives wrap the bundle in one top-level folder
// (starsync-<ver>/, see tool/package_linux.sh). Strip it; a flat
// archive (data/, lib/ and the binary at the top) is used as is.
int _wrapperDepth(List<List<String>> entries) {
  final tops = entries.where((s) => s.isNotEmpty).map((s) => s.first).toSet();
  if (tops.length != 1 || tops.single == 'data' || tops.single == 'lib') {
    return 0;
  }
  return entries.any((s) => s.length > 1) ? 1 : 0;
}

// Symlink targets must stay inside the bundle.
bool _linkStaysInside(List<String> linkDir, String target) {
  if (target.startsWith('/') || target.contains('\\')) return false;
  final stack = [...linkDir];
  for (final s in target.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (stack.isEmpty) return false;
      stack.removeLast();
    } else {
      stack.add(s);
    }
  }
  return true;
}

Future<void> _extract(List<int> raw, Directory stage, bool posix) async {
  final files = _decodeArchive(raw);
  final segs = [for (final f in files) _safeSegments(f.name)];
  final depth = _wrapperDepth(segs);
  final modes = <int, List<String>>{};
  for (var i = 0; i < files.length; i++) {
    final entry = files[i];
    if (segs[i].length <= depth) continue;
    final rel = segs[i].sublist(depth);
    final path = '${stage.path}/${rel.join('/')}';
    if (entry.isSymbolicLink) {
      final target = entry.symbolicLink!;
      if (!_linkStaysInside(rel.sublist(0, rel.length - 1), target)) {
        throw FormatException('unsafe symlink: ${entry.name} -> $target');
      }
      await Directory(File(path).parent.path).create(recursive: true);
      await Link(path).create(target);
    } else if (entry.isDirectory) {
      await Directory(path).create(recursive: true);
    } else {
      await Directory(File(path).parent.path).create(recursive: true);
      await File(path).writeAsBytes(entry.content);
      final mode = entry.mode & 0x1ff;
      if (posix && mode & 0x49 != 0) {
        modes.putIfAbsent(mode, () => []).add(path);
      }
    }
  }
  // dart:io has no chmod; one call per distinct mode keeps exec bits.
  for (final m in modes.entries) {
    final r = await Process.run('chmod', [m.key.toRadixString(8), ...m.value]);
    if (r.exitCode != 0) {
      throw FileSystemException('chmod failed: ${r.stderr}'.trim());
    }
  }
}

Future<void> _rename(String from, String to) async {
  switch (await FileSystemEntity.type(from, followLinks: false)) {
    case FileSystemEntityType.directory:
      await Directory(from).rename(to);
    case FileSystemEntityType.link:
      await Link(from).rename(to);
    case FileSystemEntityType.notFound:
      throw FileSystemException('missing', from);
    default:
      await File(from).rename(to);
  }
}

Future<bool> _exists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;

Future<void> _deleteQuietly(String path) async {
  try {
    switch (await FileSystemEntity.type(path, followLinks: false)) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.notFound:
        break;
      default:
        await File(path).delete();
    }
  } catch (e) {
    _log.warning('could not remove $path: $e');
  }
}

// Test seam: called before each move with a step label; throwing from it
// simulates a mid-swap failure.
typedef ApplyHook = Future<void> Function(String step);

// Unpack [archive] into a staging dir inside [root], then swap it in.
// On failure the install is left exactly as it was.
Future<void> applyUpdate(File archive, Directory root,
    {String? executableName, bool? windows, ApplyHook? hook}) async {
  final win = windows ?? Platform.isWindows;
  final stage = Directory('${root.path}/$_stagingDir');
  if (await stage.exists()) await stage.delete(recursive: true);
  await stage.create();
  try {
    await _extract(await archive.readAsBytes(), stage, !win);
    if (!_isBundle(stage.path, win) ||
        (executableName != null &&
            !await _hasBinary(stage.path, executableName))) {
      throw const FormatException(
          'archive is not a release bundle (missing data/, lib/ or binary)');
    }
    if (win) {
      await _swapWindows(stage, root, hook);
    } else {
      await _swapPosix(stage, root, hook);
    }
  } finally {
    await _deleteQuietly(stage.path);
  }
  await removeOldNames(root, windows: win);
}

// The running binary's name, or for an old name its new one (archives
// no longer carry the old names; an install started by one still updates).
Future<bool> _hasBinary(String dir, String name) async {
  if (await File('$dir/$name').exists()) return true;
  final renamed = _renamedBinary(name);
  return renamed != null && await File('$dir/$renamed').exists();
}

class _Moved {
  final String name;
  final bool hadOld;
  bool movedIn = false;
  _Moved(this.name, this.hadOld);
}

Future<void> _swapPosix(Directory stage, Directory root, ApplyHook? hook) async {
  final backup = Directory('${root.path}/$_backupDir');
  if (await backup.exists()) await backup.delete(recursive: true);
  await backup.create();
  final names = [
    for (final e in await stage.list(followLinks: false).toList())
      e.path.substring(stage.path.length + 1)
  ]..sort();
  final done = <_Moved>[];
  try {
    for (final name in names) {
      final cur = '${root.path}/$name';
      final m = _Moved(name, await _exists(cur));
      if (m.hadOld) {
        await hook?.call('aside:$name');
        await _rename(cur, '${backup.path}/$name');
      }
      done.add(m);
      await hook?.call('in:$name');
      await _rename('${stage.path}/$name', cur);
      m.movedIn = true;
    }
  } catch (e) {
    _log.warning('swap failed, rolling back: $e');
    for (final m in done.reversed) {
      final cur = '${root.path}/${m.name}';
      try {
        if (m.movedIn) await _rename(cur, '${stage.path}/${m.name}');
        if (m.hadOld) await _rename('${backup.path}/${m.name}', cur);
      } catch (re) {
        // Leave the backup dir in place so nothing is lost.
        _log.severe('rollback of ${m.name} failed: $re '
            '(old files kept in ${backup.path})');
        rethrow;
      }
    }
    await _deleteQuietly(backup.path);
    rethrow;
  }
  await _deleteQuietly(backup.path);
}

// File-level: a running exe/dll can be renamed but
// not deleted or overwritten, so every existing file goes to `<f>.old`
// first; leftovers are swept by cleanupUpdateLeftovers on next start.
Future<void> _swapWindows(Directory stage, Directory root, ApplyHook? hook) async {
  final rels = <String>[
    await for (final e in stage.list(recursive: true, followLinks: false))
      if (e is File) e.path.substring(stage.path.length + 1)
  ]..sort();
  final done = <(String rel, String? old, bool movedIn)>[];
  try {
    for (final rel in rels) {
      final cur = '${root.path}/$rel';
      String? old;
      if (await File(cur).exists()) {
        old = '$cur.old';
        if (await File(old).exists()) {
          try {
            await File(old).delete();
          } on FileSystemException {
            old = '$cur.old.${DateTime.now().millisecondsSinceEpoch}';
          }
        }
        await hook?.call('aside:$rel');
        await File(cur).rename(old);
      }
      done.add((rel, old, false));
      await Directory(File(cur).parent.path).create(recursive: true);
      await hook?.call('in:$rel');
      await File('${stage.path}/$rel').rename(cur);
      done.last = (rel, old, true);
    }
  } catch (e) {
    _log.warning('swap failed, rolling back: $e');
    for (final (rel, old, movedIn) in done.reversed) {
      final cur = '${root.path}/$rel';
      if (movedIn) await File(cur).delete();
      if (old != null) await File(old).rename(cur);
    }
    rethrow;
  }
  for (final (_, old, _) in done) {
    if (old == null) continue;
    try {
      await File(old).delete();
    } on FileSystemException {
      // In use (the running exe/dlls) — swept next start.
    }
  }
}

// Shared by the CLI and the in-app banner: download next to the install
// (same filesystem), verify, apply, clean up.
Future<void> downloadAndApply(UpdateManifest manifest, Directory root,
    {HttpClient? http,
    DownloadProgress? onProgress,
    String? executableName,
    void Function(String line)? say}) async {
  final file = File('${root.path}/$_downloadFile');
  try {
    say?.call('downloading ${manifest.url} ...');
    await downloadFile(manifest.url, file, http: http, onProgress: onProgress);
    if (manifest.sha256 != null) {
      await verifySha256(file, manifest.sha256!);
    } else {
      say?.call('no checksum in manifest — skipping verification '
          '(HTTPS transit + gzip CRC still apply).');
    }
    say?.call('verified, applying over ${root.path} ...');
    await applyUpdate(file, root, executableName: executableName);
  } finally {
    await _deleteQuietly(file.path);
  }
}

String requiredUpdateNote(UpdateManifest m) =>
    'Required update: servers on ${m.version} speak protocol ${m.protocol}, '
    'this build speaks ${RelayConstants.protoVersion} and cannot join them.';

// Returns a process exit code: 0 ok / already current, 1 failure,
// 2 not a packaged install (update manually). [program] names the front
// end in the first line; [restartNote] is the last line after an update.
// [checkOnly] reports what is available and changes nothing.
Future<int> runUpgrade(
    {String currentVersion = appVersion,
    List<String> manifestUrls = updateManifestUrls,
    HttpClient? http,
    String? executablePath,
    Directory? installRoot,
    String program = 'starsync',
    String Function(String version)? restartNote,
    bool checkOnly = false}) async {
  stdout.writeln('$program $currentVersion (proto ${RelayConstants.protoVersion})');
  late final UpdateManifest manifest;
  try {
    manifest = await fetchLatestManifest(
        http: http, currentVersion: currentVersion, urls: manifestUrls);
  } catch (e) {
    stdout.writeln('update check failed: $e');
    return 1;
  }
  if (!isNewerVersion(currentVersion, manifest.version)) {
    stdout.writeln('already up to date (${manifest.version}).');
    return 0;
  }
  stdout.writeln('update available: ${manifest.version} (proto ${manifest.protocol})');
  if (manifest.notes.isNotEmpty) {
    stdout.writeln(manifest.notes);
  }
  if (manifest.isRequired) {
    stdout.writeln(requiredUpdateNote(manifest));
  }
  if (checkOnly) return 0;
  final exe = executablePath ?? currentExecutablePath();
  final root = installRoot ?? findInstallRoot(exe);
  if (root == null) {
    stdout.writeln('not a packaged install — download the tarball and update manually.');
    return 2;
  }
  try {
    await cleanupUpdateLeftovers(root);
    await downloadAndApply(manifest, root,
        http: http,
        executableName: installRoot == null ? _basename(exe) : null,
        say: stdout.writeln);
  } catch (e) {
    stdout.writeln('update failed: $e');
    return 1;
  }
  stdout.writeln(restartNote?.call(manifest.version) ??
      'updated to ${manifest.version} — restart the app to use it.');
  return 0;
}
