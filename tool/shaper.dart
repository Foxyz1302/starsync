import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  var listenPort = 8090;
  var targetHost = '127.0.0.1';
  var targetPort = 8080;
  var kbps = 1024;
  var latencyMs = 0;
  var killAfterSecs = 0;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--listen':
        listenPort = int.parse(args[++i]);
      case '--target':
        final parts = args[++i].split(':');
        targetHost = parts[0];
        targetPort = int.parse(parts[1]);
      case '--kbps':
        kbps = int.parse(args[++i]);
      case '--latency-ms':
        latencyMs = int.parse(args[++i]);
      case '--kill-after':
        killAfterSecs = int.parse(args[++i]);
    }
  }
  final server = await ServerSocket.bind(InternetAddress.anyIPv4, listenPort);
  // ignore: avoid_print
  print('SHAPER :$listenPort -> $targetHost:$targetPort ${kbps}KB/s latency=${latencyMs}ms'
      '${killAfterSecs > 0 ? ' kill-after=${killAfterSecs}s' : ''}');
  var dead = false;
  if (killAfterSecs > 0) {
    Timer(Duration(seconds: killAfterSecs), () {
      dead = true;
      // ignore: avoid_print
      print('SHAPER kill switch fired, closing listener');
      server.close();
    });
  }
  await for (final client in server) {
    if (dead) {
      client.close();
      continue;
    }
    Socket? upstream;
    try {
      upstream = await Socket.connect(targetHost, targetPort);
    } catch (e) {
      // ignore: avoid_print
      print('SHAPER upstream refused: $e');
      client.close();
      continue;
    }
    unawaited(_pipe(client, upstream, kbps, latencyMs, 'c->s'));
    unawaited(_pipe(upstream, client, kbps, latencyMs, 's->c'));
  }
}

Future<void> _pipe(Socket from, Socket to, int kbps, int latencyMs, String tag) async {
  final chunkBudget = kbps * 1024 ~/ 10;
  try {
    await for (final data in from) {
      if (latencyMs > 0) await Future.delayed(Duration(milliseconds: latencyMs));
      var offset = 0;
      while (offset < data.length) {
        final end = (offset + chunkBudget).clamp(0, data.length);
        to.add(data.sublist(offset, end));
        await to.flush();
        offset = end;
        if (offset < data.length) await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    await to.close();
  } catch (e) {
    // ignore: avoid_print
    print('SHAPER $tag closed: $e');
    try {
      await to.close();
    } catch (_) {}
  }
}
