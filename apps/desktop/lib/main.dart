import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'src/screens/home/ui.dart';
import 'src/state/session_state.dart';
import 'src/state/settings.dart';
import 'src/update/updater.dart';

Future<void> main(List<String> args) async {
  launchArgs = List.unmodifiable(args);
  if (args.contains('--upgrade')) {
    exitCode = await runUpgrade();
    exit(exitCode);
  }
  initLogging();
  if (args.contains('--headless')) {
    await runHeadless(args);
    return;
  }
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
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  windowManager.addListener(_CloseGuard());
  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(160, 90),
    center: true,
    backgroundColor: Color(0xFF000000),
    titleBarStyle: TitleBarStyle.hidden,
    title: appName,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  await Hive.initFlutter();
  await AppSettings.instance.ensureLoaded();
  try {
    await SessionState.instance.loadForm();
  } catch (e, st) {
    debugPrint('load connect form failed: $e\n$st');
  }
  MediaKit.ensureInitialized();
  runApp(const WatchTogetherApp());
}

Future<void> runHeadless(List<String> args) async {
  final session = SessionState.instance;
  await session.startHeadless(args);
  await ProcessSignal.sigint.watch().first;
  await session.stopServer();
}

/// Close button / Alt+F4: leave gracefully first (others see "left", a
/// hosted server shuts down), bounded so a hung socket can't keep the
/// window open.
class _CloseGuard with WindowListener {
  bool _closing = false;

  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await SessionState.instance.leave().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('leave on close failed: $e');
    }
    await windowManager.destroy();
  }
}
