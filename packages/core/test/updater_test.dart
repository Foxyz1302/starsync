import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_core/testing.dart';
import 'package:test/test.dart';

// Manifests are signed by a throwaway test key, trusted through the
// config source each run gets ([_cfg]: no hosts, nothing kept).
final _signer = TestSigner();
late String _testKey;
RemoteConfigSource _cfg() => RemoteConfigSource(builtInKeys: [_testKey], builtInUrls: []);

// Answers a manifest path with [at]'s JSON and its `.sig` with [signer]'s
// signature (default: the test key); [at] null: 404.
Future<void> _serveManifest(HttpRequest req, Map<String, Object?>? Function(String path) at,
    {TestSigner? signer}) async {
  final path = req.uri.path;
  final sig = path.endsWith('.sig');
  final json = at(sig ? path.substring(0, path.length - 4) : path);
  final by = signer ?? _signer;
  if (json == null) {
    req.response.statusCode = 404;
  } else if (sig) {
    req.response.write(await by.sign(TestSigner.bytesOf(json)));
  } else {
    req.response.add(TestSigner.bytesOf(json));
  }
  await req.response.close();
}

/// A checksum for this platform that is well-formed (not the archive's).
Map<String, Object?> _anySha() => {'assetSha256': {updatePlatform: 'a' * 64}};

// Work dir base: WT_TEST_TMP or the system temp. Staging lives inside
// the install root, so the result doesn't depend on which filesystem
// this is (the old /tmp staging broke when /tmp was tmpfs).
final _tmpBase =
    Platform.environment['WT_TEST_TMP'] ?? Directory.systemTemp.path;

Future<Directory> _work() async {
  final base = Directory(_tmpBase);
  await base.create(recursive: true);
  return base.createTemp('wt-up-test');
}

// Linux-layout tests check exec bits and symlinks, which NTFS lacks.
final _posixOnly = Platform.isWindows ? 'POSIX install layout' : null;

bool _isExec(String path) => File(path).statSync().mode & 0x40 != 0;

