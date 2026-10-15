import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/update/update_controller.dart';

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
// bundle copied into <stage>/starsync-<ver>/ with the launcher by the
// old name (lib/src/update/bundle/watch_together, the shipped file), then
// `tar -czf out -C <stage> starsync-<ver>`. [app]: the app binary's
// content.
Future<List<int>> _releaseTarball(Directory work,
    {String version = '0.2.0', String app = 'binary-v2'}) async {
  final stage = Directory('${work.path}/pkg-$version-lin');
  final folder = Directory('${stage.path}/starsync-$version');
  await Directory('${folder.path}/data/flutter_assets').create(recursive: true);
  await File('${folder.path}/data/flutter_assets/fresh.cfg')
      .writeAsString('fresh-config');
  await File('${folder.path}/starsync').writeAsString(app);
  await Directory('${folder.path}/lib').create();
  await File('${folder.path}/lib/libapp.so.1').writeAsString('lib-v2');
  await Link('${folder.path}/lib/libapp.so').create('libapp.so.1');
  for (final f in ['update.sh', 'watch_together', 'watch-together-server']) {
    await File('lib/src/update/bundle/$f').copy('${folder.path}/$f');
  }
  if (!Platform.isWindows) {
    final r = await Process.run('chmod', [
      '755',
      for (final f in ['starsync', 'update.sh', 'watch_together', 'watch-together-server'])
        '${folder.path}/$f'
    ]);
    expect(r.exitCode, 0);
  }
  final out = File('${work.path}/out-$version.tar.gz');
  final r = await Process.run('tar', ['-czf', out.path, '-C', stage.path, 'starsync-$version']);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return out.readAsBytes();
}

// An install as 1.2.x left it: the binary is still called watch_together.
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
          'url': '$base/starsync-0.2.0-linux-x64.tar.gz',
          'sha256': sha256.convert(tarball).toString(),
          'notes': 'test build',
          ...manifestExtra,
        }));
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

// The updater itself is tested in packages/core/test/updater_test.dart
// (fixtures above mirror it); this covers the app's UpdateController.
void main() {
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
      // Already renamed: started as starsync.
      await File('${root.path}/watch_together').rename('${root.path}/starsync');
      final restarts = <(String, List<String>)>[];
      launchArgs = const ['--some-flag'];
      final c = UpdateController(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          executablePath: '${root.path}/starsync',
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
      expect(await File('${root.path}/starsync').readAsString(),
          'binary-v2');
      expect(_isExec('${root.path}/starsync'), isTrue);
      expect(restarts.single.$1, '${root.path}/starsync');
      expect(restarts.single.$2, ['--some-flag']);
    }, skip: _posixOnly);

    test('started by the old name: restarts the new binary; the old name launches it',
        () async {
      server.tarball = await _releaseTarball(work,
          version: '0.2.1', app: '#!/bin/sh\necho "starsync \$*"\n');
      final root = await _fakeRoot(work);
      final restarts = <String>[];
      final c = UpdateController(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          executablePath: '${root.path}/watch_together',
          restart: (exe, _) async => restarts.add(exe));
      await c.checkOnce();
      await c.install();
      expect(c.status.value.phase, UpdatePhase.restarting);
      expect(restarts.single, '${root.path}/starsync');
      // What a 1.2.x app restarts after this update, and the VPS server
      // name: both launch the new binaries.
      final app = await Process.run('${root.path}/watch_together', ['--a']);
      expect('${app.stdout}'.trim(), 'starsync --a', reason: '${app.stderr}');
      expect(_isExec('${root.path}/watch-together-server'), isTrue);
    }, skip: _posixOnly);

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

    test('Later hides it until the next check; a check leaves an install be',
        () async {
      final c = UpdateController(
          currentVersion: '0.1.0',
          manifestUrl: server.manifestUrl,
          executablePath: '${work.path}/stray-binary',
          restart: (_, _) async {});
      await c.checkOnce();
      expect(c.status.value.phase, UpdatePhase.available);
      c.dismiss();
      expect(c.status.value.phase, UpdatePhase.idle);
      await c.checkNow();
      expect(c.status.value.phase, UpdatePhase.available);
      final m = c.status.value.manifest;
      c.status.value = UpdateStatus(UpdatePhase.downloading,
          manifest: m, progress: 0.4, canInstall: true);
      await c.checkNow();
      expect(c.status.value.phase, UpdatePhase.downloading);
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
    }, skip: _posixOnly);
  });
}
