import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as pkg_logging;
import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';

import 'media_endpoint.dart';
import 'server_hub.dart';
import 'session.dart';

class SyncServer {
  final AppConfig config;
  final pkg_logging.Logger _log = createLogger('sync_server');
  final RelicApp _app = RelicApp();
  final SessionMap sessions = SessionMap();
  late final ServerHub hub;
  RelicServer? _server;
  DateTime? _startedAt;
  Timer? _heartbeat;
  bool _routesMounted = false;

  SyncServer(this.config) {
    hub = ServerHub(sessions, config.secret, hostKey: config.hostKey);
  }

  bool get isRunning => _server != null;
  int get boundPort => _server?.port ?? config.port;
  Session get session => sessions.getOrCreate('default', config.secret);

  Future<bool> setLocalFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final name = file.path.split(Platform.pathSeparator).last;
    final size = await file.length();
    session.media = SessionMedia(name: name, size: size, duration: 0, file: file);
    hub.engine.media = HelloMedia(name: name, size: size, duration: 0);
    return true;
  }

  void _mountRoutes() {
    if (_routesMounted) return;
    _routesMounted = true;
    _app.get('/health', (final req) {
      final s = sessions.get('default');
      final viewers = s?.tokens.length ?? 0;
      final bytes = s?.totalBytesServed ?? 0;
      final uptime = _startedAt == null ? 0 : DateTime.now().difference(_startedAt!).inSeconds;
      return Response.ok(
        body: Body.fromString(jsonEncode({
          'ok': true,
          'name': config.name,
          'proto': RelayConstants.protoVersion,
          'viewers': viewers,
          'bytesServed': bytes,
          'uptimeSecs': uptime,
        })),
      );
    });
    mountSessionMediaRoute(_app, sessions);
    mountSyncRoute(_app, hub, (sid, token, media, dialledHost) {
      final name = Uri.encodeComponent(media?.name ?? 'file');
      // advertiseHost is only an explicit override; otherwise echo what the client dialled.
      final authority = config.advertiseHost.isNotEmpty
          ? '${config.advertiseHost}:$boundPort'
          : dialledHost;
      return 'http://$authority/m/$sid/$token/$name';
    });
    _app.fallback = (final req) => Response.notFound(
          body: Body.fromString('not found'),
        );
  }

  Future<void> start() async {
    if (_server != null) return;
    final s = session;
    if (config.mediaPath.isNotEmpty) {
      final file = File(config.mediaPath);
      if (await file.exists()) {
        final name = file.path.split(Platform.pathSeparator).last;
        final size = await file.length();
        s.media = SessionMedia(name: name, size: size, duration: 0, file: file);
        hub.engine.media = HelloMedia(name: name, size: size, duration: 0);
      } else {
        _log.warning('media file not found: ${config.mediaPath}');
      }
    }
    if (config.secret.isEmpty) {
      _log.warning('no password set: open server, anyone who can reach it can join');
    }
    _mountRoutes();
    _server = await _app.serve(
      address: InternetAddress.anyIPv4,
      port: config.port,
      // A killed isolate never closes its listening socket, so the port stays
      // bound in this process. Shared lets the next server in the same
      // process bind it again (it then gets all connections); another
      // process is still refused.
      shared: true,
    );
    _startedAt = DateTime.now();
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      hub.engine.tick();
      hub.sweepClosedSockets();
      hub.dropSilentSockets();
      hub.broadcastState();
      hub.broadcastFeed();
    });
    _log.info('server "${config.name}" listening on $boundPort');
  }

  Future<void> stop() async {
    if (_server == null) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    await hub.closeAllSockets();
    await _app.close();
    _server = null;
    _log.info('server "${config.name}" stopped');
  }
}
