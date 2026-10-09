import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../jellyfin/accounts.dart';
import '../jellyfin/session_media.dart';
import '../playback/yt_dlp_app.dart';
import '../sfx/sfx.dart';
import '../sfx/synth_sfx.dart';
import '../session/health.dart';
import '../session/session_coordinator.dart';
import '../widgets/avatar_pipeline.dart';
import 'connect_prefs.dart';
import 'server_isolate.dart';
import 'settings.dart';

enum AppRoute {
  home,
  session,
}

enum ConnectMode { host, join }

/// Both Home cards prefill from this. [host]/[port]/[secret] belong to
/// the Join card, [hostPort]/[hostSecret] to the Host card.
class ConnectForm {
  String host;
  String port;
  String secret;
  String hostPort;
  String hostSecret;
  String name;
  String avatarPath;
  String mediaPath;
  String linkUrl;
  ConnectForm({
    this.host = '127.0.0.1',
    this.port = '8080',
    this.secret = '',
    this.hostPort = '8080',
    this.hostSecret = '',
    this.name = '',
    this.avatarPath = '',
    this.mediaPath = '',
    this.linkUrl = '',
  });

  ConnectForm copy() => ConnectForm(
        host: host,
        port: port,
        secret: secret,
        hostPort: hostPort,
        hostSecret: hostSecret,
        name: name,
        avatarPath: avatarPath,
        mediaPath: mediaPath,
        linkUrl: linkUrl,
      );
}

const connectKeyHostPort = 'hostPort';
const connectKeyHostSecret = 'hostSecret';
const connectKeyRecents = 'recents';
const maxRecentServers = 6;

/// A server the user got into, shown as a Recent chip on Home. Hosted
/// entries refill the Host card; joined ones join in one click.
class RecentServer {
  final bool hosted;
  final String host;
  final String port;
  final String secret;
  const RecentServer(
      {required this.hosted,
      required this.host,
      required this.port,
      this.secret = ''});

  String get key => hosted ? 'host:$port' : '${host.toLowerCase()}:$port';

  Map<String, Object> toJson() =>
      {'hosted': hosted, 'host': host, 'port': port, 'secret': secret};

  static RecentServer? fromJson(Object? j) {
    if (j is! Map) return null;
    final host = j['host'], port = j['port'], secret = j['secret'];
    if (host is! String || port is! String) return null;
    return RecentServer(
      hosted: j['hosted'] == true,
      host: host,
      port: port,
      secret: secret is String ? secret : '',
    );
  }
}

/// Newest first, one entry per server, capped at [maxRecentServers].
List<RecentServer> pushRecent(List<RecentServer> list, RecentServer s) => [
      s,
      ...list.where((r) => r.key != s.key),
    ].take(maxRecentServers).toList();

String encodeRecents(List<RecentServer> list) =>
    jsonEncode([for (final r in list) r.toJson()]);

List<RecentServer> decodeRecents(Object? raw) {
  if (raw is! String) return const [];
  try {
    final list = jsonDecode(raw);
    if (list is! List) return const [];
    return [
      for (final j in list) ?RecentServer.fromJson(j),
    ].take(maxRecentServers).toList();
  } catch (_) {
    return const [];
  }
}

/// Before recents existed only the last form was stored: a saved remote
/// address becomes the first Recent chip.
List<RecentServer> migrateRecents(
    {required bool hadForm,
    required String host,
    required String port,
    required String secret}) {
  final h = host.trim().toLowerCase();
  if (!hadForm || h.isEmpty || h == '127.0.0.1' || h == 'localhost') {
    return const [];
  }
  return [RecentServer(hosted: false, host: host.trim(), port: port, secret: secret)];
}

/// The hosted server died during setup; shown on the Host card.
class ServerCrashed implements Exception {
  final String cause;
  const ServerCrashed(this.cause);
  @override
  String toString() => 'server crashed: $cause';
}

/// A fresh per-hosting key: the app's own client sends it in hello to be
/// recognised as the (unkickable) host.
String newHostKey() {
  final r = Random.secure();
  return base64Url.encode([for (var i = 0; i < 24; i++) r.nextInt(256)]);
}

class SessionState {
  static final SessionState instance = SessionState._();
  SessionState._();

