import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as pkg_logging;
import 'package:relic/relic.dart';
import 'package:sync_relay_core/core.dart';

import 'jellyfin_relay.dart';
import 'media_endpoint.dart';
import 'relay_routes.dart';
import 'server_hub.dart';
import 'session.dart';
import 'session_log.dart';

/// [configured], else systemd's `$STATE_DIRECTORY/yt-dlp`, else `yt-dlp`
/// next to the server binary when that is writable (not under `dart run`),
/// else `~/.cache/watch-together/yt-dlp`.
String serverYtDlpDir(String configured) => configured.isNotEmpty ? configured : serverDataDir('yt-dlp');

/// A writable folder [name] for the dedicated server's own files:
/// `$STATE_DIRECTORY/<name>` (systemd), else next to the binary if
/// writable, else `~/.cache/watch-together/<name>`.
String serverDataDir(String name) {
  final sep = Platform.pathSeparator;
  final state = (Platform.environment['STATE_DIRECTORY'] ?? '').split(':').first;
  if (state.isNotEmpty) return '$state$sep$name';
  final exe = File(Platform.resolvedExecutable);
  final exeName = exe.uri.pathSegments.last.toLowerCase();
  if (exeName != 'dart' && exeName != 'dart.exe' && exeName != 'dartaotruntime') {
    final dir = Directory('${exe.parent.path}$sep$name');
    try {
      dir.createSync(recursive: true);
      final probe = File('${dir.path}$sep.writable')..writeAsStringSync('');
      probe.deleteSync();
      return dir.path;
    } catch (_) {}
  }
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$home$sep.cache${sep}watch-together$sep$name';
}

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
  /// Upstream connections of the Jellyfin relay; created on first use.
  HttpClient? _relayClient;

  /// Listen on 127.0.0.1 only (the app's solo session), not on every
  /// IPv4 interface.
  final bool loopbackOnly;

  /// The folder of the session log (`session-YYYY-MM-DD.log`, every
  /// member's diagnostics and the server's records merged); null: none.
  final String? logDir;
  SessionLog? _sessionLog;

  /// The session log while running with a [logDir].
  SessionLog? get sessionLog => _sessionLog;

  /// [ytDlp] replaces the server's own (tests).
  SyncServer(this.config, {YtDlp? ytDlp, this.loopbackOnly = false, this.logDir}) {
    hub = ServerHub(sessions, config.secret,
        hostKey: config.hostKey,
        jellyfin: config.jellyfin,
        ytDlp: ytDlp ?? YtDlp(serverYtDlpDir(config.ytDlpDir), enabled: config.ytDlp));
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
    final requests = MediaRequestLog();
    void logRequest(String token, MediaLog log) => requests(hub.who(token), log);
    mountSessionMediaRoute(_app, sessions, onLog: logRequest);
    mountRelayRoutes(_app, sessions, relayAt: hub.relayAt, sourceOf: hub.sourceOf, onLog: logRequest);
    mountAvatarRoute(_app, hub);
    mountArtRoute(_app, hub);
    mountSessionLogRoutes(_app, hub, () => _sessionLog);
    mountJellyfinRelayRoute(
        _app, sessions, () => hub.jellyfin, () => _relayClient ??= HttpClient(),
        next: () => hub.nextJellyfinRef, onLog: logRequest);
    // advertiseHost is only an explicit override; otherwise echo what the client dialled.
    String authority(String dialledHost) => config.advertiseHost.isNotEmpty
        ? '${config.advertiseHost}:$boundPort'
        : dialledHost;
    mountSyncRoute(_app, hub, (sid, token, media, dialledHost) {
      final name = Uri.encodeComponent(media?.name ?? 'file');
      return 'http://${authority(dialledHost)}/m/$sid/$token/$name';
    }, relayUrlBuilder: (sid, token, itemId, dialledHost) =>
        'http://${authority(dialledHost)}/j/$sid/$token/${Uri.encodeComponent(itemId)}',
        relayMediaUrlBuilder: (sid, token, key, name, tracks, dialledHost) =>
            relayViewerUrl('http://${authority(dialledHost)}/r/$sid/$token/$key', name, tracks: tracks));
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
    final dir = logDir;
    if (dir != null && _sessionLog == null) {
      try {
        _sessionLog = SessionLog(dir)..captureOwn();
      } catch (e) {
        _log.warning('no session log: cannot write $dir ($e)');
      }
    }
    await _resolveJellyfinServerId();
    _mountRoutes();
    _server = await _app.serve(
      address: loopbackOnly ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4,
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
      hub.sampleRates();
      hub.broadcastState();
      hub.broadcastFeed();
      _sessionLog?.flush();
    });
    _log.info('server "${config.name}" listening on $boundPort');
  }

  /// A configured credential without a ServerId gets it from
  /// `/System/Info/Public` (unauthenticated). On failure the relay stays off.
  Future<void> _resolveJellyfinServerId() async {
    final cred = hub.jellyfin;
    if (cred == null) return;
    if (cred.serverId.isEmpty) {
      final client = JellyfinClient(baseUrl: cred.baseUrl, clientInfo: cred.clientInfo);
      try {
        final info = await client.publicInfo().timeout(const Duration(seconds: 10));
        hub.jellyfin = cred.withServerId(info.id);
      } catch (e) {
        _log.warning('jellyfin relay off: server id lookup failed: $e');
        return;
      } finally {
        client.close();
      }
    }
    _log.info('jellyfin relay on for server ${hub.jellyfin!.serverId}');
  }

  Future<void> stop() async {
    if (_server == null) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    _relayClient?.close(force: true);
    _relayClient = null;
    hub.dropRelays();
    await hub.closeAllSockets();
    await _app.close();
    _server = null;
    _log.info('server "${config.name}" stopped');
    await _sessionLog?.close();
    _sessionLog = null;
  }
}
