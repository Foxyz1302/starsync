// Relay harness: a real SyncServer, a member that swaps a file in as
// relayed media, and that member's RelaySource dialling the server through
// [--via] (e.g. a link shaper). Prints `URL <viewer url>` for players, and
// `STATS ...` every 5 s. Usage:
//   dart run tool/relay_e2e.dart --file x.mkv [--port 9100] [--via 9200]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';

Future<void> main(List<String> argv) async {
  final a = (ArgParser()
        ..addOption('file', mandatory: true)
        ..addOption('port', defaultsTo: '9100')
        ..addOption('via')
        ..addOption('viewers', defaultsTo: '1'))
      .parse(argv);
  final file = File(a['file'] as String);
  final port = int.parse(a['port'] as String);
  final server = SyncServer(AppConfig(port: port, secret: '', name: 'e2e'));
  await server.start();

  Future<(WebSocket, WelcomeMessage)> join(String name) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/sync');
    final welcome = Completer<WelcomeMessage>();
    ws.listen((f) {
      final j = jsonDecode('$f') as Map;
      if (j['t'] == 'welcome' && !welcome.isCompleted) {
        welcome.complete(WelcomeMessage.fromJson(Map<String, Object?>.from(j)));
      }
    });
    ws.add(jsonEncode(HelloMessage(
            proto: RelayConstants.protoVersion,
            secret: '',
            user: HelloUser(name: name))
        .toJson()));
    // Stay alive like a real client (a silent member goes gone).
    Timer.periodic(const Duration(seconds: 1), (_) => ws.add(jsonEncode({'t': 'report', 'position': 0, 'buffered': 0, 'eventId': 0})));
    return (ws, await welcome.future);
  }

  final (srcWs, srcW) = await join('source');
  final name = file.uri.pathSegments.last;
  srcWs.add(jsonEncode(SwapIntent(
          media: HelloMedia(name: name, size: await file.length(), duration: 0, relay: const MediaRelay()))
      .toJson()));
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final via = a['via'] as String? ?? '$port';
  var source = RelaySource(
      Uri.parse('ws://127.0.0.1:$via/r/default/${srcW.token}/source'), RelayMedia.single(FileRelayBytes(file)));
  await source.start();
  final urls = <String>[];
  for (var i = 0; i < int.parse(a['viewers'] as String); i++) {
    urls.add((await join('viewer$i')).$2.mediaUrl!);
  }
  stdout.writeln('URL ${urls.join(',')}');
  Timer.periodic(const Duration(seconds: 5), (_) {
    final b = server.hub.relay?.buffers.firstOrNull;
    stdout.writeln('STATS sourceSent=${source.bytesSent} toViewers=${b?.bytesToViewers} '
        'cached=${b?.cachedBytes} window=${source.window.window}');
  });
  // SIGUSR1: drop the source; SIGUSR2: bring it back (outage tests).
  ProcessSignal.sigusr1.watch().listen((_) => source.close());
  ProcessSignal.sigusr2.watch().listen((_) async {
    source = RelaySource(
        Uri.parse('ws://127.0.0.1:$via/r/default/${srcW.token}/source'), RelayMedia.single(FileRelayBytes(file)));
    await source.start();
  });
}
