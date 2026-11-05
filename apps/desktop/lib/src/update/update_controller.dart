import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../platform/app_shutdown.dart';

// In-app update flow behind the update bar (UpdateBar). Same code path as
// `--upgrade` (core's updater, downloadAndApply); this adds state for the
// UI and the restart. Check failures are logged only — the banner shows up just when
// there is something to install.

final _log = createLogger('update');

enum UpdatePhase { idle, available, downloading, applying, restarting, failed }

class UpdateStatus {
  final UpdatePhase phase;
  final UpdateManifest? manifest;
  final double? progress;
  final String? error;
  /// The failure is a refusal ([UpdateRefused]): [error] says it in plain
  /// words.
  final bool refused;
  // False for dev runs / unpacked builds: banner tells the user to update
  // by hand instead of offering the button.
  final bool canInstall;
  const UpdateStatus(this.phase,
      {this.manifest, this.progress, this.error, this.refused = false, this.canInstall = false});
}

// Process args as main() received them — restart relaunches with these.
List<String> launchArgs = const [];

typedef RestartFn = Future<void> Function(String executable, List<String> args);

// The orderly close (players, leave), Hive's box locks released before
// the new instance opens the same boxes, the (now replaced) binary
// relaunched detached with the same args, then the window closes.
Future<void> _closeAndRestart(String executable, List<String> args) async {
  final keep = args.where((a) => a != '--upgrade').toList();
  await shutDownApp(restart: true, beforeQuit: () async {
    try {
      await Hive.close();
    } catch (e) {
      _log.warning('closing hive before restart: $e');
    }
    await Process.start(executable, keep,
        mode: ProcessStartMode.detached,
        workingDirectory: Directory.current.path);
  });
}

class UpdateController {
  static final instance = UpdateController();

  final String currentVersion;
  /// Overrides the config's manifest addresses (tests); null: the
  /// config's ([config]).
  final List<String>? manifestUrls;
  final List<String>? devUrls;
  /// The signed config: the manifests' addresses and the trusted keys,
  /// refreshed with every check. The app sets one that keeps its copy in
  /// the data folder and tries Settings → Updates → More, "Config
  /// address" first (`AppGraph.build`).
  RemoteConfigSource config;
  final String? executablePath;
  final Directory? installRoot;
  final RestartFn restart;
  final bool skipDevBuilds;
  /// Awaited after the apply, before [restart]: keeps the new version's
  /// notes for its first start ([WhatsNew.installing], wired by `AppGraph`).
  Future<void> Function(UpdateManifest manifest)? beforeRestart;
  /// The update channel each check reads (the setting, wired by
  /// `AppGraph`); null: [defaultUpdateChannel] of [currentVersion].
  UpdateChannel Function()? channelOf;

  UpdateController(
      {this.currentVersion = appVersion,
      this.manifestUrls,
      this.devUrls,
      RemoteConfigSource? config,
      this.executablePath,
      this.installRoot,
      this.restart = _closeAndRestart,
      this.skipDevBuilds = true,
      this.beforeRestart,
      this.channelOf}) : config = config ?? RemoteConfigSource();

  UpdateChannel get channel => channelOf?.call() ?? defaultUpdateChannel(currentVersion);

  final status = ValueNotifier(const UpdateStatus(UpdatePhase.idle));
  /// The manifest of the last check that read one, newer or not (What's
  /// new picks up this version's notes from it).
  final latest = ValueNotifier<UpdateManifest?>(null);
  /// Outcome of the last finished check, for Settings/About wording
  /// ("Up to date", "Check failed: ..."); null until one finishes.
  final lastCheck = ValueNotifier<String?>(null);
  /// On the stable channel in a test build: the latest release when it
  /// is older than this build (offered only by [goBackTo], after asking).
  final stableBehind = ValueNotifier<UpdateManifest?>(null);
  Future<void>? _check;
  late final String _exe = executablePath ?? currentExecutablePath();
  late final Directory? _root = installRoot ?? findInstallRoot(_exe);
  String get _exeName => _exe.replaceAll('\\', '/').split('/').last;

  // Once per process; later calls return the same future.
  Future<void> checkOnce() => _check ??= _checkNow();

  // User-triggered re-check ("Check now"); joins one already in flight.
  Future<void> checkNow() {
    final inFlight = _check;
    if (inFlight != null && _checking) return inFlight;
    return _check = _checkNow();
  }

  bool _checking = false;

  Future<void> _checkNow() async {
    _checking = true;
    try {
      await _runCheck();
    } finally {
      _checking = false;
    }
  }

