import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sync_relay_core/core.dart';

import 'app.dart';
import 'src/state/session_state.dart';

Future<void> main(List<String> args) async {
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
  await Hive.initFlutter();
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
