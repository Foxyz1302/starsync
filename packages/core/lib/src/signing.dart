import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:cryptography/cryptography.dart';

// Detached Ed25519 signatures (ARCHITECTURE "Updater", Signing): the
// signature of a file `X` is the file `X.sig` next to it, one line per
// signing key, each the base64 of the 64-byte signature over X's exact
// bytes. Keys travel as base64 of their 32 bytes (the private key as its
// 32-byte seed). Pure Dart (DartEd25519), so the app, the dedicated
// server and the tools sign and check the same way.

final _ed25519 = DartEd25519();

/// The 32 bytes of a base64 public key, or null when it is not one.
List<int>? decodePublicKey(String key) {
  try {
    final bytes = base64.decode(key.trim());
    return bytes.length == 32 ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// Of [keys] (base64 public keys), the index of the last one that made
/// one of the signatures in [sig] (the text of a `.sig` file: one base64
/// signature per line) over [data]; null when none did, so also for an
/// empty or garbled [sig].
Future<int?> verifyDetached(List<int> data, String sig, List<String> keys) async {
  final sigs = <List<int>>[];
  for (final line in const LineSplitter().convert(sig)) {
    if (line.trim().isEmpty) continue;
    try {
      final bytes = base64.decode(line.trim());
      if (bytes.length == 64) sigs.add(bytes);
    } on FormatException {
      // A garbled line proves nothing; the others may still.
    }
  }
  for (var i = keys.length - 1; i >= 0; i--) {
    final pk = decodePublicKey(keys[i]);
    if (pk == null) continue;
    final public = SimplePublicKey(pk, type: KeyPairType.ed25519);
    for (final s in sigs) {
      if (await _ed25519.verify(data, signature: Signature(s, publicKey: public))) return i;
    }
  }
  return null;
}

/// The `.sig` line for [data] made with the private key [seed] (32 bytes).
Future<String> signDetached(List<int> data, List<int> seed) async {
  final pair = await _ed25519.newKeyPairFromSeed(seed);
  final s = await _ed25519.sign(data, keyPair: pair);
  return base64.encode(s.bytes);
}

/// The base64 public key of the private key [seed].
Future<String> publicKeyOf(List<int> seed) async {
  final pair = await _ed25519.newKeyPairFromSeed(seed);
  return base64.encode((await pair.extractPublicKey()).bytes);
}

/// A manifest, config or download that is not the developer's, in plain
/// words for Settings → Updates ([message]); [detail] says why, for the
/// log.
class UpdateRefused implements Exception {
  final String message;
  final String detail;
  const UpdateRefused(this.message, this.detail);

  @override
  String toString() => message;
}

/// What [fetchSigned] read: the file's exact bytes and its `.sig` text
/// (null when the host has no `.sig`, HTTP 404).
typedef SignedFile = ({List<int> body, String? sig});

/// GETs [url] and `[url].sig` with [client]. Throws an [HttpException]
/// when the file itself cannot be read or is larger than [maxBytes], or
/// when the `.sig` fails other than by being absent.
Future<SignedFile> fetchSigned(HttpClient client, String url,
    {Duration timeout = const Duration(seconds: 15), int maxBytes = 1 << 20}) async {
  Future<(int, List<int>)> get(String u) async {
    final req = await client.getUrl(Uri.parse(u)).timeout(timeout);
    final res = await req.close().timeout(timeout);
    final body = <int>[];
    await for (final chunk in res.timeout(timeout)) {
      body.addAll(chunk);
      if (body.length > maxBytes) throw HttpException('larger than $maxBytes bytes', uri: Uri.parse(u));
    }
    return (res.statusCode, body);
  }

  final (code, body) = await get(url);
  if (code != 200) throw HttpException('HTTP $code', uri: Uri.parse(url));
  final (sigCode, sig) = await get('$url.sig');
  if (sigCode == 404) return (body: body, sig: null);
  if (sigCode != 200) throw HttpException('signature: HTTP $sigCode', uri: Uri.parse('$url.sig'));
  return (body: body, sig: utf8.decode(sig, allowMalformed: true));
}
