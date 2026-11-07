// Publish to a GitHub release (Foxyz1302/starsync): create the release for
// a tag or update its text, then upload (or replace) the given files. Each
// file's `<file>.sig` beside it goes up right after it when there is one;
// `.json` files (the manifest, a config) go up last, so they never point at
// an archive that is not there yet.
//   dart tool/publish_github.dart vX.Y.Z <file>...
//     a release: its text is the version's CHANGELOG.md section; the tag
//     must match the desktop pubspec. .github/workflows/release.yml passes
//     both archives (the signed manifest comes after, on main:
//     tool/sign_release.sh).
//   dart tool/publish_github.dart dev <file>... <manifest.json>
//     the `dev` prerelease (created at main on first use): the files
//     uploaded, every other asset deleted, its text the changelog's
//     Unreleased.
// Options: --repo owner/name (else GITHUB_REPOSITORY, else a github.com
// origin); --dry-run prints what it would do, with no token and no network.
// Env: GITHUB_TOKEN (Actions) or GH_TOKEN, else `gh auth token`;
// GITHUB_API_URL (Actions sets it) overrides https://api.github.com.
// dart: imports only — runs without `pub get`.
import 'dart:convert';
import 'dart:io';

import 'changelog.dart';

const _usage = 'usage: dart tool/publish_github.dart [--repo owner/name] [--dry-run] vX.Y.Z <file>...\n'
    '       dart tool/publish_github.dart [--repo owner/name] [--dry-run] dev <file>... <manifest.json>';

const _devText = 'Latest test build; dev builds update from here.';

Future<void> main(List<String> argv) async {
  var dry = false;
  String? repo;
  final args = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--dry-run') {
      dry = true;
    } else if (a == '--repo' && i + 1 < argv.length) {
      repo = argv[++i];
    } else if (a.startsWith('--repo=')) {
      repo = a.substring('--repo='.length);
    } else if (a.startsWith('--')) {
      _die('unknown option $a\n$_usage');
    } else {
      args.add(a);
    }
  }
  final dev = args.isNotEmpty && args[0] == 'dev';
  if (args.length < (dev ? 3 : 2)) _die(_usage);
  final tag = args[0];
  final files = [for (final a in args.skip(1)) File(a)];
  for (final f in files) {
    if (!f.existsSync()) _die('missing: ${f.path}');
  }
  final root = File.fromUri(Platform.script).parent.parent.path;
  repo ??= _repo(root);
  if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo)) _die('bad repo "$repo"');

  final String name;
  final String body;
  if (dev) {
    if (!_isJson(files.last) || files.where(_isJson).length != 1) {
      _die('dev: the manifest goes last and must be the only .json file');
    }
    name = 'Test build';
    final ver = _readJson(files.last)['version'];
    final next = _changelog(root)?.section(unreleased);
    body = next == null || next.isEmpty ? _devText : '$_devText\n\n${next.releaseBody('$ver')}';
  } else {
    final ver = tag.startsWith('v') ? tag.substring(1) : tag;
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(ver)) {
      _die('tag must look like v0.2.0, got $tag');
    }
    final pubspec = File('$root/apps/desktop/pubspec.yaml').readAsStringSync();
    final pub = RegExp(r'^version: ([0-9.]+)', multiLine: true).firstMatch(pubspec)?.group(1);
    if (pub != ver) _die('tag $tag != desktop pubspec $pub (run tool/release.sh first)');
    name = tag;
    body = _changelog(root)?.section(ver)?.releaseBody(ver) ?? 'Starsync $ver.';
  }

  // Upload order: archives (each with its .sig), then .json files (each
  // with its .sig). A dev build's manifest is always last.
  final ordered = [
    for (final f in files) if (!_isJson(f)) f,
    for (final f in files) if (_isJson(f)) f,
  ];
  final uploads = <File>[
    for (final f in ordered) ...[
      f,
      if (File('${f.path}.sig').existsSync() && !files.any((g) => _same(g, File('${f.path}.sig'))))
        File('${f.path}.sig'),
    ],
  ];
  final names = [for (final f in uploads) _base(f)];
  if (names.toSet().length != names.length) _die('two files share a name: $names');
  for (final f in ordered.where(_isJson)) {
    _checkManifestUrls(f, repo, tag);
  }

  final api = (Platform.environment['GITHUB_API_URL'] ?? 'https://api.github.com')
      .replaceAll(RegExp(r'/+$'), '');
  final base = '$api/repos/$repo';

  if (dry) {
    stdout.writeln('dry run: $base, release $tag ("$name"${dev ? ', prerelease' : ''})');
    stdout.writeln('text:\n${body.trimRight().split('\n').map((l) => '  | $l').join('\n')}');
    for (final f in uploads) {
      stdout.writeln('upload ${_base(f)} (${f.lengthSync()} bytes, replacing one of that name)');
    }
    if (dev) stdout.writeln('then delete every other asset of $tag');
    return;
  }

  final http = HttpClient();
  try {
    final c = _Api(http, _token());
    var rel = await c.get('$base/releases/tags/$tag');
    if (rel == null) {
      stdout.writeln('creating release $tag on $repo ...');
      rel = await c.post('$base/releases', {
        'tag_name': tag,
        if (dev) 'target_commitish': 'main',
        'name': name,
        'body': body,
        'draft': false,
        'prerelease': dev,
      });
      // Someone else made it meanwhile.
      rel ??= await c.get('$base/releases/tags/$tag') ?? _die('could not create or find release $tag');
    } else if (rel['body'] != body || rel['name'] != name) {
      stdout.writeln('updating the text of release $tag ...');
      await c.patch('$base/releases/${rel['id']}', {'name': name, 'body': body});
    }
    final id = rel['id'];
    stdout.writeln('release id: $id');
    final uploadUrl = (rel['upload_url'] as String).replaceFirst(RegExp(r'\{.*\}$'), '');

    // Before the manifest: a dev build's stale archives go (the manifest
    // still names the previous build until its own upload).
    final firstJson = uploads.indexWhere(_isJson);
    final before = firstJson < 0 ? uploads : uploads.sublist(0, firstJson);
    final after = firstJson < 0 ? <File>[] : uploads.sublist(firstJson);
    for (final f in before) {
      await c.replaceAsset(base, id, uploadUrl, f);
    }
    if (dev) {
      final keep = names.toSet();
      for (final a in await c.assets(base, id)) {
        if (!keep.contains(a['name'])) {
          stdout.writeln('deleting old ${a['name']} ...');
          await c.delete('$base/releases/assets/${a['id']}');
        }
      }
    }
    for (final f in after) {
      await c.replaceAsset(base, id, uploadUrl, f);
    }
    stdout.writeln('published ${names.join(', ')} to $tag on $repo.');
  } on IOException catch (e) {
    _die('$e');
  } finally {
    http.close();
  }
}

