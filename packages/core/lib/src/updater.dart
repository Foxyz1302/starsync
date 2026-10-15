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

const updateManifestUrl =
    'https://git.example.org/Foxyz/sync_replay_project/raw/branch/main/updates/manifest.json';

/// Test builds (`tool/dev_release.sh`): one Gitea prerelease, tag `dev`,
/// whose assets each run replaces. Only dev builds read it.
const devManifestUrl =
    'https://git.example.org/Foxyz/sync_replay_project/releases/download/dev/manifest.json';

const appVersion = String.fromEnvironment('APP_VERSION',
    defaultValue: '0.0.0-dev');

// Key into the manifest's `assets` map, e.g. linux-x64, windows-x64.
final updatePlatform = '${Platform.operatingSystem}-x64';

/// The app's binary in a release bundle (`.exe` on Windows).
const appBinaryName = 'starsync';
/// The dedicated server's binary next to it (`.exe` on Windows).
const serverBinaryName = 'starsync-server';
/// The names up to 1.2.x. The archive still carries launchers by these
/// names (tool/package_linux.sh, package_windows.ps1): a 1.2.x updater
/// checks that its own name is in the archive and restarts it, and VPS
/// units and `update.sh` copies run the old server name.
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

class UpdateManifest {
  final String version;
  final int protocol;
  final String url;
  final String? sha256;
  final String notes;
  const UpdateManifest(
      {required this.version,
      required this.protocol,
      required this.url,
      this.sha256,
      required this.notes});

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
        notes: (json['notes'] as String?) ?? '');
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

Future<UpdateManifest> fetchManifest(
    {HttpClient? http, String url = updateManifestUrl}) async {
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

/// The manifest to update from: the stable one, and for a [isDevBuild]
/// also the dev one, whichever is newer (either alone if the other fails).
/// A release outranks its own test builds, so testers return to stable.
Future<UpdateManifest> fetchLatestManifest(
    {HttpClient? http,
    String currentVersion = appVersion,
    String url = updateManifestUrl,
    String devUrl = devManifestUrl}) async {
  final stable = fetchManifest(http: http, url: url);
  if (!isDevBuild(currentVersion)) return stable;
  stable.ignore(); // awaited below; don't let an early failure go uncaught
  final dev = await fetchManifest(http: http, url: devUrl)
      .then<UpdateManifest?>((m) => m, onError: (Object e) {
    _log.warning('dev manifest: $e');
    return null;
  });
  if (dev == null) return stable;
  try {
    final s = await stable;
    return isNewerVersion(s.version, dev.version) ? dev : s;
  } catch (_) {
    return dev;
  }
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
// interrupted run, and Windows `*.old` files that were still in use.
// The running app is complete (it started), so leftovers are garbage.
Future<void> cleanupUpdateLeftovers(Directory root) async {
  for (final name in [_stagingDir, _backupDir, _downloadFile]) {
    await _deleteQuietly('${root.path}/$name');
  }
  if (!await root.exists()) return;
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
}

// The running binary's name, or for an old name its new one (an archive
// without the old launchers still updates an install started by one).
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
    String manifestUrl = updateManifestUrl,
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
        http: http, currentVersion: currentVersion, url: manifestUrl);
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
