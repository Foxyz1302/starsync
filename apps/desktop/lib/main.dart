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
import 'src/platform/crash_watch.dart';
import 'src/platform/desktop/attention.dart' show exitNow, windowLaunchToken;
import 'src/platform/desktop/desktop_app_dirs.dart';
import 'src/platform/desktop/windows_api.dart' show allowSetForegroundWindow;
import 'src/platform/desktop_entry.dart';
import 'src/platform/ports/window_activity.dart';
import 'src/platform/single_instance.dart';
import 'src/platform/url_scheme.dart';
import 'src/platform/smoke.dart';
import 'src/screens/home/ui.dart';
import 'src/session/app_events.dart' show UpdateAvailable;
import 'src/session/invite.dart' show InviteLink;
import 'src/state/settings.dart';
import 'src/update/update_controller.dart' show UpdatePhase, launchArgs;

Future<void> main(List<String> args) async {
  // An invite link is handled once: Update and restart does not pass it on.
  launchArgs = List.unmodifiable([
    for (final a in args)
      if (InviteLink.parse(a) == null) a,
  ]);
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
  // One app per profile: a second start (a clicked starsync:// link) hands
  // its arguments to the running one and ends before its window shows.
  final instance = await InstanceLock.claim(
    Directory(dirs.hive).parent.path,
    args: args,
    activation: await windowLaunchToken(),
    beforeSend: Platform.isWindows ? allowSetForegroundWindow : null,
  );
  if (instance == null) await exitNow();
  await startAppLogging(dirs);
  // The last run's unclean end (and its Windows crash records), and UI
  // stalls (ARCHITECTURE "Logging").
  startCrashWatch(Directory(dirs.logs).parent.path, version: displayVersion());
  startStallWatch();
  Hive.init(dirs.hive);
  await AppSettings.instance.ensureLoaded();
  // The composition root: every system, made once.
  final graph = AppGraph.build();
  final ports = graph.ports;
  // Close button / Alt+F4: the orderly close ([shutDownApp]), so others
  // see "left", your server shuts down and no player outlives the engine.
  final close = closeAppWith(graph, instance: instance);
  await ports.shell.start(
      title: dirs.profile == null ? appName : '$appName [${dirs.profile}]', onCloseRequest: () => close());
  // Focus, minimise and restore feed auto sit-out and the Notifier (in
  // the background, notices go out as system notifications).
  // Coming to the front also looks for an invite on the clipboard (the
  // join prompt; nothing of it is logged).
  ports.shell.watchActivity((a) {
    graph.coordinator.windowActivity(a);
    graph.notifier.window = a;
    if (a == WindowActivity.focused) {
      unawaited(ports.shell.readClipboardText().then(graph.joinOffers.fromClipboard));
    }
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
  // Windows: starsync:// links start this install (HKCU, release builds).
  unawaited(registerWindowsScheme());
  // A found update is an event too (the band shows it).
  final updates = graph.updates;
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
  // A clicked invite link: the one this app started with, then each one a
  // later start hands over (the window comes to the front for it).
  graph.joinOffers.fromArgs(args);
  instance.handoffs.listen((h) {
    unawaited(ports.shell.focus(activation: h.activation));
    graph.joinOffers.fromArgs(h.args);
  });
  unawaited(ports.shell.readClipboardText().then(graph.joinOffers.fromClipboard));
  // The sound device opens once the window is up, not on the first sound.
  Future.delayed(const Duration(seconds: 2), graph.sfx.warmUp);
}
