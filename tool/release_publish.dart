// Publish one platform's archive to the Gitea release for a tag: create
// the release if it doesn't exist yet, then upload (or replace) the asset.
// The Linux and Windows CI jobs both run this, possibly at the same time,
// so a lost create race falls back to the release the other job made.
// The manifest is written by tool/release.sh at release time (predictable
// asset URLs). The release page's text is the version's CHANGELOG.md
// section (tool/changelog.dart).
// Usage: dart tool/release_publish.dart vX.Y.Z <archive>
//   (run after tool/package_linux.sh or tool/package_windows.ps1)
//   dart tool/release_publish.dart dev <archive> <manifest.json>
//   (tool/dev_release.sh): the `dev` prerelease, its assets all replaced.
// Env: RELEASE_TOKEN (preferred) or the Actions-provided GITHUB_TOKEN /
// GITEA_TOKEN. dart: imports only — runs without `pub get`.
import 'dart:convert';
import 'dart:io';

import 'changelog.dart';

Future<void> main(List<String> args) async {
  final dev = args.isNotEmpty && args[0] == 'dev';
  if (args.length != (dev ? 3 : 2)) {
    _die('usage: dart tool/release_publish.dart vX.Y.Z <archive>\n'
        '       dart tool/release_publish.dart dev <archive> <manifest.json>');
  }
  final tag = args[0];
  final files = [for (final a in args.skip(1)) File(a)];
  for (final f in files) {
    if (!f.existsSync()) _die('missing: ${f.path}');
  }
  final root = File.fromUri(Platform.script).parent.parent.path;
  if (dev) return _publishDev(root, files);
  final archive = files.single;
  final ver = tag.startsWith('v') ? tag.substring(1) : tag;
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(ver)) {
    _die('tag must look like v0.2.0, got $tag');
  }
  final pubspec = File('$root/apps/desktop/pubspec.yaml').readAsStringSync();
  final pub = RegExp(r'^version: ([0-9.]+)', multiLine: true)
      .firstMatch(pubspec)
      ?.group(1);
  if (pub != ver) {
    _die('tag $tag != desktop pubspec $pub (run tool/release.sh first)');
  }

  final token = _token();
  final api = _apiBase(root);

  final body = _changelog(root)?.section(ver)?.releaseBody(ver) ?? 'Starsync $ver.';

  final http = HttpClient();
  try {
    final c = _Api(http, token);
    var rel = await c.get('$api/releases/tags/$tag');
    if (rel == null) {
      stdout.writeln('creating release $tag on $api ...');
      rel = await c.post('$api/releases', {
        'tag_name': tag,
        'name': tag,
        'body': body,
        'draft': false,
        'prerelease': false,
      });
      // The other platform's job won the race.
      rel ??= await c.get('$api/releases/tags/$tag') ??
          _die('could not create or find release $tag');
    }
    final id = rel['id'];
    stdout.writeln('release id: $id');

    final name = archive.uri.pathSegments.last;
    for (final a in (rel['assets'] as List? ?? const [])) {
      if (a is Map && a['name'] == name) {
        stdout.writeln('replacing existing $name ...');
        await c.delete('$api/releases/$id/assets/${a['id']}');
      }
    }
    stdout.writeln('uploading $name ...');
    await c.upload(
        '$api/releases/$id/assets?name=${Uri.encodeQueryComponent(name)}',
        archive,
        name);
    stdout.writeln('published $name to $tag.');
  } finally {
    http.close();
  }
}

String _token() {
  final env = Platform.environment;
  return [env['RELEASE_TOKEN'], env['GITHUB_TOKEN'], env['GITEA_TOKEN']]
      .firstWhere((t) => t != null && t.isNotEmpty,
          orElse: () => _die('set RELEASE_TOKEN (or run in Actions)'))!;
}

// The repo's API URL, from origin.
String _apiBase(String root) {
  final origin = _git(root, ['remote', 'get-url', 'origin']);
  final server = RegExp(r'^(https?://[^/]+)/').firstMatch(origin)?.group(1) ??
      Platform.environment['GITHUB_SERVER_URL'] ??
      _die('cannot derive server from origin $origin');
  final repo =
      RegExp(r'([^/:]+/[^/]+?)(\.git)?$').firstMatch(origin)!.group(1)!;
  return '$server/api/v1/repos/$repo';
}