bool _isJson(File f) => _base(f).endsWith('.json');
String _base(File f) => f.uri.pathSegments.last;
bool _same(File a, File b) => a.absolute.path == b.absolute.path;

// A manifest whose asset URLs are not this release's own downloads still
// goes up (it is what tool/release.sh wrote), with a warning.
void _checkManifestUrls(File f, String repo, String tag) {
  final json = _readJson(f);
  if (json['assets'] is! Map) return;
  final want = 'https://github.com/$repo/releases/download/$tag/';
  final off = [
    for (final u in (json['assets'] as Map).values)
      if (u is String && !u.startsWith(want)) u
  ];
  if (off.isNotEmpty) {
    stderr.writeln('warning: ${_base(f)} points elsewhere than $want: ${off.join(', ')}');
  }
}

Map<String, Object?> _readJson(File f) {
  try {
    final json = jsonDecode(f.readAsStringSync());
    if (json is Map<String, Object?>) return json;
  } on Exception {
    // Below.
  }
  return _die('${f.path} is not a JSON object');
}

String _repo(String root) {
  final env = Platform.environment['GITHUB_REPOSITORY'];
  if (env != null && env.isNotEmpty) return env;
  final r = Process.runSync('git', ['-C', root, 'remote', 'get-url', 'origin']);
  final origin = r.exitCode == 0 ? (r.stdout as String).trim() : '';
  final m = RegExp(r'github\.com[:/]([^/]+/[^/]+?)(\.git)?$').firstMatch(origin);
  return m?.group(1) ?? _die('origin is not on github.com: pass --repo owner/name');
}

