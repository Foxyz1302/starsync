import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_core/testing.dart';
import 'package:test/test.dart';

Map<String, Object?> _config(int serial, {List<String>? configUrls, String stable = 'https://s/m.json', String? nextKey}) => {
      'schema': 1,
      'serial': serial,
      'configUrls': configUrls ?? const [],
      'updates': {
        'stable': [stable],
        'dev': ['https://d/m.json'],
      },
      if (nextKey != null) 'nextKey': nextKey,
    };

/// Serves `path -> (json, signer)`; a null signer serves no `.sig`.
class _Hosts {
  late HttpServer http;
  final files = <String, (Map<String, Object?>, TestSigner?)>{};
  final hits = <String>[];

  String get base => 'http://127.0.0.1:${http.port}';
  String url(String path) => '$base$path';

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      final path = req.uri.path;
      hits.add(path);
      final sig = path.endsWith('.sig');
      final f = files[sig ? path.substring(0, path.length - 4) : path];
      if (f == null || (sig && f.$2 == null)) {
        req.response.statusCode = 404;
      } else {
        final bytes = TestSigner.bytesOf(f.$1);
        if (sig) {
          req.response.write(await f.$2!.sign(bytes));
        } else {
          req.response.add(bytes);
        }
      }
      await req.response.close();
    });
  }

  Future<void> stop() => http.close(force: true);
}