  final route = signal(AppRoute.home);
  final recents = signal<List<RecentServer>>(const []);
  final status = signal(const HealthStatus(HealthSeverity.info, 'idle'));
  final SfxService sfx = SynthSfx(
    volume: () => AppSettings.instance.soundVolume.peek(),
    enabled: (k) => !AppSettings.instance.soundsOff.peek().contains(k.name),
  );
  late final SessionCoordinator coordinator = SessionCoordinator(sfx: sfx);
  final lastForm = ConnectForm();
  JellyfinAccounts get jellyfin => JellyfinAccounts.instance;
  /// Set when the hosted server died mid-session; Home shows it on the
  /// Host card and clears it.
  final serverCrash = signal<String?>(null);

  /// The app's yt-dlp folder for the hosted server; '' (the server's own
  /// default) when the app-support folder is not available.
  static Future<String> _sharedYtDlpDir() async {
    try {
      return (await AppYtDlp.instance.ytDlp).dir;
    } catch (_) {
      return '';
    }
  }
  ServerIsolate? _server;
  String? _setupCrash;

  @visibleForTesting
  ServerIsolate? get hostedServer => _server;
  void Function()? _stopKickWatch;
  // Bumped by host/join/cancelPending: a cancelled setup notices at its
  // next step and unwinds instead of connecting.
  int _op = 0;

  Future<void> loadForm() async {
    final box = await openConnectFormBox();
    lastForm
      ..host = readString(box, connectKeyHost, '127.0.0.1')
      ..port = readString(box, connectKeyPort, '8080')
      ..secret = readString(box, connectKeySecret, '');
    // Old installs had one port/password for both modes.
    lastForm
      ..hostPort = readString(box, connectKeyHostPort, lastForm.port)
      ..hostSecret = readString(box, connectKeyHostSecret, lastForm.secret)
      ..name = readString(box, connectKeyName, '')
      ..avatarPath = readString(box, connectKeyAvatarPath, '')
      ..mediaPath = readString(box, connectKeyMediaPath, '')
      ..linkUrl = readString(box, connectKeyLinkUrl, '');
    recents.value = box.containsKey(connectKeyRecents)
        ? decodeRecents(box.get(connectKeyRecents))
        : migrateRecents(
            hadForm: box.containsKey(connectKeyHost),
            host: lastForm.host,
            port: lastForm.port,
            secret: lastForm.secret);
  }

  Future<void> saveForm() async {
    final box = connectFormBoxIfOpen() ?? await openConnectFormBox();
    await box.putAll({
      connectKeyHost: lastForm.host,
      connectKeyPort: lastForm.port,
      connectKeySecret: lastForm.secret,
      connectKeyHostPort: lastForm.hostPort,
      connectKeyHostSecret: lastForm.hostSecret,
      connectKeyName: lastForm.name,
      connectKeyAvatarPath: lastForm.avatarPath,
      connectKeyMediaPath: lastForm.mediaPath,
      connectKeyLinkUrl: lastForm.linkUrl,
      connectKeyRecents: encodeRecents(recents.peek()),
    });
  }

  Future<String> loadAvatar(String path) => encodeAvatar(path);

  /// Called by Home after a host/join got through.
  Future<void> rememberServer(RecentServer server) async {
    recents.value = pushRecent(recents.peek(), server);
    await _saveFormQuietly();
  }

  Future<void> forgetServer(RecentServer server) async {
    recents.value = [
      for (final r in recents.peek())
        if (r.key != server.key) r,
    ];
    await _saveFormQuietly();
  }

