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

  /// Listen on 127.0.0.1 only (the hosting app's own server until it
  /// shares it, see [share]), not on every IPv4 interface.
  final bool loopbackOnly;

  /// The second listener [share] attaches: every IPv4 interface, its own
  /// port; null while not shared.
  RelicServer? _shared;

  /// The folder of the session log (`session-YYYY-MM-DD.log`, every
  /// member's diagnostics and the server's records merged); null: none.
  final String? logDir;
  SessionLog? _sessionLog;

  /// The session log while running with a [logDir].
  SessionLog? get sessionLog => _sessionLog;

  /// [ytDlp] replaces the server's own (tests). [clock] and [liveness]
  /// go to the engine: a test passes a fake clock to step through the
  /// silence, grace and joiner limits ([Liveness]) without waiting.
  SyncServer(this.config,
      {YtDlp? ytDlp, this.loopbackOnly = false, this.logDir, SyncClock? clock, Liveness liveness = const Liveness()}) {
    hub = ServerHub(sessions, config.secret,
        engine: SyncEngine(clock: clock, liveness: liveness),
        hostKey: config.hostKey,
        jellyfin: config.jellyfin,
        ytDlp: ytDlp ?? YtDlp(serverYtDlpDir(config.ytDlpDir), enabled: config.ytDlp),
        animeFlow: config.animeFlow);
  }

  bool get isRunning => _server != null;
  int get boundPort => _server?.port ?? config.port;

  /// The port friends dial while shared ([share]); null otherwise.
  int? get sharedPort => _shared?.port;
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
          'proto': RelayConstants.protoMax,
          'protoMin': RelayConstants.protoMin,
          'protoMax': RelayConstants.protoMax,
          'version': appVersion,
          'tls': false,
          'viewers': viewers,
          'bytesServed': bytes,
          'uptimeSecs': uptime,
        })),
      );
    });
    _app.use('/', closeWhenAsked);
    final requests = MediaRequestLog();
    void logRequest(String token, MediaLog log) => requests(hub.who(token), log);
    mountSessionMediaRoute(_app, sessions, onLog: logRequest);
    mountRelayRoutes(_app, sessions,
        relayAt: hub.relayAt, sourceOf: hub.sourceOf, onOtherMedia: hub.relayOtherMedia, onLog: logRequest);
    mountAvatarRoute(_app, hub);
    mountArtRoute(_app, hub);
    mountSessionLogRoutes(_app, hub, () => _sessionLog);
    mountJellyfinRelayRoute(
        _app, sessions, hub.loginFor, () => _relayClient ??= HttpClient(),
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
      hub.heartbeat();
      _sessionLog?.flush();
    });
    _log.info('server "${config.name}" listening on $boundPort');
    if (config.animeFlow.isNotEmpty) _log.info('AnimeFlow offered to members: ${config.animeFlow}');
  }

  /// A configured credential without a ServerId gets it from
  /// `/System/Info/Public` (unauthenticated). On failure that login stays
  /// unused.
  Future<void> _resolveJellyfinServerId() async {
    final logins = <JellyfinCredential>[];
    for (final cred in hub.jellyfinLogins) {
      var c = cred;
      if (c.serverId.isEmpty) {
        final client = JellyfinClient(baseUrl: c.baseUrl, clientInfo: c.clientInfo);
        try {
          final info = await client.publicInfo().timeout(const Duration(seconds: 10));
          c = c.withServerId(info.id);
        } catch (e) {
          _log.warning('jellyfin relay off for ${c.baseUrl}: server id lookup failed: $e');
        } finally {
          client.close();
        }
      }
      if (c.serverId.isNotEmpty && !logins.any((l) => l.serverId == c.serverId)) {
        logins.add(c);
        _log.info('jellyfin relay on for server ${c.serverId}');
      }
    }
    hub.jellyfinLogins = logins;
  }

  /// Opens the running server to the network: a second listener on
  /// every IPv4 interface at [port] (0: a free one), the password
  /// [secret] ('' : open), the Jellyfin relay logins [jellyfin] (one
  /// per Jellyfin server; null keeps the ones it has) and the AnimeFlow
  /// address [animeFlow] (`welcome.animeFlow`; null keeps it). Members
  /// already in (on the first listener) stay connected; nothing restarts.
  /// Shared already: the listener moves to [port] when it differs. Returns
  /// the bound port; throws when it cannot bind.
  Future<int> share(
      {required int port, required String secret, List<JellyfinCredential>? jellyfin, String? animeFlow}) async {
    if (_server == null) throw StateError('the server is not running');
    final was = _shared;
    if (was != null && (port == 0 || port == was.port)) {
      _applyShareSettings(secret, jellyfin, animeFlow);
      await _resolveJellyfinServerId();
      return was.port;
    }
    if (was != null) {
      _shared = null;
      await was.close(force: true);
    }
    final listener = RelicServer(() => IOAdapter.bind(InternetAddress.anyIPv4, port: port, shared: true));
    try {
      await listener.mountAndStart(_app.asHandler);
    } catch (e) {
      try {
        await listener.close(force: true);
      } catch (_) {}
      rethrow;
    }
    _shared = listener;
    _applyShareSettings(secret, jellyfin, animeFlow);
    await _resolveJellyfinServerId();
    if (secret.isEmpty) _log.warning('shared without a password: anyone who can reach port ${listener.port} can join');
    _log.info('server "${config.name}" shared on port ${listener.port}');
    return listener.port;
  }

  void _applyShareSettings(String secret, List<JellyfinCredential>? jellyfin, String? animeFlow) {
    session.secret = secret;
    if (jellyfin != null) hub.jellyfinLogins = [...jellyfin];
    if (animeFlow != null) hub.animeFlow = checkAnimeFlowAddress(animeFlow);
  }

  /// Closes the network listener [share] opened: everyone but the host
  /// leaves ([ServerHub.closeGuests]), the password goes; the host's own
  /// member, the media and Up next stay as they are.
  Future<void> unshare() async {
    final listener = _shared;
    if (listener == null) return;
    _shared = null;
    final left = hub.closeGuests();
    session.secret = '';
    await listener.close(force: true);
    _log.info('server "${config.name}" no longer shared${left == 0 ? '' : ' ($left left)'}');
  }

  Future<void> stop() async {
    if (_server == null) return;
    final shared = _shared;
    _shared = null;
    if (shared != null) {
      try {
        await shared.close(force: true);
      } catch (_) {}
    }
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
