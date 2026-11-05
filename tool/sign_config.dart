// Publishes a change to the signed config (DEVELOPMENT "Signing", "Moving
// an address"): checks `updates/starsync-config.json`, sets its serial
// one above the committed copy's (unless it is already higher), signs it
// (`starsync-config.json.sig`) and stages both. Commit and push: the
// apps read it from the addresses in `configUrls` / distribution.dart.
// Usage: dart tool/sign_config.dart [--key <path>]...
//   (several --key: signed by each, e.g. the old and the new key during a
//   key handover)
import 'dart:convert';
import 'dart:io';

import 'package:sync_relay_core/core.dart' show RemoteConfig, configFileName;

import 'signing_key.dart';

Future<void> main(List<String> argv) async {
  final args = [...argv];
  final seeds = takeKeys(args);
  if (args.isNotEmpty) {
    stderr.writeln('usage: dart tool/sign_config.dart [--key <path>]...');
    exit(64);
  }
  final root = File.fromUri(Platform.script).parent.parent.path;
  final rel = 'updates/$configFileName';
  final file = File('$root/$rel');
  if (!file.existsSync()) _die('missing: $rel');
  final Map<String, Object?> json;
  try {
    json = (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
  } catch (e) {
    _die('$rel is not a JSON object: $e');
  }
  final committed = Process.runSync('git', ['-C', root, 'show', 'HEAD:$rel']);
  var base = 0;
  if (committed.exitCode == 0) {
    try {
      final s = (jsonDecode(committed.stdout as String) as Map)['serial'];
      if (s is int) base = s;
    } catch (_) {}
  }
  final serial = json['serial'];
  final next = serial is int && serial > base ? serial : base + 1;
  json['serial'] = next;
  try {
    RemoteConfig.fromJson(json);
  } on FormatException catch (e) {
    _die('$rel: ${e.message}');
  }
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(json)}\n');
  stdout.writeln('$rel: serial $next (committed: ${committed.exitCode == 0 ? base : 'none'})');
  await signFiles([file], seeds);
  final add = Process.runSync('git', ['-C', root, 'add', rel, '$rel.sig']);
  if (add.exitCode != 0) _die('git add: ${add.stderr}');
  stdout.writeln('staged $rel and $rel.sig; commit and push them to publish.');
}

Never _die(String msg) {
  stderr.writeln('error: $msg');
  exit(1);
}