  Future<void> host(ConnectParams params, ConnectForm form) async {
    final op = ++_op;
    _rememberForm(form);
    try {
      status.value =
          const HealthStatus(HealthSeverity.info, 'starting server…');
      await stopServer();
      if (op != _op) throw const ConnectCancelled();
      final hostKey = newHostKey();
      _setupCrash = null;
      // A pasted Jellyfin link goes up as a ref like a browser pick.
      final media = params.media ??
          (params.linkUrl.isEmpty ? null : await mediaForLink(jellyfin, params.linkUrl));
      if (op != _op) throw const ConnectCancelled();
      // Guests without an account watch through the server, with the
      // host's own sign-in (the hosted item's server, else the default).
      await jellyfin.ensureLoaded(validate: false);
      final relay = relayCredentialFor(jellyfin, serverId: media?.jellyfin?.serverId);
      late final ServerIsolate server;
      try {
        server = await ServerIsolate.start(
          AppConfig(
            port: params.port,
            secret: params.secret,
            name: 'server',
            mediaPath: params.mediaPath,
            hostKey: hostKey,
            jellyfin: relay,
            ytDlpDir: await _sharedYtDlpDir(),
          ),
          onLog: (line) => debugPrint('[server] $line'),
          onCrash: (cause) => _onServerCrash(server, cause),
        );
      } catch (e, st) {
        debugPrint('server start failed: $e\n$st');
        status.value = HealthStatus(
            HealthSeverity.error, 'cannot start server on port ${params.port}: $e');
        rethrow;
      }
      if (op != _op) {
        await server.stop();
        throw const ConnectCancelled();
      }
      _server = server;
      coordinator.hostFile = (path) async =>
          identical(_server, server) ? server.setFile(path) : null;
      status.value =
          HealthStatus(HealthSeverity.ok, 'hosting on port ${server.port}');
      try {
        await coordinator.connect(ConnectParams(
          host: '127.0.0.1',
          port: server.port,
          secret: params.secret,
          name: params.name,
          avatar: params.avatar,
          hostKey: hostKey,
          media: media,
        ));
        if (op != _op) throw const ConnectCancelled();
      } catch (e) {
        // Own join failed or was cancelled: don't leave the port open.
        if (identical(_server, server)) await stopServer();
        final crash = _setupCrash;
        if (crash != null && e is! ConnectCancelled) throw ServerCrashed(crash);
        rethrow;
      }
      _watchKick();
      route.value = AppRoute.session;
    } finally {
      await _saveFormQuietly();
    }
  }

  /// The server isolate died without being stopped. In a session: show it
  /// and leave. During setup the own join fails and [host] reports it.
  void _onServerCrash(ServerIsolate server, String cause) {
    if (!identical(_server, server)) return;
    final message = 'server crashed: $cause';
    debugPrint('[server] $message');
    if (route.peek() != AppRoute.session) {
      _setupCrash = cause;
      return;
    }
    coordinator.health.value = HealthStatus(HealthSeverity.error, message);
    serverCrash.value = message;
    unawaited(leave().catchError((Object e) => debugPrint('leave after crash failed: $e')));
  }

  Future<void> join(ConnectParams params, ConnectForm form) async {
    final op = ++_op;
    _rememberForm(form);
    try {
      await coordinator.connect(params);
      if (op != _op) throw const ConnectCancelled();
      route.value = AppRoute.session;
    } finally {
      await _saveFormQuietly();
    }
  }

  /// Cancel button during setup: abort whichever step is running (server
  /// start, player init, socket dial) without connecting.
  Future<void> cancelPending() async {
    _op++;
    try {
      await coordinator.cancelConnect();
    } catch (_) {}
    await stopServer();
  }

  /// A kicked host must not keep serving.
  void _watchKick() {
    _stopKickWatch?.call();
    _stopKickWatch = effect(() {
      // Microtask: stopServer disposes this effect, not from inside it.
      if (coordinator.kickReason.value != null) scheduleMicrotask(stopServer);
    });
  }

  /// Saved whatever the outcome: a failed join is exactly when the user
  /// wants the form back.
  Future<void> _saveFormQuietly() async {
    try {
      await saveForm();
    } catch (e, st) {
      debugPrint('save connect form failed: $e\n$st');
    }
  }

  void _rememberForm(ConnectForm form) {
    lastForm
      ..host = form.host
      ..port = form.port
      ..secret = form.secret
      ..hostPort = form.hostPort
      ..hostSecret = form.hostSecret
      ..name = form.name
      ..avatarPath = form.avatarPath
      ..mediaPath = form.mediaPath
      ..linkUrl = form.linkUrl;
  }

  Future<void> stopServer() async {
    coordinator.hostFile = null;
    _stopKickWatch?.call();
    _stopKickWatch = null;
    final server = _server;
    _server = null;
    await server?.stop();
  }

  Future<void> leave() async {
    await coordinator.leave();
    await stopServer();
    status.value = const HealthStatus(HealthSeverity.info, 'idle');
    route.value = AppRoute.home;
  }
}
