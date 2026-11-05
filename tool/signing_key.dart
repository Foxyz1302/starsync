// The owner's signing key for the tools (keygen.dart, sign.dart,
// sign_config.dart): the 32-byte Ed25519 seed as base64, from the
// environment variable STARSYNC_SIGNING_KEY or the file
// ~/.config/starsync-signing-key (mode 600). Never printed or logged.
// DEVELOPMENT "Signing".
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart' show publicKeyOf, signDetached, trustedKeys, verifyDetached;

const signingKeyEnv = 'STARSYNC_SIGNING_KEY';

String get signingKeyPath {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$home/.config/starsync-signing-key';
}

/// The seed from [signingKeyEnv], else from [path] (default
/// [signingKeyPath]); exits with a plain error when there is none.
List<int> loadSigningKey({String? path}) {
  final env = Platform.environment[signingKeyEnv];
  final file = File(path ?? signingKeyPath);
  final String text;
  final String from;
  if (path == null && env != null && env.trim().isNotEmpty) {
    text = env;
    from = '\$$signingKeyEnv';
  } else if (file.existsSync()) {
    text = file.readAsStringSync();
    from = file.path;
  } else {
    stderr.writeln('error: no signing key: set $signingKeyEnv or put the key in ${file.path} '
        '(DEVELOPMENT "Signing"; a new owner runs dart tool/keygen.dart)');
    exit(1);
  }
  List<int>? seed;
  try {
    seed = base64.decode(text.trim());
  } on FormatException {
    seed = null;
  }
  if (seed == null || seed.length != 32) {
    stderr.writeln('error: the signing key in $from is not a base64 Ed25519 seed (32 bytes)');
    exit(1);
  }
  return seed;
}

/// The seeds of the `--key <path>` options in [args] (each loaded with
/// [loadSigningKey]), or the default key when there is none; removes
/// them from [args].
List<List<int>> takeKeys(List<String> args) {
  final seeds = <List<int>>[];
  while (true) {
    final i = args.indexOf('--key');
    if (i < 0) break;
    if (i + 1 >= args.length) {
      stderr.writeln('error: --key needs a path');
      exit(64);
    }
    seeds.add(loadSigningKey(path: args[i + 1]));
    args.removeRange(i, i + 2);
  }
  return seeds.isEmpty ? [loadSigningKey()] : seeds;
}

/// Writes `<file>.sig` next to each of [files]: one line per seed, each
/// the base64 Ed25519 signature over the file's exact bytes. Warns when no
/// seed is one of distribution.dart's [trustedKeys] (fine during a key
/// handover, a mistake otherwise).
Future<void> signFiles(List<File> files, List<List<int>> seeds) async {
  final publics = [for (final s in seeds) await publicKeyOf(s)];
  if (!publics.any(trustedKeys.contains)) {
    stderr.writeln("warning: the signing key is not in distribution.dart's trustedKeys; "
        'only apps that took it over from a config (nextKey) accept these signatures');
  }
  for (final f in files) {
    final bytes = await f.readAsBytes();
    final lines = [for (final s in seeds) await signDetached(bytes, s)];
    if (await verifyDetached(bytes, lines.join('\n'), publics) == null) {
      stderr.writeln('error: the signature of ${f.path} does not verify');
      exit(1);
    }
    await File('${f.path}.sig').writeAsString('${lines.join('\n')}\n');
    stdout.writeln('signed ${f.path} -> ${f.path}.sig');
  }
}

/// Whether `<file>.sig` is a good signature of [file] by one of [keys].
Future<bool> verifyFile(File file, List<String> keys) async {
  final sig = File('${file.path}.sig');
  if (!await file.exists() || !await sig.exists()) return false;
  return await verifyDetached(await file.readAsBytes(), await sig.readAsString(), keys) != null;
}
