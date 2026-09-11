import 'dart:io';

import 'package:args/args.dart';
import 'package:relic/relic.dart';
import 'package:sync_relay_server/server.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('file', abbr: 'f', help: 'media file to serve')
    ..addOption('port', abbr: 'p', defaultsTo: '8080')
    ..addOption('route', defaultsTo: '/m/file');
  final parsed = parser.parse(args);
  final fileArg = parsed['file'] as String?;
  if (fileArg == null) {
    stderr.writeln('usage: range_logger.dart --file <path> [--port 8080]');
    exit(2);
  }
  final file = File(fileArg);
  if (!await file.exists()) {
    stderr.writeln('file not found: $fileArg');
    exit(2);
  }
  final size = await file.length();
  final app = RelicApp();
  mountMediaRoute(app, file,
      route: parsed['route'] as String,
      onLog: (log) {
        // ignore: avoid_print
        print(log);
      });
  app.fallback = (final req) {
    // ignore: avoid_print
    print('${req.method.name} ${req.url} -> 404');
    return Response.notFound(body: Body.fromString('not found'));
  };
  final server = await app.serve(
    address: InternetAddress.anyIPv4,
    port: int.tryParse('${parsed['port']}') ?? 8080,
  );
  // ignore: avoid_print
  print('SERVING file=$fileArg size=$size on :${server.port}${parsed['route']}');
  await ProcessSignal.sigint.watch().first;
  await app.close();
}
