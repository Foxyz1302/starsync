import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress;
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:signals/signals.dart';
import 'package:sync_relay_core/core.dart';

import '../jellyfin/accounts.dart';
import '../jellyfin/session_media.dart' show relayCredentialsFor;
import '../state/connect_prefs.dart';
import '../state/server_isolate.dart';
import 'invite.dart';
import 'public_address.dart';

/// A fresh key per app run: this app's own client sends it in hello to be
/// recognised as the host (`members[].host`; it also stands in for the
/// password).
String newHostKey() {
  final r = Random.secure();
  return base64Url.encode([for (var i = 0; i < 24; i++) r.nextInt(256)]);
}

/// Starts the server isolate (tests may pass their own).
typedef ServerStarter = Future<ServerIsolate> Function(
  AppConfig config, {
  bool loopbackOnly,
  String? logDir,
  required void Function(String line) onLog,
  required void Function(String error) onCrash,
});

Future<ServerIsolate> _startIsolate(
  AppConfig config, {
  bool loopbackOnly = false,
  String? logDir,
  required void Function(String line) onLog,
  required void Function(String error) onCrash,
}) =>
    ServerIsolate.start(config, loopbackOnly: loopbackOnly, logDir: logDir, onLog: onLog, onCrash: onCrash);

/// "Your server": the one server this app runs for its whole life (a
/// [ServerIsolate] running `serve`). It starts on 127.0.0.1 and a free
/// port, so only this app reaches it; [invite] attaches a second
/// listener on every interface at the configured port (Settings → Party
/// & network: port and password) and [stopSharing] detaches it. Members,
/// what plays and Up next never restart or reconnect for either. Sharing
/// also looks up the internet address ([reach]). Made by the composition
/// root.
class YourServer {
  YourServer({
    required this.forms,
    this.jellyfin,
    Future<String> Function()? ytDlpDir,
    String? Function()? logDir,
    ServerStarter? starter,
    Future<List<({String name, InternetAddress address})>> Function()? interfaces,
    Future<String?> Function()? publicAddress,
    this.publicWait = const Duration(seconds: 4),
  })  : _ytDlpDir = ytDlpDir ?? (() async => ''),
        _logDir = logDir ?? (() => null),
        _starter = starter ?? _startIsolate,
        _interfaces = interfaces ?? machineInterfaces,
        _publicAddress = publicAddress ?? lookUpPublicAddress;

  final ConnectStore forms;
  /// Linked Jellyfin servers (default: the app's): the relay logins.
  final JellyfinAccounts? jellyfin;
  final Future<String> Function() _ytDlpDir;
  final String? Function() _logDir;
  final ServerStarter _starter;
  final Future<List<({String name, InternetAddress address})>> Function() _interfaces;
  final Future<String?> Function() _publicAddress;

  /// How long [invite] waits for the internet address before it hands
  /// out a local one (the lookup goes on; [reach] and [shared] follow).
  final Duration publicWait;

  /// Where friends can reach it while shared: the internet address (once
  /// looked up) and this machine's; null when not shared.
  final reach = signal<InviteReach?>(null);

  /// What `/health` calls it ("Bob's server"), the invite's name.
  String _name = '';

  /// Sent by this app's own client (see [newHostKey]).
  final String hostKey = newHostKey();

  /// The loopback port while it runs; null before [start] and after
  /// [stop] or a crash.
  final port = signal<int?>(null);

  /// The invite while shared (the listener attached); null when only this
  /// app can reach it.
  final shared = signal<Invite?>(null);

  /// An [invite] or [stopSharing] is under way.
  final busy = signal(false);

  /// The password the server was shared with (empty: none).
  String _secret = '';

  /// What Invite copies: [invite]'s bare `starsync://` link with the
  /// password the server was shared with, so a friend just clicks it.
  String inviteLink(Invite invite) => invite.link(secret: _secret).uri;

  /// Set when the server died without being stopped; the shell says so
  /// and clears it. The next [start] makes a new one.
  final crash = signal<String?>(null);

  /// Called after a crash (the navigation reconnects home).
  void Function()? onCrash;

  ServerIsolate? _server;
  Future<int>? _starting;

  @visibleForTesting
  ServerIsolate? get server => _server;

  JellyfinAccounts get _accounts => jellyfin ?? JellyfinAccounts.instance;

  /// Starts it once (later calls get the same port); a new one after a
  /// crash. [name]: what `/health` calls it ("Bob's server").
  Future<int> start({String name = ''}) {
    final running = _server;
    if (running != null && running.isRunning) return Future.value(running.port);
    return _starting ??= _start(name).whenComplete(() => _starting = null);
  }