// The `dev` prerelease (created at main's head on first use): [files]
// uploaded (the manifest last), the previous ones deleted. Its manifest's URL is fixed, so
// test builds find each new one.
Future<void> _publishDev(String root, List<File> files) async {
  final token = _token();
  final api = _apiBase(root);
  final http = HttpClient();
  try {
    final c = _Api(http, token);
    final rel = await c.get('$api/releases/tags/dev') ??
        await c.post('$api/releases', {
          'tag_name': 'dev',
          'target_commitish': 'main',
          'name': 'Test build',
          'body': 'Latest test build; dev builds update from here.',
          'draft': false,
          'prerelease': true,
        }) ??
        _die('could not create or find release dev');
    final id = rel['id'];
    // The page says what the build has: Unreleased.
    final ver = jsonDecode(files.last.readAsStringSync())['version'];
    final next = _changelog(root)?.section(unreleased);
    if (next != null && !next.isEmpty) {
      await c.patch('$api/releases/$id', {'body': 'Latest test build; dev builds update from here.\n\n${next.releaseBody('$ver')}'});
    }
    final old = [for (final a in (rel['assets'] as List? ?? const [])) if (a is Map) a];
    Future<void> upload(File f) {
      final name = f.uri.pathSegments.last;
      stdout.writeln('uploading $name ...');
      return c.upload('$api/releases/$id/assets?name=${Uri.encodeQueryComponent(name)}', f, name);
    }

    // The archive first, the old assets after, the manifest last: a failed
    // upload leaves the previous build in place, never an empty release.
    final manifest = files.last;
    for (final f in files.take(files.length - 1)) {
      await upload(f);
    }
    for (final a in old) {
      await c.delete('$api/releases/$id/assets/${a['id']}');
    }
    await upload(manifest);
    stdout.writeln('published to dev.');
  } finally {
    http.close();
  }
}

Changelog? _changelog(String root) {
  final f = File('$root/CHANGELOG.md');
  try {
    return Changelog.parse(f.readAsStringSync());
  } on Object catch (e) {
    stderr.writeln('warning: CHANGELOG.md not used: $e');
    return null;
  }
}

Never _die(String msg) {
  stderr.writeln('error: $msg');
  exit(1);
}

String _git(String root, List<String> args, {bool allowFail = false}) {
  final r = Process.runSync('git', ['-C', root, ...args]);
  if (r.exitCode != 0) {
    if (allowFail) return '';
    _die('git ${args.join(' ')}: ${r.stderr}'.trim());
  }
  return (r.stdout as String).trim();
}

class _Api {
  final HttpClient http;
  final String token;
  _Api(this.http, this.token);

  Future<(int, String)> _send(String method, String url,
      {List<int>? body, String? type}) async {
    final req = await http.openUrl(method, Uri.parse(url));
    req.headers.set('Authorization', 'token $token');
    req.headers.set('Accept', 'application/json');
    if (body != null) {
      req.headers.set('Content-Type', type!);
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  // null on 404.
  Future<Map<String, Object?>?> get(String url) async {
    final (code, text) = await _send('GET', url);
    if (code == 404) return null;
    _check('GET', url, code, text);
    return jsonDecode(text) as Map<String, Object?>;
  }

  // null on 409 (already exists).
  Future<Map<String, Object?>?> post(String url, Object json) async {
    final (code, text) = await _send('POST', url,
        body: utf8.encode(jsonEncode(json)), type: 'application/json');
    if (code == 409) return null;
    _check('POST', url, code, text);
    return jsonDecode(text) as Map<String, Object?>;
  }

  Future<void> patch(String url, Object json) async {
    final (code, text) = await _send('PATCH', url,
        body: utf8.encode(jsonEncode(json)), type: 'application/json');
    _check('PATCH', url, code, text);
  }

  Future<void> delete(String url) async {
    final (code, text) = await _send('DELETE', url);
    _check('DELETE', url, code, text);
  }

  // Gitea's asset API takes a multipart form with an `attachment` field.
  Future<void> upload(String url, File file, String name) async {
    final boundary = 'wt-${DateTime.now().microsecondsSinceEpoch}';
    final body = <int>[
      ...utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="attachment"; filename="$name"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n'),
      ...await file.readAsBytes(),
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ];
    final (code, text) = await _send('POST', url,
        body: body, type: 'multipart/form-data; boundary=$boundary');
    _check('upload', url, code, text);
  }

  void _check(String what, String url, int code, String text) {
    if (code < 200 || code >= 300) {
      _die(
          '$what $url → HTTP $code: ${text.length > 300 ? text.substring(0, 300) : text}');
    }
  }
}
