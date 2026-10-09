import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:args/args.dart';
import 'package:logging/logging.dart' as pkg_logging;
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';

/// Dedicated server: `dart compile exe` of this file is shipped as
/// `watch-together-server`. Runs [serve] until SIGINT or SIGTERM.
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8080', help: 'TCP port to listen on (all IPv4 interfaces).')
    ..addOption('secret', defaultsTo: '', help: 'Shared password. Empty means an open server: anyone who can reach it can join.')
    ..addOption('name', defaultsTo: 'server', help: 'Server name, reported by /health.')
    ..addOption('media', defaultsTo: '', help: 'Local file to serve as the starting media.')
    ..addOption('advertise-host', defaultsTo: '', help: 'Host put in file-media URLs instead of the one each client dialled.')
    ..addOption('jellyfin',
        help: 'YAML or JSON file with a Jellyfin login (baseUrl, token, client, device, deviceId, version[, serverId]) '
            'to relay Jellyfin media to viewers without an account. The device fields must be the ones the token was issued with.')
    ..addFlag('yt-dlp',
        defaultsTo: true,
        help: 'Read web pages (YouTube, Twitter/X, ...) for "the server fetches it" with yt-dlp, '
            'downloaded on first use.')
    ..addOption('yt-dlp-dir',
        defaultsTo: '', help: 'Writable folder for that yt-dlp (default: yt-dlp next to this binary).')
    ..addOption('config', help: 'YAML or JSON config file (keys as in AppConfig); overrides the other flags.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exitCode = 64;
    return;
  }
  if (parsed['help'] as bool) {
    // ignore: avoid_print
    print('watch-together-server (proto ${RelayConstants.protoVersion})\n\n${parser.usage}');
    return;
  }

  initLogging(level: pkg_logging.Level.INFO);
  AppConfig config;
  final configPath = parsed['config'] as String?;
  try {
    if (configPath != null) {
      config = await AppConfig.loadFile(configPath);
    } else {
      final port = int.tryParse('${parsed['port']}');
      if (port == null || port < 0 || port > 65535) {
        throw ConfigException('bad --port: ${parsed['port']}');
      }
      config = AppConfig(
        port: port,
        secret: '${parsed['secret']}',
        name: '${parsed['name']}',
        mediaPath: '${parsed['media']}',
        advertiseHost: '${parsed['advertise-host']}',
        ytDlp: parsed['yt-dlp'] as bool,
        ytDlpDir: '${parsed['yt-dlp-dir']}',
      );
    }
    final jellyfinPath = parsed['jellyfin'] as String?;
    if (jellyfinPath != null) {
      final c = config;
      config = AppConfig(
        port: c.port,
        secret: c.secret,
        name: c.name,
        mediaPath: c.mediaPath,
        logLevel: c.logLevel,
        advertiseHost: c.advertiseHost,
        hostKey: c.hostKey,
        jellyfin: await JellyfinCredential.loadFile(jellyfinPath),
        ytDlp: c.ytDlp,
        ytDlpDir: c.ytDlpDir,
      );
    }
  } on ConfigException catch (e) {
    stderr.writeln(e.message);
    exitCode = 64;
    return;
  }
  if (config.secret.isEmpty) {
    stderr.writeln(
        'WARNING: no --secret set: this is an open server, anyone who can reach port ${config.port} can join.');
  }

  final events = ReceivePort('server events');
  final done = serve(config.toMap(), events: events.sendPort);
  final signals = <StreamSubscription<ProcessSignal>>[];
  await for (final msg in events) {
    if (msg is! Map) continue;
    if (msg['t'] == 'error') {
      stderr.writeln('server failed to start: ${msg['message']}');
      exitCode = 1;
      break;
    }
    if (msg['t'] == 'ready') {
      final stop = msg['stop'] as SendPort;
      // ignore: avoid_print
      print('READY port=${msg['port']} name=${config.name}');
      void onSignal(ProcessSignal _) => stop.send({'t': 'stop'});
      signals.add(ProcessSignal.sigint.watch().listen(onSignal));
      if (!Platform.isWindows) {
        signals.add(ProcessSignal.sigterm.watch().listen(onSignal));
      }
      break;
    }
  }
  await done;
  events.close();
  for (final s in signals) {
    await s.cancel();
  }
}
