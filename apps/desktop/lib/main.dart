import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'src/playback/yt_dlp_app.dart';
import 'src/platform/desktop_entry.dart';
import 'src/platform/window_memory.dart';
import 'src/screens/home/ui.dart';
import 'src/state/session_state.dart';
import 'src/state/settings.dart';
import 'src/update/update_controller.dart' show launchArgs;

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
  await Hive.initFlutter();
  await AppSettings.instance.ensureLoaded();
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  final memory = WindowMemory(Hive.isBoxOpen(settingsBoxName) ? Hive.box(settingsBoxName) : null);
  windowManager.addListener(_CloseGuard(memory));
  final windowOptions = WindowOptions(
    size: memory.size,
    minimumSize: const Size(160, 90),
    center: !memory.hasPosition,
    backgroundColor: const Color(0xFF000000),
    titleBarStyle: TitleBarStyle.hidden,
    title: appName,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await memory.restore();
    await windowManager.show();
    await windowManager.focus();
  });
  try {
    await SessionState.instance.loadForm();
  } catch (e, st) {
    debugPrint('load connect form failed: $e\n$st');
  }
  MediaKit.ensureInitialized();
  // yt-dlp for web page links: downloaded on first run, kept current.
  AppYtDlp.instance.warmUp();
  // Linux: the launcher entry and icon Wayland needs (release installs).
  unawaited(installDesktopEntry());
  runApp(const WatchTogetherApp());
}

/// Close button / Alt+F4: leave gracefully first (others see "left", a
/// hosted server shuts down), bounded so a hung socket can't keep the
/// window open.
class _CloseGuard with WindowListener {
  final WindowMemory memory;
  bool _closing = false;
  _CloseGuard(this.memory);

  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    _closing = true;
    await memory.save();
    try {
      await SessionState.instance.leave().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('leave on close failed: $e');
    }
    await windowManager.destroy();
  }
}
