import 'dart:io';

import 'package:args/args.dart';
import 'package:logging/logging.dart' as pkg_logging;
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8080')
    ..addOption('secret', defaultsTo: 'change-me')
    ..addOption('name', defaultsTo: 'room')
    ..addOption('media', defaultsTo: '')
    ..addOption('advertise-host', defaultsTo: '127.0.0.1')
    ..addOption('config')
    ..addFlag('help', abbr: 'h', negatable: false);
  final parsed = parser.parse(args);
  if (parsed['help'] as bool) {
    // ignore: avoid_print
    print(parser.usage);
    return;
  }

  initLogging(level: pkg_logging.Level.INFO);
  AppConfig config;
  final configPath = parsed['config'] as String?;
  if (configPath != null) {
    config = await AppConfig.loadFile(configPath);
  } else {
    config = AppConfig(
      port: int.tryParse('${parsed['port']}') ?? 8080,
      secret: '${parsed['secret']}',
      name: '${parsed['name']}',
      mediaPath: '${parsed['media']}',
      advertiseHost: '${parsed['advertise-host']}',
    );
  }

  final server = RoomServer(config);
  await server.start();

  // ignore: avoid_print
  print('READY port=${server.boundPort} room=${config.name}');

  await ProcessSignal.sigint.watch().first;
  await server.stop();
}