void main() {
  final a = TestSigner(1);
  final b = TestSigner(2);
  final c = TestSigner(3);
  late String keyA;
  late String keyB;
  late String keyC;
  late _Hosts hosts;
  late Directory dir;

  setUpAll(() async {
    keyA = await a.publicKey;
    keyB = await b.publicKey;
    keyC = await c.publicKey;
  });

  setUp(() async {
    hosts = _Hosts();
    await hosts.start();
    dir = await Directory.systemTemp.createTemp('starsync-config-test');
  });

  tearDown(() async {
    await hosts.stop();
    await dir.delete(recursive: true);
  });

  RemoteConfigSource source({List<String>? urls, String? extra, bool keep = true}) => RemoteConfigSource(
        dir: keep ? dir.path : null,
        builtInKeys: [keyA],
        builtInUrls: urls ?? [hosts.url('/one.json'), hosts.url('/two.json')],
        extraUrl: () => extra,
        timeout: const Duration(seconds: 2),
      );

  group('RemoteConfig.fromJson', () {
    test('reads a schema-1 config, drops what is not a web address', () {
      final cfg = RemoteConfig.fromJson({
        ..._config(3),
        'configUrls': ['https://x/c.json', 'ftp://x/c.json', 7],
      });
      expect(cfg.serial, 3);
      expect(cfg.configUrls, ['https://x/c.json']);
      expect(cfg.stable, ['https://s/m.json']);
      expect(cfg.dev, ['https://d/m.json']);
      expect(cfg.nextKey, isNull);
    });

    test('refuses another schema, a bad serial, no update addresses or a bad nextKey', () {
      expect(() => RemoteConfig.fromJson({..._config(1), 'schema': 2}), throwsFormatException);
      expect(() => RemoteConfig.fromJson({..._config(1), 'serial': 0}), throwsFormatException);
      expect(() => RemoteConfig.fromJson({..._config(1), 'serial': '2'}), throwsFormatException);
      expect(() => RemoteConfig.fromJson(_config(1, stable: 'not a url')), throwsFormatException);
      expect(() => RemoteConfig.fromJson({..._config(1), 'updates': null}), throwsFormatException);
      expect(() => RemoteConfig.fromJson({..._config(1), 'nextKey': 'abc'}), throwsFormatException);
      expect(() => RemoteConfig.fromJson([]), throwsFormatException);
    });

    test('the repo config is valid and signed by a trusted key', () async {
      final file = File('../../updates/$configFileName');
      final bytes = file.readAsBytesSync();
      final cfg = RemoteConfig.fromJson(jsonDecode(utf8.decode(bytes)));
      expect(cfg.serial, greaterThan(RemoteConfig.builtIn.serial));
      expect(await verifyDetached(bytes, File('${file.path}.sig').readAsStringSync(), trustedKeys), isNotNull,
          reason: 'run dart tool/sign_config.dart after editing it');
    });
  });

  test('no copy anywhere: the built-in values', () async {
    final s = source();
    final cfg = await s.refresh();
    expect(cfg.serial, 0);
    expect(cfg.stable, builtInStableManifestUrls);
    expect(s.keys, [keyA]);
  });

  test('the first good copy with a higher serial is taken and saved', () async {
    hosts.files['/one.json'] = (_config(2, stable: 'https://one/m.json'), a);
    hosts.files['/two.json'] = (_config(3, stable: 'https://two/m.json'), a);
    final s = source();
    expect((await s.refresh()).stable, ['https://one/m.json']);
    expect(hosts.hits, isNot(contains('/two.json')), reason: 'the first newer copy ends the search');
    expect(File('${dir.path}/$configFileName').existsSync(), isTrue);
    // Now at 2: one.json is not newer, two.json (3) is.
    expect((await s.refresh()).stable, ['https://two/m.json']);
    // Nothing newer: stays at 3.
    expect((await s.refresh()).serial, 3);
  });

  test('unsigned or signed by another key: refused, the next address is tried', () async {
    hosts.files['/one.json'] = (_config(5, stable: 'https://evil/m.json'), null);
    hosts.files['/two.json'] = (_config(6, stable: 'https://evil/m.json'), c);
    hosts.files['/three.json'] = (_config(2, stable: 'https://good/m.json'), a);
    final s = source(urls: [hosts.url('/one.json'), hosts.url('/two.json'), hosts.url('/three.json')]);
    final cfg = await s.refresh();
    expect(cfg.stable, ['https://good/m.json']);
    expect(cfg.serial, 2);
    await expectLater(s.accept(TestSigner.bytesOf(_config(9)), null), throwsA(isA<UpdateRefused>()));
  });

  test('every fetch fails: the saved copy; a tampered saved copy is ignored', () async {
    hosts.files['/one.json'] = (_config(4, stable: 'https://saved/m.json'), a);
    await source().refresh();
    final urls = [hosts.url('/one.json'), hosts.url('/two.json')];
    await hosts.stop();
    final later = source(urls: urls);
    final cfg = await later.refresh();
    expect(cfg.serial, 4);
    expect(cfg.stable, ['https://saved/m.json']);

    File('${dir.path}/$configFileName').writeAsStringSync(jsonEncode(_config(9, stable: 'https://evil/m.json')));
    final tampered = source(urls: urls);
    await tampered.load();
    expect(tampered.current.serial, 0);
    await hosts.start(); // tearDown stops it
  });

  test('the config address setting goes first, then the copy\'s configUrls, then the built-in list', () async {
    hosts.files['/mirror.json'] = (_config(2, configUrls: [hosts.url('/moved.json')]), a);
    final s = source(extra: hosts.url('/mirror.json'));
    expect(s.candidates.first, hosts.url('/mirror.json'));
    expect((await s.refresh()).serial, 2);
    expect(s.candidates, [hosts.url('/mirror.json'), hosts.url('/moved.json'), hosts.url('/one.json'), hosts.url('/two.json')]);
    hosts.files['/moved.json'] = (_config(3, stable: 'https://moved/m.json'), a);
    hosts.files['/one.json'] = (_config(7, stable: 'https://one/m.json'), a);
    expect((await s.refresh()).stable, ['https://moved/m.json']);
    // A mirror never brings its own key: unsigned there is refused like anywhere.
    hosts.files['/mirror.json'] = (_config(50), c);
    expect((await s.refresh()).stable, ['https://one/m.json']);
    expect(source(extra: '  not a url ').candidates, [hosts.url('/one.json'), hosts.url('/two.json')]);
  });

  test('key handover: nextKey is trusted once signed in, the old key retires when the new one signs', () async {
    hosts.files['/one.json'] = (_config(2, nextKey: keyB), a);
    final s = source();
    await s.refresh();
    expect(s.keys, [keyA, keyB]);
    // Signed by B alone: taken, and A is no longer trusted.
    hosts.files['/one.json'] = (_config(3, nextKey: keyB), b);
    await s.refresh();
    expect(s.current.serial, 3);
    expect(s.keys, [keyB]);
    hosts.files['/one.json'] = (_config(4, stable: 'https://old-key/m.json'), a);
    expect((await s.refresh()).serial, 3);
    // Kept across starts.
    final later = source(urls: []);
    await later.load();
    expect(later.keys, [keyB]);
    expect(later.current.serial, 3);
    // A nextKey without the current key's signature means nothing.
    hosts.files['/one.json'] = (_config(5, nextKey: keyC), c);
    expect((await s.refresh()).serial, 3);
    expect(s.keys, [keyB]);
  });

  test('without a data folder nothing is kept', () async {
    hosts.files['/one.json'] = (_config(2), a);
    final s = source(keep: false);
    expect((await s.refresh()).serial, 2);
    expect(dir.listSync(), isEmpty);
  });
}
