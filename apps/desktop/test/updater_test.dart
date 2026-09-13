import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/src/update/updater.dart';

void main() {
  test('version compare', () {
    expect(isNewerVersion('0.1.0', '0.1.1'), isTrue);
    expect(isNewerVersion('0.1.0', '0.2.0'), isTrue);
    expect(isNewerVersion('0.1.0', '1.0.0'), isTrue);
    expect(isNewerVersion('0.0.0-dev', '0.1.0'), isTrue);
    expect(isNewerVersion('0.1.0', '0.1.0'), isFalse);
    expect(isNewerVersion('0.2.0', '0.1.9'), isFalse);
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
      'protocol': 4,
      'url': 'https://x/y.tar.gz',
    });
    expect(noSha.sha256, isNull);
  });

  test('findInstallRoot honors bundle layout', () async {
    final tmp = await Directory.systemTemp.createTemp('wt-root-test');
    try {
      final root = Directory('${tmp.path}/root');
      await Directory('${root.path}/data').create(recursive: true);
      await Directory('${root.path}/lib').create(recursive: true);
      final exe = File('${root.path}/watch_together')..createSync();
      expect(findInstallRoot(exe.path)?.path, root.path);
      expect(findInstallRoot('${tmp.path}/stray-binary'), isNull);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  group('upgrade flow', () {
    late HttpServer server;
    late Directory work;
    late List<int> tarball;
    late String tarSha;
    var tarHits = 0;

    setUp(() async {
      tarHits = 0;
      work = await Directory.systemTemp.createTemp('wt-up-test');
      final archive = Archive();
      final v2 = utf8.encode('binary-v2');
      archive.addFile(ArchiveFile('watch_together', v2.length, v2));
      final cfg = utf8.encode('fresh-config');
      archive.addFile(ArchiveFile('data/fresh.cfg', cfg.length, cfg));
      tarball = GZipEncoder().encode(TarEncoder().encode(archive));
      tarSha = sha256.convert(tarball).toString();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path == '/manifest.json') {
          final manifest = {
            'version': '0.2.0',
            'protocol': 4,
            'url':
                'http://127.0.0.1:${server.port}/watch-together-0.2.0.tar.gz',
            'sha256': tarSha,
            'notes': 'test build',
          };
          req.response
            ..statusCode = 200
            ..write(jsonEncode(manifest));
        } else if (req.uri.path == '/watch-together-0.2.0.tar.gz') {
          tarHits++;
          req.response
            ..statusCode = 200
            ..add(tarball);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await work.exists()) {
        await work.delete(recursive: true);
      }
    });

    Future<Directory> fakeRoot() async {
      final root = Directory('${work.path}/root');
      await Directory('${root.path}/data').create(recursive: true);
      await Directory('${root.path}/lib').create(recursive: true);
      await File('${root.path}/watch_together')
          .writeAsString('binary-v1', flush: true);
      return root;
    }

    String manifestUrl() =>
        'http://127.0.0.1:${server.port}/manifest.json';

    test('downloads, verifies and applies', () async {
      final root = await fakeRoot();
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrl: manifestUrl(),
          installRoot: root);
      expect(rc, 0);
      expect(tarHits, 1);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v2');
      expect(await File('${root.path}/data/fresh.cfg').readAsString(),
          'fresh-config');
    });

    test('up to date downloads nothing', () async {
      final root = await fakeRoot();
      final rc = await runUpgrade(
          currentVersion: '0.2.0',
          manifestUrl: manifestUrl(),
          installRoot: root);
      expect(rc, 0);
      expect(tarHits, 0);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v1');
    });

    test('bad hash aborts, install untouched', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path == '/manifest.json') {
          req.response
            ..statusCode = 200
            ..write(jsonEncode({
              'version': '0.2.0',
              'protocol': 4,
              'url':
                  'http://127.0.0.1:${server.port}/watch-together-0.2.0.tar.gz',
              'sha256': '0' * 64,
              'notes': '',
            }));
        } else {
          tarHits++;
          req.response
            ..statusCode = 200
            ..add(tarball);
        }
        await req.response.close();
      });
      final root = await fakeRoot();
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrl: manifestUrl(),
          installRoot: root);
      expect(rc, 1);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v1');
    });

    test('manifest without sha256 still applies', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path == '/manifest.json') {
          req.response
            ..statusCode = 200
            ..write(jsonEncode({
              'version': '0.2.0',
              'protocol': 4,
              'url':
                  'http://127.0.0.1:${server.port}/watch-together-0.2.0.tar.gz',
              'notes': '',
            }));
        } else {
          req.response
            ..statusCode = 200
            ..add(tarball);
        }
        await req.response.close();
      });
      final root = await fakeRoot();
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrl: manifestUrl(),
          installRoot: root);
      expect(rc, 0);
      expect(await File('${root.path}/watch_together').readAsString(),
          'binary-v2');
    });

    test('unknown layout asks for manual update', () async {
      final rc = await runUpgrade(
          currentVersion: '0.1.0',
          manifestUrl: manifestUrl(),
          executablePath: '${work.path}/stray-binary');
      expect(rc, 2);
    });
  });
}
