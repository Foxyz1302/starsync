import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:watch_together/src/update/update_controller.dart';
import 'package:watch_together/src/update/updater.dart';

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

bool _isExec(String path) => File(path).statSync().mode & 0x40 != 0;

// Builds the release archive exactly like tool/package_linux.sh:
// bundle copied into <stage>/watch-together-<ver>/, then
// `tar -czf out -C <stage> watch-together-<ver>`.
Future<List<int>> _releaseTarball(Directory work,
    {String version = '0.2.0', bool windows = false, bool bundle = true}) async {
  final stage = Directory('${work.path}/pkg-$version-${windows ? 'win' : 'lin'}');
  final folder = Directory('${stage.path}/watch-together-$version');
  await Directory('${folder.path}/data/flutter_assets').create(recursive: true);
  await File('${folder.path}/data/flutter_assets/fresh.cfg')
      .writeAsString('fresh-config');
  if (windows) {
    await File('${folder.path}/watch_together.exe').writeAsString('binary-v2');
    await File('${folder.path}/flutter_windows.dll').writeAsString('dll-v2');
  } else {
    await File('${folder.path}/watch_together').writeAsString('binary-v2');
    if (bundle) {
      await Directory('${folder.path}/lib').create();
      await File('${folder.path}/lib/libapp.so.1').writeAsString('lib-v2');
      await Link('${folder.path}/lib/libapp.so').create('libapp.so.1');
    }
    await File('${folder.path}/update.sh')
        .writeAsString('#!/bin/sh\nexec ./watch_together --upgrade\n');
    final r = await Process.run('chmod',
        ['755', '${folder.path}/watch_together', '${folder.path}/update.sh']);
    expect(r.exitCode, 0);
  }
  final out = File('${work.path}/out-$version.tar.gz');
  final r = await Process.run('tar', [
    '-czf',
    out.path,
    '-C',
    stage.path,
    'watch-together-$version',
  ]);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return out.readAsBytes();
}

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
    await Process.run('chmod', ['755', '${root.path}/watch_together']);
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
  int tarHits = 0;
  _Server(this.tarball);

  String get base => 'http://127.0.0.1:${http.port}';
  String get manifestUrl => '$base/manifest.json';

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      if (req.uri.path == '/manifest.json' && !brokenManifest) {
        req.response.write(jsonEncode({
          'version': '0.2.0',
          'protocol': RelayConstants.protoVersion,
          'url': '$base/watch-together-0.2.0-linux-x64.tar.gz',
          'sha256': sha256.convert(tarball).toString(),
          'notes': 'test build',
          ...manifestExtra,
        }));
      } else if (req.uri.path == '/watch-together-0.2.0-linux-x64.tar.gz') {
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

  test('manifest rejects missing fields, sha256 is optional', () {
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
    expect(
        UpdateManifest.fromJson({
          'version': '0.2.0',
          'protocol': RelayConstants.protoVersion + 1,
          'url': 'https://x/y.tar.gz',
        }).isRequired,
        isTrue);
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
          manifestUrl: server.manifestUrl,
          installRoot: root);
      expect(rc, 0);
      expect(server.tarHits, 1);
      final p = root.path;
      expect(await File('$p/watch_together').readAsString(), 'binary-v2');
      expect(await File('$p/data/flutter_assets/fresh.cfg').readAsString(),
          'fresh-config');
      expect(Directory('$p/watch-together-0.2.0').existsSync(), isFalse);
      expect(_isExec('$p/watch_together'), isTrue);
      expect(_isExec('$p/update.sh'), isTrue);
      expect(await Link('$p/lib/libapp.so').target(), 'libapp.so.1');
      expect(await File('$p/lib/libapp.so').readAsString(), 'lib-v2');
      // Bundle dirs are replaced whole; unrelated top-level files stay.
      expect(File('$p/lib/libgone.so').existsSync(), isFalse);
      expect(File('$p/data/old.cfg').existsSync(), isFalse);
      expect(await File('$p/user-notes.txt').readAsString(), 'mine');
      expect(_leftovers(root), isEmpty);
    });

    test('up to date downloads nothing', () async {
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.2.0',
          manifestUrl: server.manifestUrl,
          installRoot: root);
      expect(rc, 0);
      expect(server.tarHits, 0);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v1');
    });

    test('bad hash aborts, install untouched', () async {
      server.manifestExtra = {'sha256': '0' * 64};
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          installRoot: root);
      expect(rc, 1);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v1');
      expect(_leftovers(root), isEmpty);
    });

    test('manifest without sha256 still applies', () async {
      server.manifestExtra = {'sha256': null};
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          installRoot: root);
      expect(rc, 0);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v2');
    });

    test('unknown layout asks for manual update', () async {
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          executablePath: '${work.path}/stray-binary');
      expect(rc, 2);
    });

    test('archive that is not a bundle is refused, install untouched',
        () async {
      server.tarball = await _releaseTarball(work, version: '9.9.9', bundle: false);
      final root = await _fakeRoot(work);
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
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
      expect(_leftovers(root), isEmpty);
    }

    // Each step of the swap (move-aside / move-in per top-level entry)
    // failing must leave the old install fully intact.
    for (final step in [
      'aside:data',
      'in:data',
      'aside:lib',
      'in:update.sh',
      'aside:watch_together',
      'in:watch_together',
    ]) {
      test('failure at $step rolls back', () async {
        final root = await _fakeRoot(work);
        await expectLater(
            applyUpdate(await archive(), root, windows: false, hook: (s) async {
              if (s == step) throw FileSystemException('injected', s);
            }),
            throwsA(isA<FileSystemException>()));
        await expectUntouched(root);
      });
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
    });

    test('leftovers from an interrupted run are swept', () async {
      final root = await _fakeRoot(work);
      await Directory('${root.path}/.update-staging/x').create(recursive: true);
      await Directory('${root.path}/.update-backup').create();
      await File('${root.path}/.update-download').writeAsString('partial');
      await File('${root.path}/data/thing.dll.old').writeAsString('o');
      await cleanupUpdateLeftovers(root);
      expect(_leftovers(root), isEmpty);
      expect(File('${root.path}/data/thing.dll.old').existsSync(), isFalse);
    });

    // Windows strategy exercised on Linux: proves the bookkeeping, not the
    // Windows file-locking semantics (no Windows runner yet).
    test('windows-style swap applies and parks old files', () async {
      final root = await _fakeRoot(work, windows: true);
      await applyUpdate(await archive(windows: true), root, windows: true);
      final p = root.path;
      expect(await File('$p/watch_together.exe').readAsString(), 'binary-v2');
      expect(await File('$p/flutter_windows.dll').readAsString(), 'dll-v2');
      expect(await File('$p/data/flutter_assets/fresh.cfg').readAsString(),
          'fresh-config');
      // Not in use here, so the .old copies were deleted right away.
      expect(File('$p/watch_together.exe.old').existsSync(), isFalse);
      expect(_leftovers(root), isEmpty);
    });

    test('windows-style swap rolls back', () async {
      final root = await _fakeRoot(work, windows: true);
      await expectLater(
          applyUpdate(await archive(windows: true), root, windows: true,
              hook: (s) async {
            if (s == 'in:watch_together.exe') {
              throw const FileSystemException('injected');
            }
          }),
          throwsA(isA<FileSystemException>()));
      final p = root.path;
      expect(await File('$p/watch_together.exe').readAsString(), 'binary-v1');
      expect(await File('$p/flutter_windows.dll').readAsString(), 'dll-v1');
      expect(File('$p/data/flutter_assets/fresh.cfg').existsSync(), isFalse);
      expect(File('$p/flutter_windows.dll.old').existsSync(), isFalse);
      expect(_leftovers(root), isEmpty);
    });
  });

  group('in-app controller', () {
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

    test('check, download with progress, apply, restart same binary',
        () async {
      final root = await _fakeRoot(work);
      final restarts = <(String, List<String>)>[];
      launchArgs = const ['--some-flag'];
      final c = UpdateController(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          executablePath: '${root.path}/watch_together',
          restart: (exe, args) async => restarts.add((exe, args)));
      await c.checkOnce();
      expect(c.status.value.phase, UpdatePhase.available);
      expect(c.status.value.canInstall, isTrue);
      expect(c.status.value.manifest!.isRequired, isFalse);
      final progress = <double>[];
      c.status.addListener(() {
        final p = c.status.value.progress;
        if (p != null) progress.add(p);
      });
      await c.install();
      expect(progress.last, 1.0);
      expect(c.status.value.phase, UpdatePhase.restarting);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v2');
      expect(_isExec('${root.path}/watch_together'), isTrue);
      expect(restarts.single.$1, '${root.path}/watch_together');
      expect(restarts.single.$2, ['--some-flag']);
    });

    test('newer protocol is a required update, cannot be dismissed',
        () async {
      server.manifestExtra = {'protocol': RelayConstants.protoVersion + 1};
      final c = UpdateController(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          executablePath: '${work.path}/stray-binary',
          restart: (_, _) async {});
      await c.checkOnce();
      expect(c.status.value.manifest!.isRequired, isTrue);
      expect(c.status.value.canInstall, isFalse);
      c.dismiss();
      expect(c.status.value.phase, UpdatePhase.available);
    });

    test('failed check stays quiet; dev builds skip the check', () async {
      server.brokenManifest = true;
      final c = UpdateController(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          executablePath: '${work.path}/stray-binary',
          restart: (_, _) async {});
      await c.checkOnce();
      expect(c.status.value.phase, UpdatePhase.idle);
      server.brokenManifest = false;
      final dev = UpdateController(
          currentVersion: '0.0.0-dev',
          manifestUrl: server.manifestUrl,
          executablePath: '${work.path}/stray-binary',
          restart: (_, _) async {});
      await dev.checkOnce();
      expect(dev.status.value.phase, UpdatePhase.idle);
    });

    test('failed install shows error, install untouched, retry works',
        () async {
      server.manifestExtra = {'sha256': '0' * 64};
      final root = await _fakeRoot(work);
      var restarted = false;
      final c = UpdateController(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          executablePath: '${root.path}/watch_together',
          restart: (_, _) async => restarted = true);
      await c.checkOnce();
      await c.install();
      expect(c.status.value.phase, UpdatePhase.failed);
      expect(c.status.value.error, contains('sha256'));
      expect(restarted, isFalse);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v1');
    });
  });
}
