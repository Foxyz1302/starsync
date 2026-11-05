// Makes the owner's Ed25519 signing key pair (DEVELOPMENT "Signing"):
// the private key (its 32-byte seed, base64) goes to
// ~/.config/starsync-signing-key with mode 600 and is never printed;
// the public key is printed, for distribution.dart (`trustedKeys`) or a
// config's `nextKey`. Refuses to overwrite an existing file.
// Usage: dart tool/keygen.dart [--out <path>]
//   (--out: a second key for a handover, kept apart from the current one)
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sync_relay_core/core.dart' show publicKeyOf;

import 'signing_key.dart';

Future<void> main(List<String> args) async {
  var path = signingKeyPath;
  if (args.length == 2 && args[0] == '--out') {
    path = args[1];
  } else if (args.isNotEmpty) {
    stderr.writeln('usage: dart tool/keygen.dart [--out <path>]');
    exit(64);
  }
  final file = File(path);
  if (file.existsSync() || Link(path).existsSync()) {
    stderr.writeln('error: $path already exists; not overwriting a signing key '
        '(move it away yourself if you really mean to replace it)');
    exit(1);
  }
  await file.parent.create(recursive: true);
  final rnd = Random.secure();
  final seed = List<int>.generate(32, (_) => rnd.nextInt(256));
  // Created empty and made 600 before the key goes in.
  await file.create(exclusive: true);
  if (!Platform.isWindows) {
    final r = await Process.run('chmod', ['600', path]);
    if (r.exitCode != 0) {
      await file.delete();
      stderr.writeln('error: chmod 600 $path failed: ${r.stderr}');
      exit(1);
    }
  }
  await file.writeAsString('${base64.encode(seed)}\n', flush: true);
  stdout.writeln('private key written to $path (mode 600). Back it up somewhere safe and offline;');
  stdout.writeln('without it no update can be signed. Never commit or share it.');
  stdout.writeln('public key (for distribution.dart):');
  stdout.writeln(await publicKeyOf(seed));
}
