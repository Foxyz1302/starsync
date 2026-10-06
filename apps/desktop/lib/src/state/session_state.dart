import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';

import '../sfx/sfx.dart';
import '../session/health.dart';
import '../session/session_coordinator.dart';
import '../widgets/avatar_pipeline.dart';
import 'connect_prefs.dart';

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

class SessionState {
  static final SessionState instance = SessionState._();
  SessionState._();

  final route = signal(AppRoute.home);
  final recents = signal<List<RecentServer>>(const []);
  final status = signal(const HealthStatus(HealthSeverity.info, 'idle'));
  final room = signal<RoomBroadcast?>(null);
  final SfxService sfx = const NoopSfxService();
  late final SessionCoordinator coordinator = SessionCoordinator(sfx: sfx);
  final lastForm = ConnectForm();
  RoomServer? _server;
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
      final server = RoomServer(AppConfig(
        port: params.port,
        secret: params.secret,
        name: 'room',
        mediaPath: params.mediaPath,
      ));
      try {
        await server.start();
      } catch (e, st) {
        debugPrint('server start failed: $e\n$st');
        status.value = HealthStatus(
            HealthSeverity.error, 'cannot bind port ${params.port}: $e');
        rethrow;
      }
      if (op != _op) {
        await server.stop();
        throw const ConnectCancelled();
      }
      _server = server;
      status.value =
          HealthStatus(HealthSeverity.ok, 'hosting on port ${server.boundPort}');
      try {
        await coordinator.connect(ConnectParams(
          host: '127.0.0.1',
          port: server.boundPort,
          secret: params.secret,
          name: params.name,
          avatar: params.avatar,
          linkUrl: params.linkUrl,
        ));
        if (op != _op) throw const ConnectCancelled();
      } catch (_) {
        // Own join failed or was cancelled: don't leave the port open.
        if (identical(_server, server)) await stopServer();
        rethrow;
      }
      _watchKick();
      route.value = AppRoute.session;
    } finally {
      await _saveFormQuietly();
    }
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

  Future<void> startHeadless(List<String> args) async {
    int port = 8080;
    for (var i = 0; i < args.length - 1; i++) {
      if (args[i] == '--port') port = int.tryParse(args[i + 1]) ?? port;
    }
    _server = RoomServer(AppConfig(port: port, secret: '', name: 'room'));
    await _server!.start();
  }

  Future<void> stopServer() async {
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
