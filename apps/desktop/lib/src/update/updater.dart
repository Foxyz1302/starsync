import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:sync_relay_core/core.dart';

// Zero Flutter imports: this file must stay unit-testable with plain
// `flutter test` (no widgets, no media_kit). Linux-first v1: a CLI flag,
// `watch-together --upgrade`, that checks the manifest, downloads the
// tarball, verifies sha256, and extracts it over the live install.
// Linux allows replacing (unlink/rename) files under a running process —
// only opening the running binary for writing is refused (ETXTBSY) — so
// apply is extract-to-temp then delete-first move-over, and the running
// (old) image just prints the result and exits. Next launch is new.

const updateManifestUrl =
    'https://git.example.org/Foxyz/sync_replay_project/raw/branch/main/updates/manifest.json';

const appVersion = String.fromEnvironment('APP_VERSION',
    defaultValue: '0.0.0-dev');

class UpdateManifest {
  final String version;
  final int protocol;
  final String url;
  final String sha256;
  final String notes;
  const UpdateManifest(
      {required this.version,
      required this.protocol,
      required this.url,
      required this.sha256,
      required this.notes});

  factory UpdateManifest.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final protocol = json['protocol'];
    final url = json['url'];
    final sha = json['sha256'];
    if (version is! String ||
        version.isEmpty ||
        protocol is! int ||
        url is! String ||
        url.isEmpty ||
        sha is! String ||
        sha.isEmpty) {
      throw const FormatException('update manifest missing version/protocol/url/sha256');
    }
    return UpdateManifest(
        version: version,
        protocol: protocol,
        url: url,
        sha256: sha,
        notes: (json['notes'] as String?) ?? '');
  }
}

List<int> parseVersion(String v) {
  final out = <int>[];
  for (final part in v.split('.')) {
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

bool isNewerVersion(String current, String latest) {
  final c = parseVersion(current);
  final l = parseVersion(latest);
  for (var i = 0; i < 3; i++) {
    if (l[i] != c[i]) return l[i] > c[i];
  }
  return false;
}

Future<UpdateManifest> fetchManifest(
    {HttpClient? http, String url = updateManifestUrl}) async {
  final client = http ?? HttpClient();
  try {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    final res = await req.close();
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
    client.close();
  }
}

Future<void> downloadFile(String url, File dest, {HttpClient? http}) async {
  final client = http ?? HttpClient();
  try {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('download failed: HTTP ${res.statusCode}');
    }
    final sink = dest.openWrite();
    try {
      await res.pipe(sink);
    } finally {
      await sink.close();
    }
  } finally {
    client.close();
  }
}

Future<void> verifySha256(File file, String want) async {
  final digest = await sha256.bind(file.openRead()).first;
  if (digest.toString() != want.trim().toLowerCase()) {
    throw const FormatException('sha256 mismatch — download is corrupt');
  }
}

// Release bundle layout is <root>/<binary> with <root>/data and <root>/lib
// siblings. Anything else (dev runs, dart run) is not a packaged install.
Directory? findInstallRoot(String executablePath) {
  final dir = File(executablePath).parent;
  if (Directory('${dir.path}/data').existsSync() &&
      Directory('${dir.path}/lib').existsSync()) {
    return dir;
  }
  return null;
}

// Extract to temp, then move every file over delete-first: opening the
// running executable for writing throws ETXTBSY, delete+rename does not.
Future<void> applyTarball(File tarball, Directory root) async {
  final raw = await tarball.readAsBytes();
  final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(raw));
  final stage =
      await Directory.systemTemp.createTemp('watch-together-update');
  try {
    for (final entry in archive) {
      final name = entry.name;
      if (name.isEmpty || name.startsWith('/') || name.contains('..')) {
        throw FormatException('unsafe tar entry: $name');
      }
      final target = File('${stage.path}/$name');
      if (entry.isDirectory) {
        await Directory(target.path).create(recursive: true);
      } else if (entry.isFile) {
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.content as List<int>);
      } else {
        throw FormatException('unsupported tar entry: $name');
      }
    }
    await for (final entity
        in stage.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(stage.path.length + 1);
      final dest = File('${root.path}/$rel');
      await dest.parent.create(recursive: true);
      if (await dest.exists() || await Link(dest.path).exists()) {
        await dest.delete();
      }
      await entity.rename(dest.path);
    }
  } finally {
    if (await stage.exists()) {
      await stage.delete(recursive: true);
    }
  }
}

// Returns a process exit code: 0 ok / already current, 1 failure,
// 2 not a packaged install (update manually).
Future<int> runUpgrade(
    {String currentVersion = appVersion,
    String manifestUrl = updateManifestUrl,
    HttpClient? http,
    String? executablePath,
    Directory? installRoot}) async {
  stdout.writeln('watch-together $currentVersion (proto ${RelayConstants.protoVersion})');
  late final UpdateManifest manifest;
  try {
    manifest = await fetchManifest(http: http, url: manifestUrl);
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
  if (manifest.protocol != RelayConstants.protoVersion) {
    stdout.writeln('WARNING: protocol ${manifest.protocol} != ${RelayConstants.protoVersion} — '
        'update together with everyone in the room, mixed versions cannot sync.');
  }
  final root = installRoot ??
      findInstallRoot(executablePath ?? Platform.resolvedExecutable);
  if (root == null) {
    stdout.writeln('not a packaged install — download the tarball and update manually.');
    return 2;
  }
  final tmp = await Directory.systemTemp.createTemp('watch-together-dl');
  try {
    final file = File('${tmp.path}/update.tar.gz');
    stdout.writeln('downloading ${manifest.url} ...');
    await downloadFile(manifest.url, file, http: http);
    await verifySha256(file, manifest.sha256);
    stdout.writeln('verified, applying over ${root.path} ...');
    await applyTarball(file, root);
  } catch (e) {
    stdout.writeln('update failed: $e');
    return 1;
  } finally {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  }
  stdout.writeln('updated to ${manifest.version} — restart the app to use it.');
  return 0;
}