  Future<int> _start(String name) async {
    final who = name.trim();
    _name = who.isEmpty ? '' : "$who's server";
    late final ServerIsolate server;
    server = await _starter(
      AppConfig(
        port: 0,
        secret: '',
        name: who.isEmpty ? 'server' : _name,
        hostKey: hostKey,
        ytDlpDir: await _ytDlpDir(),
      ),
      loopbackOnly: true,
      // Its session log (every member's shared diagnostics and its own
      // records) goes next to the app's.
      logDir: _logDir(),
      // Its records join the app's log as `server.<logger>`.
      onLog: (line) => relogLine('server', line),
      onCrash: (cause) => _onCrash(server, cause),
    );
    _server = server;
    port.value = server.port;
    return server.port;
  }

  void _onCrash(ServerIsolate server, String cause) {
    if (!identical(_server, server)) return;
    _server = null;
    port.value = null;
    shared.value = null;
    reach.value = null;
    final message = 'server crashed: $cause';
    debugPrint('[server] $message');
    crash.value = message;
    onCrash?.call();
  }

  /// Opens it to friends (attaching the network listener if it is not
  /// yet) and returns the invite to hand out. Throws when the port can't
  /// be opened (in use) or the server is not running.
  Future<Invite> invite() async {
    final server = _server;
    if (server == null || !server.isRunning) throw StateError('your server is not running');
    final current = shared.peek();
    if (current != null) return current;
    busy.value = true;
    try {
      final form = forms.form;
      final want = int.tryParse(form.hostPort.trim()) ?? 8080;
      await _accounts.ensureLoaded(validate: false);
      final secret = form.hostSecret;
      final bound = await server.share(
        port: want,
        secret: secret,
        // Guests without an account watch Jellyfin items through the
        // server, with this app's own sign-in on the item's server.
        jellyfin: relayCredentialsFor(_accounts),
      );
      _secret = secret;
      final local = inviteAddresses(await _interfaces());
      final gen = ++_shareGen;
      reach.value = InviteReach(local: local, looking: true);
      final lookup = _lookUp(local, gen);
      // The internet address when it comes quickly; else a local one now
      // and the internet one when it lands.
      final public = await lookup.timeout(publicWait, onTimeout: () => null);
      final invite = inviteFor(bound, password: secret.isNotEmpty, host: reach.peek()?.best);
      shared.value = invite;
      if (public == null) {
        unawaited(lookup.then((ip) {
          final now = shared.peek();
          if (ip != null && gen == _shareGen && identical(now, invite)) shared.value = now!.at(ip);
        }));
      }
      return invite;
    } finally {
      busy.value = false;
    }
  }

  /// Bumped by every share and unshare: a lookup of an earlier one is
  /// dropped.
  int _shareGen = 0;

  /// The internet address into [reach] (its own failure is no address).
  Future<String?> _lookUp(List<String> local, int gen) async {
    String? ip;
    try {
      ip = await _publicAddress();
    } catch (e) {
      debugPrint('public address lookup failed: $e');
    }
    if (gen != _shareGen || reach.peek() == null) return null;
    reach.value = InviteReach(public: ip, local: local);
    return ip;
  }

  /// The invite for [port] at [host] (else this machine's best address,
  /// see [inviteAddresses]; 127.0.0.1 when there is none).
  Invite inviteFor(int port, {required bool password, String? host}) {
    final local = reach.peek()?.local ?? const [];
    return Invite(
      host: host ?? (local.isEmpty ? '127.0.0.1' : local.first),
      port: port,
      name: _name,
      password: password,
      version: appVersion,
    );
  }

  /// [link] points at this server (one of its invite addresses, or this
  /// machine, at its shared or loopback port).
  bool isOwn(InviteLink link) {
    final host = link.host.toLowerCase();
    final local = host == 'localhost' || host == '127.0.0.1' || host == '::1';
    if (local && link.port == port.peek()) return true;
    final s = shared.peek();
    if (s == null || link.port != s.port) return false;
    return local || host == s.host || (reach.peek()?.choices.any((c) => c.host == host) ?? false);
  }

  /// Closes it to friends again: everyone but you leaves (told, so their
  /// apps do not retry); you, what plays and Up next stay.
  Future<void> stopSharing() async {
    final server = _server;
    if (server == null || shared.peek() == null) return;
    busy.value = true;
    try {
      await server.unshare();
      _shareGen++;
      shared.value = null;
      reach.value = null;
    } finally {
      busy.value = false;
    }
  }

  /// Makes [path] the hosted file (a File put up here; `/m` serves it).
  Future<({String name, int size})?> setFile(String path) async => _server?.setFile(path);

  /// The app closes: the server stops (sockets closed, port freed).
  Future<void> stop() async {
    final server = _server;
    _server = null;
    port.value = null;
    shared.value = null;
    reach.value = null;
    await server?.stop();
  }
}
