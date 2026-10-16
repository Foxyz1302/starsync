import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:sync_relay_core/core.dart';

import 'app.dart';
import 'src/app/app_graph.dart';
import 'src/files/thumbnails.dart' show thumbnailPlayers;
import 'src/platform/app_log.dart';
import 'src/platform/app_shutdown.dart' show closeAppWith;
import 'src/platform/desktop/desktop_app_dirs.dart';
import 'src/platform/desktop_entry.dart';
import 'src/platform/smoke.dart';
import 'src/screens/home/ui.dart';
import 'src/session/app_events.dart' show UpdateAvailable;
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
  final dirs = await const DesktopAppDirs().resolve();
  await startAppLogging(dirs);
  Hive.init(dirs.hive);
  await AppSettings.instance.ensureLoaded();
  // The composition root: every system, made once.
  final graph = AppGraph.build();
  // Sounds stay off after an audio-device crash (see SoundEngine.crashMark).
  graph.sfx.engine.crashMark = '${dirs.support}${Platform.pathSeparator}audio-init.pending';
  final ports = graph.ports;
  // Close button / Alt+F4: the orderly close ([shutDownApp]), so others
  // see "left", your server shuts down and no player outlives the engine.
  final close = closeAppWith(graph);
  await ports.shell.start(
      title: dirs.profile == null ? appName : '$appName [${dirs.profile}]', onCloseRequest: () => close());
  // Focus, minimise and restore feed auto sit-out and the Notifier (in
  // the background, notices go out as system notifications).
  ports.shell.watchActivity((a) {
    graph.coordinator.windowActivity(a);
    graph.notifier.window = a;
  });
  try {
    await graph.forms.load();
  } catch (e, st) {
    debugPrint('load connect form failed: $e\n$st');
  }
  // The library's matches, pins and offsets, and the watch history
  // (device-owned).
  unawaited(graph.library.ensureLoaded());
  unawaited(graph.watch.history.ensureLoaded());
  ports.players.init();
  thumbnailPlayers = ports.players;
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
      graph.notifier.notify(UpdateAvailable(version));
    }
  });
  runApp(AppScope(graph: graph, child: const WatchTogetherApp()));
  // CI's close smoke run: open a file, play, close (see smoke.dart).
  final smoke = smokeMedia;
  if (smoke != null) {
    unawaited(WidgetsBinding.instance.endOfFrame.then((_) => runSmoke(graph, smoke)));
  }
  // Home: your own server, quietly (only this app can reach it until
  // Invite).
  unawaited(graph.navigation.start());
  // The sound device opens once the window is up, not on the first sound.
  Future.delayed(const Duration(seconds: 2), graph.sfx.warmUp);
}
