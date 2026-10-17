import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:sync_relay_core/core.dart';

import '../platform/app_shutdown.dart';
import 'whats_new.dart';

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
  // False for dev runs / unpacked builds: banner tells the user to update
  // by hand instead of offering the button.
  final bool canInstall;
  const UpdateStatus(this.phase,
      {this.manifest, this.progress, this.error, this.canInstall = false});
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
  final String manifestUrl;
  final String? executablePath;
  final Directory? installRoot;
  final RestartFn restart;
  final bool skipDevBuilds;
  /// Awaited after the apply, before [restart]: keeps the new version's
  /// notes for its first start ([WhatsNew.installing]).
  final Future<void> Function(UpdateManifest manifest)? beforeRestart;

  UpdateController(
      {this.currentVersion = appVersion,
      this.manifestUrl = updateManifestUrl,
      this.executablePath,
      this.installRoot,
      this.restart = _closeAndRestart,
      this.skipDevBuilds = true,
      Future<void> Function(UpdateManifest manifest)? beforeRestart})
      : beforeRestart = beforeRestart ?? WhatsNew.instance.installing;

  final status = ValueNotifier(const UpdateStatus(UpdatePhase.idle));
  /// The manifest of the last check that read one, newer or not (What's
  /// new picks up this version's notes from it).
  final latest = ValueNotifier<UpdateManifest?>(null);
  /// Outcome of the last finished check, for Settings/About wording
  /// ("Up to date", "Check failed: ..."); null until one finishes.
  final lastCheck = ValueNotifier<String?>(null);
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
      final m = await fetchLatestManifest(
          currentVersion: currentVersion, url: manifestUrl);
      latest.value = m;
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
    } catch (e) {
      _log.warning('update check failed: $e');
      lastCheck.value = 'Update check failed: $e';
    }
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
      _log.warning('update failed: $e');
      status.value = UpdateStatus(UpdatePhase.failed,
          manifest: m, error: '$e', canInstall: true);
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
    // Started by an old name (1.2.x's restart, an old launcher): the new
    // binary next to it.
    await restart(relaunchExecutable(_exe), launchArgs);
  }
}
