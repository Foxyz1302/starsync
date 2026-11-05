// Signs files for the updater (DEVELOPMENT "Signing"): writes `<file>.sig`
// next to each, one base64 Ed25519 signature per key. The key: each
// `--key <path>`, else STARSYNC_SIGNING_KEY or ~/.config/starsync-signing-key.
// Usage: dart tool/sign.dart [--key <path>]... <file>...
//        dart tool/sign.dart --verify [--pub <base64>]... <file>...
//          (exit 1 unless each `<file>.sig` is good for distribution.dart's
//          trustedKeys, or the given public keys)
//        dart tool/sign.dart --check-key  (exit 1 when there is no key)
import 'dart:io';

import 'package:sync_relay_core/core.dart' show publicKeyOf, trustedKeys;

import 'signing_key.dart';

Future<void> main(List<String> argv) async {
  final args = [...argv];
  if (args.remove('--check-key')) {
    final key = await publicKeyOf(loadSigningKey());
    stdout.writeln(trustedKeys.contains(key)
        ? 'signing key found (trusted by distribution.dart)'
        : 'signing key found (NOT in distribution.dart\'s trustedKeys)');
    return;
  }
  if (args.remove('--verify')) {
    final pubs = <String>[];
    while (true) {
      final i = args.indexOf('--pub');
      if (i < 0 || i + 1 >= args.length) break;
      pubs.add(args[i + 1]);
      args.removeRange(i, i + 2);
    }
    if (args.isEmpty) _usage();
    var bad = 0;
    for (final path in args) {
      final ok = await verifyFile(File(path), pubs.isEmpty ? trustedKeys : pubs);
      stdout.writeln('${ok ? 'good' : 'NOT GOOD'}: $path');
      if (!ok) bad++;
    }
    if (bad > 0) exit(1);
    return;
  }
  final seeds = takeKeys(args);
  if (args.isEmpty || args.any((a) => a.startsWith('--'))) _usage();
  for (final path in args) {
    if (!File(path).existsSync()) {
      stderr.writeln('error: missing: $path');
      exit(1);
    }
  }
  await signFiles([for (final p in args) File(p)], seeds);
}

Never _usage() {
  stderr.writeln('usage: dart tool/sign.dart [--key <path>]... <file>...\n'
      '       dart tool/sign.dart --verify [--pub <base64>]... <file>...\n'
      '       dart tool/sign.dart --check-key');
  exit(64);
}
