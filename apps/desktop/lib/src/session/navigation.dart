import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:signals/signals.dart';
import 'package:sync_relay_core/core.dart';

import '../screens/home/health_probe.dart';
import '../state/connect_prefs.dart';
import 'app_events.dart' show ActionFailed, ServerRefused;
import 'connection.dart';
import 'identity.dart' show Profile;
import 'session_coordinator.dart';
import 'your_server.dart';

/// Which server this app is in.
enum Place {
  /// None yet (starting, or between two servers).
  none,

  /// Your own server ([YourServer]): home.
  yours,

  /// A friend's (joined from the Join card).
  friend,
}

/// A join that did not get as far as connecting, in plain words.
class JoinFailed implements Exception {
  final String message;
  const JoinFailed(this.message);
  @override
  String toString() => message;
}

/// Where this app is: home on your own server, or in a friend's. It
/// starts the app at home, switches to a friend's server on a join (after
/// the version gate) and back home when you leave theirs, a join fails or
/// they stop sharing. Your server stays up all the while; you leave it
/// (with `bye`) while you are away. Made by the composition root.
class Navigation {
  Navigation({
    required this.coordinator,
    required this.yourServer,
    required this.forms,
    this.profile,
    this.healthGet = defaultHealthGet,
  }) {
    yourServer.onCrash = () {
      if (place.peek() != Place.friend) unawaited(goHome());
    };
    // A friend closed their server to friends: back home, and say so.
    _stops.add(effect(() {
      final s = coordinator.connection.state.value;
      if (s is ConnRefused && s.code == 'closed' && untracked(() => place.value) == Place.friend) {
        // Said once home (a connect clears the toasts).
        scheduleMicrotask(() => unawaited(goHome().then(
            (_) => coordinator.notify(const ServerRefused('The host stopped sharing their server')))));
      }
    }));
    // A friend's server came back restarted (an update, a crash): read its
    // name and version again, they may have changed.
    var restarts = coordinator.restarts.peek();
    _stops.add(effect(() {
      final n = coordinator.restarts.value;
      if (n <= restarts) {
        restarts = n;
        return;
      }
      restarts = n;
      if (untracked(() => place.value) != Place.friend) return;
      final at = untracked(() => address.value);
      scheduleMicrotask(() => unawaited(_refreshHealth(at)));
    }));
  }

  /// Reads `/health` of the friend's server at [at] ("host:port") again
  /// and updates [serverLabel] and [serverVersion] if still there.
  Future<void> _refreshHealth(String at) async {
    final i = at.lastIndexOf(':');
    if (i <= 0) return;
    final health = await probeHealth(at.substring(0, i), at.substring(i + 1), healthGet);
    if (!health.online || place.peek() != Place.friend || address.peek() != at) return;
    serverLabel.value = health.label;
    serverVersion.value = health.version;
  }

  final SessionCoordinator coordinator;
  final YourServer yourServer;
  final ConnectStore forms;
  /// Name and picture for your own connection (default: the app's).
  final Profile? profile;
  final HealthGetter healthGet;
  final _stops = <void Function()>[];

  Profile get _me => profile ?? Profile.instance;

  final place = signal(Place.none);

  /// In a server (yours or a friend's).
  late final Computed<bool> online = computed(() => place.value != Place.none);

  /// On your own server.
  late final Computed<bool> home = computed(() => place.value == Place.yours);

  /// A friend's server's own name (`/health`), '' for yours, until known
  /// or when it only has the default name.
  final serverLabel = signal('');

  /// The server's Starsync version: yours is this app's; a friend's
  /// comes from its `/health`; '' until known.
  final serverVersion = signal('');

  /// The address dialled for a friend's server ("host:port"), '' at home.
  final address = signal('');

  // Bumped by every move; a superseded one stops at its next step.
  int _op = 0;

  /// The app starts: home, on your own server.
  Future<void> start() => goHome();

  /// To your own server (started if it is not running). False when it
  /// could not start or the move was superseded; the reason is a notice.
  Future<bool> goHome() async {
    final op = ++_op;
    _arrive(Place.none);
    try {
      await _me.ensureLoaded();
      final name = _me.name.peek().trim();
      final port = await yourServer.start(name: name);
      if (op != _op) return false;
      coordinator.hostFile = yourServer.setFile;
      await coordinator.connect(ConnectParams(
        host: '127.0.0.1',
        port: port,
        secret: '',
        name: name.isEmpty ? 'Me' : name,
        avatar: _me.avatarBase64(),
        color: _me.colorWire(),
        hostKey: yourServer.hostKey,
      ));
      if (op != _op) return false;
      serverVersion.value = appVersion;
      _arrive(Place.yours);
      return true;
    } on ConnectCancelled {
      return false;
    } catch (e, st) {
      debugPrint('your server: $e\n$st');
      if (op == _op) coordinator.notify(ActionFailed("couldn't start your server: $e"));
      return false;
    }
  }

  void _arrive(Place p) {
    if (p != Place.yours) coordinator.hostFile = null;
    if (p == Place.none) {
      serverLabel.value = '';
      serverVersion.value = '';
      address.value = '';
    }
    place.value = p;
  }

  /// Joins a friend's server. The version gate first (`/health`): an
  /// unreachable server or one without a version in common stops here,
  /// still at home ([JoinFailed], [VersionGateRefused]). Then you leave
  /// your server and connect; when that fails you are back home and the
  /// error is rethrown (a refusal: [HelloRefused]).
  Future<void> join(ConnectParams params) async {
    final op = ++_op;
    final health = await probeHealth(params.host, '${params.port}', healthGet);
    if (op != _op) throw const ConnectCancelled();
    if (!health.online) throw const JoinFailed('host offline — check address and port');
    final fit = health.fit;
    if (fit != null && fit != VersionFit.ok) {
      throw VersionGateRefused(versionGateText(health), youUpdate: fit == VersionFit.youUpdate);
    }
    _arrive(Place.none);
    try {
      await coordinator.connect(params);
      if (op != _op) throw const ConnectCancelled();
    } catch (_) {
      if (op == _op) unawaited(goHome());
      rethrow;
    }
    serverLabel.value = health.label;
    serverVersion.value = health.version;
    address.value = '${params.host}:${params.port}';
    _arrive(Place.friend);
    await forms.remember(RecentServer(host: params.host, port: '${params.port}', secret: params.secret));
  }

  /// The Join card's Cancel: stops a join under way; when it had already
  /// left home, back home.
  Future<void> cancelPending() async {
    _op++;
    try {
      await coordinator.cancelConnect();
    } catch (_) {}
    if (place.peek() != Place.yours) await goHome();
  }

  /// Out of a friend's server (Leave): back home.
  Future<bool> leaveFriend() => goHome();

  /// The app closes: out of whichever server ([bye] false: Update and
  /// restart, the member stays `gone` for the restarted app).
  Future<void> leave({bool bye = true}) async {
    _op++;
    await coordinator.leave(bye: bye);
    _arrive(Place.none);
  }

  void dispose() {
    for (final stop in _stops) {
      stop();
    }
  }
}
