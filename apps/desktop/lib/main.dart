import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';

import 'app.dart';
import 'src/platform/app_dirs.dart';
import 'src/platform/app_log.dart';
import 'src/platform/app_shutdown.dart';
import 'src/platform/desktop_entry.dart';
import 'src/screens/home/ui.dart';
import 'src/session/app_events.dart' show UpdateAvailable;
import 'src/state/session_state.dart';
import 'src/state/settings.dart';
import 'src/update/update_controller.dart' show UpdateController, UpdatePhase, launchArgs;

Future<void> main(List<String> args) async {
  launchArgs = List.unmodifiable(args);
  if (args.contains('--upgrade')) {
    exitCode = await runUpgrade();
    exit(exitCode);
  }
  initLogging();
  FlutterError.onError = (details) {
    debugPrint('FLUTTER ERROR: ${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFF101010),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Something broke rendering this view:\n${details.exceptionAsString()}',
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
  WidgetsFlutterBinding.ensureInitialized();
  final dirs = await AppDirs.resolve();
  await startAppLogging(dirs);
  // An absolute subDir replaces the documents folder (package:path join).
  await Hive.initFlutter(dirs.hive);
  await AppSettings.instance.ensureLoaded();
  // Close button / Alt+F4: the orderly close ([shutDownApp]), so others
  // see "left", a hosted server shuts down and no player outlives the
  // engine.
  final ports = SessionState.instance.ports;
  await ports.shell.start(
      title: dirs.profile == null ? appName : '$appName [${dirs.profile}]', onCloseRequest: shutDownApp);
  try {
    await SessionState.instance.loadForm();
  } catch (e, st) {
    debugPrint('load connect form failed: $e\n$st');
  }
  MediaKit.ensureInitialized();
  // yt-dlp for web page links: downloaded on first run, kept current.
  ports.links.warmUp();
  // Linux: the launcher entry and icon Wayland needs (release installs).
  unawaited(installDesktopEntry());
  // A found update is an event too (the band shows it).
  final updates = UpdateController.instance;
  updates.status.addListener(() {
    final s = updates.status.value;
    final version = s.manifest?.version;
    if (s.phase == UpdatePhase.available && version != null) {
      SessionState.instance.notifier.notify(UpdateAvailable(version));
    }
  });
  runApp(const WatchTogetherApp());
  // The sound device opens once the window is up, not on the first sound.
  Future.delayed(const Duration(seconds: 2), SessionState.instance.sfx.warmUp);
}
