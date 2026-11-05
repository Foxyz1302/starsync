import 'dart:convert';

import '../signing.dart';

/// A throwaway signing key for tests (never the owner's): signs JSON
/// documents the way the release tools do, for servers that answer
/// `X` and `X.sig`.
class TestSigner {
  final List<int> seed;
  TestSigner([int fill = 7]) : seed = List.filled(32, fill);

  /// Its base64 public key (for `keys:` / `builtInKeys:`).
  Future<String> get publicKey => publicKeyOf(seed);

  /// The `.sig` text for [bytes].
  Future<String> sign(List<int> bytes) async => '${await signDetached(bytes, seed)}\n';

  /// The exact bytes a test server serves for [json].
  static List<int> bytesOf(Object json) => utf8.encode(jsonEncode(json));
}