// Builds the release archive exactly like tool/package_linux.sh:
// bundle copied into <stage>/starsync-<ver>/, then
// `tar -czf out -C <stage> starsync-<ver>`. [zip]: like
// tool/package_windows.ps1 (`tar -a -c -f out.zip`, bsdtar — Windows only).
// [app]: the app binary's content (Linux).
Future<List<int>> _releaseTarball(Directory work,
    {String version = '0.2.0',
    bool windows = false,
    bool bundle = true,
    bool zip = false,
    String app = 'binary-v2'}) async {
  final stage = Directory('${work.path}/pkg-$version-${windows ? 'win' : 'lin'}');
  final folder = Directory('${stage.path}/starsync-$version');
  await Directory('${folder.path}/data/flutter_assets').create(recursive: true);
  await File('${folder.path}/data/flutter_assets/fresh.cfg')
      .writeAsString('fresh-config');
  if (windows) {
    await File('${folder.path}/starsync.exe').writeAsString('binary-v2');
    await File('${folder.path}/flutter_windows.dll').writeAsString('dll-v2');
  } else {
    await File('${folder.path}/starsync').writeAsString(app);
    if (bundle) {
      await Directory('${folder.path}/lib').create();
      await File('${folder.path}/lib/libapp.so.1').writeAsString('lib-v2');
      await Link('${folder.path}/lib/libapp.so').create('libapp.so.1');
    }
    await File('${folder.path}/update.sh')
        .writeAsString('#!/bin/sh\nexec ./starsync-server --upgrade\n');
    final exec = ['starsync', 'update.sh'];
    if (!Platform.isWindows) {
      final r = await Process.run(
          'chmod', ['755', for (final f in exec) '${folder.path}/$f']);
      expect(r.exitCode, 0);
    }
  }
  final out = File('${work.path}/out-$version.${zip ? 'zip' : 'tar.gz'}');
  final r = await Process.run('tar', [
    ...zip ? ['-a', '-c', '-f'] : ['-czf'],
    out.path,
    '-C',
    stage.path,
    'starsync-$version',
  ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return out.readAsBytes();
}

// An install whose binary still has the name up to 1.2.x (watch_together):
// it must still update, and the update removes that name.
Future<Directory> _fakeRoot(Directory work, {bool windows = false}) async {
  final root = Directory('${work.path}/install');
  await Directory('${root.path}/data').create(recursive: true);
  await File('${root.path}/data/old.cfg').writeAsString('old-config');
  if (windows) {
    await File('${root.path}/watch_together.exe').writeAsString('binary-v1');
    await File('${root.path}/flutter_windows.dll').writeAsString('dll-v1');
  } else {
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/libgone.so').writeAsString('lib-v1');
    await File('${root.path}/watch_together').writeAsString('binary-v1');
    if (!Platform.isWindows) {
      await Process.run('chmod', ['755', '${root.path}/watch_together']);
    }
  }
  await File('${root.path}/user-notes.txt').writeAsString('mine');
  return root;
}

List<String> _leftovers(Directory root) => root
    .listSync()
    .map((e) => e.path.substring(root.path.length + 1))
    .where((n) => n.startsWith('.update'))
    .toList();

// Serves /manifest.json and the tarball. Fields can be overridden per test.
class _Server {
  late HttpServer http;
  List<int> tarball;
  Map<String, Object?> manifestExtra = {};
  bool brokenManifest = false;
  /// Signs the manifest; null: no `.sig`.
  TestSigner? signer = _signer;
  /// Serves a `.sig` of other bytes than the manifest's.
  bool tampered = false;
  int tarHits = 0;
  _Server(this.tarball);

  String get base => 'http://127.0.0.1:${http.port}';
  String get manifestUrl => '$base/manifest.json';

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      if ((req.uri.path == '/manifest.json' || req.uri.path == '/manifest.json.sig') && !brokenManifest) {
        final json = {
          'version': '0.2.0',
          'protocol': RelayConstants.protoVersion,
          'url': '$base/starsync-0.2.0-linux-x64.tar.gz',
          'assetSha256': {updatePlatform: sha256.convert(tarball).toString()},
          'notes': 'test build',
          ...manifestExtra,
        };
        final bytes = TestSigner.bytesOf(json);
        if (req.uri.path == '/manifest.json') {
          req.response.add(bytes);
        } else if (signer == null) {
          req.response.statusCode = 404;
        } else {
          req.response.write(await signer!.sign(tampered ? [...bytes, 32] : bytes));
        }
      } else if (req.uri.path == '/starsync-0.2.0-linux-x64.tar.gz') {
        tarHits++;
        req.response.contentLength = tarball.length;
        req.response.add(tarball);
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }

  Future<void> stop() => http.close(force: true);
}

void main() {
  setUpAll(() async => _testKey = await _signer.publicKey);

  test('version compare', () {
    expect(isNewerVersion('0.1.0', '0.1.1'), isTrue);
    expect(isNewerVersion('0.1.0', '0.2.0'), isTrue);
    expect(isNewerVersion('0.1.0', '1.0.0'), isTrue);
    expect(isNewerVersion('0.0.0-dev', '0.1.0'), isTrue);
    expect(isNewerVersion('0.1.0', '0.1.0'), isFalse);
    expect(isNewerVersion('0.2.0', '0.1.9'), isFalse);
  });

  test('prerelease sorts below its release', () {
    expect(isNewerVersion('1.2.3-rc1', '1.2.3'), isTrue);
    expect(isNewerVersion('1.2.3', '1.2.3-rc1'), isFalse);
    expect(isNewerVersion('1.2.3-rc1', '1.2.3-rc2'), isTrue);
    expect(isNewerVersion('1.2.3-rc.2', '1.2.3-rc.10'), isTrue);
    expect(isNewerVersion('1.2.3-alpha', '1.2.3-beta'), isTrue);
    expect(isNewerVersion('1.2.2', '1.2.3-rc1'), isTrue);
    expect(compareVersions('1.2.3+build5', '1.2.3'), 0);
    expect(compareVersions('1.2.3-rc1', '1.2.3-rc1'), 0);
  });

  test("manifest rejects missing fields; the checksum is this platform's assetSha256", () {
    expect(() => UpdateManifest.fromJson({}), throwsFormatException);
    expect(
        () => UpdateManifest.fromJson({
              'version': '0.2.0',
              'protocol': 4,
            }),
        throwsFormatException);
    final noSha = UpdateManifest.fromJson({
      'version': '0.2.0',
      'protocol': RelayConstants.protoVersion,
      'url': 'https://x/y.tar.gz',
    });
    expect(noSha.sha256, isNull);
    expect(noSha.isRequired, isFalse);
    final shas = {
      'version': '0.2.0',
      'protocol': 4,
      'url': 'https://x/y.tar.gz',
      'sha256': 'b' * 64, // what 1.4.x reads; ignored now
      'assetSha256': {'linux-x64': 'A' * 64, 'windows-x64': 'c' * 64, 'macos-x64': 'short'},
    };
    expect(UpdateManifest.fromJson(shas, platform: 'linux-x64').sha256, 'a' * 64);
    expect(UpdateManifest.fromJson(shas, platform: 'windows-x64').sha256, 'c' * 64);
    expect(UpdateManifest.fromJson(shas, platform: 'macos-x64').sha256, isNull);
    expect(UpdateManifest.fromJson({...shas, 'assetSha256': null}).sha256, isNull);
    expect(
        UpdateManifest.fromJson({
          'version': '0.2.0',
          'protocol': RelayConstants.protoVersion + 1,
          'url': 'https://x/y.tar.gz',
        }).isRequired,
        isTrue);
  });

  test('manifest changes: structured lists, notes kept, old manifests without', () {
    final base = {
      'version': '1.3.3',
      'protocol': RelayConstants.protoVersion,
      'url': 'https://x/y.tar.gz',
      'notes': 'One line for older apps.',
    };
    final old = UpdateManifest.fromJson(base);
    expect(old.changes, isNull);
    expect(old.highlights, isEmpty);
    expect(old.notes, 'One line for older apps.');

    final m = UpdateManifest.fromJson({
      ...base,
      'changes': {
        'added': ['Danmaku style notifications', '  ', 7],
        'fixed': ['Various bug fixes'],
        'later': ['unknown kinds are ignored'],
      },
    });
    expect(m.notes, 'One line for older apps.');
    expect(m.changes!.added, ['Danmaku style notifications']);
    expect(m.changes!.changed, isEmpty);
    expect(m.changes!.fixed, ['Various bug fixes']);
    expect(m.changes!.length, 2);
    expect(ReleaseChanges.fromJson(m.changes!.toJson())!.toJson(), m.changes!.toJson());

    // Junk or empty `changes` (and a non-string `notes`) do not break the manifest.
    for (final junk in [null, 'text', [], {}, {'added': 'no list'}]) {
      expect(UpdateManifest.fromJson({...base, 'changes': junk}).changes, isNull);
    }
    expect(UpdateManifest.fromJson({...base, 'notes': 3}).notes, '');

    // `highlights`: a list of lines, read leniently.
    expect(UpdateManifest.fromJson({...base, 'highlights': [' People cards ', '', 3, 'Six settings pages']}).highlights,
        ['People cards', 'Six settings pages']);
    for (final junk in [null, 'text', {}, 7]) {
      expect(UpdateManifest.fromJson({...base, 'highlights': junk}).highlights, isEmpty);
    }
  });

  test('the repo manifest parses, is signed, has every checksum, and keeps a one-line string notes for 1.2.x/1.3.x',
      () async {
    final file = File('../../updates/manifest.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(await verifyDetached(file.readAsBytesSync(), File('${file.path}.sig').readAsStringSync(), trustedKeys),
        isNotNull,
        reason: 'tool/sign_release.sh writes and signs it');
    for (final platform in (json['assets'] as Map).keys) {
      expect(UpdateManifest.fromJson(json, platform: '$platform').sha256, isNotNull, reason: '$platform');
    }
    // A string sha256 would be checked by 1.4.x against every platform's archive.
    expect(json['sha256'], isNull);
    // Older apps read `(json['notes'] as String?)`: it must stay a string.
    expect(json['notes'], isA<String>());
    expect((json['notes'] as String).contains('\n'), isFalse);
    expect(UpdateManifest.fromJson(json, platform: 'linux-x64').version, json['version']);
  });

  test('manifest picks the asset for this platform', () {
    final json = {
      'version': '0.2.2',
      'protocol': RelayConstants.protoVersion,
      'url': 'https://x/linux.tar.gz',
      'assets': {
        'linux-x64': 'https://x/linux.tar.gz',
        'windows-x64': 'https://x/windows.zip',
      },
    };
    expect(UpdateManifest.fromJson(json, platform: 'windows-x64').url,
        'https://x/windows.zip');
    expect(UpdateManifest.fromJson(json, platform: 'linux-x64').url,
        'https://x/linux.tar.gz');
    expect(() => UpdateManifest.fromJson(json, platform: 'macos-x64'),
        throwsFormatException);
  });

  test('findInstallRoot honors bundle layout', () async {
    final work = await _work();
    try {
      final root = await _fakeRoot(work);
      expect(findInstallRoot('${root.path}/watch_together', windows: false)?.path,
          root.path);
      expect(findInstallRoot('${work.path}/stray-binary', windows: false), isNull);
      final win = await _fakeRoot(await work.createTemp('w'), windows: true);
      expect(findInstallRoot('${win.path}/watch_together.exe', windows: true)?.path,
          win.path);
    } finally {
      await work.delete(recursive: true);
    }
  });

  test('dev builds also read the dev manifest, the newer wins', () async {
    final versions = {'/stable': '1.1.2', '/dev': '1.1.3-dev.2'};
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) => _serveManifest(req, (path) {
          final v = versions[path];
          return v == null ? null : {'version': v, 'protocol': 1, 'url': 'http://x/$v.tar.gz', ..._anySha()};
        }));
    final base = 'http://127.0.0.1:${http.port}';
    Future<String> latest(String current, [UpdateChannel? channel]) async => (await fetchLatestManifest(
            currentVersion: current,
            channel: channel,
            urls: ['$base/stable'],
            devUrls: ['$base/dev'],
            keys: [_testKey]))
        .version;
    try {
      expect(await latest('1.1.2'), '1.1.2'); // stable builds never see dev
      expect(await latest('1.1.3-dev.1'), '1.1.3-dev.2');
      versions['/stable'] = '1.1.3'; // the release outranks its test builds
      expect(await latest('1.1.3-dev.2'), '1.1.3');
      // A release installed on the dev channel still sees the next test line.
      versions['/dev'] = '1.1.4-dev.1';
      expect(await latest('1.1.3', UpdateChannel.dev), '1.1.4-dev.1');
      expect(await latest('1.1.3', UpdateChannel.stable), '1.1.3');
      expect(await latest('1.1.4-dev.1', UpdateChannel.stable), '1.1.3');
      versions.remove('/stable');
      expect(await latest('1.1.3-dev.1'), '1.1.4-dev.1');
    } finally {
      await http.close(force: true);
    }
  });

  test('the manifest comes from the first address that serves one', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stranger = TestSigner(9);
    http.listen((req) async {
      final path = req.uri.path;
      if (path == '/junk' || path == '/junk.sig') {
        req.response.write('<html>moved</html>');
        await req.response.close();
        return;
      }
      await _serveManifest(
          req,
          (p) => switch (p) {
                '/new' || '/old' => {
                    'version': p == '/new' ? '1.5.0' : '1.4.0',
                    'protocol': 1,
                    'url': 'http://x/a.tar.gz',
                    ..._anySha(),
                  },
                '/stranger' => {'version': '6.6.6', 'protocol': 1, 'url': 'http://x/evil.tar.gz', ..._anySha()},
                '/nosum' => {'version': '1.6.0', 'protocol': 1, 'url': 'http://x/a.tar.gz'},
                _ => null,
              },
          signer: path.startsWith('/stranger') ? stranger : null);
    });
    final base = 'http://127.0.0.1:${http.port}';
    // A port nothing listens on: the connection itself fails.
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final gone = 'http://127.0.0.1:${dead.port}/manifest.json';
    await dead.close();
    Future<String> from(List<String> urls) async =>
        (await fetchManifest(urls: urls, keys: [_testKey])).version;
    try {
      expect(await from(['$base/new', '$base/old']), '1.5.0');
      expect(await from([gone, '$base/missing', '$base/junk', '$base/old']), '1.4.0');
      // A manifest signed by another key, or without a checksum, is passed over.
      expect(await from(['$base/stranger', '$base/nosum', '$base/old']), '1.4.0');
      // None serves one: the first address's error...
      await expectLater(fetchManifest(urls: ['$base/missing', '$base/junk'], keys: [_testKey]),
          throwsA(isA<HttpException>()));
      // ... unless one was refused: that says why.
      await expectLater(fetchManifest(urls: ['$base/missing', '$base/stranger'], keys: [_testKey]),
          throwsA(isA<UpdateRefused>().having((e) => e.message, 'message', contains('not signed'))));
      await expectLater(fetchManifest(urls: ['$base/nosum'], keys: [_testKey]),
          throwsA(isA<UpdateRefused>().having((e) => e.message, 'message', contains('no checksum'))));
      // Signed by the right key, but the app trusts another one.
      await expectLater(fetchManifest(urls: ['$base/old'], keys: [await stranger.publicKey]),
          throwsA(isA<UpdateRefused>()));
    } finally {
      await http.close(force: true);
    }
  });

  test('update channel: default, pick by semver, a stable behind a test build', () {
    UpdateManifest m(String v) => UpdateManifest(version: v, protocol: 1, url: 'http://x/$v', notes: '');
    expect(defaultUpdateChannel('1.4.0-dev.3'), UpdateChannel.dev);
    expect(defaultUpdateChannel('1.4.0'), UpdateChannel.stable);
    expect(defaultUpdateChannel('0.0.0-dev'), UpdateChannel.stable);
    expect(UpdateChannel.fromName('dev'), UpdateChannel.dev);
    expect(UpdateChannel.fromName('beta'), isNull);
    String? pick(UpdateChannel ch, String? s, String? d) =>
        pickManifest(ch, stable: s == null ? null : m(s), dev: d == null ? null : m(d))?.version;
    expect(pick(UpdateChannel.dev, '1.4.0', '1.4.0-dev.3'), '1.4.0');
    expect(pick(UpdateChannel.dev, '1.4.0', '1.4.1-dev.1'), '1.4.1-dev.1');
    expect(pick(UpdateChannel.dev, '1.3.2', '1.4.0-dev.3'), '1.4.0-dev.3');
    expect(pick(UpdateChannel.dev, null, '1.4.0-dev.3'), '1.4.0-dev.3');
    expect(pick(UpdateChannel.dev, '1.3.2', null), '1.3.2');
    expect(pick(UpdateChannel.stable, '1.3.2', '1.4.0-dev.3'), '1.3.2');
    expect(isStableBehind('1.4.0-dev.3', m('1.3.2')), isTrue);
    expect(isStableBehind('1.4.0-dev.3', m('1.4.0')), isFalse);
    expect(isStableBehind('1.3.2', m('1.3.1')), isFalse); // not a test build
    expect(isStableBehind('1.4.0-dev.3', m('1.4.0-dev.2')), isFalse);
  });

  group('upgrade flow', () {
    late Directory work;
    late _Server server;

    setUp(() async {
      work = await _work();
      server = _Server(await _releaseTarball(work));
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      if (await work.exists()) await work.delete(recursive: true);
    });

    test('real release layout lands at the install root, modes kept',
        () async {
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrls: [server.manifestUrl],
          config: _cfg(),
          installRoot: root);
      expect(rc, 0);
      expect(server.tarHits, 1);
      final p = root.path;
      expect(await File('$p/starsync').readAsString(), 'binary-v2');
      expect(await File('$p/data/flutter_assets/fresh.cfg').readAsString(),
          'fresh-config');
      expect(Directory('$p/starsync-0.2.0').existsSync(), isFalse);
      expect(_isExec('$p/starsync'), isTrue);
      expect(File('$p/watch_together').existsSync(), isFalse,
          reason: 'the old name goes once starsync is there');
      expect(_isExec('$p/update.sh'), isTrue);
      expect(await Link('$p/lib/libapp.so').target(), 'libapp.so.1');
      expect(await File('$p/lib/libapp.so').readAsString(), 'lib-v2');
      // Bundle dirs are replaced whole; unrelated top-level files stay.
      expect(File('$p/lib/libgone.so').existsSync(), isFalse);
      expect(File('$p/data/old.cfg').existsSync(), isFalse);
      expect(await File('$p/user-notes.txt').readAsString(), 'mine');
      expect(_leftovers(root), isEmpty);
    }, skip: _posixOnly);

    test('up to date downloads nothing', () async {
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.2.0',
          manifestUrls: [server.manifestUrl],
          config: _cfg(),
          installRoot: root);
      expect(rc, 0);
      expect(server.tarHits, 0);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v1');
    });

    test('bad hash aborts, install untouched', () async {
      server.manifestExtra = {'assetSha256': {updatePlatform: '0' * 64}};
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrls: [server.manifestUrl],
          config: _cfg(),
          installRoot: root);
      expect(rc, 1);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v1');
      expect(_leftovers(root), isEmpty);
    });

    test('a manifest without a checksum is refused, nothing downloads', () async {
      server.manifestExtra = {'assetSha256': null};
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrls: [server.manifestUrl],
          config: _cfg(),
          installRoot: root);
      expect(rc, 1);
      expect(server.tarHits, 0);
      expect(await File('${root.path}/watch_together').readAsString(), 'binary-v1');
    });

    for (final (what, setUpServer) in [
      ('unsigned', (_Server s) => s.signer = null),
      ('signed by another key', (_Server s) => s.signer = TestSigner(9)),
      ('tampered after signing', (_Server s) => s.tampered = true),
    ]) {
      test('a manifest $what is refused, nothing downloads', () async {
        setUpServer(server);
        final root = await _fakeRoot(work);
        final rc = await runUpgrade(
            currentVersion: '0.1.0',
            manifestUrls: [server.manifestUrl],
            config: _cfg(),
            installRoot: root);
        expect(rc, 1);
        expect(server.tarHits, 0);
        expect(await File('${root.path}/watch_together').readAsString(), 'binary-v1');
      });
    }

    test('downloadAndApply: a checksum mismatch is a refusal; no checksum refuses before downloading', () async {
      final root = await _fakeRoot(work);
      final m = UpdateManifest(
          version: '0.2.0',
          protocol: RelayConstants.protoVersion,
          url: '${server.base}/starsync-0.2.0-linux-x64.tar.gz',
          sha256: '0' * 64,
          notes: '');
      await expectLater(downloadAndApply(m, root),
          throwsA(isA<UpdateRefused>().having((e) => e.message, 'message', contains('does not match'))));
      expect(server.tarHits, 1);
      final none = UpdateManifest(version: '0.2.0', protocol: 1, url: m.url, notes: '');
      await expectLater(downloadAndApply(none, root), throwsA(isA<UpdateRefused>()));
      expect(server.tarHits, 1);
      expect(await File('${root.path}/watch_together').readAsString(), 'binary-v1');
      expect(_leftovers(root), isEmpty);
    });

    test('unknown layout asks for manual update', () async {
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrls: [server.manifestUrl],
          config: _cfg(),
          executablePath: '${work.path}/stray-binary');
      expect(rc, 2);
    });

    test('archive that is not a bundle is refused, install untouched',
        () async {
      server.tarball = await _releaseTarball(work, version: '9.9.9', bundle: false);
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrls: [server.manifestUrl],
          config: _cfg(),
          installRoot: root);
      expect(rc, 1);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v1');
      expect(File('${root.path}/lib/libgone.so').existsSync(), isTrue);
      expect(_leftovers(root), isEmpty);
    });
  });

  group('apply', () {
    late Directory work;
    setUp(() async => work = await _work());
    tearDown(() async {
      if (await work.exists()) await work.delete(recursive: true);
    });

    Future<File> archive({bool windows = false}) async {
      final f = File('${work.path}/u.tar.gz');
      await f.writeAsBytes(await _releaseTarball(work, windows: windows));
      return f;
    }

    Future<void> expectUntouched(Directory root) async {
      final p = root.path;
      expect(await File('$p/watch_together').readAsString(), 'binary-v1');
      expect(_isExec('$p/watch_together'), isTrue);
      expect(await File('$p/lib/libgone.so').readAsString(), 'lib-v1');
      expect(await File('$p/data/old.cfg').readAsString(), 'old-config');
      expect(File('$p/update.sh').existsSync(), isFalse);
      expect(File('$p/starsync').existsSync(), isFalse);
      expect(_leftovers(root), isEmpty);
    }

    // Each step of the swap (move-aside / move-in per top-level entry)
    // failing must leave the old install fully intact.
    for (final step in [
      'aside:data',
      'in:data',
      'aside:lib',
      'in:starsync',
      'in:update.sh',
    ]) {
      test('failure at $step rolls back', () async {
        final root = await _fakeRoot(work);
        await expectLater(
            applyUpdate(await archive(), root, windows: false, hook: (s) async {
              if (s == step) throw FileSystemException('injected', s);
            }),
            throwsA(isA<FileSystemException>()));
        await expectUntouched(root);
      }, skip: _posixOnly);
    }

    test('stages next to the install, never in the system temp', () async {
      final root = await _fakeRoot(work);
      final seen = <String>[];
      await applyUpdate(await archive(), root, windows: false, hook: (s) async {
        if (seen.isEmpty) {
          seen.add(Directory('${root.path}/.update-staging').existsSync()
              ? 'staged-in-root'
              : 'elsewhere');
        }
      });
      expect(seen, ['staged-in-root']);
    });

    test('unsafe archive entries are rejected', () async {
      final root = await _fakeRoot(work);
      final evil = Archive()
        ..addFile(ArchiveFile('x/../../escape', 3, utf8.encode('bad')));
      final f = File('${work.path}/evil.tar.gz')
        ..writeAsBytesSync(GZipEncoder().encode(TarEncoder().encode(evil)));
      await expectLater(
          applyUpdate(f, root, windows: false), throwsFormatException);
      final link = Archive()
        ..addFile(ArchiveFile.symlink('w/lib/x.so', '../../../etc/passwd'));
      f.writeAsBytesSync(GZipEncoder().encode(TarEncoder().encode(link)));
      await expectLater(
          applyUpdate(f, root, windows: false), throwsFormatException);
      expect(File('${work.path}/escape').existsSync(), isFalse);
      await expectUntouched(root);
    }, skip: _posixOnly);

    test('leftovers from an interrupted run are swept', () async {
      final root = await _fakeRoot(work);
      await Directory('${root.path}/.update-staging/x').create(recursive: true);
      await Directory('${root.path}/.update-backup').create();
      await File('${root.path}/.update-download').writeAsString('partial');
      await File('${root.path}/data/thing.dll.old').writeAsString('o');
      await cleanupUpdateLeftovers(root, windows: false);
      expect(_leftovers(root), isEmpty);
      expect(File('${root.path}/data/thing.dll.old').existsSync(), isFalse);
      // No starsync next to it: the old name is the install's binary, kept.
      expect(await File('${root.path}/watch_together').readAsString(), 'binary-v1');
    });

    // A 1.4.x updater swaps in only what the archive has, so the old names
    // outlive that update: the next start's sweep removes them.
    test('the sweep removes the old names once the new binaries are there',
        () async {
      final root = await _fakeRoot(work);
      final p = root.path;
      for (final n in ['starsync', 'starsync-server', 'watch-together-server']) {
        await File('$p/$n').writeAsString('x');
      }
      await cleanupUpdateLeftovers(root, windows: false);
      expect(File('$p/watch_together').existsSync(), isFalse);
      expect(File('$p/watch-together-server').existsSync(), isFalse);
      expect(File('$p/starsync').existsSync(), isTrue);
      expect(File('$p/starsync-server').existsSync(), isTrue);
      // Each old name only goes with its own new binary next to it.
      final lone = await work.createTemp('lone');
      await File('${lone.path}/starsync').writeAsString('x');
      await File('${lone.path}/watch-together-server').writeAsString('x');
      await removeOldNames(lone, windows: false);
      expect(File('${lone.path}/watch-together-server').existsSync(), isTrue);
    });

    test('started by an old name: applies, removes the old name, restarts starsync',
        () async {
      final root = await _fakeRoot(work);
      final f = File('${work.path}/plain.tar.gz')
        ..writeAsBytesSync(await _releaseTarball(work));
      await applyUpdate(f, root,
          windows: false, executableName: legacyAppBinaryName);
      expect(await File('${root.path}/starsync').readAsString(), 'binary-v2');
      expect(File('${root.path}/watch_together').existsSync(), isFalse);
      expect(relaunchExecutable('${root.path}/watch_together'),
          '${root.path}/starsync');
      // Unknown names still need their binary in the archive.
      final again = File('${work.path}/plain2.tar.gz')
        ..writeAsBytesSync(await _releaseTarball(work, version: '0.3.0'));
      await expectLater(
          applyUpdate(again, root, windows: false, executableName: 'other'),
          throwsFormatException);
    });

    test('relaunchExecutable maps old names to the new binary next to them',
        () async {
      final dir = (await work.createTemp('r')).path;
      for (final n in ['starsync', 'starsync.exe', 'starsync-server']) {
        await File('$dir/$n').writeAsString('x');
      }
      expect(relaunchExecutable('$dir/watch_together'), '$dir/starsync');
      expect(relaunchExecutable('$dir/watch_together.exe'), '$dir/starsync.exe');
      expect(relaunchExecutable('$dir/watch-together-server'),
          '$dir/starsync-server');
      expect(relaunchExecutable('$dir/starsync'), '$dir/starsync');
      expect(relaunchExecutable('$dir/other'), '$dir/other');
      // No new binary next to it: the old name stays.
      expect(relaunchExecutable('${work.path}/watch_together'),
          '${work.path}/watch_together');
      expect(relaunchExecutable(r'C:\x\watch_together.exe'),
          r'C:\x\watch_together.exe');
    });

    // Windows strategy exercised on Linux: proves the bookkeeping, not the
    // Windows file-locking semantics (no Windows runner yet).
    test('windows-style swap applies and parks old files', () async {
      final root = await _fakeRoot(work, windows: true);
      final p = root.path;
      await File('$p/watch_together.exe.old').writeAsString('older');
      await File('$p/watch-together-server.exe').writeAsString('server-v1');
      await applyUpdate(await archive(windows: true), root, windows: true);
      expect(await File('$p/starsync.exe').readAsString(), 'binary-v2');
      expect(await File('$p/flutter_windows.dll').readAsString(), 'dll-v2');
      expect(await File('$p/data/flutter_assets/fresh.cfg').readAsString(),
          'fresh-config');
      // Not in use here, so the .old copies were deleted right away.
      expect(File('$p/flutter_windows.dll.old').existsSync(), isFalse);
      // The old app name goes with its .old copy; the server's old name
      // stays, this archive has no starsync-server.exe.
      expect(File('$p/watch_together.exe').existsSync(), isFalse);
      expect(File('$p/watch_together.exe.old').existsSync(), isFalse);
      expect(File('$p/watch-together-server.exe').existsSync(), isTrue);
      expect(_leftovers(root), isEmpty);
    });

    test('windows-style swap rolls back', () async {
      final root = await _fakeRoot(work, windows: true);
      await expectLater(
          applyUpdate(await archive(windows: true), root, windows: true,
              hook: (s) async {
            if (s == 'in:starsync.exe') {
              throw const FileSystemException('injected');
            }
          }),
          throwsA(isA<FileSystemException>()));
      final p = root.path;
      expect(await File('$p/watch_together.exe').readAsString(), 'binary-v1');
      expect(await File('$p/flutter_windows.dll').readAsString(), 'dll-v1');
      expect(File('$p/data/flutter_assets/fresh.cfg').existsSync(), isFalse);
      expect(File('$p/starsync.exe').existsSync(), isFalse);
      expect(File('$p/flutter_windows.dll.old').existsSync(), isFalse);
      expect(_leftovers(root), isEmpty);
    });

    // The real thing: the release zip (bsdtar, like package_windows.ps1)
    // applied over an install whose exes are running. Windows refuses to
    // delete a running image but allows renaming it, so the running
    // starsync.exe is parked as .old, and so is a running copy by the old
    // name (no longer in the archive); both are swept on the next start.
    test('windows: zip over a running exe', () async {
      final root = await _fakeRoot(work, windows: true);
      final exe = '${root.path}/starsync.exe';
      final old = '${root.path}/watch_together.exe';
      await File(r'C:\Windows\System32\PING.EXE').copy(exe);
      await File(r'C:\Windows\System32\PING.EXE').copy(old);
      final zip = File('${work.path}/u.zip')
        ..writeAsBytesSync(
            await _releaseTarball(work, windows: true, zip: true));
      final running = [
        for (final e in [exe, old]) await Process.start(e, ['-n', '60', '127.0.0.1'])
      ];
      try {
        for (final e in [exe, old]) {
          expect(() => File(e).deleteSync(), throwsA(isA<FileSystemException>()),
              reason: 'precondition: a running exe is locked');
        }
        await applyUpdate(zip, root, windows: true);
        expect(await File(exe).readAsString(), 'binary-v2');
        expect(File('$exe.old').existsSync(), isTrue);
        expect(File(old).existsSync(), isFalse);
        expect(File('$old.old').existsSync(), isTrue);
        expect(relaunchExecutable(old), exe);
        expect(
            await File('${root.path}/data/flutter_assets/fresh.cfg')
                .readAsString(),
            'fresh-config');
        expect(_leftovers(root), isEmpty);
      } finally {
        for (final r in running) {
          r.kill();
          await r.exitCode;
        }
      }
      await cleanupUpdateLeftovers(root);
      expect(File('$exe.old').existsSync(), isFalse);
      expect(File('$old.old').existsSync(), isFalse);
    }, skip: Platform.isWindows ? null : 'needs Windows');
  });
}
