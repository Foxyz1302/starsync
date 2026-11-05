import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:sync_relay_core/core.dart';
import 'package:starsync/src/state/settings.dart';
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
// bundle copied into <stage>/starsync-<ver>/ with the shipped update.sh,
// then `tar -czf out -C <stage> starsync-<ver>`.
Future<List<int>> _releaseTarball(Directory work, {String version = '0.2.0'}) async {
  final stage = Directory('${work.path}/pkg-$version-lin');
  final folder = Directory('${stage.path}/starsync-$version');
  await Directory('${folder.path}/data/flutter_assets').create(recursive: true);
  await File('${folder.path}/data/flutter_assets/fresh.cfg')
      .writeAsString('fresh-config');
  await File('${folder.path}/starsync').writeAsString('binary-v2');
  await Directory('${folder.path}/lib').create();
  await File('${folder.path}/lib/libapp.so.1').writeAsString('lib-v2');
  await Link('${folder.path}/lib/libapp.so').create('libapp.so.1');
  await File('lib/src/update/bundle/update.sh').copy('${folder.path}/update.sh');
  if (!Platform.isWindows) {
    final r = await Process.run('chmod', [
      '755',
      for (final f in ['starsync', 'update.sh']) '${folder.path}/$f'
    ]);
    expect(r.exitCode, 0);
  }
  final out = File('${work.path}/out-$version.tar.gz');
  final r = await Process.run('tar', ['-czf', out.path, '-C', stage.path, 'starsync-$version']);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return out.readAsBytes();
}

// An install whose binary still has the name up to 1.2.x (watch_together).
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

    test('started by the old name: restarts the new binary; the old name is gone',
        () async {
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
      expect(File('${root.path}/watch_together').existsSync(), isFalse);
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

    test('channel: dev offers a newer release; stable in a test build asks before going back', () async {
      var channel = UpdateChannel.dev;
      final root = await _fakeRoot(work);
      final restarts = <String>[];
      // The dev manifest is missing (404): only the stable 0.2.0 is read.
      final c = UpdateController(
          currentVersion: '0.2.0-dev.3',
          manifestUrl: server.manifestUrl,
          devUrl: '${server.base}/dev.json',
          executablePath: '${root.path}/watch_together',
          restart: (exe, _) async => restarts.add(exe))
        ..channelOf = () => channel;
      await c.checkOnce();
      expect(c.status.value.phase, UpdatePhase.available);
      expect(c.status.value.manifest!.version, '0.2.0');
      expect(c.stableBehind.value, isNull);

      final behind = UpdateController(
          currentVersion: '0.3.0-dev.1',
          manifestUrl: server.manifestUrl,
          devUrl: '${server.base}/dev.json',
          executablePath: '${root.path}/watch_together',
          restart: (exe, _) async => restarts.add(exe))
        ..channelOf = () => channel;
      await behind.checkOnce();
      expect(behind.status.value.phase, UpdatePhase.idle); // dev: 0.2.0 is older
      expect(behind.stableBehind.value, isNull);
      channel = UpdateChannel.stable;
      await behind.checkNow();
      expect(behind.status.value.phase, UpdatePhase.idle); // never offered by itself
      expect(behind.stableBehind.value?.version, '0.2.0');
      expect(behind.lastCheck.value, contains('older than this test build'));
      final m = await behind.stableToGoBackTo();
      expect(m?.version, '0.2.0');
      await behind.goBackTo(m!);
      expect(behind.status.value.phase, UpdatePhase.restarting);
      expect(await File('${root.path}/starsync').readAsString(), 'binary-v2');
      expect(restarts, hasLength(1));
    }, skip: _posixOnly);
  });

  group('update channel setting', () {
    late Directory dir;
    setUp(() async {
      dir = await _work();
      Hive.init('${dir.path}/hive');
    });
    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    Future<AppSettings> load(String version) async {
      await Hive.close();
      final s = AppSettings(runningVersion: version, channelFile: File('${dir.path}/update-channel'));
      await s.ensureLoaded();
      return s;
    }

    test('a test build keeps Dev across an update to a release; a choice stays', () async {
      expect((await load('1.3.2')).updateChannel.value, UpdateChannel.stable);
      // Stable by default is not stored: a test build later still starts on Dev.
      expect((await load('1.4.0-dev.1')).updateChannel.value, UpdateChannel.dev);
      // Updated to the release: stays on Dev.
      final s = await load('1.4.0');
      expect(s.updateChannel.value, UpdateChannel.dev);
      s.setUpdateChannel(UpdateChannel.stable);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await load('1.4.1-dev.1')).updateChannel.value, UpdateChannel.stable);
    });

    test('the update-channel file sets the channel once and is deleted', () async {
      expect((await load('1.3.2')).updateChannel.value, UpdateChannel.stable);
      final f = File('${dir.path}/update-channel');
      await f.writeAsString('dev\n');
      expect((await load('1.3.2')).updateChannel.value, UpdateChannel.dev);
      expect(f.existsSync(), isFalse);
      expect((await load('1.3.2')).updateChannel.value, UpdateChannel.dev);
    });
  });
}