String _token() {
  final env = Platform.environment;
  for (final t in [env['GITHUB_TOKEN'], env['GH_TOKEN']]) {
    if (t != null && t.isNotEmpty) return t;
  }
  try {
    final r = Process.runSync('gh', ['auth', 'token']);
    final t = (r.stdout as String).trim();
    if (r.exitCode == 0 && t.isNotEmpty) return t;
  } on ProcessException {
    // No gh.
  }
  return _die('set GITHUB_TOKEN (or run in Actions, or `gh auth login`)');
}

Changelog? _changelog(String root) {
  try {
    return Changelog.parse(File('$root/CHANGELOG.md').readAsStringSync());
  } on Object catch (e) {
    stderr.writeln('warning: CHANGELOG.md not used: $e');
    return null;
  }
}

Never _die(String msg) {
  stderr.writeln('error: $msg');
  exit(1);
}

class _Api {
  final HttpClient http;
  final String token;
  _Api(this.http, this.token);

  Future<(int, String)> _send(String method, String url, {File? file, Object? json}) async {
    final req = await http.openUrl(method, Uri.parse(url));
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('X-GitHub-Api-Version', '2022-11-28');
    req.headers.set('User-Agent', 'starsync-publish');
    if (json != null) {
      final bytes = utf8.encode(jsonEncode(json));
      req.headers.set('Content-Type', 'application/json');
      req.contentLength = bytes.length;
      req.add(bytes);
    } else if (file != null) {
      req.headers.set('Content-Type', _type(_base(file)));
      req.contentLength = file.lengthSync();
      await req.addStream(file.openRead());
    }
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  static String _type(String name) => switch (name) {
        _ when name.endsWith('.json') => 'application/json',
        _ when name.endsWith('.zip') => 'application/zip',
        _ when name.endsWith('.gz') => 'application/gzip',
        _ => 'application/octet-stream',
      };

  // null on 404.
  Future<Map<String, Object?>?> get(String url) async {
    final (code, text) = await _send('GET', url);
    if (code == 404) return null;
    _check('GET', url, code, text);
    return jsonDecode(text) as Map<String, Object?>;
  }

  // null on 422 (a release for that tag exists already).
  Future<Map<String, Object?>?> post(String url, Object json) async {
    final (code, text) = await _send('POST', url, json: json);
    if (code == 422 && text.contains('already_exists')) return null;
    _check('POST', url, code, text);
    return jsonDecode(text) as Map<String, Object?>;
  }

  Future<void> patch(String url, Object json) async {
    final (code, text) = await _send('PATCH', url, json: json);
    _check('PATCH', url, code, text);
  }

  Future<void> delete(String url) async {
    final (code, text) = await _send('DELETE', url);
    if (code == 404) return;
    _check('DELETE', url, code, text);
  }

  Future<List<Map<String, Object?>>> assets(String base, Object? id) async {
    final (code, text) = await _send('GET', '$base/releases/$id/assets?per_page=100');
    _check('GET', '$base/releases/$id/assets', code, text);
    return [for (final a in jsonDecode(text) as List) a as Map<String, Object?>];
  }

  // GitHub refuses a second asset of the same name, and a failed upload can
  // leave a broken one behind: each try deletes that name first.
  Future<void> replaceAsset(String base, Object? id, String uploadUrl, File f) async {
    final name = _base(f);
    for (var attempt = 1;; attempt++) {
      for (final a in await assets(base, id)) {
        if (a['name'] == name) {
          stdout.writeln('replacing existing $name ...');
          await delete('$base/releases/assets/${a['id']}');
        }
      }
      stdout.writeln('uploading $name ...');
      final url = '$uploadUrl?name=${Uri.encodeQueryComponent(name)}';
      try {
        final (code, text) = await _send('POST', url, file: f);
        if (code >= 200 && code < 300) return;
        if (attempt >= 3 || code < 500) _check('upload', url, code, text);
        stdout.writeln('upload failed (HTTP $code), retrying ($attempt/3) ...');
      } on IOException catch (e) {
        if (attempt >= 3) _die('upload $name: $e');
        stdout.writeln('upload failed ($e), retrying ($attempt/3) ...');
      }
      await Future<void>.delayed(Duration(seconds: 3 * attempt));
    }
  }

  void _check(String what, String url, int code, String text) {
    if (code < 200 || code >= 300) {
      _die('$what $url → HTTP $code: ${text.length > 300 ? text.substring(0, 300) : text}');
    }
  }
}
