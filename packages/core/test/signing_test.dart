import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_core/testing.dart';
import 'package:test/test.dart';

void main() {
  final owner = TestSigner(1);
  final stranger = TestSigner(2);
  final data = utf8.encode('{"version":"1.5.0"}');
  late String ownerKey;
  late String strangerKey;

  setUpAll(() async {
    ownerKey = await owner.publicKey;
    strangerKey = await stranger.publicKey;
  });

  test('a good signature verifies, by the key that made it', () async {
    final sig = await owner.sign(data);
    expect(await verifyDetached(data, sig, [ownerKey]), 0);
    expect(await verifyDetached(data, sig, [strangerKey, ownerKey]), 1);
  });

  test('tampered data, a wrong key, no or a garbled signature: none', () async {
    final sig = await owner.sign(data);
    final tampered = utf8.encode('{"version":"1.5.1"}');
    expect(await verifyDetached(tampered, sig, [ownerKey]), isNull);
    expect(await verifyDetached(data, sig, [strangerKey]), isNull);
    expect(await verifyDetached(data, await stranger.sign(data), [ownerKey]), isNull);
    expect(await verifyDetached(data, '', [ownerKey]), isNull);
    expect(await verifyDetached(data, 'not base64 at all!\n', [ownerKey]), isNull);
    expect(await verifyDetached(data, base64.encode(List.filled(64, 0)), [ownerKey]), isNull);
    // A key that is not one is skipped, not an error.
    expect(await verifyDetached(data, sig, ['short', ownerKey]), 1);
  });

  test('a .sig with one line per key: any trusted one counts, the newest wins', () async {
    final sig = '${await stranger.sign(data)}${await owner.sign(data)}';
    expect(await verifyDetached(data, sig, [ownerKey]), 0);
    expect(await verifyDetached(data, sig, [ownerKey, strangerKey]), 1);
    expect(await verifyDetached(data, 'garbage\n$sig', [ownerKey]), 0);
  });

  test('public keys: 32 bytes of base64', () async {
    expect(decodePublicKey(ownerKey), hasLength(32));
    expect(decodePublicKey(base64.encode(List.filled(31, 1))), isNull);
    expect(decodePublicKey('%%%'), isNull);
    expect(trustedKeys.map(decodePublicKey), everyElement(isNotNull));
  });

  test('fetchSigned: the file and its .sig; no .sig is null, other failures throw', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      switch (req.uri.path) {
        case '/a.json':
        case '/b.json':
          req.response.add(data);
        case '/a.json.sig':
          req.response.write(await owner.sign(data));
        case '/b.json.sig':
          req.response.statusCode = 404;
        case '/c.json':
          req.response.add(data);
        case '/c.json.sig':
          req.response.statusCode = 500;
        default:
          req.response.statusCode = 404;
      }
      await req.response.close();
    });
    final base = 'http://127.0.0.1:${http.port}';
    final client = HttpClient();
    try {
      final a = await fetchSigned(client, '$base/a.json');
      expect(a.body, data);
      expect(await verifyDetached(a.body, a.sig!, [ownerKey]), 0);
      expect((await fetchSigned(client, '$base/b.json')).sig, isNull);
      await expectLater(fetchSigned(client, '$base/c.json'), throwsA(isA<HttpException>()));
      await expectLater(fetchSigned(client, '$base/gone.json'), throwsA(isA<HttpException>()));
      await expectLater(fetchSigned(client, '$base/a.json', maxBytes: 4), throwsA(isA<HttpException>()));
    } finally {
      client.close();
      await http.close(force: true);
    }
  });
}