  Future<void> _runCheck() async {
    if (skipDevBuilds && currentVersion.endsWith('-dev')) {
      _log.info('dev build ($currentVersion), skipping update check');
      lastCheck.value = 'Dev build — update checks are off';
      return;
    }
    final root = _root;
    if (root != null) await cleanupUpdateLeftovers(root);
    try {
      final ch = channel;
      final cfg = await config.refresh();
      final m = await fetchLatestManifest(
          currentVersion: currentVersion,
          channel: ch,
          urls: manifestUrls ?? cfg.stable,
          devUrls: devUrls ?? cfg.dev,
          keys: config.keys);
      latest.value = m;
      stableBehind.value = ch == UpdateChannel.stable && isStableBehind(currentVersion, m) ? m : null;
      if (stableBehind.value != null) {
        _log.info('stable channel: latest release ${m.version} is older than $currentVersion');
        lastCheck.value = 'Stable is at ${m.version}, older than this test build';
        if (!_installing && status.value.manifest?.version != m.version) {
          status.value = const UpdateStatus(UpdatePhase.idle);
        }
        return;
      }
      if (!isNewerVersion(currentVersion, m.version)) {
        _log.info('up to date ($currentVersion, latest ${m.version})');
        lastCheck.value = 'Up to date';
        return;
      }
      _log.info('update available: ${m.version} (proto ${m.protocol})');
      lastCheck.value = 'Update v${m.version} available';
      // A re-check never cuts into an install under way.
      if (_installing) return;
      status.value = UpdateStatus(UpdatePhase.available,
          manifest: m, canInstall: root != null);
    } on UpdateRefused catch (e) {
      _log.warning('update check: ${e.message} (${e.detail})');
      lastCheck.value = e.message;
    } catch (e) {
      _log.warning('update check failed: $e');
      lastCheck.value = 'Update check failed: $e';
    }
  }

  /// The latest release when it is older than this test build (the
  /// question before going back to stable); null when it is not, or the
  /// check failed.
  Future<UpdateManifest?> stableToGoBackTo() async {
    try {
      final cfg = await config.refresh();
      final m = await fetchManifest(urls: manifestUrls ?? cfg.stable, keys: config.keys);
      return isStableBehind(currentVersion, m) ? m : null;
    } catch (e) {
      _log.warning('stable manifest: $e');
      return null;
    }
  }

  /// Installs [m] although it is older (going back to stable, asked
  /// first): offered as an update, then [install].
  Future<void> goBackTo(UpdateManifest m) async {
    if (_installing) return;
    status.value = UpdateStatus(UpdatePhase.available, manifest: m, canInstall: _root != null);
    if (_root != null) await install();
  }

  bool get _installing => switch (status.value.phase) {
        UpdatePhase.downloading || UpdatePhase.applying || UpdatePhase.restarting => true,
        _ => false,
      };

  void dismiss() {
    final s = status.value;
    if ((s.phase == UpdatePhase.available || s.phase == UpdatePhase.failed) &&
        !(s.manifest?.isRequired ?? false)) {
      status.value = const UpdateStatus(UpdatePhase.idle);
    }
  }

  Future<void> install() async {
    final s = status.value;
    final m = s.manifest;
    final root = _root;
    if (m == null || root == null) return;
    if (s.phase != UpdatePhase.available && s.phase != UpdatePhase.failed) {
      return;
    }
    status.value = UpdateStatus(UpdatePhase.downloading,
        manifest: m, progress: 0, canInstall: true);
    var lastPct = -1;
    try {
      await downloadAndApply(m, root,
          executableName: installRoot == null ? _exeName : null,
          onProgress: (got, total) {
        if (total == null || total == 0) return;
        final pct = got * 100 ~/ total;
        if (pct == lastPct) return;
        lastPct = pct;
        status.value = UpdateStatus(UpdatePhase.downloading,
            manifest: m, progress: got / total, canInstall: true);
        if (pct == 100) {
          status.value =
              UpdateStatus(UpdatePhase.applying, manifest: m, canInstall: true);
        }
      }, say: (line) => _log.info(line));
    } catch (e) {
      _log.warning('update failed: ${e is UpdateRefused ? '${e.message} (${e.detail})' : e}');
      status.value = UpdateStatus(UpdatePhase.failed,
          manifest: m, error: '$e', refused: e is UpdateRefused, canInstall: true);
      return;
    }
    _log.info('updated to ${m.version}, restarting');
    status.value =
        UpdateStatus(UpdatePhase.restarting, manifest: m, canInstall: true);
    try {
      await beforeRestart?.call(m);
    } catch (e) {
      _log.warning('keeping the notes of ${m.version}: $e');
    }
    // Started by an old name (an old shortcut to `watch_together.exe`,
    // which this update removed): the new binary next to it.
    await restart(relaunchExecutable(_exe), launchArgs);
  }
}
