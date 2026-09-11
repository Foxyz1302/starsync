import 'package:flutter/widgets.dart';
import 'package:signals/signals_flutter.dart';
import 'package:sync_relay_core/core.dart';
import 'package:sync_relay_server/server.dart';

import '../sfx/sfx.dart';
import '../session/health.dart';
import '../session/session_coordinator.dart';
import '../widgets/avatar_pipeline.dart';
import 'connect_prefs.dart';

enum AppRoute { welcome, connect, session }

enum ConnectMode { host, join }

class ConnectForm {
  String host;
  String port;
  String secret;
  String name;
  String avatarPath;
  String mediaPath;
  String linkUrl;
  ConnectForm({
    this.host = '127.0.0.1',
    this.port = '8080',
    this.secret = '',
    this.name = '',
    this.avatarPath = '',
    this.mediaPath = '',
    this.linkUrl = '',
  });
}

class SessionState {
  static final SessionState instance = SessionState._();
  SessionState._();

  final route = signal(AppRoute.welcome);
  final connectMode = signal(ConnectMode.host);
  final status = signal(const HealthStatus(HealthSeverity.info, 'idle'));
  final room = signal<RoomBroadcast?>(null);
  final SfxService sfx = const NoopSfxService();
  late final SessionCoordinator coordinator = SessionCoordinator(sfx: sfx);
  final lastForm = ConnectForm();
  RoomServer? _server;

  Future<void> loadForm() async {
    final box = await openConnectFormBox();
    lastForm
      ..host = readString(box, connectKeyHost, '127.0.0.1')
      ..port = readString(box, connectKeyPort, '8080')
      ..secret = readString(box, connectKeySecret, '')
      ..name = readString(box, connectKeyName, '')
      ..avatarPath = readString(box, connectKeyAvatarPath, '')
      ..mediaPath = readString(box, connectKeyMediaPath, '')
      ..linkUrl = readString(box, connectKeyLinkUrl, '');
  }

  Future<void> saveForm() async {
    final box = connectFormBoxIfOpen() ?? await openConnectFormBox();
    await box.putAll({
      connectKeyHost: lastForm.host,
      connectKeyPort: lastForm.port,
      connectKeySecret: lastForm.secret,
      connectKeyName: lastForm.name,
      connectKeyAvatarPath: lastForm.avatarPath,
      connectKeyMediaPath: lastForm.mediaPath,
      connectKeyLinkUrl: lastForm.linkUrl,
    });
  }

  Future<String> loadAvatar(String path) => encodeAvatar(path);

  void goConnect(ConnectMode mode) {
    connectMode.value = mode;
    route.value = AppRoute.connect;
  }

  Future<void> host(ConnectParams params, ConnectForm form) async {
    _rememberForm(form);
    status.value = const HealthStatus(HealthSeverity.info, 'starting server…');
    await stopServer();
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
      status.value =
          HealthStatus(HealthSeverity.error, 'cannot bind port ${params.port}: $e');
      rethrow;
    }
    _server = server;
    status.value =
        HealthStatus(HealthSeverity.ok, 'hosting on port ${server.boundPort}');
    await coordinator.connect(ConnectParams(
      host: '127.0.0.1',
      port: server.boundPort,
      secret: params.secret,
      name: params.name,
      avatar: params.avatar,
      linkUrl: params.linkUrl,
    ));
    route.value = AppRoute.session;
    try {
      await saveForm();
    } catch (e, st) {
      debugPrint('save connect form failed: $e\n$st');
    }
  }

  Future<void> join(ConnectParams params, ConnectForm form) async {
    _rememberForm(form);
    await coordinator.connect(params);
    route.value = AppRoute.session;
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
    _server = RoomServer(AppConfig(port: port, secret: 'change-me', name: 'room'));
    await _server!.start();
  }

  Future<void> stopServer() async {
    await _server?.stop();
    _server = null;
  }

  Future<void> leave() async {
    await coordinator.leave();
    await stopServer();
    status.value = const HealthStatus(HealthSeverity.info, 'idle');
    route.value = AppRoute.connect;
  }
}
